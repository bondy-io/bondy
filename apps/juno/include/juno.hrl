

%% Adictionary describing *features* supported by the peer for that role.
%% This MUST be empty for WAMP Basic Profile implementations, and MUST
%% be used by implementations implementing parts of the Advanced Profile
%% to list the specific set of features they support.
-type role_features() :: dict().
-define(JUNO_VERSION_STRING, <<"JUNO-0.0.1">>).
-define(WS_SUBPROTOCOL_HEADER_NAME, <<"sec-websocket-protocol">>).
-define(WAMP2_JSON, <<"wamp.2.json">>).
-define(WAMP2_MSGPACK, <<"wamp.2.msgpack">>).
-define(WAMP2_MSGPACK_BATCHED,<<"wamp.2.msgpack.batched">>).
-define(WAMP2_JSON_BATCHED,<<"wamp.2.json.batched">>).
-define(MAX_ID, 9007199254740993).

-type dict()    ::  map().
-type uri()     ::  binary().
-type id()      ::  0..9007199254740993.
-type payload() ::  map().

%% A _Client_ can support any combination of the following roles but must
%% support at least one role.
-type client_role() ::  caller | callee | subscriber | publisher.

-type subprotocol() ::  #{
    id => binary(),
    frame_type => text | binary,
    encoding => json | msgpack | json_batched | msgpack_batched
}.

-define(HELLO, 1).
-define(WELCOME, 2).
-define(ABORT, 3).
-define(CHALLENGE, 4).
-define(AUTHENTICATE, 5).
-define(GOODBYE, 6).
-define(ERROR, 8).
-define(PUBLISH, 16).
-define(PUBLISHED, 17).
-define(SUBSCRIBE, 32).
-define(SUBSCRIBED, 33).
-define(UNSUBSCRIBE, 34).
-define(UNSUBSCRIBED, 35).
-define(EVENT, 36).
-define(CALL, 48).
-define(CANCEL, 49).
-define(RESULT, 50).
-define(REGISTER, 64).
-define(REGISTERED, 65).
-define(UNREGISTER, 66).
-define(UNREGISTERED, 67).
-define(INVOCATION, 68).
-define(INTERRUPT, 69).
-define(YIELD, 70).




%% DO NOT CHANGE THE ORDER OF THE RECORD FIELDS as it maps
%% to the order in WAMP messages
-record (hello, {
    realm_uri       ::  uri(),
    details         ::  map()
}).

-record (challenge, {
    auth_method      ::  binary(),
    extra            ::  map()
}).

-record (authenticate, {
    signature       ::  binary(),
    extra           ::  map()
}).

-record (welcome, {
    session_id      ::  id(),
    details         ::  map()
}).

-record (abort, {
    details         ::  map(),
    reason_uri      ::  uri()
}).

-record (goodbye, {
    details         ::  map(),
    reason_uri      ::  uri()
}).

-record (error, {
    request_type    ::  non_neg_integer(),
    request_id      ::  id(),
    details         ::  map(),
    error_uri       ::  uri(),
    arguments       ::  list(),
    payload         ::  map()
}).

-record (publish, {
    request_id      ::  id(),
    options         ::  map(),
    topic_uri       ::  uri(),
    arguments       ::  list(),
    payload         ::  map()
}).

-record (published, {
    request_id      ::  id(),
    publication_id  ::  id()
}).

-record (subscribe, {
    request_id      ::  id(),
    options         ::  map(),
    topic_uri       ::  uri()
}).

-record (subscribed, {
    request_id      ::  id(),
    subscription_id ::  id()
}).

-record (unsubscribe, {
    request_id      ::  id(),
    subscription_id ::  id()
}).

-record (unsubscribed, {
    request_id      ::  id()
}).

-record (event, {
    subscription_id ::  id(),
    publication_id  ::  id(),
    details         ::  map(),
    arguments       ::  list(),
    payload         ::  map()
}).

-record (call, {
    request_id      ::  id(),
    options         ::  map(),
    procedure_uri   ::  uri(),
    arguments       ::  list(),
    payload         ::  map()
}).

