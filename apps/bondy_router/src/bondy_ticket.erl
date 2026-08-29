%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_ticket).
-moduledoc """
This module implements the functions to issue and manage authentication
tickets.

## Overview
An authentication ticket is a signed (and possibly encrypted) assertion of a
user's identity, that a client can use to authenticate the user without the need
to ask it to re-enter its credentials.

Tickets MUST be issued by a session that was opened using an authentication
method that is neither `ticket` nor `anonymous` authentication.

## Claims

- `id`: provides a unique identifier for the ticket.
- `issued_by`: identifies the principal that issued the ticket. Most of the time
  this is an application identifier (a.k.asl username or client_id) but sometimes
  can be the WAMP session's username (a.k.a `authid`).
- `authid`: identifies the principal that is the subject of the ticket. The
  Claims in a ticket are normally statements. This is the WAMP session's username
  (a.k.a `authid`).
- `authrealm`: identifies the recipients that the ticket is intended for. The
  value is `RealmUri`.
- `expires_at`: identifies the expiration time on or after which the ticket MUST
  NOT be accepted for processing. The processing of th thia claim requires that
  the current date/time MUST be before the expiration date/time listed in the
  "exp" claim. Bondy considers a small leeway of 2 mins by default.
- `issued_at`: identifies the time at which the ticket was issued. This claim can
  be used to determine the age of the ticket. Its value is a timestamp in
  seconds.
- `issued_on`: the bondy nodename in which the ticket was issued.
- `authroles` (optional): a role RESTRICTION — present only when the ticket was
  issued with the `authroles` option, whose value must be a non-empty subset of
  the issuing session's own roles. A session authenticated with such a ticket
  gets exactly these roles, applied non-negotiably by `bondy_auth` (the bearer
  may narrow further at establishment, never widen; an empty intersection
  refuses the authentication). Absent means unrestricted. This is the
  delegation mechanism: a user hands an agent a role-restricted, short-lived
  ticket rather than their own credential.
- `scope`: the scope of the ticket, consisting of
- `realm`: If `all` the ticket grants access to all realms the user has access to
  by the authrealm (an SSO realm). Otherwise, the value is the realm this ticket
  is valid on.

> #### Scope encoding {: .warning}
>
> The wildcard is the atom `all` in memory, but a scope embedded in a ticket is
> carried as JSON, which renders it as the string `~"all"`. `scope_type/1` and
> `store_key/3` match on the atom, so any scope obtained by decoding a ticket
> MUST be passed through `bondy_auth_scope:normalize/1` before use — otherwise
> the storage key derived at verification differs from the one used at issue and
> `lookup/3` can never find the persisted claims. `verify/1` does this.

## Claims Storage

Claims are stored in the `bondy_ticket` table of the durable `main` database,
banded by the authentication realm's URI and keyed by the triple
`{authid, client_id | realm, device_id}` derived from the ticket's scope. The
scope itself follows from the options given to `issue/2`.

The key is the scope rather than the ticket's unique identifier, which bounds
how many tickets one user can hold: re-issuing within a scope replaces the
claims already stored there instead of accumulating a new cell. That bound is
what keeps ticket storage and its replication traffic proportional to users and
scopes rather than to issuance rate.

## Ticket Scopes
A ticket can be issued using different scopes. The scope is determined based on
the options used to issue the ticket.

There are 4 scopes:

1. Local scope
2. SSO scope
3. Client-Local scope
4. Client-SSO scope

### Local scope
The ticket was issued with `allow_sso` option set to `false` or when set to
`true` the user did not have SSO credentials, and the option `client_ticket` was
not provided.
The ticket can be used to authenticate on the session's realm only.

#### Authorization
To be able to issue this ticket, the user must have been granted permission
`<<"bondy.issue">>` on the `<<"bondy.ticket.scope.local">>` resource.

### SSO Scope
The ticket was issued with `allow_sso` option set to `true`, the user has SSO
credentials, and the option `client_ticket` was not provided.
The ticket can be used to authenticate on any realm the user has access to
through SSO.

#### Authorization
To be able to issue this ticket, the user must have been granted permission
`<<"bondy.issue">>` on the `<<"bondy.ticket.scope.sso">>` resource.

### Client-Local scope
The ticket was issued with `allow_sso` option set to `false` or when set to
`true` the user did not have SSO credentials, and the option `client_ticket` was
provided having a valid ticket issued by a client (a local or sso ticket).
The ticket can be used to authenticate on the session's realm by the specified
client only.

#### Authorization
To be able to issue this ticket, the session must have been granted permission
`<<"bondy.issue">>` on the `<<"bondy.ticket.scope.client_local">>` resource.

### Client-SSO scope
The ticket was issued with `allow_sso` option set to `true` and the user has SSO
credentials, and the option `client_ticket` was provided having a valid ticket
issued by a client (a local or sso ticket).
The ticket can be used to authenticate on any realm the user has access to
through SSO only by the specified client.

#### Authorization
To be able to issue this ticket, the session must have been granted permission
`<<"bondy.issue">>` on the `<<"bondy.ticket.scope.client_local">>` resource.

### Scope Summary

*Keys:*
- `uri()` in the following table refers to the scope realm (not the
  Authentication realm which is used in the prefix)

|SCOPE|Allow SSO|Client Ticket|Client Instance ID|Key|Value|
|---|---|---|---|---|---|
|Local|no|no|no|`uri()`|`t()`|
|SSO|yes|no|no|`username()`|`t()`|
|Client-Local|no|yes|no|`client_id()`|`[{uri(), t()}]`|
|Client-Local|no|yes|yes|`client_id()`|`[{{uri(), instance_id()}, t()}]`|
|Client-SSO|yes|yes|no|`client_id()`|`[{all, t()}]`|
|Client-SSO|yes|yes|yes|`client_id()`|`[{{all, instance_id()}, t()}]`|

### Permissions Summary
Issuing tickets requires the user to be granted certain permissions beyond the
WAMP permission required to call the procedures.

|Scope|Permission|Resource|
|---|---|---|
|Local|`bondy.issue`|`bondy.ticket.scope.local`|
|SSO|`bondy.issue`|`bondy.ticket.scope.sso`|
|Client-Local|`bondy.issue`|`bondy.ticket.scope.client_local`|
|Client-SSO|`bondy.issue`|`bondy.ticket.scope.client_sso`|
""".
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_db_tables.hrl").
-include("bondy_security.hrl").

