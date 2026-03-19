%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_auth_wamp_cra_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).
-define(U3, <<"user_3">>).
-define(U_NOPASS, <<"user_no_password">>).
-define(P1, <<"aWe11KeptSecret">>).
-define(P2, <<"An0therWe11KeptSecret">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        %% Original test (preserved)
        test_1,

        %% Full challenge-response flow
        full_cra_flow,
        challenge_extra_has_required_keys,

        %% Wrong signatures
        wrong_signature_fails,
        empty_signature_fails,
        random_binary_signature_fails,

        %% Source / CIDR
        user1_allowed_from_any_ip,
        user2_rejected_outside_cidr,
        user2_allowed_within_cidr,

        %% Method selection
        method_mismatch_after_challenge,
        password_auth_not_in_cra_only_realm,
        invalid_method_rejected,

        %% User without password
        user_without_password_excluded,

        %% Error cases
        nonexistent_user_error,
        nonexistent_realm_error,

        %% Context after challenge
        context_method_set_after_challenge
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.cra_auth">>,
    ok = add_realm(RealmUri),
    [{realm_uri, RealmUri} | Config].

end_per_suite(Config) ->
    {save_config, Config}.


add_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?WAMP_CRA_AUTH
        ],
        security_enabled => true,
        grants => [
            #{
                permissions => [
                    <<"wamp.register">>,
                    <<"wamp.unregister">>,
                    <<"wamp.subscribe">>,
                    <<"wamp.unsubscribe">>,
                    <<"wamp.call">>,
                    <<"wamp.cancel">>,
                    <<"wamp.publish">>
                ],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => <<"all">>
            }
        ],
        users => [
            #{
                username => ?U1,
                password => ?P1,
                groups => [],
                meta => #{}
            },
            #{
                username => ?U2,
                password => ?P1,
                groups => [],
                meta => #{}
            },
            #{
                username => ?U_NOPASS,
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            #{
                usernames => [?U1],
                authmethod => ?WAMP_CRA_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [?U2],
                authmethod => ?WAMP_CRA_AUTH,
                cidr => <<"192.168.0.0/16">>
            },
            #{
                usernames => [?U_NOPASS],
                authmethod => ?WAMP_CRA_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },
    _ = bondy_realm:create(Config),
    ok.



%% =============================================================================
%% HELPERS
%% =============================================================================



%% @private
compute_signature(Password, ChallengeExtra) ->
    #{
        challenge := Challenge,
        salt := Salt,
        keylen := KeyLen,
        iterations := Iterations
    } = ChallengeExtra,

    SPass = bondy_password_cra:salted_password(Password, Salt, #{
        kdf => pbkdf2,
        iterations => Iterations,
        hash_length => KeyLen,
        hash_function => sha256
    }),
    base64:encode(crypto:mac(hmac, sha256, SPass, Challenge)).



%% =============================================================================
%% ORIGINAL TEST (PRESERVED)
%% =============================================================================



test_1(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Roles = [],
    SourceIP = {127, 0, 0, 1},

    {ok, U1Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, SourceIP),

    ?assertEqual(
        true,
        lists:member(?WAMP_CRA_AUTH, bondy_auth:available_methods(U1Ctxt1))
    ),

    {true, U1Extra, U1Ctxt2} = bondy_auth:challenge(
        ?WAMP_CRA_AUTH, #{}, U1Ctxt1
    ),
    #{
        challenge := U1Challenge,
        salt := U1Salt,
        keylen := U1KeyLen,
        iterations := U1Iterations
    } = U1Extra,

    U1SPass = bondy_password_cra:salted_password(?P1, U1Salt, #{
        kdf => pbkdf2,
        iterations => U1Iterations,
        hash_length => U1KeyLen,
        hash_function => sha256
    }),
    U1Signature = base64:encode(
        crypto:mac(hmac, sha256, U1SPass, U1Challenge)
    ),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?WAMP_CRA_AUTH, U1Signature, undefined, U1Ctxt2)
    ),

    ?assertMatch(
        {error, bad_signature},
        bondy_auth:authenticate(?WAMP_CRA_AUTH, <<>>, undefined, U1Ctxt2)
    ),

    ?assertMatch(
        {error, bad_signature},
        bondy_auth:authenticate(?WAMP_CRA_AUTH, ?P2, undefined, U1Ctxt2)
    ),

    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, U1Ctxt2)
    ),

    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(<<"foo">>, ?P1, undefined, U1Ctxt2)
    ),

    %% user 2 is not granted access from Peer (see test_2)
    {ok, Ctxt2} = bondy_auth:init(SessionId, RealmUri, ?U2, Roles, SourceIP),

    ?assertEqual(
        false,
        lists:member(?WAMP_CRA_AUTH, bondy_auth:available_methods(Ctxt2))
    ),

    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(?WAMP_CRA_AUTH, ?P1, undefined, Ctxt2)
    ).



%% =============================================================================
%% FULL CHALLENGE-RESPONSE FLOW
%% =============================================================================



