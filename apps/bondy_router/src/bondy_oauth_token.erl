%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oauth_token).

-moduledoc """
OAuth 2.0 tokens: issuing them, refreshing them, and revoking them.

A refresh token is a durable credential; an access token is a short-lived JWT
minted from one. `issue/3` returns a token record, `to_refresh_token/1` yields
the opaque string a client stores, and `to_access_token/1` the signed JWT it
presents. `refresh/2` exchanges the former for a fresh pair.

A token's authority is fixed when it is issued. The roles and grants resolved at
that moment are written into it, so a token keeps asserting them after the
user's permissions change. Two things are re-checked instead of re-resolved: a
refresh fails once the user is deleted or disabled, and an access token is
rejected at authentication when the `token_version` it carries no longer matches
the user's, which is how a credential change invalidates tokens issued before
it.

Tokens are held per subject, not per token. All of a user's tokens in one
authentication realm live in a single `bondy_oauth_token_set` bounded by
`oauth2.max_tokens_per_user`; issuing past that bound evicts the oldest. Within
the set a token is identified by its scope — realm, client and device — so
re-issuing for the same device replaces that device's token rather than adding
one.

Expiry is not enforced by deletion. `is_expired/2` is the single predicate both
`refresh/2` and `cleanup/0` apply, so an expired token stops working at the
moment it expires whether or not anything has swept it yet.

## Storage

Each subject's set is one cell of the durable `bondy_oauth_token` table, banded
by the authentication realm — the realm the user authenticated against, which
for an SSO user is the SSO realm rather than the realm they connected to. The
key is the sha256 of the casefolded username, and the value is the set itself in
a last-writer-wins register.

Because the whole set is one cell, a write is read-modify-write, and two nodes
writing concurrently for one subject resolve last-writer-wins: a token issued on
the losing side is lost and that client re-authenticates. `cleanup/0` therefore
sweeps only the realms this node owns, which makes the sweep single-writer per
realm.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_db_tables.hrl").
-include("bondy_security.hrl").

-define(VERSION, ~"1.1").

-define(NOW, erlang:system_time(second)).
% 0 mins
-define(LEEWAY_SECS, 2 * 0).
-define(IS_GRANT_TYPE(X),
    (X == client_credentials orelse
        X == password orelse
        X == authorization_code)
).
%% TODO not supported yet

%% -define(CODE_GRANT_TTL,
%%     bondy_config:get([oauth2, code_grant_duration])
%% ).
-define(CLIENT_CREDENTIALS_GRANT_TTL,
    bondy_config:get([oauth2, client_credentials_grant_duration])
).
-define(PASSWORD_TOKEN_TTL,
    bondy_config:get([oauth2, password_grant_duration])
).
-define(REFRESH_TOKEN_TTL, bondy_config:get([oauth2, refresh_token_duration])).
-define(MAX_TOKENS, bondy_config:get([oauth2, max_tokens_per_user])).
%% Legacy-backup compatibility (bondy_export legacy import): a refresh token
%% from a legacy backup is a bare opaque string, carrying none of the subject or
%% scope the current self-describing format uses to locate a token. On import a
%% pointer from that string to the imported token's `{key, id}` is stored under
%% a
%% `legacy:`-prefixed key in this same table, never read by the token-set paths.
%% The first refresh presenting the legacy string resolves it through the
%% pointer, issues a current token and clears it, so the string works once.
-define(LEGACY_POINTER, legacy_refresh_pointer).
-define(LEGACY_KEY_PREFIX, "legacy:").

-define(OPTS_VALIDATOR, #{
    expiry_time_secs => #{
        alias => ~"expiry_time_secs",
        key => expiry_time_secs,
        required => false,
        datatype => pos_integer
    },
    allow_sso => #{
        alias => ~"allow_sso",
        key => allow_sso,
        required => true,
        datatype => boolean,
        default => true
    },
    client_id => #{
        alias => ~"client_id",
        key => client_id,
        required => false,
        datatype => binary
    },
    device_id => #{
        alias => ~"device_id",
        key => device_id,
        required => false,
        datatype => binary
    },
    metadata => #{
        alias => ~"metadata",
        key => metadata,
        required => false,
        datatype => map
    }
}).

-type t() :: #{
    type := ?MODULE,
    version := binary(),
    id => binary(),
    token_type := token_type(),
    grant_type := grant_type(),
    refresh_expires_in := pos_integer(),
    access_expires_in := pos_integer(),
    issued_at := pos_integer(),
    issued_on := nodestring(),
    kid := binary(),
    issuer := uri(),
    authrealm := uri(),
    authid := binary(),
    authscope := bondy_auth_scope:t(),
    authroles := [binary()],
    authgrants := map(),
    meta := map(),
    refresh_token := optional(binary()),
    created_at := pos_integer(),
    refreshed_at := pos_integer()
}.
-type token_id() :: binary().
-type opts() :: #{
    client_id => binary(),
    allow_sso => boolean(),
    device_id => binary(),
    expiry_time_secs => pos_integer(),
    metadata => map()
}.
-type token_type() :: access | refresh.
-type grant_type() :: client_credentials | password | authorization_code.
-type issue_error() :: any().

-export_type([t/0]).
-export_type([id/0]).
-export_type([token_id/0]).

-export([cleanup/0]).
-export([issue/3]).
%% Exported for the legacy-backup import translator (bondy_export).
-export([import_legacy/1]).
-export([lookup/2]).
-export([lookup/3]).
-export([refresh/2]).
-export([revoke/1]).
-export([revoke/2]).
-export([revoke_all/1]).
-export([revoke_all/2]).
-export([to_access_token/1]).
-export([to_refresh_token/1]).

-export([id/1]).
-export([authid/1]).
-export([authscope/1]).
-export([is_expired/1]).
-export([is_expired/2]).
-export([expires_at/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Issues a token for the subject `AuthCtxt` authenticated, and stores it.

`GrantType` decides the kind: `password` and `authorization_code` yield a
refresh token, `client_credentials` an access token with no refresh. The scope
follows from `Opts` — `client_id` and `device_id` narrow it, and `allow_sso`
decides whether a token authenticated through an SSO realm is valid across the
realms that realm serves or only the one the session is on.

The user's roles and grants are resolved now and written into the token, so it
carries the authority they had at issue time. Adding a token to a subject's set
can evict its oldest token when `oauth2.max_tokens_per_user` is reached, and
re-issuing within a scope replaces the token already there.
""".
-spec issue(
    GrantType :: grant_type(),
    AuthCtxt :: bondy_auth:context(),
    Opts :: opts()
) ->
    {ok, t()} | {error, issue_error()}.

