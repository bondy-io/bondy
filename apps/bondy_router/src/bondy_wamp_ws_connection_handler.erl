%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_ws_connection_handler).
-moduledoc """
A Cowboy WS handler.

Each WAMP message is transmitted as a separate WebSocket message
(not WebSocket frame)

The WAMP protocol MUST BE negotiated during the WebSocket opening
handshake between Peers using the WebSocket subprotocol negotiation
mechanism.

WAMP uses the following WebSocket subprotocol identifiers for
unbatched modes:

- `wamp.2.json`
- `wamp.2.msgpack`

With `wamp.2.json`, *all* WebSocket messages MUST BE of type **text**
(UTF8 encoded) and use the JSON message serialization.

With `wamp.2.msgpack`, *all* WebSocket messages MUST BE of type
**binary** and use the MsgPack message serialization.

To avoid incompatibilities merely due to naming conflicts with
WebSocket subprotocol identifiers, implementers SHOULD register
identifiers for additional serialization formats with the official
WebSocket subprotocol registry.
""".
-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("http_api.hrl").
-include("bondy.hrl").

-define(SUBPROTO_HEADER, <<"sec-websocket-protocol">>).

-record(state, {
    frame_type :: bondy_wamp_protocol:frame_type(),
    auth_token :: map() | undefined,
    proxy_protocol :: bondy_http_proxy_protocol:t(),
    source_ip :: inet:ip_address(),
    %% The listener's resolved `websocket' carrier config, carried from the
    %% route state (`bondy_http_services:carrier_state/3') so a lookup that
    %% needs it after `init/2' — e.g. `terminate/3' on an idle timeout — does
    %% not have to consult a global.
    config :: map(),
    %% The listener's name, so a connection's log lines say which listener's
    %% carrier config applied — two listeners can now enforce different
    %% frame sizes and timeouts.
    listener :: atom(),
    ping_idle_timeout :: non_neg_integer(),
    ping_tref :: optional(reference()),
    ping_payload :: binary(),
    %% Monotonic ms timestamp of the most recent router-initiated ping,
    %% used to observe the RTT when the matching pong arrives.
    ping_sent_at :: optional(integer()),
    ping_retry :: optional(bondy_retry:t()),
    %% Monotonic seconds at websocket_init, for the socket duration
    %% observation on terminate (also the "socket_open was emitted" guard).
    start_time :: optional(integer()),
    hibernate = idle :: never | idle | always,
    protocol_state :: optional(bondy_wamp_protocol:state())
}).

-type state() :: #state{}.

%% The route's `init/2' opts, built once per listener by
%% `bondy_http_services:carrier_state/3'.
-type route_state() :: #{
    listener := atom(),
    protocols := [atom()],
    config := map()
}.

-export([init/2]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).
-export([terminate/3]).

-ifdef(TEST).
%% Exposed so the "absent `enabled' means ping off" fall-through is pinned:
%% `bondy_listener_config:assert_ping_keys/4' stopped requiring `enabled'
%% BECAUSE of it, so the two have to be tested together.
-export([maybe_enable_ping/2]).
-endif.

%% =============================================================================
%% COWBOY HANDLER CALLBACKS
%% =============================================================================

-spec init(cowboy_req:req(), route_state()) ->
    {ok | module(), cowboy_req:req(), state()}
    | {module(), cowboy_req:req(), state(), hibernate}
    | {module(), cowboy_req:req(), state(), timeout()}
    | {module(), cowboy_req:req(), state(), timeout(), hibernate}.

init(Req0, RouteState) ->
    %% This callback is called from the temporary (HTTP) request process and
    %% the websocket_ callbacks from the connection process.

    %% `RouteState' is built once per listener by
    %% `bondy_http_services:carrier_state/3', which always sets `protocols'
    %% and `config' unconditionally, so this performs no configuration
    %% lookup per connection and a missing key here means the route state was
    %% built some other way.
    %%
    %% `Protocols' is the listener's operator-chosen subprotocol families
    %% (`wamp', `bamp', ...); `Config' is this carrier's resolved option map
    %% (the per-listener override, or else the global fallback — see
    %% `bondy_listener_config:resolve_carrier_config/3').
    Protocols = maps:get(protocols, RouteState),
    Config = maps:get(config, RouteState),
    Listener = maps:get(listener, RouteState),

    %% From Cowboy's
    %% [Users Guide](http://ninenines.eu/docs/en/cowboy/1.0/guide/ws_handlers/)
    %% If the sec-websocket-protocol header was sent with the request for
    %% establishing a Websocket connection, then the Websocket handler must
    %% select one of these subprotocol and send it back to the client,
    %% otherwise the client might decide to close the connection, assuming no
    %% correct subprotocol was found.
    Subprotocols = cowboy_req:parse_header(?SUBPROTO_HEADER, Req0),

    try
        {ok, Subproto, BinProto} = select_subprotocol(Subprotocols, Protocols),

        %% If we have a token we pass it to the WAMP protocol state so that
        %% we can verify it and immediately authenticate the client using
        %% the token stored information.
        AuthToken = maybe_token(Req0),
        ProxyProtocol = bondy_http_proxy_protocol:init(Req0),

        case bondy_http_proxy_protocol:source_ip(ProxyProtocol) of
            {ok, SourceIP} ->
                %% throttle new connections per source IP (no-op unless
                %% enabled) before doing any per-connection work. The
                %% cowboy `ref` is the listener name — the listener-scope
                %% dimension.
                case
                    bondy_rate_limit:throttle(connection, SourceIP, #{
                        listener => maps:get(ref, Req0)
                    })
                of
                    throttled ->
                        ?LOG_NOTICE(#{
                            description =>
                                "WS connection rejected (rate limit)",
                            source_ip => SourceIP
                        }),
                        ThrottleReq = cowboy_req:reply(
                            ?HTTP_TOO_MANY_REQUESTS, Req0
                        ),
                        {ok, ThrottleReq, undefined};
                    ok ->
                        State0 = #state{
                            proxy_protocol = ProxyProtocol,
                            source_ip = SourceIP,
                            auth_token = AuthToken,
                            config = Config,
                            listener = Listener
                        },
                        do_init(Subproto, BinProto, Req0, State0)
                end;
            {error, Reason} ->
                throw({Reason, ProxyProtocol})
        end
    catch
        throw:{{protocol_error, Message}, PP} ->
            ?LOG_NOTICE(#{
                description =>
                    "Connection rejected. "
                    "The source IP Address couldn't be obtained "
                    "due to a proxy protocol error.",
                reason => Message,
                proxy_protocol => maps:without([error], PP)
            }),
            Req1 = cowboy_req:reply(?HTTP_FORBIDDEN, Req0),
            {ok, Req1, undefined};
        throw:invalid_scheme ->
            ?LOG_NOTICE(#{
                description => "Connection rejected.",
                reason => invalid_scheme
            }),
            Req1 = cowboy_req:reply(?HTTP_BAD_REQUEST, Req0),
            {ok, Req1, undefined};
        throw:missing_subprotocol ->
            ?LOG_NOTICE(#{
                description => "Closing WS connection",
                reason => missing_header_value,
                header => ?SUBPROTO_HEADER
            }),
            Req1 = cowboy_req:reply(?HTTP_BAD_REQUEST, Req0),
            {ok, Req1, undefined};
        throw:invalid_subprotocol ->
            %% At the moment we only support WAMP, not plain WS
            ?LOG_NOTICE(#{
                description => "Closing WS connection",
                reason => invalid_header_value,
                header => ?SUBPROTO_HEADER,
                value => Subprotocols
            }),
            Req1 = cowboy_req:reply(?HTTP_BAD_REQUEST, Req0),
            {ok, Req1, undefined};
        Class:EReason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Closing connection.",
                class => Class,
                reason => EReason,
                stacktrace => Stacktrace
            }),
            Req1 = cowboy_req:reply(?HTTP_BAD_REQUEST, Req0),
            {ok, Req1, undefined}
    end.

%% =============================================================================
%% COWBOY_WEBSOCKET CALLBACKS
%% =============================================================================

-doc """
Called once the connection has been upgraded to websockets.
Note that the `init/2` function does not run in the same process as the
Websocket callbacks. Any Websocket-specific initialization must be done in
this function.
""".
websocket_init(#state{protocol_state = undefined} = State) ->
    %% This will close the WS connection
    Frame = {
        close,
        1002,
        <<"Missing value for header 'sec-websocket-protocol'.">>
    },
    {[Frame], State};
websocket_init(#state{protocol_state = PSt} = State) ->
    %% Connection processes are the highest fan-in mailboxes on a pub/sub
    %% workload (one EVENT per subscription per publication).
    _ = erlang:process_flag(
        message_queue_data,
        bondy_config:get([wamp_connection, message_queue_data], off_heap)
    ),

    ok = logger:update_process_metadata(#{
        transport => websockets,
        protocol => wamp,
        source_ip => inet:ntoa(State#state.source_ip),
        listener => State#state.listener
    }),
    ok = bondy_wamp_protocol:update_process_metadata(PSt),

    ?LOG_INFO(#{description => "Established connection with client."}),

    ok = bondy_telemetry:socket_open(wamp, ws),
    State1 = State#state{start_time = erlang:monotonic_time(second)},

    maybe_hibernate([], reset_ping(State1), control).

-doc """
Called for every frame received from the client.
""".
websocket_handle(Data, #state{protocol_state = undefined} = State) ->
    %% At the moment we only support WAMP, so we stop immediately.
    %% TODO This should be handled by the websocket_init callback above,
    %% review and eliminate.
    ?LOG_WARNING(#{
        description => "Connection closing",
        reason => unsupported_message,
        data => Data
    }),
    {[close], State};
websocket_handle(ping, State) ->
    %% Cowboy already replies to pings for us, we return nothing
    maybe_hibernate([], reset_ping(State), control);
websocket_handle({ping, _}, State) ->
    %% Cowboy already replies to pings for us, we return nothing
    maybe_hibernate([], reset_ping(State), control);
websocket_handle(pong, State) ->
    %% https://datatracker.ietf.org/doc/html/rfc6455#page-37
    %% A Pong frame MAY be sent unsolicited.  This serves as a unidirectional
    %% heartbeat. A response to an unsolicited Pong frame is not expected.
    maybe_hibernate([], reset_ping(State), control);
websocket_handle({pong, Data}, #state{ping_payload = Data} = State0) ->
    %% We've got an answer to a Bondy-initiated ping.
    State = observe_ping_rtt(State0),
    maybe_hibernate([], reset_ping(State), control);
websocket_handle({T, Data}, #state{frame_type = T} = State0) ->
    ProtoState0 = State0#state.protocol_state,

    case bondy_wamp_protocol:handle_inbound(Data, ProtoState0) of
        {noreply, ProtoState} ->
            State = State0#state{protocol_state = ProtoState},
            maybe_hibernate([], reset_ping(State), data);
        {reply, L, ProtoState} ->
            State = State0#state{protocol_state = ProtoState},
            maybe_hibernate(data_frames(T, L), reset_ping(State), data);
        {stop, ProtoState} ->
            State = State0#state{protocol_state = ProtoState},
            {[close], disable_ping(State)};
        {stop, L, ProtoState} ->
            self() ! {stop, normal},
            State = State0#state{protocol_state = ProtoState},
            Cmds = data_frames(T, L) ++ [close],
            {Cmds, disable_ping(State)};
        {stop, Reason, L, ProtoState} ->
            self() ! {stop, Reason},
            State = State0#state{protocol_state = ProtoState},
            Cmds = data_frames(T, L) ++ [{shutdown_reason, Reason}, close],
            {Cmds, disable_ping(State)}
    end;
websocket_handle(Data, State) ->
    %% We ignore this message and carry on listening
    ?LOG_DEBUG(#{
        description => "Received unsupported message",
        data => Data
    }),
    maybe_hibernate([], State, control).

-doc """
Called for every Erlang message received.
Handles internal erlang messages and WAMP messages BONDY wants to send to the
client. See `bondy:send/2`.
""".
websocket_info({?BONDY_REQ, Pid, _RealmUri, M}, State) when
    Pid =:= self()
->
    timed_outbound(State#state.frame_type, M, State);
websocket_info({?BONDY_REQ, _Pid, _RealmUri, M}, State) ->
    %% Here we receive the messages that either the router or another peer
    %% sent to us using bondy:send/2,3
    %% ok = bondy:ack(Pid, Ref),
    timed_outbound(State#state.frame_type, M, State);
websocket_info(
    {timeout, Ref, ping_idle_timeout}, #state{ping_tref = Ref} = State
) ->
    ?LOG_DEBUG(#{
        description => "Connection timeout, sending first ping",
        attempts => bondy_retry:count(State#state.ping_retry)
    }),
    %% ping_idle_timeout (not to be confused with Cowboy WS idle_timeout)
    maybe_send_ping(State);
websocket_info({timeout, Ref, ping_timeout}, #state{ping_tref = Ref} = State) ->
    ?LOG_DEBUG(#{
        description => "Ping timeout, retrying ping",
        attempts => bondy_retry:count(State#state.ping_retry)
    }),
    %% We will retry or fail depending on retry configuration and state
    maybe_send_ping(State);
websocket_info({timeout, Ref, Msg}, State) ->
    ?LOG_DEBUG(#{
        description => "Received unknown timeout",
        message => Msg,
        ref => Ref
    }),
    maybe_hibernate([], State, control);
websocket_info({stop, Reason}, State) ->
    ?LOG_INFO(#{
        description => "Connection closing",
        reason => Reason
    }),
    {[{shutdown_reason, Reason}, close], State};
websocket_info(Msg, State) ->
    ?LOG_DEBUG(#{
        description => "Received unknown message",
        message => Msg
    }),
    maybe_hibernate([], State, control).

-doc """
Termination.
""".
%% From : http://ninenines.eu/docs/en/cowboy/2.0/guide/handlers/
%% Note that while this function may be called in a Websocket handler, it is
%% generally not useful to do any clean up as the process terminates
%% immediately after calling this callback when using Websocket.
terminate(normal, _Req, State) ->
    ?LOG_INFO(#{
        description => "Connection closed",
        reason => normal
    }),
    do_terminate(State);
terminate(stop, _Req, State) ->
    ?LOG_INFO(#{
        description => "Connection closed",
        reason => stop
    }),
    do_terminate(State);
terminate(timeout, _Req, State) ->
    %% The deadline is Cowboy's: `set_idle_timeout/2' reads `idle_timeout' from
    %% the options map `do_init/4' builds out of this same `config'. Always
    %% present — `bondy_listener_config:resolve_carrier_config/3' merges
    %% `?CARRIER_DEFAULTS' under every carrier key — so the number logged is
    %% always the one in force, and Cowboy's own default is never reached.
    Timeout = maps:get(idle_timeout, State#state.config),
    ?LOG_ERROR(#{
        description => "Connection closed",
        reason => idle_timeout,
        idle_timeout => Timeout
    }),
    do_terminate(State);
terminate(remote, _Req, State) ->
    %% The remote endpoint closed the connection without giving any further
    %% details.
    ?LOG_INFO(#{
        description => "Connection closed by client",
        reason => remote
    }),
    do_terminate(State);
terminate({remote, Code, Payload}, _Req, State) ->
    ?LOG_INFO(#{
        description => "Connection closed by client",
        reason => remote,
        code => Code,
        payload => Payload
    }),
    do_terminate(State);
terminate({error, closed = Reason}, _Req, State) ->
    %% The socket has been closed brutally without a close frame being received
    %% first.
    ?LOG_INFO(#{
        description => "Connection closed brutally",
        reason => Reason
    }),
    do_terminate(State);
