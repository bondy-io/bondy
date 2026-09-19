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

A token is identified by its subject and its scope — realm, client and device
— so re-issuing for the same device replaces that device's token rather than
adding one, and a user holds at most `oauth2.max_tokens_per_user` tokens across
their scopes; issuing past that bound evicts the soonest-expiring.

Expiry is not enforced by deletion. `is_expired/2` is the single predicate both
`refresh/2` and `cleanup/0` apply, so an expired token stops working at the
moment it expires whether or not anything has swept it yet.

## Storage

Every token is its own cell of the durable `bondy_oauth_token` table, banded by
the authentication realm — the realm the user authenticated against, which for
an SSO user is the SSO realm rather than the realm they connected to. The key is
the order-preserving composite `[UserHash, Realm, ClientId, DeviceId]`
(`cell_key/2`; `UserHash` is the sha256 of the casefolded username), the value
the token in a last-writer-wins register. A user's tokens are therefore one
contiguous band of the table, co-located on the user's shard by the table's
`leading_col` aggregate root, and the refresh-token string a client holds
carries its cell key, so redeeming it is one point read.

Every write is a single cell: an issue or a refresh sets its own cell, a
revocation clears it, and nothing reads a set to write it back. Two nodes — or
two requests on one node — issuing different scopes for one user cannot lose
each other's token, and a `revoke_all/2` that interleaves with an issue clears
the tokens it found and nothing revoked comes back; the one token issued
concurrently may survive it. Concurrent writes to the SAME cell (two refreshes of
one string, a refresh against a revocation) resolve last-writer-wins by HLC, and
the loser's client re-authenticates. `bondy_oauth_token_concurrency_SUITE`
exercises the first two; `prop_bondy_oauth_token_bound` holds the bound.

## The bound

`oauth2.max_tokens_per_user` is enforced by two evictors applying one rule — drop
the first cells of the user's band in eviction order until `MAX` remain: the
issuer, on its own band right after its write, and `cleanup/0`, the single
writer per owned realm. The order is `(expires_at, write HLC, key)`: soonest-
expiring first, and among tokens expiring in the same second — every token
issued within one second, at the default TTL — the one written EARLIEST. The
HLC is the cell's, stamped by the store on the write (`bondy_oplog_hlc`:
milliseconds plus a logical counter, comparable across nodes), so "new replaces
old" holds at write resolution: an issue can evict any token but the one it
just wrote, and a refresh, being a write, makes its token the newest.
`bondy_oauth_token_store_SUITE` holds this with `MAX + 3` issues in one
second; the token id, which an earlier cut used, is not ordered by time.

Both evictors work from a snapshot that a concurrent issue may already have
outdated, so the bound is eventual: it holds once the band is quiescent and
one `cleanup/0` pass has run. No evictor can evict one of the last `MAX` cells
of the band in that order, whatever snapshot it holds, because evicting cell
`c` needs at least `MAX` cells above `c` in the snapshot, and a snapshot
contains only cells that exist — so concurrent issues never drive the band
below `MAX`, and never lose a token to anything but the bound.

`cleanup/0` sweeps only the realms this node owns, which keeps eviction
single-writer per realm across the cluster.

## Failure reporting

