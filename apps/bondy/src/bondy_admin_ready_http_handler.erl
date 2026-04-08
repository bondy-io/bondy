%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_admin_ready_http_handler).
-include("http_api.hrl").

-export([init/2]).



%% =============================================================================
%% API
%% =============================================================================



init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Req1 = bondy_http_utils:set_all_headers(Req0),
    Req2 = ready(Method, Req1),
    {ok, Req2, State}.


ready(<<"GET">>, Req) ->
    Status = status_code(bondy_config:get(status, undefined)),
    cowboy_req:reply(Status, Req);

ready(_, Req) ->
    cowboy_req:reply(?HTTP_METHOD_NOT_ALLOWED, Req).




%% =============================================================================
%% PRIVATE
%% =============================================================================


status_code(ready) -> ?HTTP_NO_CONTENT;
status_code(_) -> ?HTTP_SERVICE_UNAVAILABLE.
