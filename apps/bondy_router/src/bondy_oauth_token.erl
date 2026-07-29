%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oauth_token).

-moduledoc """

## Storage
Tokens are stored in the bondy_db `bondy_oauth_token` core table, bucketed by the authentication realm `RealmUri` (either the realm this user is connecting to or its associated SSO realm). The key is the sha256 hash of the user's username (`authid`); the value is the user's `bondy_oauth_token_set`, stored directly as a term in an `lww_register` cell (`clear` deletes). The catalogue (`bondy_namespace_catalog`) provisions the table.

Tokens are sharded by key. Cross-node replication awaits bondy_db anti-entropy (`db.aae`); until then storage is node-local.

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
%% Legacy-backup compatibility (bondy_export legacy import): a pre-existing
%% (plum_db-era) refresh token is a bare opaque string that the current,
%% self-describing token format cannot locate. On import we store a pointer from
%% that string to the imported token's `{key, id}` under a `legacy:`-prefixed key
%% in this same table (never read by the token-set paths). The first refresh that
%% presents the legacy string resolves it through the pointer, issues a current
%% token, and clears the pointer — so a legacy token works exactly once.
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
Issues a token.
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
Imports a single legacy (plum_db-era) refresh token, reconstructing a current
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
RFC: https://tools.ietf.org/html/rfc7009
The authorization server responds with HTTP status code 200 if the
token has been revoked successfully or if the client submitted an
invalid token.
Note: invalid tokens do not cause an error response since the client
cannot handle such an error in a reasonable way.  Moreover, the
purpose of the revocation request, invalidating the particular token,
is already achieved.
The content of the response body is ignored by the client as all
necessary information is conveyed in the response code.
An invalid token type hint value is ignored by the authorization
server and does not influence the revocation response.
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
Revokes all tokens issued to all users in realm `RealmUri`.
""".
-spec revoke_all(RealmUri :: uri()) -> ok.

revoke_all(RealmUri) when is_binary(RealmUri) ->
    try
        case get_authrealm_uri(RealmUri) of
            {ok, AuthRealmUri} ->
                Table = table(),
                {ok, Rows} = bondy_db:list(Table, AuthRealmUri),
                _ = [
                    bondy_db:apply(Table, AuthRealmUri, Key, clear)
                 || {Key, _Set, _Hlc} <- Rows
                ],
                ok;
            {error, _} ->
                ok
        end
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
""".
-spec to_access_token(t()) ->
    {ok, {JWT :: binary(), ExpiresIn :: pos_integer()}}.

to_access_token(#{type := ?MODULE, authrealm := RealmUri, kid := Kid} = T0) ->
    Realm = bondy_realm:fetch(RealmUri),
    PrivKey = bondy_realm:get_private_key(Realm, Kid),
    T = T0#{id => bondy_uuidv7:format(bondy_uuidv7:new())},
    to_access_token(T, PrivKey).

-doc """
""".
-spec to_refresh_token(t()) -> binary() | no_return().

to_refresh_token(#{type := ?MODULE, refresh_token := undefined}) ->
    error(bardag);
to_refresh_token(#{type := ?MODULE, refresh_token := Val}) ->
    Val.

-doc """
""".
-spec cleanup() -> map().

cleanup() ->
    Stats0 = #{
        errors => [],
        expired => 0,
        unused => 0,
        deactivated => 0
    },
    Stats1 = cleanup_expired_tokens(Stats0),
    Stats2 = cleanup_unused_tokens(Stats1),
    Stats = cleanup_deactivated_user_tokens(Stats2),
    ?LOG_INFO(#{
        description => "Finished cleaning up OAuth2 tokens",
        stats => Stats
    }),
    Stats.

id(#{type := ?MODULE, id := Val}) ->
    Val.

authid(#{type := ?MODULE, authid := Val}) ->
    Val.

authscope(#{type := ?MODULE, authscope := Val}) ->
    Val.

is_expired(#{type := ?MODULE} = T) ->
    is_expired(T, ?NOW).

is_expired(#{type := ?MODULE} = T, Now) ->
    expires_at(T) + ?LEEWAY_SECS =< Now.

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
check_authid(#{authid := AuthId}, RealmUri) ->
    Result = bondy_rbac_user:lookup(RealmUri, AuthId),
    {ok, _} = resulto:map_error(
        Result,
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
cleanup_expired_tokens(Stats0) ->
    %% TODO
    Stats0.

%% @private
cleanup_unused_tokens(Stats0) ->
    %% TODO
    Stats0.

cleanup_deactivated_user_tokens(Stats0) ->
    %% TODO
    Stats0.