-define(NOW, erlang:system_time(second)).
% 2 mins
-define(LEEWAY_SECS, 2 * 60).

%% Tickets live in the bondy_db `bondy_ticket` main table, bucketed by the auth
%% realm and keyed by the composed store key. The 3-tuple store key
%% `{Authid, A, B}` is encoded to a binary with
%% `term_to_binary/1`; it is NOT order-preserving, so `revoke_all/2` scans the
%% realm and filters by the decoded `Authid` rather than a key-prefix range. The
%% catalogue (`bondy_namespace_catalog`) provisions the table.

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
    client_ticket => #{
        alias => ~"client_ticket",
        key => client_ticket,
        required => false,
        datatype => binary
    },
    authroles => #{
        alias => ~"authroles",
        key => authroles,
        required => false,
        datatype => {list, binary}
    }
}).

-type t() :: #{
    id := ticket_id(),
    authrealm := uri(),
    authid := authid(),
    %% Present only on a role-RESTRICTED ticket (MCP-D31 delegation):
    %% `issue/2` writes it only when the `authroles` option was given, so
    %% every ticket issued before the option existed — and every
    %% unrestricted one since — verifies without it, meaning
    %% unrestricted.
    authroles => [binary()],
    authmethod := binary(),
    issued_by := authid(),
    issued_on := node(),
    issued_at := pos_integer(),
    expires_at := pos_integer(),
    scope := scope(),
    kid := binary(),
    %% Optional OIDC fields
    oidc_provider => binary(),
    oidc_refresh_token => binary(),
    oidc_access_token_expires_in =>
        pos_integer()
}.
-type opts() :: #{
    expiry_time_secs => pos_integer(),
    allow_sso => boolean(),
    client_ticket => jwt(),
    client_id => binary(),
    device_id => binary()
}.
-type verify_opts() :: #{
    allow_not_found => boolean()
}.
-type scope() :: bondy_auth_scope:t().
-type jwt() :: binary().
-type ticket_id() :: binary().
-type authid() :: bondy_rbac_user:username().
-type issue_error() ::
    {no_such_user, authid()}
    | {no_such_realm, uri()}
    | {invalid_request, binary()}
    | invalid_ticket
    | not_authorized.

-export_type([t/0]).
-export_type([jwt/0]).
-export_type([ticket_id/0]).
-export_type([scope/0]).
-export_type([opts/0]).

