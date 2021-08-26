%% =============================================================================
%%  bondy_rbac_user_SUITE.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

-module(bondy_rbac_user_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_security.hrl").

-define(LU1, <<"local_user_1">>).
-define(LU2, <<"local_user_2">>).
-define(SSOU1, <<"sso_user_1">>).
-define(SSOU2, <<"sso_user_2">>).
-define(REALM1_URI, <<"com.example.test1">>).
-define(REALM2_URI, <<"com.example.test2">>).
-define(SSO_REALM_URI, <<"com.example.test.user.sso">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        test,
        invalid_sso_realm,
        resolve,
        add_sso_user_to_realm,
        update,
        change_password,
        update_groups,
        add_group,
        remove_group
    ].


init_per_suite(Config) ->
    common:start_bondy(),
    KeyPairs = [enacl:crypto_sign_ed25519_keypair() || _ <- lists:seq(1, 3)],
    PubKeys = [
        maps:get(public, KeyPair)
        || KeyPair <- KeyPairs
    ],
    SSORealmUri = ?SSO_REALM_URI,
    ok = add_sso_realm(SSORealmUri),
    ok = add_realm(?REALM1_URI, SSORealmUri, KeyPairs, [
        #{
            username => ?LU1,
            authorized_keys => PubKeys,
            groups => [],
            meta => #{fruit => <<"apple">>}
        },
        #{
            username => ?LU2,
            password => ?LU2,
            groups => [],
            meta => #{fruit => <<"banana">>}
        },
        #{
            username => ?SSOU1,
            authorized_keys => PubKeys,
            groups => [],
            meta => #{fruit => <<"passion fruit">>},
            sso_realm_uri => ?SSO_REALM_URI
        },
        #{
            username => ?SSOU2,
            password => ?SSOU2,
            groups => [],
            meta => #{fruit => <<"orange">>},
            sso_realm_uri => ?SSO_REALM_URI
        }
    ]),
    ok = add_realm(?REALM2_URI, SSORealmUri, KeyPairs, []),
    [{keypairs, KeyPairs} | Config].

end_per_suite(Config) ->
    % common:stop_bondy(),
    {save_config, Config}.


add_sso_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"A test SSO realm">>,
        authmethods => [?WAMP_CRA_AUTH, ?WAMP_CRYPTOSIGN_AUTH],
        security_enabled => true,
        is_sso_realm => true,
        allow_connections => false,
        groups => [
            #{
                name => <<"sso_g1">>
            },
            #{
                name => <<"sso_g2">>
            }
        ]
    },
    _ = bondy_realm:add(Config),
    ok.


add_realm(RealmUri, SSORealmUri, _KeyPairs, Users) ->

    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?WAMP_CRA_AUTH, ?WAMP_CRYPTOSIGN_AUTH, ?PASSWORD_AUTH
        ],
        security_enabled => true,
        sso_realm_uri => SSORealmUri,
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
        groups => [
            #{
                name => <<"a">>
            },
            #{
                name => <<"b">>
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
        ],
        users => Users
    },
    _ = bondy_realm:add(Config),
    ok.



test(_) ->
    _LU1 = bondy_rbac_user:fetch(?REALM1_URI, ?LU1),
    _LU2 = bondy_rbac_user:fetch(?REALM1_URI, ?LU2),
    _ = bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1),
    _ = bondy_rbac_user:fetch(?REALM1_URI, ?SSOU2),
    _SSOU1 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),
    _SSOU2 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU2),
    ok.




resolve(_) ->
    Local = bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1),
    Resolved = bondy_rbac_user:resolve(Local),

    ?assertEqual(
        [],
        bondy_rbac_user:authorized_keys(Local)
    ),

    ?assertNotEqual(
        [],
        bondy_rbac_user:authorized_keys(Resolved)
    ),

    ?assertEqual(
        #{
            fruit => <<"passion fruit">>,
            sso => #{}
        },
        maps:get(meta, Resolved)
    ).


invalid_sso_realm(Config) ->
    KeyPairs = ?config(keypairs, Config),
    PubKeys = [
        maps:get(public, KeyPair)
        || KeyPair <- KeyPairs
    ],
    User0 = #{
        username => ?SSOU1,
        authorized_keys => PubKeys,
        groups => [],
        meta => #{fruit => <<"passion fruit">>},
        sso_realm_uri => <<"com.wrong.uri">>
    },
    ?assertEqual(
        {error, already_exists},
        bondy_rbac_user:add(?REALM1_URI, bondy_rbac_user:new(User0))
    ),

    User1 = User0#{username => <<"foo">>},
    ?assertEqual(
        {error, invalid_sso_realm},
        bondy_rbac_user:add(?REALM1_URI, bondy_rbac_user:new(User1))
    ).


add_sso_user_to_realm(_) ->
    SSOU1 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),
    User0 = #{
        username => ?SSOU1,
        password => <<"thisWillBeDroped">>,
        groups => [],
        meta => #{fruit => <<"passion fruit">>},
        sso_realm_uri => ?SSO_REALM_URI
    },

    ?assertEqual(
        {error, not_found},
        bondy_rbac_user:lookup(?REALM2_URI, ?SSOU1)
    ),

    {ok, NewUser} = bondy_rbac_user:add(
        ?REALM2_URI, bondy_rbac_user:new(User0)
    ),

    %% Because we are adding an existing SSO user to a new Realm the password
    %% is discarded
    ?assertEqual(
        false,
        bondy_rbac_user:has_password(NewUser)
    ),

    %% And the SSO groups, meta were for the SSO user were also discarded
    ?assertEqual(
        SSOU1,
        bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1)
    ).


