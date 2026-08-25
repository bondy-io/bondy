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
through `bondy_http_transport_queue'.

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

== Lifecycle telemetry ==

`terminate/2' emits `[bondy, http_transport, session, closed]'
unconditionally (the node's telemetry discipline), carrying the transport
facts, the session lifetime, and the stop reason classified to an atom:
a `{shutdown, Tag}' stop answers `Tag' — so `close/2' callers and the
inactivity check name their reason (`client_close', `idle_timeout', ...) —
`normal'/`shutdown' pass through, and anything else is `crash'. The event
also carries the opaque `metadata' map a transport handler registered via
`set_telemetry_metadata/2' (or `undefined'): a consumer such as the MCP
gateway matches on its own metadata key to account only its sessions.

Because `init/1' traps exits, `terminate/2' — and therefore the event —
runs for every stop return, `close/2' call, and parent shutdown; only a
brutal `kill' skips it.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-record(state, {
    transport_id :: binary(),
    realm_uri :: uri(),
    session_id :: optional(bondy_session_id:t()),
    created_at :: pos_integer(),
    last_activity :: pos_integer(),
    transport_ttl :: pos_integer(),
    protocol_state :: optional(bondy_wamp_protocol:state()),
    subprotocol :: optional(subprotocol()),
    encoding :: optional(encoding()),
    sse_pid :: optional(pid()),
    sse_monitor :: optional(reference()),
    poll_from :: optional(gen_server:from()),
    poll_timer :: optional(reference()),
    auth_claims :: optional(map()),
    %% Whether a connected SSE stream exempts the session from the
    %% inactivity check (the WAMP SSE transport's semantics, and the
    %% default). A transport whose held stream is an accessory rather
    %% than the client's whole connection — MCP's handshake-era GET
    %% stream — sets `sse_counts_as_activity => false` so that only
    %% explicit `touch/1` calls keep the session alive.
    sse_activity = true :: boolean(),
    %% Opaque map a transport handler registers via
    %% `set_telemetry_metadata/2`; carried verbatim on the lifecycle
    %% telemetry event. This module never reads it.
    telemetry_metadata :: optional(map()),
    %% Opaque state a transport handler attaches via `with_state/2`.
    %% This module never reads it.
    handler_state :: any()
}).

-type opts() :: #{sse_counts_as_activity => boolean()}.
-export_type([opts/0]).

%% API
-export([auth_claims/1]).
-export([start_link/4]).
-export([close/1]).
-export([close/2]).
-export([set_telemetry_metadata/2]).
-export([encoding/1]).
-export([handle_client_message/2]).
-export([init_protocol/3]).
-export([notify_enqueue/1]).
-export([poll_receive/2]).
-export([request_poll/2]).
-export([register_sse_stream/2]).
-export([register_sse_stream/3]).
-export([set_auth_claims/2]).
-export([whereis/1]).
-export([with_state/2]).
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

%% =============================================================================
%% API
%% =============================================================================

-doc """
Starts a transport session gen_server.

Registers with gproc as `{http_transport, TransportId}` and initialises the
transport queue via `bondy_http_transport_queue:init_transport/3`.

`Opts` may carry `sse_counts_as_activity` (default `true`): whether a
connected SSE stream by itself exempts the session from the inactivity
check — see the state field's comment.
""".
-spec start_link(
    TransportId :: binary(),
    RealmUri :: uri(),
    SessionId :: bondy_session_id:t(),
    Opts :: opts()
) -> {ok, pid()} | {error, term()}.

start_link(TransportId, RealmUri, SessionId, Opts) when
    is_binary(TransportId), is_map(Opts)
->
    gen_server:start_link(
        ?MODULE,
        [TransportId, RealmUri, SessionId, Opts],
        []
    ).

-doc """
Gracefully closes a transport session with reason `client_close`.
Equivalent to `close(PidOrId, client_close)`.
""".
-spec close(pid() | binary()) -> ok.

close(PidOrId) ->
    close(PidOrId, client_close).

