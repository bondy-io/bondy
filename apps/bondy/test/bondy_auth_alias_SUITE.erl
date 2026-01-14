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
        test_1,
        sso
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.auth_alias">>,
    ok = add_realm(RealmUri),
    [{realm_uri, RealmUri}|Config].

end_per_suite(Config) ->
    % bondy_ct:stop_bondy(),
    {save_config, Config}.


add_realm(RealmUri) ->
    _ = bondy_realm:create(maps:merge(?REALM, #{uri => RealmUri})),
    ok.


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