-export([cleanup/0]).
-export([issue/2]).
-export([lookup/3]).
-export([revoke/1]).
-export([revoke/3]).
-export([revoke_all/1]).
-export([revoke_all/2]).
-export([store_ticket/3]).
-export([update_claims/3]).
-export([verify/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Issues a ticket to be used with the WAMP Ticket authentication method. The
function stores the ticket claims data and replicates it across all nodes in the
cluster.

The session `Session` must have been opened using an authentication method that
is neither `ticket` nor `anonymous` authentication.

The function takes an options map `opts()` that can contain the following keys:
- `expiry_time_secs`: the expiration time on or after which the ticket MUST NOT
  be accepted for processing. This is a request that might not be honoured by the
  router as it depends on the router configuration, so the returned value might
  defer.

To issue a client-scoped ticket, either the option `client_ticket` or
`client_id` must be present. The `client_ticket` option takes a valid ticket
issued by a different user (normally a client). Otherwise the call will return
the error tuple with reason `invalid_request`.
""".
-spec issue(Session :: bondy_session:t(), Opts :: opts()) ->
    {ok, Ticket :: jwt(), Claims :: t()}
    | {error, issue_error()}
    | no_return().

issue(Session, Opts0) ->
    try
        Opts = maps_utils:validate(Opts0, ?OPTS_VALIDATOR),
        Authmethod = bondy_session:authmethod(Session),
        Allowed = bondy_config:get([security, ticket, authmethods]),

        lists:member(Authmethod, Allowed) orelse
            throw(
                {
                    not_authorized,
                    <<
                        "The authentication method '",
                        Authmethod/binary,
                        "' you used to establish this session is not in the list of "
                        "methods allowed to issue tickets (configuration option "
                        "'security.ticket.authmethods')."
                    >>
                }
            ),

        do_issue(Session, Opts)
    catch
        throw:Reason ->
            {error, Reason};
        _:Reason ->
            {error, Reason}
    end.

-doc """
Verifies `Ticket` and returns its claims. Equivalent to `verify/2` with default
options.
""".
-spec verify(Ticket :: binary()) ->
    {ok, t()} | {error, expired | invalid | no_match}.

verify(Ticket) ->
    verify(Ticket, #{}).

-doc """
Verifies `Ticket` and returns the claims persisted for it.

Verification is three questions, in order: is the signature valid and the ticket
well-formed (`invalid`), has it passed its expiry (`expired`), and do the
claims it carries still match the ones stored under its scope (`no_match`)?
The last is what makes revocation effective — a syntactically perfect ticket
whose stored claims are gone verifies to `no_match`.

The scope decoded from a ticket arrives in its JSON form, where the wildcard
realm is the string `~"all"` rather than the atom. This normalises it before
deriving the storage key, so a caller never has to.
""".
-spec verify(Ticket :: binary(), Opts :: verify_opts()) ->
    {ok, t()} | {error, expired | invalid | no_match}.

verify(Ticket, Opts) ->
    try
        {jose_jwt, RawClaims} = jose_jwt:peek(Ticket),
        Claims0 = bondy_utils:to_existing_atom_keys(RawClaims),

        #{
            authrealm := AuthRealmUri,
            authid := Authid,
            issued_at := IssuedAt,
            expires_at := ExpiresAt,
            % issued_on := Node,
            scope := Scope0,
            kid := Kid
        } = Claims0,

        %% The scope survives the JWT as JSON, so its wildcards come back as
        %% `~"all"` (or `undefined` for tickets issued before this fix) rather
        %% than the atom `all`. `scope_type/1` and `store_key/3` match on the
        %% atom, so without this the type — and therefore the storage key —
        %% computed here would differ from the one used at issue time and
        %% `lookup/3` could never find the persisted claims.
        Scope = bondy_auth_scope:normalize(Scope0),
        Claims = Claims0#{scope := Scope},

        is_expired(Claims) andalso throw(expired),
        ExpiresAt > IssuedAt orelse throw(invalid),

        Realm = bondy_realm:fetch(AuthRealmUri),

        Key = bondy_realm:get_public_key(Realm, Kid),
        Key =/= undefined orelse throw(invalid),

        {Verified, _, _} = jose_jwt:verify_strict(
            Key, ?ALLOWED_JWT_ALGS, Ticket
        ),
        Verified == true orelse throw(invalid),

        case is_persistent(scope_type(Scope)) of
            true ->
                AllowNotFound = allow_not_found(Opts),

                case lookup(AuthRealmUri, Authid, Scope) of
                    {ok, Claims} = OK ->
                        OK;
                    {ok, _Other} ->
                        throw(no_match);
                    {error, not_found} when AllowNotFound == true ->
                        %% We trust the signed JWT
                        {ok, Claims};
                    {error, not_found} ->
                        %% TODO Try to retrieve from Claims.node
                        %% or use Scope to lookup indices
                        throw(invalid)
                end;
            false ->
                {ok, Claims}
        end
    catch
        error:{badkey, _} ->
            {error, invalid};
        error:{badarg, _} ->
            {error, invalid};
        throw:Reason ->
            {error, Reason};
        error:{not_found, _} ->
            %% bondy_realm:fetch/1 raised because `authrealm` names a realm
            %% that does not exist. That claim is still unverified input at
            %% this point, so this is an invalid ticket, not a server fault.
            {error, invalid};
        Class:Reason:Stacktrace ->
            %% Everything above the signature check runs on attacker-controlled
            %% input: `jose_jwt:peek/1` raises `case_clause` or
            %% `function_clause` on some malformed JWTs, and
            %% `bondy_auth_scope:normalize/1` is only defined for maps, so a
            %% ticket carrying a non-map `scope` raises too. Report those as an
            %% invalid ticket rather than letting them crash the caller.
            %% Logged at warning, not error: a flood of malformed tickets is an
            %% untrusted peer, not a fault in this node. The ticket itself is
            %% never logged.
            ?LOG_WARNING(#{
                description => "Error while verifying ticket",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, invalid}
    end.

-doc """
Returns the claims persisted for `Authid` under `Scope` in `RealmUri`, or
`{error, not_found}`.

`RealmUri` is the authentication realm — the ticket's `authrealm` claim — not
the realm the ticket grants access to; for an SSO ticket the two differ. `Scope`
must be normalised (`bondy_auth_scope:normalize/1`); an un-normalised scope
derives a different storage key and finds nothing.

Reads storage only. It does not check expiry, so a caller that needs a usable
ticket wants `verify/1`.
""".
-spec lookup(
    RealmUri :: uri(),
    Authid :: bondy_rbac_user:username(),
    Scope :: scope()
) -> {ok, Claims :: t()} | {error, no_found}.

lookup(RealmUri, Authid, Scope) ->
    Key = lookup_key(Authid, Scope),

    case bondy_db:read(table(), RealmUri, encode_key(Key)) of
        {error, not_found} ->
            {error, not_found};
        {ok, {Claims, _Hlc}} when is_map(Claims) ->
            {ok, Claims};
        {ok, {List, _Hlc}} when is_list(List) ->
            %% List :: [t()]
            LKey = list_key(Scope),
            case lists:keyfind(LKey, 1, List) of
                {LKey, Claims} ->
                    {ok, Claims};
                false ->
                    {error, not_found}
            end
    end.

-doc """
Revokes a ticket, given either the encoded ticket or its claims, by deleting the
claims stored under its scope. A ticket that cannot be verified is not revoked
and the verification error is returned; `undefined` is accepted and does
nothing.

Revocation is by scope, so it also invalidates any other ticket issued into the
same scope. The next `verify/1` of a revoked ticket answers `no_match`.
""".
-spec revoke(optional(t())) -> ok | {error, any()}.

revoke(undefined) ->
    ok;
revoke(Ticket) when is_binary(Ticket) ->
    case verify(Ticket) of
        {ok, Claims} ->
            revoke(Claims);
        {error, _} = Error ->
            Error
    end;
revoke(Claims) when is_map(Claims) ->
    #{
        authrealm := RealmUri,
        authid := Authid,
        scope := Scope
    } = Claims,
    revoke(RealmUri, Authid, Scope).

-doc """
Revokes whatever ticket `Authid` holds in `Scope`, by clearing the claims stored
there.

`RealmUri` is the ticket's `authrealm` claim — the authentication realm — which
for an SSO ticket is not the realm the ticket grants access to. Revoking a scope
that holds no ticket succeeds.
""".
-spec revoke(
    RealmUri :: uri(),
    Authid :: bondy_rbac_user:username(),
    Scope :: scope()
) -> ok.

revoke(RealmUri, Authid, Scope) when
    is_binary(RealmUri), is_binary(Authid), is_map(Scope)
->
    Key = lookup_key(Authid, Scope),
    bondy_db:apply(table(), RealmUri, encode_key(Key), clear).

-doc """
Reclaims persisted ticket cells that can no longer authenticate anyone, across
the auth realms THIS NODE OWNS, and returns what it did.

`verify/1` rejects an expired ticket before it even fetches the realm key, so
this changes nothing about who can authenticate — it reclaims the storage that
outlives the ticket. Two things are dropped:

- **expired** tickets, using the same `is_expired/1` that `verify/1` rejects on,
  so storage and authentication agree on exactly which tickets exist;
- tickets whose user is **gone or disabled**. `revoke_all/2` already runs
  eventfully on user disable and delete, so this is a BACKSTOP for an event a
  node missed while partitioned or restarting, not the primary mechanism.

Empty cells are cleared rather than written back.

## Why a sweep is needed at all

`update_tickets/3` already prunes expired entries from a CLIENT-SCOPED cell
whenever it rewrites one, which bounds that shape to live devices. It cannot
reach the other shape: a `client_id = all` ticket (plain local / SSO scope —
the DEFAULT, everything issued without a `client_ticket`) is one ticket per
cell, keyed by `{Authid, RealmUri, DeviceId}`, and re-issuing writes only that
same key. A cell whose key stops being used is never read or written again, so
there is no write to hang a prune off. That residue is what this reclaims.

> #### Ownership is a safety property, not an optimisation {: .warning}
>
> Cells are read, filtered and written back over a last-write-wins store, so two
> nodes sweeping one realm concurrently could resurrect what the other
> reclaimed. Restricting each node to the realms it owns (`bondy:is_owner/1`)
> leaves a single writer per realm. The filter is therefore applied here rather
> than left to the caller, and there is deliberately no "sweep everything"
> variant.
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
        fun(RealmUri, Acc) -> cleanup_realm(RealmUri, Now, Acc) end,
        Stats0,
        owned_auth_realm_uris()
    ),
    ?LOG_INFO(#{
        description => "Finished cleaning up tickets",
        stats => Stats
    }),
    Stats.