-doc """
Gracefully closes a transport session. Accepts either a pid or a
`TransportId` binary. Unregisters gproc, deletes the transport queue,
and stops the gen_server with `{shutdown, Reason}`, so `Reason` names
the close on the lifecycle telemetry event (see the moduledoc). The
supervisor's restart strategy is `temporary`, so no stop reason triggers
a restart.
""".
-spec close(pid() | binary(), Reason :: atom()) -> ok.

close(Pid, Reason) when is_pid(Pid), is_atom(Reason) ->
    try
        gen_server:stop(Pid, {shutdown, Reason}, 5000)
    catch
        %% `gen:stop/3` on a dead pid exits the caller with a BARE
        %% `noproc`; when the server terminates with a different reason
        %% while the request is in flight (e.g. a racing close or the
        %% inactivity check) the caller exits with
        %% `{ActualReason, {sys, terminate, _}}`. Either way the goal —
        %% the session is down — is met.
        exit:noproc ->
            ok;
        exit:{noproc, _} ->
            ok;
        exit:{normal, _} ->
            ok;
        exit:{shutdown, _} ->
            ok;
        exit:{{shutdown, _}, _} ->
            ok
    end;
close(TransportId, Reason) when is_binary(TransportId) ->
    case ?MODULE:whereis(TransportId) of
        undefined ->
            ok;
        Pid ->
            close(Pid, Reason)
    end.

-doc """
Registers the opaque metadata map carried on this session's lifecycle
telemetry event (see the moduledoc). A synchronous call by design: a
handler that announces "session opened" only after this returns knows
that any later stop event for this session carries the metadata — so an
open it accounted is never missed by its close accounting.
""".
-spec set_telemetry_metadata(pid(), map()) -> ok.

set_telemetry_metadata(Pid, Metadata) when is_pid(Pid), is_map(Metadata) ->
    gen_server:call(Pid, {set_telemetry_metadata, Metadata}).

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
Registers the SSE stream pid with the transport session, replacing any
previously registered stream. Equivalent to `register_sse_stream/3` with
`mode => replace`.
""".
-spec register_sse_stream(
    SessionPid :: pid(),
    StreamPid :: pid()
) -> ok.

register_sse_stream(SessionPid, StreamPid) ->
    ok = register_sse_stream(SessionPid, StreamPid, #{mode => replace}).

-doc """
Registers the SSE stream pid with the transport session.

The SSE stream handler calls this after connecting; the session then
notifies the stream (`drain_queue`) whenever the transport queue has
content.

