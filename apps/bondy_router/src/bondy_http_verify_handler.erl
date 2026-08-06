%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_verify_handler).
-moduledoc """
Verifies a Bondy credential presented over HTTP and reports the identity behind
it.

The endpoint exists so that a reverse proxy can gate content on "is this caller
authenticated with Bondy?" without itself understanding JWTs, realms or key
rotation. It is mounted next to the other security scheme endpoints of an API
Gateway specification, at `<base_path>/oidc/verify` for an `oidc` scheme and
`<base_path>/oauth/verify` for an `oauth2` one, and it verifies against the
realm that specification is bound to.

## Contract

`GET` (or `HEAD`) with the credential in one of, in order of precedence:

1. `Authorization: Bearer <credential>`
2. `X-Bondy-Ticket: <ticket>`
3. the `bondy_ticket_<RealmUri>` cookie set by the OIDC authorization code flow

The first source that carries a value is the one verified; there is no fallback
to a later source when an earlier one fails.

A valid credential answers `200` with the identity as JSON and as `x-bondy-*`
response headers. Anything else answers `401`. Those are the only two outcomes
a proxy can act on: NGINX `auth_request` treats 401 and 403 as a denial and
turns every other non-2xx into a `500` for the end user, so failures that are
arguably server-side — an unknown realm, an internal error — are still reported
as `401` here, with the real cause logged.

## What is verified

Signature, expiry and revocation, via `bondy_ticket:verify/1` or
`bondy_oauth_jwt:verify/2`. On top of that, and deliberately matching what
`bondy_auth` enforces when a WAMP session is opened:

- the credential's scope covers this realm, and its issuer is trusted by this
  realm (`bondy_realm:is_trusted_issuer/2`) — the scope check alone is not
  enough, since an SSO-scoped credential matches every realm
- the user still exists and is enabled
- the realm still allows connections
- for access tokens, the `token_version` gate in `bondy_auth_oauth2`

Without the last three a ticket would keep opening the gate after the user was
disabled or removed, until it expired.

Authorization is out of scope: this answers who the caller is, not what they
may do.

## Not CORS-enabled

No `Access-Control-Allow-*` header is emitted, so a browser will not let a
foreign origin read the identity of a user whose cookie it can nonetheless
cause to be sent. The endpoint is meant to be called by a proxy, server to
server. For the same reason no CSRF token is required: the request is safe and
a proxy has none to send.
""".

-include_lib("kernel/include/logger.hrl").
-include("http_api.hrl").

-type state() :: #{realm_uri := binary()}.

%% COWBOY CALLBACKS
-export([init/2]).

%% =============================================================================
%% COWBOY CALLBACKS
%% =============================================================================

-doc false.
-spec init(Req :: cowboy_req:req(), State :: state()) ->
    {ok, cowboy_req:req(), state()}.

