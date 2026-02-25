%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_auth_password_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).
-define(U3, <<"user_3">>).
-define(U4, <<"user_no_password">>).
-define(P1, <<"aWe11KeptSecret">>).
-define(P2, <<"An0therWe11KeptSecret">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        %% Original tests (preserved)
        test_1,
        test_2,

        %% Source/CIDR filtering
        user1_allowed_from_any_ip,
        user2_rejected_outside_cidr,
        user2_allowed_within_cidr,

        %% Correct password / wrong password
        correct_password_succeeds,
        wrong_password_fails,
        empty_password_string_fails,

        %% Challenge step
        challenge_returns_true_empty_map,

        %% Method selection
        method_not_in_realm_rejected,
        invalid_method_name_rejected,
        already_set_method_mismatch,

        %% User without password
        user_without_password_excluded,

        %% Anonymous user
        anonymous_user_password_not_available,

        %% Non-existent user
        nonexistent_user_error,

        %% Non-existent realm
        nonexistent_realm_error,

        %% Authenticate returns empty extra map
        authenticate_returns_empty_extra,

        %% Context accessors
        context_accessors,

        %% Multiple auth methods on realm
        password_coexists_with_other_methods,

        %% Authenticate via challenge then authenticate
        full_challenge_authenticate_flow,

        %% Multiple source CIDRs for same user
        multiple_source_cidrs
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.auth_password">>,
    ok = add_realm(RealmUri),
    MultiRealmUri = <<"com.example.test.auth_password_multi">>,
    ok = add_multi_method_realm(MultiRealmUri),
    MultiCidrRealmUri = <<"com.example.test.auth_password_cidr">>,
    ok = add_multi_cidr_realm(MultiCidrRealmUri),
    [
        {realm_uri, RealmUri},
        {multi_realm_uri, MultiRealmUri},
        {multi_cidr_realm_uri, MultiCidrRealmUri}
        | Config
    ].

end_per_suite(Config) ->
    {save_config, Config}.


add_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?PASSWORD_AUTH
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
                username => ?U4,
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            #{
                usernames => [?U1],
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [?U2],
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"192.168.0.0/16">>
            },
            #{
                usernames => [?U4],
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },
    _ = bondy_realm:create(Config),
    ok.


add_multi_method_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"A realm with multiple auth methods">>,
        authmethods => [
            ?PASSWORD_AUTH,
            ?WAMP_CRA_AUTH,
            ?WAMP_ANON_AUTH
        ],
        security_enabled => true,
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => <<"all">>
            }
        ],
        users => [
            #{
                username => ?U3,
                password => ?P2,
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            #{
                usernames => [?U3],
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [?U3],
                authmethod => ?WAMP_CRA_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => all,
                authmethod => ?WAMP_ANON_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },
    _ = bondy_realm:create(Config),
    ok.


add_multi_cidr_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"A realm testing multiple CIDRs per user">>,
        authmethods => [
            ?PASSWORD_AUTH
        ],
        security_enabled => true,
        grants => [
            #{
                permissions => [<<"wamp.call">>],
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
            }
        ],
        sources => [
            #{
                usernames => [?U1],
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"10.0.0.0/8">>
            },
            #{
                usernames => [?U1],
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"172.16.0.0/12">>
            }
        ]
    },
    _ = bondy_realm:create(Config),
    ok.



%% =============================================================================
%% ORIGINAL TESTS (PRESERVED)
%% =============================================================================



test_1(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Roles = [],
    SourceIP = {127, 0, 0, 1},

    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, SourceIP),

    ?assertEqual(
        true,
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt1)
    ),
    ?assertMatch(
        {error, bad_signature},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P2, undefined, Ctxt1)
    ),

    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(?WAMP_CRA_AUTH, ?P1, undefined, Ctxt1)
    ),

    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(<<"foo">>, ?P1, undefined, Ctxt1)
    ),

    %% user 2 is not granted access from Peer (see test_2)
    {ok, Ctxt2} = bondy_auth:init(SessionId, RealmUri, ?U2, Roles, SourceIP),

    ?assertEqual(
        false,
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt2))
    ),

    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt2)
    ).