full_cra_flow(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    %% Step 1: Challenge
    {true, Extra, Ctxt1} = bondy_auth:challenge(?WAMP_CRA_AUTH, #{}, Ctxt0),

    %% Step 2: Compute correct signature and authenticate
    Signature = compute_signature(?P1, Extra),
    {ok, AuthExtra, Ctxt2} = bondy_auth:authenticate(
        ?WAMP_CRA_AUTH, Signature, undefined, Ctxt1
    ),

    %% CRA returns empty extra on success
    ?assertEqual(#{}, AuthExtra),

    %% Method is set in context
    ?assertEqual(?WAMP_CRA_AUTH, bondy_auth:method(Ctxt2)).


challenge_extra_has_required_keys(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    {true, Extra, _} = bondy_auth:challenge(?WAMP_CRA_AUTH, #{}, Ctxt0),

    %% Challenge extra must contain all required CRA fields
    ?assert(maps:is_key(challenge, Extra)),
    ?assert(maps:is_key(salt, Extra)),
    ?assert(maps:is_key(keylen, Extra)),
    ?assert(maps:is_key(iterations, Extra)),

    %% Challenge is a JSON-encoded binary
    ?assert(is_binary(maps:get(challenge, Extra))),
    %% Salt is a binary
    ?assert(is_binary(maps:get(salt, Extra))),
    %% keylen and iterations are positive integers
    ?assert(is_integer(maps:get(keylen, Extra))),
    ?assert(maps:get(keylen, Extra) > 0),
    ?assert(is_integer(maps:get(iterations, Extra))),
    ?assert(maps:get(iterations, Extra) > 0).



%% =============================================================================
%% WRONG SIGNATURES
%% =============================================================================



wrong_signature_fails(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    {true, Extra, Ctxt1} = bondy_auth:challenge(?WAMP_CRA_AUTH, #{}, Ctxt0),

    %% Signature computed with wrong password
    WrongSig = compute_signature(?P2, Extra),
    ?assertMatch(
        {error, bad_signature},
        bondy_auth:authenticate(?WAMP_CRA_AUTH, WrongSig, undefined, Ctxt1)
    ).


empty_signature_fails(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    {true, _, Ctxt1} = bondy_auth:challenge(?WAMP_CRA_AUTH, #{}, Ctxt0),

    ?assertMatch(
        {error, bad_signature},
        bondy_auth:authenticate(?WAMP_CRA_AUTH, <<>>, undefined, Ctxt1)
    ).


random_binary_signature_fails(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    {true, _, Ctxt1} = bondy_auth:challenge(?WAMP_CRA_AUTH, #{}, Ctxt0),

    ?assertMatch(
        {error, bad_signature},
        bondy_auth:authenticate(
            ?WAMP_CRA_AUTH, <<"totally_wrong_sig">>, undefined, Ctxt1
        )
    ).



%% =============================================================================
%% SOURCE / CIDR
%% =============================================================================



user1_allowed_from_any_ip(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    IPs = [{127, 0, 0, 1}, {10, 0, 0, 5}, {8, 8, 8, 8}],
    lists:foreach(
        fun(IP) ->
            {ok, Ctxt} = bondy_auth:init(
                SessionId, RealmUri, ?U1, [], IP
            ),
            ?assert(
                lists:member(
                    ?WAMP_CRA_AUTH, bondy_auth:available_methods(Ctxt)
                )
            )
        end,
        IPs
    ).


user2_rejected_outside_cidr(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U2, [], {10, 0, 0, 1}
    ),
    ?assertNot(
        lists:member(?WAMP_CRA_AUTH, bondy_auth:available_methods(Ctxt))
    ).


user2_allowed_within_cidr(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U2, [], {192, 168, 1, 50}
    ),
    ?assert(
        lists:member(?WAMP_CRA_AUTH, bondy_auth:available_methods(Ctxt0))
    ),

    %% Full flow within CIDR
    {true, Extra, Ctxt1} = bondy_auth:challenge(?WAMP_CRA_AUTH, #{}, Ctxt0),
    Signature = compute_signature(?P1, Extra),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?WAMP_CRA_AUTH, Signature, undefined, Ctxt1)
    ).



%% =============================================================================
%% METHOD SELECTION
%% =============================================================================



method_mismatch_after_challenge(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    {true, _, Ctxt1} = bondy_auth:challenge(?WAMP_CRA_AUTH, #{}, Ctxt0),

    %% After challenge with CRA, trying to authenticate with a different
    %% method should fail
    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt1)
    ).


password_auth_not_in_cra_only_realm(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    %% Realm only allows CRA; password should not be available
    ?assertNot(
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt))
    ).


invalid_method_rejected(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(
            <<"bogus_method">>, <<"data">>, undefined, Ctxt
        )
    ).



%% =============================================================================
%% USER WITHOUT PASSWORD
%% =============================================================================



user_without_password_excluded(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U_NOPASS, [], {127, 0, 0, 1}
    ),
    %% CRA requires password with cra protocol; user without password excluded
    ?assertNot(
        lists:member(?WAMP_CRA_AUTH, bondy_auth:available_methods(Ctxt))
    ).



%% =============================================================================
%% ERROR CASES
%% =============================================================================



nonexistent_user_error(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    ?assertMatch(
        {error, {no_such_user, <<"ghost">>}},
        bondy_auth:init(SessionId, RealmUri, <<"ghost">>, [], {127, 0, 0, 1})
    ).


nonexistent_realm_error(_Config) ->
    SessionId = bondy_session_id:new(),

    ?assertMatch(
        {error, {no_such_realm, <<"com.no.such.realm">>}},
        bondy_auth:init(
            SessionId,
            <<"com.no.such.realm">>,
            ?U1,
            [],
            {127, 0, 0, 1}
        )
    ).



%% =============================================================================
%% CONTEXT AFTER CHALLENGE
%% =============================================================================



context_method_set_after_challenge(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    %% Before challenge, method is not set
    ?assertEqual(error, maps:find(method, Ctxt0)),

    %% After challenge, method is set
    {true, _, Ctxt1} = bondy_auth:challenge(?WAMP_CRA_AUTH, #{}, Ctxt0),
    ?assertEqual(?WAMP_CRA_AUTH, bondy_auth:method(Ctxt1)),
    ?assertEqual(RealmUri, bondy_auth:realm_uri(Ctxt1)),
    ?assertEqual(?U1, bondy_auth:user_id(Ctxt1)).
