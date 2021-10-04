# API Changes

## 0.9.0
### Conventions

* Procedures follow the pattern `bondy.[{subsystem}].{resource}.{verb|noun}` e.g. `bondy.realm.create` or `bondy.rbac.user.groups`
* Events follow the pattern `bondy.{resource}.{verb-in-past-term}` e.g. `bondy.realm.created`
* Errors follow the pattern `bondy.[{subsystem}].error.{reason}` e.g. `bondy.error.not_found` or `bondy.backup.error.operation_failed`

### NEW URIS
|MACRO|CURRENT|NEW|
|---|---|---|
|BONDY_BACKUP_CREATE|bondy.backup.create|bondy.backup.create|
|BONDY_BACKUP_RESTORE|bondy.backup.restore|bondy.backup.restore|
|BONDY_BACKUP_STATUS|bondy.backup.status|bondy.backup.status|
|BONDY_CLUSTER_CONNECTIONS|bondy.cluster.connections|bondy.cluster.connections|
|BONDY_CLUSTER_MEMBERS|-|bondy.cluster.members|
|BONDY_CLUSTER_PEER_INFO|-|bondy.cluster.member.info|
|BONDY_CLUSTER_STATUS|-|bondy.cluster.status|
|BONDY_HTTP_GATEWAY_LIST|bondy.api_gateway.list|bondy.http_gateway.api.list|
|BONDY_HTTP_GATEWAY_LOAD|bondy.api_gateway.load|bondy.http_gateway.api.load|
|BONDY_HTTP_GATEWAY_GET|bondy.api_gateway.lookup|bondy.http_gateway.api.get|
|BONDY_OAUTH2_CLIENT_ADD|bondy.api_gateway.add_client|bondy.oauth2.client.add|
|BONDY_OAUTH2_CLIENT_DELETE|bondy.api_gateway.delete_client|bondy.oauth2.client.delete|
|BONDY_OAUTH2_CLIENT_GET|bondy.api_gateway.fetch_client|bondy.oauth2.client.get|
|BONDY_OAUTH2_CLIENT_LIST|bondy.api_gateway.list_clients|bondy.oauth2.client.list|
|BONDY_OAUTH2_CLIENT_UPDATE|bondy.api_gateway.update_client|bondy.oauth2.client.update|
|BONDY_OAUTH2_RES_OWNER_ADD|bondy.api_gateway.add_resource_owner|bondy.oauth2.resource_owner.add|
|BONDY_OAUTH2_RES_OWNER_DELETE|bondy.api_gateway.delete_resource_owner|bondy.oauth2.resource_owner.delete|
|BONDY_OAUTH2_RES_OWNER_GET|bondy.api_gateway.fetch_resource_owner|bondy.oauth2.resource_owner.get|
|BONDY_OAUTH2_RES_OWNER_LIST|bondy.api_gateway.list_resource_owners|bondy.oauth2.resource_owner.list|
|BONDY_OAUTH2_RES_OWNER_UPDATE|bondy.api_gateway.update_resource_owner|bondy.oauth2.resource_owner.update|
|BONDY_OAUTH2_TOKEN_GET|-|bondy.oauth2.token.get|
|BONDY_OAUTH2_TOKEN_LOOKUP|bondy.oauth2.lookup_token|bondy.oauth2.token.lookup|
|BONDY_OAUTH2_TOKEN_REFRESH|-|bondy.oauth2.token.refresh|
|BONDY_OAUTH2_TOKEN_REVOKE_ALL|bondy.oauth2.revoke_tokens|bondy.oauth2.token.revoke_all|
|BONDY_OAUTH2_TOKEN_REVOKE|bondy.oauth2.revoke_token|bondy.oauth2.token.revoke|
|BONDY_RBAC_GROUP_ADD|bondy.security.add_group|bondy.rbac.group.add|
|BONDY_RBAC_GROUP_DELETE|bondy.security.delete_group|bondy.rbac.group.delete|
|BONDY_RBAC_GROUP_FIND|bondy.security.find_group|bondy.rbac.group.find|
|BONDY_RBAC_GROUP_LIST|bondy.security.list_groups|bondy.rbac.group.list|
|BONDY_RBAC_GROUP_UPDATE|bondy.security.update_group|bondy.rbac.group.update|
|BONDY_RBAC_SOURCE_ADD|bondy.security.add_source|bondy.rbac.source.add|
|BONDY_RBAC_SOURCE_DELETE|bondy.security.delete_source|bondy.rbac.source.delete|
|BONDY_RBAC_SOURCE_FIND|bondy.security.find_source|bondy.rbac.source.find|
|BONDY_RBAC_SOURCE_LIST|bondy.security.list_sources|bondy.rbac.source.list|
|BONDY_RBAC_USER_ADD|bondy.security.add_user|bondy.rbac.user.add|
|BONDY_RBAC_USER_CHANGE_PASSWORD|bondy.security.change_password|bondy.rbac.user.change_password|
|BONDY_RBAC_USER_DELETE|bondy.security.delete_user|bondy.rbac.user.delete|
|BONDY_RBAC_USER_FIND|bondy.security.find_user|bondy.rbac.user.find|
|BONDY_RBAC_USER_LIST|bondy.security.list_users|bondy.rbac.user.list|
|BONDY_RBAC_USER_UPDATE|bondy.security.update_user|bondy.rbac.user.update|
|BONDY_REALM_CREATE|bondy.security.create_realm|bondy.realm.create|
|BONDY_REALM_DELETE|bondy.security.delete_realm|bondy.realm.delete|
|BONDY_REALM_GET|-|bondy.realm.get|
|BONDY_REALM_LIST|bondy.security.list_realms|bondy.realm.list|
|BONDY_REALM_SECURITY_DISABLE|bondy.security.disable|bondy.realm.security.disable|
|BONDY_REALM_SECURITY_ENABLE|bondy.security.enable|bondy.realm.security.enable|
|BONDY_REALM_SECURITY_IS_ENABLED|bondy.security.is_enabled|bondy.realm.security.is_enabled|
|BONDY_REALM_SECURITY_STATUS|bondy.security.status|bondy.realm.security.status|
|BONDY_REALM_UPDATE|bondy.security.update_realm|bondy.realm.update|
|BONDY_REGISTRY_LIST|bondy.registry.list|bondy.wamp.registry.list|
|BONDY_REG_MATCH|bondy.registry.match|bondy.wamp.registry.match|
|BONDY_SUBSCRIPTION_LIST|bondy.subscription.list|bondy.wamp.subscription.list|
|BONDY_TELEMETRY_METRICS|bondy.telemetry.metrics|bondy.telemetry.metrics|
|BONDY_WAMP_CALLEE_GET|bondy.callee.get|-|
|BONDY_WAMP_CALLEE_LIST|bondy.callee.list|-|



