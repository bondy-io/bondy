%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% A Cowboy WS handler.
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
-include("juno.hrl").
-include_lib("wamp/include/wamp.hrl").

%% Cowboy will automatically close the Websocket connection when no data
%% arrives on the socket after ?CONN_TIMEOUT
-define(CONN_TIMEOUT, 60000*10).
-define(WS_SUBPROTOCOL_HEADER_NAME, <<"sec-websocket-protocol">>).


%% The WS subprotocol config
-record(subprotocol, {
    id                      ::  binary(),
    frame_type              ::  text | binary,
    encoding                ::  json | msgpack | json_batched | msgpack_batched
}).

-record(state, {
    subprotocol             ::  subprotocol() | undefined,
    context                 ::  juno_context:context() | undefined,
    data = <<>>             ::  binary(),
    hibernate = false       ::  boolean()
}).

-type state()               ::  #state{}.
-type subprotocol()         ::  #subprotocol{}.

-export([init/2]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).
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
    case cowboy_req:parse_header(?WS_SUBPROTOCOL_HEADER_NAME, Req) of
        undefined ->
            %% At the moment we only support wamp, not plain ws
            lager:info(
                <<"Closing WS connection. Initialised without a value for http header '~p'">>, [?WS_SUBPROTOCOL_HEADER_NAME]),
            %% Returning ok will cause the handler to stop in websocket_handle
            {ok, Req, Opts};
        Subprotocols ->
            Ctxt = juno_context:set_peer(
                juno_context:new(), cowboy_req:peer(Req)),
            St = #state{
                context = Ctxt,
                subprotocol = undefined,
                data = <<>>,
                hibernate = false %% TODO define business logic
            },
            %% The client provided subprotocol options
            subprotocol_init(select_subprotocol(Subprotocols), Req, St)
    end.



