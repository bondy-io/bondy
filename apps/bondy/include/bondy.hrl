
-define(BONDY_VERSION_STRING, <<"BONDY-0.0.2">>).
-define(BONDY_REALM_URI, <<"bondy">>).

-define(BONDY_PEER_CALL, <<"$bondy_call">>).
-define(BONDY_PEER_ACK, <<"$bondy_ack">>).


%% =============================================================================
%% FEATURES
%% =============================================================================




-define(DEALER_FEATURES, #{
    <<"progressive_call_results">> => false,
    <<"progressive_calls">> => false,
    <<"call_timeout">> => true,
    <<"call_canceling">> => false,
    <<"caller_identification">> => false,
    <<"call_trustlevels">> => false,
    <<"registration_meta_api">> => false,
    <<"registration_revocation">> => false,
    <<"session_meta_api">> => false,
    <<"pattern_based_registration">> => true,
    <<"procedure_reflection">> => false,
    <<"shared_registration">> => true,
    <<"sharded_registration">> => false
}).

-define(CALLEE_FEATURES, #{
    <<"progressive_call_results">> => false,
    <<"progressive_calls">> => false,
    <<"call_timeout">> => true,
    <<"call_canceling">> => false,
    <<"caller_identification">> => false,
    <<"call_trustlevels">> => false,
    <<"registration_revocation">> => false,
    <<"session_meta_api">> => false,
    <<"pattern_based_registration">> => true,
    <<"shared_registration">> => true,
    <<"sharded_registration">> => false
}).

-define(CALLER_FEATURES, #{
    <<"progressive_call_results">> => false,
    <<"progressive_calls">> => false,
    <<"call_timeout">> => false,
    <<"call_canceling">> => false,
    <<"caller_identification">> => false
}).

-define(BROKER_FEATURES, #{
    <<"event_history">> => false,
    <<"pattern_based_subscription">> => true,
    <<"publication_trustlevels">> => false,
    <<"publisher_exclusion">> => false,
    <<"publisher_identification">> => false,
    <<"session_meta_api">> => false,
    <<"sharded_subscription">> => false,
    <<"subscriber_blackwhite_listing">> => false,
    <<"subscription_meta_api">> => false,
    <<"topic_reflection">> => false
}).

-define(SUBSCRIBER_FEATURES, #{
    <<"event_history">> => false,
    <<"pattern_based_subscription">> => true,
    <<"publication_trustlevels">> => false,
    <<"publisher_identification">> => false,
    <<"sharded_subscription">> => false
}).

-define(PUBLISHER_FEATURES, #{
    <<"publisher_exclusion">> => false,
    <<"publisher_identification">> => false,
    <<"subscriber_blackwhite_listing">> => false
}).





%% =============================================================================
%% META EVENTS & PROCEDURES
%% =============================================================================

% USER
-define(BONDY_USER_ADD, <<"bondy.security.user.add">>).
-define(BONDY_USER_DELETE, <<"bondy.security.user.delete">>).
-define(BONDY_USER_LIST, <<"bondy.security.user.list">>).
-define(BONDY_USER_LOOKUP, <<"bondy.security.user.get">>).
-define(BONDY_USER_UPDATE, <<"bondy.security.user.update">>).

-define(BONDY_USER_ON_ADD, <<"bondy.security.user.on_add">>).
-define(BONDY_USER_ON_DELETE, <<"bondy.security.user.on_delete">>).
-define(BONDY_USER_ON_UPDATE, <<"bondy.security.user.on_update">>).


% GROUP
-define(BONDY_GROUP_ADD, <<"bondy.security.group.add">>).
-define(BONDY_GROUP_DELETE, <<"bondy.security.group.delete">>).
-define(BONDY_GROUP_LIST, <<"bondy.security.group.list">>).
-define(BONDY_GROUP_LOOKUP, <<"bondy.security.group.get">>).
-define(BONDY_GROUP_UPDATE, <<"bondy.security.group.update">>).

-define(BONDY_GROUP_ON_ADD, <<"bondy.security.group.on_add">>).
-define(BONDY_GROUP_ON_DELETE, <<"bondy.security.group.on_delete">>).
-define(BONDY_GROUP_ON_UPDATE, <<"bondy.security.group.on_update">>).


% SOURCE
-define(BONDY_SOURCE_ADD, <<"bondy.security.source.add">>).
-define(BONDY_SOURCE_DELETE, <<"bondy.security.source.delete">>).
-define(BONDY_SOURCE_LIST, <<"bondy.security.source.list">>).
-define(BONDY_SOURCE_LOOKUP, <<"bondy.security.source.get">>).

-define(BONDY_SOURCE_ON_ADD, <<"bondy.security.source.on_add">>).
-define(BONDY_SOURCE_ON_DELETE, <<"bondy.security.source.on_delete">>).


-define(BONDY_ERROR_NOT_IN_SESSION, <<"bondy.error.not_in_session">>).
-define(BONDY_SESSION_ALREADY_EXISTS, <<"bondy.error.session_already_exists">>).

-define(BONDY_ERROR_TIMEOUT, <<"bondy.error.timeout">>).

-type peer_id() :: {pid(), integer()}.





%% =============================================================================
%% UTILS
%% =============================================================================

-define(EOT, '$end_of_table').
-define(CHARS2BIN(Chars), unicode:characters_to_binary(Chars, utf8, utf8)).
-define(CHARS2LIST(Chars), unicode:characters_to_list(Chars, utf8)).