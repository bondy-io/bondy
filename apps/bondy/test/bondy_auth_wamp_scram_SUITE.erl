%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_auth_wamp_scram_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).
-define(U_NOPASS, <<"user_no_password">>).
-define(P1, <<"aWe11KeptSecret">>).
-define(P2, <<"An0therWe11KeptSecret">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        %% Original test (preserved)
        missing_client_nonce,

        %% Full SCRAM flow (was commented out, now enabled)
        test_1,

        %% Password protocol verification
        password_protocol_is_scram,

        %% Challenge extra keys
        challenge_extra_has_required_keys,

        %% Wrong signatures
        wrong_signature_fails,

        %% CIDR filtering
        user1_allowed_from_any_ip,
        user2_rejected_outside_cidr,

        %% Method selection
        method_mismatch_after_challenge,
        invalid_method_rejected,

        %% User without password
        user_without_password_excluded,

        %% Server verifier
        server_verifier_in_auth_extra,

        %% Error cases
        nonexistent_user_error,

        %% Nonce validation
        nonce_mismatch_rejected
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.auth_wamp_scram">>,
    ok = add_realm(RealmUri),

    [{realm_uri, RealmUri} | Config].

end_per_suite(Config) ->
    {save_config, Config}.


add_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?WAMP_SCRAM_AUTH
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
                authmethod => ?WAMP_SCRAM_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [?U2],
                authmethod => ?WAMP_SCRAM_AUTH,
                cidr => <<"198.162.0.0/16">>
            },
            #{
                usernames => [?U_NOPASS],
                authmethod => ?WAMP_SCRAM_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },

    _ = bondy_realm:create(Config),

    ?assertEqual(
        scram,
        bondy_password:protocol(
            bondy_rbac_user:password(
                bondy_rbac_user:fetch(RealmUri, ?U1)
            )
        )
    ),

    ok.



%% =============================================================================
%% HELPERS
%% =============================================================================



%% @private
client_signature(UserId, ClientNonce, ChallengeExtra) ->
    #{
        nonce := ServerNonceB64,
        salt := SaltB64,
        iterations := Iterations
    } = ChallengeExtra,

    ServerNonce = base64:decode(ServerNonceB64),
    Salt = base64:decode(SaltB64),

    AuthMessage = bondy_password_scram:auth_message(
        UserId, ClientNonce, ServerNonce, Salt, Iterations
    ),

    Params0 = maps:with([kdf, iterations, memory], ChallengeExtra),
    Params = Params0#{
        hash_function => bondy_password_scram:hash_function(),
        hash_length => bondy_password_scram:hash_length()
    },

    SPassword = bondy_password_scram:salted_password(?P1, Salt, Params),

    ClientKey = bondy_password_scram:client_key(SPassword),
    StoredKey = bondy_password_scram:stored_key(ClientKey),
    ClientSig = bondy_password_scram:client_signature(
        StoredKey, AuthMessage
    ),
    ClientProof = bondy_password_scram:client_proof(ClientKey, ClientSig),

    base64:encode(ClientProof).


%% @private
client_signature_with_password(UserId, Password, ClientNonce, ChallengeExtra) ->
    #{
        nonce := ServerNonceB64,
        salt := SaltB64,
        iterations := Iterations
    } = ChallengeExtra,

    ServerNonce = base64:decode(ServerNonceB64),
    Salt = base64:decode(SaltB64),

    AuthMessage = bondy_password_scram:auth_message(
        UserId, ClientNonce, ServerNonce, Salt, Iterations
    ),

    Params0 = maps:with([kdf, iterations, memory], ChallengeExtra),
    Params = Params0#{
        hash_function => bondy_password_scram:hash_function(),
        hash_length => bondy_password_scram:hash_length()
    },

    SPassword = bondy_password_scram:salted_password(Password, Salt, Params),

    ClientKey = bondy_password_scram:client_key(SPassword),
    StoredKey = bondy_password_scram:stored_key(ClientKey),
    ClientSig = bondy_password_scram:client_signature(
        StoredKey, AuthMessage
    ),
    ClientProof = bondy_password_scram:client_proof(ClientKey, ClientSig),

    base64:encode(ClientProof).


