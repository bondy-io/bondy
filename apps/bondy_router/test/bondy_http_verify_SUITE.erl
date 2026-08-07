%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_verify_SUITE).
-moduledoc """
Integration tests for the credential verification endpoint.

Starts a full Bondy node, loads an API Gateway specification carrying an `oidc`
security scheme, and drives `<base_path>/oidc/verify` over real HTTP.

The routing group asserts on the parser output directly, since route mounting
is decided before any request is served.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

-define(API_PORT, 18080).
-define(REALM, <<"com.example.verify">>).
-define(OTHER_REALM, <<"com.example.verify.other">>).
-define(BASE_PATH, <<"/vtest/v1.0">>).
-define(VERIFY_PATH, "/vtest/v1.0/oidc/verify").
-define(USER, <<"alice">>).
-define(DISABLED_USER, <<"bob">>).
-define(PROVIDER, <<"testidp">>).

%% SSO topology, mirroring bondy_trusted_issuer_SUITE:
%%   SSO      — an SSO realm
%%   M1, M2   — member realms (sso_realm_uri = SSO)
%%   M3       — a member realm the user is NOT a member of
%%   X        — ?OTHER_REALM, unrelated (no sso_realm_uri)
-define(SSO, <<"com.example.verify.sso">>).
-define(M1, <<"com.example.verify.m1">>).
-define(M2, <<"com.example.verify.m2">>).
-define(M3, <<"com.example.verify.m3">>).
-define(M1_VERIFY, "/vm1/v1.0/oidc/verify").
-define(M2_VERIFY, "/vm2/v1.0/oidc/verify").
-define(M3_VERIFY, "/vm3/v1.0/oidc/verify").
-define(X_VERIFY, "/vx/v1.0/oidc/verify").

all() ->
    [
        {group, routing},
        {group, http},
        {group, sso}
    ].

groups() ->
    [
        {routing, [], [
            mounts_verify_route,
            mounts_verify_route_with_zero_paths,
            does_not_duplicate_verify_route,
            verify_path_override,
            oauth2_scheme_mounts_verify_route
        ]},
        {http, [], [
            cookie_credential_is_accepted,
            bearer_credential_is_accepted,
            ticket_header_credential_is_accepted,
            identity_headers_match_body,
            no_cors_headers,
            does_not_leak_oidc_tokens,
            sets_no_store_cache_headers,
            no_credential_is_rejected,
            expired_ticket_is_rejected,
            tampered_ticket_is_rejected,
            revoked_ticket_is_rejected,
            cross_realm_ticket_is_rejected,
            disabled_user_is_rejected,
            deleted_user_is_rejected,
            malformed_credentials_never_500,
            deleted_realm_never_500,
            post_is_not_allowed
        ]},
        {sso, [], [
            sso_ticket_is_sso_shaped,
            sso_ticket_accepted_by_issuing_member,
            sso_ticket_accepted_by_sibling_member,
            sso_ticket_rejected_by_unrelated_realm,
            sso_ticket_rejected_when_not_a_member_of_target_realm,
            sso_ticket_rejected_when_user_disabled_in_target_realm,
            prototype_realm_inherits_sso_trust
        ]}
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    ok = ensure_realm(?REALM),
    ok = ensure_realm(?OTHER_REALM),
    ok = ensure_user(?REALM, ?USER),
    ok = ensure_user(?REALM, ?DISABLED_USER),
    ok = ensure_user(?OTHER_REALM, ?USER),
    ok = load_spec(),
    Config.

end_per_suite(Config) ->
    catch bondy_http_gateway:delete(<<"com.example.verify.api">>),
    {save_config, Config}.

init_per_group(sso, Config) ->
    ok = add_sso_realm(?SSO),
    ok = add_member_realm(?M1, ?SSO, [?USER]),
    ok = add_member_realm(?M2, ?SSO, [?USER]),
    %% M3 shares the SSO realm but the user is not one of its members.
    ok = add_member_realm(?M3, ?SSO, []),
    ok = load_spec(<<"com.example.verify.m1">>, ?M1, <<"/vm1/v1.0">>),
    ok = load_spec(<<"com.example.verify.m2">>, ?M2, <<"/vm2/v1.0">>),
    ok = load_spec(<<"com.example.verify.m3">>, ?M3, <<"/vm3/v1.0">>),
    ok = load_spec(<<"com.example.verify.x">>, ?OTHER_REALM, <<"/vx/v1.0">>),
    ok = await_route(?M1_VERIFY, 50),
    ok = await_route(?M2_VERIFY, 50),
    ok = await_route(?M3_VERIFY, 50),
    ok = await_route(?X_VERIFY, 50),
    Config;
init_per_group(_, Config) ->
    Config.

end_per_group(sso, Config) ->
    _ = [
        catch bondy_http_gateway:delete(Id)
     || Id <- [
            <<"com.example.verify.m1">>,
            <<"com.example.verify.m2">>,
            <<"com.example.verify.m3">>,
            <<"com.example.verify.x">>
        ]
    ],
    Config;
end_per_group(_, Config) ->
    Config.

%% =============================================================================
%% ROUTING
%% =============================================================================

mounts_verify_route(_) ->
    Rules = scheme_rules(spec(#{})),
    ?assert(
        lists:member(<<?BASE_PATH/binary, "/oidc/verify">>, paths(Rules)),
        "the oidc security scheme must mount the verify endpoint"
    ).

mounts_verify_route_with_zero_paths(_) ->
    %% An API that exists only to expose the security scheme endpoints declares
    %% no paths of its own. This is the shape of examples/config/oidc_api_spec.
    Rules = scheme_rules(spec(#{}, #{})),
    Paths = paths(Rules),
    ?assert(
        lists:member(<<?BASE_PATH/binary, "/oidc/verify">>, Paths),
        "verify must mount even when the version declares no paths"
    ),
    ?assert(
        lists:member(<<?BASE_PATH/binary, "/oidc/login">>, Paths),
        "the other security scheme routes must mount too"
    ).

does_not_duplicate_verify_route(_) ->
    %% security_scheme_rules/5 is evaluated once per version AND once per path,
    %% so a three-path spec emits the tuple four times. Identical rules collapse
    %% in build_dispatch_table/3 because a leap_relation is a set.
    Spec = spec(#{}, #{
        <<"/a">> => path_spec(),
        <<"/b">> => path_spec(),
        <<"/c">> => path_spec()
    }),
    Verify = <<?BASE_PATH/binary, "/oidc/verify">>,
    Table = bondy_http_gateway_api_spec_parser:dispatch_table(
        [bondy_http_gateway_api_spec_parser:parse(Spec)], []
    ),
    ?assertEqual(1, count_path(Verify, Table)).

verify_path_override(_) ->
    Rules = scheme_rules(spec(#{<<"verify_path">> => <<"/oidc/check">>})),
    Paths = paths(Rules),
    ?assert(lists:member(<<?BASE_PATH/binary, "/oidc/check">>, Paths)),
    ?assertNot(lists:member(<<?BASE_PATH/binary, "/oidc/verify">>, Paths)).

oauth2_scheme_mounts_verify_route(_) ->
    Sec = #{
        <<"type">> => <<"oauth2">>,
        <<"flow">> => <<"resource_owner_password_credentials">>,
        <<"schemes">> => [<<"http">>]
    },
    Rules = scheme_rules(spec_with_security(Sec, #{})),
    ?assert(
        lists:member(<<?BASE_PATH/binary, "/oauth/verify">>, paths(Rules))
    ).

%% =============================================================================
%% HTTP
%% =============================================================================

cookie_credential_is_accepted(_) ->
    {ok, JWT, _} = issue_ticket(?REALM, ?USER),
    {Status, _, Body} = get_verify(cookie_header(?REALM, JWT)),
    ?assertEqual(200, Status),
    ?assertMatch(#{~"active" := true, ~"authid" := ?USER}, decode(Body)).

bearer_credential_is_accepted(_) ->
    {ok, JWT, _} = issue_ticket(?REALM, ?USER),
    {Status, _, Body} = get_verify([
        {<<"authorization">>, <<"Bearer ", JWT/binary>>}
    ]),
    ?assertEqual(200, Status),
    ?assertMatch(#{~"authid" := ?USER}, decode(Body)).

ticket_header_credential_is_accepted(_) ->
    {ok, JWT, _} = issue_ticket(?REALM, ?USER),
    {Status, _, Body} = get_verify([{<<"x-bondy-ticket">>, JWT}]),
    ?assertEqual(200, Status),
    ?assertMatch(#{~"authid" := ?USER}, decode(Body)).

identity_headers_match_body(_) ->
    {ok, JWT, _} = issue_ticket(?REALM, ?USER),
    {200, Headers, Body} = get_verify(cookie_header(?REALM, JWT)),
    Decoded = decode(Body),
    ?assertEqual(?USER, header(<<"x-bondy-authid">>, Headers)),
    ?assertEqual(?REALM, header(<<"x-bondy-authrealm">>, Headers)),
    ?assertEqual(?REALM, header(<<"x-bondy-realm">>, Headers)),
    ?assertEqual(
        maps:get(~"authid", Decoded), header(<<"x-bondy-authid">>, Headers)
    ),
    ?assertEqual(
        integer_to_binary(maps:get(~"expires_at", Decoded)),
        header(<<"x-bondy-expires-at">>, Headers)
    ).

no_cors_headers(_) ->
    {ok, JWT, _} = issue_ticket(?REALM, ?USER),
    Headers0 = [{<<"origin">>, <<"https://evil.example">>}],
    {200, Headers, _} = get_verify(Headers0 ++ cookie_header(?REALM, JWT)),
    %% Without an Allow-Origin header a browser will not let a foreign origin
    %% read the identity, even though it can cause the cookie to be sent.
    ?assertEqual(
        undefined, header(<<"access-control-allow-origin">>, Headers)
    ),
    ?assertEqual(
        undefined, header(<<"access-control-allow-credentials">>, Headers)
    ).

does_not_leak_oidc_tokens(_) ->
    IdToken = <<"id-token-must-not-be-echoed">>,
    RefreshToken = <<"refresh-token-must-not-be-echoed">>,
    {ok, JWT, _} = bondy_oidc_ticket:issue(
        ?REALM,
        ?USER,
        ?PROVIDER,
        #{id_token => IdToken, refresh_token => RefreshToken},
        #{authroles => [], expiry_time_secs => 3600}
    ),
    {200, _, Body} = get_verify(cookie_header(?REALM, JWT)),
    ?assertEqual(nomatch, binary:match(Body, IdToken)),
    ?assertEqual(nomatch, binary:match(Body, RefreshToken)).

sets_no_store_cache_headers(_) ->
    {ok, JWT, _} = issue_ticket(?REALM, ?USER),
    {200, Headers, _} = get_verify(cookie_header(?REALM, JWT)),
    CacheControl = header(<<"cache-control">>, Headers),
    ?assertNotEqual(nomatch, binary:match(CacheControl, <<"no-store">>)),
    ?assertNotEqual(undefined, header(<<"vary">>, Headers)).

no_credential_is_rejected(_) ->
    {Status, _, Body} = get_verify([]),
    ?assertEqual(401, Status),
    ?assertMatch(#{~"active" := false}, decode(Body)).

expired_ticket_is_rejected(_) ->
    %% The verifier allows a 120s leeway, so the ticket must be older than that.
    {ok, JWT, _} = issue_ticket(?REALM, ?USER, -300),
    {Status, _, Body} = get_verify(cookie_header(?REALM, JWT)),
    ?assertEqual(401, Status),
    ?assertEqual(
        ~"bondy.error.token_expired", maps:get(~"uri", decode(Body))
    ).

tampered_ticket_is_rejected(_) ->
    {ok, JWT, _} = issue_ticket(?REALM, ?USER),
    Tampered = tamper(JWT),
    {Status, _, Body} = get_verify(cookie_header(?REALM, Tampered)),
    ?assertEqual(401, Status),
    ?assertEqual(
        ~"bondy.error.token_invalid", maps:get(~"uri", decode(Body))
    ).

revoked_ticket_is_rejected(_) ->
    %% Revocation is only enforced when the stored copy of the ticket is
    %% required. With `security.ticket.allow_not_found` at its shipped default
    %% of `on`, verification falls back to trusting the signature, so a revoked
    %% ticket keeps passing until it expires — the endpoint deliberately
    %% behaves exactly like WAMP ticket authentication here. Both halves are
    %% asserted so the trade-off cannot change silently.
    Key = [security, ticket, allow_not_found],
    Original = bondy_config:get(Key),

    {ok, JWT, Claims} = issue_ticket(?REALM, ?USER),
    {200, _, _} = get_verify(cookie_header(?REALM, JWT)),
    ok = bondy_ticket:revoke(Claims),

    try
        ok = bondy_config:set(Key, true),
        ?assertMatch(
            {200, _, _},
            get_verify(cookie_header(?REALM, JWT)),
            "with allow_not_found on, a revoked ticket still verifies"
        ),

        ok = bondy_config:set(Key, false),
        ?assertMatch(
            {401, _, _},
            get_verify(cookie_header(?REALM, JWT)),
            "with allow_not_found off, revocation closes the gate"
        )
    after
        bondy_config:set(Key, Original)
    end.

cross_realm_ticket_is_rejected(_) ->
    %% A ticket minted by another realm must not open this realm's gate.
    {ok, JWT, _} = issue_ticket(?OTHER_REALM, ?USER),
    {Status, _, _} = get_verify(cookie_header(?OTHER_REALM, JWT)),
    ?assertEqual(401, Status).

disabled_user_is_rejected(_) ->
    {ok, JWT, _} = issue_ticket(?REALM, ?DISABLED_USER),
    {200, _, _} = get_verify(cookie_header(?REALM, JWT)),
    %% Signature and expiry are untouched by this; only the user changed.
    ok = bondy_rbac_user:disable(?REALM, ?DISABLED_USER),
    try
        {Status, _, _} = get_verify(cookie_header(?REALM, JWT)),
        ?assertEqual(401, Status)
    after
        catch bondy_rbac_user:enable(?REALM, ?DISABLED_USER)
    end.

deleted_user_is_rejected(_) ->
    Username = <<"carol">>,
    ok = ensure_user(?REALM, Username),
    {ok, JWT, _} = issue_ticket(?REALM, Username),
    {200, _, _} = get_verify(cookie_header(?REALM, JWT)),
    ok = bondy_rbac_user:remove(?REALM, Username),
    {Status, _, _} = get_verify(cookie_header(?REALM, JWT)),
    ?assertEqual(401, Status).

malformed_credentials_never_500(_) ->
    %% cow_http_hd:parse_authorization/1 and cow_cookie:parse_cookie/1 raise on
    %% each of these, which would otherwise surface as a 500 plus a crash report
    %% for any unauthenticated caller.
    Cases = [
        [{<<"authorization">>, <<"garbage">>}],
        [{<<"authorization">>, <<"Bearer">>}],
        [{<<"authorization">>, <<"Bearer ">>}],
        [{<<"authorization">>, <<"Basic zzz">>}],
        [{<<"authorization">>, <<"Bearer a.b.c">>}],
        [{<<"authorization">>, <<"Bearer eyJhbGciOiJub25lIn0.W10.">>}],
        [{<<"cookie">>, <<"=x">>}],
        [{<<"x-bondy-ticket">>, <<"not-a-jwt">>}]
    ],
    lists:foreach(
        fun(Headers) ->
            {Status, _, _} = get_verify(Headers),
            ?assertEqual(401, Status, {unexpected_status, Headers})
        end,
        Cases
    ).

deleted_realm_never_500(_) ->
    %% Routes outlive their realm: the dispatch table is compiled ahead of
    %% time, so a request can arrive for a realm that has since been removed.
    %% The realm and user lookups raise in that case and must not surface as a
    %% 5xx, which a proxy cannot act on.
    Transient = <<"com.example.verify.transient">>,
    ok = ensure_realm(Transient),
    ok = ensure_user(Transient, ?USER),
    {ok, JWT, _} = issue_ticket(Transient, ?USER),
    ok = bondy_realm:delete(Transient, #{force => true}),
    {Status, _, _} = get_verify(cookie_header(Transient, JWT)),
    ?assertEqual(401, Status).

post_is_not_allowed(_) ->
    {ok, Status, _, _} = hackney:request(
        post, api_url(?VERIFY_PATH), [], <<>>, []
    ),
    ?assertEqual(405, Status).

%% =============================================================================
%% SSO AND REALM INHERITANCE
%% =============================================================================

sso_ticket_is_sso_shaped(_) ->
    %% Guards every other case in this group: if the ticket stopped being
    %% SSO-scoped they would silently degrade into same-realm tests and the
    %% trust boundary below would no longer be exercised at all.
    {_, Claims} = issue_sso_ticket(),
    ?assertMatch(#{scope := #{realm := all}}, Claims),
    ?assertEqual(?SSO, maps:get(authrealm, Claims)).

sso_ticket_accepted_by_issuing_member(_) ->
    {JWT, _} = issue_sso_ticket(),
    {Status, _, Body} = get_verify(?M1_VERIFY, cookie_header(?SSO, JWT)),
    ?assertEqual(200, Status),
    ?assertMatch(#{~"authid" := ?USER, ~"authrealm" := ?SSO}, decode(Body)).

sso_ticket_accepted_by_sibling_member(_) ->
    %% The `is_trusted_issuer/2` SSO branch: M2 never issued this ticket, but
    %% it shares M1's SSO realm, so the issuer is trusted.
    {JWT, _} = issue_sso_ticket(),
    {Status, _, Body} = get_verify(?M2_VERIFY, cookie_header(?SSO, JWT)),
    ?assertEqual(200, Status),
    ?assertMatch(#{~"realm" := ?M2, ~"authrealm" := ?SSO}, decode(Body)).

sso_ticket_rejected_by_unrelated_realm(_) ->
    %% The security crux. `matches_realm/2` returns true for ANY realm when the
    %% scope is SSO-wide, so the scope check alone would let this through.
    %% `is_trusted_issuer/2` is what actually pins it: X has no SSO realm.
    {JWT, Claims} = issue_sso_ticket(),
    ?assert(
        bondy_auth_scope:matches_realm(maps:get(scope, Claims), ?OTHER_REALM)
    ),
    ?assertNot(bondy_realm:is_trusted_issuer(?OTHER_REALM, ?SSO)),

    {Status, _, Body} = get_verify(?X_VERIFY, cookie_header(?SSO, JWT)),
    ?assertEqual(401, Status),
    ?assertEqual(
        ~"bondy.error.token_invalid", maps:get(~"uri", decode(Body))
    ).

sso_ticket_rejected_when_not_a_member_of_target_realm(_) ->
    %% M3 trusts the issuer and the scope is realm-wide, so both realm checks
    %% pass — only the principal check stands between the caller and a 200.
    %% An SSO realm can name a user; it cannot make them a member of M3.
    {JWT, _} = issue_sso_ticket(),
    ?assert(bondy_realm:is_trusted_issuer(?M3, ?SSO)),
    ?assertEqual({error, not_found}, bondy_rbac_user:lookup(?M3, ?USER)),

    {Status, _, _} = get_verify(?M3_VERIFY, cookie_header(?SSO, JWT)),
    ?assertEqual(401, Status).

sso_ticket_rejected_when_user_disabled_in_target_realm(_) ->
    %% Disabled in M2 only: M1 must keep working, so this proves the check is
    %% made against the realm being accessed, not the issuing one.
    {JWT, _} = issue_sso_ticket(),
    ok = bondy_rbac_user:disable(?M2, ?USER),
    try
        ?assertMatch(
            {401, _, _}, get_verify(?M2_VERIFY, cookie_header(?SSO, JWT))
        ),
        ?assertMatch(
            {200, _, _}, get_verify(?M1_VERIFY, cookie_header(?SSO, JWT))
        )
    after
        catch bondy_rbac_user:enable(?M2, ?USER)
    end.

prototype_realm_inherits_sso_trust(_) ->
    %% `bondy_realm:sso_realm_uri/1` walks the prototype chain, so a realm that
    %% declares no SSO realm of its own still trusts its prototype's.
    Proto = <<"com.example.verify.proto">>,
    Child = <<"com.example.verify.child">>,
    ok = add_prototype_realm(Proto, ?SSO),
    ok = add_prototype_child_realm(Child, Proto, [?USER]),

    ?assertEqual(?SSO, bondy_realm:sso_realm_uri(Child)),
    ?assert(bondy_realm:is_trusted_issuer(Child, ?SSO)),

    ok = load_spec(<<"com.example.verify.child">>, Child, <<"/vchild/v1.0">>),
    Path = "/vchild/v1.0/oidc/verify",
    ok = await_route(Path, 50),

    try
        {JWT, _} = issue_sso_ticket(),
        {Status, _, Body} = get_verify(Path, cookie_header(?SSO, JWT)),
        ?assertEqual(200, Status),
        ?assertMatch(#{~"realm" := Child}, decode(Body))
    after
        catch bondy_http_gateway:delete(<<"com.example.verify.child">>)
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

api_url(Path) ->
    iolist_to_binary([
        "http://localhost:", integer_to_list(?API_PORT), Path
    ]).

get_verify(Headers) ->
    get_verify(?VERIFY_PATH, Headers).

get_verify(Path, Headers) ->
    {ok, Status, RespHeaders, Ref} = hackney:request(
        get, api_url(Path), Headers, <<>>, []
    ),
    Body =
        case hackney:body(Ref) of
            {ok, B} -> B;
            {error, _} -> <<>>
        end,
    {Status, RespHeaders, Body}.

cookie_header(RealmUri, JWT) ->
    Name = bondy_http_utils:ticket_cookie_name(RealmUri),
    [{<<"cookie">>, <<Name/binary, "=", JWT/binary>>}].

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> Value;
        false -> undefined
    end.

decode(<<>>) ->
    #{};
decode(Body) ->
    json:decode(Body).

%% Flips a byte of the signature so the JWT stays well-formed but fails
%% verification.
tamper(JWT) ->
    [H, P, S] = binary:split(JWT, <<".">>, [global]),
    <<First:8, Rest/binary>> = S,
    Flipped =
        case First of
            $A -> $B;
            _ -> $A
        end,
    <<H/binary, ".", P/binary, ".", Flipped, Rest/binary>>.

issue_ticket(RealmUri, Authid) ->
    issue_ticket(RealmUri, Authid, 3600).

issue_ticket(RealmUri, Authid, ExpirySecs) ->
    bondy_oidc_ticket:issue(
        RealmUri,
        Authid,
        ?PROVIDER,
        #{},
        #{authroles => [], expiry_time_secs => ExpirySecs}
    ).

ensure_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"Verify endpoint test realm">>,
        authmethods => [<<"ticket">>, <<"anonymous">>],
        security_enabled => true
    },
    _ =
        case bondy_realm:exists(RealmUri) of
            true -> bondy_realm:fetch(RealmUri);
            false -> bondy_realm:create(Config)
        end,
    ok.

ensure_user(RealmUri, Username) ->
    case bondy_rbac_user:lookup(RealmUri, Username) of
        {ok, _} ->
            ok;
        {error, not_found} ->
            User = bondy_rbac_user:new(#{
                username => Username,
                groups => [],
                meta => #{}
            }),
            {ok, _} = bondy_rbac_user:add(RealmUri, User),
            ok
    end.

load_spec() ->
    ok = bondy_http_gateway:load(spec(#{}, #{})),
    _ = bondy_http_gateway:rebuild_dispatch_tables(),
    ok = await_route(?VERIFY_PATH, 50).

load_spec(Id, RealmUri, BasePath) ->
    Sec = #{
        <<"type">> => <<"oidc">>,
        <<"provider">> => ?PROVIDER,
        <<"schemes">> => [<<"http">>]
    },
    ok = bondy_http_gateway:load(spec(Id, RealmUri, BasePath, Sec, #{})),
    _ = bondy_http_gateway:rebuild_dispatch_tables(),
    ok.

%% Polls the endpoint itself rather than inspecting the dispatch table: rebuilds
%% are debounced, and `bondy_http_gateway:dispatch_table/1` hands back a
%% `{persistent_term, Key}` indirection rather than the routes. An unmounted
%% path answers 404; a mounted one answers 401 for a request with no credential.
await_route(_, 0) ->
    error(verify_route_not_mounted);
await_route(Path, N) ->
    case get_verify(Path, []) of
        {404, _, _} ->
            timer:sleep(100),
            await_route(Path, N - 1);
        _ ->
            ok
    end.

%% Mints a genuinely SSO-scoped ticket: `alice` is SSO-managed in M1, so
%% `bondy_ticket:issue/2` with `allow_sso` yields `scope.realm = all` and
%% `authrealm = SSO`.
issue_sso_ticket() ->
    Session = bondy_session:new(?M1, #{
        peer => {{127, 0, 0, 1}, 0},
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
    {Ticket, Claims}.

add_sso_realm(Uri) ->
    _ = bondy_realm:create(#{
        uri => Uri,
        description => <<"Verify endpoint SSO realm">>,
        authmethods => [?WAMP_CRA_AUTH, ?WAMP_CRYPTOSIGN_AUTH],
        security_enabled => true,
        is_sso_realm => true,
        allow_connections => false
    }),
    ok.

add_member_realm(Uri, SSOUri, Usernames) ->
    _ = bondy_realm:create(#{
        uri => Uri,
        description => <<"Verify endpoint member realm">>,
        authmethods => [
            ?WAMP_TICKET_AUTH, ?WAMP_CRA_AUTH, ?PASSWORD_AUTH
        ],
        security_enabled => true,
        sso_realm_uri => SSOUri,
        grants => [
            #{
                permissions => [<<"bondy.issue">>],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => <<"all">>
            }
        ],
        users => [
            #{
                username => U,
                password => <<"aWe11KeptSecret">>,
                groups => [],
                sso_realm_uri => SSOUri
            }
         || U <- Usernames
        ],
        sources => [
            #{
                usernames => <<"all">>,
                authmethod => ?WAMP_CRA_AUTH,
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

add_prototype_realm(Uri, SSOUri) ->
    _ = bondy_realm:create(#{
        uri => Uri,
        description => <<"Verify endpoint prototype realm">>,
        is_prototype => true,
        security_enabled => true,
        sso_realm_uri => SSOUri,
        %% Required, and not merely tidy: `bondy_realm:allow_connections/1`
        %% falls back to `not is_prototype` when the value is unset, and a child
        %% realm inherits that computed `false`. Leaving it out here would close
        %% the child realm to every caller and make this test fail for a reason
        %% having nothing to do with SSO trust.
        allow_connections => true
    }),
    ok.

add_prototype_child_realm(Uri, ProtoUri, Usernames) ->
    _ = bondy_realm:create(#{
        uri => Uri,
        description => <<"Verify endpoint prototype child realm">>,
        prototype_uri => ProtoUri,
        security_enabled => true,
        users => [
            #{
                username => U,
                password => <<"aWe11KeptSecret">>,
                groups => []
            }
         || U <- Usernames
        ]
    }),
    ok.

%% The parser emits [{Scheme, [{Host, [{Path, Mod, State}]}]}].
count_path(Path, Table) ->
    length([
        P
     || {_Scheme, Hosts} <- Table,
        {_Host, Paths} <- Hosts,
        {P, _, _} <- Paths,
        P == Path
    ]).

scheme_rules(Spec) ->
    bondy_http_gateway_api_spec_parser:dispatch_table(
        [bondy_http_gateway_api_spec_parser:parse(Spec)], []
    ).

paths(Table) ->
    lists:usort([
        P
     || {_Scheme, Hosts} <- Table,
        {_Host, Paths} <- Hosts,
        {P, _, _} <- Paths
    ]).

path_spec() ->
    #{
        <<"is_collection">> => false,
        <<"get">> => #{
            <<"action">> => #{
                <<"type">> => <<"static">>,
                <<"response">> => #{}
            },
            <<"response">> => #{
                <<"on_result">> => #{<<"body">> => <<>>},
                <<"on_error">> => #{<<"body">> => <<>>}
            }
        }
    }.

spec(SecurityExtra) ->
    spec(SecurityExtra, #{<<"/things">> => path_spec()}).

spec(SecurityExtra, Paths) ->
    Sec = maps:merge(
        #{
            <<"type">> => <<"oidc">>,
            <<"provider">> => ?PROVIDER,
            <<"schemes">> => [<<"http">>]
        },
        SecurityExtra
    ),
    spec_with_security(Sec, Paths).

spec_with_security(Sec, Paths) ->
    spec(<<"com.example.verify.api">>, ?REALM, ?BASE_PATH, Sec, Paths).

spec(Id, RealmUri, BasePath, Sec, Paths) ->
    #{
        <<"id">> => Id,
        <<"name">> => Id,
        <<"host">> => <<"_">>,
        <<"realm_uri">> => RealmUri,
        <<"variables">> => #{
            <<"schemes">> => [<<"http">>],
            <<"security">> => Sec
        },
        <<"defaults">> => #{
            <<"timeout">> => 15000,
            <<"security">> => <<"{{variables.security}}">>,
            <<"schemes">> => <<"{{variables.schemes}}">>
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => BasePath,
                <<"paths">> => Paths
            }
        }
    }.
