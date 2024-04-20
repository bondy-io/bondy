%% =============================================================================
%%  bondy_wamp_ws_connection_handler.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc A Cowboy WS handler.
%%
%% Each WAMP message is transmitted as a separate WebSocket message
%% (not WebSocket frame)
%%
%% The WAMP protocol MUST BE negotiated during the WebSocket opening
%% handshake between Peers using the WebSocket subprotocol negotiation
%% mechanism.
%%
%% WAMP uses the following WebSocket subprotocol identifiers for
%% unbatched modes:
%%
%% *  "wamp.2.json"
%% *  "wamp.2.msgpack"
%%
%% With "wamp.2.json", _all_ WebSocket messages MUST BE of type *text*
%% (UTF8 encoded) and use the JSON message serialization.
%%
%% With "wamp.2.msgpack", _all_ WebSocket messages MUST BE of type
%% *binary* and use the MsgPack message serialization.
%%
%% To avoid incompatibilities merely due to naming conflicts with
%% WebSocket subprotocol identifiers, implementers SHOULD register
%% identifiers for additional serialization formats with the official
%% WebSocket subprotocol registry.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_wamp_ws_connection_handler).
-include_lib("wamp/include/wamp.hrl").
-include("http_api.hrl").
-include("bondy.hrl").

%% Cowboy will automatically close the Websocket connection when no data
%% arrives on the socket after ?IDLE_TIMEOUT
-define(IDLE_TIMEOUT, 60000*10).
-define(SUBPROTO_HEADER, <<"sec-websocket-protocol">>).


-record(state, {
    frame_type              ::  bondy_wamp_protocol:frame_type(),
    auth_token              ::  map() | undefined,
    proxy_protocol          ::  bondy_http_proxy_protocol:t(),
    source_ip               ::  inet:ip_address(),
    ping_idle_timeout       ::  non_neg_integer(),
    ping_tref               ::  optional(reference()),
    ping_payload            ::  binary(),
    ping_retry              ::  optional(bondy_retry:t()),
    hibernate = false       ::  boolean(),
    protocol_state          ::  optional(bondy_wamp_protocol:state())
}).

-type state()               ::  #state{}.



-export([init/2]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).
-export([terminate/3]).



%% =============================================================================
%% COWBOY HANDLER CALLBACKS
%% =============================================================================

-spec init(cowboy_req:req(), state()) ->
    {ok | module(), cowboy_req:req(), state()}
    | {module(), cowboy_req:req(), state(), hibernate}
    | {module(), cowboy_req:req(), state(), timeout()}
    | {module(), cowboy_req:req(), state(), timeout(), hibernate}.

init(Req0, _) ->
    %% This callback is called from the temporary (HTTP) request process and
    %% the websocket_ callbacks from the connection process.

    %% From Cowboy's
    %% [Users Guide](http://ninenines.eu/docs/en/cowboy/1.0/guide/ws_handlers/)
    %% If the sec-websocket-protocol header was sent with the request for
    %% establishing a Websocket connection, then the Websocket handler must
    %% select one of these subprotocol and send it back to the client,
    %% otherwise the client might decide to close the connection, assuming no
    %% correct subprotocol was found.
    Subprotocols = cowboy_req:parse_header(?SUBPROTO_HEADER, Req0),

    try
        {ok, Subproto, BinProto} = select_subprotocol(Subprotocols),

        %% If we have a token we pass it to the WAMP protocol state so that
        %% we can verify it and immediately authenticate the client using
        %% the token stored information.
        AuthToken = maybe_token(Req0),
        ProxyProtocol = bondy_http_proxy_protocol:init(Req0),

        case bondy_http_proxy_protocol:source_ip(ProxyProtocol) of
            {ok, SourceIP} ->
                State0 = #state{
                    proxy_protocol = ProxyProtocol,
                    source_ip = SourceIP,
                    auth_token = AuthToken
                },

                do_init(Subproto, BinProto, Req0, State0);
            {error, Reason} ->
                throw({Reason, ProxyProtocol})
        end

    catch
        throw:{{protocol_error, Message}, PP} ->
            ?LOG_INFO(#{
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
            %% Returning ok will cause the handler
            %% to stop in websocket_handle
            Req1 = cowboy_req:reply(?HTTP_BAD_REQUEST, Req0),
            {ok, Req1, undefined};

        throw:missing_subprotocol ->
            ?LOG_INFO(#{
                description => "Closing WS connection",
                reason => missing_header_value,
                header => ?SUBPROTO_HEADER
            }),
            %% Returning ok will cause the handler
            %% to stop in websocket_handle
            Req1 = cowboy_req:reply(?HTTP_BAD_REQUEST, Req0),
            {ok, Req1, undefined};

        throw:invalid_subprotocol ->
            %% At the moment we only support WAMP, not plain WS
            ?LOG_INFO(#{
                description => "Closing WS connection",
                reason => invalid_header_value,
                header => ?SUBPROTO_HEADER,
                value => Subprotocols
            }),
            %% Returning ok will cause the handler
            %% to stop in websocket_handle
            Req1 = cowboy_req:reply(?HTTP_BAD_REQUEST, Req0),
            {ok, Req1, undefined};

        throw:_Reason ->
            %% Returning ok will cause the handler
            %% to stop in websocket_handle
            Req1 = cowboy_req:reply(?HTTP_BAD_REQUEST, Req0),
            {ok, Req1, undefined}
    end.



