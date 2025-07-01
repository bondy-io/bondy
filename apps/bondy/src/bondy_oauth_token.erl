%% =============================================================================
%%  bondy_oauth_token.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================


-module(bondy_oauth_token).

-moduledoc """

## Storage
Tokens are stored in PlumDB under prefix `{bondy_oauth_token, RealmUri}` where `RealmUri` is the authentication realm i.e. either the Realm this user is connecting to or its associated SSO realm. The key is the sha256 hash of the user's username i.e. `authid`.

Tokens are sharded by key and globally replicated to cluster peers.

""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_plum_db.hrl").
-include("bondy_security.hrl").

-define(VERSION, ~"1.1").

-define(NOW, erlang:system_time(second)).
-define(LEEWAY_SECS, 2 * 0). % 0 mins
-define(EXPIRY_TIME_SECS(Ts, Secs), Ts + Secs + ?LEEWAY_SECS).
-define(IS_GRANT_TYPE(X),
    (
        X == client_credentials orelse
        X == password orelse
        X == authorization_code
    )
).
%% TODO not supported yet

%% -define(CODE_GRANT_TTL,
%%     bondy_config:get([oauth2, code_grant_duration])
%% ).
-define(CLIENT_CREDENTIALS_GRANT_TTL,
    bondy_config:get([oauth2, client_credentials_grant_duration])
).
-define(PASSWORD_TOKEN_TTL, bondy_config:get([oauth2, password_grant_duration])).
-define(REFRESH_TOKEN_TTL, bondy_config:get([oauth2, refresh_token_duration])).
-define(REFRESH_TOKEN_LEN, bondy_config:get([oauth2, refresh_token_length])).
-define(MAX_TOKENS, bondy_config:get([oauth2, max_tokens_per_user])).
-define(DB_PREFIX(Uri), {?PLUM_DB_OAUTH_TOKEN_TAB, Uri}).
%% -define(DB_GET_OPTS, [{resolver, lww}, {allow_put, true}, {remove_tomstones, true}]).
-define(DB_PUT_OPTS, [{resolver, lww}]).
-define(DB_FOLD_OPTS, [{resolver, lww}]).

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

-type t()           ::  #{
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
-type token_id()    ::  binary().
-type opts()        ::  #{
                            client_id => binary(),
                            allow_sso =>  boolean(),
                            device_id => binary(),
                            expiry_time_secs => pos_integer(),
                            metadata => map()
                        }.
-type token_type()      ::  access | refresh.
-type grant_type()      ::  client_credentials | password | authorization_code.
-type issue_error()     ::  any().

-export_type([t/0]).
-export_type([id/0]).


-export([cleanup/0]).
-export([issue/3]).
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
    Opts :: opts()) ->
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
        %% Throw exception if client is requesting a token issued to itself
        AuthId =/= ClientId
            orelse GrantType == client_credentials
            orelse throw(invalid_request),

        AuthRealm = bondy_realm:fetch(AuthRealmUri),
        Kid = bondy_realm:get_random_kid(AuthRealm),
        DeviceId = maps:get(device_id, Opts, all),
        ScopeUri = case maps:get(allow_sso, Opts) of
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

        {TokenId, RToken} = case TokenType of
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
""".
-spec refresh(Realm :: bondy_realm:uri(), RefreshToken :: binary()) ->
    {ok, t()} | {error, oauth2_invalid_grant}.

refresh(RealmUri, RefreshToken)
when is_binary(RealmUri) andalso is_binary(RefreshToken) ->
    maybe
        {ok, AuthRealmUri} ?= get_authrealm_uri(RealmUri),
        {ok, Components} ?= bondy_oauth_refresh_token:parse(RefreshToken),
        {ok, {T, Set}} ?= find_in_set(AuthRealmUri, Components),
        ok ?= check_expired(T),
        {ok, _} ?= check_authid(T, AuthRealmUri),
        do_refresh(T, Set)

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
        {ok, Components} ?= bondy_oauth_refresh_token:parse(RefreshToken),
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
    Scope :: bondy_auth_scope:t()) ->
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
        {ok, Components} ?= bondy_oauth_refresh_token:parse(RefreshToken),
        {ok, {T, Set}} ?= find_in_set(AuthRealmUri, Components),
        do_revoke(T, Set)

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
                    Prefix = ?DB_PREFIX(AuthRealmUri),
                    Fun = fun({Key, _Set}) -> plum_db:delete(Prefix, Key) end,
                    %% We cannot use keys_only as it will currently ignore
                    %% remove_tombstones
                    Opts = [{remove_tombstones, true}, {resolver, lww}],
                    plum_db:foreach(Fun, Prefix, Opts);

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
                Prefix = ?DB_PREFIX(AuthRealmUri),
                Key = store_key(AuthId),
                plum_db:delete(Prefix, Key);

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
store_key(AuthId) ->
    base16:encode(crypto:hash(sha256, string:casefold(AuthId))).


%% @private
add_to_set(#{type := ?MODULE} = T) ->
    #{type := ?MODULE, authrealm := AuthRealmUri, authid := AuthId} = T,
    Prefix = ?DB_PREFIX(AuthRealmUri),
    Key = store_key(AuthId),

    try
        %% We have to update the set, so first we fetch it.
        Set0 = bondy_stdlib:lazy_or_else(
            plum_db:get(Prefix, Key),
            fun() -> bondy_oauth_token_set:new() end
        ),
        Set1 = bondy_oauth_token_set:add(Set0, T),
        {_Truncated, Set} = bondy_oauth_token_set:truncate(Set1, ?MAX_TOKENS),
        ok = plum_db:put(Prefix, Key, Set, ?DB_PUT_OPTS)

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
    Prefix = ?DB_PREFIX(RealmUri),

    case plum_db:get(Prefix, Key) of
        undefined ->
            {error, not_found};

        Set when is_map(Set) ->
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
    Prefix = ?DB_PREFIX(RealmUri),
    Key = store_key(AuthId),

    case plum_db:get(Prefix, Key) of
        undefined ->
            {error, not_found};

        Set when TokenId == undefined ->
            Result = bondy_oauth_token_set:find(Set, Scope),
            resulto:map(Result, fun(Token) -> {Token, Set} end);

        Set ->
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

    Prefix = ?DB_PREFIX(AuthRealmUri),
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
        ok = plum_db:put(Prefix, Key, Set, ?DB_PUT_OPTS),
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

    Prefix = ?DB_PREFIX(AuthRealmUri),
    Key = store_key(AuthId),

    try
        Set1 = bondy_oauth_token_set:remove(Set0, Scope, TokenId0),
        {_Removed, Set} = bondy_oauth_token_set:cleanup_and_truncate(
            Set1, ?MAX_TOKENS, Now
        ),
        ok = plum_db:put(Prefix, Key, Set, ?DB_PUT_OPTS),
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
