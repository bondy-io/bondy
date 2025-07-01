%% -----------------------------------------------------------------------------
%%  Copyright (c) 2015-2021 Leapsight. All rights reserved.
%% -----------------------------------------------------------------------------


%% =============================================================================
%% COMMON
%% =============================================================================


-define(WAMP2_JSON, <<"wamp.2.json">>).
-define(WAMP2_MSGPACK, <<"wamp.2.msgpack">>).
-define(WAMP2_BERT, <<"wamp.2.bert">>).
-define(WAMP2_ERL, <<"wamp.2.erl">>).
-define(WAMP2_MSGPACK_BATCHED,<<"wamp.2.msgpack.batched">>).
-define(WAMP2_JSON_BATCHED,<<"wamp.2.json.batched">>).
-define(WAMP2_BERT_BATCHED,<<"wamp.2.bert.batched">>).
-define(WAMP2_ERL_BATCHED,<<"wamp.2.erl.batched">>).

-define(WAMP_ENCODINGS, [
    json,
    msgpack,
    bert,
    erl,
    json_batched,
    msgpack_batched,
    bert_batched,
    erl_batched
]).

-define(MAX_ID, 9007199254740992).

-type encoding()        ::  json
                            | msgpack
                            | bert
                            | erl
                            | json_batched
                            | msgpack_batched
                            | bert_batched
                            | erl_batched.

-type frame_type()      ::  text | binary.
-type transport()       ::  ws | raw.
-type subprotocol()     ::  {transport(), frame_type(), encoding()}.


%% Adictionary describing *features* supported by the peer for that role.
%% This MUST be empty for WAMP Basic Profile implementations, and MUST
%% be used by implementations implementing parts of the Advanced Profile
%% to list the specific set of features they support.
-type uri()             ::  binary().
-type id()              ::  0..?MAX_ID.



%% =============================================================================
%% RAW_SOCKET
%% =============================================================================


-define(RAW_MAGIC, 16#7F).
-define(RAW_MSG_PREFIX, <<0:5, 0:3>>).
-define(RAW_PING_PREFIX, <<0:5, 1:3>>).
-define(RAW_PONG_PREFIX, <<0:5, 2:3>>).

%% 0: illegal (must not be used)
%% 1: serializer unsupported
%% 2: maximum message length unacceptable
%% 3: use of reserved bits (unsupported feature)
%% 4: maximum connection count reached
%% 5 - 15: reserved for future errors
-define(RAW_ERROR(Upper),
    <<?RAW_MAGIC:8, Upper:4, 0:20>>
).

-define(RAW_FRAME(Bin),
    <<(?RAW_MSG_PREFIX)/binary, (byte_size(Bin)):24, Bin/binary>>
).


-type raw_error()   ::
    invalid_response
    | invalid_socket
    | invalid_handshake
    | maximum_connection_count_reached
    | maximum_message_length_unacceptable
    | maximum_message_length_exceeded
    | serializer_unsupported
    | use_of_reserved_bits.


%% =============================================================================
%% AUTH
%% =============================================================================




%% =============================================================================
%% FEATURE ANNOUNCEMENT
%% =============================================================================


-define(ROUTER_ROLES_SPEC, #{
    broker => #{
        alias => <<"broker">>,
        required => false,
        datatype => map,
        validator => #{
            features => #{
                alias => <<"features">>,
                required => false,
                datatype => map,
                validator => ?BROKER_FEATURES_SPEC
            }
        }
    },
    dealer => #{
        alias => <<"dealer">>,
        required => false,
        datatype => map,
        validator => #{
            features => #{
                alias => <<"features">>,
                required => false,
                datatype => map,
                validator => ?DEALER_FEATURES_SPEC
            }
        }
    }
}).

-define(WAMP_COMMON_FEATURES_SPEC,
    begin
        #{payload_passthru_mode => #{
            alias => <<"payload_passthru_mode">>,
            required => false,
            datatype => boolean
        }}
    end
).


-define(WAMP_RPC_FEATURES_SPEC,
    begin
        (?WAMP_COMMON_FEATURES_SPEC)#{
            progressive_call_results => #{
                alias => <<"progressive_call_results">>,
                required => false,
                datatype => boolean
            },
            progressive_calls => #{
                alias => <<"progressive_calls">>,
                required => false,
                datatype => boolean
            },
            call_timeout => #{
                alias => <<"call_timeout">>,
                required => false,
                datatype => boolean
            },
            call_canceling => #{
                alias => <<"call_canceling">>,
                required => false,
                datatype => boolean
            },
            caller_identification=> #{
                alias => <<"caller_identification">>,
                required => false,
                datatype => boolean
            },
            sharded_registration => #{
                alias => <<"sharded_registration">>,
                required => false,
                datatype => boolean
            }
    }
    end
).


-define(WAMP_DEALER_FEATURES_SPEC,
    begin
        (?WAMP_RPC_FEATURES_SPEC)#{
            call_reroute => #{
                alias => <<"call_reroute">>,
                required => false,
                datatype => boolean
            },
            call_trustlevels => #{
                alias => <<"call_trustlevels">>,
                required => false,
                datatype => boolean
            },
            pattern_based_registration => #{
                alias => <<"pattern_based_registration">>,
                required => false,
                datatype => boolean
            },
            shared_registration => #{
                alias => <<"shared_registration">>,
                required => false,
                datatype => boolean
            },
            registration_revocation => #{
                alias => <<"registration_revocation">>,
                required => false,
                datatype => boolean
            },
            testament_meta_api => #{
                alias => <<"testament_meta_api">>,
                required => false,
                datatype => boolean
            },
            session_meta_api => #{
                alias => <<"session_meta_api">>,
                required => false,
                datatype => boolean
            },
            registration_meta_api => #{
                alias => <<"registration_meta_api">>,
                required => false,
                datatype => boolean
            },
            reflection => #{
                alias => <<"reflection">>,
                required => false,
                datatype => boolean
            }
        }
    end
).


