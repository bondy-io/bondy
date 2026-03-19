%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_auth_alias_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).
-define(P1, <<"aWe11KeptSecret">>).
-define(P2, <<"An0therWe11KeptSecret">>).
-define(REALM, #{
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
        }
    ]
}).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        %% Original tests (preserved)
        test_1,
        sso,

        %% Alias authentication
        alias_auth_correct_password,
        alias_auth_wrong_password,

        %% Alias lifecycle
        remove_alias_then_fail,
        alias_not_found_after_remove,

        %% Multiple aliases
        multiple_aliases_same_user,

        %% Alias with CIDR restriction
        alias_respects_cidr,

        %% Context via alias
        context_user_id_is_username_not_alias
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.auth_alias">>,
    ok = add_realm(RealmUri),
    [{realm_uri, RealmUri}|Config].

end_per_suite(Config) ->
    {save_config, Config}.


add_realm(RealmUri) ->
    _ = bondy_realm:create(maps:merge(?REALM, #{uri => RealmUri})),
    ok.



%% =============================================================================
%% ORIGINAL TESTS (PRESERVED)
%% =============================================================================



test_1(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Roles = [],
    SourceIP = {127, 0, 0, 1},
    Alias = <<?U1/binary, ":alias1">>,

    ok = bondy_rbac_user:add_alias(RealmUri, ?U1, Alias),

    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, Alias, Roles, SourceIP),


    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt1)
    ),

    ok = bondy_rbac_user:remove_alias(RealmUri, ?U1, Alias),

    ?assertEqual(
        {error,{no_such_user, Alias}},
        bondy_auth:init(SessionId, RealmUri, Alias, Roles, SourceIP)
    ).


sso(_) ->
    SSOUri = <<"com.leapsight.test+auth_alias_sso">>,
    Uri = <<"com.leapsight.test+auth_alias">>,

    _ = bondy_realm:create(maps:merge(?REALM, #{
        uri => SSOUri,
        is_sso_realm => true,
        users => [],
        sources => [
            #{
                usernames => <<"all">>,
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]

    })),
    _ = bondy_realm:create(maps:merge(?REALM, #{
        uri => Uri,
        authmethods => [?PASSWORD_AUTH],
        is_sso_realm => false,
        sso_realm_uri => SSOUri,
        users => [],
        sources => [
            #{
                usernames => <<"all">>,
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    })),

    User = #{
        username => ?U1,
        password => ?P1,
        sso_realm_uri => SSOUri
    },
    SessionId = bondy_session_id:new(),
    Roles = [],
    SourceIP = {127, 0, 0, 1},
    Alias = <<?U1/binary, ":alias2">>,

    {ok, _} = bondy_rbac_user:add(Uri, bondy_rbac_user:new(User)),

    {ok, Ctxt1} = bondy_auth:init(SessionId, SSOUri, ?U1, Roles, SourceIP),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt1)
    ),

    {ok, Ctxt2} = bondy_auth:init(SessionId, Uri, ?U1, Roles, SourceIP),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt2)
    ),

    ok = bondy_rbac_user:add_alias(Uri, ?U1, Alias),


    {ok, Ctxt3} = bondy_auth:init(SessionId, SSOUri, Alias, Roles, SourceIP),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt3)
    ),

    {ok, Ctxt4} = bondy_auth:init(SessionId, Uri, Alias, Roles, SourceIP),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt4)
    ),

    ok = bondy_rbac_user:remove_alias(Uri, ?U1, Alias),

    ?assertEqual(
        {error,{no_such_user, Alias}},
        bondy_auth:init(SessionId, SSOUri, Alias, Roles, SourceIP)
    ),
    ?assertEqual(
        {error,{no_such_user, Alias}},
        bondy_auth:init(SessionId, Uri, Alias, Roles, SourceIP)
    ).



%% =============================================================================
%% ALIAS AUTHENTICATION
%% =============================================================================



alias_auth_correct_password(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Alias = <<?U1/binary, ":auth_test">>,

    ok = bondy_rbac_user:add_alias(RealmUri, ?U1, Alias),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, Alias, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt)
    ),

    ok = bondy_rbac_user:remove_alias(RealmUri, ?U1, Alias).


