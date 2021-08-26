%% =============================================================================
%%  bondy_wamp_rbac_api.erl -
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
-module(bondy_wamp_rbac_api).
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


handle_call(?BONDY_GROUP_ADD, #call{} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_group:add(Uri, bondy_rbac_group:new(Data)) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_GROUP_DELETE, #call{} = M, Ctxt) ->
    [Uri, Name] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_group:remove(Uri, Name) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_GROUP_GET, #call{} = M, Ctxt) ->
    [Uri, Name] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_group:lookup(Uri, Name) of
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M);
        Group ->
            Ext = bondy_rbac_group:to_external(Group),
            wamp_message:result(M#call.request_id, #{}, [Ext])
    end;

handle_call(?BONDY_GROUP_LIST, #call{} = M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 1),
    Ext = [bondy_rbac_group:to_external(X) || X <- bondy_rbac_group:list(Uri)],
    wamp_message:result(M#call.request_id, #{}, [Ext]);

handle_call(?BONDY_GROUP_UPDATE, #call{} = M, Ctxt) ->
    [Uri, Name, Info] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:update(Uri, Name, Info) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_GROUP_ADD_GROUP, #call{} = M, Ctxt) ->
    [Uri, Name, Group] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:add_group(Uri, Name, Group) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_GROUP_ADD_GROUPS, #call{} = M, Ctxt) ->
    [Uri, Name, Group] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:add_groups(Uri, Name, Group) of
        ok ->
            Ext = bondy_rbac_group:to_external(Group),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_GROUP_REMOVE_GROUP, #call{} = M, Ctxt) ->
    [Uri, Name, Groupname] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:remove_group(Uri, Name, Groupname) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_GROUP_REMOVE_GROUPS, #call{} = M, Ctxt) ->
    [Uri, Name, Groupnames] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:remove_groups(Uri, Name, Groupnames) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_SOURCE_ADD, #call{} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_source:add(Uri, bondy_rbac_source:new_assignment(Data)) of
        {ok, Source} ->
            Ext = bondy_rbac_source:to_external(Source),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_SOURCE_DELETE, #call{} = M, Ctxt) ->
    [Uri, Username, CIDR] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_source:remove(Uri, Username, CIDR) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_SOURCE_GET, #call{} = M, _) ->
    %% TODO
    bondy_wamp_utils:no_such_procedure_error(M);

handle_call(?BONDY_SOURCE_LIST, #call{} = M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 1),
    Ext = [
        bondy_rbac_source:to_external(S)
        || S <- bondy_rbac_source:list(Uri)
    ],
    wamp_message:result(M#call.request_id, #{}, [Ext]);

handle_call(?BONDY_SOURCE_MATCH, #call{} = M, Ctxt) ->
    %% [Uri, Username] or [Uri, Username, IPAddress]
    L = bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3),
    Ext = [
        bondy_rbac_source:to_external(S)
        || S <- erlang:apply(bondy_rbac_source, match, L)
    ],
    wamp_message:result(M#call.request_id, #{}, [Ext]);

handle_call(?BONDY_USER_ADD, #call{} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_user:add(Uri, bondy_rbac_user:new(Data)) of
        {ok, User} ->
            Ext = bondy_rbac_user:to_external(User),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_USER_DELETE, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_user:remove(Uri, Username) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_USER_GET, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_user:lookup(Uri, Username) of
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M);
        User ->
            Ext = bondy_rbac_user:to_external(User),
            wamp_message:result(M#call.request_id, #{}, [Ext])
    end;

handle_call(?BONDY_USER_IS_ENABLED, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    Res = bondy_rbac_user:is_enabled(Uri, Username),
    wamp_message:result(M#call.request_id, #{}, [Res]);

handle_call(?BONDY_USER_ENABLE, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    ok = bondy_rbac_user:enable(Uri, Username),
    wamp_message:result(M#call.request_id, #{});

handle_call(?BONDY_USER_DISABLE, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    ok = bondy_rbac_user:disable(Uri, Username),
    wamp_message:result(M#call.request_id, #{});

handle_call(?BONDY_USER_LIST, #call{} = M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 1),

    Ext = [bondy_rbac_user:to_external(X) || X <- bondy_rbac_user:list(Uri)],
    wamp_message:result(M#call.request_id, #{}, [Ext]);

handle_call(?BONDY_USER_UPDATE, #call{} = M, Ctxt) ->
    [Uri, Username, Info] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:update(Uri, Username, Info) of
        {ok, User} ->
            Ext = bondy_rbac_user:to_external(User),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_USER_CHANGE_PASSWORD, #call{} = M, Ctxt) ->
    %% L is either [Uri, Username, New] or [Uri, Username, New, Old]
    L = bondy_wamp_utils:validate_call_args(M, Ctxt, 3, 4),

    case erlang:apply(bondy_rbac_user, change_password, L) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)

        end;

handle_call(?BONDY_USER_ADD_GROUP, #call{} = M, Ctxt) ->
    [Uri, Name, Group] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:add_group(Uri, Name, Group) of
        {ok, Group} ->
            Ext = bondy_rbac_user:to_external(Group),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_USER_ADD_GROUPS, #call{} = M, Ctxt) ->
    [Uri, Name, Group] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:add_groups(Uri, Name, Group) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_USER_REMOVE_GROUP, #call{} = M, Ctxt) ->
    [Uri, Name, Groupname] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:remove_group(Uri, Name, Groupname) of
        {ok, Group} ->
            Ext = bondy_rbac_user:to_external(Group),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_USER_REMOVE_GROUPS, #call{} = M, Ctxt) ->
    [Uri, Name, Groupnames] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:remove_groups(Uri, Name, Groupnames) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_TICKET_ISSUE, #call{} = M, Ctxt) ->
    [_Uri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 0),
    Session = bondy_context:session(Ctxt),

    Opts = case M#call.arguments_kw of
        undefined -> maps:new();
        Map -> Map
    end,

    case bondy_ticket:issue(Session, Opts) of
        {ok, Ticket, Claims} ->
            Resp0 = maps:with(
                [id, expires_at, issued_at, scope], Claims
            ),
            Resp = maps:put(ticket, Ticket, Resp0),
            wamp_message:result(M#call.request_id, #{}, [Resp]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

handle_call(?BONDY_TICKET_REVOKE_ALL, #call{} = M, Ctxt) ->
    [Uri, Authid] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    ok = bondy_ticket:revoke_all(Uri, Authid),
    wamp_message:result(M#call.request_id, #{});

%% TODO BONDY_TICKET_VERIFY
%% TODO BONDY_TICKET_REVOKE

handle_call(_, #call{} = M, _) ->
    bondy_wamp_utils:no_such_procedure_error(M).




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
handle_event(
    ?BONDY_USER_ADDED, #event{arguments = [_RealmUri, _Username]}) ->
    ok;

handle_event(
    ?BONDY_USER_UPDATED, #event{arguments = [RealmUri, Username]}) ->
    bondy_oauth2:revoke_refresh_tokens(RealmUri, Username);

handle_event(
    ?BONDY_USER_DELETED, #event{arguments = [RealmUri, Username]}) ->
    bondy_oauth2:revoke_refresh_tokens(RealmUri, Username);

handle_event(
    ?BONDY_USER_CREDENTIALS_CHANGED, #event{arguments = [RealmUri, Username]}) ->
    bondy_oauth2:revoke_refresh_tokens(RealmUri, Username);

handle_event(_, _) ->
    ok.



