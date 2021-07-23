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
-define(REALM_URI, <<"com.example.test.user">>).
-define(SSO_REALM_URI, <<"com.example.test.user.sso">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        test
    ].


init_per_suite(Config) ->
    common:start_bondy(),
    KeyPairs = [enacl:crypto_sign_ed25519_keypair() || _ <- lists:seq(1, 3)],
    RealmUri = ?REALM_URI,
    SSORealmUri = ?SSO_REALM_URI,
    ok = add_sso_realm(SSORealmUri),
    ok = add_realm(RealmUri, SSORealmUri, KeyPairs),
    [{realm_uri, RealmUri}, {keypairs, KeyPairs} | Config].

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
        allow_connections => false
    },
    _ = bondy_realm:add(Config),
    ok.


add_realm(RealmUri, SSORealmUri, KeyPairs) ->
    PubKeys = [
        maps:get(public, KeyPair)
        || KeyPair <- KeyPairs
    ],

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
        users => [
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
                sso_opts => #{
                    realm_uri => ?SSO_REALM_URI,
                    groups => [],
                    meta => #{fruit => <<"mango">>}
                }
            },
            #{
                username => ?SSOU2,
                password => ?SSOU2,
                groups => [],
                meta => #{fruit => <<"orange">>},
                sso_opts => #{
                    realm_uri => ?SSO_REALM_URI,
                    groups => [],
                    meta => #{fruit => <<"grapefruit">>}
                }
            }

        ]
    },
    _ = bondy_realm:add(Config),
    ok.


test(_) ->
    _LU1 = bondy_rbac_user:fetch(?REALM_URI, ?LU1),
    _LU2 = bondy_rbac_user:fetch(?REALM_URI, ?LU2),
    _SSOU1 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),
    _SSOU2 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU2),
    ok.

