%% =============================================================================
%%  bondy_auth_oauth2_SUITE.erl -
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

-module(bondy_auth_oauth2_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-define(REALM_URI, <<"com.example.test.oauth2">>).
-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).
-define(APP1, <<"app_1">>).
-define(APP2, <<"app_2">>).
-define(PASS, <<"aWe11KeptSecret">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        client_credentials,
        resource_owner_password
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = ?REALM_URI,
    ok = add_realm(RealmUri),
    Config.

end_per_suite(Config) ->
    % bondy_ct:stop_bondy(),
    {save_config, Config}.


add_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        authmethods => [
            ?WAMP_OAUTH2_AUTH, ?PASSWORD_AUTH
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
                password => ?PASS,
                groups => [<<"resource_owners">>, <<"group_1">>]
            },
            #{
                username => ?U2,
                password => ?PASS,
                groups => [<<"group_1">>]
            },
            #{
                username => ?APP1,
                password => ?PASS,
                groups => [<<"api_clients">>]
            },
            #{
                username => ?APP2,
                password => ?PASS,
                groups => [<<"api_clients">>]
            }
        ],
        groups => [
            #{name => <<"group_1">>},
            #{name => <<"api_clients">>},
            #{name => <<"resource_owners">>}
        ],
        sources => [
            #{
                usernames => <<"all">>,
                authmethod => ?WAMP_OAUTH2_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => <<"all">>,
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },
    _ = bondy_realm:create(Config),
    ok.


resource_owner_password(_) ->
    SessionId = bondy_session_id:new(),
    Roles = [~"group_1"],
    SourceIP = {127, 0, 0, 1},
    {ok, Ctxt1} = bondy_auth:init(SessionId, ?REALM_URI, ?U1, Roles, SourceIP),
    {ok, Token} = bondy_oauth_token:issue(password, Ctxt1, #{}),
    {ok, {JWT, _}} = bondy_oauth_token:to_access_token(Token),

    ?assertMatch(
        {ok, #{
            ~"id" := _,
            ~"vsn" := _,
            ~"exp" := _,
            ~"iat" := _,
            ~"ion" := _,
            ~"kid" := _,
            ~"iss" := _,
            ~"aud" := ?REALM_URI,
            ~"sub" := ?U1,
            ~"auth" := #{
                ~"scope" := #{
                    ~"realm" := ?REALM_URI,
                    ~"client_id" := _,
                    ~"device_id" := _
                }
            },
            ~"meta" := _,
            ~"groups" := _
        }},
        bondy_oauth_jwt:verify(?REALM_URI, JWT)
    ),

    ?assertEqual(
        true,
        lists:member(?WAMP_OAUTH2_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?WAMP_OAUTH2_AUTH, JWT, #{}, Ctxt1)
    ),

    ok.


client_credentials(_) ->
    ok.


