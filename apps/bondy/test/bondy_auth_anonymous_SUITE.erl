%% =============================================================================
%%  bondy_auth_anonymous_SUITE.erl -
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

-module(bondy_auth_anonymous_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        test
    ].


init_per_suite(Config) ->
    common:start_bondy(),
    RealmUri = <<"com.example.test.auth_anonymous">>,
    ok = add_realm(RealmUri),
    [{realm_uri, RealmUri}|Config].

end_per_suite(Config) ->
    % common:stop_bondy(),
    {save_config, Config}.


test(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Roles = [],
    Peer = {{127, 0, 0, 1}, 10000},


    Ctxt = bondy_auth:init(1, RealmUri, anonymous, Roles, Peer),

    ?assertEqual(
        true,
        lists:member(?WAMP_ANON_AUTH, bondy_auth:available_methods(Ctxt))
    ),

    ?assertMatch(
        {ok, _, _},
        authenticate(?WAMP_ANON_AUTH, RealmUri, Roles, Peer)
    ),

    ?assertMatch(
        {error, method_not_allowed},
        authenticate(?PASSWORD_AUTH, RealmUri, Roles, Peer)
    ),

    ?assertMatch(
        {error, invalid_method},
        authenticate(<<"foo">>, RealmUri, Roles, Peer)
    ).



authenticate(Method, Uri, Roles, Peer) ->
    SessionId = 1,
    Roles = [],
    Ctxt = bondy_auth:init(SessionId, Uri, anonymous, Roles, Peer),
    bondy_auth:authenticate(Method, undefined, undefined, Ctxt).


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
    _ = bondy_realm:add(Config),
    ok.