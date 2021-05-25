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
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-export([handle_call/2]).


%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_call(M :: wamp_message:call(), Ctxt :: bony_context:t()) -> ok.

handle_call(M, Ctxt) ->
    PeerId = bondy_context:peer_id(Ctxt),

    try
        Reply = do_handle(M, Ctxt),
        bondy:send(PeerId, Reply)
    catch
        _:Reason ->
            %% We catch any exception from do_handle and turn it
            %% into a WAMP Error
            Error = bondy_wamp_utils:maybe_error({error, Reason}, M),
            bondy:send(PeerId, Error)
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================




-spec do_handle(M :: wamp_message:call(), Ctxt :: bony_context:t()) ->
    wamp_messsage:result() | wamp_message:error().

%% REALMS ----------------------------------------------------------------------

do_handle(#call{procedure_uri = ?BONDY_REALM_CREATE_OLD} = M, Ctxt) ->
    [Data] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),

    Realm = bondy_realm:add(Data),
    Ext = bondy_realm:to_external(Realm),
    wamp_message:result(M#call.request_id, #{}, [Ext]);

do_handle(#call{procedure_uri = ?BONDY_REALM_UPDATE} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 2),

    Realm = bondy_realm:update(Uri, Data),
    Ext = bondy_realm:to_external(Realm),
    wamp_message:result(M#call.request_id, #{}, [Ext]);

do_handle(#call{procedure_uri = ?BONDY_REALM_LIST_OLD} = M, Ctxt) ->
    [] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 0, 0),

    Ext = [bondy_realm:to_external(X) || X <- bondy_realm:list()],
    wamp_message:result(M#call.request_id, #{}, [Ext]);

do_handle(#call{procedure_uri = ?BONDY_REALM_SECURITY_ENABLE} = M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),

    ok = bondy_realm:enable_security(bondy_realm:fetch(Uri)),
    wamp_message:result(M#call.request_id, #{});

do_handle(#call{procedure_uri = ?BONDY_REALM_SECURITY_DISABLE} = M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),

    ok = bondy_realm:disable_security(bondy_realm:fetch(Uri)),
    wamp_message:result(M#call.request_id, #{});

do_handle(#call{procedure_uri = ?BONDY_REALM_SECURITY_STATUS} = M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),

    Status = bondy_realm:security_status(bondy_realm:fetch(Uri)),
    wamp_message:result(M#call.request_id, #{}, [Status]);

do_handle(#call{procedure_uri = ?BONDY_REALM_SECURITY_IS_ENABLED} = M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),

    Boolean = bondy_realm:is_security_enabled(bondy_realm:fetch(Uri)),
    wamp_message:result(M#call.request_id, #{}, [Boolean]);

do_handle(#call{procedure_uri = ?BONDY_REALM_DELETE_OLD} = M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),

    case bondy_realm:delete(Uri) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

%% USERS -----------------------------------------------------------------------

do_handle(#call{procedure_uri = ?BONDY_RBAC_USER_ADD} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_user:add(Uri, bondy_rbac_user:new(Data)) of
        {ok, User} ->
            Ext = bondy_rbac_user:to_external(User),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;


do_handle(#call{procedure_uri = ?BONDY_RBAC_USER_UPDATE} = M, Ctxt) ->
    [Uri, Username, Info] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_user:update(Uri, Username, Info) of
        {ok, User} ->
            Ext = bondy_rbac_user:to_external(User),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

do_handle(#call{procedure_uri = ?BONDY_RBAC_USER_DELETE} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_user:remove(Uri, Username) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

do_handle(#call{procedure_uri = ?BONDY_RBAC_USER_LIST} = M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 1),

    Ext = [bondy_rbac_user:to_external(X) || X <- bondy_rbac_user:list(Uri)],
    wamp_message:result(M#call.request_id, #{}, [Ext]);

do_handle(#call{procedure_uri = ?BONDY_RBAC_USER_FIND} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_user:lookup(Uri, Username) of
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M);
        User ->
            Ext = bondy_rbac_user:to_external(User),
            wamp_message:result(M#call.request_id, #{}, [Ext])
    end;

do_handle(#call{procedure_uri = ?BONDY_RBAC_USER_CHANGE_PASSWORD} = M, Ctxt) ->
    %% L is either [Uri, Username, New] or [Uri, Username, New, Old]
    L = bondy_wamp_utils:validate_call_args(M, Ctxt, 3, 4),

    case erlang:apply(bondy_rbac_user, change_password, L) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

%% GROUPS ----------------------------------------------------------------------

do_handle(#call{procedure_uri = ?BONDY_RBAC_GROUP_ADD} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_group:add(Uri, bondy_rbac_group:new(Data)) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

do_handle(#call{procedure_uri = ?BONDY_RBAC_GROUP_DELETE} = M, Ctxt) ->
    [Uri, Name] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_group:remove(Uri, Name) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

do_handle(#call{procedure_uri = ?BONDY_RBAC_GROUP_LIST} = M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 1),
    Ext = [bondy_rbac_group:to_external(X) || X <- bondy_rbac_group:list(Uri)],
    wamp_message:result(M#call.request_id, #{}, [Ext]);

do_handle(#call{procedure_uri = ?BONDY_RBAC_GROUP_FIND} = M, Ctxt) ->
    [Uri, Name] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_group:lookup(Uri, Name) of
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M);
        Group ->
            Ext = bondy_rbac_group:to_external(Group),
            wamp_message:result(M#call.request_id, #{}, [Ext])
    end;

do_handle(#call{procedure_uri = ?BONDY_RBAC_GROUP_UPDATE} = M, Ctxt) ->
    [Uri, Name, Info] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_group:update(Uri, Name, Info) of
        {ok, Group} ->
            Ext = bondy_rbac_group:to_external(Group),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

%% SOURCES ---------------------------------------------------------------------

do_handle(#call{procedure_uri = ?BONDY_RBAC_SOURCE_ADD} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_rbac_source:add(Uri, bondy_rbac_source:new_assignment(Data)) of
        {ok, Source} ->
            Ext = bondy_rbac_source:to_external(Source),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

do_handle(#call{procedure_uri = ?BONDY_RBAC_SOURCE_DELETE} = M, Ctxt) ->
    [Uri, Username, CIDR] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),

    case bondy_rbac_source:remove(Uri, Username, CIDR) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

do_handle(#call{procedure_uri = ?BONDY_RBAC_SOURCE_LIST} = M, _) ->
    %% @TODO
    bondy_wamp_utils:no_such_procedure_error(M);

do_handle(#call{procedure_uri = ?BONDY_RBAC_SOURCE_FIND} = M, _) ->
    %% @TODO
    bondy_wamp_utils:no_such_procedure_error(M);

do_handle(#call{} = M, _) ->
    bondy_wamp_utils:no_such_procedure_error(M).
