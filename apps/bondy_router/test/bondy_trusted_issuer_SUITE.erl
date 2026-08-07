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
        sso_ticket_accepted_by_sibling_member,

        %% Revocation must follow tickets into the SSO bucket they live in.
        revoke_all_user_reaches_the_sso_bucket,
        revoke_all_realm_spares_sibling_realms,
        token_revoke_all_realm_spares_sibling_realms
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

%% An SSO user's tickets are bucketed by the AUTH realm (`S`), not by the realm
%% they connected to (`M1`). `revoke_all/2` scanned only the realm it was given,
%% so disabling or deleting an SSO user left every ticket of theirs working.
revoke_all_user_reaches_the_sso_bucket(_Config) ->
    Scope = ticket_scope(?M1),
    ok = bondy_ticket:store_ticket(?SSO, ?USER, ticket_claims(?SSO, Scope)),
    ?assertMatch(
        {ok, _},
        bondy_ticket:lookup(?SSO, ?USER, Scope),
        "Precondition: the ticket lives in the SSO realm's bucket"
    ),

    %% The caller passes the realm the user connected to, never the SSO realm.
    ok = bondy_ticket:revoke_all(?M1, ?USER),

    ?assertEqual(
        {error, not_found},
        bondy_ticket:lookup(?SSO, ?USER, Scope),
        "Revoking an SSO user's tickets must reach the SSO realm's bucket"
    ).

%% The SSO bucket is SHARED by every member realm, so deleting one member must
%% not revoke the siblings' tickets — nor the SSO-scoped ones, which still grant
%% the realms the user can still reach.
revoke_all_realm_spares_sibling_realms(_Config) ->
    M1Scope = ticket_scope(?M1),
    M2Scope = ticket_scope(?M2),
    SsoScope = ticket_scope(all),

    ok = bondy_ticket:store_ticket(?SSO, ?USER, ticket_claims(?SSO, M1Scope)),
    ok = bondy_ticket:store_ticket(?SSO, ?USER, ticket_claims(?SSO, M2Scope)),
    ok = bondy_ticket:store_ticket(?SSO, ?USER, ticket_claims(?SSO, SsoScope)),

    ok = bondy_ticket:revoke_all(?M1),

    ?assertEqual(
        {error, not_found},
        bondy_ticket:lookup(?SSO, ?USER, M1Scope),
        "The deleted realm's tickets must go"
    ),
    ?assertMatch(
        {ok, _},
        bondy_ticket:lookup(?SSO, ?USER, M2Scope),
        "A sibling member realm's tickets must survive"
    ),
    ?assertMatch(
        {ok, _},
        bondy_ticket:lookup(?SSO, ?USER, SsoScope),
        "An SSO-scoped ticket still grants the realms its user can reach"
    ),

    %% Leave the bucket clean for any later case.
    ok = bondy_ticket:revoke_all(?M2, ?USER).

%% The token mirror of `revoke_all_realm_spares_sibling_realms`, and the reason
%% resolving the auth realm and clearing its bucket is NOT a valid fix: all
%% three of these tokens live in ONE cell in the SSO realm's bucket (the store
%% key is a hash of the authid), so a bucket-wide clear would take every sibling
%% realm's tokens with it.
token_revoke_all_realm_spares_sibling_realms(_Config) ->
    M1Scope = bondy_oauth_token:authscope(issue_scoped_token(?M1)),
    M2Scope = bondy_oauth_token:authscope(issue_scoped_token(?M2)),
    SsoScope = bondy_oauth_token:authscope(issue_sso_token()),

    ?assertMatch({ok, _}, bondy_oauth_token:lookup(?M1, ?USER, M1Scope)),
    ?assertMatch({ok, _}, bondy_oauth_token:lookup(?M2, ?USER, M2Scope)),
    ?assertMatch({ok, _}, bondy_oauth_token:lookup(?M1, ?USER, SsoScope)),

    ok = bondy_oauth_token:revoke_all(?M1),

    %% `lookup/3` maps a missing token to `oauth2_invalid_grant`, not
    %% `not_found` — the OAuth2 error a caller must not be able to distinguish
    %% from a bad token.
    ?assertEqual(
        {error, oauth2_invalid_grant},
        bondy_oauth_token:lookup(?M1, ?USER, M1Scope),
        "The deleted realm's tokens must go"
    ),
    ?assertMatch(
        {ok, _},
        bondy_oauth_token:lookup(?M2, ?USER, M2Scope),
        "A sibling member realm's tokens must survive"
    ),
    ?assertMatch(
        {ok, _},
        bondy_oauth_token:lookup(?M1, ?USER, SsoScope),
        "An SSO-scoped token still grants the realms its user can reach"
    ),

    ok = bondy_oauth_token:revoke_all(?M2, ?USER).

%% `allow_sso => false` pins the token's scope to the realm it was issued in,
%% while the auth realm — and so the BUCKET — stays the SSO realm.
issue_scoped_token(RealmUri) ->
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?USER, [], {127, 0, 0, 1}
    ),
    {ok, Token} = bondy_oauth_token:issue(
        password, Ctxt, #{allow_sso => false}
    ),
    Token.

issue_sso_token() ->
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(
        SessionId, ?M1, ?USER, [], {127, 0, 0, 1}
    ),
    {ok, Token} = bondy_oauth_token:issue(
        password, Ctxt, #{allow_sso => true}
    ),
    Token.

%% A local-scope (`client_id = all`) scope on `RealmUri`, or the SSO scope when
%% given `all` — one ticket per cell either way.
ticket_scope(RealmUri) ->
    #{realm => RealmUri, client_id => all, device_id => all}.

ticket_claims(AuthRealmUri, Scope) ->
    #{
        authrealm => AuthRealmUri,
        authid => ?USER,
        scope => Scope,
        expires_at => erlang:system_time(second) + 3600
    }.

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
    %% Sanity: an SSO ticket is not pinned to a single realm. The wildcard is
    %% the atom `all`, matching the spelling used by bondy_oauth_token.
    ?assertMatch(#{scope := #{realm := all}}, Claims),
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