issue(GrantType, AuthCtxt, Opts0) when ?IS_GRANT_TYPE(GrantType) ->
    %% Realm we are operating in
    RealmUri = bondy_auth:realm_uri(AuthCtxt),
    %% Maybe SSO realm used for auth
    AuthRealmUri = bondy_auth:authrealm(AuthCtxt),
    AuthId = string:casefold(bondy_auth:user_id(AuthCtxt)),
    %% We get roles and grants from the operating Realm
    AuthRoles = bondy_auth:roles(AuthCtxt),
    AuthGrants = [
        bondy_rbac:externalize_grant(X)
     || X <- bondy_rbac:user_grants(RealmUri, AuthId)
    ],
    Issuer = bondy_auth:issuer(AuthCtxt),

    try
        Opts = maps_utils:validate(Opts0, ?OPTS_VALIDATOR),
        Now = ?NOW,

        ClientId = maps:get(client_id, Opts, all),
        %% %% Throw exception if client is requesting a token issued to itself
        %% AuthId =/= ClientId
        %%     orelse GrantType == client_credentials
        %%     orelse throw(invalid_request),

        AuthRealm = bondy_realm:fetch(AuthRealmUri),
        Kid = bondy_realm:get_random_kid(AuthRealm),
        DeviceId = maps:get(device_id, Opts, all),
        ScopeUri =
            case maps:get(allow_sso, Opts) of
                true when AuthRealmUri =/= RealmUri ->
                    %% The token can be used to authenticate on all user realms
                    %% connected to this SSORealmUri
                    all;
                _ ->
                    %% SSORealmUri is all or SSO was not allowed,
                    %% the scope realm can only be the session realm
                    RealmUri
            end,

        AuthScope = bondy_auth_scope:new(ScopeUri, ClientId, DeviceId),
        TokenType = token_type(GrantType),

        {TokenId, RToken} =
            case TokenType of
                access ->
                    {bondy_uuidv7:new(), undefined};
                refresh ->
                    gen_refresh_token(store_key(AuthId))
            end,

        T = #{
            type => ?MODULE,
            version => ?VERSION,
            id => TokenId,
            grant_type => GrantType,
            token_type => TokenType,
            refresh_expires_in => ?REFRESH_TOKEN_TTL,
            access_expires_in => get_access_expires_in(GrantType),
            issued_on => bondy_config:nodestring(),
            issued_at => Now,
            kid => Kid,
            issuer => Issuer,
            authrealm => AuthRealmUri,
            authid => AuthId,
            authscope => AuthScope,
            authroles => AuthRoles,
            authgrants => AuthGrants,
            %% The user's revocation zookie at issue time — the user cell's HLC,
            %% read from the AUTH realm (canonical user record). The auth path
            %% refuses a token whose `tv` is older than the user's current
            %% version, forcing re-auth (STORAGE_ARCHITECTURE §9.3).
            token_version => user_token_version(AuthRealmUri, AuthId),
            meta => maps:get(metadata, Opts, #{}),
            refresh_token => RToken,
            refreshed_at => Now,
            created_at => Now
        },

        ok = add_to_set(T),
        {ok, T}
    catch
        throw:not_found ->
            {error, {no_such_realm, AuthRealmUri}};
        throw:Reason ->
            {error, Reason};
        _:Reason ->
            {error, Reason}
    end.

-doc """
Imports a single refresh token from a legacy backup, reconstructing a current
token for the subject and storing it in the subject's token set, plus a pointer
from the bare legacy refresh-token string to that token so the first refresh that
presents the legacy string resolves (see `refresh/2`).

The user and the auth realm must already exist (users are imported before this
runs; realms are recreated from configuration). `authgrants` are read from the
current RBAC state. Returns `{error, user_not_found}` (skipped) when the subject
was not imported.
""".
-spec import_legacy(Spec :: map()) -> ok | {error, term()}.