%% @private
do_challenge(RealmUri, Username) ->
    SessionId = bondy_session_id:new(),
    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, Username, [], {127, 0, 0, 1}
    ),
    ClientNonce = crypto:strong_rand_bytes(16),
    HelloDetails = #{authextra => #{
        <<"nonce">> => base64:encode(ClientNonce)
    }},
    {true, Extra, Ctxt1} = bondy_auth:challenge(
        ?WAMP_SCRAM_AUTH, HelloDetails, Ctxt0
    ),
    {Ctxt0, Ctxt1, Extra, ClientNonce}.



%% =============================================================================
%% ORIGINAL TEST (PRESERVED)
%% =============================================================================



missing_client_nonce(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Roles = [],
    SourceIP = {127, 0, 0, 1},

    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, SourceIP),
    ?assertEqual(
        true,
        lists:member(?WAMP_SCRAM_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ?assertMatch(
        {error, missing_nonce},
        bondy_auth:challenge(?WAMP_SCRAM_AUTH, #{}, Ctxt1)
    ).



%% =============================================================================
%% FULL SCRAM FLOW
%% =============================================================================



test_1(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Roles = [],
    SourceIP = {127, 0, 0, 1},

    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, SourceIP),

    {ok, User} = bondy_rbac_user:lookup(RealmUri, ?U1),

    ?assertEqual(
        scram,
        bondy_password:protocol(bondy_rbac_user:password(User))
    ),
    ?assertEqual(
        true,
        lists:member(?WAMP_SCRAM_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ClientNonce = crypto:strong_rand_bytes(16),
    HelloDetails = #{authextra => #{
        <<"nonce">> => base64:encode(ClientNonce)
    }},
    {true, ChallengeExtra, NewCtxt1} = bondy_auth:challenge(
        ?WAMP_SCRAM_AUTH, HelloDetails, Ctxt1
    ),

    Signature = client_signature(?U1, ClientNonce, ChallengeExtra),

    AuthExtra = #{
        <<"nonce">> => maps:get(nonce, ChallengeExtra),
        <<"channel_binding">> => undefined
    },

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(
            ?WAMP_SCRAM_AUTH, Signature, AuthExtra, NewCtxt1
        )
    ),
    ?assertMatch(
        {error, _},
        bondy_auth:authenticate(
            ?WAMP_SCRAM_AUTH, <<"foo">>, AuthExtra, NewCtxt1
        )
    ),

    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(?PASSWORD_AUTH, <<"foo">>, AuthExtra, NewCtxt1)
    ),

    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(<<"foo">>, <<"foo">>, AuthExtra, NewCtxt1)
    ),

    %% user 2 is not granted access from SourceIP
    {ok, Ctxt2} = bondy_auth:init(SessionId, RealmUri, ?U2, Roles, SourceIP),

    ?assertEqual(
        false,
        lists:member(?WAMP_SCRAM_AUTH, bondy_auth:available_methods(Ctxt2))
    ),

    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(
            ?WAMP_SCRAM_AUTH, <<"foo">>, AuthExtra, Ctxt2
        )
    ).



%% =============================================================================
%% PASSWORD PROTOCOL VERIFICATION
%% =============================================================================



password_protocol_is_scram(Config) ->
    RealmUri = ?config(realm_uri, Config),

    {ok, User} = bondy_rbac_user:lookup(RealmUri, ?U1),
    Password = bondy_rbac_user:password(User),

    ?assertEqual(scram, bondy_password:protocol(Password)).



%% =============================================================================
%% CHALLENGE EXTRA KEYS
%% =============================================================================



challenge_extra_has_required_keys(Config) ->
    RealmUri = ?config(realm_uri, Config),
    {_, _, Extra, _} = do_challenge(RealmUri, ?U1),

    %% SCRAM challenge extra must contain these fields
    ?assert(maps:is_key(nonce, Extra)),
    ?assert(maps:is_key(salt, Extra)),
    ?assert(maps:is_key(kdf, Extra)),
    ?assert(maps:is_key(iterations, Extra)),

    %% nonce and salt are base64-encoded binaries
    ?assert(is_binary(maps:get(nonce, Extra))),
    ?assert(is_binary(maps:get(salt, Extra))),
    ?assert(is_integer(maps:get(iterations, Extra))),
    ?assert(maps:get(iterations, Extra) > 0).