-define(DEALER_FEATURES_SPEC, ?WAMP_DEALER_FEATURES_SPEC#{
    call_retries => #{
        alias => <<"call_retries">>,
        required => false,
        datatype => boolean
    }
}).

-define(WAMP_PUBSUB_FEATURES_SPEC,
    begin
        (?WAMP_COMMON_FEATURES_SPEC)#{
            publisher_identification => #{
                alias => <<"publisher_identification">>,
                required => false,
                datatype => boolean
            },
            sharded_subscription => #{
                alias => <<"sharded_subscription">>,
                required => false,
                datatype => boolean
            }
        }
    end
).

-define(BROKER_FEATURES_SPEC, (?WAMP_PUBSUB_FEATURES_SPEC)#{
    subscriber_blackwhite_listing => #{
        alias => <<"subscriber_blackwhite_listing">>,
        required => false,
        datatype => boolean
    },
    publisher_exclusion => #{
        alias => <<"publisher_exclusion">>,
        required => false,
        datatype => boolean
    },
    publication_trustlevels => #{
        alias => <<"publication_trustlevels">>,
        required => false,
        datatype => boolean
    },
    pattern_based_subscription => #{
        alias => <<"pattern_based_subscription">>,
        required => false,
        datatype => boolean
    },
    event_history => #{
        alias => <<"event_history">>,
        required => false,
        datatype => boolean
    },
    event_retention => #{
        alias => <<"event_retention">>,
        required => false,
        datatype => boolean
    },
    subscription_revocation => #{
        alias => <<"subscription_revocation">>,
        required => false,
        datatype => boolean
    },
    session_meta_api => #{
        alias => <<"session_meta_api">>,
        required => false,
        datatype => boolean
    },
    subscription_meta_api => #{
        alias => <<"subscription_meta_api">>,
        required => false,
        datatype => boolean
    },
    reflection => #{
        alias => <<"reflection">>,
        required => false,
        datatype => boolean
    },
    %% Non-standard
    acknowledge_event_received => #{
        alias => <<"acknowledge_event_received">>,
        required => false,
        datatype => boolean
    },
    acknowledge_subscriber_received => #{
        alias => <<"acknowledge_subscriber_received">>,
        required => false,
        datatype => boolean
    }
}).


-define(CLIENT_ROLES_SPEC, #{
    publisher => #{
        alias => <<"publisher">>,
        required => false,
        datatype => map,
        validator => #{
            features => #{
                alias => <<"features">>,
                required => false,
                datatype => map,
                validator => ?PUBLISHER_FEATURES_SPEC
            }
        }
    },
    subscriber => #{
        alias => <<"subscriber">>,
        required => false,
        datatype => map,
        validator => #{
            features => #{
                alias => <<"features">>,
                required => false,
                datatype => map,
                validator => ?SUBSCRIBER_FEATURES_SPEC
            }
        }
    },
    caller => #{
        alias => <<"caller">>,
        required => false,
        datatype => map,
        validator => #{
            features => #{
                alias => <<"features">>,
                required => false,
                datatype => map,
                validator => ?CALLER_FEATURES_SPEC
            }
        }
    },
    callee => #{
        alias => <<"callee">>,
        required => false,
        datatype => map,
        validator => #{
            features => #{
                alias => <<"features">>,
                required => false,
                datatype => map,
                validator => ?CALLEE_FEATURES_SPEC
            }
        }
    }
}).

-define(CALLEE_FEATURES_SPEC, (?WAMP_RPC_FEATURES_SPEC)#{
    call_reroute => #{
        alias => <<"call_reroute">>,
        required => false,
        datatype => boolean
    },
    call_trustlevels => #{
        alias => <<"call_trustlevels">>,
        required => false,
        datatype => boolean
    },
    pattern_based_registration => #{
        alias => <<"pattern_based_registration">>,
        required => false,
        datatype => boolean
    },
    shared_registration => #{
        alias => <<"shared_registration">>,
        required => false,
        datatype => boolean
    },
    registration_revocation => #{
        alias => <<"registration_revocation">>,
        required => false,
        datatype => boolean
    },
    testament_meta_api => #{
        alias => <<"testament_meta_api">>,
        required => false,
        datatype => boolean
    },
    session_meta_api => #{
        alias => <<"session_meta_api">>,
        required => false,
        datatype => boolean
    },
    registration_meta_api => #{
        alias => <<"registration_meta_api">>,
        required => false,
        datatype => boolean
    },
    reflection => #{
        alias => <<"reflection">>,
        required => false,
        datatype => boolean
    }
}).

-define(CALLER_FEATURES_SPEC, ?WAMP_CALLER_FEATURES_SPEC#{
    call_retries => #{
        alias => <<"call_retries">>,
        required => false,
        datatype => boolean
    }
}).

-define(WAMP_CALLER_FEATURES_SPEC, ?WAMP_RPC_FEATURES_SPEC).


-define(SUBSCRIBER_FEATURES_SPEC, (?WAMP_PUBSUB_FEATURES_SPEC)#{
    publication_trustlevels => #{
        alias => <<"publication_trustlevels">>,
        required => false,
        datatype => boolean
    },
    pattern_based_subscription => #{
        alias => <<"pattern_based_subscription">>,
        required => false,
        datatype => boolean
    },
    event_history => #{
        alias => <<"event_history">>,
        required => false,
        datatype => boolean
    },
    subscription_revocation => #{
        alias => <<"subscription_revocation">>,
        required => false,
        datatype => boolean
    },
    %% Non-standard
    acknowledge_subscriber_received => #{
        alias => <<"acknowledge_subscriber_received">>,
        required => false,
        datatype => boolean
    }
}).