terminate({error, badencoding = Reason}, _Req, State) ->
    %% A text frame was sent by the client with invalid encoding. All text
    %% frames must be valid UTF-8.
    ?LOG_ERROR(#{
        description => "Connection closed",
        reason => Reason
    }),
    do_terminate(State, true);
terminate({error, badframe = Reason}, _Req, State) ->
    %% A protocol error has been detected.
    ?LOG_ERROR(#{
        description => "Connection closed",
        reason => Reason
    }),
    do_terminate(State, true);
terminate({error, Reason}, _Req, State) ->
    ?LOG_ERROR(#{
        description => "Connection closed",
        reason => Reason
    }),
    do_terminate(State, true);
terminate({crash, Class, Reason}, _Req, State) ->
    %% A crash occurred in the handler.
    ?LOG_ERROR(#{
        description => "Connection closed. A crash occurred in the handler.",
        class => Class,
        reason => Reason
    }),
    do_terminate(State, true);
terminate(Other, _Req, State) ->
    ?LOG_ERROR(#{
        description => "Connection closed",
        reason => Other
    }),
    do_terminate(State, true).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Wraps `handle_outbound/3` so egress is observable: mailbox depth at
%% dequeue plus the in-process handling time. This is the last hop before
%% the wire, and it was the only unmeasured segment of the delivery path
%% (`match`/`fanout` cover the publisher, `router_flow_ingress/3` covers
%% relay ingress).
%%
%% Depth, not a queue wait: a router delivery arrives as a plain `!` into
%% this mailbox with no dispatch timestamp, the same situation relay ingress
%% is in. Reading own message_queue_len takes no lock.
%%
%% The service time is the ENCODE only — cowboy writes the socket after this
%% callback returns, so the send is not in scope here (see
%% `bondy_telemetry:wamp_egress/3`). Emitted in an `after` so a failing
%% encode is measured too.
timed_outbound(T, M, State) ->
    {message_queue_len, Depth} = erlang:process_info(self(), message_queue_len),
    Started = erlang:monotonic_time(microsecond),

    try
        handle_outbound(T, M, State)
    after
        ok = bondy_telemetry:wamp_egress(
            websocket, erlang:monotonic_time(microsecond) - Started, Depth
        )
    end.