%% =============================================================================
%% COWBOY_WEBSOCKET CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Called once the connection has been upgraded to websockets.
%% Note that the init/2 function does not run in the same process as the
%% Websocket callbacks. Any Websocket-specific initialization must be done in
%% this function.
%% @end
%% -----------------------------------------------------------------------------
websocket_init(#state{protocol_state = undefined} = State) ->
    %% This will close the WS connection
    Frame = {
        close,
        1002,
        <<"Missing value for header 'sec-websocket-protocol'.">>
    },
    {[Frame], State};

websocket_init(#state{protocol_state = PSt} = State) ->
    ok = logger:update_process_metadata(#{
        transport => websockets,
        protocol => wamp,
        source_ip => inet:ntoa(State#state.source_ip)
    }),
    ok = bondy_wamp_protocol:update_process_metadata(PSt),

    ?LOG_INFO(#{description => "Established connection with client."}),

    {[], reset_ping(State)}.


%% -----------------------------------------------------------------------------
%% @doc Called for every frame received from the client
%% @end
%% -----------------------------------------------------------------------------
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
    {[], reset_ping(State)};

websocket_handle({ping, _}, State) ->
    %% Cowboy already replies to pings for us, we return nothing
    {[], reset_ping(State)};

websocket_handle(pong, State) ->
    %% https://datatracker.ietf.org/doc/html/rfc6455#page-37
    %% A Pong frame MAY be sent unsolicited.  This serves as a unidirectional
    %% heartbeat. A response to an unsolicited Pong frame is not expected.
    {[], reset_ping(State)};

websocket_handle({pong, Data}, #state{ping_payload = Data} = State) ->
    %% We've got an answer to a Bondy-initiated ping.
    {[], reset_ping(State)};

websocket_handle({T, Data}, #state{frame_type = T} = State0) ->
    ProtoState0 = State0#state.protocol_state,

    case bondy_wamp_protocol:handle_inbound(Data, ProtoState0) of
        {ok, ProtoState} ->
            State = State0#state{protocol_state = ProtoState},
            {[], reset_ping(State)};

        {reply, L, ProtoState} ->
            State = State0#state{protocol_state = ProtoState},
            {data_frames(T, L), reset_ping(State)};

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
    {[], State}.


%% -----------------------------------------------------------------------------
%% @doc Called for every Erlang message received.
%% Handles internal erlang messages and WAMP messages BONDY wants to send to the
%% client. See {@link bondy:send/2}.
%% @end
%% -----------------------------------------------------------------------------
websocket_info({?BONDY_REQ, Pid, _RealmUri, M}, State)
when Pid =:= self() ->
    handle_outbound(State#state.frame_type, M, State);

websocket_info({?BONDY_REQ, _Pid, _RealmUri, M}, State) ->
    %% Here we receive the messages that either the router or another peer
    %% sent to us using bondy:send/2,3
    %% ok = bondy:ack(Pid, Ref),
    handle_outbound(State#state.frame_type, M, State);

websocket_info(
    {timeout, Ref, ping_idle_timeout}, #state{ping_tref = Ref} = State) ->
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
    {[], State};

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
    {[], State}.


%% -----------------------------------------------------------------------------
%% @doc
%% Termination
%% @end
%% -----------------------------------------------------------------------------
%% From : http://ninenines.eu/docs/en/cowboy/2.0/guide/handlers/
%% Note that while this function may be called in a Websocket handler, it is
%% generally not useful to do any clean up as the process terminates
%% immediately after calling this callback when using Websocket.
terminate(normal, _Req, State) ->
    do_terminate(State);

terminate(stop, _Req, State) ->
    do_terminate(State);

terminate(timeout, _Req, State) ->
    Timeout = bondy_config:get([wamp_websocket, idle_timeout]),
    ?LOG_ERROR(#{
        description => "Connection closing",
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
    do_terminate(State);

terminate({error, badframe = Reason}, _Req, State) ->
    %% A protocol error has been detected.
    ?LOG_ERROR(#{
        description => "Connection closed",
        reason => Reason
    }),
    do_terminate(State);

terminate({error, Reason}, _Req, State) ->
    ?LOG_ERROR(#{
        description => "Connection closed",
        reason => Reason
    }),
    do_terminate(State);

terminate({crash, Class, Reason}, _Req, State) ->
    %% A crash occurred in the handler.
    ?LOG_ERROR(#{
        description => "A crash occurred in the handler.",
        class => Class,
        reason => Reason
    }),
    do_terminate(State);

terminate(Other, _Req, State) ->
    ?LOG_ERROR(#{
        description => "Process crashed",
        reason => Other
    }),
    do_terminate(State).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
handle_outbound(T, M, State) ->
    case bondy_wamp_protocol:handle_outbound(M, State#state.protocol_state) of
        {ok, Bin, PSt} ->
            {data_frames(T, Bin), State#state{protocol_state = PSt}};

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
    Peer = cowboy_req:peer(Req0),
    SourceIP = State0#state.source_ip,
    AuthToken = State0#state.auth_token,
    ProtoOpts = #{auth_token => AuthToken, source_ip => SourceIP},

    ok = logger:update_process_metadata(#{
        transport => websockets,
        protocol => wamp,
        source_ip => SourceIP
    }),

    case bondy_wamp_protocol:init(Subproto, Peer, ProtoOpts) of
        {ok, CBState} ->
            Opts0 = maps_utils:from_property_list(
                bondy_config:get(wamp_websocket)
            ),
            {PingOpts, Opts} = maps:take(ping, Opts0),

            State1 = State0#state{
                frame_type = FrameType,
                protocol_state = CBState
            },

            State = maybe_enable_ping(PingOpts, State1),

            Req = cowboy_req:set_resp_header(?SUBPROTO_HEADER, BinProto, Req0),

            %% We upgrade the HTTP connection to Websockets
            %% We pass the wamp.websocket.* opts
            %% (defined via bondy.conf) which include:
            %% - idle_timeout
            %% - max_frame_size
            %% - compress
            %% - deplate_opts
            {cowboy_websocket, Req, State, Opts};

        {error, _Reason} ->
            %% Returning ok will cause the handler to stop in websocket_handle
            Req = cowboy_req:reply(?HTTP_BAD_REQUEST, Req0),
            {ok, Req, undefined}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% The order is undefined
%% @end
%% -----------------------------------------------------------------------------
-spec select_subprotocol(list(binary()) | undefined) ->
    {ok, bondy_wamp_protocol:subprotocol(), binary()}
    | no_return().

select_subprotocol(undefined) ->
    throw(missing_subprotocol);

select_subprotocol(L) when is_list(L) ->
    try
        Fun = fun(X) ->
            case bondy_wamp_protocol:validate_subprotocol(X) of
                {ok, SP} ->
                    throw({break, SP, X});
                {error, invalid_subprotocol} ->
                    ok
            end
        end,
        ok = lists:foreach(Fun, L),
        throw(invalid_subprotocol)
    catch
        throw:{break, SP, X} ->
            {ok, SP, X}
    end.


%% @private
do_terminate(undefined) ->
    ok;

do_terminate(State) ->
    ok = cancel_timer(State#state.ping_tref),
    bondy_wamp_protocol:terminate(State#state.protocol_state).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% From cow_ws:frame().
%% -type frame() :: close | ping | pong
%% 	| {text | binary | close | ping | pong, iodata()}
%% 	| {close, close_code(), iodata()}
%% 	| {fragment, fin | nofin, text | binary | continuation, iodata()}.
%% @end
%% -----------------------------------------------------------------------------
data_frames(Type, L) when is_list(L) ->
    [{Type, E} || E <- L];

data_frames(Type, E) ->
    [{Type, E}].



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
            deadline => 0, % disable, use max_retries only
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
maybe_send_ping(Limit, State)
when Limit == deadline orelse Limit == max_retries ->
    ?LOG_INFO(#{
        description => "Connection closing.",
        reason => ping_timeout
    }),
    {[close], State};

maybe_send_ping(_Time, #state{} = State0) ->
    %% We schedule the next retry
    Ref = bondy_retry:fire(State0#state.ping_retry),
    State = State0#state{ping_tref = Ref},

    %% https://datatracker.ietf.org/doc/html/rfc6455#page-37
    %% If an endpoint receives a Ping frame and has not yet sent Pong
    %% frame(s) in response to previous Ping frame(s), the endpoint MAY
    %% elect to send a Pong frame for only the most recently processed Ping
    %% frame.
    %% For that reason the payload is static.
    Msg = {ping, State#state.ping_payload},
    {[Msg], State}.

