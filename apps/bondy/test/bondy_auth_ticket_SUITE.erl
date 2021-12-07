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
-define(APP, <<"app_1">>).
-define(P1, <<"aWe11KeptSecret">>).
-define(P2, <<"An0therWe11KeptSecret">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        anon_auth_not_allowed,
        ticket_auth_not_allowed,
        local_scope,
        client_scope_with_ticket,
        client_scope_with_id
    ].


init_per_suite(Config) ->
    common:start_bondy(),
    KeyPairs = [enacl:crypto_sign_ed25519_keypair() || _ <- lists:seq(1, 3)],
    RealmUri = <<"com.example.test.auth_ticket">>,
    ok = add_realm(RealmUri, KeyPairs),
    [{realm_uri, RealmUri}, {keypairs, KeyPairs} | Config].

end_per_suite(Config) ->
    % common:stop_bondy(),
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
            ?WAMP_TICKET_AUTH, ?WAMP_ANON_AUTH, ?WAMP_CRA_AUTH
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
                    <<"bondy.issue">>
                ],
                resources => [
                    #{uri => <<"bondy.ticket.scope.local">>, match => <<"exact">>}
                ],
                roles => [?APP]
            },
            #{
                permissions => [
                    <<"bondy.issue">>
                ],
                resources => [
                    #{
                        uri => <<"bondy.ticket.scope.client_local">>,
                        match => <<"exact">>
                    },
                    #{
                        uri => <<"bondy.ticket.scope.client_sso">>,
                        match => <<"exact">>
                    }
                ],
                roles => [?U1]
            }
        ],
        users => [
            #{
                username => ?U1,
                password => ?P1,
                groups => []
            },
            #{
                username => ?U2,
                password => ?P1,
                groups => []
            },
            #{
                username => ?APP,
                authorized_keys => PubKeys,
                groups => []
            }
        ],
        sources => [
            #{
                usernames => [?U1],
                authmethod => ?WAMP_TICKET_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [?APP],
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
    _ = bondy_realm:create(Config),
    ok.


anon_auth_not_allowed(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Peer = {{127, 0, 0, 1}, 10000},

    %% We simulate U1 has logged in using wampcra
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => <<"foo">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => true,
        authroles => [<<"anonymous">>],
        roles => #{
            caller => #{}
        }
    }),
    ets:insert(bondy_session:table(bondy_session:id(Session)), Session),

    ?assertMatch(
        {
            error,
            {not_authorized, <<"The authentication method 'anonymous' you used to establish this session is not in the list of methods allowed to issue tickets (configuration option 'security.ticket.authmethods').">>}
        },
        bondy_ticket:issue(Session, #{})
    ).

ticket_auth_not_allowed(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Roles = [],
    Peer = {{127, 0, 0, 1}, 10000},

    %% We disable ticket auth
    ok = bondy_config:set([security, ticket, authmethods], [
        <<"cryptosign">>, <<"wampcra">>
    ]),

    %% We simulate U1 has logged in using wampcra
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => ?U1,
        authmethod => ?WAMP_TICKET_AUTH,
        security_enabled => true,
        authroles => Roles,
        roles => #{
            caller => #{}
        }
    }),
    ets:insert(bondy_session:table(bondy_session:id(Session)), Session),

    ?assertMatch(
        {error, {not_authorized, _}},
        bondy_ticket:issue(Session, #{})
    ),

     %% We re-enable authmethods
     ok = bondy_config:set([security, ticket, authmethods], [
        <<"cryptosign">>, <<"password">>, <<"ticket">>, <<"tls">>, <<"trust">>,<<"wamp-scram">>, <<"wampcra">>
    ]).

local_scope(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Roles = [],
    Peer = {{127, 0, 0, 1}, 10000},

    %% We simulate U1 has logged in using wampcra
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => ?U1,
        authmethod => ?WAMP_CRA_AUTH,
        security_enabled => true,
        authroles => Roles,
        roles => #{
            caller => #{}
        }
    }),
    ets:insert(bondy_session:table(bondy_session:id(Session)), Session),

    ?assertMatch(
        {error, {not_authorized, _}},
        bondy_ticket:issue(Session, #{})
    ),

    %% We issue a self-issued ticket
    ok = bondy_rbac:grant(
        RealmUri,
        bondy_rbac:request(#{
            roles => [?U1],
            permissions => [<<"bondy.issue">>],
            resources => [#{
                uri => <<"bondy.ticket.scope.local">>,
                match => <<"exact">>
            }]
        })
    ),

    %% Re-insert session so that we cleanup the rbac_ctxt
    ets:insert(bondy_session:table(bondy_session:id(Session)), Session),

    %% We issue a local scope ticket
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
    ),

    ?assertEqual(
        {error, invalid_request},
        bondy_ticket:issue(Session, #{client_ticket => Ticket}),
        "Nested self-issued tickets not allowed"
    ).



client_scope_with_ticket(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Roles = [],
    Peer = {{127, 0, 0, 1}, 10000},

    %% We simulate APP has logged in using cryptosign
    AppSession = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => ?APP,
        authmethod => ?WAMP_CRYPTOSIGN_AUTH,
        security_enabled => true,
        authroles => Roles,
        roles => #{
            caller => #{}
        }
    }),
    ets:insert(bondy_session:table(bondy_session:id(AppSession)), AppSession),

    %% We issue a self-issued ticket
    {ok, AppTicket, _} = bondy_ticket:issue(AppSession, #{
        expiry_time_secs => 300
    }),

    %% We simulate U1 has logged in using wampcra
    UserSession = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => ?U1,
        authmethod => ?WAMP_CRA_AUTH,
        security_enabled => true,
        authroles => Roles,
        roles => #{
            caller => #{}
        }
    }),
    ets:insert(bondy_session:table(bondy_session:id(UserSession)), UserSession),

    %% We issue a self-issued ticket
    {ok, UserTicket, _} = bondy_ticket:issue(UserSession, #{
        client_ticket => AppTicket,
        expiry_time_secs => 300
    }),

    %% We simulate a new session
    SessionId = 1,
    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, Peer),

    ?assertEqual(
        true,
        lists:member(?WAMP_TICKET_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?WAMP_TICKET_AUTH, UserTicket, undefined, Ctxt1)
    ).

client_scope_with_id(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Roles = [],
    Peer = {{127, 0, 0, 1}, 10000},

    %% We simulate U1 has logged in using wampcra
    UserSession = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => ?U1,
        authmethod => ?WAMP_CRA_AUTH,
        security_enabled => true,
        authroles => Roles,
        roles => #{
            caller => #{}
        }
    }),
    ets:insert(bondy_session:table(bondy_session:id(UserSession)), UserSession),

    %% We issue a self-issued ticket
    {ok, UserTicket, Details} = bondy_ticket:issue(
        UserSession,
        #{
            client_id => ?APP,
            expiry_time_secs => 300
        }
    ),

    ?assertMatch(
        #{scope := #{client_id := ?APP}},
        Details
    ),

    %% We simulate a new session
    SessionId = 1,
    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, Peer),

    ?assertEqual(
        true,
        lists:member(?WAMP_TICKET_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?WAMP_TICKET_AUTH, UserTicket, undefined, Ctxt1)
    ).

