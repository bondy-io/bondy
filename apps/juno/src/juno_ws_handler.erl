%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
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
%% =============================================================================
-module(juno_ws_handler).
-include_lib("wamp/include/wamp.hrl").

%% Cowboy will automatically close the Websocket connection when no data
%% arrives on the socket after ?TIMEOUT
-define(TIMEOUT, 60000*10).

-type state()       ::  #{
    context => juno_context:context(),
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
            Ctxt = juno_context:set_peer(
                juno_context:new(), cowboy_req:peer(Req)),
            St = #{
                context => Ctxt,
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
    %% At the moment we only support WAMP, so we stop.
    %% TODO use lager
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
    %% TODO use lager
    error_logger:error_report([
        {error, {unsupported_message, Data}},
        {state, St},
        {stacktrace, erlang:get_stacktrace()}
    ]),
    %% We ignore this message and carry on listening
    {ok, Req, St}.


%% -----------------------------------------------------------------------------
%% @doc
%% Handles internal erlang messages and WAMP messages JUNO wants to send to the
%% client. See {@link juno:send/2}.
%% @end
%% -----------------------------------------------------------------------------
websocket_info({timeout, _Ref, _Msg}, Req, St) ->
    %% erlang:start_timer(1000, self(), <<"How' you doin'?">>),
    %% reply(text, Msg, Req, St);
    {ok, Req, St};

websocket_info({stop, Reason}, Req, St) ->
    %% TODO use lager
    error_logger:error_report([
        {description, <<"WAMP session shutdown">>},
        {reason, Reason}
    ]),
    {shutdown, Req, St};

websocket_info(M, Req, St) ->
    case wamp_message:is_message(M) of
        true ->
            %% We send a WAMP message to the client
            #{subprotocol := #{encoding := E, frame_type := T}} = St,
            Reply = frame(T, wamp_encoding:encode(M, E)),
            {reply, Reply, Req, St};
        false ->
            %% All other erlang messages
            {ok, Req, St}
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% Termination
%% @end
%% -----------------------------------------------------------------------------
terminate(normal, _Req, St) ->
    close_session(St);
terminate(stop, _Req, St) ->
    close_session(St);
terminate(timeout, _Req, St) ->
    close_session(St);
terminate(remote, _Req, St) ->
    close_session(St);
terminate({error, closed}, _Req, St) ->
    close_session(St);
terminate({error, badencoding}, _Req, St) ->
    close_session(St);
terminate({error, badframe}, _Req, St) ->
    close_session(St);
terminate({error, _Other}, _Req, St) ->
    close_session(St);
terminate({crash, error, Reason}, _Req, St) ->
    %% TODO use lager
    error_logger:error_report([
        {reason, Reason},
        {stacktrace, erlang:get_stacktrace()}
    ]),
    close_session(St);
terminate({crash, exit, _Other}, _Req, St) ->
    close_session(St);
terminate({crash, throw, _Other}, _Req, St) ->
    close_session(St);
terminate({remote, _Code, _Binary}, _Req, St) ->
    close_session(St).


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
%% TODO Maybe share this with all protocol handlers e.g. tcp.
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
    %% @TODO define condition. We mights need to do this to scale
    %% to millions of connections per node
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
    {Messages, Data3} = wamp_encoding:decode(Data2, T, E),
    St1 = St0#{data => Data3},

    case handle_wamp_messages(Messages, Ctxt0) of
        {ok, Ctxt1} ->
            {ok, Req, set_ctxt(St1, Ctxt1)};
        {stop, Ctxt1} ->
            {shutdown, Req, set_ctxt(St1, Ctxt1)};
        {reply, Replies, Ctxt1} ->
            ReplyFrames = [wamp_encoding:encode(R, E) || R <- Replies],
            reply(T, ReplyFrames, Req, set_ctxt(St1, Ctxt1));
        {stop, Replies, Ctxt1} ->
            self() ! {stop, <<"Router dropped session.">>},
            ReplyFrames = [wamp_encoding:encode(R, E) || R <- Replies],
            reply(T, ReplyFrames, Req, set_ctxt(St1, Ctxt1))
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Handles one or more messages, routing them and returning a reply
%% when required.
%% @end
%% -----------------------------------------------------------------------------
handle_wamp_messages(Ms, Ctxt) ->
    handle_wamp_messages(Ms, Ctxt, []).


%% @private
handle_wamp_messages([], Ctxt, []) ->
    %% We have no replies
    {ok, Ctxt};

handle_wamp_messages([], Ctxt, Acc) ->
    {reply, lists:reverse(Acc), Ctxt};

handle_wamp_messages(
    [#goodbye{}|_], #{goodbye_initiated := true} = Ctxt, _) ->
    %% The client is replying to our goodbye
    {stop, Ctxt};

handle_wamp_messages(
    [#goodbye{} = M|_], #{goodbye_initiated := false} = Ctxt, _) ->
    %% The client initiated a goodbye, so we will not process
    %% any subsequent messages
    juno_router:handle_message(M, Ctxt#{goodbye_initiated => true});

handle_wamp_messages([H|T], Ctxt0, Acc) ->
    case juno_router:handle_message(H, Ctxt0) of
        {ok, Ctxt1} ->
            handle_wamp_messages(T, Ctxt1, Acc);
        {stop, Ctxt1} ->
            {stop, Ctxt1};
        {stop, Reply, Ctxt1} ->
            {stop, Reply, Ctxt1};
        {reply, Reply, Ctxt1} ->
            handle_wamp_messages(T, Ctxt1, [Reply | Acc])
    end.


%% @private
close_session(#{context := #{session_id := SessionId} = Ctxt}) ->
    %% We cleanup session and router data for this Ctxt
    juno_pubsub:unsubscribe_all(Ctxt),
    juno_rpc:unregister_all(Ctxt),
    juno_session:close(SessionId);
close_session(_) ->
    ok.

%% @private
set_ctxt(St, Ctxt) ->
    St#{context => juno_context:reset(Ctxt)}.