import_legacy(#{
    authrealm := AuthRealmUri,
    refresh_token := RefreshToken,
    username := Username,
    client_id := ClientId,
    device_id := DeviceId,
    groups := Groups,
    meta := Meta,
    expires_in := ExpiresIn,
    issued_at := IssuedAt
}) ->
    AuthId = string:casefold(Username),
    try bondy_rbac_user:lookup(AuthRealmUri, AuthId) of
        {error, not_found} ->
            {error, user_not_found};
        {ok, _} ->
            Realm = bondy_realm:fetch(AuthRealmUri),
            Kid = bondy_realm:get_random_kid(Realm),
            TokenId = bondy_uuidv7:format(bondy_uuidv7:new()),
            AuthGrants = [
                bondy_rbac:externalize_grant(X)
             || X <- bondy_rbac:user_grants(AuthRealmUri, AuthId)
            ],
            T = #{
                type => ?MODULE,
                version => ?VERSION,
                id => TokenId,
                grant_type => password,
                token_type => refresh,
                refresh_expires_in => ExpiresIn,
                access_expires_in => get_access_expires_in(password),
                issued_on => bondy_config:nodestring(),
                issued_at => IssuedAt,
                kid => Kid,
                issuer => AuthRealmUri,
                authrealm => AuthRealmUri,
                authid => AuthId,
                authscope => bondy_auth_scope:new(
                    AuthRealmUri, ClientId, DeviceId
                ),
                authroles => Groups,
                authgrants => AuthGrants,
                token_version => user_token_version(AuthRealmUri, AuthId),
                meta => Meta,
                refresh_token => RefreshToken,
                created_at => IssuedAt,
                refreshed_at => IssuedAt
            },
            Table = table(),
            Key = store_key(AuthId),
            Set0 = fetch_set(Table, AuthRealmUri, Key),
            Set1 = bondy_oauth_token_set:add(Set0, T),
            {_Truncated, Set} = bondy_oauth_token_set:truncate(
                Set1, ?MAX_TOKENS
            ),
            ok = bondy_db:apply(Table, AuthRealmUri, Key, {set, Set}),
            ok = write_legacy_pointer(AuthRealmUri, RefreshToken, Key, TokenId),
            ok
    catch
        throw:not_found ->
            {error, no_such_realm};
        Class:Reason ->
            {error, {Class, Reason}}
    end.

-doc """
Exchanges `RefreshToken` for a fresh token, and returns it.

The presented refresh token stops working: a refresh rotates it, so a token
replayed after a successful refresh is refused. The user is re-checked — a
refresh fails once they are deleted or disabled — while the roles and grants of
the new token are carried over from the old one rather than re-resolved.

Answers `{error, oauth2_invalid_grant}` for a token that is unknown, expired,
already rotated, or whose user is gone. The reason is deliberately the same in
every case, so a caller cannot use the error to distinguish them.
""".
-spec refresh(Realm :: bondy_realm:uri(), RefreshToken :: binary()) ->
    {ok, t()} | {error, oauth2_invalid_grant}.

refresh(RealmUri, RefreshToken) when
    is_binary(RealmUri) andalso is_binary(RefreshToken)
->
    maybe
        {ok, AuthRealmUri} ?= get_authrealm_uri(RealmUri),
        {ok, {Components, IsLegacy}} ?=
            resolve_components(AuthRealmUri, RefreshToken),
        {ok, {T, Set}} ?= find_in_set(AuthRealmUri, Components),
        ok ?= check_expired(T),
        {ok, _} ?= check_authid(T, AuthRealmUri),
        {ok, NewT} ?= do_refresh(T, Set),
        %% A legacy token works exactly once: clear its pointer now that the
        %% client has received a current-format token.
        ok = maybe_clear_legacy(IsLegacy, AuthRealmUri, RefreshToken),
        {ok, NewT}
    else
        {error, user_not_found} ->
            %% We do not remove tokens, as this should have been done by
            %% bondy_rbac_user
            {error, oauth2_invalid_grant};
        {error, not_found} ->
            {error, oauth2_invalid_grant};
        {error, _} = Error ->
            Error
    end.

-doc """
Returns the stored token that `RefreshToken` identifies in `RealmUri`, without
redeeming it.

Reads storage only: it neither rotates the token nor checks that the user still
exists, so a caller needing a usable token wants `refresh/2`.
""".
-spec lookup(RealmUri :: uri(), RefreshToken :: binary()) ->
    {ok, Token :: t()} | {error, no_found | oauth2_invalid_grant}.

lookup(RealmUri, RefreshToken) when is_binary(RefreshToken) ->
    maybe
        {ok, AuthRealmUri} ?= get_authrealm_uri(RealmUri),
        {ok, {Components, _IsLegacy}} ?=
            resolve_components(AuthRealmUri, RefreshToken),
        {ok, {T, _Set}} ?= find_in_set(AuthRealmUri, Components),
        {ok, T}
    else
        {error, _} = Error ->
            Error
    end.

-doc """
Returns the token stored for `AuthId` under `Scope` in `RealmUri`, without
redeeming it.

Addresses a token by who holds it and in what scope, rather than by the string a
client presents.
""".
-spec lookup(
    RealmUri :: uri(),
    AuthId :: bondy_rbac_user:username(),
    Scope :: bondy_auth_scope:t()
) ->
    {ok, Token :: t()} | {error, no_found | oauth2_invalid_grant}.