-define(PUBLISHER_FEATURES_SPEC, (?WAMP_PUBSUB_FEATURES_SPEC)#{
    subscriber_blackwhite_listing => #{
        alias => <<"subscriber_blackwhite_listing">>,
        required => false,
        datatype => boolean
    },
    publisher_exclusion => #{
        alias => <<"publisher_exclusion">>,
        required => false,
        datatype => boolean
    },
    %% Non-standard
    acknowledge_event_received => #{
        alias => <<"acknowledge_event_received">>,
        required => false,
        datatype => boolean
    }
}).



%% =============================================================================
%% WAMP MESSAGES
%% =============================================================================



-define(HELLO, 1).
-define(WELCOME, 2).
-define(ABORT, 3).
-define(CHALLENGE, 4).
-define(AUTHENTICATE, 5).
-define(GOODBYE, 6).
-define(ERROR, 8).

%% -----------------------------------------------------------------------------
%% PUSUB
%% -----------------------------------------------------------------------------
-define(PUBLISH, 16).
-define(PUBLISHED, 17).
-define(SUBSCRIBE, 32).
-define(SUBSCRIBED, 33).
-define(UNSUBSCRIBE, 34).
-define(UNSUBSCRIBED, 35).
-define(EVENT, 36).
-define(EVENT_RECEIVED, 37).
-define(SUBSCRIBER_RECEIVED, 38).

%% -----------------------------------------------------------------------------
%% RPC
%% -----------------------------------------------------------------------------
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

-type message_name()    ::  hello
                            | welcome
                            | abort
                            | challenge
                            | authenticate
                            | goodbye
                            | error
                            | publish
                            | published
                            | subscribe
                            | subscribed
                            | unsubscribe
                            | unsubscribed
                            | event
                            | event_received
                            | subscriber_received
                            | call
                            | cancel
                            | result
                            | register
                            | registered
                            | unregister
                            | unregistered
                            | invocation
                            | interrupt
                            | yield.

-type wamp_message()     ::  wamp_hello()
                            | wamp_challenge()
                            | wamp_authenticate()
                            | wamp_welcome()
                            | wamp_abort()
                            | wamp_goodbye()
                            | wamp_error()
                            | wamp_publish()
                            | wamp_published()
                            | wamp_subscribe()
                            | wamp_subscribed()
                            | wamp_unsubscribe()
                            | wamp_unsubscribed()
                            | wamp_event()
                            | wamp_event_received()
                            | wamp_subscriber_received()
                            | wamp_call()
                            | wamp_cancel()
                            | wamp_result()
                            | wamp_register()
                            | wamp_registered()
                            | wamp_unregister()
                            | wamp_unregistered()
                            | wamp_invocation()
                            | wamp_interrupt()
                            | wamp_yield().


-define(EXACT_MATCH, <<"exact">>).
-define(PREFIX_MATCH, <<"prefix">>).
-define(WILDCARD_MATCH, <<"wildcard">>).
-define(MATCH_STRATEGIES, [
    ?EXACT_MATCH,
    ?PREFIX_MATCH,
    ?WILDCARD_MATCH
]).

-define(PPT_DETAILS_SPEC,
    begin
        #{
    %% The ppt_scheme identifies the Key Management Schema. It is a required
    %% string attribute. This attribute can contain the name or identifier of a
    %% key management provider that is known to the target peer, so it can be
    %% used to obtain information about encryption keys. A Router can recognize
    %% that Payload Passthru Mode is in use by checking the existence and
    %% non-empty value of this attribute within the options of CALL, PUBLISH
    %% and YIELD messages.
    ppt_scheme => #{
        alias => <<"ppt_scheme">>,
        required => false,
        datatype => binary
    },
    %% The ppt_serializer attribute is optional. It specifies what serializer
    %% was used to encode the payload. It can be a value a such as mqtt, amqp,
    %% stomp to indicate that the incoming data is tunneling through such
    %% technologies, or it can be ordinary json, msgpack, cbor, flatbuffers
    %% data serializers.
    ppt_serializer => #{
        alias => <<"ppt_serializer">>,
        required => false,
        datatype => binary
    },
    %% The ppt_cipher attribute is optional. It is required if the payload is
    %% encrypted. This attribute specifies the cryptographic algorithm that was
    %% used to encrypt the payload. It can be xsalsa20poly1305, aes256gcm for
    %% now.
    ppt_cipher => #{
        alias => <<"ppt_cipher">>,
        required => false,
        datatype => binary
    },
    %% The ppt_keyid attribute is optional. This attribute can contain the
    %% encryption key id that was used to encrypt the payload. The ppt_keyid
    %% attribute is a string type. The value can be a hex-encoded string, URI,
    %% DNS name, Ethereum address, UUID identifier - any meaningful value which
    %% allows the target peer to choose a private key without guessing. The
    %% format of the value may depend on the ppt_scheme attribute.
    ppt_keyid => #{
        alias => <<"ppt_keyid">>,
        required => false,
        datatype => binary
    }
    }
end).


%% NOTICE: DO NOT CHANGE THE ORDER OF THE RECORD FIELDS as they map
%% to the order in WAMP messages and we use list_to_tuple/1 to convert from
%% WAMP list to Erlang tuple and vicecersa


%% -----------------------------------------------------------------------------
%% HELLO 1
%% -----------------------------------------------------------------------------

-record(hello, {
    realm_uri       ::  uri(),
    details         ::  map()
}).

-type wamp_hello()  ::  #hello{}.

