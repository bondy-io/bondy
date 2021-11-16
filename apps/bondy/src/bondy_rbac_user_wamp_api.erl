%% =============================================================================
%%  bondy_rbac_user_wamp_api.erl -
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
-module(bondy_rbac_user_wamp_api).
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

handle_call(?BONDY_USER_ADD, #call{} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_user:add(Uri, bondy_rbac_user:new(Data)) of
        {ok, User} ->
            Ext = bondy_rbac_user:to_external(User),
            R = wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_DELETE, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_user:remove(Uri, Username) of
        ok ->
            R = wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_GET, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_user:lookup(Uri, Username) of
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E};
        User ->
            Ext = bondy_rbac_user:to_external(User),
            R = wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R}
    end;

handle_call(?BONDY_USER_IS_ENABLED, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    Res = bondy_rbac_user:is_enabled(Uri, Username),
    R = wamp_message:result(M#call.request_id, #{}, [Res]),
    {reply, R};

handle_call(?BONDY_USER_ENABLE, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    ok = bondy_rbac_user:enable(Uri, Username),
    R = wamp_message:result(M#call.request_id, #{}),
    {reply, R};

handle_call(?BONDY_USER_DISABLE, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    ok = bondy_rbac_user:disable(Uri, Username),
    R = wamp_message:result(M#call.request_id, #{}),
    {reply, R};

handle_call(?BONDY_USER_LIST, #call{} = M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 1),

    Ext = [bondy_rbac_user:to_external(X) || X <- bondy_rbac_user:list(Uri)],
    R = wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

handle_call(?BONDY_USER_UPDATE, #call{} = M, Ctxt) ->
    [Uri, Username, Info] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:update(Uri, Username, Info) of
        {ok, User} ->
            Ext = bondy_rbac_user:to_external(User),
            R = wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_CHANGE_PASSWORD, #call{} = M, Ctxt) ->
    %% L is either [Uri, Username, New] or [Uri, Username, New, Old]
    L = bondy_wamp_utils:validate_call_args(M, Ctxt, 3, 4),

    case erlang:apply(bondy_rbac_user, change_password, L) of
        ok ->
            R = wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_ADD_GROUP, #call{} = M, Ctxt) ->
    [Uri, Name, Group] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:add_group(Uri, Name, Group) of
        {ok, Group} ->
            Ext = bondy_rbac_user:to_external(Group),
            R = wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_ADD_GROUPS, #call{} = M, Ctxt) ->
    [Uri, Name, Group] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:add_groups(Uri, Name, Group) of
        ok ->
            R = wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_REMOVE_GROUP, #call{} = M, Ctxt) ->
    [Uri, Name, Groupname] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:remove_group(Uri, Name, Groupname) of
        {ok, Group} ->
            Ext = bondy_rbac_user:to_external(Group),
            R = wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_REMOVE_GROUPS, #call{} = M, Ctxt) ->
    [Uri, Name, Groupnames] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:remove_groups(Uri, Name, Groupnames) of
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