alias_auth_wrong_password(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Alias = <<?U1/binary, ":wrong_pass_test">>,

    ok = bondy_rbac_user:add_alias(RealmUri, ?U1, Alias),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, Alias, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {error, bad_signature},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P2, undefined, Ctxt)
    ),

    ok = bondy_rbac_user:remove_alias(RealmUri, ?U1, Alias).



%% =============================================================================
%% ALIAS LIFECYCLE
%% =============================================================================



remove_alias_then_fail(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Alias = <<?U1/binary, ":lifecycle_test">>,

    ok = bondy_rbac_user:add_alias(RealmUri, ?U1, Alias),

    %% Can authenticate via alias
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, Alias, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt)
    ),

    %% Remove alias
    ok = bondy_rbac_user:remove_alias(RealmUri, ?U1, Alias),

    %% Now init should fail
    ?assertMatch(
        {error, {no_such_user, Alias}},
        bondy_auth:init(SessionId, RealmUri, Alias, [], {127, 0, 0, 1})
    ).


alias_not_found_after_remove(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Alias = <<?U1/binary, ":not_found_test">>,

    %% Alias that was never added should not resolve
    ?assertMatch(
        {error, {no_such_user, Alias}},
        bondy_auth:init(SessionId, RealmUri, Alias, [], {127, 0, 0, 1})
    ).



%% =============================================================================
%% MULTIPLE ALIASES
%% =============================================================================



multiple_aliases_same_user(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Alias1 = <<?U1/binary, ":multi_a">>,
    Alias2 = <<?U1/binary, ":multi_b">>,

    ok = bondy_rbac_user:add_alias(RealmUri, ?U1, Alias1),
    ok = bondy_rbac_user:add_alias(RealmUri, ?U1, Alias2),

    %% Both aliases should work
    {ok, C1} = bondy_auth:init(
        SessionId, RealmUri, Alias1, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, C1)
    ),

    {ok, C2} = bondy_auth:init(
        SessionId, RealmUri, Alias2, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, C2)
    ),

    %% Removing one shouldn't affect the other
    ok = bondy_rbac_user:remove_alias(RealmUri, ?U1, Alias1),

    ?assertMatch(
        {error, {no_such_user, Alias1}},
        bondy_auth:init(SessionId, RealmUri, Alias1, [], {127, 0, 0, 1})
    ),

    {ok, C3} = bondy_auth:init(
        SessionId, RealmUri, Alias2, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, C3)
    ),

    ok = bondy_rbac_user:remove_alias(RealmUri, ?U1, Alias2).



%% =============================================================================
%% ALIAS WITH CIDR RESTRICTION
%% =============================================================================



alias_respects_cidr(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Alias = <<?U2/binary, ":cidr_test">>,

    ok = bondy_rbac_user:add_alias(RealmUri, ?U2, Alias),

    %% U2 has CIDR 192.168.0.0/16; alias should respect the same restriction.
    %% From outside CIDR: password method not available
    {ok, Ctxt1} = bondy_auth:init(
        SessionId, RealmUri, Alias, [], {10, 0, 0, 1}
    ),
    ?assertNot(
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    %% From within CIDR: password method available
    {ok, Ctxt2} = bondy_auth:init(
        SessionId, RealmUri, Alias, [], {192, 168, 1, 1}
    ),
    ?assert(
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt2))
    ),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt2)
    ),

    ok = bondy_rbac_user:remove_alias(RealmUri, ?U2, Alias).



%% =============================================================================
%% CONTEXT VIA ALIAS
%% =============================================================================



context_user_id_is_username_not_alias(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Alias = <<?U1/binary, ":ctxt_test">>,

    ok = bondy_rbac_user:add_alias(RealmUri, ?U1, Alias),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, Alias, [], {127, 0, 0, 1}
    ),

    %% The context user_id should be the real username, not the alias
    ?assertEqual(?U1, bondy_auth:user_id(Ctxt)),
    ?assertEqual(RealmUri, bondy_auth:realm_uri(Ctxt)),

    ok = bondy_rbac_user:remove_alias(RealmUri, ?U1, Alias).