init(Req0, State) ->
    Req1 = bondy_http_utils:set_all_headers(Req0),
    Req2 = handle(cowboy_req:method(Req1), Req1, State),
    {ok, Req2, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
handle(Method, Req, #{realm_uri := RealmUri}) when
    Method == <<"GET">> orelse Method == <<"HEAD">>
->
    case do_verify(RealmUri, Req) of
        {ok, Identity} ->
            reply_ok(RealmUri, Identity, Req);

        {error, Reason} ->
            ?LOG_INFO(#{
                description => "Credential verification failed",
                realm_uri => RealmUri,
                reason => Reason
            }),
            reply_error(?HTTP_UNAUTHORIZED, error_type(Reason), RealmUri, Req)
    end;

handle(_, Req, _) ->
    Headers = maps:put(
        <<"allow">>, <<"GET, HEAD">>, no_store_headers()
    ),
    cowboy_req:reply(?HTTP_METHOD_NOT_ALLOWED, Headers, <<>>, Req).

%% @private
do_verify(RealmUri, Req) ->
    try
        Credential = credential(RealmUri, Req),
        Credential =/= undefined orelse throw(no_credential),

        Identity =
            case classify(Credential) of
                ticket ->
                    verify_ticket(RealmUri, Credential);
                oauth2 ->
                    verify_access_token(RealmUri, Credential);
                unknown ->
                    throw(invalid)
            end,

        ok = check_principal(RealmUri, maps:get(authid, Identity)),
        ok = check_realm(RealmUri),

        {ok, Identity}
    catch
        throw:Reason ->
            {error, Reason};

        Class:Reason:Stacktrace ->
            %% Nothing may escape as a 5xx: a proxy cannot act on one, and an
            %% unauthenticated caller must not be able to provoke crash reports.
            %% Reachable when the realm is removed after the dispatch table was
            %% compiled, since the realm and user lookups then raise.
            ?LOG_WARNING(#{
                description => "Error while verifying credential",
                realm_uri => RealmUri,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, invalid}
    end.

%% -----------------------------------------------------------------------------
%% Credential extraction
%% -----------------------------------------------------------------------------

%% @private
%% Explicit beats ambient: a caller that went to the trouble of naming a
%% credential means that one, so we never silently fall back to the cookie when
%% it turns out to be invalid.
credential(RealmUri, Req) ->
    case bondy_http_utils:safe_bearer_token(Req) of
        undefined ->
            header_or_cookie_credential(RealmUri, Req);
        Token ->
            Token
    end.

%% @private
header_or_cookie_credential(RealmUri, Req) ->
    case cowboy_req:header(?TICKET_HEADER, Req, undefined) of
        Ticket when is_binary(Ticket), Ticket =/= <<>> ->
            Ticket;

        _ ->
            Cookies = bondy_http_utils:safe_parse_cookies(Req),

            case bondy_http_utils:find_ticket_cookie(RealmUri, Cookies) of
                {value, {_, Value}} when is_binary(Value), Value =/= <<>> ->
                    Value;
                _ ->
                    undefined
            end
    end.

%% @private
%% Both credentials are JWTs, so the payload shape is what tells them apart: a
%% Bondy ticket carries `authrealm` and `scope`, an access token carries `aud`
%% and `kid`. This runs on unverified input and only picks the verifier — both
%% verifiers re-read and check the signature themselves, so nothing here is
%% trusted. `jose_jwt:peek/1` raises several different ways on malformed input,
%% hence the blanket catch.
classify(Credential) ->
    try jose_jwt:peek(Credential) of
        {jose_jwt, #{~"authrealm" := R, ~"scope" := _}} when is_binary(R) ->
            ticket;
        {jose_jwt, #{~"aud" := A, ~"kid" := _}} when is_binary(A) ->
            oauth2;
        _ ->
            unknown
    catch
        _:_ ->
            unknown
    end.

%% -----------------------------------------------------------------------------
%% Verification
%% -----------------------------------------------------------------------------

%% @private
verify_ticket(RealmUri, Ticket) ->
    case bondy_ticket:verify(Ticket) of
        {ok, #{scope := Scope, authrealm := AuthRealmUri} = Claims} ->
            %% Both checks are required. `matches_realm/2` is true for every
            %% realm when the scope is SSO-wide, so on its own it would let a
            %% ticket issued for one realm authenticate against any other.
            bondy_auth_scope:matches_realm(Scope, RealmUri) orelse
                throw(realm_mismatch),
            bondy_realm:is_trusted_issuer(RealmUri, AuthRealmUri) orelse
                throw(untrusted_issuer),

            #{
                authid => maps:get(authid, Claims),
                authrealm => AuthRealmUri,
                authroles => maps:get(authroles, Claims, []),
                authmethod => maps:get(authmethod, Claims),
                scope => Scope,
                issued_at => maps:get(issued_at, Claims),
                expires_at => maps:get(expires_at, Claims)
            };

        {error, Reason} ->
            throw(Reason)
    end.

%% @private
verify_access_token(RealmUri, JWT) ->
    case bondy_oauth_jwt:verify(RealmUri, JWT) of
        {ok, Claims} ->
            Authid = maps:get(~"sub", Claims),

            %% The same gate `bondy_auth_oauth2` applies on the session path:
            %% the token must not predate a credential or membership change.
            case bondy_auth_oauth2:cp_security_check(Claims, Authid) of
                ok -> ok;
                {error, Reason} -> throw(Reason)
            end,

            Auth = maps:get(~"auth", Claims, #{}),
            IssuedAt = maps:get(~"iat", Claims),

            #{
                authid => Authid,
                authrealm => maps:get(~"aud", Claims),
                authroles => maps:get(~"roles", Auth, []),
                authmethod => ~"oauth2",
                scope => maps:get(~"scope", Auth, #{}),
                issued_at => IssuedAt,
                %% `exp` is a duration, not an instant.
                expires_at => IssuedAt + maps:get(~"exp", Claims)
            };

        {error, Reason} ->
            throw(Reason)
    end.

%% @private
%% Neither verifier reads the user, so without this a ticket would keep
%% authenticating a user who has since been disabled or removed. Resolution is
%% shared with `bondy_auth:get_user/3` so that this endpoint and the WAMP
%% session path cannot disagree on who counts as a valid principal — notably,
%% an SSO realm naming a user does not by itself make them a member of the
%% realm being accessed.
check_principal(RealmUri, Authid) ->
    SSORealmUri = bondy_realm:sso_realm_uri(RealmUri),

    case bondy_rbac_user:lookup(RealmUri, SSORealmUri, Authid) of
        {ok, _} ->
            ok;
        {error, user_disabled} ->
            throw(user_disabled);
        {error, not_found} ->
            throw(no_such_user)
    end.

%% @private
check_realm(RealmUri) ->
    bondy_realm:allow_connections(RealmUri) orelse
        throw(connections_not_allowed),
    ok.

%% -----------------------------------------------------------------------------
%% Replies
%% -----------------------------------------------------------------------------

%% @private
%% The body is assembled field by field on purpose. A ticket's claims also carry
%% the user's OIDC `id_token` and `refresh_token`, so serialising the claims map
%% would hand those to the proxy, and from there into `auth_request_set` and its
%% access logs.
reply_ok(RealmUri, Identity, Req) ->
    #{
        authid := Authid,
        authrealm := AuthRealmUri,
        authroles := Authroles,
        authmethod := Authmethod,
        scope := Scope,
        issued_at := IssuedAt,
        expires_at := ExpiresAt
    } = Identity,

    Body = json:encode(#{
        ~"active" => true,
        ~"authid" => Authid,
        ~"authrealm" => AuthRealmUri,
        ~"realm" => RealmUri,
        ~"authroles" => Authroles,
        ~"authmethod" => Authmethod,
        ~"scope" => Scope,
        ~"issued_at" => IssuedAt,
        ~"expires_at" => ExpiresAt,
        ~"expires_in" => max(0, ExpiresAt - erlang:system_time(second))
    }),

    Headers = maps:merge(no_store_headers(), #{
        <<"content-type">> => <<"application/json">>,
        ?AUTHID_HEADER => Authid,
        ?AUTHREALM_HEADER => AuthRealmUri,
        ?REALM_HEADER => RealmUri,
        ?AUTHROLES_HEADER => join_roles(Authroles),
        ?AUTHMETHOD_HEADER => Authmethod,
        ?EXPIRES_AT_HEADER => integer_to_binary(ExpiresAt)
    }),

    cowboy_req:reply(?HTTP_OK, Headers, Body, Req).

%% @private
reply_error(Status, Type, RealmUri, Req) ->
    Error = bondy_error:from_term(Type),
    Body = json:encode(
        maps:put(~"active", false, bondy_error:to_map(Error))
    ),

    Headers = maps:merge(no_store_headers(), #{
        <<"content-type">> => <<"application/json">>,
        <<"www-authenticate">> =>
            <<"Bearer realm=\"", RealmUri/binary,
                "\", error=\"invalid_token\"">>
    }),

    cowboy_req:reply(Status, Headers, Body, Req).

%% @private
%% An identity response must not be stored by any intermediary, and it varies
%% by every credential source we read.
no_store_headers() ->
    #{
        <<"cache-control">> => <<"no-store, no-cache, must-revalidate">>,
        <<"pragma">> => <<"no-cache">>,
        <<"vary">> => <<"Authorization, Cookie, X-Bondy-Ticket">>
    }.

%% @private
join_roles([]) ->
    <<>>;
join_roles(Roles) ->
    iolist_to_binary(lists:join($,, Roles)).

%% @private
%% Every failure maps to a `bondy_error` type whose HTTP status is 401.
%% Routing raw reasons through `bondy_error:from_term/1` would not do: bare
%% atoms fall through to `internal_error` (500) and `oauth2_invalid_grant`
%% resolves to `bondy.error.invalid_grant` (400). A proxy can act on neither.
error_type(expired) -> token_expired;
error_type(no_credential) -> invalid_credentials;
error_type(no_such_user) -> invalid_credentials;
error_type(user_disabled) -> invalid_credentials;
error_type(_) -> token_invalid.
