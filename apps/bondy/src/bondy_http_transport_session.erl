%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_http_transport_session).
-moduledoc """
A gen_server implementing a per-transport session process for HTTP transports
(longpoll/SSE).

== Motivation ==

WebSocket and TCP transports have a long-lived connection process whose pid
serves as the stable identity for the WAMP session. HTTP transports (longpoll,
SSE) do not — each HTTP request is handled by an ephemeral Cowboy process. This
module provides the persistent process that fills that role.

== Relationship with `bondy_session' and `bondy_session_manager' ==

<ul>
<li>`bondy_session' is a pure data module (no process). It defines the
`#session{}' record and provides ETS-backed storage, accessors, and matching.
It has no lifecycle management.</li>
<li>`bondy_session_manager' is a `gen_server' pool that owns session lifecycle:
it stores sessions, monitors the owning connection process, registers WAMP
procedures, and cleans up on crash or close.</li>
<li>`bondy_http_transport_session' (this module) is the process that
`bondy_session_manager' monitors for HTTP transports. It is the HTTP-transport
equivalent of the WebSocket/TCP connection handler pid.</li>
</ul>

The interaction flow on session creation:

```
HTTP Request (WAMP HELLO)
    |
    v
bondy_http_transport_session:handle_client_message/2
    |  (gen_server:call -> handle_call({client_message, Data}))
    |
    v
bondy_wamp_protocol:handle_inbound/2
    |  (runs inside this gen_server's process)
    |
    +---> bondy_session_manager:open/3
    |        |
    |        +---> bondy_session:store(Session)       <- persists to ETS
    |        +---> monitor(process, self())            <- monitors this pid
    |        +---> register WAMP procedures
    |
    v
WELCOME reply returned to client
```

Note that `bondy_session_manager:open/3' is called by `bondy_wamp_protocol',
not by this module directly. However, because `bondy_wamp_protocol' runs
inside this gen_server's process, `bondy_session_manager' ends up monitoring
this pid — making it the crash-safety anchor for the WAMP session.

If this process dies (inactivity timeout, crash), `bondy_session_manager'
detects the `DOWN' signal and cleans up the WAMP session automatically.

== Transport identity ==

Each transport session is identified by a `TransportId' (binary) and registered
with gproc as `{http_transport, TransportId}'. This maps to the `transport_id'
field in the `#session{}' record. An inactivity timer auto-closes the session
if no HTTP request touches it within the configured `transport_ttl' window.

== Protocol and message handling ==

This gen_server holds the `bondy_wamp_protocol' state and routes inbound
client messages via `handle_client_message/2'. Outbound messages are delivered
through `bondy_transport_queue'.

For SSE transports, the gen_server additionally manages:
<ul>
<li>SSE stream pid registration and monitoring</li>
<li>Reply buffering for sync replies before the SSE stream connects</li>
<li>Queue-ready notifications forwarded to the SSE stream pid</li>
</ul>

For Longpoll transports, the gen_server additionally manages:
<ul>
<li>Blocking `poll_receive' calls with configurable timeout</li>
<li>Reply buffering for sync replies before a poll_receive call arrives</li>
</ul>
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").


-record(state, {
    transport_id            ::  binary(),
    realm_uri               ::  uri(),
    session_id              ::  optional(bondy_session_id:t()),
    created_at              ::  pos_integer(),
    last_activity           ::  pos_integer(),
    transport_ttl           ::  pos_integer(),
    protocol_state          ::  optional(bondy_wamp_protocol:state()),
    subprotocol             ::  optional(subprotocol()),
    encoding                ::  optional(encoding()),
    sse_pid                 ::  optional(pid()),
    sse_monitor             ::  optional(reference()),
    reply_buffer = []       ::  [binary()],
    poll_from               ::  optional(gen_server:from()),
    poll_timer              ::  optional(reference()),
    auth_claims             ::  optional(map())
}).


%% API
-export([auth_claims/1]).
-export([start_link/3]).
-export([close/1]).
-export([encoding/1]).
-export([handle_client_message/2]).
-export([init_protocol/3]).
-export([notify_enqueue/1]).
-export([poll_receive/2]).
-export([request_poll/2]).
-export([register_sse_stream/2]).
-export([set_auth_claims/2]).
-export([whereis/1]).
-export([touch/1]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).


%% Inactivity check interval (half the TTL, minimum 5 seconds)
-define(MIN_CHECK_INTERVAL, 5000).

%% Default batch size for dequeue operations
-define(DEQUEUE_BATCH_SIZE, 50).



%% =============================================================================
%% API
%% =============================================================================



-doc """
Starts a transport session gen_server.

