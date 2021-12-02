%% =============================================================================
%%  bondy_oauth2.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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

%% -----------------------------------------------------------------------------
%% @doc
%%
%% The following table documents the storage layout in plum_db of the token
%% data and its indices:
%%
%% |Datum|Prefix|Key|Value|
%% |---|---|---|---|
%% |Refresh Token|{oauth2_refresh_tokens, Realm ++ "," ++ Issuer}|Token| TokenData|
%% |Refresh Token Index|{oauth2_refresh_tokens, Realm ++ "," ++ Issuer}|Token|Issuer|
%% |Refresh Token Index|{oauth2_refresh_tokens, Realm ++ "," ++ Issuer ++ "," ++ Username}|DeviceId| Token|
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_oauth2).

-include_lib("kernel/include/logger.hrl").
-include("bondy.hrl").

-define(FOLD_OPTS, [{resolver, lww}]).

-define(ENV, bondy_config:get(oauth2)).
-define(CLIENT_CREDENTIALS_GRANT_TTL,
    element(2, lists:keyfind(client_credentials_grant_duration, 1, ?ENV))
).
-define(CODE_GRANT_TTL,
    element(2, lists:keyfind(code_grant_duration, 1, ?ENV))
).
-define(PASSWORD_GRANT_TTL,
    element(2, lists:keyfind(password_grant_duration, 1, ?ENV))
).
-define(REFRESH_TOKEN_TTL,
    element(2, lists:keyfind(refresh_token_duration, 1, ?ENV))
).
-define(REFRESH_TOKEN_LEN,
    element(2, lists:keyfind(refresh_token_length, 1, ?ENV))
).

-define(NOW, erlang:system_time(second)).
-define(LEEWAY_SECS, 2 * 60). % 2 mins
-define(EXPIRY_TIME_SECS(Ts, Secs), Ts + Secs + ?LEEWAY_SECS).



-define(REFRESH_TOKENS_PREFIX(Realm, IssuerOrSub),
    {oauth2_refresh_tokens, <<Realm/binary, $,, IssuerOrSub/binary>>}
).

-define(REFRESH_TOKENS_PREFIX(Realm, Issuer, Sub),
    {oauth2_refresh_tokens,
        <<Realm/binary, $,, Issuer/binary, $,, Sub/binary>>}
).


-record(bondy_oauth2_token, {
    issuer                  ::  binary(), %% aka client_id
    username                ::  binary(),
    groups = []             ::  [binary()],
    meta = #{}              ::  map(),
    expires_in              ::  pos_integer(),
    issued_at               ::  pos_integer(),
    is_active = true        ::  boolean
}).


-type token_data()      ::  #bondy_oauth2_token{}.
-type grant_type()      ::  client_credentials | password | authorization_code.
-type error()           ::  oauth2_invalid_grant | no_such_realm.
-type token_type()      ::  access_token | refresh_token.

-export_type([error/0]).

