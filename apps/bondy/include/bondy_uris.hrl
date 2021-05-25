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


-define(BONDY_OAUTH2_ADD_CLIENT,      <<"bondy.api_gateway.add_client">>).
-define(BONDY_OAUTH2_ADD_RES_OWNER,   <<"bondy.api_gateway.add_resource_owner">>).
-define(BONDY_OAUTH2_CLIENT_ADDED,    <<"bondy.api_gateway.client_added">>).
-define(BONDY_OAUTH2_CLIENT_DELETED,  <<"bondy.api_gateway.client_deleted">>).
-define(BONDY_OAUTH2_CLIENT_UPDATED,  <<"bondy.api_gateway.client_updated">>).
-define(BONDY_OAUTH2_DELETE_CLIENT,   <<"bondy.api_gateway.delete_client">>).
-define(BONDY_OAUTH2_DELETE_RES_OWNER,     <<"bondy.api_gateway.delete_resource_owner">>).
-define(BONDY_OAUTH2_FETCH_CLIENT,     <<"bondy.api_gateway.fetch_client">>).
-define(BONDY_OAUTH2_FETCH_RES_OWNER, <<"bondy.api_gateway.fetch_resource_owner">>).
-define(BONDY_API_GATEWAY_LIST,              <<"bondy.api_gateway.list">>).
-define(BONDY_OAUTH2_LIST_CLIENTS,     <<"bondy.api_gateway.list_clients">>).
-define(BONDY_OAUTH2_LIST_RES_OWNERS, <<"bondy.api_gateway.list_resource_owners">>).
-define(BONDY_API_GATEWAY_LOAD,             <<"bondy.api_gateway.load">>).
-define(BONDY_API_GATEWAY_LOOKUP,            <<"bondy.api_gateway.lookup">>).
-define(BONDY_OAUTH2_RES_OWNER_ADDED, <<"bondy.api_gateway.resource_owner_added">>).
-define(BONDY_OAUTH2_RES_OWNER_DELETED,   <<"bondy.api_gateway.resource_owner_deleted">>).
-define(BONDY_OAUTH2_RES_OWNER_UPDATED,   <<"bondy.api_gateway.resource_owner_updated">>).
-define(BONDY_OAUTH2_UPDATE_CLIENT,   <<"bondy.api_gateway.update_client">>).
-define(BONDY_OAUTH2_UPDATE_RES_OWNER,     <<"bondy.api_gateway.update_resource_owner">>).
-define(BONDY_BACKUP_CREATE,            <<"bondy.backup.create">>).
-define(BONDY_BACKUP_FINISHED,          <<"bondy.backup.finished">>).
-define(BONDY_BACKUP_RESTORE,           <<"bondy.backup.restore">>).
-define(BONDY_BACKUP_RESTORE_FINISHED,  <<"bondy.backup.restore_finished">>).
-define(BONDY_BACKUP_RESTORE_STARTED,   <<"bondy.backup.restore_started">>).
-define(BONDY_BACKUP_STARTED,           <<"bondy.backup.started">>).
-define(BONDY_BACKUP_STATUS,            <<"bondy.backup.status">>).
-define(BONDY_CALLEE_GET,               <<"bondy.callee.get">>).
-define(BONDY_CALLEE_LIST,              <<"bondy.callee.list">>).
-define(BONDY_RBAC_USER_CHANGE_PASSWORD,          <<"bondy.security.change_password">>).
-define(BONDY_CLUSTER_CONNECTIONS,      <<"bondy.cluster.connections">>).
-define(BONDY_CLUSTER_MEMBERS,          <<"bondy.cluster.members">>).
-define(BONDY_CLUSTER_PEER_INFO,        <<"bondy.cluster.peer_info">>).
-define(BONDY_CLUSTER_STATUS,           <<"bondy.cluster.status">>).
-define(BONDY_ERROR_ALREADY_EXISTS, <<"bondy.error.already_exists">>).
-define(BONDY_ERROR_BACKUP_FAILED,      <<"bondy.error.backup_failed">>).
-define(BONDY_ERROR_BACKUP_RESTORE_FAILED,  <<"bondy.error.backup_restore_failed">>).
-define(BONDY_ERROR_BAD_GATEWAY, <<"bondy.error.bad_gateway">>).
-define(BONDY_ERROR_INTERNAL, <<"bondy.error.internal_error">>).
-define(BONDY_ERROR_NOT_FOUND, <<"bondy.error.not_found">>).
-define(BONDY_ERROR_NOT_IN_SESSION, <<"bondy.error.not_in_session">>).
-define(BONDY_ERROR_TIMEOUT, <<"bondy.error.timeout">>).
-define(BONDY_INCONSISTENCY_ERROR, <<"bondy.error.inconsistency_error">>).
-define(BONDY_REALM_CREATE,             <<"bondy.realm.create">>).
-define(BONDY_REALM_CREATED,            <<"bondy.realm.created">>).
-define(BONDY_REALM_CREATE_OLD,           <<"bondy.security.create_realm">>).
-define(BONDY_REALM_DELETE,             <<"bondy.realm.delete">>).
-define(BONDY_REALM_DELETED_OLD,          <<"bondy.security.realm_deleted">>).
-define(BONDY_REALM_DELETE_OLD,           <<"bondy.security.delete_realm">>).
-define(BONDY_REALM_LIST,               <<"bondy.realm.list">>).
-define(BONDY_REALM_LIST_OLD,            <<"bondy.security.list_realms">>).
-define(BONDY_REGISTRY_LIST,            <<"bondy.registry.list">>).
-define(BONDY_REG_MATCH,                <<"bondy.registry.match">>).
-define(BONDY_API_GATEWAY_ERROR_INVALID_EXPR, <<"bondy.error.api_gateway.invalid_expression">>).
-define(BONDY_SECURITY_DISABLE,         <<"bondy.security.disable">>).
-define(BONDY_SECURITY_ENABLE,          <<"bondy.security.enable">>).
-define(BONDY_SECURITY_IS_ENABLED,      <<"bondy.security.is_enabled">>).
-define(BONDY_SECURITY_STATUS,          <<"bondy.security.status">>).
-define(BONDY_RBAC_GROUP_ADD,            <<"bondy.security.add_group">>).
-define(BONDY_RBAC_SOURCE_ADD,           <<"bondy.security.add_source">>).
-define(BONDY_RBAC_USER_ADD,             <<"bondy.security.add_user">>).
-define(BONDY_RBAC_GROUP_DELETE,         <<"bondy.security.delete_group">>).
-define(BONDY_RBAC_SOURCE_DELETE,        <<"bondy.security.delete_source">>).
-define(BONDY_RBAC_USER_DELETE,          <<"bondy.security.delete_user">>).
-define(BONDY_RBAC_GROUP_FIND,           <<"bondy.security.find_group">>).
-define(BONDY_RBAC_SOURCE_FIND,          <<"bondy.security.find_source">>).
-define(BONDY_RBAC_USER_FIND,            <<"bondy.security.find_user">>).
-define(BONDY_RBAC_GROUP_ADDED,          <<"bondy.security.group_added">>).
-define(BONDY_RBAC_GROUP_DELETED,        <<"bondy.security.group_deleted">>).
-define(BONDY_RBAC_GROUP_UPDATED,        <<"bondy.security.group_updated">>).
-define(BONDY_RBAC_GROUP_LIST,          <<"bondy.security.list_groups">>).
-define(BONDY_RBAC_SOURCE_LIST,         <<"bondy.security.list_sources">>).
-define(BONDY_RBAC_USER_LIST,           <<"bondy.security.list_users">>).
-define(BONDY_RBAC_USER_PASSWORD_CHANGED,     <<"bondy.security.password_changed">>).
-define(BONDY_RBAC_SOURCE_ADDED,         <<"bondy.security.source_added">>).
-define(BONDY_RBAC_SOURCE_DELETED,       <<"bondy.security.source_deleted">>).
-define(BONDY_RBAC_GROUP_UPDATE,         <<"bondy.security.update_group">>).
-define(BONDY_RBAC_USER_UPDATE,          <<"bondy.security.update_user">>).
-define(BONDY_RBAC_USER_ADDED,           <<"bondy.security.user_added">>).
-define(BONDY_RBAC_USER_DELETED,         <<"bondy.security.user_deleted">>).
-define(BONDY_RBAC_USER_LOGGED_IN,       <<"bondy.security.user_logged_in">>).
-define(BONDY_RBAC_USER_UPDATED,         <<"bondy.security.user_updated">>).
-define(BONDY_ERROR_SESSION_ALREADY_EXISTS, <<"bondy.error.session_already_exists">>).
-define(BONDY_SUBS_LIST,                <<"bondy.subscription.list">>).
-define(BONDY_TELEMETRY_METRICS,        <<"bondy.telemetry.metrics">>).
-define(BONDY_REALM_UPDATE,             <<"bondy.security.update_realm">>).
-define(BONDY_OAUTH2_LOOKUP_TOKEN, <<"bondy.oauth2.lookup_token">>).
-define(BONDY_OAUTH2_REVOKE_TOKEN, <<"bondy.oauth2.revoke_token">>).
-define(BONDY_OAUTH2_REVOKE_TOKENS, <<"bondy.oauth2.revoke_tokens">>).
