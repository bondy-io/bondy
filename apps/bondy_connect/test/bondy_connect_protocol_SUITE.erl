%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_protocol_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.realm">>).
-define(PASSWORD, <<"aWe11KeptSecret">>).

all() ->
    [
        %% Config validation
        config_defaults_to_anonymous,
        config_missing_realm,
        config_bad_authmethod,

        %% HELLO / handshake start
        start_builds_hello,
        hello_advertises_feature_matrix,
        start_only_from_closed,

        %% Auth round-trips (tie back to the bondy_wamp 0b primitives)
        anonymous_welcome,
        cra_response_matches_server,
        cryptosign_signature_verifies,
        cryptosign_derives_pubkey_from_privkey,
        ticket_sends_secret,
        welcome_after_challenge,
        welcome_without_challenge_aborts,

        %% Termination paths
        router_abort_stops,
        router_goodbye_acks_and_stops,
        unexpected_message_aborts,
        outbound_before_established_errors,

        %% Security
        format_status_redacts_secret
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(bondy_wamp),
    Config.

end_per_suite(_) ->
    ok.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private Build a protocol in the `closed' state for an auth config.
protocol(AuthConfig) ->
    {ok, Cfg} = bondy_connect_config:validate(#{
        realm => ?REALM, auth => AuthConfig
    }),
    {ok, St} = bondy_connect_protocol:init(Cfg),
    St.

%% @private Build a protocol already in `establishing' (HELLO sent).
establishing(AuthConfig) ->
    {ok, _Hello, St} = bondy_connect_protocol:start(protocol(AuthConfig)),
    St.

%% @private CRA params matching the server's stored-password params.
cra_params(Salt, Iterations, KeyLen) ->
    #{
        challenge => <<"{\"nonce\":\"abc\",\"authid\":\"alice\"}">>,
        salt => Salt,
        keylen => KeyLen,
        iterations => Iterations
    }.

%% =============================================================================
%% CONFIG VALIDATION
%% =============================================================================