Registers with gproc as `{http_transport, TransportId}` and initialises the
transport queue via `bondy_transport_queue:init_transport/3`.
""".
-spec start_link(
    TransportId :: binary(),
    RealmUri :: uri(),
    SessionId :: bondy_session_id:t()
) -> {ok, pid()} | {error, term()}.

start_link(TransportId, RealmUri, SessionId)
when is_binary(TransportId) ->
    gen_server:start_link(
        ?MODULE,
        [TransportId, RealmUri, SessionId],
        []
    ).


-doc """
Gracefully closes a transport session.

Accepts either a pid or a `TransportId` binary. Unregisters gproc, deletes
the transport queue, and stops the gen_server.
""".
-spec close(pid() | binary()) -> ok.

close(Pid) when is_pid(Pid) ->
    try
        gen_server:stop(Pid, normal, 5000)
    catch
        exit:{noproc, _} ->
            ok;
        exit:{normal, _} ->
            ok
    end;

close(TransportId) when is_binary(TransportId) ->
    case ?MODULE:whereis(TransportId) of
        undefined ->
            ok;
        Pid ->
            close(Pid)
    end.


-doc """
Looks up the pid of the transport session registered for `TransportId`.

Returns `undefined` if no session is registered.
""".
-spec whereis(TransportId :: binary()) -> pid() | undefined.

whereis(TransportId) when is_binary(TransportId) ->
    try
        bondy_gproc:lookup_pid({http_transport, TransportId})
    catch
        error:badarg ->
            undefined
    end.


-doc """
Updates the `last_activity` timestamp of the transport session.

Called by HTTP handlers on each request to reset the inactivity timer.
""".
-spec touch(pid()) -> ok.

touch(Pid) when is_pid(Pid) ->
    gen_server:cast(Pid, touch).


-doc """
Initialises the WAMP protocol state within the transport session.

Called after `/open` to set up the subprotocol, encoding, and protocol state
that will be used for all subsequent message handling.
""".
-spec init_protocol(
    Pid :: pid(),
    Subprotocol :: subprotocol(),
    Peer :: bondy_session:peer()
) -> ok | {error, term()}.

init_protocol(Pid, Subprotocol, Peer) when is_pid(Pid) ->
    gen_server:call(Pid, {init_protocol, Subprotocol, Peer}).


-doc """
Processes an inbound WAMP message from the client.

Decodes and routes the message via `bondy_wamp_protocol:handle_inbound/2`.
Sync replies (WELCOME, CHALLENGE, ABORT, etc.) are forwarded directly to the
SSE stream pid, delivered to a waiting longpoll caller, or buffered if neither
is connected.
""".
-spec handle_client_message(
    Pid :: pid(),
    Data :: binary()
) -> ok | {error, term()}.

handle_client_message(Pid, Data) when is_pid(Pid) andalso is_binary(Data) ->
    gen_server:call(Pid, {client_message, Data}).


-doc """
Registers the SSE stream pid with the transport session.

The SSE stream handler calls this after connecting. Any buffered sync replies
are flushed to the stream pid immediately.
""".
-spec register_sse_stream(
    SessionPid :: pid(),
    StreamPid :: pid()
) -> ok.

register_sse_stream(SessionPid, StreamPid)
when is_pid(SessionPid) andalso is_pid(StreamPid) ->
    gen_server:call(SessionPid, {register_sse_stream, StreamPid}).


-doc """
Notifies the transport session that a message was enqueued.

