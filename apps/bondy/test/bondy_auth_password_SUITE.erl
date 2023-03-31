%% =============================================================================
%%  bondy_auth_password_SUITE.erl -
%%
%%  Copyright (c) 2016-2023 Leapsight. All rights reserved.
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

-module(bondy_auth_password_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).
-define(P1, <<"aWe11KeptSecret">>).
-define(P2, <<"An0therWe11KeptSecret">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        test_1,
        test_2
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.auth_password">>,
    ok = add_realm(RealmUri),
    [{realm_uri, RealmUri}|Config].

end_per_suite(Config) ->
    % bondy_ct:stop_bondy(),
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
    },
    _ = bondy_realm:create(Config),
    ok.


test_1(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Roles = [],
    Peer = {{127, 0, 0, 1}, 10000},

    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, Peer),

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
    {ok, Ctxt2} = bondy_auth:init(SessionId, RealmUri, ?U2, Roles, Peer),

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
    Peer = {{192, 168, 1, 45}, 10000},

    {ok, Ctxt2} = bondy_auth:init(SessionId, RealmUri, ?U2, Roles, Peer),

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
    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, Peer),

    ?assertEqual(
        true,
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt1)
    ).