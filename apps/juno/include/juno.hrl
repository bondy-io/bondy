
-define(JUNO_VERSION_STRING, <<"JUNO-0.0.2">>).
-define(JUNO_REALM_URI, <<"juno">>).

-define(JUNO_PEER_CALL, <<"$juno_call">>).
-define(JUNO_PEER_ACK, <<"$juno_ack">>).


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
-define(JUNO_USER_ADD, <<"juno.security.user.add">>).
-define(JUNO_USER_DELETE, <<"juno.security.user.delete">>).
-define(JUNO_USER_LIST, <<"juno.security.user.list">>).
-define(JUNO_USER_LOOKUP, <<"juno.security.user.get">>).
-define(JUNO_USER_UPDATE, <<"juno.security.user.update">>).

-define(JUNO_USER_ON_ADD, <<"juno.security.user.on_add">>).
-define(JUNO_USER_ON_DELETE, <<"juno.security.user.on_delete">>).
-define(JUNO_USER_ON_UPDATE, <<"juno.security.user.on_update">>).


% GROUP
-define(JUNO_GROUP_ADD, <<"juno.security.group.add">>).
-define(JUNO_GROUP_DELETE, <<"juno.security.group.delete">>).
-define(JUNO_GROUP_LIST, <<"juno.security.group.list">>).
-define(JUNO_GROUP_LOOKUP, <<"juno.security.group.get">>).
-define(JUNO_GROUP_UPDATE, <<"juno.security.group.update">>).

-define(JUNO_GROUP_ON_ADD, <<"juno.security.group.on_add">>).
-define(JUNO_GROUP_ON_DELETE, <<"juno.security.group.on_delete">>).
-define(JUNO_GROUP_ON_UPDATE, <<"juno.security.group.on_update">>).


% SOURCE
-define(JUNO_SOURCE_ADD, <<"juno.security.source.add">>).
-define(JUNO_SOURCE_DELETE, <<"juno.security.source.delete">>).
-define(JUNO_SOURCE_LIST, <<"juno.security.source.list">>).
-define(JUNO_SOURCE_LOOKUP, <<"juno.security.source.get">>).

-define(JUNO_SOURCE_ON_ADD, <<"juno.security.source.on_add">>).
-define(JUNO_SOURCE_ON_DELETE, <<"juno.security.source.on_delete">>).


-define(JUNO_ERROR_NOT_IN_SESSION, <<"juno.error.not_in_session">>).
-define(JUNO_SESSION_ALREADY_EXISTS, <<"juno.error.session_already_exists">>).



-type peer_id() :: {integer(), pid()}.
