%% =============================================================================
%%  bondy_rbac_source_SUITE.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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

-module(bondy_rbac_source_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        no_sources,
        multiple_methods
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.rbac_source">>,
    ok = add_realm(RealmUri),
    [{realm_uri, RealmUri}|Config].

end_per_suite(Config) ->
    % bondy_ct:stop_bondy(),
    {save_config, Config}.


no_sources(Config) ->
    RealmUri = ?config(realm_uri, Config),
    ?assertEqual(
        [],
        bondy_rbac_source:list(RealmUri)
    ).


multiple_methods(Config) ->
    RealmUri = ?config(realm_uri, Config),

    Source1 = bondy_rbac_source:new_assignment(#{
        usernames => <<"all">>,
        authmethod => ?PASSWORD_AUTH,
        cidr => <<"0.0.0.0/0">>
    }),

    ?assertMatch(
        {ok, _},
        bondy_rbac_source:add(RealmUri, Source1)
    ),

    ?assertMatch(
        [#{authmethod := ?PASSWORD_AUTH}],
        bondy_rbac_source:list(RealmUri)
    ),

    Source2 = bondy_rbac_source:new_assignment(#{
        usernames => <<"all">>,
        authmethod => ?WAMP_CRA_AUTH,
        cidr => <<"0.0.0.0/0">>
    }),

    ?assertMatch(
        {ok, _},
        bondy_rbac_source:add(RealmUri, Source2)
    ),

    ?assertMatch(
        [_, _],
        bondy_rbac_source:list(RealmUri)
    ).


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
        ]
    },
    _ = bondy_realm:create(Config),
    ok.