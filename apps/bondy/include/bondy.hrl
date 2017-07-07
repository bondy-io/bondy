
-define(BONDY_VERSION_STRING, <<"BONDY-0.0.2">>).
-define(BONDY_REALM_URI, <<"com.leapsight.bondy">>).

-define(BONDY_PEER_CALL, '$bondy_call').
-define(BONDY_PEER_ACK, '$bondy_ack').


%% =============================================================================
%% FEATURES
%% =============================================================================




-define(DEALER_FEATURES, #{
    progressive_call_results => false,
    progressive_calls => false,
    call_timeout => true,
    call_canceling => false,
    caller_identification => false,
    call_trustlevels => false,
    registration_meta_api => false,
    registration_revocation => false,
    session_meta_api => false,
    pattern_based_registration => true,
    procedure_reflection => false,
    shared_registration => true,
    sharded_registration => false
}).

-define(CALLEE_FEATURES, #{
    progressive_call_results => false,
    progressive_calls => false,
    call_timeout => true,
    call_canceling => false,
    caller_identification => false,
    call_trustlevels => false,
    registration_revocation => false,
    session_meta_api => false,
    pattern_based_registration => true,
    shared_registration => true,
    sharded_registration => false
}).

-define(CALLER_FEATURES, #{
    progressive_call_results => false,
    progressive_calls => false,
    call_timeout => false,
    call_canceling => false,
    caller_identification => false
}).

-define(BROKER_FEATURES, #{
    event_history => false,
    pattern_based_subscription => true,
    publication_trustlevels => false,
    publisher_exclusion => false,
    publisher_identification => false,
    session_meta_api => false,
    sharded_subscription => false,
    subscriber_blackwhite_listing => false,
    subscription_meta_api => false,
    topic_reflection => false
}).

-define(SUBSCRIBER_FEATURES, #{
    event_history => false,
    pattern_based_subscription => true,
    publication_trustlevels => false,
    publisher_identification => false,
    sharded_subscription => false
}).

-define(PUBLISHER_FEATURES, #{
    publisher_exclusion => false,
    publisher_identification => false,
    subscriber_blackwhite_listing => false
}).





%% =============================================================================
%% META EVENTS & PROCEDURES
%% =============================================================================

% USER
-define(BONDY_USER_ADD, <<"com.leapsight.bondy.security.add_user">>).
-define(BONDY_USER_DELETE, <<"com.leapsight.bondy.security.delete_user">>).
-define(BONDY_USER_LIST, <<"com.leapsight.bondy.security.list_users">>).
-define(BONDY_USER_LOOKUP, <<"com.leapsight.bondy.security.get_user">>).
-define(BONDY_USER_UPDATE, <<"com.leapsight.bondy.security.update_user">>).
-define(BONDY_USER_CHANGE_PASSWORD, <<"com.leapsight.bondy.security.users.change_password">>).

-define(BONDY_USER_ON_ADD, <<"com.leapsight.bondy.security.users.on_add">>).
-define(BONDY_USER_ON_DELETE, <<"com.leapsight.bondy.security.users.on_delete">>).
-define(BONDY_USER_ON_UPDATE, <<"com.leapsight.bondy.security.users.on_update">>).


% GROUP
-define(BONDY_GROUP_ADD, <<"com.leapsight.bondy.security.groups.add">>).
-define(BONDY_GROUP_DELETE, <<"com.leapsight.bondy.security.groups.delete">>).
-define(BONDY_GROUP_LIST, <<"com.leapsight.bondy.security.groups.list">>).
-define(BONDY_GROUP_LOOKUP, <<"com.leapsight.bondy.security.groups.get">>).
-define(BONDY_GROUP_UPDATE, <<"com.leapsight.bondy.security.groups.update">>).

-define(BONDY_GROUP_ON_ADD, <<"com.leapsight.bondy.security.groups.on_add">>).
-define(BONDY_GROUP_ON_DELETE, <<"com.leapsight.bondy.security.groups.on_delete">>).
-define(BONDY_GROUP_ON_UPDATE, <<"com.leapsight.bondy.security.groups.on_update">>).