-define(HELLO_DETAILS_SPEC, #{
    authmethods => #{
        % description => Used by the client to announce the authentication methods it is prepared to perform.">>,
        alias => <<"authmethods">>,
        required => false,
        datatype => {list, binary}
    },
    authid => #{
        % description => <<"The authentication ID (e.g. username) the client wishes to authenticate as.">>,
        alias => <<"authid">>,
        required => false,
        datatype => [binary, atom]
    },
    authrole => #{
        alias => <<"authrole">>,
        required => false,
        datatype => [binary, atom]
    },
    authextra => #{
        % description => <<"Not in RFC">>,
        alias => <<"authextra">>,
        required => false,
        allow_undefined => true,
        allow_null => false,
        datatype => map
    },
    roles => #{
        alias => <<"roles">>,
        required => true,
        datatype => map,
        validator => ?CLIENT_ROLES_SPEC
    },
    agent => #{
        % description => <<"When a software agent operates in a network protocol, it often identifies itself, its application type, operating system, software vendor, or software revision, by submitting a characteristic identification string to its operating peer. Similar to what browsers do with the User-Agent HTTP header, both the HELLO and the WELCOME message MAY disclose the WAMP implementation in use to its peer">>,
        alias => <<"agent">>,
        required => false,
        datatype => binary
    },
    transport => #{
        % description => <<"When running WAMP over a TLS (either secure WebSocket
        % or raw TCP) transport, a peer may authenticate to the other via the TLS certificate mechanism. A server might authenticate to the client, and a client may authenticate to the server (TLS client-certificate based authentication). This transport-level authentication information may be forward to the WAMP level within HELLO.Details.transport.auth|any in both directions (if available).">>,
        alias => <<"transport">>,
        required => false,
        datatype => map,
        validator => #{
            auth => #{required => true}
        }
    },
    resumable => #{
        alias => <<"resumable">>,
        required => false,
        datatype => boolean
    },
    resume_session => #{
        % description => <<"The session ID the client would like to resume.">>,
        alias => <<"resume_session">>,
        required => false,
        datatype => binary
    },
    resume_token => #{
        % description => <<"The secure token required to resume the session defined in 'resume_session'.">>,
        alias => <<"resume_token">>,
        required => false,
        datatype => binary
    }
}).


%% -----------------------------------------------------------------------------
%% WELCOME 2
%% -----------------------------------------------------------------------------

-record(welcome, {
    session_id      ::  id(),
    details         ::  map()
}).

-type wamp_welcome()       ::  #welcome{}.

-define(WELCOME_DETAILS_SPEC, #{
    realm => #{
        alias => <<"realm">>,
        required => true,
        datatype => binary
    },
    roles => #{
        alias => <<"roles">>,
        required => true,
        datatype => map,
        validator => ?ROUTER_ROLES_SPEC
    },
    authid => #{
        alias => <<"authid">>,
        required => true,
        datatype => binary
    },
    authrole => #{
        alias => <<"authrole">>,
        required => true,
        datatype => [binary, atom]
    },
    authmethod => #{
        alias => <<"authmethod">>,
        required => false,
        datatype => binary
    },
    authprovider => #{
        alias => <<"authprovider">>,
        required => false,
        datatype => binary
    },
    authextra => #{
        alias => <<"authextra">>,
        required => false,
        allow_undefined => true,
        allow_null => false,
        datatype => map
    },
    agent => #{
        alias => <<"agent">>,
        required => false,
        datatype => binary
    },
    resumed => #{
        alias => <<"resumed">>,
        required => false,
        datatype => boolean
    },
    resumable => #{
        alias => <<"resumable">>,
        required => false,
        datatype => boolean
    },
    resume_token => #{
        % description => <<"The secure token required to resume the session defined in 'resume_session'.">>,
        alias => <<"resume_token">>,
        required => false,
        datatype => binary
    }
}).


%% -----------------------------------------------------------------------------
%% ABORT 3
%% -----------------------------------------------------------------------------

-record(abort, {
    details         ::  map(),
    reason_uri      ::  uri()
}).

-type wamp_abort()       ::  #abort{}.

-define(ABORT_DETAILS_SPEC, #{
    %% Optional human-readable closing message
    message => #{
        alias => <<"message">>,
        required => false,
        datatype => binary
    }
}).


%% -----------------------------------------------------------------------------
%% CHALLENGE 4
%% -----------------------------------------------------------------------------

-record(challenge, {
    auth_method      ::  binary(),
    extra            ::  map()
}).
-type wamp_challenge()       ::  #challenge{}.


-define(CHALLENGE_DETAILS_SPEC, #{
    challenge => #{
        alias => <<"challenge">>,
        required => false,
        datatype => binary
    },
    %% For WAMP-CRA
    keylen => #{
        alias => <<"keylen">>,
        required => false,
        datatype => integer
    },
    %% For WAMP-CRA & WAMP-SCRAM
    salt => #{
        alias => <<"salt">>,
        required => false,
        datatype => binary
    },
    %% For WAMP-CRA & WAMP-SCRAM
    iterations => #{
        alias => <<"iterations">>,
        required => false,
        datatype => integer
    },
    %% For WAMP-SCRAM
    nonce => #{
        alias => <<"nonce">>,
        required => false,
        datatype => binary
    },
    %% For WAMP-SCRAM
    memory => #{
        alias => <<"memory">>,
        required => false,
        allow_undefined => true,
        allow_null => false,
        datatype => integer
    }
}).

%% -----------------------------------------------------------------------------
%% AUTHENTICATE 5
%% -----------------------------------------------------------------------------

-record(authenticate, {
    signature       ::  binary(),
    extra           ::  map()
}).

-type wamp_authenticate()       ::  #authenticate{}.


%% -----------------------------------------------------------------------------
%% GOODBYE 6
%% -----------------------------------------------------------------------------

-record(goodbye, {
    details         ::  map(),
    reason_uri      ::  uri()
}).

-type wamp_goodbye()       ::  #goodbye{}.

-define(GOODBYE_DETAILS_SPEC, #{
    %% Router: Whether the session is able to be resumed or destroyed.
    %% Client: Whether it should be resumable or destroyed.
    resumable => #{
        alias => <<"resumable">>,
        required => false,
        datatype => boolean
    }
}).

%% -----------------------------------------------------------------------------
%% ERROR 8
%% -----------------------------------------------------------------------------

