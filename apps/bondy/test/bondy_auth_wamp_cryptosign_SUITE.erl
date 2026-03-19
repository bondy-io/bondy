%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_auth_wamp_cryptosign_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).
-define(U_NOKEYS, <<"user_no_keys">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        %% Original test (preserved)
        test_1,

        %% Full sign-verify flow
        full_cryptosign_flow,
        challenge_extra_has_required_keys,

        %% Wrong key / signature
        wrong_key_signature_fails,
        invalid_hex_encoding_fails,
        missing_pubkey_in_challenge,
        no_matching_pubkey_in_challenge,

        %% CIDR filtering
        user1_allowed_from_any_ip,
        user2_rejected_outside_cidr,

        %% Method selection
        method_mismatch_after_challenge,
        invalid_method_rejected,

        %% User without authorized keys
        user_without_keys_excluded,

        %% Error cases
        nonexistent_user_error,

        %% Context after challenge
        context_method_set_after_challenge
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    KeyPairs = [
        bondy_cryptosign:generate_key()
        || _ <- lists:seq(1, 3)
    ],
    RealmUri = <<"com.example.test.auth_cryptosign">>,
    ok = add_realm(RealmUri, KeyPairs),

    [{realm_uri, RealmUri}, {keypairs, KeyPairs} | Config].

end_per_suite(Config) ->
    {save_config, Config}.


add_realm(RealmUri, KeyPairs) ->
    PubKeys = [
        maps:get(public, KeyPair)
        || KeyPair <- KeyPairs
    ],

    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?WAMP_CRYPTOSIGN_AUTH
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
                authorized_keys => PubKeys,
                groups => [],
                meta => #{}
            },
            #{
                username => ?U2,
                authorized_keys => PubKeys,
                groups => [],
                meta => #{}
            },
            #{
                username => ?U_NOKEYS,
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            #{
                usernames => [?U1],
                authmethod => ?WAMP_CRYPTOSIGN_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [?U2],
                authmethod => ?WAMP_CRYPTOSIGN_AUTH,
                cidr => <<"198.162.0.0/16">>
            },
            #{
                usernames => [?U_NOKEYS],
                authmethod => ?WAMP_CRYPTOSIGN_AUTH,
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
encode_hex(Bin) when is_binary(Bin) ->
    list_to_binary(hex_utils:bin_to_hexstr(Bin)).


%% @private
make_details(KeyPair) ->
    #{
        authextra => #{
            <<"pubkey">> => encode_hex(maps:get(public, KeyPair))
        }
    }.


%% @private
sign_challenge(HexMessage, KeyPair) ->
    Message = hex_utils:hexstr_to_bin(HexMessage),
    encode_hex(bondy_cryptosign:sign(Message, KeyPair)).



%% =============================================================================
%% ORIGINAL TEST (PRESERVED)
%% =============================================================================



test_1(Config) ->
    RealmUri = ?config(realm_uri, Config),
    KeyPairs = ?config(keypairs, Config),

    SessionId = bondy_session_id:new(),
    Roles = [],
    SourceIP = {127, 0, 0, 1},

    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, SourceIP),


    ?assertEqual(
        true,
        lists:member(?WAMP_CRYPTOSIGN_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    [KeyPair] = lists_utils:random(KeyPairs, 1),

    Details = #{
        authextra => #{
            <<"pubkey">> => list_to_binary(
                hex_utils:bin_to_hexstr(maps:get(public, KeyPair))
            )
        }
    },

    {true, Extra, NewCtxt1} = bondy_auth:challenge(
        ?WAMP_CRYPTOSIGN_AUTH, Details, Ctxt1
    ),

    HexMessage = maps:get(challenge, Extra, undefined),

    ?assertNotEqual(undefined, HexMessage, "Challenge should be present"),

    ?assertEqual(
        undefined,
        maps:get(channel_binding, Extra, undefined),
        "Channel binding not supported yet, should be undefined"
    ),


    %% We simulate the response from the client
    Message = hex_utils:hexstr_to_bin(HexMessage),
    Signature = list_to_binary(
        hex_utils:bin_to_hexstr(
            bondy_cryptosign:sign(Message, KeyPair)
        )
    ),


    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(
            ?WAMP_CRYPTOSIGN_AUTH, Signature, undefined, NewCtxt1
        )
    ),
    ?assertMatch(
        {error, invalid_signature},
        bondy_auth:authenticate(
            ?WAMP_CRYPTOSIGN_AUTH, <<"foo">>, undefined, NewCtxt1
        )
    ),

    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(?PASSWORD_AUTH, <<"foo">>, undefined, Ctxt1)
    ),

    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(<<"foo">>, <<"foo">>, undefined, Ctxt1)
    ),

    %% user 2 is not granted access from Peer (see test_2)
    {ok, Ctxt2} = bondy_auth:init(SessionId, RealmUri, ?U2, Roles, SourceIP),

    ?assertEqual(
        false,
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt2))
    ),

    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(?PASSWORD_AUTH, <<"foo">>, undefined, Ctxt2)
    ).



%% =============================================================================
%% FULL CRYPTOSIGN FLOW
%% =============================================================================



