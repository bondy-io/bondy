%% =============================================================================
%%  bondy_rbac_SUITE.erl -
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

-module(bondy_rbac_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        test_1
    ].


init_per_suite(Config) ->
    common:start_bondy(),
    RealmUri = <<"com.example.test.rbac">>,
    ok = add_realm(RealmUri),

    [{realm_uri, RealmUri}| Config].

end_per_suite(Config) ->
    % common:stop_bondy(),
    {save_config, Config}.


add_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?TRUST_AUTH
        ],
        security_enabled => true,
        groups => [
            #{
                name => <<"com.thing.system.service">>,
                groups => [],
                meta => #{}
            }
        ],
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
                roles => [<<"com.thing.system.service">>]
            },
            #{
                permissions => [
                    <<"wamp.subscribe">>,
                    <<"wamp.unsubscribe">>,
                    <<"wamp.call">>,
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
                groups => [<<"com.thing.system.service">>],
                meta => #{}
            },
            #{
                username => ?U2,
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            #{
                usernames => [?U1],
                authmethod => ?TRUST_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [?U2],
                authmethod => ?TRUST_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },
    _ = bondy_realm:add(Config),
    ok.


test_1(Config) ->
    RealmUri = ?config(realm_uri, Config),
    U1Ctxt = #{
        realm_uri => RealmUri,
        authid => ?U1
    },
    U2Ctxt = #{
        realm_uri => RealmUri,
        authid => ?U2
    },

    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.my.call">>, U1Ctxt),
        "U1 can register"
    ),

    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.my.call">>, U2Ctxt),
        "U2 cannot register"
    ).