%% =============================================================================
%% WRONG SIGNATURES
%% =============================================================================



wrong_signature_fails(Config) ->
    RealmUri = ?config(realm_uri, Config),
    {_, Ctxt1, ChallengeExtra, ClientNonce} = do_challenge(RealmUri, ?U1),

    AuthExtra = #{
        <<"nonce">> => maps:get(nonce, ChallengeExtra),
        <<"channel_binding">> => undefined
    },

    %% Signature computed with wrong password
    WrongSig = client_signature_with_password(
        ?U1, ?P2, ClientNonce, ChallengeExtra
    ),
    ?assertMatch(
        {error, authentication_failed},
        bondy_auth:authenticate(
            ?WAMP_SCRAM_AUTH, WrongSig, AuthExtra, Ctxt1
        )
    ).



%% =============================================================================
%% CIDR FILTERING
%% =============================================================================



user1_allowed_from_any_ip(Config) ->
    RealmUri = ?config(realm_uri, Config),

    IPs = [{127, 0, 0, 1}, {10, 0, 0, 5}, {8, 8, 8, 8}],
    lists:foreach(
        fun(IP) ->
            SessionId = bondy_session_id:new(),
            {ok, Ctxt} = bondy_auth:init(
                SessionId, RealmUri, ?U1, [], IP
            ),
            ?assert(
                lists:member(
                    ?WAMP_SCRAM_AUTH, bondy_auth:available_methods(Ctxt)
                )
            )
        end,
        IPs
    ).


user2_rejected_outside_cidr(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% U2 source is 198.162.0.0/16; 127.0.0.1 is outside
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U2, [], {127, 0, 0, 1}
    ),
    ?assertNot(
        lists:member(?WAMP_SCRAM_AUTH, bondy_auth:available_methods(Ctxt))
    ).



%% =============================================================================
%% METHOD SELECTION
%% =============================================================================



method_mismatch_after_challenge(Config) ->
    RealmUri = ?config(realm_uri, Config),
    {_, Ctxt1, ChallengeExtra, _} = do_challenge(RealmUri, ?U1),

    AuthExtra = #{
        <<"nonce">> => maps:get(nonce, ChallengeExtra),
        <<"channel_binding">> => undefined
    },

    %% After SCRAM challenge, trying another method should fail
    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, AuthExtra, Ctxt1)
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
    ?assertNot(
        lists:member(?WAMP_SCRAM_AUTH, bondy_auth:available_methods(Ctxt))
    ).



%% =============================================================================
%% SERVER VERIFIER
%% =============================================================================



server_verifier_in_auth_extra(Config) ->
    RealmUri = ?config(realm_uri, Config),
    {_, Ctxt1, ChallengeExtra, ClientNonce} = do_challenge(RealmUri, ?U1),

    Signature = client_signature(?U1, ClientNonce, ChallengeExtra),

    AuthExtra0 = #{
        <<"nonce">> => maps:get(nonce, ChallengeExtra),
        <<"channel_binding">> => undefined
    },

    {ok, AuthExtra, _} = bondy_auth:authenticate(
        ?WAMP_SCRAM_AUTH, Signature, AuthExtra0, Ctxt1
    ),

    %% SCRAM auth extra should contain the server verifier with "v=" prefix
    ?assert(maps:is_key(verifier, AuthExtra)),
    Verifier = maps:get(verifier, AuthExtra),
    ?assertMatch(<<"v=", _/binary>>, Verifier).



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



%% =============================================================================
%% NONCE VALIDATION
%% =============================================================================



nonce_mismatch_rejected(Config) ->
    RealmUri = ?config(realm_uri, Config),
    {_, Ctxt1, ChallengeExtra, ClientNonce} = do_challenge(RealmUri, ?U1),

    Signature = client_signature(?U1, ClientNonce, ChallengeExtra),

    %% Send a wrong nonce in the Extra map
    WrongNonce = base64:encode(crypto:strong_rand_bytes(32)),
    AuthExtra = #{
        <<"nonce">> => WrongNonce,
        <<"channel_binding">> => undefined
    },
    ?assertMatch(
        {error, invalid_nonce},
        bondy_auth:authenticate(
            ?WAMP_SCRAM_AUTH, Signature, AuthExtra, Ctxt1
        )
    ).