update(_) ->
    SSOUser0 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),
    User0 = bondy_rbac_user:fetch(?REALM2_URI, ?SSOU1),

    Password = <<"newpassword">>,

    Data0 = #{
        password => Password,
        groups => [],
        sso_realm_uri => ?SSO_REALM_URI
    },

    ?assertEqual(
        {ok, User0},
        bondy_rbac_user:update(
            ?REALM2_URI, ?SSOU1, Data0, #{update_credentials => false}
        )
    ),
    ?assertEqual(
        SSOUser0,
        bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1)
    ),


    ?assertEqual(
        {ok, User0},
        bondy_rbac_user:update(
            ?REALM2_URI, ?SSOU1, Data0, #{update_credentials => true}
        )
    ),

    SSOUser1 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),

    ?assertNotEqual(
        SSOUser0,
        SSOUser1
    ),

    ?assertEqual(
        true,
        bondy_password:verify_string(
            Password, bondy_rbac_user:password(SSOUser1)
        )
    ),

    ok.



change_password(_) ->
    SSOUser0 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),
    % User0 = bondy_rbac_user:fetch(?REALM2_URI, ?SSOU1),
    P1 = <<"newpassword">>,

    ?assertEqual(
        true,
        bondy_password:verify_string(P1, bondy_rbac_user:password(SSOUser0))
    ),

    ?assertEqual(
        false,
        bondy_password:verify_string(
            <<"wrongpassword">>, bondy_rbac_user:password(SSOUser0)
        )
    ),

    ?assertEqual(
        true,
        bondy_rbac_user:has_password(SSOUser0)
    ),

    ?assertNotEqual(
        ok,
        bondy_rbac_user:change_password(
            ?REALM2_URI, ?SSOU1, <<"123456">>, <<"wrongpassword">>
        )
    ),

    ?assertEqual(
        ok,
        bondy_rbac_user:change_password(
            ?REALM2_URI, ?SSOU1, <<"123456">>, <<"newpassword">>
        )
    ),

    ?assertEqual(
        true,
        bondy_password:verify_string(
            <<"123456">>,
            bondy_rbac_user:password(
                bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1)
            )
        )
    ),

    ?assertEqual(
        ok,
        bondy_rbac_user:change_password(
            ?REALM2_URI, ?SSOU1, <<"987654321">>
        )
    ),

    ?assertEqual(
        true,
        bondy_password:verify_string(
            <<"987654321">>,
            bondy_rbac_user:password(
                bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1)
            )
        )
    ).


update_groups(_) ->
    User0 = bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1),
    SSOUser0 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),

    ?assertEqual(
        [],
        bondy_rbac_user:groups(User0)
    ),

    ?assertEqual(
        [],
        bondy_rbac_user:groups(SSOUser0)
    ),

    ?assertMatch(
        {ok, #{groups := [<<"a">>]}},
        bondy_rbac_user:update(
            ?REALM1_URI, ?SSOU1, #{<<"groups">> => [<<"a">>]}
        )
    ),

    ?assertMatch(
        {ok, #{groups := [<<"sso_g1">>]}},
        bondy_rbac_user:update(
            ?SSO_REALM_URI,
            ?SSOU1,
            #{<<"groups">> => [<<"sso_g1">>]}
        )
    ).

add_group(_) ->
    User0 = bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1),
    SSOUser0 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),

    ?assertEqual(
        [<<"a">>],
        bondy_rbac_user:groups(User0)
    ),
    ?assertEqual(
        ok,
        bondy_rbac_user:add_group(?REALM1_URI, ?SSOU1, <<"b">>)
    ),
    ?assertEqual(
        [<<"a">>, <<"b">>],
        bondy_rbac_user:groups(bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1))
    ),
    ?assertEqual(
        {error, {no_such_groups, [<<"c">>]}},
        bondy_rbac_user:add_group(?REALM1_URI, ?SSOU1, <<"c">>)
    ),


    ?assertEqual(
        [<<"sso_g1">>],
        bondy_rbac_user:groups(SSOUser0)
    ),
    ?assertEqual(
        ok,
        bondy_rbac_user:add_group(?SSO_REALM_URI, ?SSOU1, <<"sso_g2">>)
    ),
    ?assertEqual(
        [<<"sso_g1">>, <<"sso_g2">>],
        bondy_rbac_user:groups(bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1))
    ),
    ?assertEqual(
        {error, {no_such_groups, [<<"sso_g3">>]}},
        bondy_rbac_user:add_group(?SSO_REALM_URI, ?SSOU1, <<"sso_g3">>)
    ).



remove_group(_) ->
    User0 = bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1),
    SSOUser0 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),

    ?assertEqual(
        [<<"a">>, <<"b">>],
        bondy_rbac_user:groups(User0)
    ),
    ?assertEqual(
        ok,
        bondy_rbac_user:remove_group(?REALM1_URI, ?SSOU1, <<"b">>)
    ),
    ?assertEqual(
        [<<"a">>],
        bondy_rbac_user:groups(bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1))
    ),

    ?assertEqual(
        [<<"sso_g1">>, <<"sso_g2">>],
        bondy_rbac_user:groups(SSOUser0)
    ),
    ?assertEqual(
        ok,
        bondy_rbac_user:remove_group(?SSO_REALM_URI, ?SSOU1, <<"sso_g2">>)
    ),
    ?assertEqual(
        [<<"sso_g1">>],
        bondy_rbac_user:groups(bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1))
    ).