test_2(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Roles = [],
    SourceIP = {192, 168, 1, 45},

    {ok, Ctxt2} = bondy_auth:init(SessionId, RealmUri, ?U2, Roles, SourceIP),

    ?assertEqual(
        true,
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt2))
    ),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt2)
    ),
    ?assertMatch(
        {error, bad_signature},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P2, undefined, Ctxt2)
    ),

    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(?WAMP_CRA_AUTH, ?P1, undefined, Ctxt2)
    ),

    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(<<"foo">>, ?P1, undefined, Ctxt2)
    ),

    %% user 1 is granted access from any net (see test_1)
    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, SourceIP),

    ?assertEqual(
        true,
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt1)
    ).



%% =============================================================================
%% SOURCE / CIDR FILTERING
%% =============================================================================



user1_allowed_from_any_ip(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% U1 has source 0.0.0.0/0 — should work from localhost
    {ok, C1} = bondy_auth:init(SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}),
    ?assert(lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(C1))),

    %% U1 should also work from a private IP
    {ok, C2} = bondy_auth:init(SessionId, RealmUri, ?U1, [], {10, 0, 0, 5}),
    ?assert(lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(C2))),

    %% U1 should also work from a public IP
    {ok, C3} = bondy_auth:init(SessionId, RealmUri, ?U1, [], {8, 8, 8, 8}),
    ?assert(lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(C3))).


user2_rejected_outside_cidr(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% U2 has source 192.168.0.0/16 — should be rejected from 10.x.x.x
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U2, [], {10, 0, 0, 1}
    ),
    ?assertNot(lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt))),

    %% Trying to authenticate should fail with method_not_allowed
    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt)
    ).


user2_allowed_within_cidr(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% U2 has source 192.168.0.0/16 — should succeed from 192.168.x.x
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U2, [], {192, 168, 50, 100}
    ),
    ?assert(lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt))),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt)
    ).



%% =============================================================================
%% PASSWORD VERIFICATION
%% =============================================================================



correct_password_succeeds(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt)
    ).


wrong_password_fails(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {error, bad_signature},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P2, undefined, Ctxt)
    ),
    %% Also try a completely unrelated string
    ?assertMatch(
        {error, bad_signature},
        bondy_auth:authenticate(
            ?PASSWORD_AUTH, <<"totally_wrong">>, undefined, Ctxt
        )
    ).


empty_password_string_fails(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {error, bad_signature},
        bondy_auth:authenticate(?PASSWORD_AUTH, <<>>, undefined, Ctxt)
    ).



%% =============================================================================
%% CHALLENGE STEP
%% =============================================================================



challenge_returns_true_empty_map(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    %% Password auth challenge returns {true, EmptyMap, NewCtxt}
    {true, Extra, Ctxt1} = bondy_auth:challenge(
        ?PASSWORD_AUTH, #{}, Ctxt0
    ),
    ?assertEqual(#{}, Extra),

    %% After challenge, we can authenticate
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt1)
    ).



%% =============================================================================
%% METHOD SELECTION
%% =============================================================================



method_not_in_realm_rejected(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    %% The realm only allows PASSWORD_AUTH; CRA should not be available
    ?assertNot(
        lists:member(?WAMP_CRA_AUTH, bondy_auth:available_methods(Ctxt))
    ),
    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(?WAMP_CRA_AUTH, ?P1, undefined, Ctxt)
    ).


invalid_method_name_rejected(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    %% Totally bogus method name
    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(
            <<"nonexistent_method">>, ?P1, undefined, Ctxt
        )
    ).


already_set_method_mismatch(Config) ->
    RealmUri = ?config(multi_realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U3, [], {127, 0, 0, 1}
    ),

    %% Set method via challenge to PASSWORD_AUTH
    {true, _, Ctxt1} = bondy_auth:challenge(?PASSWORD_AUTH, #{}, Ctxt0),

    %% Now trying to authenticate with a DIFFERENT valid method should fail
    %% because the context method is already set to PASSWORD_AUTH
    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(?WAMP_CRA_AUTH, ?P2, undefined, Ctxt1)
    ).



%% =============================================================================
%% USER WITHOUT PASSWORD
%% =============================================================================



user_without_password_excluded(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% U4 has no password — password auth should not be available even
    %% though the source allows it
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U4, [], {127, 0, 0, 1}
    ),
    ?assertNot(
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt))
    ),
    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(?PASSWORD_AUTH, <<"anything">>, undefined, Ctxt)
    ).



%% =============================================================================
%% ANONYMOUS USER
%% =============================================================================