config_defaults_to_anonymous(_) ->
    {ok, Cfg} = bondy_connect_config:validate(#{realm => ?REALM}),
    ?assertEqual(?REALM, maps:get(realm, Cfg)),
    ?assertEqual(#{method => <<"anonymous">>}, maps:get(auth, Cfg)),
    ?assertEqual(<<"bondy_connect/0.1.0">>, maps:get(agent, Cfg)),
    ?assertEqual(#{verify => verify_peer}, maps:get(tls, Cfg)).

config_missing_realm(_) ->
    ?assertEqual({error, missing_realm}, bondy_connect_config:validate(#{})).

config_bad_authmethod(_) ->
    ?assertEqual(
        {error, {unsupported_authmethod, <<"kerberos">>}},
        bondy_connect_config:validate(#{
            realm => ?REALM, auth => #{method => <<"kerberos">>}
        })
    ).

%% =============================================================================
%% HELLO / START
%% =============================================================================

start_builds_hello(_) ->
    St0 = protocol(#{method => <<"anonymous">>}),
    ?assertEqual(closed, bondy_connect_protocol:state_name(St0)),

    {ok, Hello, St1} = bondy_connect_protocol:start(St0),
    ?assertMatch(#hello{realm_uri = ?REALM}, Hello),
    #hello{details = Details} = Hello,
    ?assertEqual([<<"anonymous">>], maps:get(authmethods, Details)),
    ?assert(maps:is_key(roles, Details)),
    ?assertEqual(establishing, bondy_connect_protocol:state_name(St1)).

%% The default HELLO advertises exactly the advanced-profile features the client
%% implements — advertise == handle. progressive_call_results is implemented
%% for both RPC roles (paired with call_canceling per the WAMP spec);
%% progressive_calls (argument streaming) remains deferred and must be absent.
hello_advertises_feature_matrix(_) ->
    {ok, Hello, _St} = bondy_connect_protocol:start(
        protocol(#{method => <<"anonymous">>})
    ),
    #hello{details = #{roles := Roles}} = Hello,

    ?assert(feature(caller, call_canceling, Roles)),
    ?assert(feature(caller, call_timeout, Roles)),
    ?assert(feature(caller, caller_identification, Roles)),
    ?assert(feature(caller, call_retries, Roles)),
    ?assert(feature(caller, progressive_call_results, Roles)),

    ?assert(feature(callee, call_canceling, Roles)),
    ?assert(feature(callee, pattern_based_registration, Roles)),
    ?assert(feature(callee, shared_registration, Roles)),
    ?assert(feature(callee, registration_revocation, Roles)),
    ?assert(feature(callee, progressive_call_results, Roles)),

    ?assert(feature(publisher, publisher_exclusion, Roles)),
    ?assert(feature(publisher, subscriber_blackwhite_listing, Roles)),
    ?assert(feature(subscriber, pattern_based_subscription, Roles)),

    %% Deferred features must be absent from every role; a pub/sub role
    %% must not claim an RPC feature.
    [
        begin
            Features = maps:get(features, maps:get(Role, Roles, #{}), #{}),
            ?assertNot(maps:is_key(progressive_calls, Features))
        end
     || Role <- [caller, callee, publisher, subscriber]
    ],
    [
        begin
            Features = maps:get(features, maps:get(Role, Roles, #{}), #{}),
            ?assertNot(maps:is_key(progressive_call_results, Features))
        end
     || Role <- [publisher, subscriber]
    ].

%% @private
feature(Role, Feature, Roles) ->
    maps:get(
        Feature, maps:get(features, maps:get(Role, Roles, #{}), #{}), false
    ).

start_only_from_closed(_) ->
    St1 = establishing(#{method => <<"anonymous">>}),
    ?assertMatch(
        {error, {invalid_state, establishing}},
        bondy_connect_protocol:start(St1)
    ).

%% =============================================================================
%% AUTH ROUND-TRIPS
%% =============================================================================

anonymous_welcome(_) ->
    St1 = establishing(#{method => <<"anonymous">>}),
    Welcome = #welcome{
        session_id = 12345,
        details = #{
            realm => ?REALM,
            authid => <<"anonymous">>,
            authrole => <<"anonymous">>,
            authmethod => <<"anonymous">>,
            roles => #{dealer => #{}, broker => #{}}
        }
    },
    {established, Session, St2} =
        bondy_connect_protocol:handle_message(Welcome, St1),
    ?assertEqual(established, bondy_connect_protocol:state_name(St2)),
    ?assertEqual(12345, bondy_connect_session:id(Session)),
    ?assertEqual(<<"anonymous">>, bondy_connect_session:authid(Session)),
    ?assertEqual(?REALM, bondy_connect_session:realm_uri(Session)).

%% The client's CRA response must equal the signature the server computes from
%% the stored salted password (bondy_wamp_cra:response/2).
cra_response_matches_server(_) ->
    St1 = establishing(#{
        method => <<"wampcra">>, authid => <<"alice">>, password => ?PASSWORD
    }),

    Salt = bondy_wamp_cra:salt(),
    Iterations = 4096,
    KeyLen = bondy_wamp_cra:hash_length(),
    Extra = cra_params(Salt, Iterations, KeyLen),
    Challenge = maps:get(challenge, Extra),

    %% Server side: derive the stored salted password and the expected response
    SPass = bondy_wamp_cra:salted_password(?PASSWORD, Salt, #{
        kdf => pbkdf2,
        iterations => Iterations,
        hash_function => sha256,
        hash_length => KeyLen
    }),
    Expected = bondy_wamp_cra:response(Challenge, SPass),

    {reply, [Auth], St2} = bondy_connect_protocol:handle_message(
        #challenge{auth_method = <<"wampcra">>, extra = Extra}, St1
    ),
    ?assertMatch(#authenticate{}, Auth),
    #authenticate{signature = Signature} = Auth,
    ?assertEqual(Expected, Signature),
    ?assertEqual(challenging, bondy_connect_protocol:state_name(St2)).

%% The client's cryptosign signature must verify server-side against the
%% advertised public key (bondy_wamp_cryptosign:verify/3).
cryptosign_signature_verifies(_) ->
    #{public := Pub, secret := Secret} = bondy_wamp_cryptosign:generate_key(),
    PrivHex = bondy_wamp_cryptosign:encode_hex(Secret),
    PubHex = bondy_wamp_cryptosign:encode_hex(Pub),

    {ok, Hello, St1} = bondy_connect_protocol:start(
        protocol(#{
            method => <<"cryptosign">>,
            authid => <<"alice">>,
            privkey => PrivHex,
            pubkey => PubHex
        })
    ),
    #hello{details = Details} = Hello,
    ?assertEqual(#{<<"pubkey">> => PubHex}, maps:get(authextra, Details)),

    ChallengeBytes = bondy_wamp_cryptosign:strong_rand_bytes(),
    ChallengeHex = bondy_wamp_cryptosign:encode_hex(ChallengeBytes),

    {reply, [Auth], _St2} = bondy_connect_protocol:handle_message(
        #challenge{
            auth_method = <<"cryptosign">>,
            extra = #{challenge => ChallengeHex}
        },
        St1
    ),
    #authenticate{signature = SignatureHex} = Auth,
    Signature = bondy_wamp_cryptosign:decode_hex(SignatureHex),
    ?assert(bondy_wamp_cryptosign:verify(Signature, ChallengeBytes, Pub)).

cryptosign_derives_pubkey_from_privkey(_) ->
    #{public := Pub, secret := Secret} = bondy_wamp_cryptosign:generate_key(),
    PrivHex = bondy_wamp_cryptosign:encode_hex(Secret),
    PubHex = bondy_wamp_cryptosign:encode_hex(Pub),

    %% No pubkey in config -> derived from the private key.
    {ok, Hello, _St1} = bondy_connect_protocol:start(
        protocol(#{
            method => <<"cryptosign">>, privkey => PrivHex
        })
    ),
    #hello{details = Details} = Hello,
    ?assertEqual(#{<<"pubkey">> => PubHex}, maps:get(authextra, Details)).

ticket_sends_secret(_) ->
    Ticket = <<"s3cr3t-ticket">>,
    St1 = establishing(#{
        method => <<"ticket">>, authid => <<"bob">>, ticket => Ticket
    }),
    {reply, [Auth], _St2} = bondy_connect_protocol:handle_message(
        #challenge{auth_method = <<"ticket">>, extra = #{}}, St1
    ),
    ?assertEqual(Ticket, Auth#authenticate.signature).

welcome_after_challenge(_) ->
    St1 = establishing(#{
        method => <<"wampcra">>, authid => <<"alice">>, password => ?PASSWORD
    }),
    Salt = bondy_wamp_cra:salt(),
    Extra = cra_params(Salt, 4096, bondy_wamp_cra:hash_length()),
    {reply, [_Auth], St2} = bondy_connect_protocol:handle_message(
        #challenge{auth_method = <<"wampcra">>, extra = Extra}, St1
    ),
    ?assertEqual(challenging, bondy_connect_protocol:state_name(St2)),

    Welcome = #welcome{session_id = 7, details = #{authid => <<"alice">>}},
    {established, Session, St3} =
        bondy_connect_protocol:handle_message(Welcome, St2),
    ?assertEqual(established, bondy_connect_protocol:state_name(St3)),
    ?assertEqual(7, bondy_connect_session:id(Session)).

%% A WELCOME arriving straight from `establishing` (no prior CHALLENGE) must be
%% rejected for every credential-bearing method — silently accepting it would
%% downgrade the operator's configured security posture (review B2). Anonymous
%% is the only method that may be welcomed un-challenged (anonymous_welcome).
welcome_without_challenge_aborts(_) ->
    #{secret := Secret} = bondy_wamp_cryptosign:generate_key(),
    PrivHex = bondy_wamp_cryptosign:encode_hex(Secret),
    Configs = [
        #{
            method => <<"cryptosign">>,
            authid => <<"alice">>,
            privkey => PrivHex
        },
        #{
            method => <<"wampcra">>,
            authid => <<"alice">>,
            password => ?PASSWORD
        },
        #{method => <<"ticket">>, authid => <<"bob">>, ticket => <<"s3cr3t">>}
    ],
    Welcome = #welcome{session_id = 99, details = #{authid => <<"alice">>}},
    lists:foreach(
        fun(AuthConfig) ->
            St1 = establishing(AuthConfig),
            ?assertMatch(
                {stop, {shutdown, {welcome_without_challenge, _}}, [#abort{}],
                    _},
                bondy_connect_protocol:handle_message(Welcome, St1)
            )
        end,
        Configs
    ).

%% =============================================================================
%% TERMINATION
%% =============================================================================

router_abort_stops(_) ->
    St1 = establishing(#{method => <<"anonymous">>}),
    Abort = #abort{reason_uri = <<"wamp.error.no_such_realm">>, details = #{}},
    {stop, Reason, Out, _St2} =
        bondy_connect_protocol:handle_message(Abort, St1),
    ?assertEqual([], Out),
    ?assertMatch(
        {shutdown, {abort, <<"wamp.error.no_such_realm">>, _}}, Reason
    ).

router_goodbye_acks_and_stops(_) ->
    St1 = establishing(#{method => <<"anonymous">>}),
    {established, _, St2} = bondy_connect_protocol:handle_message(
        #welcome{session_id = 1, details = #{}}, St1
    ),
    Goodbye = #goodbye{
        reason_uri = <<"wamp.close.close_realm">>, details = #{}
    },
    {stop, Reason, [Ack], St3} =
        bondy_connect_protocol:handle_message(Goodbye, St2),
    ?assertMatch(#goodbye{reason_uri = <<"wamp.close.goodbye_and_out">>}, Ack),
    ?assertMatch({shutdown, {goodbye, _}}, Reason),
    ?assertEqual(shutting_down, bondy_connect_protocol:state_name(St3)).

unexpected_message_aborts(_) ->
    St1 = establishing(#{method => <<"anonymous">>}),
    %% A bare term that is not a WAMP message must become an ABORT, not crash.
    {stop, Reason, [Abort], St2} =
        bondy_connect_protocol:handle_message(garbage, St1),
    ?assertMatch(
        #abort{reason_uri = <<"wamp.error.protocol_violation">>}, Abort
    ),
    ?assertMatch({shutdown, {protocol_violation, _}}, Reason),
    ?assertEqual(shutting_down, bondy_connect_protocol:state_name(St2)).

outbound_before_established_errors(_) ->
    St1 = establishing(#{method => <<"anonymous">>}),
    Msg = #goodbye{reason_uri = <<"wamp.close.normal">>, details = #{}},
    ?assertMatch(
        {error, {not_established, establishing}, _},
        bondy_connect_protocol:outbound(Msg, St1)
    ).

%% =============================================================================
%% SECURITY
%% =============================================================================

%% The raw secret must not survive format_status/1 (it is present beforehand).
format_status_redacts_secret(_) ->
    Secret = <<"super-secret-password-value">>,
    St = establishing(#{
        method => <<"wampcra">>, authid => <<"alice">>, password => Secret
    }),
    ?assertNotEqual(nomatch, binary:match(term_to_binary(St), Secret)),

    Redacted = bondy_connect_protocol:format_status(St),
    ?assertEqual(nomatch, binary:match(term_to_binary(Redacted), Secret)).
