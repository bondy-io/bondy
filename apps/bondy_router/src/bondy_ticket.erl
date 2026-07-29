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

Claims for a ticket are stored in PlumDB using the prefix
`{bondy_ticket, Suffix :: binary()}` where `Suffix` is the concatenation of the
authentication realm's URI and the user's username (a.k.a `authid`) and a key
which is derived by the ticket's scope. The scope itself is the result of the
combination of the different options provided by the `issue/2` function.

The decision to use this key as opposed to the ticket's unique identifier is so
that we are able to bound the number of tickets a user can have at any point in
time in order to reduce data storage and cluster replication traffic.

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
    }
}).

-type t() :: #{
    id := ticket_id(),
    authrealm := uri(),
    authid := authid(),
    authroles := [binary()],
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

-export([issue/2]).
-export([lookup/3]).
-export([remove_expired/0]).
-export([revoke/1]).
-export([revoke/3]).
-export([revoke_all/1]).
-export([revoke_all/2]).
-export([revoke_all/3]).
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

-spec verify(Ticket :: binary()) -> {ok, t()} | {error, expired | invalid}.

verify(Ticket) ->
    verify(Ticket, #{}).

-spec verify(Ticket :: binary(), Opts :: verify_opts()) ->
    {ok, t()} | {error, expired | invalid}.

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
            {error, Reason}
    end.

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
`RealmUri` should be the value of the ticket's `authrealm` claim.
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
Revokes all tickets issued to all users in realm `RealmUri`.
""".
-spec revoke_all(RealmUri :: uri()) -> ok.

revoke_all(RealmUri) when is_binary(RealmUri) ->
    Table = table(),
    {ok, Rows} = bondy_db:list(Table, RealmUri),
    _ = [
        bondy_db:apply(Table, RealmUri, Key, clear)
     || {Key, _V, _Hlc} <- Rows
    ],
    ok.

-doc """
Revokes all tickets issued to user with `Username` in realm `RealmUri`.
Notice that the ticket could have been issued by itself or by a client
application.
""".
-spec revoke_all(RealmUri :: uri(), Authid :: bondy_rbac_user:username()) ->
    ok.

revoke_all(RealmUri, Authid) ->
    %% The tickets for a user are distributed across all the shards because we
    %% shard by key, and `term_to_binary/1` keys are not order-preserving — so
    %% rather than a key-prefix range we scan the realm and filter by the
    %% decoded Authid (the first element of the composed store key). Revocation
    %% is a cold path, so the O(realm) scan is acceptable.
    Table = table(),
    {ok, Rows} = bondy_db:list(Table, RealmUri),
    _ = [
        bondy_db:apply(Table, RealmUri, Key, clear)
     || {Key, _V, _Hlc} <- Rows, is_authid_key(Key, Authid)
    ],
    ok.

-doc """
Revokes all tickets issued to user with `Username` in realm `RealmUri` matching
the scope `Scope`.
""".
-spec revoke_all(
    RealmUri :: uri(),
    Authid :: all | bondy_rbac_user:username(),
    Scope :: scope()
) -> ok.

revoke_all(_RealmUri, _Authid, _Scope) ->
    error(not_implemented).

remove_expired() ->
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

    AuthRealm = bondy_realm:fetch(AuthRealmUri),
    %% Pick the signing key atomically: keys are generated lazily, so the kid
    %% and its private key must come from the same (post-generation) realm.
    {Kid, PrivKey} = bondy_realm:get_random_private_key(AuthRealm),

    IssuedAt = ?NOW,
    ExpiresAt = IssuedAt + expiry_time_secs(Opts),

    Claims = #{
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
            %% TODO implement new Error standard
            error(#{
                code => invalid_value,
                description => <<
                    "The value for 'client_ticket' is not valid."
                >>,
                key => client_ticket,
                message => <<
                    "The value for 'client_ticket' is not either not a ticket,"
                    " it has an invalid signature or it is expired."
                >>
            })
    end;
scope(Session, Opts, Uri) ->
    Authid = bondy_session:authid(Session),
    ClientId = maps:get(client_id, Opts, all),
    InstanceId = maps:get(device_id, Opts, all),

    %% Throw exception if client is requesting a ticket issued to itself
    Authid =/= ClientId orelse throw(invalid_request),

    bondy_auth_scope:new(Uri, ClientId, InstanceId).

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

%% @private
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
        lists:keystore(Key, 1, Tickets, {Key, Claims})
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
is_expired(#{expires_at := Exp}) ->
    Exp =< ?NOW + ?LEEWAY_SECS.

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
