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



%% =============================================================================
%% PROCEDURE URIS
%% =============================================================================


-define(BONDY_BACKUP_CREATE,            <<"bondy.backup.create">>).
-define(BONDY_BACKUP_RESTORE,           <<"bondy.backup.restore">>).
-define(BONDY_BACKUP_STATUS,            <<"bondy.backup.status">>).

-define(BONDY_CLUSTER_CONNECTIONS,      <<"bondy.cluster.connections">>).
-define(BONDY_CLUSTER_MEMBERS,          <<"bondy.cluster.members">>).
-define(BONDY_CLUSTER_PEER_INFO,        <<"bondy.cluster.peer_info">>).
-define(BONDY_CLUSTER_STATUS,           <<"bondy.cluster.status">>).

-define(BONDY_HTTP_GATEWAY_ADD,         <<"bondy.http_gateway.api.add">>).
-define(BONDY_HTTP_GATEWAY_GET,         <<"bondy.http_gateway.api.get">>).
-define(BONDY_HTTP_GATEWAY_LIST,        <<"bondy.http_gateway.api.list">>).
-define(BONDY_HTTP_GATEWAY_LOAD,        <<"bondy.http_gateway.api.load">>).
-define(BONDY_HTTP_GATEWAY_DELETE,      <<"bondy.http_gateway.api.delete">>).

-define(BONDY_OAUTH2_CLIENT_ADD,        <<"bondy.oauth2.client.add">>).
-define(BONDY_OAUTH2_CLIENT_DELETE,     <<"bondy.oauth2.client.delete">>).
-define(BONDY_OAUTH2_CLIENT_GET,        <<"bondy.oauth2.client.get">>).
-define(BONDY_OAUTH2_CLIENT_LIST,       <<"bondy.oauth2.client.list">>).
-define(BONDY_OAUTH2_CLIENT_UPDATE,     <<"bondy.oauth2.client.update">>).
-define(BONDY_OAUTH2_RES_OWNER_ADD,     <<"bondy.oauth2.resource_owner.add">>).
-define(BONDY_OAUTH2_RES_OWNER_DELETE,<<"bondy.oauth2.resource_owner.delete">>).
-define(BONDY_OAUTH2_RES_OWNER_GET,     <<"bondy.oauth2.resource_owner.get">>).
-define(BONDY_OAUTH2_RES_OWNER_LIST, <<"bondy.oauth2.resource_owners.list">>).
-define(BONDY_OAUTH2_RES_OWNER_UPDATE,  <<"bondy.oauth2.resource_owner.update">>).
-define(BONDY_OAUTH2_TOKEN_GET,         <<"bondy.oauth2.token.get">>).
-define(BONDY_OAUTH2_TOKEN_LOOKUP,      <<"bondy.oauth2.token.lookup">>).
-define(BONDY_OAUTH2_TOKEN_REVOKE,      <<"bondy.oauth2.token.revoke">>).
-define(BONDY_OAUTH2_TOKEN_REVOKE_ALL,  <<"bondy.oauth2.token.revoke_all">>).
-define(BONDY_OAUTH2_TOKEN_REFRESH,     <<"bondy.oauth2.token.refresh">>).

-define(BONDY_GROUP_ADD,           <<"bondy.group.add">>).
-define(BONDY_GROUP_DELETE,        <<"bondy.group.delete">>).
-define(BONDY_GROUP_GET,           <<"bondy.group.get">>).
-define(BONDY_GROUP_LIST,          <<"bondy.group.list">>).
-define(BONDY_GROUP_UPDATE,        <<"bondy.group.update">>).
-define(BONDY_SOURCE_ADD,          <<"bondy.source.add">>).
-define(BONDY_SOURCE_DELETE,       <<"bondy.source.delete">>).
-define(BONDY_SOURCE_GET,          <<"bondy.source.get">>).
-define(BONDY_SOURCE_LIST,         <<"bondy.source.list">>).
-define(BONDY_SOURCE_MATCH,        <<"bondy.source.match">>).
-define(BONDY_USER_ADD,            <<"bondy.user.add">>).
-define(BONDY_USER_CHANGE_PASSWORD, <<"bondy.user.change_password">>).
-define(BONDY_USER_DELETE,         <<"bondy.user.delete">>).
-define(BONDY_USER_GET,            <<"bondy.user.get">>).
-define(BONDY_USER_LIST,           <<"bondy.user.list">>).
-define(BONDY_USER_UPDATE,         <<"bondy.user.update">>).

