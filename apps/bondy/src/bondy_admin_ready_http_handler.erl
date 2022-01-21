
%% =============================================================================
%%  bondy_admin_ready_http_handler.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
    Req1 = bondy_http_utils:set_meta_headers(Req0),
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