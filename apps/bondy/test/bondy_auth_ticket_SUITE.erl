%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
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
        %% Original tests (preserved)
        anon_auth_not_allowed,
        ticket_auth_not_allowed,
        local_scope,
        client_scope_with_ticket,
        client_scope_with_id,

        %% Ticket auth method availability
        ticket_method_available_for_user,
        ticket_method_not_available_outside_cidr,

        %% Ticket issuance
        issue_with_custom_expiry,
        issue_returns_ticket_and_details,

        %% Ticket authentication flow
        ticket_auth_full_flow,
        wrong_user_ticket_rejected,

        %% Error cases
        invalid_method_rejected,
        nonexistent_user_error
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    KeyPairs = [bondy_cryptosign:generate_key() || _ <- lists:seq(1, 3)],
    RealmUri = <<"com.example.test.auth_ticket">>,
    ok = add_realm(RealmUri, KeyPairs),
    [{realm_uri, RealmUri}, {keypairs, KeyPairs} | Config].

end_per_suite(Config) ->
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



%% =============================================================================
%% HELPERS
%% =============================================================================



%% @private
make_session(RealmUri, Username, AuthMethod) ->
    make_session(RealmUri, Username, AuthMethod, {127, 0, 0, 1}).


%% @private
make_session(RealmUri, Username, AuthMethod, SourceIP) ->
    Session = bondy_session:new(RealmUri, #{
        peer => {SourceIP, 0},
        authrealm => RealmUri,
        authid => Username,
        authmethod => AuthMethod,
        security_enabled => true,
        authroles => [],
        roles => #{
            caller => #{}
        }
    }),
    ets:insert(
        bondy_session:table(bondy_session:external_id(Session)),
        Session
    ),
    Session.



%% =============================================================================
%% ORIGINAL TESTS (PRESERVED)
%% =============================================================================



anon_auth_not_allowed(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Peer = {{127, 0, 0, 1}, 10000},

    %% We simulate U1 has logged in using wampcra
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authrealm => RealmUri,
        authid => <<"foo">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => true,
        authroles => [<<"anonymous">>],
        roles => #{
            caller => #{}
        }
    }),
    ets:insert(bondy_session:table(bondy_session:external_id(Session)), Session),

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
        authrealm => RealmUri,
        authid => ?U1,
        authmethod => ?WAMP_TICKET_AUTH,
        security_enabled => true,
        authroles => Roles,
        roles => #{
            caller => #{}
        }
    }),
    ets:insert(bondy_session:table(bondy_session:external_id(Session)), Session),

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
    SourceIP = {127, 0, 0, 1},

    %% We simulate U1 has logged in using wampcra
    Session = bondy_session:new(RealmUri, #{
        peer => {SourceIP, 0},
        authrealm => RealmUri,
        authid => ?U1,
        authmethod => ?WAMP_CRA_AUTH,
        security_enabled => true,
        authroles => Roles,
        roles => #{
            caller => #{}
        }
    }),
    ets:insert(bondy_session:table(bondy_session:external_id(Session)), Session),

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
    ets:insert(bondy_session:table(bondy_session:external_id(Session)), Session),

    %% We issue a local scope ticket
    {ok, Ticket, _} = bondy_ticket:issue(Session, #{}),

    %% We simulate a new session
    SessionId = bondy_session_id:new(),
    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, SourceIP),

    ?assertEqual(
        true,
        lists:member(?WAMP_TICKET_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?WAMP_TICKET_AUTH, Ticket, undefined, Ctxt1)
    ),

    ?assertEqual(
        {error,{invalid_request,"Nested tickets are not allowed"}},
        bondy_ticket:issue(Session, #{client_ticket => Ticket})
    ).


client_scope_with_ticket(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Roles = [],
    SourceIP = {127, 0, 0, 1},

    %% We simulate APP has logged in using cryptosign
    AppSession = bondy_session:new(RealmUri, #{
        peer => {SourceIP, 0},
        authrealm => RealmUri,
        authid => ?APP,
        authmethod => ?WAMP_CRYPTOSIGN_AUTH,
        security_enabled => true,
        authroles => Roles,
        roles => #{
            caller => #{}
        }
    }),
    ets:insert(
        bondy_session:table(bondy_session:external_id(AppSession)),
        AppSession
    ),

    %% We issue a self-issued ticket
    {ok, AppTicket, _} = bondy_ticket:issue(AppSession, #{
        expiry_time_secs => 300
    }),

    %% We simulate U1 has logged in using wampcra
    UserSession = bondy_session:new(RealmUri, #{
        peer => {SourceIP, 0},
        authrealm => RealmUri,
        authid => ?U1,
        authmethod => ?WAMP_CRA_AUTH,
        security_enabled => true,
        authroles => Roles,
        roles => #{
            caller => #{}
        }
    }),
    ets:insert(
        bondy_session:table(bondy_session:external_id(UserSession)),
        UserSession
    ),

    ?assertEqual(
        {error,{invalid_request,"Nested tickets are not allowed"}},
        bondy_ticket:issue(UserSession, #{
            client_ticket => AppTicket,
            expiry_time_secs => 300
        })
    ).