% SOURCE
-define(BONDY_SOURCE_ADD, <<"com.leapsight.bondy.security.sources.add">>).
-define(BONDY_SOURCE_DELETE, <<"com.leapsight.bondy.security.sources.delete">>).
-define(BONDY_SOURCE_LIST, <<"com.leapsight.bondy.security.sources.list">>).
-define(BONDY_SOURCE_LOOKUP, <<"com.leapsight.bondy.security.sources.get">>).

-define(BONDY_SOURCE_ON_ADD, <<"com.leapsight.bondy.security.sources.on_add">>).
-define(BONDY_SOURCE_ON_DELETE, <<"com.leapsight.bondy.security.sources.on_delete">>).




%% =============================================================================
%% API GATEWAY
%% =============================================================================



-define(BONDY_GATEWAY_CLIENT_CHANGE_PASSWORD,
    <<"com.leapsight.bondy.api_gateway.change_password">>).

-define(BONDY_GATEWAY_CLIENT_ADD,
    <<"com.leapsight.bondy.api_gateway.add_client">>).
-define(BONDY_GATEWAY_CLIENT_DELETE,
    <<"com.leapsight.bondy.api_gateway.delete_client">>).
-define(BONDY_GATEWAY_CLIENT_LIST,
    <<"com.leapsight.bondy.api_gateway.list_clients">>).
-define(BONDY_GATEWAY_CLIENT_LOOKUP,
    <<"com.leapsight.bondy.api_gateway.get_client">>).
-define(BONDY_GATEWAY_CLIENT_UPDATE,
    <<"com.leapsight.bondy.api_gateway.update_client">>).

-define(BONDY_GATEWAY_CLIENT_ON_ADD,
    <<"com.leapsight.bondy.api_gateway.client_added">>).
-define(BONDY_GATEWAY_CLIENT_ON_DELETE,
    <<"com.leapsight.bondy.api_gateway.clients.client_deleted">>).
-define(BONDY_GATEWAY_CLIENT_ON_UPDATE,
    <<"com.leapsight.bondy.api_gateway.clients.client_updated">>).


-define(BONDY_GATEWAY_RESOURCE_OWNER_ADD,
    <<"com.leapsight.bondy.api_gateway.add_resource_owner">>).
-define(BONDY_GATEWAY_RESOURCE_OWNER_DELETE,
    <<"com.leapsight.bondy.api_gateway.delete_resource_owner">>).
-define(BONDY_GATEWAY_RESOURCE_OWNER_LIST,
    <<"com.leapsight.bondy.api_gateway.list_resource_owners">>).
-define(BONDY_GATEWAY_RESOURCE_OWNER_LOOKUP,
    <<"com.leapsight.bondy.api_gateway.get_resource_owner">>).
-define(BONDY_GATEWAY_RESOURCE_OWNER_UPDATE,
    <<"com.leapsight.bondy.api_gateway.update_resource_owner">>).

-define(BONDY_GATEWAY_RESOURCE_OWNER_ON_ADD,
    <<"com.leapsight.bondy.api_gateway.resource_owner_added">>).
-define(BONDY_GATEWAY_RESOURCE_OWNER_ON_DELETE,
    <<"com.leapsight.bondy.api_gateway.resource_owner_deleted">>).
-define(BONDY_GATEWAY_RESOURCE_OWNER_ON_UPDATE,
    <<"com.leapsight.bondy.api_gateway.resource_owner_updated">>).


-define(BONDY_GATEWAY_LOAD_API_SPEC,
    <<"com.leapsight.bondy.api_gateway.load_api_spec">>).


%% =============================================================================
%% GENERAL
%% =============================================================================



-define(BONDY_ERROR_NOT_IN_SESSION, <<"com.leapsight.bondy.error.not_in_session">>).
-define(BONDY_SESSION_ALREADY_EXISTS, <<"com.leapsight.bondy.error.session_already_exists">>).

-define(BONDY_ERROR_TIMEOUT, <<"com.leapsight.bondy.error.timeout">>).

-type peer_id() :: {integer(), pid()}.





%% =============================================================================
%% UTILS
%% =============================================================================

-define(EOT, '$end_of_table').
-define(CHARS2BIN(Chars), unicode:characters_to_binary(Chars, utf8, utf8)).
-define(CHARS2LIST(Chars), unicode:characters_to_list(Chars, utf8)).