lookup(RealmUri, AuthId, Scope) when is_map(Scope) ->
    maybe
        {ok, AuthRealmUri} ?= get_authrealm_uri(RealmUri),
        {ok, {T, _}} ?= find_in_set(AuthRealmUri, AuthId, Scope),
        {ok, T}
    else
        {error, not_found} ->
            {error, oauth2_invalid_grant};
        {error, _} = Error ->
            Error
    end.

-doc """
Revokes token `T`, removing it from the set stored for its subject.

Revocation is per token, not per subject: the subject's other tokens — issued
under different scopes — keep working. The refresh token cannot be redeemed
afterwards; access tokens already minted from it remain valid until they expire,
which is the trade the short access-token lifetime pays for.
""".
-spec revoke(t()) -> ok.

revoke(#{type := ?MODULE} = T) ->
    #{authrealm := AuthRealmUri, authid := AuthId, authscope := AuthScope} = T,

    maybe
        {ok, {T, Set}} ?= find_in_set(AuthRealmUri, AuthId, AuthScope),
        do_revoke(T, Set)
    else
        {error, user_not_found} ->
            %% We do not remove tokens, as this should have been done by
            %% bondy_rbac_user
            ok;
        {error, not_found} ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Error while revoking token",
                reason => Reason
            }),
            ok
    end.

-doc """
Revokes a token of `RealmUri`, given either the token or the refresh-token
string a client presented.

Answers `ok` whether or not the token existed. RFC 7009 requires this: an
invalid token is not an error, because the caller's goal — that the token no
longer work — already holds, and reporting otherwise would make the endpoint an
oracle for guessing valid tokens.
""".
-spec revoke(RealmUri :: binary(), t() | binary()) -> ok.

revoke(RealmUri, RefreshToken) when is_binary(RefreshToken) ->
    maybe
        {ok, AuthRealmUri} ?= get_authrealm_uri(RealmUri),
        {ok, {Components, IsLegacy}} ?=
            resolve_components(AuthRealmUri, RefreshToken),
        {ok, {T, Set}} ?= find_in_set(AuthRealmUri, Components),
        ok ?= do_revoke(T, Set),
        ok = maybe_clear_legacy(IsLegacy, AuthRealmUri, RefreshToken),
        ok
    else
        {error, user_not_found} ->
            %% We do not remove tokens, as this should have been done by
            %% bondy_rbac_user
            ok;
        {error, not_found} ->
            ok;
        {error, invalid_token} ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Error while revoking token",
                reason => Reason
            }),
            ok
    end.

-doc """
Revokes every token that is valid on realm `RealmUri`.

Tokens are bucketed by the AUTH realm, so a member realm's tokens sit in its SSO
realm's bucket together with every SIBLING realm's. Clearing that bucket
wholesale would revoke the siblings' users too, so the two buckets are treated
differently:

- **`RealmUri`'s own bucket** holds tokens issued by sessions that authenticated
  against it (its local, non-SSO users). Those users go with the realm, so it is
  cleared wholesale.
- **Every other auth realm** is a shared SSO bucket. Only tokens whose
  `authscope` names `RealmUri` are removed; a token scoped to `all` is kept,
  since it still grants the realms its user can reach.

The auth realm is deliberately NOT resolved from `RealmUri`:
`bondy_realm:delete/2` clears the realm record before running this, so there
would be nothing to resolve — and the previous implementation, which did
resolve it, therefore silently revoked NOTHING on that path. Every surviving
auth realm is scanned instead. O(realms), on a cold one-off path.
""".
-spec revoke_all(RealmUri :: uri()) -> ok.

revoke_all(RealmUri) when is_binary(RealmUri) ->
    try
        Table = table(),
        Buckets = lists:usort([RealmUri | bondy_realm:auth_realm_uris()]),
        _ = [revoke_all_in(Table, Bucket, RealmUri) || Bucket <- Buckets],
        ok
    catch
        _:Reason ->
            Job = {?MODULE, revoke_all, [RealmUri]},
            enqueue(Job, #{
                description => "Failed to revoke tokens. Enqueued for retry.",
                reason => Reason
            })
    end.

-doc """
Revokes all tokens issued to user with `Username` in realm `RealmUri`.
""".
-spec revoke_all(RealmUri :: uri(), AuthId :: bondy_rbac_user:username()) ->
    ok.

revoke_all(RealmUri, AuthId) ->
    try
        case get_authrealm_uri(RealmUri) of
            {ok, AuthRealmUri} ->
                Key = store_key(AuthId),
                bondy_db:apply(table(), AuthRealmUri, Key, clear);
            {error, _} ->
                ok
        end
    catch
        _:Reason ->
            Job = {?MODULE, revoke_all, [RealmUri, AuthId]},
            enqueue(Job, #{
                description => "Failed to revoke tokens. Enqueued for retry.",
                reason => Reason
            })
    end.

-doc """
Returns the signed access-token JWT for `T`, and the seconds it remains valid.

Each call mints a new JWT with a fresh id, signed with the realm key named by
the token's `kid`. Rotating that key out of the realm makes tokens signed with
it unverifiable. Raises when the realm or the key is gone.
""".
-spec to_access_token(t()) ->
    {ok, {JWT :: binary(), ExpiresIn :: pos_integer()}}.

