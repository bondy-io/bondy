%% =============================================================================
%%  bondy_auth_wamp_cryptosign_SUITE.erl -
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

-module(bondy_auth_wamp_cryptosign_SUITE).
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
    bondy_ct:start_bondy(),
    KeyPairs = [
        bondy_cryptosign:generate_key()
        || _ <- lists:seq(1, 3)
    ],
    RealmUri = <<"com.example.test.auth_cryptosign">>,
    ok = add_realm(RealmUri, KeyPairs),

    [{realm_uri, RealmUri}, {keypairs, KeyPairs} | Config].

end_per_suite(Config) ->
    % bondy_ct:stop_bondy(),
    {save_config, Config}.


add_realm(RealmUri, KeyPairs) ->
    %% We use the same keys for both users (not to be done in real life)
    PubKeys = [
        maps:get(public, KeyPair)
        || KeyPair <- KeyPairs
    ],

    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?WAMP_CRYPTOSIGN_AUTH
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
                authorized_keys => PubKeys,
                groups => [],
                meta => #{}
            },
            #{
                username => ?U2,
                authorized_keys => PubKeys,
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            #{
                usernames => [?U1],
                authmethod => ?WAMP_CRYPTOSIGN_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [?U2],
                authmethod => ?WAMP_CRYPTOSIGN_AUTH,
                cidr => <<"198.162.0.0/16">>
            }
        ]
    },
    _ = bondy_realm:create(Config),
    ok.


test_1(Config) ->
    RealmUri = ?config(realm_uri, Config),
    KeyPairs = ?config(keypairs, Config),

    SessionId = bondy_session_id:new(),
    Roles = [],
    SourceIP = {127, 0, 0, 1},

    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, SourceIP),


    ?assertEqual(
        true,
        lists:member(?WAMP_CRYPTOSIGN_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    [KeyPair] = lists_utils:random(KeyPairs, 1),

    Details = #{
        authextra => #{
            <<"pubkey">> => list_to_binary(
                hex_utils:bin_to_hexstr(maps:get(public, KeyPair))
            )
        }
    },

    {true, Extra, NewCtxt1} = bondy_auth:challenge(
        ?WAMP_CRYPTOSIGN_AUTH, Details, Ctxt1
    ),

    HexMessage = maps:get(challenge, Extra, undefined),

    ?assertNotEqual(undefined, HexMessage, "Challenge should be present"),

    ?assertEqual(
        undefined,
        maps:get(channel_binding, Extra, undefined),
        "Channel binding not supported yet, should be undefined"
    ),


    %% We simulate the response from the client
    Message = hex_utils:hexstr_to_bin(HexMessage),
    Signature = list_to_binary(
        hex_utils:bin_to_hexstr(
            bondy_cryptosign:sign(Message, KeyPair)
        )
    ),


    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(
            ?WAMP_CRYPTOSIGN_AUTH, Signature, undefined, NewCtxt1
        )
    ),
    ?assertMatch(
        {error, invalid_signature},
        bondy_auth:authenticate(
            ?WAMP_CRYPTOSIGN_AUTH, <<"foo">>, undefined, NewCtxt1
        )
    ),

    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(?PASSWORD_AUTH, <<"foo">>, undefined, Ctxt1)
    ),

    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(<<"foo">>, <<"foo">>, undefined, Ctxt1)
    ),

    %% user 2 is not granted access from Peer (see test_2)
    {ok, Ctxt2} = bondy_auth:init(SessionId, RealmUri, ?U2, Roles, SourceIP),

    ?assertEqual(
        false,
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt2))
    ),

    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(?PASSWORD_AUTH, <<"foo">>, undefined, Ctxt2)
    ).