-record(error, {
    request_type    ::  pos_integer(),
    request_id      ::  id(),
    details         ::  map(),
    error_uri       ::  uri(),
    args            ::  list() | undefined,
    kwargs          ::  map() | undefined
}).
-type wamp_error()       ::  #error{}.

-define(ERROR_DETAILS_SPEC, ?PPT_DETAILS_SPEC).

%% -----------------------------------------------------------------------------
%% PUBLISH 16
%%
%% -----------------------------------------------------------------------------

-record(publish, {
    request_id      ::  id(),
    options         ::  map(),
    topic_uri       ::  uri(),
    args            ::  list() | undefined,
    kwargs          ::  map() | undefined
}).

-type wamp_publish()       ::  #publish{}.


-define(PUBLISH_OPTS_SPEC,
    begin
        ?PPT_DETAILS_SPEC#{
            %% resource key
            acknowledge => #{
                alias => <<"acknowledge">>,
                required => false,
                datatype => boolean
            },
            rkey => #{
                alias => <<"rkey">>,
                required => false,
                datatype => binary
            },
            disclose_me => #{
                alias => <<"disclose_me">>,
                required => false,
                datatype => boolean
            },
            %% blacklisting
            exclude => #{
                alias => <<"exclude">>,
                required => false,
                datatype => {list, integer}
            },
            exclude_authid => #{
                alias => <<"exclude_authid">>,
                required => false,
                datatype => {list, binary}
            },
            exclude_authrole => #{
                alias => <<"exclude_authrole">>,
                required => false,
                datatype => {list, binary}
            },
            exclude_me => #{
                alias => <<"exclude_me">>,
                required => false,
                datatype => boolean
            },
            %% whitelisting
            eligible => #{
                alias => <<"eligible">>,
                required => false,
                datatype => {list, integer}
            },
            eligible_authid => #{
                alias => <<"eligible_authid">>,
                required => false,
                datatype => {list, binary}
            },
            eligible_authrole => #{
                alias => <<"eligible_authrole">>,
                required => false,
                datatype => {list, binary}
            },
            retain => #{
                alias => <<"retain">>,
                required => false,
                datatype => boolean
            }
        }
    end
).

%% -----------------------------------------------------------------------------
%% PUBLISHED 17
%% -----------------------------------------------------------------------------

-record(published, {
    request_id      ::  id(),
    publication_id  ::  id()
}).
-type wamp_published()       ::  #published{}.

%% -----------------------------------------------------------------------------
%% SUBSCRIBE 32
%% -----------------------------------------------------------------------------

-record(subscribe, {
    request_id      ::  id(),
    options         ::  map(),
    topic_uri       ::  uri()
}).

-type wamp_subscribe()       ::  #subscribe{}.

-define(SUBSCRIBE_OPTS_SPEC, #{
    match => #{
        alias => <<"match">>,
        required => true,
        default => ?EXACT_MATCH,
        datatype => {in, ?MATCH_STRATEGIES}
    },
    %% node key
    nkey => #{
        alias => <<"nkey">>,
        required => false,
        datatype => binary
    },
    get_retained => #{
        alias => <<"get_retained">>,
        required => false,
        datatype => boolean
    }
}).

%% -----------------------------------------------------------------------------
%% SUBSCRIBED 33
%% -----------------------------------------------------------------------------

-record(subscribed, {
    request_id      ::  id(),
    subscription_id ::  id()
}).
-type wamp_subscribed()       ::  #subscribed{}.

%% -----------------------------------------------------------------------------
%% UNSUBSCRIBE 34
%% -----------------------------------------------------------------------------

-record(unsubscribe, {
    request_id      ::  id(),
    subscription_id ::  id()
}).
-type wamp_unsubscribe()       ::  #unsubscribe{}.

%% -----------------------------------------------------------------------------
%% UNSUBSCRIBED 35
%% -----------------------------------------------------------------------------

-record(unsubscribed, {
    request_id      ::  id()
}).
-type wamp_unsubscribed()       ::  #unsubscribed{}.

%% -----------------------------------------------------------------------------
%% EVENT 36
%% -----------------------------------------------------------------------------

-record(event, {
    subscription_id ::  id(),
    publication_id  ::  id(),
    details         ::  map(),
    args            ::  list() | undefined,
    kwargs          ::  map() | undefined
}).

-type wamp_event()       ::  #event{}.

-define(EVENT_DETAILS_SPEC, ?PPT_DETAILS_SPEC#{
    acknowledge => #{
        alias => <<"acknowledge">>,
        required => false,
        datatype => boolean
    },
    topic => #{
        alias => <<"topic">>,
        required => false,
        datatype => binary
    },
    %% Set when publisher is disclosed
    publisher => #{
        alias => <<"publisher">>,
        required => false,
        datatype => integer
    },
    %% Set when publisher is disclosed
    publisher_authid => #{
        alias => <<"publisher_authid">>,
        required => false,
        datatype => binary
    },
    %% Set when publisher is disclosed
    publisher_authrole => #{
        alias => <<"publisher_authrole">>,
        required => false,
        datatype => binary
    },
    retained => #{
        alias => <<"retained">>,
        required => false,
        datatype => boolean
    }
}).


%% -----------------------------------------------------------------------------
%% EVENT_RECEIVED 37
%% -----------------------------------------------------------------------------

-record(event_received, {
    publication_id  ::  id(),
    details         ::  map(),
    payload         ::  binary() | undefined
}).

-type wamp_event_received()  ::  #event_received{}.

-define(EVENT_RECEIVED_DETAILS_SPEC, ?PPT_DETAILS_SPEC).

%% -----------------------------------------------------------------------------
%% EVENT_RECEIVED 38
%% -----------------------------------------------------------------------------

-record(subscriber_received, {
    %% From #event_received.publication_id
    publication_id  ::  id(),
    details         ::  map(),
    %% From #event_received.payload
    payload         ::  binary() | undefined
}).

