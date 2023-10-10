%% =============================================================================
%%  bondy_cluster_wamp_api.erl -
%%
%%  Copyright (c) 2016-2023 Leapsight. All rights reserved.
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
-module(bondy_cluster_wamp_api).
-behaviour(bondy_wamp_api).

-include_lib("wamp/include/wamp.hrl").
-include("bondy_uris.hrl").

-export([handle_call/3]).



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
    | {reply, wamp_result() | wamp_error()}
    | no_return().

handle_call(?BONDY_CLUSTER_JOIN, #call{} = M, _Ctxt) ->
    R = bondy_wamp_utils:no_such_procedure_error(M),
    {reply, R};

handle_call(?BONDY_CLUSTER_LEAVE, #call{} = M, _Ctxt) ->
    %% TODO
    R = wamp_message:result(M#call.request_id, #{}, []),
    {reply, R};

handle_call(?BONDY_CLUSTER_CONNECTIONS, #call{} = M, _Ctxt) ->
    %% TODO
    R = bondy_wamp_utils:no_such_procedure_error(M),
    {reply, R};

handle_call(?BONDY_CLUSTER_MEMBERS, #call{} = M, _Ctxt) ->
    {ok, Members} = partisan_peer_service:members(),
    R = wamp_message:result(M#call.request_id, #{}, [Members]),
    {reply, R};

handle_call(?BONDY_CLUSTER_INFO, #call{} = M, _Ctxt) ->
    %% TODO
    Info = #{
        <<"node_spec">> => bondy_wamp_utils:node_spec(),
        <<"nodes">> => partisan:nodes()
    },
    R = wamp_message:result(M#call.request_id, #{}, [Info]),
    {reply, R};

handle_call(_, #call{} = M, _) ->
    R = bondy_wamp_utils:no_such_procedure_error(M),
    {reply, R}.



%% =============================================================================
%% PRIVATE
%% =============================================================================