-doc """
Revokes every ticket that is valid on realm `RealmUri`.

Tickets are bucketed by the issuing session's AUTHENTICATION realm — an SSO
user's ticket lives under the SSO realm, not under the realm they connected to.
Scanning only `RealmUri` therefore missed every SSO-backed realm's tickets
entirely, so deleting such a realm left working tickets behind.

Two buckets can hold them, and they are treated differently:

- **`RealmUri`'s own bucket** holds tickets issued by sessions that
  authenticated against it (its local, non-SSO users). Those users go with the
  realm, so the bucket is cleared wholesale.
- **Every other auth realm** is a shared SSO bucket holding several member
  realms' tickets. Only those scoped to `RealmUri` may go — clearing such a
  bucket would revoke sibling realms' users too. An SSO-scoped ticket
  (`scope.realm = all`) is deliberately KEPT: it still grants the realms its
  user can still reach.

The SSO realm is not resolved from `RealmUri`, because `bondy_realm:delete/2`
clears the realm record BEFORE running this — so by now there is nothing to
resolve. Every surviving auth realm is scanned instead. That is O(realms), but
realm deletion is a cold, one-off path.
""".
-spec revoke_all(RealmUri :: uri()) -> ok.

revoke_all(RealmUri) when is_binary(RealmUri) ->
    Table = table(),
    Buckets = lists:usort([RealmUri | bondy_realm:auth_realm_uris()]),
    _ = [revoke_all_in(Table, Bucket, RealmUri) || Bucket <- Buckets],
    ok.

-doc """
Revokes all tickets issued to user `Authid` in realm `RealmUri`, whether the
user issued them itself or a client application did.

Called when a user is deleted, disabled or has its credentials changed, so it
must not miss any: a revocation that misses is a security failure, whereas one
that over-reaches only costs a re-authentication. It therefore clears EVERY
ticket held for `Authid`, including SSO-scoped ones that also grant the user's
other realms.

Both buckets a user's tickets can live in are scanned — the realm itself (where
a local user authenticates) and its SSO realm (where an SSO user does).
Scanning only `RealmUri` missed an SSO user's tickets entirely, which meant
disabling or deleting such a user left their tickets working.
""".
-spec revoke_all(RealmUri :: uri(), Authid :: bondy_rbac_user:username()) ->
    ok.

revoke_all(RealmUri, Authid) ->
    Table = table(),
    _ = [
        revoke_all_for(Table, Bucket, Authid)
     || Bucket <- ticket_buckets(RealmUri)
    ],
    ok.

-doc """
Updates the claims stored in PlumDB for an existing ticket. This is used by the
OIDC refresh worker to update OIDC tokens (refresh_token,
access_token_expires_at) without re-issuing the ticket.
""".
-spec update_claims(
    AuthRealmUri :: uri(),
    Authid :: bondy_rbac_user:username(),
    UpdateFun :: fun((t()) -> t())
) -> ok | {error, not_found}.

update_claims(AuthRealmUri, Authid, UpdateFun) when
    is_binary(AuthRealmUri) andalso is_binary(Authid) andalso
        is_function(UpdateFun, 1)
