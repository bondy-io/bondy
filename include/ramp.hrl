-type dict()    ::  map().
-type uri()     ::  binary().
-type id()      ::  0..9007199254740993.
-type payload() ::  map().


-define(HELLO, 1).
-define(WELCOME, 2).
-define(ABORT, 3).
-define(CHALLENGE, 4).
-define(AUTHENTICATE, 5).
-define(GOODBYE, 6).
-define(HEARTBEAT, 7).
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


%% DO NOT CHANGE THE ORDER OF THE RECORD FIELDS
-record (hello, {
    realm_uri       ::  uri(),
    details         ::  map()
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

-record (yield, {
    request_id      ::  id(),
    options         ::  map(),
    arguments       ::  list(),
    payload         ::  map()
}).
