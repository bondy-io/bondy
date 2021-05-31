%% =============================================================================
%%  bondy_wamp_http_gateway_api.erl - the Cowboy handler for all API Gateway
%%  requests
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
-module(bondy_wamp_http_gateway_api).
-behaviour(bondy_wamp_api).

-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").



-export([handle_call/3]).
-export([handle_event/2]).


%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_call(
    Proc :: uri(), M :: wamp_message:call(), Ctxt :: bony_context:t()) -> wamp_messsage:result() | wamp_message:error().


handle_call(?BONDY_HTTP_GATEWAY_LOAD, #call{} = M, Ctxt) ->
    [Spec] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),
    case bondy_http_gateway:load(Spec) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_HTTP_GATEWAY_LIST, #call{} = M, Ctxt) ->
    [] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 0),
    Result = bondy_http_gateway:list(),
    wamp_message:result(M#call.request_id, #{}, [Result]);

handle_call(?BONDY_HTTP_GATEWAY_GET, #call{} = M, Ctxt) ->
    [Id] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),
    case bondy_http_gateway:lookup(Id) of
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M);
        Spec ->
            wamp_message:result(M#call.request_id, #{}, [Spec])
    end;

handle_call(_, #call{} = M, _) ->
    bondy_wamp_utils:no_such_procedure_error(M).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
handle_event(_, #event{}) ->
    ok.




