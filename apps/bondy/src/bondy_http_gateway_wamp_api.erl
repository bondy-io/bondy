%% =============================================================================
%%  bondy_http_gateway_wamp_api.erl - the Cowboy handler for all API Gateway
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
-module(bondy_http_gateway_wamp_api).
-behaviour(bondy_wamp_api).

-include_lib("wamp/include/wamp.hrl").
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
    Proc :: uri(), M :: wamp_message:call(), Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined)
    }
    | {reply, wamp_result() | wamp_error()}.


handle_call(?BONDY_HTTP_GATEWAY_LOAD, #call{} = M, Ctxt) ->
    [Spec] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),

    case bondy_http_gateway:load(Spec) of
        ok ->
            R = wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_HTTP_GATEWAY_LIST, #call{} = M, Ctxt) ->
    [] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 0),

    Result = bondy_http_gateway:list(),
    R = wamp_message:result(M#call.request_id, #{}, [Result]),
    {reply, R};

handle_call(?BONDY_HTTP_GATEWAY_GET, #call{} = M, Ctxt) ->
    [Id] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),

    case bondy_http_gateway:lookup(Id) of
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E};
        Spec ->
            R = wamp_message:result(M#call.request_id, #{}, [Spec]),
            {reply, R}
    end;

handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_utils:no_such_procedure_error(M),
    {reply, E}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
handle_event(_, #event{}) ->
    ok.