-record (cancel, {
    request_id      ::  id(),
    options         ::  map()
}).

-record (result, {
    request_id      ::  id(),
    details         ::  map(),
    arguments       ::  list(),
    payload         ::  map()
}).

-record (register, {
    request_id      ::  id(),
    options         ::  map(),
    procedure_uri   ::  uri()
}).

-record (registered, {
    request_id      ::  id(),
    registration_id ::  id()
}).

-record (unregister, {
    request_id      ::  id(),
    registration_id ::  id()
}).

-record (unregistered, {
    request_id      ::  id()
}).

-record (invocation, {
    request_id      ::  id(),
    registration_id ::  id(),
    details         ::  map(),
    arguments       ::  list(),
    payload         ::  map()
}).

-record (interrupt, {
    request_id      ::  id(),
    options         ::  map()
}).

-record (yield, {
    request_id      ::  id(),
    options         ::  map(),
    arguments       ::  list(),
    payload         ::  map()
}).

-type message()     ::  #hello{} | #challenge{} | #authenticate{} | #welcome{}
                        | #abort{}
                        | #goodbye{}
                        | #error{}
                        | #publish{} | #published{}
                        | #subscribe{} | #subscribed{}
                        | #unsubscribe{} | #unsubscribed{}
                        | #event{}
                        | #call{}
                        | #cancel{}
                        | #result{}
                        | #register{} | #registered{}
                        | #unregister{} | #unregistered{}
                        | #invocation{}
                        | #interrupt{}
                        | #yield{}.


-define(WAMP_ERROR_AUTHORIZATION_FAILED, <<"wamp.error.authorization_failed">>).
-define(WAMP_ERROR_CANCELED, <<"wamp.error.canceled">>).
-define(WAMP_ERROR_CLOSE_REALM, <<"wamp.error.close_realm">>).
-define(WAMP_ERROR_DISCLOSE_ME_NOT_ALLOWED,
    <<"wamp.error.disclose_me.not_allowed">>).
-define(WAMP_ERROR_GOODBYE_AND_OUT, <<"wamp.error.goodbye_and_out">>).
-define(WAMP_ERROR_INVALID_ARGUMENT, <<"wamp.error.invalid_argument">>).
-define(WAMP_ERROR_INVALID_URI, <<"wamp.error.invalid_uri">>).
-define(WAMP_ERROR_NET_FAILURE, <<"wamp.error.network_failure">>).
-define(WAMP_ERROR_NO_ELIGIBLE_CALLE, <<"wamp.error.no_eligible_callee">>).
-define(WAMP_ERROR_NO_SUCH_PROCEDURE, <<"wamp.error.no_such_procedure">>).
-define(WAMP_ERROR_NO_SUCH_REALM, <<"wamp.error.no_such_realm">>).
-define(WAMP_ERROR_NO_SUCH_REGISTRATION, <<"wamp.error.no_such_registration">>).
-define(WAMP_ERROR_NO_SUCH_ROLE, <<"wamp.error.no_such_role">>).
-define(WAMP_ERROR_NO_SUCH_SESSION, <<"wamp.error.no_such_session">>).
-define(WAMP_ERROR_NO_SUCH_SUBSCRIPTION, <<"wamp.error.no_such_subscription">>).
-define(WAMP_ERROR_NOT_AUTHORIZED, <<"wamp.error.not_authorized">>).
-define(WAMP_ERROR_OPTION_DISALLOWED_DISCLOSE_ME,
    <<"wamp.error.option_disallowed.disclose_me">>).
-define(WAMP_ERROR_OPTION_NOT_ALLOWED, <<"wamp.error.option_not_allowed">>).
-define(WAMP_ERROR_PROCEDURE_ALREADY_EXISTS,
    <<"wamp.error.procedure_already_exists">>).
-define(WAMP_ERROR_SYSTEM_SHUTDOWN, <<"wamp.error.system_shutdown">>).

-define(JUNO_ERROR_NOT_IN_SESSION, <<"juno.error.not_in_session">>).
-define(JUNO_SESSION_ALREADY_EXISTS, <<"juno.error.session_already_exists">>).