Called by `bondy:maybe_enqueue/3` after successfully enqueuing a message.
If an SSE stream is connected, forwards a `drain_queue` message to it.
If a longpoll caller is waiting, dequeues and replies immediately.
""".
-spec notify_enqueue(TransportId :: binary()) -> ok.

notify_enqueue(TransportId) when is_binary(TransportId) ->
    case ?MODULE:whereis(TransportId) of
        undefined ->
            ok;
        Pid ->
            Pid ! queue_ready,
            ok
    end.


-doc """
Blocking receive for longpoll transports.

Checks for buffered sync replies and queued messages. If none are available,
blocks until messages arrive or the timeout expires.

Returns `{ok, {replies, [binary()]}}` if sync replies are available,
`{ok, {messages, [wamp_message()]}}` if queue messages are available,
or `{ok, {messages, []}}` on timeout.
""".
-spec poll_receive(
    Pid :: pid(),
    Timeout :: pos_integer()
) -> {ok, {replies, [binary()]} | {messages, [wamp_message()]}}.

poll_receive(Pid, Timeout)
when is_pid(Pid) andalso is_integer(Timeout) andalso Timeout > 0 ->
    gen_server:call(Pid, {poll_receive, Timeout}, Timeout + 5000).


-doc """
Async alternative to `poll_receive/2`.

