%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_trusted_issuer_SUITE).
-moduledoc """
WP-F / A-1 regression suite.

Proves the cross-realm token/ticket trust boundary: a token or ticket signed by
realm `S` (its `aud`/`authrealm` claim) may only establish a session in realm
`B` when `S` is `B` itself or `B`'s configured SSO realm
(`bondy_realm:is_trusted_issuer/2`).

Topology:
- `S`  — an SSO realm (`is_sso_realm = true`).
- `M1` — a member realm (`sso_realm_uri = S`); issues the SSO token/ticket.
- `M2` — a sibling member realm (`sso_realm_uri = S`); a legitimate SSO peer.
- `X`  — an unrelated realm (no `sso_realm_uri`); must reject `S`-issued tokens.

The same user (`alice`) exists in every realm so the auth callbacks reach the
issuer-trust check rather than failing earlier on user resolution.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-define(SSO, <<"com.example.test.trusted_issuer.sso">>).
-define(M1, <<"com.example.test.trusted_issuer.m1">>).
-define(M2, <<"com.example.test.trusted_issuer.m2">>).
-define(X, <<"com.example.test.trusted_issuer.x">>).
-define(USER, <<"alice">>).
-define(PASS, <<"aWe11KeptSecret">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        %% The shared predicate every verifier delegates to.
        is_trusted_issuer_predicate,

        %% JWT (oauth2) end-to-end.
        sso_token_accepted_by_issuing_member,
        sso_token_accepted_by_sibling_member,
        sso_token_accepted_by_issuer_realm,
        sso_token_rejected_by_unrelated_realm,

        %% Ticket end-to-end.
        sso_ticket_rejected_by_unrelated_realm,
        sso_ticket_accepted_by_sibling_member
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    ok = add_sso_realm(?SSO),
    ok = add_member_realm(?M1),
    ok = add_member_realm(?M2),
    ok = add_unrelated_realm(?X),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

%% =============================================================================
%% FIXTURES
%% =============================================================================

add_sso_realm(Uri) ->
    _ = bondy_realm:create(#{
        uri => Uri,
        description => <<"SSO realm">>,
        authmethods => [?WAMP_CRA_AUTH, ?WAMP_CRYPTOSIGN_AUTH],
        security_enabled => true,
        is_sso_realm => true,
        allow_connections => false
    }),
    ok.

add_member_realm(Uri) ->
    _ = bondy_realm:create(#{
        uri => Uri,
        description => <<"Member realm">>,
        authmethods => [
            ?WAMP_OAUTH2_AUTH, ?PASSWORD_AUTH, ?WAMP_TICKET_AUTH, ?WAMP_CRA_AUTH
        ],
        security_enabled => true,
        sso_realm_uri => ?SSO,
        grants => [
            #{
                permissions => [
                    <<"wamp.call">>,
                    <<"wamp.subscribe">>,
                    <<"bondy.issue">>
                ],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => <<"all">>
            }
        ],
        users => [
            #{
                username => ?USER,
                password => ?PASS,
                groups => [],
                sso_realm_uri => ?SSO
            }
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
            },
            #{
                usernames => <<"all">>,
                authmethod => ?WAMP_TICKET_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => <<"all">>,
                authmethod => ?WAMP_CRA_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    }),
    ok.

add_unrelated_realm(Uri) ->
    _ = bondy_realm:create(#{
        uri => Uri,
        description => <<"Unrelated realm (no SSO)">>,
        authmethods => [?WAMP_OAUTH2_AUTH, ?PASSWORD_AUTH, ?WAMP_TICKET_AUTH],
        security_enabled => true,
        grants => [
            #{
                permissions => [<<"wamp.call">>, <<"wamp.subscribe">>],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => <<"all">>
            }
        ],
        users => [
            #{
                username => ?USER,
                password => ?PASS,
                groups => []
            }
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
            },
            #{
                usernames => <<"all">>,
                authmethod => ?WAMP_TICKET_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    }),
    ok.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% Issues an SSO-scoped access token for `alice` via member realm `M1`. Because
%% `M1` is a member realm (`sso_realm_uri = S`), the auth context's authrealm is
%% `S`, so the token carries `aud = S` and `auth.scope.realm = all`.
issue_sso_jwt() ->
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(
        SessionId, ?M1, ?USER, [], {127, 0, 0, 1}
    ),
    {ok, Token} = bondy_oauth_token:issue(password, Ctxt, #{allow_sso => true}),
    {ok, {JWT, _}} = bondy_oauth_token:to_access_token(Token),
    JWT.

%% @private
issue_sso_ticket() ->
    Session = bondy_session:new(?M1, #{
        peer => {{127, 0, 0, 1}, 0},
        %% The ticket is signed by (and scoped to) the SSO realm.
        authrealm => ?SSO,
        authid => ?USER,
        authmethod => ?WAMP_CRA_AUTH,
        security_enabled => true,
        authroles => [],
        roles => #{caller => #{}}
    }),
    ets:insert(
        bondy_session:table(bondy_session:external_id(Session)), Session
    ),
    {ok, Ticket, Claims} = bondy_ticket:issue(Session, #{allow_sso => true}),
    %% Sanity: an SSO ticket is not pinned to a single realm.
    ?assertMatch(#{scope := #{realm := undefined}}, Claims),
    ?assertEqual(?SSO, maps:get(authrealm, Claims)),
    Ticket.

%% @private
ticket_authenticate(TargetRealm, Ticket) ->
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(
        SessionId, TargetRealm, ?USER, [], {127, 0, 0, 1}
    ),
    bondy_auth:authenticate(?WAMP_TICKET_AUTH, Ticket, undefined, Ctxt).

%% =============================================================================
%% TESTS — shared predicate
%% =============================================================================

is_trusted_issuer_predicate(_Config) ->
    %% A realm trusts itself.
    ?assert(bondy_realm:is_trusted_issuer(?M1, ?M1)),
    ?assert(bondy_realm:is_trusted_issuer(?X, ?X)),
    ?assert(bondy_realm:is_trusted_issuer(?SSO, ?SSO)),

    %% A member realm trusts its SSO realm.
    ?assert(bondy_realm:is_trusted_issuer(?M1, ?SSO)),
    ?assert(bondy_realm:is_trusted_issuer(?M2, ?SSO)),

    %% A member realm does NOT trust a sibling member as an issuer.
    ?assertNot(bondy_realm:is_trusted_issuer(?M1, ?M2)),

    %% An unrelated realm trusts neither the SSO realm nor a member.
    ?assertNot(bondy_realm:is_trusted_issuer(?X, ?SSO)),
    ?assertNot(bondy_realm:is_trusted_issuer(?X, ?M1)),

    %% The SSO realm does not trust its members as issuers.
    ?assertNot(bondy_realm:is_trusted_issuer(?SSO, ?M1)),

    ok.

%% =============================================================================
%% TESTS — JWT (oauth2)
%% =============================================================================

sso_token_accepted_by_issuing_member(_Config) ->
    JWT = issue_sso_jwt(),
    %% Confirm the token really is SSO-shaped.
    {ok, Claims} = bondy_oauth_jwt:verify(?M1, JWT),
    ?assertEqual(?SSO, maps:get(<<"aud">>, Claims)),
    ok.

sso_token_accepted_by_sibling_member(_Config) ->
    %% The legitimate SSO use case: a token minted under S via M1 is accepted by
    %% sibling member M2 (both trust S). This is what A-1's fix must NOT break.
    JWT = issue_sso_jwt(),
    ?assertMatch({ok, _}, bondy_oauth_jwt:verify(?M2, JWT)),
    ok.

sso_token_accepted_by_issuer_realm(_Config) ->
    %% Presented back to the issuing SSO realm itself.
    JWT = issue_sso_jwt(),
    ?assertMatch({ok, _}, bondy_oauth_jwt:verify(?SSO, JWT)),
    ok.

sso_token_rejected_by_unrelated_realm(_Config) ->
    %% THE A-1 ATTACK: a token minted under SSO realm S (aud = S, scope = all)
    %% must be rejected by an unrelated realm X that does not trust S — even
    %% though the token verifies against S's own key and the `all` scope would
    %% otherwise match any realm.
    JWT = issue_sso_jwt(),
    ?assertEqual(
        {error, untrusted_issuer},
        bondy_oauth_jwt:verify(?X, JWT)
    ),
    ok.

%% =============================================================================
%% TESTS — ticket
%% =============================================================================

sso_ticket_rejected_by_unrelated_realm(_Config) ->
    %% The ticket analogue of the A-1 attack: an SSO ticket (authrealm = S,
    %% scope.realm = undefined) presented to unrelated realm X is rejected at the
    %% ticket auth boundary.
    Ticket = issue_sso_ticket(),
    %% `bondy_auth:authenticate/4` strips the callback's state on error, so the
    %% reason surfaces as a 2-tuple.
    ?assertEqual(
        {error, untrusted_issuer},
        ticket_authenticate(?X, Ticket)
    ),
    ok.

sso_ticket_accepted_by_sibling_member(_Config) ->
    %% Legitimate SSO ticket use: sibling member M2 trusts S, so the same ticket
    %% authenticates.
    Ticket = issue_sso_ticket(),
    ?assertMatch({ok, _, _}, ticket_authenticate(?M2, Ticket)),
    ok.