->
    Scope = #{realm => all, client_id => all, device_id => all},
    Table = table(),
    EncKey = encode_key(lookup_key(Authid, Scope)),

    case bondy_db:read(Table, AuthRealmUri, EncKey) of
        {error, not_found} ->
            {error, not_found};
        {ok, {Claims, _Hlc}} when is_map(Claims) ->
            UpdatedClaims = UpdateFun(Claims),
            ok = bondy_db:apply(
                Table, AuthRealmUri, EncKey, {set, UpdatedClaims}
            );
        {ok, {_List, _Hlc}} ->
            %% For list-type entries (client-scoped), not supported for OIDC
            {error, not_found}
    end.

%% ===========================================================================
%% PRIVATE
%% ===========================================================================

%% @private
do_issue(Session, Opts) ->
    RealmUri = bondy_session:realm_uri(Session),
    AuthRealmUri = bondy_session:authrealm(Session),
    Authid = bondy_session:authid(Session),
    User = bondy_session:user(Session),
    SSORealmUri = bondy_rbac_user:sso_realm_uri(User),

    ScopeUri =
        case maps:get(allow_sso, Opts) of
            true when SSORealmUri =/= undefined ->
                %% The ticket can be used to authenticate on all user realms
                %% connected to this SSORealmUri. The wildcard carries no realm
                %% itself: the reachable set is determined at verification time
                %% by bondy_realm:is_trusted_issuer/2 against the `authrealm`
                %% claim.
                all;
            _ ->
                %% SSORealmUri is undefined or SSO was not allowed,
                %% the scope realm can only be the session realm
                RealmUri
        end,

    Scope = scope(Session, Opts, ScopeUri),
    ScopeType = scope_type(Scope),
    AuthCtxt = bondy_session:rbac_context(Session),

    ok = authorize(ScopeType, AuthCtxt),

    %% MCP-D31 delegation: an `authroles` restriction must be a subset of
    %% the ISSUING SESSION's roles — not the user's groups — so a
    %% restricted session can never mint a wider ticket than itself
    %% (falsifier:
    %% `bondy_auth_ticket_SUITE:issue_with_authroles_superset_refused`).
    Authroles = maps:get(authroles, Opts, undefined),
    ok = assert_authroles(Authroles, Session),

    AuthRealm = bondy_realm:fetch(AuthRealmUri),
    %% Pick the signing key atomically: keys are generated lazily, so the kid
    %% and its private key must come from the same (post-generation) realm.
    {Kid, PrivKey} = bondy_realm:get_random_private_key(AuthRealm),

    IssuedAt = ?NOW,
    ExpiresAt = IssuedAt + expiry_time_secs(Opts),

    Claims0 = #{
        id => bondy_utils:uuid(),
        authrealm => AuthRealmUri,
        authid => Authid,
        authmethod => bondy_session:authmethod(Session),
        issued_by => issuer(Authid, Scope),
        issued_on => atom_to_binary(bondy_config:node(), utf8),
        issued_at => IssuedAt,
        expires_at => ExpiresAt,
        scope => Scope,
        kid => Kid
    },
    %% Written only when restricting: an absent claim means unrestricted,
    %% which is also what every ticket issued before this field existed
    %% verifies as.
    Claims =
        case Authroles of
            undefined -> Claims0;
            _ -> Claims0#{authroles => Authroles}
        end,

    JWT = jose_jwt:from(Claims),

    %% We first sign (jose lib does not still support nested JWS in JWE, so we
    %% do it our way)
    {_, Ticket} = jose_jws:compact(jose_jwt:sign(PrivKey, JWT)),

    case is_persistent(ScopeType) of
        true ->
            ok = store_ticket(AuthRealmUri, Authid, Claims);
        false ->
            ok
    end,

    {ok, Ticket, Claims}.

