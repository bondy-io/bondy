
-define(DEALER_FEATURES, #{
    progressive_call_results => false,
    progressive_calls => false,
    call_timeout => false,
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
    call_timeout => false,
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