-define(BONDY_REALM_CREATE,             <<"bondy.realm.create">>).
-define(BONDY_REALM_DELETE,             <<"bondy.realm.delete">>).
-define(BONDY_REALM_GET,                <<"bondy.realm.get">>).
-define(BONDY_REALM_LIST,               <<"bondy.realm.list">>).
-define(BONDY_REALM_SECURITY_DISABLE,   <<"bondy.realm.security.disable">>).
-define(BONDY_REALM_SECURITY_ENABLE,    <<"bondy.realm.security.enable">>).
-define(BONDY_REALM_SECURITY_IS_ENABLED, <<"bondy.realm.security.is_enabled">>).
-define(BONDY_REALM_SECURITY_STATUS,    <<"bondy.realm.security.status">>).
-define(BONDY_REALM_UPDATE,             <<"bondy.realm.update">>).

-define(BONDY_REGISTRY_LIST,            <<"bondy.registry.list">>).
-define(BONDY_REG_MATCH,                <<"bondy.registry.match">>).
-define(BONDY_SUBSCRIPTION_LIST,        <<"bondy.subscription.list">>).
-define(BONDY_REGISTRATION_LIST,        <<"bondy.registration.list">>).
-define(BONDY_TELEMETRY_METRICS,        <<"bondy.telemetry.metrics">>).
-define(BONDY_WAMP_CALLEE_GET,          <<"bondy.wamp.callee.get">>).
-define(BONDY_WAMP_CALLEE_LIST,         <<"bondy.wamp.callee.list">>).


%% =============================================================================
%% TOPIC URIS
%% =============================================================================


-define(BONDY_BACKUP_FAILED,            <<"bondy.backup.failed">>).
-define(BONDY_BACKUP_FINISHED,          <<"bondy.backup.finished">>).
-define(BONDY_BACKUP_RESTORE_FAILED,    <<"bondy.backup.restore_failed">>).
-define(BONDY_BACKUP_RESTORE_FINISHED,  <<"bondy.backup.restore_finished">>).
-define(BONDY_BACKUP_RESTORE_STARTED,   <<"bondy.backup.restore_started">>).
-define(BONDY_BACKUP_STARTED,           <<"bondy.backup.started">>).
-define(BONDY_OAUTH2_CLIENT_ADDED,      <<"bondy.oauth2.client.added">>).
-define(BONDY_OAUTH2_CLIENT_DELETED,    <<"bondy.oauth2.client.deleted">>).
-define(BONDY_OAUTH2_CLIENT_UPDATED,    <<"bondy.oauth2.client.updated">>).
-define(BONDY_OAUTH2_RES_OWNER_ADDED, <<"bondy.oauth2.resource_owner.added">>).
-define(BONDY_OAUTH2_RES_OWNER_DELETED, <<"bondy.oauth2.resource_owner.deleted">>).
-define(BONDY_OAUTH2_RES_OWNER_UPDATED, <<"bondy.oauth2.resource_owner.updated">>).
-define(BONDY_GROUP_ADDED,         <<"bondy.group.added">>).
-define(BONDY_GROUP_DELETED,       <<"bondy.group.deleted">>).
-define(BONDY_GROUP_UPDATED,       <<"bondy.group.updated">>).
-define(BONDY_SOURCE_ADDED,        <<"bondy.source.added">>).
-define(BONDY_SOURCE_DELETED,      <<"bondy.source.deleted">>).
-define(BONDY_USER_ADDED,          <<"bondy.user.added">>).
-define(BONDY_USER_DELETED,        <<"bondy.user.deleted">>).
-define(BONDY_USER_LOGGED_IN,      <<"bondy.user.logged_in">>).
-define(BONDY_USER_PASSWORD_CHANGED, <<"bondy.user.password_changed">>).
-define(BONDY_USER_UPDATED,        <<"bondy.user.updated">>).
-define(BONDY_REALM_CREATED,            <<"bondy.realm.created">>).
-define(BONDY_REALM_DELETED,          <<"bondy.realm.deleted">>).


