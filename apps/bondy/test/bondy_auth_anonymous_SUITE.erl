%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_auth_anonymous_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        %% Original test (preserved)
        test,

        %% Challenge behaviour
        challenge_returns_false,

        %% Successful anonymous auth
        anonymous_auth_succeeds,
        anonymous_auth_returns_empty_extra,

        %% Named user cannot use anonymous
        named_user_cannot_use_anon,

        %% Method selection
        anon_not_available_when_not_in_realm,
        invalid_method_rejected,
        method_not_allowed_for_anon,

        %% CIDR filtering
        anonymous_from_any_ip,

        %% Error cases
        nonexistent_realm_error,

        %% Context
        context_user_id_is_anonymous,

        %% Coexistence with other methods
        anon_coexists_with_password,

        %% Security disabled
        security_disabled_allows_anon
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.auth_anonymous">>,
    ok = add_realm(RealmUri),
    AnonOnlyRealmUri = <<"com.example.test.auth_anonymous_only">>,
    ok = add_anon_only_realm(AnonOnlyRealmUri),
    DisabledRealmUri = <<"com.example.test.auth_anonymous_disabled">>,
    ok = add_security_disabled_realm(DisabledRealmUri),
    [
        {realm_uri, RealmUri},
        {anon_only_realm_uri, AnonOnlyRealmUri},
        {disabled_realm_uri, DisabledRealmUri}
        | Config
    ].

end_per_suite(Config) ->
    {save_config, Config}.


add_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?WAMP_ANON_AUTH, ?PASSWORD_AUTH
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
            },
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
                roles => [<<"anonymous">>]
            }
        ],
        users => [
            #{
                username => <<"named_user">>,
                password => <<"Secret123">>,
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            #{
                usernames => <<"all">>,
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [<<"anonymous">>],
                authmethod => ?WAMP_ANON_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },
    _ = bondy_realm:create(Config),
    ok.


add_anon_only_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => true,
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => [<<"anonymous">>]
            }
        ],
        sources => [
            #{
                usernames => [<<"anonymous">>],
                authmethod => ?WAMP_ANON_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },
    _ = bondy_realm:create(Config),
    ok.


add_security_disabled_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => false
    },
    _ = bondy_realm:create(Config),
    ok.



%% =============================================================================
%% ORIGINAL TEST (PRESERVED)
%% =============================================================================



test(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Roles = [],
    SourceIP = {127, 0, 0, 1},
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, anonymous, Roles, SourceIP
    ),

    ?assertMatch(
        {false, _},
        bondy_auth:challenge(?WAMP_ANON_AUTH, undefined, Ctxt)
    ),


    ?assertEqual(
        true,
        lists:member(?WAMP_ANON_AUTH, bondy_auth:available_methods(Ctxt))
    ),

    ?assertMatch(
        {ok, _, _},
        authenticate(?WAMP_ANON_AUTH, RealmUri, Roles, SourceIP)
    ),

    ?assertMatch(
        {error, method_not_allowed},
        authenticate(?PASSWORD_AUTH, RealmUri, Roles, SourceIP)
    ),

    ?assertMatch(
        {error, invalid_method},
        authenticate(<<"foo">>, RealmUri, Roles, SourceIP)
    ).



authenticate(Method, Uri, Roles, Peer) ->
    SessionId = bondy_session_id:new(),
    Roles = [],
    {ok, Ctxt} = bondy_auth:init(SessionId, Uri, anonymous, Roles, Peer),
    bondy_auth:authenticate(Method, undefined, undefined, Ctxt).



%% =============================================================================
%% CHALLENGE BEHAVIOUR
%% =============================================================================



challenge_returns_false(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, anonymous, [], {127, 0, 0, 1}
    ),

    %% Anonymous auth does not use challenge-response; challenge returns false
    ?assertMatch(
        {false, _},
        bondy_auth:challenge(?WAMP_ANON_AUTH, #{}, Ctxt)
    ).



%% =============================================================================
%% SUCCESSFUL ANONYMOUS AUTH
%% =============================================================================



anonymous_auth_succeeds(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, anonymous, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?WAMP_ANON_AUTH, undefined, undefined, Ctxt)
    ).


