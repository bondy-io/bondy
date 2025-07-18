%% =============================================================================
%%  bondy_wamp_api.erl -
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
-module(bondy_wamp_api).
-behaviour(bondy_wamp_callback).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

-export([handle_call/2]).
-export([resolve/1]).


%% =============================================================================
%% CALLBACKS
%% =============================================================================



-callback handle_call(
    Procedure :: uri(),
    M :: bondy_wamp_message:call(),
    Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined)
    }
    | {reply, wamp_result() | wamp_error()}.



%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_call(M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined)
    }
    | {reply, wamp_result() | wamp_error()}.

handle_call(#call{procedure_uri = Proc} = M, Ctxt) ->
    do_handle_call(resolve(Proc), M, Ctxt).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
-spec do_handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined)
    }
    | {reply, wamp_result() | wamp_error()}.

do_handle_call(<<"bondy.ping">>, M, _Ctxt) ->
    R = bondy_wamp_message:result(M#call.request_id, #{}, []),
    {reply, R};

do_handle_call(<<"bondy.backup.", _/binary>> = Proc, M, Ctxt) ->
    bondy_backup_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.cluster.", _/binary>> = Proc, M, Ctxt) ->
    bondy_cluster_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.grant.", _/binary>> = Proc, M, Ctxt) ->
    bondy_rbac_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.group.", _/binary>> = Proc, M, Ctxt) ->
    bondy_rbac_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.http_gateway.", _/binary>> = Proc, M, Ctxt) ->
    bondy_http_gateway_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.oauth2.", _/binary>> = Proc, M, Ctxt) ->
    bondy_oauth2_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.rbac.", _/binary>> = Proc, M, Ctxt) ->
    bondy_rbac_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.realm.", _/binary>> = Proc, M, Ctxt) ->
    bondy_realm_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.registration.", _/binary>> = Proc, M, Ctxt) ->
    bondy_registry_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.router.bridge.", _/binary>> = Proc, M, Ctxt) ->
    bondy_bridge_relay_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.source.", _/binary>> = Proc, M, Ctxt) ->
    bondy_rbac_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.subscription.", _/binary>> = Proc, M, Ctxt) ->
    bondy_registry_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.telemetry.", _/binary>> = Proc, M, Ctxt) ->
    bondy_telemetry_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.ticket.", _/binary>> = Proc, M, Ctxt) ->
    bondy_ticket_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.user.", _/binary>> = Proc, M, Ctxt) ->
    bondy_rbac_api:handle_call(Proc, M, Ctxt);

do_handle_call(<<"bondy.", _/binary>>, M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.



%% -----------------------------------------------------------------------------
%% @private
%% @doc Resolves old (next to be deprecated URI) into new URI
%% @end
%% -----------------------------------------------------------------------------
-spec resolve(Uri :: uri()) -> uri() | no_return().

resolve(<<"com.bondy.", _/binary>> = Uri) ->
    <<"com.", Rest/binary>> = Uri,
    resolve(Rest);
resolve(<<"com.leapsight.bondy.", _/binary>> = Uri) ->
    <<"com.leapsight.", Rest/binary>> = Uri,
    resolve(Rest);
resolve(?BONDY_HTTP_GATEWAY_GET_OLD) ->
    ?BONDY_HTTP_GATEWAY_GET;
resolve(?BONDY_HTTP_GATEWAY_LIST_OLD) ->
    ?BONDY_HTTP_GATEWAY_LIST;
resolve(?BONDY_HTTP_GATEWAY_LOAD_OLD) ->
    ?BONDY_HTTP_GATEWAY_LOAD;
resolve(?BONDY_OAUTH2_CLIENT_ADD_OLD) ->
    ?BONDY_OAUTH2_CLIENT_ADD;
resolve(?BONDY_OAUTH2_CLIENT_DELETE_OLD) ->
    ?BONDY_OAUTH2_CLIENT_DELETE;
resolve(?BONDY_OAUTH2_CLIENT_GET_OLD) ->
    ?BONDY_OAUTH2_CLIENT_GET;
resolve(?BONDY_OAUTH2_CLIENT_LIST_OLD) ->
    ?BONDY_OAUTH2_CLIENT_LIST;
resolve(?BONDY_OAUTH2_CLIENT_UPDATED_OLD) ->
    ?BONDY_OAUTH2_CLIENT_UPDATED;
resolve(?BONDY_OAUTH2_CLIENT_UPDATE_OLD) ->
    ?BONDY_OAUTH2_CLIENT_UPDATE;
resolve(?BONDY_OAUTH2_RES_OWNER_ADD_OLD) ->
    ?BONDY_OAUTH2_RES_OWNER_ADD;
resolve(?BONDY_OAUTH2_RES_OWNER_DELETE_OLD) ->
    ?BONDY_OAUTH2_RES_OWNER_DELETE;
resolve(?BONDY_OAUTH2_RES_OWNER_GET_OLD) ->
    ?BONDY_OAUTH2_RES_OWNER_GET;
resolve(?BONDY_OAUTH2_RES_OWNER_LIST_OLD) ->
    ?BONDY_OAUTH2_RES_OWNER_LIST;
resolve(?BONDY_OAUTH2_RES_OWNER_UPDATED_OLD) ->
    ?BONDY_OAUTH2_RES_OWNER_UPDATED;
resolve(?BONDY_OAUTH2_RES_OWNER_UPDATE_OLD) ->
    ?BONDY_OAUTH2_RES_OWNER_UPDATE;
resolve(?BONDY_OAUTH2_TOKEN_LOOKUP_OLD) ->
    ?BONDY_OAUTH2_TOKEN_LOOKUP;
resolve(?BONDY_OAUTH2_TOKEN_REVOKE_ALL_OLD) ->
    ?BONDY_OAUTH2_TOKEN_REVOKE_ALL;
resolve(?BONDY_OAUTH2_TOKEN_REVOKE_OLD) ->
    ?BONDY_OAUTH2_TOKEN_REVOKE;
resolve(?BONDY_GROUP_ADD_OLD) ->
    ?BONDY_GROUP_ADD;
resolve(?BONDY_GROUP_DELETE_OLD) ->
    ?BONDY_GROUP_DELETE;
resolve(?BONDY_GROUP_FIND_OLD) ->
    ?BONDY_GROUP_GET;
resolve(?BONDY_GROUP_LIST_OLD) ->
    ?BONDY_GROUP_LIST;
resolve(?BONDY_GROUP_UPDATE_OLD) ->
    ?BONDY_GROUP_UPDATE;
resolve(?BONDY_SOURCE_ADD_OLD) ->
    ?BONDY_SOURCE_ADD;
resolve(?BONDY_SOURCE_DELETE_OLD) ->
    ?BONDY_SOURCE_DELETE;
resolve(?BONDY_SOURCE_FIND_OLD) ->
    ?BONDY_SOURCE_GET;
resolve(?BONDY_SOURCE_LIST_OLD) ->
    ?BONDY_SOURCE_LIST;
resolve(?BONDY_USER_ADD_OLD) ->
    ?BONDY_USER_ADD;
resolve(?BONDY_USER_CHANGE_PASSWORD_OLD) ->
    ?BONDY_USER_CHANGE_PASSWORD;
resolve(?BONDY_USER_DELETE_OLD) ->
    ?BONDY_USER_DELETE;
resolve(?BONDY_USER_FIND_OLD) ->
    ?BONDY_USER_GET;
resolve(?BONDY_USER_LIST_OLD) ->
    ?BONDY_USER_LIST;
resolve(?BONDY_USER_UPDATE_OLD) ->
    ?BONDY_USER_UPDATE;
resolve(?BONDY_REALM_CREATE_OLD) ->
    ?BONDY_REALM_CREATE;
resolve(?BONDY_REALM_DELETE_OLD) ->
    ?BONDY_REALM_DELETE;
resolve(?BONDY_REALM_GET_OLD) ->
    ?BONDY_REALM_GET;
resolve(?BONDY_REALM_LIST_OLD) ->
    ?BONDY_REALM_LIST;
resolve(?BONDY_REALM_SECURITY_DISABLE_OLD) ->
    ?BONDY_REALM_SECURITY_DISABLE;
resolve(?BONDY_REALM_SECURITY_ENABLE_OLD) ->
    ?BONDY_REALM_SECURITY_ENABLE;
resolve(?BONDY_REALM_SECURITY_IS_ENABLED_OLD) ->
    ?BONDY_REALM_SECURITY_IS_ENABLED;
resolve(?BONDY_REALM_SECURITY_STATUS_OLD) ->
    ?BONDY_REALM_SECURITY_STATUS;
resolve(?BONDY_REALM_UPDATE_OLD) ->
    ?BONDY_REALM_UPDATE;
resolve(?BONDY_SUBSCRIPTION_LIST_OLD) ->
    ?BONDY_SUBSCRIPTION_LIST;
resolve(?BONDY_TELEMETRY_METRICS_OLD) ->
    ?BONDY_TELEMETRY_METRICS;
resolve(?BONDY_REGISTRY_CALLEE_LIST_OLD) ->
    ?BONDY_REGISTRATION_CALLEE_LIST;
resolve(Uri) ->
    Uri.