-type wamp_subscriber_received()  ::  #subscriber_received{}.

-define(SUBSCRIBER_RECEIVED_DETAILS_SPEC, ?PPT_DETAILS_SPEC#{
    %% Set when publisher is disclosed
    subscriber => #{
        alias => <<"subscriber">>,
        required => false,
        datatype => integer
    },
    %% Set when subscriber is disclosed
    subscriber_authid => #{
        alias => <<"subscriber_authid">>,
        required => false,
        datatype => binary
    },
    %% Set when subscriber is disclosed
    subscriber_authrole => #{
        alias => <<"subscriber_authrole">>,
        required => false,
        datatype => binary
    }
}).

%% -----------------------------------------------------------------------------
%% CALL 48
%% -----------------------------------------------------------------------------

-record(call, {
    request_id      ::  id(),
    options         ::  map(),
    procedure_uri   ::  uri(),
    args            ::  list() | undefined,
    kwargs          ::  map() | undefined
}).

-type wamp_call()       ::  #call{}.

-define(WAMP_CALL_OPTS_SPEC,
    begin
        ?PPT_DETAILS_SPEC#{
            timeout => #{
                alias => <<"timeout">>,
                required => false,
                default => 0,
                datatype => non_neg_integer
            },
            receive_progress => #{
                alias => <<"receive_progress">>,
                required => false,
                datatype => boolean
            },
            disclose_me => #{
                alias => <<"disclose_me">>,
                required => false,
                datatype => boolean
            },
            runmode => #{
                alias => <<"runmode">>,
                required => false,
                datatype => {in, [<<"partition">>]}
            },
            %% if runmode is present then rkey should be present
            rkey => #{
                alias => <<"rkey">>,
                required => false,
                datatype => binary
            },
            %% 'all' invocation strategy (ALPHA)
            yields => #{
                alias => <<"yields">>,
                required => false,
                datatype => {in, [<<"first">>, <<"gather">>, <<"progressive">>]}
            }
        }
    end
).

-define(CALL_OPTS_SPEC,
    begin
        ?WAMP_CALL_OPTS_SPEC#{
            retries => #{
                alias => <<"retries">>,
                required => false,
                datatype => map,
                validator => ?RETRIES_SPEC
            }
        }
    end
).

-define(RETRIES_SPEC, #{
    allowance => #{
        alias => <<"allowance">>,
        required => true,
        datatype => map,
        validator => #{
            min_retries_per_sec => #{
                alias => <<"min_retries_frequency">>,
                required => true,
                default => 5,
                datatype => non_neg_integer
            },
            ratio => #{
                alias => <<"ratio">>,
                required => true,
                default => 0.5,
                datatype => float
            },
            ttl => #{
                alias => <<"ttl">>,
                required => true,
                default => 5000,
                datatype => timeout
            }
        }
    },
    backoff => #{
        alias => <<"backoff">>,
        required => true,
        datatype => map,
        validator => #{
            type => #{
                alias => <<"type">>,
                required => true,
                default => <<"normal">>,
                datatype => {in, [<<"normal">>, <<"jitter">>]}
            },
            min_duration => #{
                alias => <<"min_duration">>,
                required => true,
                default => 50,
                datatype => non_neg_integer
            },
            max_duration => #{
                alias => <<"max_duration">>,
                required => true,
                default => 5000,
                datatype => non_neg_integer
            }
        }
    }
}).

%% -----------------------------------------------------------------------------
%% CANCEL 49
%% -----------------------------------------------------------------------------

-record(cancel, {
    request_id      ::  id(),
    options         ::  map()
}).
-type wamp_cancel()       ::  #cancel{}.

-define(CALL_CANCELLING_OPTS_SPEC, #{
    mode => #{
        alias => <<"mode">>,
        required => false,
        datatype => {in, [<<"skip">>, <<"kill">>, <<"killnowait">>]}
    }
}).

%% -----------------------------------------------------------------------------
%% RESULT 50
%% -----------------------------------------------------------------------------

-record(result, {
    request_id      ::  id(),
    details         ::  map(),
    args            ::  list() | undefined,
    kwargs          ::  map() | undefined
}).

-type wamp_result()       ::  #result{}.

-define(RESULT_DETAILS_SPEC, ?PPT_DETAILS_SPEC#{
    progress => #{
        alias => <<"progress">>,
        required => false,
        datatype => boolean
    }
}).

%% -----------------------------------------------------------------------------
%% REGISTER 64
%% -----------------------------------------------------------------------------

-record(register, {
    request_id      ::  id(),
    options         ::  map(),
    procedure_uri   ::  uri()
}).

-type wamp_register()       ::  #register{}.

-define(INVOKE_SINGLE, <<"single">>).
-define(INVOKE_ROUND_ROBIN, <<"roundrobin">>).
-define(INVOKE_RANDOM, <<"random">>).
-define(INVOKE_FIRST, <<"first">>).
-define(INVOKE_LAST, <<"last">>).
%% ALPHA
-define(INVOKE_ALL, <<"last">>).

-define(REGISTER_OPTS_SPEC, #{
    disclose_caller => #{
        alias => <<"disclose_caller">>,
        required => false,
        datatype => boolean
    },
    match => #{
        alias => <<"match">>,
        required => false,
        default => ?EXACT_MATCH,
        datatype => {in, ?MATCH_STRATEGIES}
    },
    invoke => #{
        alias => <<"invoke">>,
        required => false,
        default => ?INVOKE_SINGLE,
        datatype => {in, [
            ?INVOKE_SINGLE,
            ?INVOKE_ROUND_ROBIN,
            ?INVOKE_RANDOM,
            ?INVOKE_FIRST,
            ?INVOKE_LAST,
            ?INVOKE_ALL
        ]}
    },
    %% The (maximum) concurrency to be used for the registration. A value of 0
    %% disables it.
    concurrency => #{
        alias => <<"concurrency">>,
        required => true,
        default => 0,
        datatype => non_neg_integer
    },
    %% When set to true this allows subsequent sessions to “kick out” any
    %% current registrations; those previous registration must have also
    %% specified force_reregister=true.
    force_reregister => #{
        alias => <<"force_reregister">>,
        required => false,
        datatype => boolean
    }
}).

