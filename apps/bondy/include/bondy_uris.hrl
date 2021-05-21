%% =============================================================================
%%  bondy_wamp_api.hrl -
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


-define(BONDY_ALREADY_EXISTS_ERROR, <<"bondy.error.already_exists">>).
-define(BONDY_INTERNAL_ERROR, <<"bondy.error.internal_error">>).
-define(BONDY_API_GATEWAY_ADD_CLIENT,      <<"bondy.api_gateway.add_client">>).
-define(BONDY_API_GATEWAY_ADD_RES_OWNER,   <<"bondy.api_gateway.add_resource_owner">>).
-define(BONDY_API_GATEWAY_CLIENT_ADDED,    <<"bondy.api_gateway.client_added">>).
-define(BONDY_API_GATEWAY_CLIENT_DELETED,  <<"bondy.api_gateway.client_deleted">>).
-define(BONDY_API_GATEWAY_CLIENT_UPDATED,  <<"bondy.api_gateway.client_updated">>).
-define(BONDY_API_GATEWAY_DELETE_CLIENT,   <<"bondy.api_gateway.delete_client">>).
-define(BONDY_API_GATEWAY_DELETE_RES_OWNER,     <<"bondy.api_gateway.delete_resource_owner">>).
-define(BONDY_API_GATEWAY_FETCH_CLIENT,     <<"bondy.api_gateway.fetch_client">>).
-define(BONDY_API_GATEWAY_FETCH_RES_OWNER, <<"bondy.api_gateway.fetch_resource_owner">>).
-define(BONDY_API_GATEWAY_LIST,              <<"bondy.api_gateway.list">>).
-define(BONDY_API_GATEWAY_LIST_CLIENTS,     <<"bondy.api_gateway.list_clients">>).
-define(BONDY_API_GATEWAY_LIST_RES_OWNERS, <<"bondy.api_gateway.list_resource_owners">>).
-define(BONDY_API_GATEWAY_LOAD,             <<"bondy.api_gateway.load">>).
-define(BONDY_API_GATEWAY_LOOKUP,            <<"bondy.api_gateway.lookup">>).
-define(BONDY_API_GATEWAY_RES_OWNER_ADDED, <<"bondy.api_gateway.resource_owner_added">>).
-define(BONDY_API_GATEWAY_RES_OWNER_DELETED,   <<"bondy.api_gateway.resource_owner_deleted">>).
-define(BONDY_API_GATEWAY_RES_OWNER_UPDATED,   <<"bondy.api_gateway.resource_owner_updated">>).
-define(BONDY_API_GATEWAY_UPDATE_CLIENT,   <<"bondy.api_gateway.update_client">>).
-define(BONDY_API_GATEWAY_UPDATE_RES_OWNER,     <<"bondy.api_gateway.update_resource_owner">>).
-define(BONDY_BACKUP_CREATE,            <<"bondy.backup.create">>).
-define(BONDY_BACKUP_FINISHED,          <<"bondy.backup.finished">>).
-define(BONDY_BACKUP_RESTORE,           <<"bondy.backup.restore">>).
-define(BONDY_BACKUP_RESTORE_FINISHED,  <<"bondy.backup.restored_finished">>).
-define(BONDY_BACKUP_RESTORE_STARTED,   <<"bondy.backup.restored_started">>).
-define(BONDY_BACKUP_STARTED,           <<"bondy.backup.started">>).
-define(BONDY_BACKUP_STATUS,            <<"bondy.backup.status">>).
-define(BONDY_BAD_GATEWAY_ERROR, <<"bondy.error.bad_gateway">>).
-define(BONDY_CALLEE_GET,               <<"bondy.callee.get">>).
-define(BONDY_CALLEE_LIST,              <<"bondy.callee.list">>).
-define(BONDY_CHANGE_PASSWORD,          <<"bondy.security.change_password">>).
-define(BONDY_CLUSTER_CONNECTIONS,      <<"bondy.cluster.connections">>).
-define(BONDY_CLUSTER_MEMBERS,          <<"bondy.cluster.members">>).
-define(BONDY_CLUSTER_PEER_INFO,        <<"bondy.cluster.peer_info">>).
-define(BONDY_CLUSTER_STATUS,           <<"bondy.cluster.status">>).
-define(BONDY_ERROR_BACKUP_FAILED,      <<"bondy.error.backup_failed">>).
-define(BONDY_ERROR_BACKUP_RESTORE_FAILED,  <<"bondy.error.backup_restore_failed">>).
-define(BONDY_ERROR_NOT_IN_SESSION, <<"bondy.error.not_in_session">>).
-define(BONDY_ERROR_TIMEOUT, <<"bondy.error.timeout">>).
-define(BONDY_INCONSISTENCY_ERROR, <<"bondy.error.unknown_error">>).
-define(BONDY_NOT_FOUND_ERROR, <<"bondy.error.not_found">>).
-define(BONDY_REALM_CREATED,            <<"bondy.realm.created">>).
-define(BONDY_REALM_CREATE,             <<"bondy.realm.create">>).
-define(BONDY_REALM_DELETE,             <<"bondy.realm.delete">>).
-define(BONDY_REALM_LIST,               <<"bondy.realm.list">>).
-define(BONDY_REGISTRY_LIST,            <<"bondy.registry.list">>).
-define(BONDY_REG_MATCH,                <<"bondy.registry.match">>).
-define(BONDY_REST_GATEWAY_INVALID_EXPR_ERROR, <<"bondy.error.api_gateway.invalid_expression">>).
-define(BONDY_SECURITY_DISABLE,         <<"bondy.security.disable">>).
-define(BONDY_SECURITY_ENABLE,          <<"bondy.security.enable">>).
-define(BONDY_SECURITY_IS_ENABLED,      <<"bondy.security.is_enabled">>).
-define(BONDY_SECURITY_STATUS,          <<"bondy.security.status">>).
-define(BONDY_SEC_ADD_GROUP,            <<"bondy.security.add_group">>).
-define(BONDY_SEC_ADD_SOURCE,           <<"bondy.security.add_source">>).
-define(BONDY_SEC_ADD_USER,             <<"bondy.security.add_user">>).
-define(BONDY_SEC_DELETE_GROUP,         <<"bondy.security.delete_group">>).
-define(BONDY_SEC_DELETE_SOURCE,        <<"bondy.security.delete_source">>).
-define(BONDY_SEC_DELETE_USER,          <<"bondy.security.delete_user">>).
-define(BONDY_SEC_FIND_GROUP,           <<"bondy.security.find_group">>).
-define(BONDY_SEC_FIND_SOURCE,          <<"bondy.security.find_source">>).
-define(BONDY_SEC_FIND_USER,            <<"bondy.security.find_user">>).
-define(BONDY_SEC_GROUP_ADDED,          <<"bondy.security.group_added">>).
-define(BONDY_SEC_GROUP_DELETED,        <<"bondy.security.group_deleted">>).
-define(BONDY_SEC_GROUP_UPDATED,        <<"bondy.security.group_updated">>).
-define(BONDY_SEC_LIST_GROUPS,          <<"bondy.security.list_groups">>).
-define(BONDY_SEC_LIST_SOURCES,         <<"bondy.security.list_sources">>).
-define(BONDY_SEC_LIST_USERS,           <<"bondy.security.list_users">>).
-define(BONDY_SEC_PASSWORD_CHANGED,     <<"bondy.security.password_changed">>).
-define(BONDY_SEC_SOURCE_ADDED,         <<"bondy.security.source_added">>).
-define(BONDY_SEC_SOURCE_DELETED,       <<"bondy.security.source_deleted">>).
-define(BONDY_SEC_UPDATE_GROUP,         <<"bondy.security.update_group">>).
-define(BONDY_SEC_UPDATE_USER,          <<"bondy.security.update_user">>).
-define(BONDY_SEC_USER_ADDED,           <<"bondy.security.user_added">>).
-define(BONDY_SEC_USER_DELETED,         <<"bondy.security.user_deleted">>).
-define(BONDY_SEC_USER_LOGGED_IN,       <<"bondy.security.user_logged_in">>).
-define(BONDY_SEC_USER_UPDATED,         <<"bondy.security.user_updated">>).
-define(BONDY_SESSION_ALREADY_EXISTS, <<"bondy.error.session_already_exists">>).
-define(BONDY_SUBS_LIST,                <<"bondy.subscription.list">>).
-define(BONDY_TELEMETRY_METRICS,        <<"bondy.telemetry.metrics">>).
-define(BONDY_UPDATE_REALM,             <<"bondy.security.update_realm">>).
-define(D_BONDY_CREATE_REALM,           <<"bondy.security.create_realm">>).
-define(D_BONDY_DELETE_REALM,           <<"bondy.security.delete_realm">>).
-define(D_BONDY_LIST_REALMS,            <<"bondy.security.list_realms">>).
-define(D_BONDY_REALM_DELETED,          <<"bondy.security.realm_deleted">>).
-define(LOOKUP_TOKEN, <<"bondy.oauth2.lookup_token">>).
-define(REVOKE_TOKEN, <<"bondy.oauth2.revoke_token">>).
-define(REVOKE_TOKENS, <<"bondy.oauth2.revoke_tokens">>).
