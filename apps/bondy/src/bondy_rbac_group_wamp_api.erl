%% =============================================================================
%%  bondy_rbac_group_wamp_api.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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
-module(bondy_rbac_group_wamp_api).
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


handle_call(?BONDY_GROUP_ADD, #call{} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_group:add(Uri, bondy_rbac_group:new(Data)) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            R = wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GROUP_DELETE, #call{} = M, Ctxt) ->
    [Uri, Name] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_group:remove(Uri, Name) of
        ok ->
            R = wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GROUP_GET, #call{} = M, Ctxt) ->
    [Uri, Name] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_group:lookup(Uri, Name) of
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E};
        Group ->
            Ext = bondy_rbac_group:to_external(Group),
            R = wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R}
    end;

handle_call(?BONDY_GROUP_LIST, #call{} = M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 1),
    Ext = [bondy_rbac_group:to_external(X) || X <- bondy_rbac_group:list(Uri)],
    R = wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

handle_call(?BONDY_GROUP_UPDATE, #call{} = M, Ctxt) ->
    [Uri, Name, Info] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:update(Uri, Name, Info) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            R = wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GROUP_ADD_GROUP, #call{} = M, Ctxt) ->
    [Uri, Name, Group] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:add_group(Uri, Name, Group) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            R = wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GROUP_ADD_GROUPS, #call{} = M, Ctxt) ->
    [Uri, Name, Group] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:add_groups(Uri, Name, Group) of
        ok ->
            Ext = bondy_rbac_group:to_external(Group),
            R = wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GROUP_REMOVE_GROUP, #call{} = M, Ctxt) ->
    [Uri, Name, Groupname] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:remove_group(Uri, Name, Groupname) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            R = wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GROUP_REMOVE_GROUPS, #call{} = M, Ctxt) ->
    [Uri, Name, Groupnames] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:remove_groups(Uri, Name, Groupnames) of
        ok ->
            R = wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_utils:no_such_procedure_error(M),
    {reply, E}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------

handle_event(_, _) ->
    ok.