%% -----------------------------------------------------------------------------
%% REGISTERED 65
%% -----------------------------------------------------------------------------

-record(registered, {
    request_id      ::  id(),
    registration_id ::  id()
}).
-type wamp_registered()       ::  #registered{}.

%% -----------------------------------------------------------------------------
%% UNREGISTER 66
%% -----------------------------------------------------------------------------

-record(unregister, {
    request_id      ::  id(),
    registration_id ::  id()
}).

-type wamp_unregister()       ::  #unregister{}.


%% -----------------------------------------------------------------------------
%% UNREGISTERED 67
%% -----------------------------------------------------------------------------

-record(unregistered, {
    request_id      ::  id(),
    details         ::  map() | undefined
}).

-type wamp_unregistered()       ::  #unregistered{}.


%% -----------------------------------------------------------------------------
%% UNREGISTERED 67
%% -----------------------------------------------------------------------------

-record(unregistered_2, {
    request_id      ::  id(),
    details         ::  map()
}).

-type wamp_unregister_ext()       ::  #unregister{}.

-define(UNREGISTERED_DETAILS_SPEC, #{
    %% The reason URI for revocation.
    reason => #{
        alias => <<"reason">>,
        required => false,
        datatype => binary
    },
    registration => #{
        alias => <<"registration">>,
        required => false,
        datatype => integer
    }
}).

%% -----------------------------------------------------------------------------
%% INVOCATION 68
%% -----------------------------------------------------------------------------

-record(invocation, {
    request_id      ::  id(),
    registration_id ::  id(),
    details         ::  map(),
    args            ::  list() | undefined,
    kwargs          ::  map() | undefined
}).

-type wamp_invocation()       ::  #invocation{}.

-define(INVOCATION_DETAILS_SPEC, ?PPT_DETAILS_SPEC#{
    trustlevel => #{
        alias => <<"trustlevel">>,
        required => false,
        datatype => integer
    },
    procedure => #{
        alias => <<"procedure">>,
        required => false,
        datatype => binary
    },
    %% If present, let the callee automatically timeout the invocation
    timeout => #{
        alias => <<"timeout">>,
        required => false,
        datatype => non_neg_integer
    },
    %% Tells callee to produce progressive results
    receive_progress => #{
        alias => <<"receive_progress">>,
        required => false,
        datatype => boolean
    },
    %% Present when caller is disclosed
    caller => #{
        alias => <<"caller">>,
        required => false,
        datatype => integer
    },
    %% Present when caller is disclosed
    caller_authid => #{
        alias => <<"caller_authid">>,
        required => false,
        datatype => binary
    },
    %% Present when caller is disclosed
    caller_authrole => #{
        alias => <<"caller_authrole">>,
        required => false,
        datatype => binary
    }
}).

%% -----------------------------------------------------------------------------
%% INTERRUPT 69
%% -----------------------------------------------------------------------------

-record(interrupt, {
    request_id      ::  id(),
    options         ::  map()
}).
-type wamp_interrupt()       ::  #interrupt{}.


-define(INTERRUPT_OPTIONS_SPEC, #{
    mode => #{
        alias => <<"mode">>,
        required => false,
        datatype => binary
    }
}).

%% -----------------------------------------------------------------------------
%% YIELD 70
%% -----------------------------------------------------------------------------

-record(yield, {
    request_id      ::  id(),
    options         ::  map(),
    args            ::  list() | undefined,
    kwargs          ::  map() | undefined
}).

-type wamp_yield()  ::  #yield{}.

-define(YIELD_OPTIONS_SPEC, ?PPT_DETAILS_SPEC).



%% =============================================================================
%% URIs
%% =============================================================================



-define(WAMP_CLOSE_LOGOUT, <<"wamp.close.logout">>).
-define(WAMP_CLOSE_NORMAL, <<"wamp.close.normal">>).
-define(WAMP_CLOSE_REALM, <<"wamp.close.close_realm">>).

-define(WAMP_UNAVAILABLE, <<"wamp.error.unavailable">>).
-define(WAMP_NO_AVAILABLE_CALLEE, <<"wamp.error.no_available_callee">>).
-define(WAMP_FEATURE_NOT_SUPPORTED, <<"wamp.error.no_available_callee">>).
-define(WAMP_AUTHENTICATION_FAILED, <<"wamp.error.authentication_failed">>).
-define(WAMP_AUTHORIZATION_FAILED, <<"wamp.error.authorization_failed">>).
-define(WAMP_CANCELLED, <<"wamp.error.canceled">>).
-define(WAMP_COUNT_CALLEES,             <<"wamp.registration.count_callees">>).
-define(WAMP_DISCLOSE_ME_NOT_ALLOWED, <<"wamp.error.disclose_me.not_allowed">>).
-define(WAMP_ERROR_INVALID_URI,         <<"wamp.error.invalid_uri">>).
-define(WAMP_ERROR_NO_SUCH_SESSION,     <<"wamp.error.no_such_session">>).
-define(WAMP_GOODBYE_AND_OUT, <<"wamp.close.goodbye_and_out">>).
-define(WAMP_INVALID_ARGUMENT, <<"wamp.error.invalid_argument">>).
-define(WAMP_INVALID_PAYLOAD, <<"wamp.error.invalid_payload">>).
-define(WAMP_INVALID_URI, <<"wamp.error.invalid_uri">>).
-define(WAMP_LIST_CALLEES,              <<"wamp.registration.list_callees">>).
-define(WAMP_NET_FAILURE, <<"wamp.error.network_failure">>).
-define(WAMP_NOT_AUTHORIZED, <<"wamp.error.not_authorized">>).
-define(WAMP_NOT_AUTH_METHOD, <<"wamp.error.not_auth_method">>).
-define(WAMP_NO_ELIGIBLE_CALLE, <<"wamp.error.no_eligible_callee">>).
-define(WAMP_NO_SUCH_PRINCIPAL, <<"wamp.error.no_such_principal">>).
-define(WAMP_NO_SUCH_PROCEDURE, <<"wamp.error.no_such_procedure">>).
-define(WAMP_NO_SUCH_REALM, <<"wamp.error.no_such_realm">>).
-define(WAMP_NO_SUCH_REGISTRATION, <<"wamp.error.no_such_registration">>).
-define(WAMP_NO_SUCH_ROLE, <<"wamp.error.no_such_role">>).
-define(WAMP_NO_SUCH_SESSION, <<"wamp.error.no_such_session">>).
-define(WAMP_NO_SUCH_SUBSCRIPTION, <<"wamp.error.no_such_subscription">>).
-define(WAMP_OPTION_DISALLOWED_DISCLOSE_ME,
    <<"wamp.error.option_disallowed.disclose_me">>).