full_cryptosign_flow(Config) ->
    RealmUri = ?config(realm_uri, Config),
    KeyPairs = ?config(keypairs, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    %% Use first key pair
    KeyPair = hd(KeyPairs),
    Details = make_details(KeyPair),

    %% Step 1: Challenge
    {true, Extra, Ctxt1} = bondy_auth:challenge(
        ?WAMP_CRYPTOSIGN_AUTH, Details, Ctxt0
    ),

    %% Step 2: Sign and authenticate
    HexChallenge = maps:get(challenge, Extra),
    Signature = sign_challenge(HexChallenge, KeyPair),

    {ok, AuthExtra, Ctxt2} = bondy_auth:authenticate(
        ?WAMP_CRYPTOSIGN_AUTH, Signature, undefined, Ctxt1
    ),

    %% Cryptosign returns empty extra on success
    ?assertEqual(#{}, AuthExtra),
    ?assertEqual(?WAMP_CRYPTOSIGN_AUTH, bondy_auth:method(Ctxt2)).


challenge_extra_has_required_keys(Config) ->
    RealmUri = ?config(realm_uri, Config),
    KeyPairs = ?config(keypairs, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    Details = make_details(hd(KeyPairs)),
    {true, Extra, _} = bondy_auth:challenge(
        ?WAMP_CRYPTOSIGN_AUTH, Details, Ctxt0
    ),

    %% Challenge extra must have 'challenge' key (hex-encoded)
    ?assert(maps:is_key(challenge, Extra)),
    ?assert(is_binary(maps:get(challenge, Extra))),
    ?assert(byte_size(maps:get(challenge, Extra)) > 0).



%% =============================================================================
%% WRONG KEY / SIGNATURE
%% =============================================================================



wrong_key_signature_fails(Config) ->
    RealmUri = ?config(realm_uri, Config),
    KeyPairs = ?config(keypairs, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    %% Challenge with a valid key
    Details = make_details(hd(KeyPairs)),
    {true, Extra, Ctxt1} = bondy_auth:challenge(
        ?WAMP_CRYPTOSIGN_AUTH, Details, Ctxt0
    ),

    %% Sign with a different (not registered) key
    WrongKeyPair = bondy_cryptosign:generate_key(),
    HexChallenge = maps:get(challenge, Extra),
    WrongSig = sign_challenge(HexChallenge, WrongKeyPair),

    ?assertMatch(
        {error, invalid_signature},
        bondy_auth:authenticate(
            ?WAMP_CRYPTOSIGN_AUTH, WrongSig, undefined, Ctxt1
        )
    ).


invalid_hex_encoding_fails(Config) ->
    RealmUri = ?config(realm_uri, Config),
    KeyPairs = ?config(keypairs, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    Details = make_details(hd(KeyPairs)),
    {true, _, Ctxt1} = bondy_auth:challenge(
        ?WAMP_CRYPTOSIGN_AUTH, Details, Ctxt0
    ),

    %% Non-hex string should fail
    ?assertMatch(
        {error, invalid_signature},
        bondy_auth:authenticate(
            ?WAMP_CRYPTOSIGN_AUTH, <<"not_hex!!!">>, undefined, Ctxt1
        )
    ).


missing_pubkey_in_challenge(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    %% Challenge without pubkey in authextra
    ?assertMatch(
        {error, missing_pubkey},
        bondy_auth:challenge(
            ?WAMP_CRYPTOSIGN_AUTH, #{authextra => #{}}, Ctxt0
        )
    ).


no_matching_pubkey_in_challenge(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    %% Challenge with a pubkey not in the user's authorized_keys
    UnknownKeyPair = bondy_cryptosign:generate_key(),
    Details = make_details(UnknownKeyPair),

    ?assertMatch(
        {error, no_matching_pubkey},
        bondy_auth:challenge(?WAMP_CRYPTOSIGN_AUTH, Details, Ctxt0)
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
                    ?WAMP_CRYPTOSIGN_AUTH,
                    bondy_auth:available_methods(Ctxt)
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
        lists:member(
            ?WAMP_CRYPTOSIGN_AUTH, bondy_auth:available_methods(Ctxt)
        )
    ).



%% =============================================================================
%% METHOD SELECTION
%% =============================================================================



method_mismatch_after_challenge(Config) ->
    RealmUri = ?config(realm_uri, Config),
    KeyPairs = ?config(keypairs, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    Details = make_details(hd(KeyPairs)),
    {true, _, Ctxt1} = bondy_auth:challenge(
        ?WAMP_CRYPTOSIGN_AUTH, Details, Ctxt0
    ),

    %% After cryptosign challenge, trying another method fails
    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(?PASSWORD_AUTH, <<"x">>, undefined, Ctxt1)
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
%% USER WITHOUT AUTHORIZED KEYS
%% =============================================================================



user_without_keys_excluded(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U_NOKEYS, [], {127, 0, 0, 1}
    ),
    ?assertNot(
        lists:member(
            ?WAMP_CRYPTOSIGN_AUTH, bondy_auth:available_methods(Ctxt)
        )
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



%% =============================================================================
%% CONTEXT AFTER CHALLENGE
%% =============================================================================



context_method_set_after_challenge(Config) ->
    RealmUri = ?config(realm_uri, Config),
    KeyPairs = ?config(keypairs, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    Details = make_details(hd(KeyPairs)),
    {true, _, Ctxt1} = bondy_auth:challenge(
        ?WAMP_CRYPTOSIGN_AUTH, Details, Ctxt0
    ),

    ?assertEqual(?WAMP_CRYPTOSIGN_AUTH, bondy_auth:method(Ctxt1)),
    ?assertEqual(RealmUri, bondy_auth:realm_uri(Ctxt1)),
    ?assertEqual(?U1, bondy_auth:user_id(Ctxt1)).