`mode => replace` (the default) replaces a previously registered stream —
the WAMP SSE transport's reconnect semantics. `mode => exclusive` refuses
with `{error, already_registered}` while a previously registered stream
is still alive — for transports that allow one held stream per session
(MCP's handshake-era GET stream answers it with `409 Conflict`). A dead
predecessor never blocks: liveness is checked here because the `DOWN`
that clears the registration may still be queued behind this call.
""".
-spec register_sse_stream(
    SessionPid :: pid(),
    StreamPid :: pid(),
    Opts :: #{mode => replace | exclusive}
) -> ok | {error, already_registered}.

register_sse_stream(SessionPid, StreamPid, Opts) when
    is_pid(SessionPid) andalso is_pid(StreamPid) andalso is_map(Opts)
->
    Mode = maps:get(mode, Opts, replace),
    gen_server:call(SessionPid, {register_sse_stream, StreamPid, Mode}).

-doc """
Runs `Fun(HandlerState)` inside the session process and stores the new
handler state it returns. The handler state is opaque to this module: a
transport handler (e.g. the MCP handshake era) keeps its per-session
state here so that updates from concurrent HTTP request processes are
serialized by this gen_server, and so that code needing to run in the
session process — such as `bondy_session_manager:open/3`, whose monitor
must target this process — has a place to run.

A raising closure answers `{error, {Class, Reason}}` and leaves the
handler state unchanged; it never terminates the session.
""".
-spec with_state(
    Pid :: pid(),
    Fun :: fun((HandlerState :: any()) -> {Reply :: any(), any()})
) -> {ok, Reply :: any()} | {error, {atom(), any()}}.

with_state(Pid, Fun) when is_pid(Pid), is_function(Fun, 1) ->
    %% The closure may itself make a 15s-bounded call
    %% (`bondy_session_manager:open/3`), so the outer timeout exceeds it.
    gen_server:call(Pid, {with_state, Fun}, 30000).

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

poll_receive(Pid, Timeout) when
    is_pid(Pid) andalso is_integer(Timeout) andalso Timeout > 0
->
    gen_server:call(Pid, {poll_receive, Timeout}, Timeout + 5000).

-doc """
Async alternative to `poll_receive/2`.

Sends a `{request_poll, Timeout, ReplyTo}` cast to the transport session. The
session will send `{poll_result, {ok, Result}}` to the `ReplyTo` pid when data
is available or the timeout expires.
""".
-spec request_poll(Pid :: pid(), Timeout :: pos_integer()) -> ok.

request_poll(Pid, Timeout) when
    is_pid(Pid) andalso is_integer(Timeout) andalso Timeout > 0
->
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

init([TransportId, RealmUri, SessionId, Opts]) ->
    process_flag(trap_exit, true),

    %% Register with gproc
    true = bondy_gproc:register({http_transport, TransportId}),

    %% Initialise the transport queue
    case
        bondy_http_transport_queue:init_transport(
            TransportId, RealmUri, SessionId
        )
    of
        ok ->
            TTL = bondy_config:get([http_transport, idle_timeout], 3600000),
            Now = erlang:system_time(millisecond),

            State = #state{
                transport_id = TransportId,
                realm_uri = RealmUri,
                session_id = SessionId,
                created_at = Now,
                last_activity = Now,
                transport_ttl = TTL,
                sse_activity = maps:get(sse_counts_as_activity, Opts, true)
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
    ProtoState =
        case State#state.auth_claims of
            undefined ->
                ProtoState0;
            Claims ->
                bondy_wamp_protocol:set_auth_claims(Claims, ProtoState0)
        end,
    try bondy_wamp_protocol:handle_inbound(Data, ProtoState) of
        {reply, Bins, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            S2 = enqueue_replies(Bins, S1),
            {reply, ok, S2};
        {noreply, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            {reply, ok, S1};
        {stop, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            {stop, normal, ok, S1};
        {stop, Bins, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            S2 = enqueue_replies(Bins, S1),
            signal_sse_stop(Bins, S2),
            {stop, normal, ok, deliver_to_poller(S2)};
        {stop, _Reason, Bins, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            S2 = enqueue_replies(Bins, S1),
            signal_sse_stop(Bins, S2),
            {stop, normal, ok, deliver_to_poller(S2)}
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
handle_call({register_sse_stream, StreamPid, Mode}, _From, State) ->
    Prev = State#state.sse_pid,
    case
        Mode == exclusive andalso is_pid(Prev) andalso is_process_alive(Prev)
    of
        true ->
            {reply, {error, already_registered}, State};
        false ->
            %% Replacing (or succeeding a dead stream): release the old
            %% monitor, or its eventual DOWN would clear the NEW
            %% registration.
            case State#state.sse_monitor of
                undefined -> ok;
                OldRef -> erlang:demonitor(OldRef, [flush])
            end,
            MonRef = erlang:monitor(process, StreamPid),
            S1 = State#state{sse_pid = StreamPid, sse_monitor = MonRef},
            %% Anything produced before the stream attached is in the queue,
            %% in order, so the stream drains it like everything else instead
            %% of being handed a separate buffer first.
            ok = notify_enqueue(State#state.transport_id),
            {reply, ok, S1}
    end;
handle_call({with_state, Fun}, _From, State) ->
    try Fun(State#state.handler_state) of
        {Reply, HandlerState} ->
            {reply, {ok, Reply}, State#state{handler_state = HandlerState}};
        Other ->
            %% A non-matching `of` pattern raises OUTSIDE this try's own
            %% catch, so the contract violation is answered explicitly
            %% rather than crashing the session.
            {reply, {error, {bad_return, Other}}, State}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Transport handler closure raised",
                transport_id => State#state.transport_id,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {reply, {error, {Class, Reason}}, State}
    end;
handle_call({poll_receive, Timeout}, From, State) ->
    %% One queue, so one read. Return one item at a time: the longpoll handler
    %% is unbatched and consumes only the first, so the rest must stay queued.
    TransportId = State#state.transport_id,

    case bondy_http_transport_queue:dequeue_batch(TransportId, 1) of
        [Item] ->
            {reply, {ok, poll_result(Item)}, State};
        [] ->
            %% Nothing available, block until messages arrive or timeout
            TimerRef = erlang:send_after(
                Timeout, self(), {poll_timeout, From}
            ),
            S1 = State#state{poll_from = From, poll_timer = TimerRef},
            {noreply, S1}
    end;
handle_call({set_telemetry_metadata, Metadata}, _From, State) ->
    {reply, ok, State#state{telemetry_metadata = Metadata}};
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
    TransportId = State#state.transport_id,

    case bondy_http_transport_queue:dequeue_batch(TransportId, 1) of
        [Item] ->
            ReplyTo ! {poll_result, {ok, poll_result(Item)}},
            {noreply, State};
        [] ->
            TimerRef = erlang:send_after(
                Timeout, self(), {poll_timeout, {async, ReplyTo}}
            ),
            S1 = State#state{
                poll_from = {async, ReplyTo}, poll_timer = TimerRef
            },
            {noreply, S1}
    end;
handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

handle_info(queue_ready, #state{poll_from = PollFrom} = State) when
    PollFrom =/= undefined
->
    {noreply, deliver_to_poller(State)};
handle_info(queue_ready, #state{sse_pid = SsePid} = State) when
    is_pid(SsePid)
->
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
            S2 = enqueue_replies([Bin], S1),
            {noreply, S2};
        {stop, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            {stop, normal, S1};
        {stop, Bin, NewProtoState} ->
            S1 = State#state{protocol_state = NewProtoState},
            S2 = enqueue_replies([Bin], S1),
            signal_sse_stop([Bin], S2),
            {stop, normal, deliver_to_poller(S2)};
        {stop, Bin, NewProtoState, _After} ->
            S1 = State#state{protocol_state = NewProtoState},
            S2 = enqueue_replies([Bin], S1),
            signal_sse_stop([Bin], S2),
            {stop, normal, deliver_to_poller(S2)};
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
handle_info(
    check_inactivity,
    #state{sse_pid = SsePid, sse_activity = true} = State
) when is_pid(SsePid) ->
    %% An SSE stream is connected and this transport counts it as
    %% activity (the default — the WAMP SSE transport's semantics), so
    %% skip the inactivity check and reschedule. A transport started with
    %% `sse_counts_as_activity => false` falls through to the normal
    %% check: its held stream does not keep the session alive.
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
            {stop, {shutdown, idle_timeout}, State};
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

terminate(Reason, #state{transport_id = TransportId} = State) ->
    %% Lifecycle event before any cleanup step. `emit_closed/2` is total
    %% (its try/catch swallows everything), so it cannot endanger the
    %% queue-cleanup guarantee below.
    ok = emit_closed(Reason, State),

    %% Cleanup transport queue FIRST — this is the most important cleanup
    %% (without it, queue entries and the meta row leak until the eviction
    %% sweep ages them out). Running it first guarantees it happens even if
    %% a subsequent cleanup step raises unexpectedly.
    ok = bondy_http_transport_queue:delete_transport(TransportId),

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

    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% One queue, two result shapes, decided per ITEM rather than per source: an
%% entry the protocol already encoded answers `replies', a record the router
%% delivered answers `messages' for the caller to encode. The handlers read both
%% and always did; what has changed is that the ORDER between them is now the
%% queue's, not a priority rule.
%% @private Hand one queued message to a parked longpoll poll, if one is parked.
%%
%% Shared by the `queue_ready' notification and by the terminal-stop paths. The
%% stop paths need it because `enqueue_replies/2' delivers by sending
%% `queue_ready' to self(), and a gen_server returning `{stop, ...}' never
%% handles its own mailbox again — so the ABORT or GOODBYE just queued was
%% deleted unread by `terminate/2', and the client's next request answered
%% `404 transport_not_found'. A failed credential reached the client as a
%% missing transport. SSE never had the bug because `signal_sse_stop/2' hands
%% the bins straight to the stream process; this is longpoll's counterpart.
%%
%% One message, because the longpoll handler is unbatched. On the stop path the
%% rest go with the queue, which is the terminal reply itself and nothing else.
%%
%% This does not close the window: a client whose poller is between cycles has
%% nothing parked here, and still learns of the close from the next request's
%% 404. What it removes is the case where the client IS waiting and the router
%% has the answer in hand.
deliver_to_poller(#state{poll_from = undefined} = State) ->
    State;
deliver_to_poller(#state{poll_from = {async, ReplyTo}} = State) ->
    Msgs = bondy_http_transport_queue:dequeue_batch(
        State#state.transport_id, 1
    ),
    ReplyTo ! {poll_result, {ok, poll_result(Msgs)}},
    clear_poll(State);
deliver_to_poller(#state{poll_from = PollFrom} = State) ->
    Msgs = bondy_http_transport_queue:dequeue_batch(
        State#state.transport_id, 1
    ),
    gen_server:reply(PollFrom, {ok, poll_result(Msgs)}),
    clear_poll(State).

%% @private
clear_poll(State) ->
    _ = erlang:cancel_timer(State#state.poll_timer),
    State#state{poll_from = undefined, poll_timer = undefined}.

poll_result([]) ->
    {messages, []};
poll_result([Item]) ->
    poll_result(Item);
poll_result({encoded, Bin}) ->
    {replies, [Bin]};
poll_result(Msg) ->
    {messages, [Msg]}.

%% @private
schedule_inactivity_check(#state{transport_ttl = TTL}) ->
    %% Check at half the TTL interval, but at least every MIN_CHECK_INTERVAL ms
    Interval = max(?MIN_CHECK_INTERVAL, TTL div 2),
    _ = erlang:send_after(Interval, self(), check_inactivity),
    ok.

%% @private
%% A synchronous reply goes into the SAME queue the router's deliveries go into,
%% and then wakes whoever is waiting, exactly as `bondy:maybe_enqueue/3' does.
%%
%% Every clause, not only the "nobody is waiting" one. A direct
%% `gen_server:reply/2' here would still let a reply produced now overtake a
%% message queued a moment ago, which is the whole defect: this used to keep
%% replies in a `reply_buffer' that `poll_receive' drained FIRST, so a client
%% received them out of order. Pinned by
%% `bondy_http_longpoll_SUITE:queued_message_precedes_later_synchronous_reply'.
enqueue_replies(Bins, #state{transport_id = TransportId} = State) ->
    ok = lists:foreach(
        fun(Bin) ->
            _ = bondy_http_transport_queue:enqueue(
                TransportId, {encoded, iolist_to_binary(Bin)}, #{}
            ),
            ok
        end,
        Bins
    ),
    ok = notify_enqueue(TransportId),
    State.

%% @private
signal_sse_stop(FinalBins, #state{sse_pid = SsePid}) when is_pid(SsePid) ->
    SsePid ! {stop_stream, FinalBins};
signal_sse_stop(_FinalBins, _State) ->
    ok.

%% @private
%% Total: the lifecycle event must never fail `terminate/2`.
emit_closed(Reason, State) ->
    try
        Now = erlang:system_time(millisecond),
        telemetry:execute(
            [bondy, http_transport, session, closed],
            #{count => 1, duration => Now - State#state.created_at},
            #{
                transport_id => State#state.transport_id,
                realm => State#state.realm_uri,
                session_id => State#state.session_id,
                reason => close_reason(Reason),
                metadata => State#state.telemetry_metadata
            }
        )
    catch
        _:_ ->
            ok
    end.

%% @private
%% A `{shutdown, Tag}` stop names its close reason; plain graceful stops
%% pass through; anything else is a crash.
close_reason(normal) -> normal;
close_reason(shutdown) -> shutdown;
close_reason({shutdown, Tag}) when is_atom(Tag) -> Tag;
close_reason({shutdown, _}) -> shutdown;
close_reason(_) -> crash.