-define(WAMP_OPTION_NOT_ALLOWED,
    <<"wamp.error.option_not_allowed">>).
-define(WAMP_PAYLOAD_SIZE_EXCEEDED,
    <<"wamp.error.payload_size_exceeded">>).
-define(WAMP_PROCEDURE_ALREADY_EXISTS,
    <<"wamp.error.procedure_already_exists">>).
-define(WAMP_PROCEDURE_EXISTS_WITH_DIFF_POLICY,
    <<"wamp.error.procedure_exists_with_different_invocation_policy">>).
-define(WAMP_PROTOCOL_VIOLATION,    <<"wamp.error.protocol_violation">>).
-define(WAMP_REGISTRATION_ON_CREATE,    <<"wamp.registration.on_create">>).
-define(WAMP_REGISTRATION_ON_DELETE,    <<"wamp.registration.on_delete">>).
-define(WAMP_REGISTRATION_ON_REGISTER,  <<"wamp.registration.on_register">>).
-define(WAMP_REGISTRATION_ON_UNREGISTER, <<"wamp.registration.on_unregister">>).
-define(WAMP_REG_GET,                   <<"wamp.registration.get">>).
-define(WAMP_REG_LIST,                  <<"wamp.registration.list">>).
-define(WAMP_REG_LOOKUP,                <<"wamp.registration.lookup">>).
-define(WAMP_REG_MATCH,                 <<"wamp.registration.match">>).
-define(WAMP_REG_ON_CREATE,             <<"wamp.registration.on_create">>).
-define(WAMP_REG_ON_DELETE,             <<"wamp.registration.on_delete">>).
-define(WAMP_REG_ON_REGISTER,           <<"wamp.registration.on_register">>).
-define(WAMP_REG_ON_UNREGISTER,         <<"wamp.registration.on_unregister">>).
-define(WAMP_SESSION_COUNT,             <<"wamp.session.count">>).
-define(WAMP_SESSION_GET,               <<"wamp.session.get">>).
-define(WAMP_SESSION_KILL,              <<"wamp.session.kill">>).
-define(WAMP_SESSION_KILL_ALL,          <<"wamp.session.kill_all">>).
-define(WAMP_SESSION_KILL_BY_AUTHID,    <<"wamp.session.kill_by_authid">>).
-define(WAMP_SESSION_KILL_BY_AUTHROLE,  <<"wamp.session.kill_by_authrole">>).
-define(WAMP_SESSION_LIST,              <<"wamp.session.list">>).
-define(WAMP_SESSION_ON_JOIN,           <<"wamp.session.on_join">>).
-define(WAMP_SESSION_ON_LEAVE,          <<"wamp.session.on_leave">>).
-define(WAMP_SUBCRIPTION_ON_CREATE, <<"wamp.subscription.on_create">>).
-define(WAMP_SUBCRIPTION_ON_DELETE, <<"wamp.subscription.on_delete">>).
-define(WAMP_SUBCRIPTION_ON_REGISTER, <<"wamp.subscription.on_subscribe">>).
-define(WAMP_SUBCRIPTION_ON_UNREGISTER, <<"wamp.subscription.on_unsubscribe">>).
-define(WAMP_SUBSCRIPTION_COUNT_SUBSCRIBERS,
    <<"wamp.subscription.count_subscribers">>).
-define(WAMP_SUBSCRIPTION_GET,                  <<"wamp.subscription.get">>).
-define(WAMP_SUBSCRIPTION_LIST,                 <<"wamp.subscription.list">>).
-define(WAMP_SUBSCRIPTION_LIST_SUBSCRIBERS,
    <<"wamp.subscription.list_subscribers">>).
-define(WAMP_SUBSCRIPTION_LOOKUP,               <<"wamp.subscription.lookup">>).
-define(WAMP_SUBSCRIPTION_MATCH,                <<"wamp.subscription.match">>).
-define(WAMP_SUBSCRIPTION_ON_CREATE,            <<"wamp.subscription.on_create">>).
-define(WAMP_SUBSCRIPTION_ON_DELETE,            <<"wamp.subscription.on_delete">>).
-define(WAMP_SUBSCRIPTION_ON_SUBSCRIBE,         <<"wamp.subscription.on_subscribe">>).
-define(WAMP_SUBSCRIPTION_ON_UNSUBSCRIBE,       <<"wamp.subscription.on_unsubscribe">>).
-define(WAMP_SYSTEM_SHUTDOWN,           <<"wamp.close.system_shutdown">>).
-define(WAMP_ERROR_TIMEOUT,                   <<"wamp.error.timeout">>).
-define(WAMP_TYPE_CHECK_ERROR,          <<"wamp.error.type_check_error">>).