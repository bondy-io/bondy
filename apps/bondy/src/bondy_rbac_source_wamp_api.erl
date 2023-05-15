%% =============================================================================
%%  bondy_rbac_source_wamp_api.erl -
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
-module(bondy_rbac_source_wamp_api).
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

handle_call(?BONDY_SOURCE_ADD, #call{} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_source:add(Uri, bondy_rbac_source:new_assignment(Data)) of
        {ok, Source} ->
            Ext = bondy_rbac_source:to_external(Source),
            R = wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_SOURCE_DELETE, #call{} = M, Ctxt) ->
    [Uri, Username, CIDR] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_source:remove(Uri, Username, CIDR) of
        ok ->
            R = wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_SOURCE_GET, #call{} = M, _) ->
    %% TODO
    E = bondy_wamp_utils:no_such_procedure_error(M),
    {reply, E};

handle_call(?BONDY_SOURCE_LIST, #call{} = M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 1),
    Ext = [
        bondy_rbac_source:to_external(S)
        || S <- bondy_rbac_source:list(Uri)
    ],
    R = wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

handle_call(?BONDY_SOURCE_MATCH, #call{} = M, Ctxt) ->
    %% [Uri, Username] or [Uri, Username, IPAddress]
    L = bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3),
    Ext = [
        bondy_rbac_source:to_external(S)
        || S <- erlang:apply(bondy_rbac_source, match, L)
    ],
    R = wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_utils:no_such_procedure_error(M),
    {reply, E}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------

handle_event(_, _) ->
    ok.



