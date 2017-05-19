%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2017. All rights reserved.
%% -----------------------------------------------------------------------------

-module(juno_rest_reverse_proxy_handler).

-define(CONN_TIMEOUT, 8000).
-define(RECV_TIMEOUT, 5000).


-export([init/2]).



%% ============================================================================
%% COWBOY CALLBACKS
%% ============================================================================


init(Req, St) ->
	forward(cowboy_req:method(Req), Req, St).





%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
forward(Method, Req0, St) ->
    Opts = [
        {connect_timeout, maps:get(connect_timeout, St, ?CONN_TIMEOUT)},
        {recv_timeout, maps:get(connect_timeout, St, ?RECV_TIMEOUT)}
    ],
    URL = maps:get(<<"upstream_url">>, St),
    URI = cowboy_req:uri(Req0, #{host => URL, port => 80}),
    Headers = cowboy_req:headers(Req0),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    io:format(
        "Gateway is forwarding request to ~p~n", 
        [[method(Method), URI, Headers, Body, Opts]]
    ),
    try 
        Response = hackney:request(method(Method), URI, Headers, Body, Opts),
        reply(Method, Response, Req1, St)
    catch
         _:Reason ->
             reply(Method, Reason, Req1, St)
            
    end.
    


%% @private
reply(<<"HEAD">>, {ok, StatusCode, RespHeaders}, Req0, St) ->
    Req1 = cowboy_req:reply(StatusCode, RespHeaders, <<>>, Req0),
    {ok, Req1, St};

reply(_, {ok, StatusCode, RespHeaders, ClientRef}, Req0, St) ->
    {ok, Body} = hackney:body(ClientRef),
    Req1 = cowboy_req:reply(StatusCode, RespHeaders, Body, Req0),
    {ok, Req1, St};

reply(_, {error, _Reason}, Req0, St) ->
    %% TODO Reply error
    Req1 = cowboy_req:reply(500, [], <<>>, Req0),
    {ok, Req1, St}.


%% @private
method(<<"DELETE">>) -> delete;
method(<<"GET">>) -> get;
method(<<"HEAD">>) -> head;
method(<<"OPTIONS">>) -> options;
method(<<"PATCH">>) -> patch;
method(<<"POST">>) -> post;
method(<<"PUT">>) -> put.