### TOPIC URIS
|MACRO|CURRENT|NEW|
|---|---|---|
|BONDY_BACKUP_FINISHED|bondy.backup.finished|bondy.backup.finished|
|BONDY_BACKUP_RESTORE_FINISHED|bondy.backup.restore_finished|bondy.backup.restore_finished|
|BONDY_BACKUP_RESTORE_STARTED|bondy.backup.restore_started|bondy.backup.restore_started|
|BONDY_BACKUP_STARTED|bondy.backup.started|bondy.backup.started|
|BONDY_OAUTH2_CLIENT_ADDED|bondy.api_gateway.client_added|bondy.oauth2.client.added|
|BONDY_OAUTH2_CLIENT_DELETED|bondy.api_gateway.client_deleted|bondy.oauth2.client.deleted|
|BONDY_OAUTH2_CLIENT_UPDATED|bondy.api_gateway.client_updated|bondy.oauth2.client.updated|
|BONDY_OAUTH2_RES_OWNER_ADDED|bondy.api_gateway.resource_owner.added|bondy.oauth2.resource_owner.added|
|BONDY_OAUTH2_RES_OWNER_DELETED|bondy.api_gateway.resource_owner.deleted|bondy.oauth2.resource_owner.deleted|
|BONDY_OAUTH2_RES_OWNER_UPDATED|bondy.api_gateway.resource_owner.updated|bondy.oauth2.resource_owner.updated|
|BONDY_RBAC_GROUP_ADDED|bondy.security.group_added|bondy.rbac.group.added|
|BONDY_RBAC_GROUP_DELETED|bondy.security.group_deleted|bondy.rbac.group.deleted|
|BONDY_RBAC_GROUP_UPDATED|bondy.security.group_updated|bondy.rbac.group.updated|
|BONDY_RBAC_SOURCE_ADDED|bondy.security.source_added|bondy.rbac.source.added|
|BONDY_RBAC_SOURCE_DELETED|bondy.security.source_deleted|bondy.rbac.source.deleted|
|BONDY_RBAC_USER_ADDED|bondy.security.user_added|bondy.rbac.user.added|
|BONDY_RBAC_USER_DELETED|bondy.security.user_deleted|bondy.rbac.user.deleted|
|BONDY_RBAC_USER_LOGGED_IN|bondy.security.user_logged_in|bondy.rbac.user.logged_in|
|BONDY_RBAC_USER_PASSWORD_CHANGED|bondy.security.password_changed|bondy.rbac.user.password_changed|
|BONDY_RBAC_USER_UPDATED|bondy.security.user_updated|bondy.rbac.user.updated|
|BONDY_REALM_CREATED|bondy.security.realm_created|bondy.realm.created|
|BONDY_REALM_DELETED|bondy.security.realm_deleted|bondy.realm.deleted|


## GENERAL ERRORS

|MACRO|CURRENT|NEW|
|---|---|---|
|BONDY_ERROR_ALREADY_EXISTS|bondy.error.already_exists|bondy.error.already_exists|
|BONDY_ERROR_BAD_GATEWAY|bondy.error.bad_gateway|bondy.error.bad_gateway|
|BONDY_ERROR_HTTP_API_GATEWAY_INVALID_EXPR|bondy.error.http_gateway.invalid_expression|bondy.error.http_gateway.invalid_expression|
|BONDY_ERROR_INTERNAL|bondy.error.internal_error|bondy.error.internal_error|
|BONDY_ERROR_NOT_FOUND|bondy.error.not_found|bondy.error.not_found|
|BONDY_ERROR_NOT_IN_SESSION|bondy.error.not_in_session|bondy.error.not_in_session|
|BONDY_ERROR_OPERATION_FAILED|-|bondy.error.operation_failed|
|BONDY_ERROR_TIMEOUT|bondy.error.timeout|bondy.error.timeout|
|BONDY_ERROR_INCONSISTENCY_ERROR|bondy.error.inconsistency_error|bondy.error.inconsistency_error|
