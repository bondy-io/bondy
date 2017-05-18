%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2017. All rights reserved.
%% -----------------------------------------------------------------------------

-module(juno_rest_reverse_proxy_handler).




-export([init/2]).



%% ============================================================================
%% COWBOY CALLBACKS
%% ============================================================================


init(Req, Opts) ->
	% Req = forward(Method, Echo, Req0),
	{ok, Req, Opts}.


% forward(Req, State) ->
%     Method = Req#http_req.method,
%     Path = Req#http_req.raw_path,
%     Host = to_string(Req#http_req.host, "."),
%     Qs  = Req#http_req.raw_qs,
%     Binds = Req#http_req.bindings,
%     Cookies = Req#http_req.cookies,
%     Headers = Req#http_req.headers,

%     Opts = [
%         {connect_timeout, maps:get(connect_timeout, State)},
%         {recv_timeout, maps:get(connect_timeout, State)}
%     ],
%     URI = [
%         UpstreamURL,
%         cowboy_req:path(Req),
%         cowboy_req:qs(Req),
%         cowboy_req:fragment(Req)
%     ]
%     hackney:request(method(Method), URI, Headers, Body, Opts)




%% @private
method(<<"DELETE">>) -> delete;
method(<<"GET">>) -> get;
method(<<"HEAD">>) -> head;
method(<<"OPTIONS">>) -> options;
method(<<"PATCH">>) -> patch;
method(<<"POST">>) -> post;
method(<<"PUT">>) -> put.