-export([decode_jwt/1]).
-export([issue_token/6]).
-export([lookup_token/3]).
-export([refresh_token/3]).
-export([revoke_dangling_tokens/2]).
-export([rebuild_token_indices/2]).
-export([revoke_refresh_token/3]).
-export([revoke_refresh_token/4]).
-export([revoke_refresh_tokens/2]).
-export([revoke_refresh_tokens/3]).
-export([revoke_token/4]).
-export([revoke_token/5]).
-export([revoke_tokens/3]).
-export([revoke_tokens/4]).
-export([verify_jwt/2]).
-export([verify_jwt/3]).
-export([issuer/1]).
-export([issued_at/1]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Returns the issuer a.k.a. ClientId of the token data.
%% @end
%% -----------------------------------------------------------------------------
-spec issuer(TokenData :: token_data()) -> binary().

issuer(#bondy_oauth2_token{issuer = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the timestamp for the token data.
%% @end
%% -----------------------------------------------------------------------------
-spec issued_at(token_data()) -> pos_integer().

issued_at(#bondy_oauth2_token{issued_at = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Generates an access token and a refresh token.
%% The access token is a JWT whereas the refresh token is a binary.
%%
%% The function stores the refresh token in the store and creates a number of
%% store indices.
%% @end
%% -----------------------------------------------------------------------------
-spec issue_token(
    token_type(), bondy_realm:uri(), binary(), binary(), [binary()], map()) ->
    {ok, AccessToken :: binary(), RefreshToken :: binary(), Claims :: map()}
    | {error, any()}.

issue_token(GrantType, RealmUri, Issuer, Username, Groups, Meta) ->
    Data = #bondy_oauth2_token{
        issuer = string:casefold(Issuer),
        username = string:casefold(Username),
        groups = Groups,
        meta = Meta
    },
    issue_token(GrantType, RealmUri, Data).


%% -----------------------------------------------------------------------------
%% @doc Generates an access token and a refresh token.
%% The access token is a JWT whereas the refresh token is a binary.
%%
%% The function stores the refresh token in the store and creates a number of
%% store indices.
%% @end
%% -----------------------------------------------------------------------------
-spec issue_token(grant_type(), bondy_realm:uri(), token_data()) ->
    {ok, JWT :: binary(), RefreshToken :: binary(), Claims :: map()}
    | {error, any()}.

issue_token(GrantType, RealmUri, Data0) ->
   case bondy_realm:lookup(RealmUri) of
        {error, not_found} ->
           {error, no_such_realm};
        Realm ->
            do_issue_token(Realm, Data0, supports_refresh_token(GrantType))
    end.


%% -----------------------------------------------------------------------------
%% @doc Returns the data token_data() associated with `Token' or the tuple
%% `{error, not_found}'.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup_token(
    Realm :: bondy_realm:uri(), Issuer :: binary(), Token :: binary()) ->
    token_data() | {error, not_found}.

lookup_token(RealmUri, Issuer0, Token) ->
    Issuer = string:casefold(Issuer0),

    case plum_db:get(?REFRESH_TOKENS_PREFIX(RealmUri, Issuer), Token) of
        #bondy_oauth2_token{} = Data -> Data;
        undefined -> {error, not_found}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% After refreshing a token, the previous refresh token will be revoked
%% @end
%% -----------------------------------------------------------------------------
-spec refresh_token(
    Realm :: bondy_realm:uri(), Issuer :: binary(), Token :: binary()) ->
    {ok, AccessToken :: binary(), RefreshToken :: binary(), Claims :: map()}
    | {error, oauth2_invalid_grant}.

refresh_token(RealmUri, Issuer0, Token) ->
    Now = ?NOW,
    Secs = ?REFRESH_TOKEN_TTL,
    Issuer = string:casefold(Issuer0),

    case lookup_token(RealmUri, Issuer, Token) of
        #bondy_oauth2_token{issued_at = Ts}
        when ?EXPIRY_TIME_SECS(Ts, Secs) =< Now  ->
            %% The refresh token expired, the user will need to login again and
            %% get a new one
            {error, oauth2_invalid_grant};

        #bondy_oauth2_token{username = Username} = Data0 ->
            %% We double check the user still exists
            case bondy_rbac_user:lookup(RealmUri, Username) of
                {error, not_found} ->
                    ?LOG_WARNING(#{
                        description => "Removing dangling refresh_token",
                        refresh_token => Token,
                        realm_uri => RealmUri,
                        issuer => Issuer
                    }),
                    %% We remove all refresh tokens for this user
                    _ = revoke_tokens(refresh_token, RealmUri, Username),
                    {error, oauth2_invalid_grant};

                _ ->
                    %% Issue new tokens
                    %% We revoke the previous refresh token first because this
                    %% also deletes the client_device_id index,
                    %% if we do it later we would be deleting the new
                    %% client_device_id index
                    ok = revoke_refresh_token(RealmUri, Issuer, Token),

                    Realm = bondy_realm:fetch(RealmUri),

                    case do_issue_token(Realm, Data0, true) of
                        {ok, _, _, _} = OK ->
                            OK;
                        {error, _} = Error ->
                            Error
                    end
                end;

        {error, not_found} ->
            {error, oauth2_invalid_grant}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_token(
    Hint :: token_type() | undefined,
    bondy_realm:uri(),
    Issuer :: binary(),
    TokenOrUsername :: binary()) -> ok | {error, unsupported_operation}.

