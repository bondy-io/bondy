%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rbac_api).
-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

-export([handle_call/3]).
-export([handle_event/2]).



%% =============================================================================
%% API
%% =============================================================================


-spec handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined)
    }
    | {reply, wamp_result() | wamp_error()}.


%% -----------------------------------------------------------------------------
%% bondy.user.*
%% -----------------------------------------------------------------------------
handle_call(?BONDY_USER_ADD, #call{} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_user:add(Uri, bondy_rbac_user:new(Data)) of
        {ok, User} ->
            Ext = bondy_rbac_user:to_external(User),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_DELETE, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_user:remove(Uri, Username) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_GET, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_user:lookup(Uri, Username) of
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E};
        User ->
            Ext = bondy_rbac_user:to_external(User),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R}
    end;

handle_call(?BONDY_USER_IS_ENABLED, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    Res = bondy_rbac_user:is_enabled(Uri, Username),
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Res]),
    {reply, R};

handle_call(?BONDY_USER_ENABLE, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    ok = bondy_rbac_user:enable(Uri, Username),
    R = bondy_wamp_message:result(M#call.request_id, #{}),
    {reply, R};

handle_call(?BONDY_USER_DISABLE, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    ok = bondy_rbac_user:disable(Uri, Username),
    R = bondy_wamp_message:result(M#call.request_id, #{}),
    {reply, R};

handle_call(?BONDY_USER_LIST, #call{} = M, Ctxt) ->
    [Uri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),

    Ext = [bondy_rbac_user:to_external(X) || X <- bondy_rbac_user:list(Uri)],
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

handle_call(?BONDY_USER_UPDATE, #call{} = M, Ctxt) ->
    [Uri, Username, Info] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:update(Uri, Username, Info) of
        {ok, User} ->
            Ext = bondy_rbac_user:to_external(User),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_CHANGE_PASSWORD, #call{} = M, Ctxt) ->
    %% L is either [Uri, Username, New] or [Uri, Username, New, Old]
    L = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3, 4),

    case erlang:apply(bondy_rbac_user, change_password, L) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_ADD_ALIAS, #call{} = M, Ctxt) ->
    [Uri, Name, Alias] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:add_alias(Uri, Name, Alias) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_REMOVE_ALIAS, #call{} = M, Ctxt) ->
    [Uri, Name, Alias] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:remove_alias(Uri, Name, Alias) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_ADD_GROUP, #call{} = M, Ctxt) ->
    [Uri, Name, Group] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:add_group(Uri, Name, Group) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;


handle_call(?BONDY_USER_ADD_GROUPS, #call{} = M, Ctxt) ->
    [Uri, Name, Groups] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:add_groups(Uri, Name, Groups) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_REMOVE_GROUP, #call{} = M, Ctxt) ->
    [Uri, Name, Groupname] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:remove_group(Uri, Name, Groupname) of
        {ok, Group} ->
            Ext = bondy_rbac_user:to_external(Group),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_REMOVE_GROUPS, #call{} = M, Ctxt) ->
    [Uri, Name, Groupnames] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:remove_groups(Uri, Name, Groupnames) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_USER_GRANTS, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),

    Ext = [bondy_rbac:externalize_grant(X) || X <- bondy_rbac:user_grants(Uri, Username)],
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

%% -----------------------------------------------------------------------------
%% bondy.group.*
%% -----------------------------------------------------------------------------
handle_call(?BONDY_GROUP_ADD, #call{} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_group:add(Uri, bondy_rbac_group:new(Data)) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GROUP_DELETE, #call{} = M, Ctxt) ->
    [Uri, Name] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_group:remove(Uri, Name) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GROUP_GET, #call{} = M, Ctxt) ->
    [Uri, Name] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_group:lookup(Uri, Name) of
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E};
        Group ->
            Ext = bondy_rbac_group:to_external(Group),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R}
    end;

handle_call(?BONDY_GROUP_LIST, #call{} = M, Ctxt) ->
    [Uri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    Ext = [bondy_rbac_group:to_external(X) || X <- bondy_rbac_group:list(Uri)],
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

handle_call(?BONDY_GROUP_UPDATE, #call{} = M, Ctxt) ->
    [Uri, Name, Info] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:update(Uri, Name, Info) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GROUP_ADD_GROUP, #call{} = M, Ctxt) ->
    [Uri, Name, Group] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:add_group(Uri, Name, Group) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GROUP_ADD_GROUPS, #call{} = M, Ctxt) ->
    [Uri, Name, Group] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:add_groups(Uri, Name, Group) of
        ok ->
            Ext = bondy_rbac_group:to_external(Group),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GROUP_REMOVE_GROUP, #call{} = M, Ctxt) ->
    [Uri, Name, Groupname] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:remove_group(Uri, Name, Groupname) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GROUP_REMOVE_GROUPS, #call{} = M, Ctxt) ->
    [Uri, Name, Groupnames] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:remove_groups(Uri, Name, Groupnames) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GROUP_GRANTS, #call{} = M, Ctxt) ->
    [Uri, GroupName] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),

    Ext = [bondy_rbac:externalize_grant(X) || X <- bondy_rbac:group_grants(Uri, GroupName)],
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

%% -----------------------------------------------------------------------------
%% bondy.grant.*
%% -----------------------------------------------------------------------------
handle_call(?BONDY_GRANT_CREATE, #call{} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    case bondy_rbac:grant(Uri, Data) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_GRANT_REVOKE, #call{} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    case bondy_rbac:revoke(Uri, Data) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

%% -----------------------------------------------------------------------------
%% bondy.source.*
%% -----------------------------------------------------------------------------
handle_call(?BONDY_SOURCE_ADD, #call{} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_source:add(Uri, bondy_rbac_source:new_assignment(Data)) of
        {ok, Source} ->
            Ext = bondy_rbac_source:to_external(Source),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_SOURCE_DELETE, #call{} = M, Ctxt) ->
    [Uri, Username, CIDR] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_source:remove(Uri, Username, CIDR) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_SOURCE_GET, #call{} = M, _) ->
    %% TODO
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E};

handle_call(?BONDY_SOURCE_LIST, #call{} = M, Ctxt) ->
    [Uri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    Ext = [
        bondy_rbac_source:to_external(S)
        || S <- bondy_rbac_source:list(Uri)
    ],
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

handle_call(?BONDY_SOURCE_MATCH, #call{} = M, Ctxt) ->
    %% [Uri, Username] or [Uri, Username, IPAddress]
    L = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2, 3),
    Ext = [
        bondy_rbac_source:to_external(S)
        || S <- erlang:apply(bondy_rbac_source, match, L)
    ],
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

%% -----------------------------------------------------------------------------
%% bondy.grant.*
%% -----------------------------------------------------------------------------

handle_call(?BONDY_RBAC_AUTHORIZE, #call{} = M, Ctxt) ->
    [AuthId, Permission, Resource] =
        bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),
    RealmUri = bondy_context:realm_uri(Ctxt),
    RBACCtxt = bondy_rbac:get_context(RealmUri, AuthId),
    R =
        try bondy_rbac:authorize(Permission, Resource, RBACCtxt) of
            ok ->
                bondy_wamp_message:result(M#call.request_id, #{}, [true])
        catch
            error:{not_authorized, Msg} ->
                bondy_wamp_message:result(
                    M#call.request_id, #{}, [false], #{message => Msg}
                )
        end,

    {reply, R};

handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------

handle_event(_, _) ->
    ok.




%% =============================================================================
%% PRIVATE
%% =============================================================================