%% =============================================================================
%% ERROR URIS
%% =============================================================================



-define(BONDY_ERROR_ALREADY_EXISTS, <<"bondy.error.already_exists">>).
-define(BONDY_ERROR_BAD_GATEWAY, <<"bondy.error.bad_gateway">>).
-define(BONDY_ERROR_HTTP_API_GATEWAY_INVALID_EXPR, <<"bondy.error.http_gateway.invalid_expression">>).
-define(BONDY_ERROR_INTERNAL, <<"bondy.error.internal_error">>).
-define(BONDY_ERROR_NOT_FOUND, <<"bondy.error.not_found">>).
-define(BONDY_ERROR_NOT_IN_SESSION, <<"bondy.error.not_in_session">>).
-define(BONDY_ERROR_TIMEOUT, <<"bondy.error.timeout">>).
-define(BONDY_ERROR_INCONSISTENCY_ERROR, <<"bondy.error.inconsistency_error">>).



%% =============================================================================
%% TO BE DEPRECATED PROCEDURES
%% =============================================================================


-define(BONDY_HTTP_GATEWAY_GET_OLD, <<"bondy.api_gateway.lookup">>).
-define(BONDY_HTTP_GATEWAY_LIST_OLD, <<"bondy.api_gateway.list">>).
-define(BONDY_HTTP_GATEWAY_LOAD_OLD, <<"bondy.api_gateway.load">>).
-define(BONDY_OAUTH2_CLIENT_ADD_OLD, <<"bondy.api_gateway.add_client">>).
-define(BONDY_OAUTH2_CLIENT_DELETE_OLD, <<"bondy.api_gateway.delete_client">>).
-define(BONDY_OAUTH2_CLIENT_GET_OLD, <<"bondy.api_gateway.fetch_client">>).
-define(BONDY_OAUTH2_CLIENT_LIST_OLD, <<"bondy.api_gateway.list_clients">>).
-define(BONDY_OAUTH2_CLIENT_UPDATED_OLD, <<"bondy.api_gateway.client_updated">>).
-define(BONDY_OAUTH2_CLIENT_UPDATE_OLD, <<"bondy.api_gateway.update_client">>).
-define(BONDY_OAUTH2_RES_OWNER_ADD_OLD, <<"bondy.api_gateway.add_resource_owner">>).
-define(BONDY_OAUTH2_RES_OWNER_DELETE_OLD, <<"bondy.api_gateway.delete_resource_owner">>).
-define(BONDY_OAUTH2_RES_OWNER_GET_OLD, <<"bondy.api_gateway.fetch_resource_owner">>).
-define(BONDY_OAUTH2_RES_OWNER_LIST_OLD, <<"bondy.api_gateway.list_resource_owners">>).
-define(BONDY_OAUTH2_RES_OWNER_UPDATED_OLD, <<"bondy.api_gateway.resource_owner_updated">>).
-define(BONDY_OAUTH2_RES_OWNER_UPDATE_OLD, <<"bondy.api_gateway.update_resource_owner">>).
-define(BONDY_OAUTH2_TOKEN_LOOKUP_OLD, <<"bondy.oauth2.lookup_token">>).
-define(BONDY_OAUTH2_TOKEN_REVOKE_ALL_OLD, <<"bondy.oauth2.revoke_tokens">>).
-define(BONDY_OAUTH2_TOKEN_REVOKE_OLD, <<"bondy.oauth2.revoke_token">>).
-define(BONDY_GROUP_ADD_OLD, <<"bondy.security.add_group">>).
-define(BONDY_GROUP_DELETE_OLD, <<"bondy.security.delete_group">>).
-define(BONDY_GROUP_FIND_OLD, <<"bondy.security.find_group">>).
-define(BONDY_GROUP_LIST_OLD, <<"bondy.security.list_groups">>).
-define(BONDY_GROUP_UPDATE_OLD, <<"bondy.security.update_group">>).
-define(BONDY_SOURCE_ADD_OLD, <<"bondy.security.add_source">>).
-define(BONDY_SOURCE_DELETE_OLD, <<"bondy.security.delete_source">>).
-define(BONDY_SOURCE_FIND_OLD, <<"bondy.security.find_source">>).
-define(BONDY_SOURCE_LIST_OLD, <<"bondy.security.list_sources">>).
-define(BONDY_USER_ADD_OLD, <<"bondy.security.add_user">>).
-define(BONDY_USER_CHANGE_PASSWORD_OLD, <<"bondy.security.change_password">>).
-define(BONDY_USER_DELETE_OLD, <<"bondy.security.delete_user">>).
-define(BONDY_USER_FIND_OLD, <<"bondy.security.find_user">>).
-define(BONDY_USER_LIST_OLD, <<"bondy.security.list_users">>).
-define(BONDY_USER_UPDATE_OLD, <<"bondy.security.update_user">>).
-define(BONDY_REALM_CREATE_OLD, <<"bondy.security.create_realm">>).
-define(BONDY_REALM_DELETE_OLD, <<"bondy.security.delete_realm">>).
-define(BONDY_REALM_GET_OLD, <<"bondy.realm.get">>).
-define(BONDY_REALM_LIST_OLD, <<"bondy.security.list_realms">>).
-define(BONDY_REALM_SECURITY_DISABLE_OLD, <<"bondy.security.disable">>).
-define(BONDY_REALM_SECURITY_ENABLE_OLD, <<"bondy.security.enable">>).
-define(BONDY_REALM_SECURITY_IS_ENABLED_OLD, <<"bondy.security.is_enabled">>).
-define(BONDY_REALM_SECURITY_STATUS_OLD, <<"bondy.security.status">>).
-define(BONDY_REALM_UPDATE_OLD, <<"bondy.security.update_realm">>).
-define(BONDY_REGISTRY_LIST_OLD, <<"bondy.registry.list">>).
-define(BONDY_REG_MATCH_OLD, <<"bondy.registry.match">>).
-define(BONDY_SUBSCRIPTION_LIST_OLD, <<"bondy.subscription.list">>).
-define(BONDY_TELEMETRY_METRICS_OLD, <<"bondy.telemetry.metrics">>).
-define(BONDY_WAMP_CALLEE_GET_OLD, <<"bondy.callee.get">>).
-define(BONDY_WAMP_CALLEE_LIST_OLD, <<"bondy.callee.list">>).




