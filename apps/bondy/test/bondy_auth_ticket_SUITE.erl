%% =============================================================================
%%  bondy_auth_password_SUITE.erl -
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

-module(bondy_auth_ticket_SUITE).
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
        test_1
    ].


init_per_suite(Config) ->
    common:start_bondy(),
    RealmUri = <<"com.example.test.auth_ticket">>,
    ok = add_realm(RealmUri),
    [{realm_uri, RealmUri}|Config].

end_per_suite(Config) ->
    % common:stop_bondy(),
    {save_config, Config}.


add_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?WAMP_TICKET_AUTH
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
                authmethod => ?WAMP_TICKET_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [?U2],
                authmethod => ?WAMP_TICKET_AUTH,
                cidr => <<"192.168.0.0/16">>
            }
        ]
    },
    _ = bondy_realm:add(Config),
    ok.


test_1(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Roles = [],
    Peer = {{127, 0, 0, 1}, 10000},

    Session = bondy_session:new(Peer, RealmUri, #{
        authid => ?U1,
        authmethod => ?WAMP_CRA_AUTH,
        security_enabled => true,
        authroles => Roles,
        roles => #{
            caller => #{}
        }
    }),

    {ok, Ticket, _} = bondy_ticket:issue(Session, #{}),

    %% We simulate a new session
    SessionId = 1,
    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, Peer),

    ?assertEqual(
        true,
        lists:member(?WAMP_TICKET_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?WAMP_TICKET_AUTH, Ticket, undefined, Ctxt1)
    ).