revoke_token(refresh_token, RealmUri, Issuer, Token) ->
    revoke_refresh_token(RealmUri, Issuer, Token);

revoke_token(access_token, _, _, _) ->
    {error, unsupported_operation}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_token(
    Hint :: token_type() | undefined,
    bondy_realm:uri(),
    Issuer :: binary(),
    Username :: binary(),
    DeviceId :: non_neg_integer()) -> ok | {error, unsupported_operation}.

revoke_token(refresh_token, RealmUri, Issuer, Username, DeviceId) ->
    revoke_refresh_token(RealmUri, Issuer, Username, DeviceId);

revoke_token(access_token, _, _, _, _) ->
    {error, unsupported_operation}.




%% -----------------------------------------------------------------------------
%% @doc Removes a refresh token from store using an index to match the function
%% arguments.
%% This also removes all store indices.
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_refresh_token(
    Realm :: bondy_realm:uri(),
    IssuerOrData :: binary() | token_data(),
    Token :: binary()) -> ok.

revoke_refresh_token(RealmUri, #bondy_oauth2_token{} = Data, Token) ->
    %% This case occurs when iterating over the ?REFRESH_TOKENS_PREFIX/2
    Issuer = Data#bondy_oauth2_token.issuer,
    revoke_refresh_token(RealmUri, Issuer, Token);

revoke_refresh_token(RealmUri, Issuer0, Token) ->
    Issuer = string:casefold(Issuer0),
    Prefix = ?REFRESH_TOKENS_PREFIX(RealmUri, Issuer),
    case plum_db:get(Prefix, Token) of
        undefined ->
            ok;
        Data ->
            do_revoke_refresh_token(RealmUri, Token, Data)
    end.


%% -----------------------------------------------------------------------------
%% @doc Removes a refresh token from store using an index to match the function
%% arguments.
%% This also removes all store indices.
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_refresh_token(
    bondy_realm:uri(),
    Issuer :: binary(),
    Username :: binary(),
    DeviceId :: binary()) -> ok.

revoke_refresh_token(RealmUri, Issuer0, Username, DeviceId) ->
    Issuer = string:casefold(Issuer0),
    UserPrefix = ?REFRESH_TOKENS_PREFIX(RealmUri, Issuer, Username),

    case plum_db:get(UserPrefix, DeviceId) of
        undefined ->
            ok;
        Token ->
            revoke_refresh_token(RealmUri, Issuer, Token)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_tokens(
    Hint :: token_type() | undefined,
    Realm :: bondy_realm:uri(),
    Username :: binary()) ->
        ok | {error, unsupported_operation}.

revoke_tokens(refresh_token, RealmUri, Username) ->
    revoke_refresh_tokens(RealmUri, Username);

revoke_tokens(access_token, _RealmUri, _Username) ->
    {error, unsupported_operation}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_tokens(
    Hint :: token_type() | undefined,
    bondy_realm:uri(),
    Issuer :: binary(),
    Username :: binary()) ->
        ok | {error, unsupported_operation}.

revoke_tokens(refresh_token, RealmUri, Issuer, Username) ->
    revoke_refresh_tokens(RealmUri, Issuer, Username);

revoke_tokens(access_token, _RealmUri, _Issuer, _Username) ->
    {error, unsupported_operation}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_refresh_tokens(bondy_realm:uri(), Username :: binary()) -> ok.

revoke_refresh_tokens(RealmUri, Username0) ->
    Username = string:casefold(Username0),

    AllPrefix = ?REFRESH_TOKENS_PREFIX(RealmUri, Username),
    Get = fun
        ({_, ?TOMBSTONE}, Acc) ->
            Acc;
        (Tuple, Acc) ->
            [Tuple | Acc]
    end,

    UserTokens = plum_db:fold(Get, [], AllPrefix, ?FOLD_OPTS),

    _ = [
        revoke_refresh_token(RealmUri, Issuer, Token)
        || {Token, Issuer} <- UserTokens
    ],
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_refresh_tokens(
    bondy_realm:uri(), Issuer :: binary(), Username :: binary()) -> ok.

revoke_refresh_tokens(RealmUri, Issuer0, Username0) ->
    Issuer = string:casefold(Issuer0),
    Username = string:casefold(Username0),

    Prefix = ?REFRESH_TOKENS_PREFIX(RealmUri, Issuer, Username),
    Get = fun
        ({_, ?TOMBSTONE}, Acc) ->
            Acc;
        ({DeviceId, Token}, Acc) ->
            [{DeviceId, Token} | Acc]
    end,
    DeviceTokens = plum_db:fold(Get, [], Prefix, ?FOLD_OPTS),

    _ = [
        revoke_refresh_token(RealmUri, Issuer, Token)
        || {_DeviceId, Token} <- DeviceTokens
    ],
    ok.


%% -----------------------------------------------------------------------------
%% @doc Removes all refresh tokens whose user has been removed.
%% This function is used for db maintenance.
%% @end
%% -----------------------------------------------------------------------------
revoke_dangling_tokens(RealmUri, Issuer0) ->
    Issuer = string:casefold(Issuer0),
    Prefix = ?REFRESH_TOKENS_PREFIX(RealmUri, Issuer),

    Fun = fun
        ({_, ?TOMBSTONE}) ->
            ok;
        ({Token, #bondy_oauth2_token{} = Data}) ->
            Username = Data#bondy_oauth2_token.username,
            case bondy_rbac_user:lookup(RealmUri, Username) of
                {error, not_found} ->
                    do_revoke_refresh_token(RealmUri, Token, Data);
                _ ->
                    ok
            end
    end,
    plum_db:foreach(Fun, Prefix, ?FOLD_OPTS).


%% -----------------------------------------------------------------------------
%% @doc Rebuilds refresh_token indices.
%% This function is used for db maintenance.
%% @end
%% -----------------------------------------------------------------------------
rebuild_token_indices(RealmUri, Issuer0) ->
    Issuer = string:casefold(Issuer0),
    Prefix = ?REFRESH_TOKENS_PREFIX(RealmUri, Issuer),

    Fun = fun
        ({_, ?TOMBSTONE}) ->
            ok;
        ({Token, #bondy_oauth2_token{issuer = Iss} = Data})
        when Iss == Issuer ->
            store_token_indices(RealmUri, Token, Data);
        ({Token, #bondy_oauth2_token{issuer = Iss}}) ->
            ?LOG_WARNING(#{
                description => "Found invalid token",
                token => Token,
                reason => issuer_mismatch,
                issuer => Iss
            }),
            ok
    end,
    plum_db:foreach(Fun, Prefix, ?FOLD_OPTS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec decode_jwt(binary()) -> map().

decode_jwt(JWT) ->
    {jose_jwt, Map} = jose_jwt:peek(JWT),
    Map.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec verify_jwt(binary(), binary()) -> {ok, map()} | {error, error()}.

verify_jwt(RealmUri, JWT) ->
    verify_jwt(RealmUri, JWT, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec verify_jwt(RealmUri :: binary(), JWTString :: binary(), MatchSpec :: map()) ->
    {ok, map()} | {error, error()}.

verify_jwt(RealmUri, JWTString, MatchSpec) ->

    case bondy_cache:get(RealmUri, JWTString) of
        {ok, Claims} ->
            %% We skip verification as we found the JWT
            maybe_expired(matches(RealmUri, Claims, MatchSpec), JWTString);
        {error, not_found} ->
            %% This JWT might still be valid i.e. created by another Bondy
            %% node and we have never received the broadcast,
            %% so we verify it and if valid we cache it
            Result = maybe_expired(
                do_verify_jwt(RealmUri, JWTString, MatchSpec), JWTString
            ),
            maybe_cache(Result, JWTString)
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_issue_token(Realm, Data0, RefreshTokenFlag) ->
    Id = wamp_utils:rand_uniform(),
    Uri = bondy_realm:uri(Realm),
    Kid = bondy_realm:get_random_kid(Realm),
    Key = bondy_realm:get_private_key(Realm, Kid),
    Iss = Data0#bondy_oauth2_token.issuer,
    Sub = Data0#bondy_oauth2_token.username,
    Meta = Data0#bondy_oauth2_token.meta,
    Now = ?NOW,
    Secs = ?PASSWORD_GRANT_TTL,

    %% We generate and sign the JWT
    %% TODO Refresh grants by querying the User data
    Claims = #{
        <<"id">> => Id,
        <<"exp">> => Secs,
        <<"iat">> => Now,
        <<"kid">> => Kid,
        <<"sub">> => Sub,
        <<"iss">> => Iss,
        <<"aud">> => Uri,
        <<"groups">> => Data0#bondy_oauth2_token.groups,
        <<"meta">> => Meta
    },
    %% We create the JWT used as access token
    AccessToken = sign(Key, Claims),
    RefreshToken = maybe_issue_refresh_token(RefreshTokenFlag, Uri, Now, Data0),
    ok = cache(Claims, AccessToken),
    {ok, AccessToken, RefreshToken, Claims}.


%% @private
%% @TODO Commented to avoid breaking current apps, we will activate
%% this in next major release
maybe_issue_refresh_token(false, _, _, _) ->
    %% The client credentials flow should not return a refresh token
    undefined;

maybe_issue_refresh_token(true, Uri, IssuedAt, Data0) ->
    %% We create the refresh token data by cloning the access token
    %% and changing only the expires_in property, so that the refresh_token
    %% acts as a template to create new access_token(s)
    Issuer = Data0#bondy_oauth2_token.issuer,
    Data1 = Data0#bondy_oauth2_token{
        expires_in = ?REFRESH_TOKEN_TTL,
        issued_at = IssuedAt
    },

    %% The refresh token representation as a string
    RefreshToken = bondy_utils:generate_fragment(?REFRESH_TOKEN_LEN),

    %% 1. We store the token under de Iss prefix
    ok = plum_db:put(?REFRESH_TOKENS_PREFIX(Uri, Issuer), RefreshToken, Data1),
    %% 2. We store the indices
    ok = store_token_indices(Uri, RefreshToken, Data1),
    RefreshToken.



store_token_indices(Uri, Token, #bondy_oauth2_token{} = Data) ->
    Issuer = Data#bondy_oauth2_token.issuer,
    Username = Data#bondy_oauth2_token.username,

    %% 2. An index to find all refresh tokens issued for a Username
    %% A Username can have many active tokens per Iss (on different DeviceIds)
    ok = case Issuer == Username of
        true ->
            ok;
        false ->
            plum_db:put(?REFRESH_TOKENS_PREFIX(Uri, Username), Token, Issuer)
    end,

    %% 2. We store an index to find the refresh token matching
    %% {Iss, Sub, DeviceId} or to iterate over all tokens for {Iss, Sub}
    ok = case client_device_id(Data) of
        undefined ->
            ok;
        DeviceId ->
            plum_db:put(
                ?REFRESH_TOKENS_PREFIX(Uri, Issuer, Username), DeviceId, Token)
    end.


%% @private
delete_token_indices(Uri, Token, #bondy_oauth2_token{} = Data) ->
    Issuer = Data#bondy_oauth2_token.issuer,
    Username = Data#bondy_oauth2_token.username,

    ok = case Issuer == Username of
        true ->
            ok;
        false ->
            plum_db:delete(?REFRESH_TOKENS_PREFIX(Uri, Username), Token)
    end,

    case client_device_id(Data) of
        undefined ->
            ok;
        DeviceId ->
            plum_db:delete(
                ?REFRESH_TOKENS_PREFIX(Uri, Issuer, Username), DeviceId)
    end.


%% -----------------------------------------------------------------------------
%% @doc Removes the refresh token from store.
%% This also removes all store indices for this refresh token.
%% @end
%% -----------------------------------------------------------------------------
-spec do_revoke_refresh_token(bondy_realm:uri(), binary(), token_data()) -> ok.

do_revoke_refresh_token(RealmUri, Token, #bondy_oauth2_token{} = Data) ->
    %% RFC: https://tools.ietf.org/html/rfc7009
    %% The authorization server responds with HTTP status code 200 if the
    %% token has been revoked successfully or if the client submitted an
    %% invalid token.
    %% Note: invalid tokens do not cause an error response since the client
    %% cannot handle such an error in a reasonable way.  Moreover, the
    %% purpose of the revocation request, invalidating the particular token,
    %% is already achieved.
    %% The content of the response body is ignored by the client as all
    %% necessary information is conveyed in the response code.
    %% An invalid token type hint value is ignored by the authorization
    %% server and does not influence the revocation response.

    Issuer = Data#bondy_oauth2_token.issuer,

    %% Delete token
    _ = plum_db:delete(?REFRESH_TOKENS_PREFIX(RealmUri, Issuer), Token),
    delete_token_indices(RealmUri, Token, Data).


%% @private
supports_refresh_token(client_credentials) -> false;
supports_refresh_token(application_code) -> true;
supports_refresh_token(password) -> true;
supports_refresh_token(Grant) -> error({oauth2_unsupported_grant_type, Grant}).


%% @private
sign(Key, Claims) ->
    Signed = jose_jwt:sign(Key, Claims),
    element(2, jose_jws:compact(Signed)).


%% @private
-spec do_verify_jwt(Realm :: binary(), binary(), map()) ->
    {ok, map()} | {error, error()}.

do_verify_jwt(RealmUri, JWT, Match) ->
    try
        {jose_jwt, Map} = jose_jwt:peek(JWT),
        #{
            <<"aud">> := JWTRealmUri,
            <<"kid">> := Kid
        } = Map,

        %% An early check, matches/3 will also check realm but we do it
        %% here to avoid verifying if we already know there will not be
        %% a match.
        JWTRealmUri == RealmUri orelse throw(oauth2_invalid_grant),

        %% We check the realm actualyy exists
        Realm = bondy_realm:fetch(RealmUri),

        %% Finally we try to verify the JWT
        case bondy_realm:get_public_key(Realm, Kid) of
            undefined ->
                {error, oauth2_invalid_grant};
            JWK ->
                case jose_jwt:verify(JWK, JWT) of
                    {true, {jose_jwt, Claims}, _} ->
                        matches(RealmUri, Claims, Match);
                    {false, {jose_jwt, _Claims}, _} ->
                        {error, oauth2_invalid_grant}
                end
        end
    catch
        throw:Reason ->
            {error, Reason};
        error:no_such_realm ->
            {error, no_such_realm};
        error:_ ->
            {error, oauth2_invalid_grant}
    end.


%% @private
maybe_cache({ok, Claims} = OK, AccessToken) when is_map(Claims) ->
    ok = cache(Claims, AccessToken),
    OK;

maybe_cache(Error, _) ->
    Error.


%% @private
cache(Claims, AccessToken) when is_map(Claims) ->
    #{<<"aud">> := RealmUri, <<"exp">> := Secs} = Claims,
    Opts = #{exp => ?EXPIRY_TIME_SECS(?NOW, Secs)},
    _ = bondy_cache:put(RealmUri, AccessToken, Claims, Opts),
    ok.


%% @private
maybe_expired({ok, #{<<"iat">> := Ts, <<"exp">> := Secs} = Claims}, _JWT) ->
    Now = ?NOW,
    case ?EXPIRY_TIME_SECS(Ts, Secs) =< Now of
        true ->
            %% ok = bondy_cache:remove(RealmUri, JWT),
            {error, oauth2_invalid_grant};
        false ->
            {ok, Claims}
    end;

maybe_expired(Error, _) ->
    Error.


%% @private
matches(RealmUri, Claims, Spec0) ->
    Spec1 = Spec0#{<<"aud">> => RealmUri},
    Keys = maps:keys(Spec1),

    case maps_utils:collect(Keys, Claims) =:= maps_utils:collect(Keys, Spec1) of
        true ->
            {ok, Claims};
        false ->
            {error, oauth2_invalid_grant}
    end.


%% @private
client_device_id(#bondy_oauth2_token{meta = Meta}) ->
    client_device_id(Meta);

client_device_id(#{<<"client_device_id">> := <<>>}) ->
    undefined;

client_device_id(#{<<"client_device_id">> := DeviceId}) ->
    DeviceId;

client_device_id(_) ->
    undefined.