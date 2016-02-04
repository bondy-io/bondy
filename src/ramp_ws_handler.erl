%% -----------------------------------------------------------------------------
%% @doc
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
%% (UTF8 encoded payload) and use the JSON message serialization.
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
-module(ramp_ws_handler).
-include ("ramp.hrl").

%% Cowboy will automatically close the Websocket connection when no data
%% arrives on the socket after ?TIMEOUT
-define(TIMEOUT, 60000*10).

-type state()       ::  #{
    context => ramp_router:context(),
    data => binary(),
    subprotocol => subprotocol()
}.

-export([init/2]).
-export([websocket_handle/3]).
-export([websocket_info/3]).
-export([terminate/3]).



%% =============================================================================
%% COWBOY HANDLER CALLBACKS
%% =============================================================================



init(Req, Opts) ->
    %% From [Cowboy's Users Guide](http://ninenines.eu/docs/en/cowboy/1.0/guide/ws_handlers/)
    %% If the sec-websocket-protocol header was sent with the request for
    %% establishing a Websocket connection, then the Websocket handler must
    %% select one of these subprotocol and send it back to the client,
    %% otherwise the client might decide to close the connection, assuming no
    %% correct subprotocol was found.
    case cowboy_req:parse_header(<<"sec-websocket-protocol">>, Req) of
        undefined ->
            %% Plain websockets
            %% {ok, Req1, St, ?TIMEOUT};
            %% At the moment we only support wamp, not plain ws, so we stop.
            error_logger:error_report([
                {error,
                    {missing_value_for_header, <<"sec-websocket-protocol">>}}
            ]),
            {ok, Req, Opts};
        Subprotocols ->
            St = #{
                context => ramp_context:new(),
                subprotocol => undefined,
                data => <<>>
            },
            %% The client provided subprotocol options
            subprotocol_init(select_subprotocol(Subprotocols), Req, St)
    end.



%% =============================================================================
%% COWBOY_WEBSOCKET CALLBACKS
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% Handles frames sent by client
%% @end
%% -----------------------------------------------------------------------------
websocket_handle(Msg, Req, #{subprotocol := undefined} = St) ->
    %% At the moment we only support wamp, so we stop.
    error_logger:error_report([
        {error, {unsupported_message, Msg}},
        {state, St},
        {stacktrace, erlang:get_stacktrace()}
    ]),
    {stop, Req, St};

websocket_handle({T, Data}, Req, #{subprotocol := #{frame_type := T}} = St) ->
    handle_wamp_data(Data, Req, St);

websocket_handle({ping, _Msg}, Req, St) ->
    %% Cowboy already handled ping
    %% We ignore this message and carry on listening
    {ok, Req, St};

websocket_handle({pong, _Msg}, Req, St) ->
    %% We ignore this message and carry on listening
    {ok, Req, St};

websocket_handle(Data, Req, St) ->
    error_logger:error_report([
        {error, {unsupported_message, Data}},
        {state, St},
        {stacktrace, erlang:get_stacktrace()}
    ]),
    %% We ignore this message and carry on listening
    {ok, Req, St}.


%% -----------------------------------------------------------------------------
%% @doc
%% Handles internal erlang messages
%% @end
%% -----------------------------------------------------------------------------
websocket_info({timeout, _Ref, _Msg}, Req, St) ->
    %% erlang:start_timer(1000, self(), <<"How' you doin'?">>),
    %% reply(text, Msg, Req, St);
    {ok, Req, St};

websocket_info({stop, Reason}, Req, St) ->
    error_logger:error_report([
        {description, <<"WAMP session shutdown">>},
        {reason, Reason}
    ]),
    {shutdown, Req, St};

websocket_info(#event{} = M, Req, St) ->
    #{subprotocol := #{encoding := E, frame_type := T}} = St,
    %% We send the event to the client
    {reply, frame(T, ramp_encoding:encode(M, E)), Req, St};


websocket_info(_Info, Req, St) ->
    {ok, Req, St}.


%% -----------------------------------------------------------------------------
%% @doc
%% Termination
%% @end
%% -----------------------------------------------------------------------------
terminate(normal, _Req, St) ->
    maybe_close_session(St);
terminate(stop, _Req, St) ->
    maybe_close_session(St);
terminate(timeout, _Req, St) ->
    maybe_close_session(St);
terminate(remote, _Req, St) ->
    maybe_close_session(St);
terminate({error, closed}, _Req, St) ->
    maybe_close_session(St);
terminate({error, badencoding}, _Req, St) ->
    maybe_close_session(St);
terminate({error, badframe}, _Req, St) ->
    maybe_close_session(St);
terminate({error, _Other}, _Req, St) ->
    maybe_close_session(St);
terminate({crash, error, Reason}, _Req, St) ->
    error_logger:error_report([
        {reason, Reason},
        {stacktrace, erlang:get_stacktrace()}
    ]),
    maybe_close_session(St);
terminate({crash, exit, _Other}, _Req, St) ->
    maybe_close_session(St);
terminate({crash, throw, _Other}, _Req, St) ->
    maybe_close_session(St);
terminate({remote, _Code, _Binary}, _Req, St) ->
    maybe_close_session(St).


%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
-spec subprotocol_init(
    undefined | subprotocol(), cowboy_req:req(), state()) ->
    {ok | module(), cowboy_req:req(), state()}
    | {module(), cowboy_req:req(), state(), hibernate}
    | {module(), cowboy_req:req(), state(), timeout()}
    | {module(), cowboy_req:req(), state(), timeout(), hibernate}.
subprotocol_init(undefined, Req0, St) ->
    %% No valid subprotocol found in sec-websocket-protocol header, so we stop
    {ok, Req0, St};

subprotocol_init(Subprotocol, Req0, St0) when is_map(Subprotocol) ->
    #{id := SubprotocolId} = Subprotocol,

    Req1 = cowboy_req:set_resp_header(
        ?WS_SUBPROTOCOL_HEADER_NAME, SubprotocolId, Req0),

    St1 = St0#{
        data => <<>>,
        subprotocol => Subprotocol
    },
    {cowboy_websocket, Req1, St1, ?TIMEOUT}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% The priority is determined by the order of the header contents
%% i.e. determined by the client
%% @end
%% -----------------------------------------------------------------------------
-spec select_subprotocol(list(binary())) -> map() | not_found.
select_subprotocol([]) ->
    undefined;
select_subprotocol([?WAMP2_JSON | _T]) ->
    #{
        frame_type => text,
        encoding => json,
        id => ?WAMP2_JSON
    };
select_subprotocol([?WAMP2_MSGPACK | _T]) ->
    #{
        frame_type => binary,
        encoding => msgpack,
        id => ?WAMP2_MSGPACK
    };