client_scope_with_id(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Roles = [],
    SourceIP = {127, 0, 0, 1},

    %% We simulate U1 has logged in using wampcra
    UserSession = bondy_session:new(RealmUri, #{
        peer => {SourceIP, 0},
        authrealm => RealmUri,
        authid => ?U1,
        authmethod => ?WAMP_CRA_AUTH,
        security_enabled => true,
        authroles => Roles,
        roles => #{
            caller => #{}
        }
    }),
    ets:insert(bondy_session:table(bondy_session:external_id(UserSession)), UserSession),

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
    SessionId = bondy_session_id:new(),
    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, SourceIP),

    ?assertEqual(
        true,
        lists:member(?WAMP_TICKET_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?WAMP_TICKET_AUTH, UserTicket, undefined, Ctxt1)
    ).



%% =============================================================================
%% TICKET AUTH METHOD AVAILABILITY
%% =============================================================================



ticket_method_available_for_user(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% U1 has source for ticket auth from 0.0.0.0/0
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    ?assert(
        lists:member(?WAMP_TICKET_AUTH, bondy_auth:available_methods(Ctxt))
    ).


ticket_method_not_available_outside_cidr(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% U2 has ticket source restricted to 192.168.0.0/16
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U2, [], {10, 0, 0, 1}
    ),
    ?assertNot(
        lists:member(?WAMP_TICKET_AUTH, bondy_auth:available_methods(Ctxt))
    ).



%% =============================================================================
%% TICKET ISSUANCE
%% =============================================================================



issue_with_custom_expiry(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Session = make_session(RealmUri, ?U1, ?WAMP_CRA_AUTH),

    {ok, Ticket, Details} = bondy_ticket:issue(Session, #{
        expiry_time_secs => 600
    }),

    ?assert(is_binary(Ticket)),
    ?assert(is_map(Details)),
    ?assert(maps:is_key(expires_at, Details)),

    %% The expiry should be roughly 600 seconds from now
    ExpiresAt = maps:get(expires_at, Details),
    Now = erlang:system_time(second),
    ?assert(ExpiresAt > Now),
    ?assert(ExpiresAt =< Now + 610).


issue_returns_ticket_and_details(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Session = make_session(RealmUri, ?U1, ?WAMP_CRA_AUTH),

    {ok, Ticket, Details} = bondy_ticket:issue(Session, #{}),

    ?assert(is_binary(Ticket)),
    ?assert(is_map(Details)),
    ?assert(maps:is_key(authid, Details)),
    ?assert(maps:is_key(authrealm, Details)),
    ?assertEqual(?U1, maps:get(authid, Details)),
    ?assertEqual(RealmUri, maps:get(authrealm, Details)).



%% =============================================================================
%% TICKET AUTHENTICATION FLOW
%% =============================================================================



ticket_auth_full_flow(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SourceIP = {127, 0, 0, 1},

    %% Step 1: Issue a ticket via a CRA-authenticated session
    Session = make_session(RealmUri, ?U1, ?WAMP_CRA_AUTH),
    {ok, Ticket, _} = bondy_ticket:issue(Session, #{}),

    %% Step 2: Authenticate in a new session using the ticket
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], SourceIP
    ),
    ?assert(
        lists:member(?WAMP_TICKET_AUTH, bondy_auth:available_methods(Ctxt))
    ),
    {ok, Extra, _} = bondy_auth:authenticate(
        ?WAMP_TICKET_AUTH, Ticket, undefined, Ctxt
    ),

    %% Should return extra map (may contain scope info)
    ?assert(is_map(Extra)).


wrong_user_ticket_rejected(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SourceIP = {127, 0, 0, 1},

    %% Issue a ticket for U1
    Session = make_session(RealmUri, ?U1, ?WAMP_CRA_AUTH),
    {ok, Ticket, _} = bondy_ticket:issue(Session, #{}),

    %% Try to authenticate as APP using U1's ticket
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?APP, [], SourceIP
    ),

    %% Should fail because the ticket's authid doesn't match
    ?assertMatch(
        {error, _},
        bondy_auth:authenticate(
            ?WAMP_TICKET_AUTH, Ticket, undefined, Ctxt
        )
    ).



%% =============================================================================
%% ERROR CASES
%% =============================================================================



invalid_method_rejected(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(
            <<"nonexistent">>, <<"data">>, undefined, Ctxt
        )
    ).


nonexistent_user_error(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    ?assertMatch(
        {error, {no_such_user, <<"ghost">>}},
        bondy_auth:init(SessionId, RealmUri, <<"ghost">>, [], {127, 0, 0, 1})
    ).