%% @private
handle_outbound(T, M, State) ->
    case bondy_wamp_protocol:handle_outbound(M, State#state.protocol_state) of
        {ok, Bin, PSt} ->
            %% Bin is ONE message as iodata — do not pass it to
            %% data_frames/2, which maps over a list of messages.
            maybe_hibernate(
                [{T, Bin}], State#state{protocol_state = PSt}, data
            );
        {stop, PSt} ->
            {[close], State#state{protocol_state = PSt}};
        {stop, Bin, PSt} ->
            Cmds = data_frames(T, [Bin]) ++ [close],
            {Cmds, State#state{protocol_state = PSt}};
        {stop, Bin, PSt, Time} when is_integer(Time), Time > 0 ->
            %% We schedule the stop (this is to allow the client to reply a
            %% WAMP Goodbye).
            erlang:send_after(Time, self(), {stop, normal}),
            {data_frames(T, [Bin]), State#state{protocol_state = PSt}}
    end.

%% @private
maybe_token(Req) ->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        undefined ->
            undefined;
        {bearer, Token} ->
            Token;
        _ ->
            throw(invalid_scheme)
    end.

%% @private
do_init({ws, FrameType, _Enc} = Subproto, BinProto, Req0, State0) ->
    Peer = bondy_http_utils:peer(Req0),
    SourceIP = State0#state.source_ip,
    AuthToken = State0#state.auth_token,
    ProtoOpts = #{
        auth_token => AuthToken,
        source_ip => SourceIP,
        listener => State0#state.listener
    },

    ok = logger:update_process_metadata(#{
        transport => websockets,
        protocol => wamp,
        source_ip => SourceIP,
        listener => State0#state.listener
    }),

    case bondy_wamp_protocol:init(Subproto, Peer, ProtoOpts) of
        {ok, CBState} ->
            %% This works only on HTTP1, we will change this for a stratgy
            %% based on {active, boolean()} and bondy_regulator.
            Opts0 = maps:put(active_n, 1, State0#state.config),
            %% Both read with no default: a resolved `websocket' carrier
            %% config carries every key of
            %% `bondy_listener_config:?CARRIER_DEFAULTS', `ping' and
            %% `hibernate' included, whatever the operator wrote. A default
            %% here would be a second, divergent statement of what they are
            %% worth — which is how this handler and the schema came to
            %% disagree about `ping.enabled' and `idle_timeout' before.
            PingOpts = maps:get(ping, Opts0),
            Opts1 = maps:remove(ping, Opts0),
            %% Ours, not Cowboy's: see maybe_hibernate/3.
            Hibernate = maps:get(hibernate, Opts1),
            Opts = maps:remove(hibernate, Opts1),

            State1 = State0#state{
                frame_type = FrameType,
                hibernate = Hibernate,
                protocol_state = CBState
            },

            State = maybe_enable_ping(PingOpts, State1),

            Req = cowboy_req:set_resp_header(?SUBPROTO_HEADER, BinProto, Req0),

            %% We upgrade the HTTP connection to Websockets. `Opts` is this
            %% listener's resolved `websocket' carrier config — the
            %% per-listener `listeners.$name.websocket.*` override where set,
            %% the global `wamp.websocket.*` block otherwise — and includes:
            %% - idle_timeout
            %% - max_frame_size
            %% - compress
            %% - deflate_opts
            {cowboy_websocket, Req, State, Opts};
        {error, _Reason} ->
            %% Returning ok will cause the handler to stop in websocket_handle
            Req = cowboy_req:reply(?HTTP_BAD_REQUEST, Req0),
            {ok, Req, undefined}
    end.

%% @private
-doc """
The order of `Offered` is undefined.

`Allowed` restricts the subprotocol FAMILY (`wamp`, `bamp`, ...), not the
validated subprotocol itself: a family a client offers and this build
supports is not necessarily one the listener it connected to carries, since
the operator chooses per listener which families it serves.
""".
-spec select_subprotocol(list(binary()) | undefined, [atom()]) ->
    {ok, bondy_wamp_protocol:subprotocol(), binary()}
    | no_return().

select_subprotocol(undefined, _Allowed) ->
    throw(missing_subprotocol);
select_subprotocol(L, Allowed) when is_list(L) ->
    %% Filtered by family BEFORE validation: `bondy_wamp_protocol:subprotocol/1'
    %% maps each `?WAMP2_*' id to a `{Transport, Framing, Encoding}' tuple —
    %% `<<"wamp.2.json">>' becomes `{ws, text, json}' — discarding the family,
    %% which therefore survives only in the id's own prefix and cannot be
    %% recovered after validation.
    Offered = [X || X <- L, lists:member(protocol_family(X), Allowed)],
    case Offered of
        [] -> throw(invalid_subprotocol);
        _ -> select_valid(Offered)
    end.

%% @private
select_valid([]) ->
    throw(invalid_subprotocol);
select_valid([X | T]) ->
    case bondy_wamp_protocol:validate_subprotocol(X) of
        {ok, SP} -> {ok, SP, X};
        {error, invalid_subprotocol} -> select_valid(T)
    end.

%% @private
%% The subprotocol id's prefix is the only place the protocol family
%% survives: see `select_subprotocol/2'.
%%
%% An unrecognised prefix answers `'$unknown'' rather than `undefined'. Both are
%% rejected today, but for different reasons: `undefined' is rejected only
%% because `bondy_listener_config:add_protocol/2' happens to drop it from a
%% carrier's protocol set, so `Allowed' never contains it. `'$unknown'' cannot be
%% a member of `Allowed' whatever that function does, since every family there
%% comes from a `service_spec/1' row and no valid protocol atom is spelled this
%% way. The filter in `select_subprotocol/2' is then closed by construction
%% rather than by an invariant held in another module.
protocol_family(<<"wamp.", _/binary>>) -> wamp;
protocol_family(<<"bamp.", _/binary>>) -> bamp;
protocol_family(_) -> '$unknown'.

%% @private
do_terminate(State) ->
    do_terminate(State, false).

%% @private
%% Emits the socket metrics ([bondy, socket, closed] with the connection
%% duration, plus [bondy, socket, error] for error-class terminations)
%% iff websocket_init ran (start_time set), mirroring the raw-socket
%% handler's contract.
do_terminate(undefined, _) ->
    ok;
do_terminate(State, IsError) ->
    case State#state.start_time of
        StartTime when is_integer(StartTime) ->
            Seconds = erlang:monotonic_time(second) - StartTime,
            ok = bondy_telemetry:socket_closed(wamp, ws, Seconds),
            case IsError of
                true -> ok = bondy_telemetry:socket_error(wamp, ws);
                false -> ok
            end;
        undefined ->
            ok
    end,
    ok = cancel_timer(State#state.ping_tref),
    bondy_wamp_protocol:terminate(State#state.protocol_state).

%% @private
%% A hibernate return forces a full-sweep GC + heap shrink, so data-path
%% callbacks (inbound frames, outbound router messages) only pay it under
%% the `always` strategy; control-path callbacks (pings, timeouts, init)
%% also hibernate under `idle`, shrinking quiet connections without a GC
%% per routed message.
maybe_hibernate(Cmds, #state{hibernate = always} = State, _) ->
    {Cmds, State, hibernate};
maybe_hibernate(Cmds, #state{hibernate = never} = State, _) ->
    {Cmds, State};
maybe_hibernate(Cmds, State, data) ->
    {Cmds, State};
maybe_hibernate(Cmds, State, control) ->
    {Cmds, State, hibernate}.

%% @private
-doc """
From `cow_ws:frame()`.

```erlang
-type frame() :: close | ping | pong
	| {text | binary | close | ping | pong, iodata()}
	| {close, close_code(), iodata()}
	| {fragment, fin | nofin, text | binary | continuation, iodata()}.
```

`L` must be a proper list of encoded messages (each one iodata, one
frame each) — a bare iodata message would be misread as several.
""".
data_frames(Type, L) when is_list(L) ->
    [{Type, E} || E <- L].

%% =============================================================================
%% PRIVATE: PING TIMEOUT
%% =============================================================================

%% @private
maybe_enable_ping(#{enabled := true} = PingOpts, State) ->
    IdleTimeout = maps:get(idle_timeout, PingOpts),
    Timeout = maps:get(timeout, PingOpts),
    Attempts = maps:get(max_attempts, PingOpts),

    Retry = bondy_retry:init(
        ping_timeout,
        #{
            % disable, use max_retries only
            deadline => 0,
            interval => Timeout,
            max_retries => Attempts,
            backoff_enabled => false
        }
    ),

    State#state{
        ping_idle_timeout = IdleTimeout,
        ping_payload = bondy_utils:generate_fragment(16),
        ping_retry = Retry
    };
maybe_enable_ping(#{enabled := false}, State) ->
    State;
maybe_enable_ping(#{enabled := Invalid}, _State) ->
    error({invalid_ping_enabled, Invalid});
%% Same three cases, and the same reasoning, as
%% `bondy_wamp_tcp_connection_handler:maybe_enable_ping/2'. A carrier makes the
%% absent case reachable in one more way than a listener does: every `ping.*'
%% path resolves INDEPENDENTLY, so `ping.idle_timeout' can come from the listener
%% while `ping.enabled' is set nowhere, leaving a `ping' map with no `enabled'.
maybe_enable_ping(_PingOpts, State) ->
    State.

%% @private
reset_ping(#state{ping_retry = undefined} = State) ->
    %% ping disabled
    State;
reset_ping(#state{ping_tref = undefined} = State) ->
    Time = State#state.ping_idle_timeout,
    Ref = erlang:start_timer(Time, self(), ping_idle_timeout),

    State#state{ping_tref = Ref};
reset_ping(#state{} = State) ->
    ok = cancel_timer(State#state.ping_tref),

    %% Reset retry state
    {_, Retry} = bondy_retry:succeed(State#state.ping_retry),

    Time = State#state.ping_idle_timeout,
    Ref = erlang:start_timer(Time, self(), ping_idle_timeout),

    State#state{
        ping_retry = Retry,
        ping_tref = Ref
    }.

%% @private
%% Observes the ping round-trip time when a pong answers a
%% router-initiated ping. Retries resend the same payload, so the RTT is
%% measured from the most recent send.
observe_ping_rtt(#state{ping_sent_at = SentAt} = State) when
    is_integer(SentAt)
->
    Rtt = erlang:monotonic_time(millisecond) - SentAt,
    ok = bondy_telemetry:ping_rtt(wamp, ws, Rtt),
    State#state{ping_sent_at = undefined};
observe_ping_rtt(State) ->
    State.

%% @private
disable_ping(#state{ping_retry = undefined} = State) ->
    State;
disable_ping(#state{} = State) ->
    ok = cancel_timer(State#state.ping_tref),
    State#state{ping_retry = undefined}.

%% @private
cancel_timer(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok;
cancel_timer(_) ->
    ok.

%% @private
maybe_send_ping(#state{ping_idle_timeout = undefined} = State) ->
    %% ping disabled
    {[], State};
maybe_send_ping(#state{} = State) ->
    {Result, Retry} = bondy_retry:fail(State#state.ping_retry),
    maybe_send_ping(Result, State#state{ping_retry = Retry}).

%% @private
maybe_send_ping(Limit, State) when
    Limit == deadline orelse Limit == max_retries
->
    ?LOG_INFO(#{
        description => "Connection closing.",
        reason => ping_timeout
    }),
    {[close], State};
maybe_send_ping(_Time, #state{} = State0) ->
    %% We schedule the next retry
    Ref = bondy_retry:fire(State0#state.ping_retry),
    State = State0#state{
        ping_tref = Ref,
        ping_sent_at = erlang:monotonic_time(millisecond)
    },

    %% https://datatracker.ietf.org/doc/html/rfc6455#page-37
    %% If an endpoint receives a Ping frame and has not yet sent Pong
    %% frame(s) in response to previous Ping frame(s), the endpoint MAY
    %% elect to send a Pong frame for only the most recently processed Ping
    %% frame.
    %% For that reason the payload is static.
    Msg = {ping, State#state.ping_payload},
    {[Msg], State}.
