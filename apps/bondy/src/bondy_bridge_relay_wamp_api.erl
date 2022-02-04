%% =============================================================================
%%  bondy_bridge_api.erl - Bondy configuration schema for Cuttlefish
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
-module(bondy_bridge_relay_wamp_api).
-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").

-include_lib("bondy_uris.hrl").

-export([handle_call/3]).


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


handle_call(?BONDY_ROUTER_BRIDGE_ADD, #call{} = M, _Ctxt) ->
    no_such_procedure(M);

handle_call(?BONDY_ROUTER_BRIDGE_CHECK_SPEC, #call{} = M, _Ctxt) ->
    no_such_procedure(M);

handle_call(?BONDY_ROUTER_BRIDGE_GET_SPEC, #call{} = M, _Ctxt) ->
    no_such_procedure(M);

handle_call(?BONDY_ROUTER_BRIDGE_STATUS, #call{} = M, _Ctxt) ->
    no_such_procedure(M);

handle_call(?BONDY_ROUTER_BRIDGE_REMOVE, #call{} = M, _Ctxt) ->
    no_such_procedure(M);

handle_call(?BONDY_ROUTER_BRIDGE_STOP, #call{} = M, _Ctxt) ->
    no_such_procedure(M);

handle_call(_, #call{} = M, _) ->
    no_such_procedure(M).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
no_such_procedure(M) ->
    E = bondy_wamp_utils:no_such_procedure_error(M),
    {reply, E}.