anonymous_auth_returns_empty_extra(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, anonymous, [], {127, 0, 0, 1}
    ),
    {ok, Extra, _} = bondy_auth:authenticate(
        ?WAMP_ANON_AUTH, undefined, undefined, Ctxt
    ),
    ?assertEqual(#{}, Extra).



%% =============================================================================
%% NAMED USER CANNOT USE ANONYMOUS
%% =============================================================================



named_user_cannot_use_anon(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% A named user should not have anonymous in available methods
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, <<"named_user">>, [], {127, 0, 0, 1}
    ),
    ?assertNot(
        lists:member(?WAMP_ANON_AUTH, bondy_auth:available_methods(Ctxt))
    ).



%% =============================================================================
%% METHOD SELECTION
%% =============================================================================



anon_not_available_when_not_in_realm(_Config) ->
    %% Create a realm that only allows PASSWORD_AUTH
    RealmUri = <<"com.example.test.no_anon_realm">>,
    _ = bondy_realm:create(#{
        uri => RealmUri,
        authmethods => [?PASSWORD_AUTH],
        security_enabled => true,
        sources => [
            #{
                usernames => [<<"anonymous">>],
                authmethod => ?WAMP_ANON_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    }),
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, anonymous, undefined, {127, 0, 0, 1}
    ),

    %% Anonymous method should not be available since realm doesn't allow it
    ?assertNot(
        lists:member(?WAMP_ANON_AUTH, bondy_auth:available_methods(Ctxt))
    ).


invalid_method_rejected(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, anonymous, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(
            <<"nonexistent_method">>, undefined, undefined, Ctxt
        )
    ).


method_not_allowed_for_anon(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, anonymous, [], {127, 0, 0, 1}
    ),

    %% Password auth requires identification, anonymous can't use it
    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(
            ?PASSWORD_AUTH, <<"anything">>, undefined, Ctxt
        )
    ).



%% =============================================================================
%% CIDR FILTERING
%% =============================================================================



anonymous_from_any_ip(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% Source is 0.0.0.0/0 for anonymous, should work from any IP
    IPs = [{127, 0, 0, 1}, {10, 0, 0, 5}, {192, 168, 1, 1}, {8, 8, 8, 8}],
    lists:foreach(
        fun(IP) ->
            {ok, Ctxt} = bondy_auth:init(
                SessionId, RealmUri, anonymous, [], IP
            ),
            ?assert(
                lists:member(
                    ?WAMP_ANON_AUTH, bondy_auth:available_methods(Ctxt)
                )
            )
        end,
        IPs
    ).



%% =============================================================================
%% ERROR CASES
%% =============================================================================



nonexistent_realm_error(_Config) ->
    SessionId = bondy_session_id:new(),

    ?assertMatch(
        {error, {no_such_realm, <<"com.does.not.exist">>}},
        bondy_auth:init(
            SessionId,
            <<"com.does.not.exist">>,
            anonymous,
            [],
            {127, 0, 0, 1}
        )
    ).



%% =============================================================================
%% CONTEXT
%% =============================================================================



context_user_id_is_anonymous(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, anonymous, [], {127, 0, 0, 1}
    ),

    ?assertEqual(anonymous, bondy_auth:user_id(Ctxt)),
    ?assertEqual(RealmUri, bondy_auth:realm_uri(Ctxt)),
    ?assertEqual(SessionId, bondy_auth:session_id(Ctxt)),
    ?assertEqual({127, 0, 0, 1}, bondy_auth:source_ip(Ctxt)).



%% =============================================================================
%% COEXISTENCE WITH OTHER METHODS
%% =============================================================================



anon_coexists_with_password(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% When anonymous user connects to a realm with both anon and password,
    %% only anon should be available
    {ok, AnonCtxt} = bondy_auth:init(
        SessionId, RealmUri, anonymous, [], {127, 0, 0, 1}
    ),
    AnonMethods = bondy_auth:available_methods(AnonCtxt),
    ?assert(lists:member(?WAMP_ANON_AUTH, AnonMethods)),
    ?assertNot(lists:member(?PASSWORD_AUTH, AnonMethods)),

    %% When named user connects, password should be available but not anon
    {ok, NamedCtxt} = bondy_auth:init(
        SessionId, RealmUri, <<"named_user">>, [], {127, 0, 0, 1}
    ),
    NamedMethods = bondy_auth:available_methods(NamedCtxt),
    ?assert(lists:member(?PASSWORD_AUTH, NamedMethods)),
    ?assertNot(lists:member(?WAMP_ANON_AUTH, NamedMethods)).



%% =============================================================================
%% SECURITY DISABLED
%% =============================================================================



security_disabled_allows_anon(Config) ->
    RealmUri = ?config(disabled_realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, anonymous, undefined, {127, 0, 0, 1}
    ),
    ?assert(
        lists:member(?WAMP_ANON_AUTH, bondy_auth:available_methods(Ctxt))
    ).
