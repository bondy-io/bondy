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

-module(ramp_wamp_ws_handler).


-export([init/3]).
-export([websocket_handle/3]).
-export([websocket_info/3]).

init({tcp, http}, Req0, _Opts) ->
    %% From [Cowboy's Users Guide](http://ninenines.eu/docs/en/cowboy/1.0/guide/ws_handlers/)
    %% If the sec-websocket-protocol header was sent with the request for
    %% establishing a Websocket connection, then the Websocket handler must
    %% select one of these subprotocol and send it back to the client,
    %% otherwise the client might decide to close the connection, assuming no
    %% correct subprotocol was found.
    case cowboy_req:parse_header(<<"sec-websocket-protocol">>, Req0) of
        {ok, undefined, Req1} ->
            {cowboy_websocket, Req1, #{}};
        {ok, Subprotocols, Req1} ->
            case select_protocol(Subprotocols) of
                {ok, Subprotocol} ->
                    Req2 = cowboy_req:set_resp_header(
                        <<"sec-websocket-protocol">>, Subprotocol, Req1),
                    {cowboy_websocket, Req2, #{}};
                not_found ->
                    Error = ramp:error(
                        invalid_sec_websocket_procotol, Subprotocols),
                    {ok, Req2} = cowboy_req:reply(
                        500,
                        [{<<"content-type">>, <<"application/json">>}],
                        jsx:encode(Error),
                        Req1
                    ),
                    {ok, Req2, #{}}
            end
    end.


websocket_handle({text, Msg}, Req, State) ->
    {reply, {text, << "That's what she said! ", Msg/binary >>}, Req, State};

websocket_handle({binary, _Data}, Req, State) ->
    {ok, Req, State}.


websocket_info({timeout, _Ref, Msg}, Req, State) ->
    erlang:start_timer(1000, self(), <<"How' you doin'?">>),
    {reply, {text, Msg}, Req, State};

websocket_info(_Info, Req, State) ->
    {ok, Req, State}.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
select_protocol(Ps) ->
    select_protocol(Ps, []).


%% @private
-spec select_protocol(list(), list()) -> {ok, binary()} | not_found.
select_protocol([], []) ->
    not_found;

select_protocol([], Acc) ->
    %% We pick the one with highest priority
    {ok, hd(lists:usort(Acc))};

select_protocol([<<"wamp.2.json">> = P | T], Acc) ->
    select_protocol(T, [{2, P, json} | Acc]);

select_protocol([<<"wamp.2.msgpack">> = P | T], Acc) ->
    %% We prefer a binary serialization => 1
    select_protocol(T, [{1, P, msgpack} | Acc]);

select_protocol([_ | T], Acc) ->
    select_protocol(T, Acc).
