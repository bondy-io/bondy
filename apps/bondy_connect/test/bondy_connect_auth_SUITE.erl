%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_auth_SUITE).

-moduledoc """
M2 integration tests proving that all four supported authentication methods —
**anonymous**, **WAMP-CRA**, **cryptosign** and **ticket** — establish a real
WAMP session end-to-end against a live Bondy router over raw TCP.

The cryptographic round-trips themselves are unit-tested at the protocol layer
(`bondy_connect_protocol_SUITE`); this suite proves the full client stack
(connection → transport) negotiates each method with a real router.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(HOST, "127.0.0.1").
-define(PORT, 18082).

-define(ANON_REALM, <<"com.example.bondy_connect.m2.auth.anon">>).
-define(CRA_REALM, <<"com.example.bondy_connect.m2.auth.cra">>).
-define(CS_REALM, <<"com.example.bondy_connect.m2.auth.cs">>).
-define(TICKET_REALM, <<"com.example.bondy_connect.m2.auth.ticket">>).

-define(USER, <<"alice">>).
-define(PASSWORD, <<"secret-password-123">>).

all() ->
    [
        anonymous_establishes,
        wampcra_establishes,
        cryptosign_establishes,
        ticket_establishes
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect),

    ok = add_anon_realm(?ANON_REALM),
    ok = add_cra_realm(?CRA_REALM),
    KeyPair = bondy_wamp_cryptosign:generate_key(),
    ok = add_cryptosign_realm(?CS_REALM, KeyPair),
    ok = add_ticket_realm(?TICKET_REALM),

    [{keypair, KeyPair} | Config].

end_per_suite(_) ->
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

anonymous_establishes(_) ->
    {ok, Conn} = bondy_connect:connect(#{
        transport => tcp,
        endpoint => {?HOST, ?PORT},
        realm => ?ANON_REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    }),
    ?assertEqual(established, bondy_connect:status(Conn)),
    ok = bondy_connect:disconnect(Conn).

wampcra_establishes(_) ->
    {ok, Conn} = bondy_connect:connect(#{
        transport => tcp,
        endpoint => {?HOST, ?PORT},
        realm => ?CRA_REALM,
        auth => #{
            method => ?WAMP_CRA_AUTH,
            authid => ?USER,
            password => ?PASSWORD
        },
        serializers => [json]
    }),
    ?assertEqual(established, bondy_connect:status(Conn)),
    ok = bondy_connect:disconnect(Conn).

cryptosign_establishes(Config) ->
    #{secret := Secret} = ?config(keypair, Config),
    PrivHex = bondy_wamp_cryptosign:encode_hex(Secret),
    {ok, Conn} = bondy_connect:connect(#{
        transport => tcp,
        endpoint => {?HOST, ?PORT},
        realm => ?CS_REALM,
        auth => #{
            method => ?WAMP_CRYPTOSIGN_AUTH,
            authid => ?USER,
            privkey => PrivHex
        },
        serializers => [json]
    }),
    ?assertEqual(established, bondy_connect:status(Conn)),
    ok = bondy_connect:disconnect(Conn).

ticket_establishes(_) ->
    %% Issue a real ticket from a (simulated) wampcra-authenticated session, then
    %% authenticate a fresh client connection with it.
    Session = make_session(?TICKET_REALM, ?USER, ?WAMP_CRA_AUTH),
    {ok, Ticket, _} = bondy_ticket:issue(Session, #{}),

    {ok, Conn} = bondy_connect:connect(#{
        transport => tcp,
        endpoint => {?HOST, ?PORT},
        realm => ?TICKET_REALM,
        auth => #{
            method => ?WAMP_TICKET_AUTH,
            authid => ?USER,
            ticket => Ticket
        },
        serializers => [json]
    }),
    ?assertEqual(established, bondy_connect:status(Conn)),
    ok = bondy_connect:disconnect(Conn).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
add_anon_realm(RealmUri) ->
    create(#{
        uri => RealmUri,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => true,
        grants => [grant([<<"wamp.call">>], [<<"anonymous">>])],
        sources => [source([<<"anonymous">>], ?WAMP_ANON_AUTH)]
    }).

%% @private
add_cra_realm(RealmUri) ->
    create(#{
        uri => RealmUri,
        authmethods => [?WAMP_CRA_AUTH],
        security_enabled => true,
        grants => [grant([<<"wamp.call">>], <<"all">>)],
        users => [
            #{
                username => ?USER,
                password => ?PASSWORD,
                groups => [],
                meta => #{}
            }
        ],
        sources => [source([?USER], ?WAMP_CRA_AUTH)]
    }).

%% @private
add_cryptosign_realm(RealmUri, #{public := PubKey}) ->
    create(#{
        uri => RealmUri,
        authmethods => [?WAMP_CRYPTOSIGN_AUTH],
        security_enabled => true,
        grants => [grant([<<"wamp.call">>], <<"all">>)],
        users => [
            #{
                username => ?USER,
                authorized_keys => [PubKey],
                groups => [],
                meta => #{}
            }
        ],
        sources => [source([?USER], ?WAMP_CRYPTOSIGN_AUTH)]
    }).

%% @private Ticket auth: the user authenticates with wampcra to *issue* a ticket
%% and with ticket to *use* it.
add_ticket_realm(RealmUri) ->
    %% Allow wampcra-authenticated sessions to issue tickets.
    ok = bondy_config:set(
        [security, ticket, authmethods],
        [<<"wampcra">>, <<"password">>, <<"ticket">>, <<"cryptosign">>]
    ),
    create(#{
        uri => RealmUri,
        authmethods => [?WAMP_CRA_AUTH, ?WAMP_TICKET_AUTH],
        security_enabled => true,
        grants => [
            grant([<<"wamp.call">>], <<"all">>),
            #{
                permissions => [<<"bondy.issue">>],
                resources => [
                    #{
                        uri => <<"bondy.ticket.scope.local">>,
                        match => <<"exact">>
                    }
                ],
                roles => <<"all">>
            }
        ],
        users => [
            #{
                username => ?USER,
                password => ?PASSWORD,
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            source([?USER], ?WAMP_CRA_AUTH),
            source([?USER], ?WAMP_TICKET_AUTH)
        ]
    }).

%% @private
grant(Permissions, Roles) ->
    #{
        permissions => Permissions,
        uri => <<"">>,
        match => <<"prefix">>,
        roles => Roles
    }.

%% @private
source(Usernames, AuthMethod) ->
    #{
        usernames => Usernames,
        authmethod => AuthMethod,
        cidr => <<"0.0.0.0/0">>
    }.

%% @private
create(Cfg) ->
    _ = bondy_realm:create(Cfg),
    ok.

%% @private Build and register a session row so `bondy_ticket:issue/2` can read
%% it (mirrors `bondy_auth_ticket_SUITE`).
make_session(RealmUri, Username, AuthMethod) ->
    Session = bondy_session:new(RealmUri, #{
        peer => {{127, 0, 0, 1}, 0},
        authrealm => RealmUri,
        authid => Username,
        authmethod => AuthMethod,
        security_enabled => true,
        authroles => [],
        roles => #{caller => #{}}
    }),
    ets:insert(
        bondy_session:table(bondy_session:external_id(Session)),
        Session
    ),
    Session.