to_access_token(#{type := ?MODULE, authrealm := RealmUri, kid := Kid} = T0) ->
    Realm = bondy_realm:fetch(RealmUri),
    PrivKey = bondy_realm:get_private_key(Realm, Kid),
    T = T0#{id => bondy_uuidv7:format(bondy_uuidv7:new())},
    to_access_token(T, PrivKey).

-doc """
Returns the opaque refresh-token string for `T` — what a client stores and later
presents to `refresh/2`.

Raises when `T` carries no refresh token, which is the case for a token issued
under the `client_credentials` grant.
""".
-spec to_refresh_token(t()) -> binary() | no_return().

to_refresh_token(#{type := ?MODULE, refresh_token := undefined}) ->
    error(bardag);
to_refresh_token(#{type := ?MODULE, refresh_token := Val}) ->
    Val.

-doc """
Reclaims token cells that can no longer authenticate anyone, across the realms
THIS NODE OWNS, and returns what it did.

Three things are dropped:

- **expired** tokens, via `bondy_oauth_token_set:cleanup/2` — the same
  predicate `refresh/2` rejects on, so storage and authentication agree on
  exactly which tokens exist;
- tokens whose user is **gone or disabled**, matching what `refresh/2`
  enforces through `check_authid/2` plus the `is_enabled` check auth applies;
- **empty cells**, cleared rather than written back as an empty set.

This is a cold task, not something on any request path. `bondy_reclaimer` runs
it on an interval; it is also safe to call by hand.

> #### Ownership is a safety property, not an optimisation {: .warning}
>
> A cell is read, filtered and written back, and the store is last-write-wins.
> If two nodes swept the same realm concurrently, one could write back a set it
> read before the other's clear and RESURRECT reclaimed tokens. Restricting each
> node to the realms it owns (`bondy:is_owner/1`) makes the sweep single-writer
> per realm, which removes that hazard — so the filter is applied here rather
> than left to the caller, and there is deliberately no "sweep everything"
> variant.
>
> The remaining, unavoidable race is with live issuance on the SAME node: a
> token issued between this read and its write is lost, and that user
> re-authenticates. Mitigated by writing ONLY when something was actually
> removed.
""".
-spec cleanup() -> map().

cleanup() ->
    Now = ?NOW,
    Stats0 = #{
        errors => [],
        scanned => 0,
        expired => 0,
        deactivated => 0,
        cells_cleared => 0
    },
    Stats = lists:foldl(
        fun(AuthRealmUri, Acc) -> cleanup_realm(AuthRealmUri, Now, Acc) end,
        Stats0,
        owned_auth_realm_uris()
    ),
    ?LOG_INFO(#{
        description => "Finished cleaning up OAuth2 tokens",
        stats => Stats
    }),
    Stats.

-doc "Returns the token's unique identifier.".
id(#{type := ?MODULE, id := Val}) ->
    Val.

-doc "Returns the username the token was issued to.".
authid(#{type := ?MODULE, authid := Val}) ->
    Val.

-doc """
Returns the token's scope: the realm, client and device it is valid for. Two
tokens of the same subject with different scopes coexist; re-issuing within one
scope replaces the token already there.
""".
authscope(#{type := ?MODULE, authscope := Val}) ->
    Val.

-doc """
Whether the token's refresh lifetime has elapsed. This is the predicate
`refresh/2` rejects on and the one reclamation deletes on, so storage and
authentication agree on which tokens exist.
""".
is_expired(#{type := ?MODULE} = T) ->
    is_expired(T, ?NOW).

-doc """
Whether the token has expired as of `Now`, a POSIX timestamp in seconds.

A small leeway is allowed past `expires_at/1` so that clock skew between nodes
does not reject a token one node still considers live.
""".
is_expired(#{type := ?MODULE} = T, Now) ->
    expires_at(T) + ?LEEWAY_SECS =< Now.

-doc """
Returns the POSIX second at which the token's refresh lifetime ends.
`is_expired/2`
allows a leeway past this instant.
""".
expires_at(#{type := ?MODULE, issued_at := Ts, refresh_expires_in := Exp}) ->
    Ts + Exp.

%% =============================================================================
%% PRIVATE
%% =============================================================================

-spec get_authrealm_uri(uri()) -> {ok, uri()} | {error, not_found}.

get_authrealm_uri(RealmUri) ->
    Result = bondy_realm:lookup(RealmUri),
    resulto:then(Result, fun(Realm) ->
        Uri = bondy_stdlib:or_else(bondy_realm:sso_realm_uri(Realm), RealmUri),
        {ok, Uri}
    end).

get_access_expires_in(client_credentials) ->
    ?CLIENT_CREDENTIALS_GRANT_TTL;
get_access_expires_in(password) ->
    ?PASSWORD_TOKEN_TTL;
%% get_access_expires_in(application_code) ->
%%     refresh;

get_access_expires_in(Grant) ->
    throw({oauth2_unsupported_grant_type, Grant}).

%% @private
token_type(client_credentials) ->
    access;
token_type(application_code) ->
    refresh;
token_type(password) ->
    refresh;
token_type(Grant) ->
    throw({oauth2_unsupported_grant_type, Grant}).

%% @private
to_access_token(#{type := ?MODULE, access_expires_in := Exp} = T, PrivKey) ->
    JWT = bondy_oauth_jwt:encode(to_jwt_claims(T), PrivKey),
    {ok, {JWT, Exp}}.

%% @private
to_jwt_claims(#{type := ?MODULE, version := ~"1.1" = Vsn} = T) ->
    #{
        id := Id,
        access_expires_in := ExpiresIn,
        issued_at := IssuedAt,
        issued_on := IssuedOn,
        kid := Kid,
        issuer := Issuer,
        authrealm := AuthRealmUri,
        authid := AuthId,
        authscope := Authscope,
        authroles := AuthRoles,
        authgrants := AuthGrants,
        meta := Meta
    } = T,
    %% Defaulted for tokens minted before `token_version` existed (a stored
    %% refresh token re-minting an access token); 0 is the pre-history sentinel.
    TokenVersion = maps:get(token_version, T, 0),
    #{
        ~"id" => Id,
        ~"vsn" => Vsn,
        ~"exp" => ExpiresIn,
        ~"iat" => IssuedAt,
        ~"ion" => IssuedOn,
        ~"kid" => Kid,
        ~"iss" => Issuer,
        ~"aud" => AuthRealmUri,
        ~"sub" => AuthId,
        ~"tv" => TokenVersion,
        ~"auth" => #{
            ~"scope" => Authscope,
            ~"roles" => AuthRoles,
            ~"grants" => AuthGrants
        },
        ~"meta" => Meta,
        %% To be deprecated (included in auth map)
        ~"groups" => AuthRoles
    }.

%% @private
%% The user's current `token_version` (the user cell's HLC) at issue time, read
%% from the AUTH realm — the canonical user record (the SSO realm for SSO users,
%% the operating realm for local users). A missing user (it should exist — they
%% just authenticated) defaults to 0, guaranteeing a later mismatch and a
%% fail-closed re-auth. Bondy's revocation zookie (STORAGE_ARCHITECTURE §9.3).
user_token_version(RealmUri, AuthId) ->
    case bondy_rbac_user:token_version(RealmUri, AuthId) of
        {ok, V} -> V;
        {error, not_found} -> 0
    end.

%% @private
store_key(AuthId) ->
    base16:encode(crypto:hash(sha256, string:casefold(AuthId))).

%% @private
%% The open bondy_db `bondy_oauth_token` table handle. Raises if the catalogue
%% has not provisioned it — the table is a hard dependency (the catalogue, a
%% `bondy_sup` child, opens it at boot, well before any auth flow issues or
%% revokes a token).
table() ->
    case bondy_namespace_catalog:table(?BONDY_DB_OAUTH_TOKEN_TAB) of
        undefined -> error(oauth_token_table_unavailable);
        Table -> Table
    end.

%% @private
%% The user's current token set, or a fresh empty one when absent / cleared.
fetch_set(Table, RealmUri, Key) ->
    case bondy_db:read(Table, RealmUri, Key) of
        {ok, {Set, _Hlc}} -> Set;
        {error, not_found} -> bondy_oauth_token_set:new()
    end.

%% @private
add_to_set(#{type := ?MODULE} = T) ->
    #{type := ?MODULE, authrealm := AuthRealmUri, authid := AuthId} = T,
    Table = table(),
    Key = store_key(AuthId),

    try
        %% We have to update the set, so first we fetch it.
        Set0 = fetch_set(Table, AuthRealmUri, Key),
        Set1 = bondy_oauth_token_set:add(Set0, T),
        {_Truncated, Set} = bondy_oauth_token_set:truncate(Set1, ?MAX_TOKENS),
        ok = bondy_db:apply(Table, AuthRealmUri, Key, {set, Set})
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while writing token to store",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            throw(database_error)
    end.

%% @private
-spec find_in_set(uri(), bondy_oauth_refresh_token:components()) ->
    {ok, {t(), bondy_oauth_token_set:t()}} | {error, any()}.

find_in_set(RealmUri, #{key := Key, id := TokenId}) ->
    case bondy_db:read(table(), RealmUri, Key) of
        {error, not_found} ->
            {error, not_found};
        {ok, {Set, _Hlc}} when is_map(Set) ->
            Result = bondy_oauth_token_set:find(Set, TokenId),
            resulto:map(Result, fun(Token) -> {Token, Set} end)
    end.

%% @private
-spec find_in_set(uri(), binary(), bondy_auth_scope:t()) ->
    {ok, {t(), bondy_oauth_token_set:t()}} | {error, any()}.

find_in_set(RealmUri, AuthId, Scope) ->
    find_in_set(RealmUri, AuthId, Scope, undefined).

%% @private
-spec find_in_set(uri(), binary(), bondy_auth_scope:t(), token_id()) ->
    {ok, {t(), bondy_oauth_token_set:t()}} | {error, any()}.

find_in_set(RealmUri, AuthId, Scope, TokenId) ->
    Key = store_key(AuthId),

    case bondy_db:read(table(), RealmUri, Key) of
        {error, not_found} ->
            {error, not_found};
        {ok, {Set, _Hlc}} when TokenId == undefined ->
            Result = bondy_oauth_token_set:find(Set, Scope),
            resulto:map(Result, fun(Token) -> {Token, Set} end);
        {ok, {Set, _Hlc}} ->
            Result = bondy_oauth_token_set:find(Set, Scope, TokenId),
            resulto:map(Result, fun(Token) -> {Token, Set} end)
    end.

%% @private
check_expired(#{type := ?MODULE} = T) ->
    case is_expired(T) of
        true ->
            {error, oauth2_invalid_grant};
        false ->
            ok
    end.

%% @private
%% A token can outlive the user it names — an import, a peer's merge, a partly
%% applied teardown — so this returns the error for `refresh/2` to map to
%% `oauth2_invalid_grant` rather than matching on success.
check_authid(#{authid := AuthId}, RealmUri) ->
    resulto:map_error(
        bondy_rbac_user:lookup(RealmUri, AuthId),
        fun
            (not_found) ->
                user_not_found;
            (Other) ->
                Other
        end
    );
check_authid(_, _) ->
    {error, oauth2_invalid_grant}.

%% @private
do_refresh(#{type := ?MODULE} = T0, Set0) ->
    Now = ?NOW,
    #{
        id := TokenId0,
        authrealm := AuthRealmUri,
        authid := AuthId,
        authscope := Scope
    } = T0,

    Key = store_key(AuthId),

    try
        {TokenId, RefreshToken} = gen_refresh_token(Key),

        T = T0#{
            id => TokenId,
            refreshed_at => Now,
            issued_at => Now,
            issued_on => bondy_config:nodestring(),
            refresh_expires_in => ?REFRESH_TOKEN_TTL,
            refresh_token => RefreshToken
        },

        Set1 = bondy_oauth_token_set:remove(Set0, Scope, TokenId0),
        Set2 = bondy_oauth_token_set:add(Set1, T),
        {_Removed, Set} = bondy_oauth_token_set:cleanup_and_truncate(
            Set2, ?MAX_TOKENS, Now
        ),
        ok = bondy_db:apply(table(), AuthRealmUri, Key, {set, Set}),
        {ok, T}
    catch
        throw:not_found ->
            {error, {no_such_realm, AuthRealmUri}};
        throw:Reason ->
            {error, Reason};
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while writing token to store",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            throw(database_error)
    end.

%% @private
do_revoke(#{type := ?MODULE} = T0, Set0) ->
    Now = ?NOW,
    #{
        id := TokenId0,
        authrealm := AuthRealmUri,
        authid := AuthId,
        authscope := Scope
    } = T0,

    Key = store_key(AuthId),

    try
        Set1 = bondy_oauth_token_set:remove(Set0, Scope, TokenId0),
        {_Removed, Set} = bondy_oauth_token_set:cleanup_and_truncate(
            Set1, ?MAX_TOKENS, Now
        ),
        ok = bondy_db:apply(table(), AuthRealmUri, Key, {set, Set}),
        ok
    catch
        throw:not_found ->
            {error, {no_such_realm, AuthRealmUri}};
        throw:Reason ->
            {error, Reason};
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while writing token to store",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            throw(database_error)
    end.

enqueue(Job, Report) ->
    Q = high_priority,

    case bondy_reliable:enqueue(Q, Job) of
        {ok, Id} ->
            ?LOG_NOTICE(Report#{
                queue => Q,
                queue_id => Id
            });
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Failed to enqueued reliable job.",
                reason => Reason,
                queue => Q
            })
    end.

%% =============================================================================
%% PRIVATE: REFRESH TOKEN HELPERS
%% =============================================================================

%% @private
gen_refresh_token(Key) ->
    bondy_oauth_refresh_token:new(Key).

%% @private
%% Resolves a presented refresh token to the `{key, id}` components used to find
%% it in the subject's set. A current token self-describes (it parses); a legacy
%% (imported) token is a bare string resolved through its pointer. The boolean
%% flags whether the resolution was legacy, so the caller can clear the pointer
%% on a successful refresh / revoke.
resolve_components(AuthRealmUri, RefreshToken) ->
    case bondy_oauth_refresh_token:parse(RefreshToken) of
        {ok, Components} ->
            {ok, {Components, false}};
        {error, _} ->
            case read_legacy_pointer(AuthRealmUri, RefreshToken) of
                {ok, Components} ->
                    {ok, {Components, true}};
                error ->
                    {error, invalid_token}
            end
    end.

%% @private
legacy_key(RefreshToken) ->
    <<?LEGACY_KEY_PREFIX, RefreshToken/binary>>.

%% @private
write_legacy_pointer(AuthRealmUri, RefreshToken, StoreKey, TokenId) ->
    Pointer = #{type => ?LEGACY_POINTER, key => StoreKey, id => TokenId},
    bondy_db:apply(
        table(), AuthRealmUri, legacy_key(RefreshToken), {set, Pointer}
    ).

%% @private
read_legacy_pointer(AuthRealmUri, RefreshToken) ->
    case bondy_db:read(table(), AuthRealmUri, legacy_key(RefreshToken)) of
        {ok, {#{type := ?LEGACY_POINTER, key := Key, id := Id}, _Hlc}} ->
            {ok, #{key => Key, id => Id}};
        _ ->
            error
    end.

%% @private
maybe_clear_legacy(false, _AuthRealmUri, _RefreshToken) ->
    ok;
maybe_clear_legacy(true, AuthRealmUri, RefreshToken) ->
    bondy_db:apply(table(), AuthRealmUri, legacy_key(RefreshToken), clear).

%% @private
%% The realm's OWN bucket: everything in it was issued by a session that
%% authenticated against this realm, and those users go with it.
revoke_all_in(Table, RealmUri, RealmUri) ->
    {ok, Rows} = bondy_db:list(Table, RealmUri),
    _ = [
        bondy_db:apply(Table, RealmUri, Key, clear)
     || {Key, _V, _Hlc} <- Rows
    ],
    ok;
%% Any OTHER bucket is an SSO realm shared with sibling member realms, so only
%% the tokens scoped to `ScopeRealmUri` may go.
revoke_all_in(Table, Bucket, ScopeRealmUri) ->
    {ok, Rows} = bondy_db:list(Table, Bucket),
    _ = [revoke_scoped(Table, Bucket, Row, ScopeRealmUri) || Row <- Rows],
    ok.

%% @private
revoke_scoped(
    Table,
    Bucket,
    {Key, #{type := bondy_oauth_token_set} = Set0, _Hlc},
    ScopeRealmUri
) ->
    case bondy_oauth_token_set:remove_realm(Set0, ScopeRealmUri) of
        {[], _Set} ->
            %% Nothing matched: never rewrite a cell we did not change.
            ok;
        {_Removed, Set} ->
            case bondy_oauth_token_set:size(Set) of
                0 -> bondy_db:apply(Table, Bucket, Key, clear);
                _ -> bondy_db:apply(Table, Bucket, Key, {set, Set})
            end
    end;
revoke_scoped(_Table, _Bucket, _Row, _ScopeRealmUri) ->
    %% A legacy refresh pointer carries no scope, so there is nothing to match
    %% it on. One left dangling fails CLOSED: `refresh/2` resolves the pointer,
    %% finds no token behind it, and errors.
    ok.

%% @private
%% The token buckets THIS node owns. `bondy_realm:auth_realm_uris/0` has already
%% collapsed each SSO realm's members onto one bucket, so filtering its result
%% decides ownership of the bucket — which is the only correct grain (see that
%% function).
owned_auth_realm_uris() ->
    lists:filter(fun bondy:is_owner/1, bondy_realm:auth_realm_uris()).

%% @private
%% One realm's cells. A failure here is recorded and the sweep CONTINUES: a
%% single unreadable realm must not abandon every other realm's reclamation.
cleanup_realm(AuthRealmUri, Now, Stats0) ->
    Table = table(),

    try bondy_db:list(Table, AuthRealmUri) of
        {ok, Rows} ->
            lists:foldl(
                fun(Row, Acc) ->
                    cleanup_cell(Table, AuthRealmUri, Row, Now, Acc)
                end,
                Stats0,
                Rows
            );
        {error, Reason} ->
            add_error(Stats0, AuthRealmUri, Reason)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description => "Error while cleaning up OAuth2 tokens",
                realm_uri => AuthRealmUri,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            add_error(Stats0, AuthRealmUri, Reason)
    end.

%% @private
%% A legacy refresh pointer is not a token set — it is a one-shot indirection
%% keyed under a `legacy:` prefix. Its lifetime is owned by `refresh/2`, which
%% clears it the first time the legacy string is redeemed, so leave it alone.
cleanup_cell(_, _, {_Key, #{type := ?LEGACY_POINTER}, _Hlc}, _Now, Stats) ->
    Stats;
cleanup_cell(
    Table,
    AuthRealmUri,
    {Key, #{type := bondy_oauth_token_set} = Set0, _Hlc},
    Now,
    Stats0
) ->
    Stats1 = bump(Stats0, scanned, 1),
    {Expired, Set} = bondy_oauth_token_set:cleanup(Set0, Now),
    Stats2 = bump(Stats1, expired, length(Expired)),

    case bondy_oauth_token_set:to_list(Set) of
        [] ->
            %% Nothing survived (or the cell was already empty) — drop it
            %% rather than write an empty set back.
            ok = bondy_db:apply(Table, AuthRealmUri, Key, clear),
            bump(Stats2, cells_cleared, 1);
        [#{authid := AuthId} | _] = Live ->
            %% `store_key/1` hashes the authid, so a cell holds exactly ONE
            %% user's tokens — the user is resolved once per cell, not once
            %% per token.
            case is_user_active(AuthRealmUri, AuthId) of
                false ->
                    ok = bondy_db:apply(Table, AuthRealmUri, Key, clear),
                    Stats3 = bump(Stats2, deactivated, length(Live)),
                    bump(Stats3, cells_cleared, 1);
                true when Expired =/= [] ->
                    ok = bondy_db:apply(
                        Table, AuthRealmUri, Key, {set, Set}
                    ),
                    Stats2;
                true ->
                    %% Untouched: do not rewrite a cell we did not change, so
                    %% a concurrent issue/refresh cannot be clobbered.
                    Stats2
            end
    end;
cleanup_cell(_, _, _Row, _Now, Stats) ->
    Stats.

%% @private
%% A token authenticates only while its user both exists and is enabled — the
%% pair `refresh/2` enforces via `check_authid/2` and auth applies on session
%% establishment. A user that cannot be resolved is treated as gone.
is_user_active(AuthRealmUri, AuthId) ->
    case bondy_rbac_user:lookup(AuthRealmUri, AuthId) of
        {ok, User} -> bondy_rbac_user:is_enabled(User);
        {error, _} -> false
    end.

%% @private
bump(Stats, Key, 0) when is_map(Stats), is_atom(Key) ->
    Stats;
bump(Stats, Key, N) ->
    maps:update_with(Key, fun(V) -> V + N end, N, Stats).

%% @private
add_error(#{errors := Errors} = Stats, AuthRealmUri, Reason) ->
    Stats#{errors := [{AuthRealmUri, Reason} | Errors]}.