select_subprotocol([?WAMP2_JSON_BATCHED | _T]) ->
    #{
        frame_type => text,
        encoding => json_batched,
        id => ?WAMP2_JSON_BATCHED
    };

select_subprotocol([?WAMP2_MSGPACK_BATCHED | _T]) ->
    #{
        frame_type => binary,
        encoding => msgpack_batched,
        id => ?WAMP2_MSGPACK_BATCHED
    }.


%% @private
reply(FrameType, Frames, Req, St) ->
    case should_hibernate(St) of
        true ->
            {reply, frame(FrameType, Frames), Req, St, hibernate};
        false ->
            {reply, frame(FrameType, Frames), Req, St}
    end.

%% @private
frame(Type, L) when is_list(L) ->
    [frame(Type, E) || E <- L];
frame(Type, E) when Type == text orelse Type == binary ->
    {Type, E}.


%% @private
should_hibernate(_St) ->
    %% @TODO define condition
    false.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Handles wamp frames, decoding 1 or more messages, routing them and replying
%% the client when required.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_wamp_data(binary(), cowboy_req:req(), state()) ->
    {ok, cowboy_req:req(), state()}
    | {ok, cowboy_req:req(), state(), hibernate}
    | {reply, cowboy_websocket:frame() | [cowboy_websocket:frame()], cowboy_req:req(), state()}
    | {reply, cowboy_websocket:frame() | [cowboy_websocket:frame()], cowboy_req:req(), state(), hibernate}
    | {shutdown, cowboy_req:req(), state()}.
handle_wamp_data(Data1, Req, St0) ->
    #{
        subprotocol := #{frame_type := T, encoding := E},
        data := Data0,
        context := Ctxt0
    } = St0,

    Data2 = <<Data0/binary, Data1/binary>>,
    {Messages, Data3} = ramp_encoding:decode(Data2, T, E),
    St1 = St0#{data => Data3},

    case handle_wamp_messages(Messages, Req, Ctxt0) of
        {ok, Ctxt1} ->
            {ok, Req, St1#{context => Ctxt1}};
        {stop, Ctxt1} ->
            {shutdown, Req, St1#{context => Ctxt1}};
        {reply, Replies, Ctxt1} ->
            ReplyFrames = [ramp_encoding:encode(R, E) || R <- Replies],
            reply(T, ReplyFrames, Req, St1#{context => Ctxt1});
        {stop, Replies, Ctxt1} ->
            self() ! {stop, <<"Router dropped session.">>},
            ReplyFrames = [ramp_encoding:encode(R, E) || R <- Replies],
            reply(T, ReplyFrames, Req, St1#{context => Ctxt1})
    end.


%% @private
handle_wamp_messages(Ms, Req, Ctxt) ->
    handle_wamp_messages(Ms, Req, Ctxt, [], false).


%% @private
handle_wamp_messages([], _Req, Ctxt, [], true) ->
    {stop, Ctxt};
handle_wamp_messages([], _Req, Ctxt, [], false) ->
    {ok, Ctxt};
handle_wamp_messages([], _Req, Ctxt, Acc, true) ->
    {stop, lists:reverse(Acc), Ctxt};
handle_wamp_messages([], _Req, Ctxt, Acc, false) ->
    {reply, lists:reverse(Acc), Ctxt};
handle_wamp_messages([H|T], Req, Ctxt0, Acc, StopFlag) ->
    case ramp_router:handle_message(H, Ctxt0) of
        {ok, Ctxt1} ->
            handle_wamp_messages(T, Req, Ctxt1, Acc, StopFlag);
        {stop, Ctxt1} ->
            handle_wamp_messages(T, Req, Ctxt1, Acc, true);
        {stop, Reply, Ctxt1} ->
            handle_wamp_messages(T, Req, Ctxt1, [Reply | Acc], true);
        {reply, Reply, Ctxt1} ->
            handle_wamp_messages(T, Req, Ctxt1, [Reply | Acc], StopFlag)
    end.

maybe_close_session(St) ->
    case session_id(St) of
        undefined ->
            ok;
        SessionId ->
            #{context := Ctxt} = St,
            ramp_broker:unsubscribe_all(Ctxt),
            ramp_dealer:unregister_all(Ctxt),
            ramp_session:close(SessionId)
    end.

%% =============================================================================
%% PRIVATE STATE ACCESSORS
%% =============================================================================



%% @private
session_id(#{context := #{session_id := SessionId}}) ->
    SessionId;
session_id(_) ->
    undefined.