Sends a `{request_poll, Timeout, ReplyTo}` cast to the transport session. The
session will send `{poll_result, {ok, Result}}` to the `ReplyTo` pid when data
is available or the timeout expires.
""".
-spec request_poll(Pid :: pid(), Timeout :: pos_integer()) -> ok.

request_poll(Pid, Timeout)
when is_pid(Pid) andalso is_integer(Timeout) andalso Timeout > 0 ->
    gen_server:cast(Pid, {request_poll, Timeout, self()}).


-doc """
Returns the negotiated encoding for this transport session.
""".
-spec encoding(pid()) -> encoding() | undefined.

encoding(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, encoding).



-doc """
Stores verified auth claims (from `bondy_ticket:verify/1`) in the transport
session. Used for cookie validation on subsequent requests.
""".
-spec set_auth_claims(pid(), map()) -> ok.

set_auth_claims(Pid, Claims) when is_pid(Pid) andalso is_map(Claims) ->
    gen_server:cast(Pid, {set_auth_claims, Claims}).


-doc """
Returns the stored auth claims for this transport session.
""".
-spec auth_claims(pid()) -> map() | undefined.

auth_claims(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, auth_claims).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([TransportId, RealmUri, SessionId]) ->
    process_flag(trap_exit, true),

    %% Register with gproc
    true = bondy_gproc:register({http_transport, TransportId}),

    %% Initialise the transport queue
    case bondy_transport_queue:init_transport(TransportId, RealmUri, SessionId) of
        ok ->
            TTL = bondy_config:get([transport_queue, transport_ttl], 3600000),
            Now = erlang:system_time(millisecond),

            State = #state{
                transport_id = TransportId,
                realm_uri = RealmUri,
                session_id = SessionId,
                created_at = Now,
                last_activity = Now,
                transport_ttl = TTL
            },

            ok = schedule_inactivity_check(State),
            {ok, State};

        {error, already_exists} ->
            %% Clean up gproc and fail
            true = bondy_gproc:unregister({http_transport, TransportId}),
            {stop, {error, already_exists}}
    end.


handle_call({init_protocol, Subprotocol, Peer}, _From, State) ->
    {TransportType, _, Enc} = Subprotocol,
    Opts = #{
        transport_id => State#state.transport_id,
        transport_type => TransportType
    },
    case bondy_wamp_protocol:init(Subprotocol, Peer, Opts) of
        {ok, ProtoState} ->
            S1 = State#state{
                protocol_state = ProtoState,
                subprotocol = Subprotocol,
                encoding = Enc
            },
            {reply, ok, S1};
        {error, Reason, _ProtoState} ->
            {reply, {error, Reason}, State}
    end;

handle_call({client_message, Data}, _From, State) ->
    #state{protocol_state = ProtoState0} = State,
    ProtoState = case State#state.auth_claims of
        undefined ->
            ProtoState0;
        Claims ->
            bondy_wamp_protocol:set_auth_claims(Claims, ProtoState0)
    end,
    try bondy_wamp_protocol:handle_inbound(Data, ProtoState) of
        {reply, Bins, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            S2 = forward_or_buffer(Bins, S1),
            {reply, ok, S2};
        {noreply, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            {reply, ok, S1};
        {stop, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            {stop, normal, ok, S1};
        {stop, Bins, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            _ = forward_or_buffer(Bins, S1),
            signal_sse_stop(Bins, S1),
            {stop, normal, ok, S1};
        {stop, _Reason, Bins, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            _ = forward_or_buffer(Bins, S1),
            signal_sse_stop(Bins, S1),
            {stop, normal, ok, S1}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error handling client message",
                transport_id => State#state.transport_id,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {reply, {error, Reason}, State}
    end;

handle_call({register_sse_stream, StreamPid}, _From, State) ->
    MonRef = erlang:monitor(process, StreamPid),
    %% Flush any buffered sync replies
    Buf = lists:reverse(State#state.reply_buffer),
    lists:foreach(
        fun(Bin) -> StreamPid ! {sync_reply, Bin} end,
        Buf
    ),
    S1 = State#state{
        sse_pid = StreamPid,
        sse_monitor = MonRef,
        reply_buffer = []
    },
    {reply, ok, S1};

handle_call({poll_receive, Timeout}, From, State) ->
    %% Check for buffered sync replies first.
    %% Return one reply at a time; the longpoll handler operates in unbatched
    %% mode and only consumes the first item, so we must keep the rest.
    case State#state.reply_buffer of
        [_ | _] ->
            %% Buffer is in LIFO order; reverse to get FIFO, pop the oldest
            [Reply | Rest] = lists:reverse(State#state.reply_buffer),
            S1 = State#state{reply_buffer = lists:reverse(Rest)},
            {reply, {ok, {replies, [Reply]}}, S1};
        [] ->
            %% Check queue for pending messages — dequeue one at a time
            TransportId = State#state.transport_id,
            case bondy_transport_queue:dequeue_batch(TransportId, 1) of
                [Msg] ->
                    {reply, {ok, {messages, [Msg]}}, State};
                [] ->
                    %% Nothing available, block until messages arrive or timeout
                    TimerRef = erlang:send_after(
                        Timeout, self(), {poll_timeout, From}
                    ),
                    S1 = State#state{
                        poll_from = From,
                        poll_timer = TimerRef
                    },
                    {noreply, S1}
            end
    end;

handle_call(encoding, _From, State) ->
    {reply, State#state.encoding, State};

handle_call(auth_claims, _From, State) ->
    {reply, State#state.auth_claims, State};

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        from => From,
        event => Event
    }),
    {noreply, State}.


handle_cast(touch, State) ->
    Now = erlang:system_time(millisecond),
    {noreply, State#state{last_activity = Now}};

handle_cast({set_auth_claims, Claims}, State) ->
    {noreply, State#state{auth_claims = Claims}};

handle_cast({request_poll, Timeout, ReplyTo}, State) ->
    case State#state.reply_buffer of
        [_ | _] ->
            [Reply | Rest] = lists:reverse(State#state.reply_buffer),
            ReplyTo ! {poll_result, {ok, {replies, [Reply]}}},
            S1 = State#state{reply_buffer = lists:reverse(Rest)},
            {noreply, S1};
        [] ->
            TransportId = State#state.transport_id,
            case bondy_transport_queue:dequeue_batch(TransportId, 1) of
                [Msg] ->
                    ReplyTo ! {poll_result, {ok, {messages, [Msg]}}},
                    {noreply, State};
                [] ->
                    TimerRef = erlang:send_after(
                        Timeout, self(), {poll_timeout, {async, ReplyTo}}
                    ),
                    S1 = State#state{
                        poll_from = {async, ReplyTo},
                        poll_timer = TimerRef
                    },
                    {noreply, S1}
            end
    end;

handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.


handle_info(queue_ready, #state{poll_from = {async, ReplyTo}} = State)
when is_pid(ReplyTo) ->
    %% An async longpoll caller is waiting — dequeue and send message.
    TransportId = State#state.transport_id,
    Msgs = bondy_transport_queue:dequeue_batch(TransportId, 1),
    ReplyTo ! {poll_result, {ok, {messages, Msgs}}},
    _ = erlang:cancel_timer(State#state.poll_timer),
    S1 = State#state{poll_from = undefined, poll_timer = undefined},
    {noreply, S1};

handle_info(queue_ready, #state{poll_from = PollFrom} = State)
when PollFrom =/= undefined ->
    %% A sync longpoll caller is waiting — dequeue one message and reply.
    %% Remaining messages stay in the queue for subsequent poll_receive calls.
    TransportId = State#state.transport_id,
    Msgs = bondy_transport_queue:dequeue_batch(TransportId, 1),
    gen_server:reply(PollFrom, {ok, {messages, Msgs}}),
    _ = erlang:cancel_timer(State#state.poll_timer),
    S1 = State#state{poll_from = undefined, poll_timer = undefined},
    {noreply, S1};

handle_info(queue_ready, #state{sse_pid = SsePid} = State)
when is_pid(SsePid) ->
    SsePid ! drain_queue,
    {noreply, State};

handle_info(queue_ready, State) ->
    %% No SSE stream or longpoll caller, messages stay in queue
    {noreply, State};

handle_info({?BONDY_REQ, _Pid, _RealmUri, M}, State) ->
    #state{protocol_state = ProtoState} = State,
    try bondy_wamp_protocol:handle_outbound(M, ProtoState) of
        {ok, Bin, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            S2 = forward_or_buffer(Bin, S1),
            {noreply, S2};
        {stop, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            {stop, normal, S1};
        {stop, Bin, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            _ = forward_or_buffer(Bin, S1),
            signal_sse_stop([Bin], S1),
            {stop, normal, S1};
        {stop, Bin, NewProtoState, _After} ->
            S1 = State#state{protocol_state = NewProtoState},
            _ = forward_or_buffer(Bin, S1),
            signal_sse_stop([Bin], S1),
            {stop, normal, S1};
        {error, _Reason, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            {noreply, S1}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error handling outbound message",
                transport_id => State#state.transport_id,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {noreply, State}
    end;

handle_info(
    {poll_timeout, {async, ReplyTo} = From},
    #state{poll_from = From} = State
) ->
    %% Async longpoll timeout expired — send empty result
    ReplyTo ! {poll_result, {ok, {messages, []}}},
    S1 = State#state{poll_from = undefined, poll_timer = undefined},
    {noreply, S1};

handle_info({poll_timeout, From}, #state{poll_from = From} = State) ->
    %% Sync longpoll timeout expired — reply with empty result
    gen_server:reply(From, {ok, {messages, []}}),
    S1 = State#state{poll_from = undefined, poll_timer = undefined},
    {noreply, S1};

handle_info({poll_timeout, _StaleFrom}, State) ->
    %% Stale timeout for an already-completed poll, ignore
    {noreply, State};

handle_info(
    {'DOWN', Ref, process, Pid, _Reason},
    #state{sse_pid = Pid, sse_monitor = Ref} = State
) ->
    S1 = State#state{
        sse_pid = undefined,
        sse_monitor = undefined
    },
    {noreply, S1};

handle_info(check_inactivity, #state{sse_pid = SsePid} = State)
when is_pid(SsePid) ->
    %% An SSE stream is connected — the session is actively serving events,
    %% so skip the inactivity check and reschedule.
    ok = schedule_inactivity_check(State),
    {noreply, State};

handle_info(check_inactivity, State) ->
    #state{
        last_activity = LastActivity,
        transport_ttl = TTL
    } = State,

    Now = erlang:system_time(millisecond),
    Elapsed = Now - LastActivity,

    case Elapsed >= TTL of
        true ->
            ?LOG_INFO(#{
                description => "Transport session timed out due to inactivity",
                transport_id => State#state.transport_id,
                realm_uri => State#state.realm_uri,
                elapsed_ms => Elapsed,
                transport_ttl => TTL
            }),
            {stop, normal, State};
        false ->
            ok = schedule_inactivity_check(State),
            {noreply, State}
    end;

handle_info(Info, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Info
    }),
    {noreply, State}.


terminate(_Reason, #state{transport_id = TransportId} = State) ->
    %% Reply to any pending longpoll caller
    case State#state.poll_from of
        undefined ->
            ok;
        {async, ReplyTo} ->
            ReplyTo ! {poll_result, {ok, {messages, []}}},
            _ = erlang:cancel_timer(State#state.poll_timer);
        PollFrom ->
            gen_server:reply(PollFrom, {ok, {messages, []}}),
            _ = erlang:cancel_timer(State#state.poll_timer)
    end,

    %% Terminate WAMP protocol state if initialised
    case State#state.protocol_state of
        undefined ->
            ok;
        ProtoState ->
            try
                bondy_wamp_protocol:terminate(ProtoState)
            catch
                Class:Reason:Stacktrace ->
                    ?LOG_ERROR(#{
                        description => "Error terminating protocol state",
                        transport_id => TransportId,
                        class => Class,
                        reason => Reason,
                        stacktrace => Stacktrace
                    })
            end
    end,

    %% Signal SSE stream to close if connected
    case State#state.sse_pid of
        undefined ->
            ok;
        SsePid ->
            SsePid ! {stop_stream, []}
    end,

    %% Cleanup gproc registration
    try
        true = bondy_gproc:unregister({http_transport, TransportId})
    catch
        error:badarg ->
            %% Already unregistered
            ok
    end,

    %% Cleanup transport queue
    ok = bondy_transport_queue:delete_transport(TransportId),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
schedule_inactivity_check(#state{transport_ttl = TTL}) ->
    %% Check at half the TTL interval, but at least every MIN_CHECK_INTERVAL ms
    Interval = max(?MIN_CHECK_INTERVAL, TTL div 2),
    _ = erlang:send_after(Interval, self(), check_inactivity),
    ok.


%% @private
forward_or_buffer(Bin, State) when is_binary(Bin) ->
    forward_or_buffer([Bin], State);

forward_or_buffer(Bins, #state{sse_pid = SsePid} = State)
when is_pid(SsePid) ->
    lists:foreach(
        fun(Bin) -> SsePid ! {sync_reply, Bin} end,
        Bins
    ),
    State;

forward_or_buffer(Bins, #state{poll_from = {async, ReplyTo}} = State)
when is_pid(ReplyTo) ->
    %% An async longpoll caller is waiting — send sync replies via message
    ReplyTo ! {poll_result, {ok, {replies, Bins}}},
    _ = erlang:cancel_timer(State#state.poll_timer),
    State#state{poll_from = undefined, poll_timer = undefined};

forward_or_buffer(Bins, #state{poll_from = PollFrom} = State)
when PollFrom =/= undefined ->
    %% A sync longpoll caller is waiting — reply with sync replies directly
    gen_server:reply(PollFrom, {ok, {replies, Bins}}),
    _ = erlang:cancel_timer(State#state.poll_timer),
    State#state{poll_from = undefined, poll_timer = undefined};

forward_or_buffer(Bins, #state{reply_buffer = Buf} = State) ->
    State#state{reply_buffer = lists:reverse(Bins) ++ Buf}.


%% @private
signal_sse_stop(FinalBins, #state{sse_pid = SsePid}) when is_pid(SsePid) ->
    SsePid ! {stop_stream, FinalBins};

signal_sse_stop(_FinalBins, _State) ->
    ok.