%% =============================================================================
%% TO BE DEPRECATED TOPICS
%% =============================================================================


-define(BONDY_OAUTH2_CLIENT_ADDED_OLD,    <<"bondy.api_gateway.client_added">>).
-define(BONDY_OAUTH2_CLIENT_DELETED_OLD,  <<"bondy.api_gateway.client_deleted">>).
-define(BONDY_OAUTH2_RES_OWNER_ADDED_OLD, <<"bondy.api_gateway.resource_owner_added">>).
-define(BONDY_OAUTH2_RES_OWNER_DELETED_OLD,   <<"bondy.api_gateway.resource_owner_deleted">>).
-define(BONDY_GROUP_ADDED_OLD,          <<"bondy.security.group_added">>).
-define(BONDY_GROUP_DELETED_OLD,        <<"bondy.security.group_deleted">>).
-define(BONDY_GROUP_UPDATED_OLD,        <<"bondy.security.group_updated">>).
-define(BONDY_SOURCE_ADDED_OLD,         <<"bondy.security.source_added">>).
-define(BONDY_SOURCE_DELETED_OLD,       <<"bondy.security.source_deleted">>).
-define(BONDY_USER_ADDED_OLD,           <<"bondy.security.user_added">>).
-define(BONDY_USER_DELETED_OLD,         <<"bondy.security.user_deleted">>).
-define(BONDY_USER_LOGGED_IN_OLD,       <<"bondy.security.user_logged_in">>).
-define(BONDY_USER_PASSWORD_CHANGED_OLD,     <<"bondy.security.password_changed">>).
-define(BONDY_USER_UPDATED_OLD,         <<"bondy.security.user_updated">>).
-define(BONDY_REALM_CREATED_OLD,            <<"bondy.security.realm_created">>).
-define(BONDY_REALM_DELETED_OLD,          <<"bondy.security.realm_deleted">>).