%% @private
scope(Session, #{client_ticket := Ticket} = Opts, Uri) when
    is_binary(Ticket)
->
    Authid = bondy_session:authid(Session),

    %% We are relaxed here as these are signed by us.
    VerifyOpts = #{allow_not_found => true},

    case verify(Ticket, VerifyOpts) of
        {ok, #{scope := #{client_id := Val}}} when Val =/= all ->
            throw({invalid_request, "Nested tickets are not allowed"});
        {ok, #{issued_by := Authid}} ->
            %% A client is requesting a ticket issued to itself using its own
            %% client_ticket.
            throw({invalid_request, "Self-granting ticket not allowed"});
        {ok, #{authid := ClientId, scope := Scope}} ->
            Id0 = maps:get(device_id, Scope),
            Id = maps:get(device_id, Opts, Id0),

            all =:= Id0 orelse Id =:= Id0 orelse
                throw({invalid_request, "invalid device_id"}),

            bondy_auth_scope:new(Uri, ClientId, Id);
        {error, _Reason} ->
            error(
                bondy_error:new(invalid_value, #{
                    description =>
                        ~"The value for 'client_ticket' is not valid.",
                    message => <<
                        "The value for 'client_ticket' is not either not a "
                        "ticket, it has an invalid signature or it is expired."
                    >>,
                    details => #{key => client_ticket}
                })
            )
    end;
scope(Session, Opts, Uri) ->
    Authid = bondy_session:authid(Session),
    ClientId = maps:get(client_id, Opts, all),
    InstanceId = maps:get(device_id, Opts, all),

    %% Throw exception if client is requesting a ticket issued to itself
    Authid =/= ClientId orelse throw(invalid_request),

    bondy_auth_scope:new(Uri, ClientId, InstanceId).

%% @private
%% A role restriction must be a NON-EMPTY subset of the issuing session's
%% own roles: the session's roles are already the user's groups
%% intersected with whatever the session requested at establishment, so
%% subsetting THEM (never the user's groups) is what makes re-widening
%% through a chain of issues impossible.
assert_authroles(undefined, _) ->
    ok;
assert_authroles([], _) ->
    throw(
        {invalid_request,
            ~"The value for 'authroles' must be a non-empty list of the session's roles (groups)."}
    );
assert_authroles(Authroles, Session) ->
    SessionRoles = bondy_session:authroles(Session),
    case [R || R <- Authroles, not lists:member(R, SessionRoles)] of
        [] ->
            ok;
        Unknown ->
            throw(
                {not_authorized, <<
                    "The 'authroles' requested for the ticket are not a "
                    "subset of the roles of the session issuing it: ",
                    (iolist_to_binary(lists:join(<<", ">>, Unknown)))/binary
                >>}
            )
    end.

%% @private
authorize(ScopeType, AuthCtxt) ->
    case ScopeType of
        sso ->
            ok = bondy_rbac:authorize(
                <<"bondy.issue">>, <<"bondy.ticket.scope.sso">>, AuthCtxt
            );
        client_sso ->
            ok = bondy_rbac:authorize(
                <<"bondy.issue">>, <<"bondy.ticket.scope.client_sso">>, AuthCtxt
            );
        local ->
            ok = bondy_rbac:authorize(
                <<"bondy.issue">>, <<"bondy.ticket.scope.local">>, AuthCtxt
            );
        client_local ->
            ok = bondy_rbac:authorize(
                <<"bondy.issue">>,
                <<"bondy.ticket.scope.client_local">>,
                AuthCtxt
            )
    end.

scope_type(#{realm := all, client_id := all}) ->
    sso;
scope_type(#{realm := all, client_id := _}) ->
    client_sso;
scope_type(#{client_id := all}) ->
    local;
scope_type(#{client_id := _}) ->
    client_local.

%% @private
is_persistent(Type) ->
    bondy_config:get([security, ticket, Type, persistence], true).

%% @private
store_key(Authid, Scope) ->
    store_key(Authid, Scope, scope_type(Scope)).

%% @private
store_key(Authid, #{client_id := ClientId}, Type) when
    ClientId =/= all andalso
        (Type == client_local orelse Type == client_sso)
->
    %% client scope or client_realm scope ticket
    %% device_id handled internally by list_key
    {Authid, ClientId, <<>>};
store_key(Authid, #{device_id := all}, sso) ->
    {Authid, <<>>, <<>>};
store_key(Authid, #{device_id := Id}, sso) ->
    {Authid, <<>>, Id};
store_key(Authid, #{realm := Uri, device_id := all}, local) ->
    {Authid, Uri, <<>>};
store_key(Authid, #{realm := Uri, device_id := Id}, local) ->
    {Authid, Uri, Id}.

%% @private
lookup_key(Authid, Scope) ->
    store_key(Authid, bondy_auth_scope:normalize(Scope)).

%% @private
list_key(#{realm := Uri, device_id := Id}) ->
    {Uri, Id}.

%% Exported so tests can seed storage through the real write path — the
%% per-scope keying and per-device entry handling are what they exercise — not
%% part of the module's public surface.
-doc false.
store_ticket(AuthRealmUri, Authid, Claims) ->
    Table = table(),
    Scope = maps:get(scope, Claims),
    EncKey = encode_key(store_key(Authid, Scope)),

    case maps:get(client_id, Scope) of
        all ->
            %% local | sso ticket scope type
            %% We just replace any existing ticket in this location
            ok = bondy_db:apply(Table, AuthRealmUri, EncKey, {set, Claims});
        _ ->
            %% client_local | client_sso scope type
            %% We have to update the value, so first we fetch it.
            Tickets0 =
                case bondy_db:read(Table, AuthRealmUri, EncKey) of
                    {ok, {T, _Hlc}} -> T;
                    {error, not_found} -> undefined
                end,
            Tickets = update_tickets(Scope, Claims, Tickets0),
            ok = bondy_db:apply(Table, AuthRealmUri, EncKey, {set, Tickets})
    end.

%% @private
%% The first ticket for a client-scoped cell MUST be stored keyed by its
%% `list_key` (the `{realm, device_id}` pair), exactly like every subsequent
%% entry. Returning a bare `[Claims]` here (the historical form) left the first
%% device's ticket unkeyed in the list, so `lookup/3`'s
%% `lists:keyfind(LKey, 1, List)` could never find it and re-issuing that device
%% appended a duplicate instead of replacing — an unbounded growth bug for the
%% first device. Keying it makes lookup find it and keystore replace it.
update_tickets(Scope, Claims, undefined) when is_map(Scope) ->
    [{list_key(Scope), Claims}];
update_tickets(Scope, Claims, Tickets) when is_map(Scope) ->
    update_tickets(list_key(Scope), Claims, Tickets);
update_tickets({_, _} = Key, Claims, Tickets) ->
    lists:sort(
        lists:keystore(Key, 1, prune_expired(Tickets), {Key, Claims})
    ).

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
%% Any OTHER bucket is an SSO realm shared by several member realms. Clearing it
%% would revoke the siblings' users too, so only tickets scoped to
%% `ScopeRealmUri` go.
revoke_all_in(Table, Bucket, ScopeRealmUri) ->
    {ok, Rows} = bondy_db:list(Table, Bucket),
    _ = [revoke_scoped(Table, Bucket, Row, ScopeRealmUri) || Row <- Rows],
    ok.

%% @private
%% A map-valued cell is ONE ticket of local or SSO scope, and `store_key/3` puts
%% its scope realm in the key's second element — a realm URI for local scope,
%% `<<>>` for SSO scope. So an SSO-scoped ticket never matches a realm URI and
%% is correctly left alone: it still grants the realms its user can reach.
revoke_scoped(Table, Bucket, {Key, Claims, _Hlc}, ScopeRealmUri) when
    is_map(Claims)
->
    case key_scope_realm(Key) of
        {ok, ScopeRealmUri} ->
            bondy_db:apply(Table, Bucket, Key, clear);
        _ ->
            ok
    end;
%% A list-valued cell is a CLIENT-scoped per-device list. Its key holds the
%% client id, not a realm (`store_key/3`), so the scope realm lives in each
%% entry's `list_key/1` — `{ScopeRealm, DeviceId}`, with the atom `all` for
%% client-SSO scope. Entries are therefore pruned individually.
revoke_scoped(Table, Bucket, {Key, Entries, _Hlc}, ScopeRealmUri) when
    is_list(Entries)
->
    Keep = [E || E <- Entries, not entry_has_realm(E, ScopeRealmUri)],

    case length(Keep) =:= length(Entries) of
        true ->
            ok;
        false when Keep == [] ->
            bondy_db:apply(Table, Bucket, Key, clear);
        false ->
            bondy_db:apply(Table, Bucket, Key, {set, lists:sort(Keep)})
    end;
revoke_scoped(_, _, _Row, _ScopeRealmUri) ->
    ok.

%% @private
entry_has_realm({{Realm, _DeviceId}, _Claims}, ScopeRealmUri) ->
    Realm =:= ScopeRealmUri;
entry_has_realm(_Other, _ScopeRealmUri) ->
    %% The historical unkeyed form carries no list key to match on.
    false.

%% @private
%% The scope realm a MAP-valued cell's key names, if it names one.
key_scope_realm(EncKey) ->
    try decode_key(EncKey) of
        {_Authid, Uri, _} when is_binary(Uri) -> {ok, Uri};
        _ -> error
    catch
        _:_ -> error
    end.

%% @private
%% Every bucket a user's tickets can live in: the realm itself (where a local
%% user authenticates) and its SSO realm (where an SSO user does). Unlike
%% `revoke_all/1`, this path runs while the realm still exists, so the SSO realm
%% can be resolved.
ticket_buckets(RealmUri) ->
    case bondy_realm:lookup(RealmUri) of
        {ok, Realm} ->
            lists:usort([RealmUri, bondy_realm:auth_realm_uri(Realm)]);
        {error, _} ->
            [RealmUri]
    end.

%% @private
%% Shard by key means `term_to_binary/1` keys are not order-preserving, so
%% rather than a key-prefix range this scans the bucket and filters by the
%% decoded Authid (the first element of the composed store key). Revocation is a
%% cold path, so the O(bucket) scan is acceptable.
revoke_all_for(Table, Bucket, Authid) ->
    {ok, Rows} = bondy_db:list(Table, Bucket),
    _ = [
        bondy_db:apply(Table, Bucket, Key, clear)
     || {Key, _V, _Hlc} <- Rows, is_authid_key(Key, Authid)
    ],
    ok.

%% @private
%% The ticket buckets THIS node owns. `bondy_realm:auth_realm_uris/0` has
%% already collapsed each SSO realm's members onto one bucket, so filtering its
%% result decides ownership at the bucket grain — the only correct one.
owned_auth_realm_uris() ->
    lists:filter(fun bondy:is_owner/1, bondy_realm:auth_realm_uris()).

%% @private
%% One realm's cells. A failure is recorded and the sweep CONTINUES: one
%% unreadable realm must not abandon every other realm's reclamation.
cleanup_realm(RealmUri, Now, Stats0) ->
    Table = table(),

    try bondy_db:list(Table, RealmUri) of
        {ok, Rows} ->
            lists:foldl(
                fun(Row, Acc) ->
                    cleanup_cell(Table, RealmUri, Row, Now, Acc)
                end,
                Stats0,
                Rows
            );
        {error, Reason} ->
            add_error(Stats0, RealmUri, Reason)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description => "Error while cleaning up tickets",
                realm_uri => RealmUri,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            add_error(Stats0, RealmUri, Reason)
    end.

%% @private
%% A map-valued cell is ONE ticket (`client_id = all`); a list-valued cell is
%% one entry per device for a single (user, client). Both are keyed
%% `{Authid, _, _}`, so the user is recovered from the key rather than the
%% value — it is present even when every entry in the cell is expired.
cleanup_cell(Table, RealmUri, {Key, Claims, _Hlc}, Now, Stats0) when
    is_map(Claims)
->
    Stats = bump(Stats0, scanned, 1),

    case classify(Key, Claims, RealmUri, Now) of
        live ->
            Stats;
        Reason ->
            ok = bondy_db:apply(Table, RealmUri, Key, clear),
            bump(bump(Stats, Reason, 1), cells_cleared, 1)
    end;
cleanup_cell(Table, RealmUri, {Key, Entries, _Hlc}, Now, Stats0) when
    is_list(Entries)
->
    Stats1 = bump(Stats0, scanned, 1),

    case authid_of(Key) of
        {ok, Authid} ->
            IsActive = is_user_active(RealmUri, Authid),
            Live = [E || E <- Entries, entry_is_live(E, Now)],
            Dropped = length(Entries) - length(Live),

            case {IsActive, Live} of
                {false, _} ->
                    %% The user is gone: the whole cell goes, and every entry
                    %% counts as reclaimed for that reason rather than expiry.
                    ok = bondy_db:apply(Table, RealmUri, Key, clear),
                    Stats2 = bump(Stats1, deactivated, length(Entries)),
                    bump(Stats2, cells_cleared, 1);
                {true, []} ->
                    ok = bondy_db:apply(Table, RealmUri, Key, clear),
                    Stats2 = bump(Stats1, expired, Dropped),
                    bump(Stats2, cells_cleared, 1);
                {true, _} when Dropped > 0 ->
                    ok = bondy_db:apply(
                        Table, RealmUri, Key, {set, lists:sort(Live)}
                    ),
                    bump(Stats1, expired, Dropped);
                {true, _} ->
                    %% Untouched: never rewrite a cell we did not change, so a
                    %% concurrent issue on this node cannot be clobbered.
                    Stats1
            end;
        error ->
            Stats1
    end;
cleanup_cell(_, _, _Row, _Now, Stats) ->
    Stats.

%% @private
%% Why a single-ticket cell is reclaimable, or `live`. Expiry is checked first
%% so the stats attribute a ticket that is BOTH expired and orphaned to the
%% cheaper, more specific reason.
classify(Key, Claims, RealmUri, Now) ->
    case is_expired(Claims, Now) of
        true ->
            expired;
        false ->
            case authid_of(Key) of
                {ok, Authid} ->
                    case is_user_active(RealmUri, Authid) of
                        true -> live;
                        false -> deactivated
                    end;
                error ->
                    %% An undecodable key is left alone: it is not this
                    %% function's job to delete what it cannot read.
                    live
            end
    end.

%% @private
entry_is_live({_LKey, Claims}, Now) when is_map(Claims) ->
    not (is_map_key(expires_at, Claims) andalso is_expired(Claims, Now));
entry_is_live(_Other, _Now) ->
    %% An entry that is not a `{Key, Claims}` pair cannot be returned by
    %% `lookup/3`, and reclamation does not delete what it cannot interpret.
    true.

%% @private
%% The `Authid` a store key belongs to (its first element).
authid_of(EncKey) ->
    try decode_key(EncKey) of
        Key when is_tuple(Key), tuple_size(Key) >= 1 ->
            case element(1, Key) of
                Authid when is_binary(Authid) -> {ok, Authid};
                _ -> error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end.

%% @private
%% A ticket authenticates only while its user both exists and is enabled — the
%% pair `bondy_auth` applies on session establishment.
is_user_active(RealmUri, Authid) ->
    case bondy_rbac_user:lookup(RealmUri, Authid) of
        {ok, User} -> bondy_rbac_user:is_enabled(User);
        {error, _} -> false
    end.

%% @private
bump(Stats, _Key, 0) ->
    Stats;
bump(Stats, Key, N) ->
    maps:update_with(Key, fun(V) -> V + N end, N, Stats).

%% @private
add_error(#{errors := Errors} = Stats, RealmUri, Reason) ->
    Stats#{errors := [{RealmUri, Reason} | Errors]}.

%% @private
%% Lazy reclamation of the other devices' expired tickets, performed while we
%% are already rewriting this cell — the same shape as
%% `bondy_oauth_token_set:cleanup_and_truncate/3` on the token write paths.
%% Re-issuing for device A replaces only A's entry, so without this a device
%% that never comes back leaves its expired ticket in the cell forever.
%%
%% Pruning uses the same `is_expired/1` that `verify/1` rejects on, so storage
%% and authentication agree on exactly which tickets exist — an entry dropped
%% here could not have authenticated anyway.
%%
%% Pruning happens BEFORE the `keystore`, so the entry being written is never a
%% candidate, and only entries positively proven expired are dropped. An entry
%% that is not a `{Key, Claims}` pair is left in place: `lookup/3` cannot return
%% it either way, and dropping what cannot be interpreted is not this function's
%% decision to make.
prune_expired(Tickets) ->
    lists:filter(
        fun
            ({_, Claims}) when is_map(Claims) ->
                not (is_map_key(expires_at, Claims) andalso is_expired(Claims));
            (_) ->
                true
        end,
        Tickets
    ).

%% @private
expiry_time_secs(#{expiry_time_secs := Val}) when
    is_integer(Val) andalso Val > 0
->
    expiry_time_secs(Val);
expiry_time_secs(#{}) ->
    Default = bondy_config:get([security, ticket, expiry_time_secs]),
    expiry_time_secs(Default);
expiry_time_secs(Val) when is_integer(Val) ->
    Max = bondy_config:get([security, ticket, max_expiry_time_secs]),
    min(Val, Max).

%% @private
issuer(Authid, #{client_id := all}) ->
    Authid;
issuer(_, #{client_id := ClientId}) ->
    ClientId.

%% @private
allow_not_found(#{allow_not_found := Value}) ->
    Value;
allow_not_found(_) ->
    bondy_config:get([security, ticket, allow_not_found]).

%% @private
is_expired(Claims) ->
    is_expired(Claims, ?NOW).

%% @private
%% Explicit `Now` so a sweep judges every cell in a realm against ONE instant —
%% otherwise a long scan applies a drifting cutoff and is not reproducible.
is_expired(#{expires_at := Exp}, Now) ->
    Exp =< Now + ?LEEWAY_SECS.

%% @private
%% The open bondy_db `bondy_ticket` table handle. Raises if the catalogue has
%% not provisioned it — the table is a hard dependency (the catalogue, a
%% `bondy_sup` child, opens it at boot, well before any auth flow issues or
%% revokes a ticket).
table() ->
    case bondy_namespace_catalog:table(?BONDY_DB_TICKET_TAB) of
        undefined -> error(ticket_table_unavailable);
        Table -> Table
    end.

%% @private
%% The composed store key is a 3-tuple `{Authid, A, B}` of binaries; bondy_db
%% keys are binaries, so encode deterministically (the same tuple → the same
%% binary, so point lookups are stable).
encode_key(Key) when is_tuple(Key) ->
    term_to_binary(Key).

%% @private
%% Decode a store key written by `encode_key/1`. `[safe]` is sufficient — the
%% keys are tuples of binaries (no atoms / funs to construct).
decode_key(Bin) when is_binary(Bin) ->
    binary_to_term(Bin, [safe]).

%% @private
%% Whether an encoded store key belongs to `Authid` (its first tuple element).
is_authid_key(EncKey, Authid) ->
    case decode_key(EncKey) of
        {Authid, _, _} -> true;
        _ -> false
    end.