A write the store refuses — the shard's overlay is full, the apply barrier timed
out, the instance is restarting — is an availability condition of this node, not
a fault of the request. Every write path reports it as `service_unavailable`, a
transient the client may retry after a short delay (503 over HTTP), and logs it
once without a stacktrace. A fault while preparing a write is a `database_error`
and keeps its stacktrace.
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
%% pointer from that string to the imported token's `{key, id}` — its cell key
%% and id — is stored in this same table under the composite key
%% `[?LEGACY_COL, LegacyString]` (`legacy_key/1`). Every key of the table is
%% such a composite: the codec keeps the columns free of the separator byte,
%% which the table's `leading_col` routing decodes — a raw client string
%% carrying a `0` would otherwise be decoded as a column and crash the read
%% (`bondy_oauth2_transient_error_SUITE`). The `legacy` column is never a
%% user's hash, so a pointer falls in no user's band.
%% The first refresh presenting the legacy string resolves it through the
%% pointer, issues a current token and clears it, so the string works once.
-define(LEGACY_POINTER, legacy_refresh_pointer).
-define(LEGACY_COL, <<"legacy">>).

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
        datatype => binary,
        validator => fun bondy_data_validators:device_id/1
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
carries the authority they had at issue time. Re-issuing within a scope replaces
the token already there, and once the token is stored the subject's band is
trimmed to `oauth2.max_tokens_per_user`, evicting the soonest-expiring (see "The
bound" above).
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
        Key = cell_key(AuthId, AuthScope),

        {TokenId, RToken} =
            case TokenType of
                access ->
                    {bondy_uuidv7:new(), undefined};
                refresh ->
                    gen_refresh_token(Key)
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

        ok = store(Key, T),
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
token for the subject and storing it in its own cell, plus a pointer from the
bare legacy refresh-token string to that cell so the first refresh that presents
the legacy string resolves (see `refresh/2`).

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
            Key = cell_key(T),
            ok = store(Key, T),
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
        {ok, T} ?= find(AuthRealmUri, Components),
        ok ?= check_expired(T),
        {ok, _} ?= check_authid(T, AuthRealmUri),
        {ok, NewT} ?= do_refresh(T),
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
        {error, invalid_token} ->
            %% A string this module never minted is answered like a token it
            %% no longer holds — the doc's promise above.
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
        find(AuthRealmUri, Components)
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
        {ok, T} ?= read_cell(AuthRealmUri, cell_key(AuthId, Scope)),
        {ok, T}
    else
        {error, not_found} ->
            {error, oauth2_invalid_grant};
        {error, _} = Error ->
            Error
    end.

-doc """
Revokes token `T`, clearing its cell.

Revocation is per token, not per subject: the subject's other tokens — issued
under different scopes — keep working. The refresh token cannot be redeemed
afterwards; access tokens already minted from it remain valid until they expire,
which is the trade the short access-token lifetime pays for. A `T` that has
already been rotated or replaced is not the token in its cell, and is left
alone.
""".
-spec revoke(t()) -> ok.

revoke(#{type := ?MODULE, id := Id} = T) ->
    #{authrealm := AuthRealmUri} = T,

    case find(AuthRealmUri, #{key => cell_key(T), id => Id}) of
        {ok, T} ->
            _ = do_revoke(T),
            ok;
        {ok, _Other} ->
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

The one answer that is not `ok` is `{error, service_unavailable}`: the store
refused the write, so the token still exists. RFC 7009 §2.2.1 reserves a 503
for exactly this, so the client knows to retry rather than assume revocation.
""".
-spec revoke(RealmUri :: binary(), t() | binary()) ->
    ok | {error, service_unavailable}.

revoke(RealmUri, RefreshToken) when is_binary(RefreshToken) ->
    maybe
        {ok, AuthRealmUri} ?= get_authrealm_uri(RealmUri),
        {ok, {Components, IsLegacy}} ?=
            resolve_components(AuthRealmUri, RefreshToken),
        {ok, T} ?= find(AuthRealmUri, Components),
        ok ?= do_revoke(T),
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
        {error, service_unavailable} = Error ->
            Error;
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
Revokes all tokens issued to user with `Username` in realm `RealmUri`: every
cell of the user's band is cleared. A token issued concurrently, after the band
was read, may survive; nothing cleared here comes back.
""".
-spec revoke_all(RealmUri :: uri(), AuthId :: bondy_rbac_user:username()) ->
    ok.

revoke_all(RealmUri, AuthId) ->
    try
        case get_authrealm_uri(RealmUri) of
            {ok, AuthRealmUri} ->
                Table = table(),
                {ok, Keys} = fold_user(
                    Table,
                    AuthRealmUri,
                    AuthId,
                    fun({Key, _T, _Hlc}, Acc) -> [Key | Acc] end,
                    []
                ),
                _ = [
                    ok = bondy_db:apply(Table, AuthRealmUri, K, clear)
                 || K <- Keys
                ],
                ok;
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
    error(badarg);
to_refresh_token(#{type := ?MODULE, refresh_token := Val}) ->
    Val.

-doc """
Reclaims token cells that can no longer authenticate anyone, across the realms
THIS NODE OWNS, enforces the per-user bound, and returns what it did.

Three things are cleared:

- **expired** tokens — on the same `is_expired/2` `refresh/2` rejects on, so
  storage and authentication agree on exactly which tokens exist;
- tokens whose user is **gone or disabled**, matching what `refresh/2`
  enforces through `check_authid/2` plus the `is_enabled` check auth applies;
- a user's tokens **over the bound** — the soonest-expiring beyond
  `oauth2.max_tokens_per_user` (see "The bound" in the moduledoc): this is the
  authoritative enforcement; the issuer's own trim is the eager one.

Every write is a `clear` of one cell; nothing is read to be written back.

This is a cold task, not something on any request path. `bondy_reclaimer` runs
it on an interval; it is also safe to call by hand.

> #### Ownership keeps eviction single-writer {: .warning}
>
> Restricting each node to the realms it owns (`bondy:is_owner/1`) makes the
> bound's authoritative evictor one process per realm across the cluster, so
> the filter is applied here rather than left to the caller, and there is
> deliberately no "sweep everything" variant. A clear can only remove; a sweep
> from a stale snapshot removes at most what the bound allows (moduledoc), and
> a token issued concurrently on the same node survives it.
""".
-spec cleanup() -> map().

cleanup() ->
    Now = ?NOW,
    Stats0 = #{
        errors => [],
        scanned => 0,
        expired => 0,
        deactivated => 0,
        evicted => 0,
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

A token is expired once `Now` reaches `expires_at/1`; no clock-skew leeway is
applied.
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
%% The user column of every cell key: the sha256 of the casefolded username.
%% Hashing keeps the column fixed-width and free of the user's own bytes.
store_key(AuthId) ->
    base16:encode(crypto:hash(sha256, string:casefold(AuthId))).

%% @private
%% The cell key of a token: the order-preserving composite
%% `[UserHash, Realm, ClientId, DeviceId]` — the user hash leading, so a
%% user's cells form one band (`user_band/1`) and the table's `leading_col`
%% aggregate root co-locates them on the user's shard.
cell_key(#{type := ?MODULE, authid := AuthId, authscope := Scope}) ->
    cell_key(AuthId, Scope).

%% @private
cell_key(AuthId, Scope0) ->
    #{realm := R, client_id := C, device_id := D} =
        bondy_auth_scope:normalize(Scope0),
    bondy_oplog_index_key:encode_tuple([store_key(AuthId), R, C, D]).

%% @private
%% Half-open `[Lo, Hi)` band over all of one user's cells.
user_band(AuthId) ->
    bondy_oplog_index_key:col_bounds(store_key(AuthId)).

%% @private
%% Folds every token cell of `AuthId` in `AuthRealmUri` (legacy pointers never
%% fall in the band: their keys carry no separator). Pinned to the user's
%% shard when the table's EFFECTIVE routing co-locates the band — the
%% `aggregate` strategy with this table's `leading_col` root, or `realm` —
%% and walked across every shard otherwise (a node whose on-disk manifest
%% pinned an older root): correct either way, single-shard only when the
%% placement makes it so.
fold_user(Table, AuthRealmUri, AuthId, Fun, Acc0) ->
    {Lo, Hi} = user_band(AuthId),
    Opts =
        case
            {
                maps:get(partition_strategy, Table, entity),
                maps:get(aggregate_root, Table, identity)
            }
        of
            {aggregate, leading_col} ->
                #{shard => bondy_db:shard_for(Table, AuthRealmUri, Lo)};
            {realm, _} ->
                #{shard => bondy_db:shard_for(Table, AuthRealmUri, Lo)};
            _ ->
                #{}
        end,
    bondy_db:fold(Table, AuthRealmUri, Lo, Hi, Fun, Acc0, Opts).

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
%% Stores a freshly minted token in its cell (`Key` is `cell_key(T)`), then
%% trims the subject's band to the bound. The write is the token's durability;
%% the trim is the eager half of the bound's enforcement (moduledoc, "The
%% bound") and cannot undo the write, so a trim the store refuses is logged
%% and the issue still succeeds — `cleanup/0` enforces the same rule
%% authoritatively.
store(Key, #{type := ?MODULE} = T) ->
    #{authrealm := AuthRealmUri, authid := AuthId} = T,
    Table = table(),
    ok = write(Table, AuthRealmUri, Key, {set, T}),
    _ = enforce_bound(Table, AuthRealmUri, AuthId, ?MAX_TOKENS),
    ok.

%% @private
%% Persist `Op` on a cell. A refusal from the store is reported as
%% `service_unavailable` — see "Failure reporting" in the moduledoc. Every
%% `{error, _}` `bondy_db:apply/4` returns is such a refusal (an append the
%% shard would not admit, an apply barrier that timed out, an instance that is
%% not there); a fault raises instead and is the caller's `database_error`.
write(Table, RealmUri, Key, Op) ->
    case bondy_db:apply(Table, RealmUri, Key, Op) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description => "Token store refused the write",
                reason => Reason,
                realm_uri => RealmUri
            }),
            throw(service_unavailable)
    end.

%% @private
%% Clears the user's cells beyond `Max`, soonest-expiring first — the one
%% eviction rule both evictors apply (`eviction_order/2`). Returns the number
%% of cells cleared; a band the store could not read or a clear it refused is
%% logged and counted as nothing evicted (the caller's write already stands).
enforce_bound(Table, AuthRealmUri, AuthId, Max) ->
    Collect = fun(Row, Acc) -> [Row | Acc] end,
    try fold_user(Table, AuthRealmUri, AuthId, Collect, []) of
        {ok, Cells} ->
            Victims = over_bound(Cells, Max),
            _ = [
                ok = bondy_db:apply(Table, AuthRealmUri, Key, clear)
             || Key <- Victims
            ],
            length(Victims);
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "Could not read the user's token band to enforce the "
                    "bound; leaving it to the next reclamation sweep",
                reason => Reason,
                realm_uri => AuthRealmUri
            }),
            0
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description =>
                    "Could not trim the user's token band; leaving it to the "
                    "next reclamation sweep",
                class => Class,
                reason => Reason,
                stacktrace => frames(Stacktrace),
                realm_uri => AuthRealmUri
            }),
            0
    end.

%% @private
%% The keys of the cells to evict from `Cells` (rows `{Key, Token, Hlc}`) so
%% that at most `Max` remain: the first `length(Cells) - Max` in eviction
%% order.
over_bound(Cells, Max) when length(Cells) =< Max ->
    [];
over_bound(Cells, Max) ->
    Sorted = lists:sort(fun eviction_order/2, Cells),
    [Key || {Key, _T, _Hlc} <- lists:sublist(Sorted, length(Cells) - Max)].

%% @private
%% The total order evictions follow (moduledoc, "The bound"): soonest-expiring
%% first, then the earliest WRITTEN — the cell's HLC — then the key, so that
%% two evictors working from different snapshots never disagree on which of
%% two cells goes first.
eviction_order({KA, A, HlcA}, {KB, B, HlcB}) ->
    {expires_at(A), HlcA, KA} =< {expires_at(B), HlcB, KB}.

%% @private
%% The token in the cell `Components` names, provided it is the token the
%% components identify: a cell whose token carries another id has been rotated
%% (or re-issued) since that refresh-token string was minted, so the string no
%% longer names a token.
-spec find(uri(), bondy_oauth_refresh_token:components()) ->
    {ok, t()} | {error, any()}.

find(RealmUri, #{key := Key, id := TokenId}) when is_binary(Key) ->
    case read_cell(RealmUri, Key) of
        {ok, #{id := TokenId} = T} -> {ok, T};
        {ok, _} -> {error, not_found};
        {error, _} = Error -> Error
    end;
find(_RealmUri, #{key := _}) ->
    %% The key rides in the client's string; one that is not a cell key names
    %% no cell.
    {error, not_found}.

%% @private
%% The token stored at `Key`. A cell holding anything but a token — a legacy
%% pointer addressed by a token key can only be a crafted string — is
%% `not_found`.
-spec read_cell(uri(), binary()) -> {ok, t()} | {error, any()}.

read_cell(RealmUri, Key) ->
    case bondy_db:read(table(), RealmUri, Key) of
        {ok, {#{type := ?MODULE} = T, _Hlc}} -> {ok, T};
        {ok, _} -> {error, not_found};
        {error, _} = Error -> Error
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
%% Rotates `T0` in place: a new id and refresh-token string, a new lifetime,
%% the same cell. The presented string names the old id and stops resolving
%% the moment this write is applied (`find/2`).
do_refresh(#{type := ?MODULE} = T0) ->
    Now = ?NOW,
    #{authrealm := AuthRealmUri} = T0,
    Key = cell_key(T0),

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
        %% `write/4`'s `service_unavailable` is caught by the `throw:Reason`
        %% clause below and returned, as any other refusal of this function.
        ok = write(table(), AuthRealmUri, Key, {set, T}),
        {ok, T}
    catch
        throw:not_found ->
            {error, {no_such_realm, AuthRealmUri}};
        throw:Reason ->
            {error, Reason};
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while preparing token for the store",
                class => Class,
                reason => Reason,
                stacktrace => frames(Stacktrace)
            }),
            throw(database_error)
    end.

%% @private
%% Clears `T`'s cell. As in `do_refresh/1`: a refusal returns
%% `{error, service_unavailable}`.
do_revoke(#{type := ?MODULE, authrealm := AuthRealmUri} = T) ->
    try
        ok = write(table(), AuthRealmUri, cell_key(T), clear)
    catch
        throw:Reason ->
            {error, Reason};
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while preparing token for the store",
                class => Class,
                reason => Reason,
                stacktrace => frames(Stacktrace)
            }),
            throw(database_error)
    end.

%% @private
%% A stacktrace without its argument lists: the innermost frame of a fault on
%% these paths can carry token maps, and a token map carries the refresh-token
%% string, which is a bearer secret. The arity says where; the arguments are
%% not logged.
frames(Stacktrace) ->
    [
        {M, F, arity(A), Info}
     || {M, F, A, Info} <- Stacktrace
    ].

%% @private
arity(Args) when is_list(Args) -> length(Args);
arity(Arity) -> Arity.

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
%% its cell. A current token self-describes (it parses); a legacy
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
    bondy_oplog_index_key:encode_tuple([?LEGACY_COL, RefreshToken]).

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
%% authenticated against this realm, and those users go with it — token cells
%% and legacy pointers alike.
revoke_all_in(Table, RealmUri, RealmUri) ->
    {ok, Keys} = bondy_db:fold(
        Table,
        RealmUri,
        <<>>,
        infinity,
        fun({Key, _V, _Hlc}, Acc) -> [Key | Acc] end,
        []
    ),
    _ = [ok = bondy_db:apply(Table, RealmUri, Key, clear) || Key <- Keys],
    ok;
%% Any OTHER bucket is an SSO realm shared with sibling member realms, so only
%% the tokens scoped to `ScopeRealmUri` may go. A legacy refresh pointer
%% carries no scope, so there is nothing to match it on; one left dangling
%% fails CLOSED: `refresh/2` resolves the pointer, finds no token behind it,
%% and errors.
revoke_all_in(Table, Bucket, ScopeRealmUri) ->
    {ok, Keys} = bondy_db:fold(
        Table,
        Bucket,
        <<>>,
        infinity,
        fun
            ({Key, #{type := ?MODULE, authscope := Scope}, _Hlc}, Acc) ->
                case bondy_auth_scope:realm(Scope) of
                    ScopeRealmUri -> [Key | Acc];
                    _ -> Acc
                end;
            (_Row, Acc) ->
                Acc
        end,
        []
    ),
    _ = [ok = bondy_db:apply(Table, Bucket, Key, clear) || Key <- Keys],
    ok.

%% @private
%% The token buckets THIS node owns. `bondy_realm:auth_realm_uris/0` has already
%% collapsed each SSO realm's members onto one bucket, so filtering its result
%% decides ownership of the bucket — which is the only correct grain (see that
%% function).
owned_auth_realm_uris() ->
    lists:filter(fun bondy:is_owner/1, bondy_realm:auth_realm_uris()).

%% @private
%% One realm's cells: a streamed pass that clears the expired and the
%% deactivated (the user is resolved once per user, not once per token) and
%% counts the live tokens per user, then trims every user found over the bound.
%% A failure here is recorded and the sweep CONTINUES: a single unreadable
%% realm must not abandon every other realm's reclamation.
cleanup_realm(AuthRealmUri, Now, Stats0) ->
    Table = table(),
    Sweep = #{stats => Stats0, users => #{}, counts => #{}},

    try
        bondy_db:fold(
            Table,
            AuthRealmUri,
            <<>>,
            infinity,
            fun(Row, Acc) ->
                cleanup_cell(Table, AuthRealmUri, Row, Now, Acc)
            end,
            Sweep
        )
    of
        {ok, #{stats := Stats1, counts := Counts}} ->
            trim_over_bound(Table, AuthRealmUri, Counts, Stats1);
        {error, Reason} ->
            add_error(Stats0, AuthRealmUri, Reason)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description => "Error while cleaning up OAuth2 tokens",
                realm_uri => AuthRealmUri,
                class => Class,
                reason => Reason,
                stacktrace => frames(Stacktrace)
            }),
            add_error(Stats0, AuthRealmUri, Reason)
    end.

%% @private
%% A legacy refresh pointer is not a token — it is a one-shot indirection
%% keyed under a `legacy:` prefix. Its lifetime is owned by `refresh/2`, which
%% clears it the first time the legacy string is redeemed, so leave it alone.
cleanup_cell(_, _, {_Key, #{type := ?LEGACY_POINTER}, _Hlc}, _Now, Sweep) ->
    Sweep;
cleanup_cell(
    Table,
    AuthRealmUri,
    {Key, #{type := ?MODULE, authid := AuthId} = T, _Hlc},
    Now,
    #{stats := Stats0, users := Users0, counts := Counts0} = Sweep
) ->
    Stats1 = bump(Stats0, scanned, 1),
    case is_expired(T, Now) of
        true ->
            ok = bondy_db:apply(Table, AuthRealmUri, Key, clear),
            Stats2 = bump(bump(Stats1, expired, 1), cells_cleared, 1),
            Sweep#{stats := Stats2};
        false ->
            {Active, Users} =
                case maps:find(AuthId, Users0) of
                    {ok, A} ->
                        {A, Users0};
                    error ->
                        A = is_user_active(AuthRealmUri, AuthId),
                        {A, Users0#{AuthId => A}}
                end,
            case Active of
                false ->
                    ok = bondy_db:apply(Table, AuthRealmUri, Key, clear),
                    Stats2 = bump(
                        bump(Stats1, deactivated, 1), cells_cleared, 1
                    ),
                    Sweep#{stats := Stats2, users := Users};
                true ->
                    Counts = maps:update_with(
                        AuthId, fun(N) -> N + 1 end, 1, Counts0
                    ),
                    Sweep#{stats := Stats1, users := Users, counts := Counts}
            end
    end;
cleanup_cell(_, _, _Row, _Now, Sweep) ->
    Sweep.

%% @private
%% The authoritative half of the bound: every user the pass counted over
%% `Max` has its band re-read and trimmed by the one eviction rule.
trim_over_bound(Table, AuthRealmUri, Counts, Stats0) ->
    Max = ?MAX_TOKENS,
    maps:fold(
        fun
            (AuthId, N, Stats) when N > Max ->
                Evicted = enforce_bound(Table, AuthRealmUri, AuthId, Max),
                bump(bump(Stats, evicted, Evicted), cells_cleared, Evicted);
            (_AuthId, _N, Stats) ->
                Stats
        end,
        Stats0,
        Counts
    ).

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