%% =============================================================================
%% COWBOY_WEBSOCKET CALLBACKS
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% Initialises the WS connection.
%% @end
%% -----------------------------------------------------------------------------
websocket_init(#state{subprotocol = undefined} = St) ->
    %% This will close the WS connection
    Frame = {
        close, 
        1002, 
        <<"Missing value for header 'sec-websocket-protocol'.">>
    },
    {reply, Frame, St};

websocket_init(St) ->
    {ok, St}.


%% -----------------------------------------------------------------------------
%% @doc
%% Handles frames sent by client
%% @end
%% -----------------------------------------------------------------------------
websocket_handle(Data, #state{subprotocol = undefined} = St) ->
    %% At the moment we only support WAMP, so we stop immediately.
    %% TODO This should be handled by the websocket_init callback above, review and eliminate.
    lager:error(
        <<"Unsupported message ~p. Stacktrace: ~p">>, 
        [Data, erlang:get_stacktrace()]
    ),
    {stop, St};

websocket_handle(
    {T, Data}, #state{subprotocol = #subprotocol{frame_type = T}} = St) ->
    wamp_handle(Data, St);

websocket_handle({ping, _Msg}, St) ->
    %% Cowboy already handles pings for us
    %% We ignore this message and carry on listening
    {ok, St};

websocket_handle({pong, _Msg}, St) ->
    %% We ignore this message and carry on listening
    {ok, St};

websocket_handle(Data, St) ->
    lager:debug(
        <<"Unsupported message ~p. Stacktrace: ~p">>, 
        [Data, erlang:get_stacktrace()]
    ),
    %% We ignore this message and carry on listening
    {ok, St}.


%% -----------------------------------------------------------------------------
%% @doc
%% Handles internal erlang messages and WAMP messages JUNO wants to send to the
%% client. See {@link juno:send/2}.
%% @end
%% -----------------------------------------------------------------------------
websocket_info({timeout, _Ref, _Msg}, St) ->
    %% erlang:start_timer(1000, self(), <<"How' you doin'?">>),
    %% reply(text, Msg, St);
    {ok, St};

websocket_info({stop, Reason}, St) ->
    %% TODO use lager
    lager:debug(
        <<"description='WAMP session shutdown', reason=~p">>, [Reason]),
    {stop, St};

websocket_info({?JUNO_PEER_CALL, Pid, Ref, M}, St0) ->
    %% Here we receive the messages that either the router or another peer
    %% sent to us using juno:send/2,3
    ok = juno:ack(Pid, Ref),
    St1 = maybe_update_state(M, St0),
    %% We encode and send the message to the client
    #state{subprotocol = #subprotocol{encoding = E, frame_type = T}} = St1,
    Reply = frame(T, wamp_encoding:encode(M, E)),
    {reply, Reply, St1};

websocket_info(_, St0) ->
    %% Any other unwanted erlang messages
    {ok, St0}.



%% -----------------------------------------------------------------------------
%% @doc
%% Termination
%% @end
%% -----------------------------------------------------------------------------
%% From : http://ninenines.eu/docs/en/cowboy/2.0/guide/handlers/
%% Note that while this function may be called in a Websocket handler, it is generally not useful to do any clean up as the process terminates immediately after calling this callback when using Websocket.
terminate(normal, _Req, St) ->
    do_terminate(St);

terminate(stop, _Req, St) ->
    do_terminate(St);

terminate(timeout, _Req, St) ->
    do_terminate(St);

terminate(remote, _Req, St) ->
    do_terminate(St);

terminate({error, closed}, _Req, St) ->
    do_terminate(St);

terminate({error, badencoding}, _Req, St) ->
    do_terminate(St);

terminate({error, badframe}, _Req, St) ->
    do_terminate(St);

terminate({error, _Other}, _Req, St) ->
    do_terminate(St);

terminate({crash, error, Reason}, _Req, St) ->
    %% TODO use lager
    error_logger:error_report([
        {reason, Reason},
        {stacktrace, erlang:get_stacktrace()}
    ]),
    do_terminate(St);

terminate({crash, exit, Reason}, _Req, St) ->
    %% TODO use lager
    error_logger:error_report([
        {reason, Reason},
        {stacktrace, erlang:get_stacktrace()}
    ]),
    do_terminate(St);

terminate({crash, throw, Reason}, _Req, St) ->
    %% TODO use lager
    error_logger:error_report([
        {reason, Reason},
        {stacktrace, erlang:get_stacktrace()}
    ]),
    do_terminate(St);

terminate({remote, _Code, _Binary}, _Req, St) ->
    do_terminate(St).



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

subprotocol_init(#subprotocol{id = SId} = Sub, Req0, St0) ->
    Req1 = cowboy_req:set_resp_header(?WS_SUBPROTOCOL_HEADER_NAME, SId, Req0),
    St1 = St0#state{data = <<>>, subprotocol = Sub},
    {cowboy_websocket, Req1, St1, #{idle_timeout => ?CONN_TIMEOUT}}.


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
    #subprotocol{
        frame_type = text,
        encoding = json,
        id = ?WAMP2_JSON
    };

select_subprotocol([?WAMP2_MSGPACK | _T]) ->
    #subprotocol{
        frame_type = binary,
        encoding = msgpack,
        id = ?WAMP2_MSGPACK
    };

select_subprotocol([?WAMP2_JSON_BATCHED | _T]) ->
    #subprotocol{
        frame_type = text,
        encoding = json_batched,
        id = ?WAMP2_JSON_BATCHED
    };

select_subprotocol([?WAMP2_MSGPACK_BATCHED | _T]) ->
    #subprotocol{
        frame_type = binary,
        encoding = msgpack_batched,
        id = ?WAMP2_MSGPACK_BATCHED
    }.


%% @private
reply(FrameType, Frames, #state{hibernate = true} = St) ->
    {reply, frame(FrameType, Frames), St, hibernate};

reply(FrameType, Frames, #state{hibernate = false} = St) ->
    {reply, frame(FrameType, Frames), St}.


%% @private
frame(Type, L) when is_list(L) ->
    [frame(Type, E) || E <- L];

frame(Type, E) when Type == text orelse Type == binary ->
    {Type, E}.



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Handles wamp frames, decoding 1 or more messages, routing them and replying
%% the client when required.
%% @end
%% -----------------------------------------------------------------------------
-spec wamp_handle(binary(), state()) ->
    {ok, state()}
    | {ok, state(), hibernate}
    | {reply, cowboy_websocket:frame() | [cowboy_websocket:frame()], state()}
    | {reply, cowboy_websocket:frame() | [cowboy_websocket:frame()], state(), hibernate}
    | {shutdown, state()}.
    
wamp_handle(Data1, St0) ->
    Data0 = St0#state.data,
    Ctxt0 = St0#state.context,
    #subprotocol{frame_type = T, encoding = E} = St0#state.subprotocol,
    Data2 = <<Data0/binary, Data1/binary>>,
    {Messages, Data3} = wamp_encoding:decode(Data2, T, E),
    St1 = St0#state{data = Data3},

    case handle_wamp_messages(Messages, Ctxt0) of
        {ok, Ctxt1} ->
            {ok, set_ctxt(St1, Ctxt1)};
        {stop, Ctxt1} ->
            {shutdown, set_ctxt(St1, Ctxt1)};
        {reply, Replies, Ctxt1} ->
            ReplyFrames = [wamp_encoding:encode(R, E) || R <- Replies],
            reply(T, ReplyFrames, set_ctxt(St1, Ctxt1));
        {stop, Replies, Ctxt1} ->
            self() ! {stop, <<"Router dropped session.">>},
            ReplyFrames = [wamp_encoding:encode(R, E) || R <- Replies],
            reply(T, ReplyFrames, set_ctxt(St1, Ctxt1))
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Handles one or more messages, routing them and returning a reply
%% when required.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_wamp_messages([wamp_message()], juno_context:context()) ->
    {ok, juno_context:context()} 
    | {reply, [wamp_message()], juno_context:context()} 
    | {stop, juno_context:context()}
    | {stop, [wamp_message()], juno_context:context()}.
handle_wamp_messages(Ms, Ctxt) ->
    handle_wamp_messages(Ms, Ctxt, []).


%% @private
handle_wamp_messages([], Ctxt, []) ->
    %% We have no replies
    {ok, Ctxt};

handle_wamp_messages([], Ctxt, Acc) ->
    {reply, lists:reverse(Acc), Ctxt};

handle_wamp_messages(
    [#goodbye{} = M|_], Ctxt, Acc) ->
    %% The client initiated a goodbye, so we will not process
    %% any subsequent messages
   case juno_router:forward(M, Ctxt) of
        {stop, Ctxt1} ->
            {stop, lists:reverse(Acc), Ctxt1};
        {stop, Reply, Ctxt1} ->
            {stop, lists:reverse([Reply|Acc]), Ctxt1}
    end;

handle_wamp_messages([H|T], Ctxt0, Acc) ->
    case juno_router:forward(H, Ctxt0) of
        {ok, Ctxt1} ->
            handle_wamp_messages(T, Ctxt1, Acc);
        {stop, Reply, Ctxt1} ->
            {stop, [Reply], Ctxt1};
        {reply, Reply, Ctxt1} ->
            handle_wamp_messages(T, Ctxt1, [Reply | Acc])
    end.


%% @private
do_terminate(#state{context = Ctxt}) ->
    juno_context:close(Ctxt).


%% @private
set_ctxt(St, Ctxt) ->
    St#state{context = juno_context:reset(Ctxt)}.


maybe_update_state(#result{request_id = CallId}, St) ->
    Ctxt1 = juno_context:remove_awaiting_call_id(St#state.context, CallId),
    set_ctxt(St, Ctxt1);

maybe_update_state(
    #error{request_type = ?CALL, request_id = CallId}, St) ->
    Ctxt1 = juno_context:remove_awaiting_call_id(St#state.context, CallId),
    set_ctxt(St, Ctxt1);

maybe_update_state(_, St) ->
    St.