anonymous_user_password_not_available(Config) ->
    RealmUri = ?config(multi_realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% Anonymous users cannot use password auth (requires identification)
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, anonymous, undefined, {127, 0, 0, 1}
    ),
    ?assertNot(
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt))
    ).



%% =============================================================================
%% ERROR CASES
%% =============================================================================



nonexistent_user_error(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    ?assertMatch(
        {error, {no_such_user, <<"ghost_user">>}},
        bondy_auth:init(
            SessionId, RealmUri, <<"ghost_user">>, [], {127, 0, 0, 1}
        )
    ).


nonexistent_realm_error(_Config) ->
    SessionId = bondy_session_id:new(),

    ?assertMatch(
        {error, {no_such_realm, <<"com.does.not.exist">>}},
        bondy_auth:init(
            SessionId,
            <<"com.does.not.exist">>,
            ?U1,
            [],
            {127, 0, 0, 1}
        )
    ).



%% =============================================================================
%% RETURN VALUES
%% =============================================================================



authenticate_returns_empty_extra(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    {ok, Extra, _} = bondy_auth:authenticate(
        ?PASSWORD_AUTH, ?P1, undefined, Ctxt
    ),
    %% Password auth returns empty extra map on success
    ?assertEqual(#{}, Extra).



%% =============================================================================
%% CONTEXT ACCESSORS
%% =============================================================================



context_accessors(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    SourceIP = {127, 0, 0, 1},

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], SourceIP
    ),

    ?assertEqual(RealmUri, bondy_auth:realm_uri(Ctxt)),
    ?assertEqual(SessionId, bondy_auth:session_id(Ctxt)),
    ?assertEqual(?U1, bondy_auth:user_id(Ctxt)),
    ?assertEqual(SourceIP, bondy_auth:source_ip(Ctxt)),
    ?assertNotEqual(undefined, bondy_auth:user(Ctxt)).



%% =============================================================================
%% MULTIPLE AUTH METHODS
%% =============================================================================



password_coexists_with_other_methods(Config) ->
    RealmUri = ?config(multi_realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U3, [], {127, 0, 0, 1}
    ),

    Methods = bondy_auth:available_methods(Ctxt),

    %% Both password and CRA should be available (user has password with
    %% a protocol in [cra, scram])
    ?assert(lists:member(?PASSWORD_AUTH, Methods)),
    ?assert(lists:member(?WAMP_CRA_AUTH, Methods)),

    %% Anonymous should NOT be available (user is identified)
    ?assertNot(lists:member(?WAMP_ANON_AUTH, Methods)),

    %% Password auth should work
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P2, undefined, Ctxt)
    ).



%% =============================================================================
%% FULL CHALLENGE-AUTHENTICATE FLOW
%% =============================================================================



full_challenge_authenticate_flow(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    %% Step 1: Challenge (for password, always returns {true, #{}, _})
    {true, ChallengeExtra, Ctxt1} = bondy_auth:challenge(
        ?PASSWORD_AUTH, #{}, Ctxt0
    ),
    ?assertEqual(#{}, ChallengeExtra),

    %% Step 2: Authenticate with correct password
    {ok, AuthExtra, Ctxt2} = bondy_auth:authenticate(
        ?PASSWORD_AUTH, ?P1, undefined, Ctxt1
    ),
    ?assertEqual(#{}, AuthExtra),

    %% The method is set in the context after challenge
    ?assertEqual(?PASSWORD_AUTH, bondy_auth:method(Ctxt2)),

    %% Step 2b: Authenticate with wrong password on the same context
    ?assertMatch(
        {error, bad_signature},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P2, undefined, Ctxt1)
    ).



%% =============================================================================
%% MULTIPLE SOURCE CIDRS
%% =============================================================================



multiple_source_cidrs(Config) ->
    RealmUri = ?config(multi_cidr_realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% User has sources for 10.0.0.0/8 and 172.16.0.0/12.
    %% Should work from both ranges.
    {ok, C1} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {10, 0, 0, 5}
    ),
    ?assert(lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(C1))),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, C1)
    ),

    {ok, C2} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {172, 16, 5, 1}
    ),
    ?assert(lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(C2))),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, C2)
    ),

    %% Should NOT work from an IP outside both ranges
    {ok, C3} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {192, 168, 1, 1}
    ),
    ?assertNot(
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(C3))
    ).
