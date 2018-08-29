%% =============================================================================
%%  bondy_oauth2.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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


-module(bondy_oauth2).

% -record(oauth2_credentials, {
%     id                  ::  binary(),
%     consumer_id         ::  binary(),
%     name                ::  binary(),
%     client_id           ::  binary(),
%     client_secret       ::  binary(),
%     redirect_uri        ::  binary(),
%     created_at          ::  binary()
% }).

% -record(oauth2_auth_codes, {
%     id                      ::  binary(),
%     api_id                  ::  binary(),
%     code                    ::  binary(),
%     authenticated_userid    ::  binary(),
%     scope                   ::  binary(),
%     created_at              ::  binary()
% }).

% -record(jwt, {
%     id                      ::  binary(),
%     created_at              ::  binary(),
%     consumer_id             ::  binary(),
%     key                     ::  binary(),
%     secret                  ::  binary(),
%     rsa_public_key          ::  binary(),
%     algorithm               ::  binary() %% HS256 RS256 ES256
% }).
-define(FOLD_OPTS, [{resolver, lww}]).
-define(TOMBSTONE, '$deleted').

-define(ENV, element(2, application:get_env(bondy, oauth2))).
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
-define(LEEWAY_SECS, 2*60). % 2mins

-define(EXPIRY_TIME_SECS(Ts, Secs), Ts + Secs + ?LEEWAY_SECS).


%% * {{Realm ++ . ++ Issuer, "refresh_tokens"}, RefreshToken} ->
%% #bondy_oauth2_token{}
%% * {{Realm ++ . ++ Issuer, "refresh_tokens"}, Sub} ->
%% #bondy_oauth2_token{}
-define(REFRESH_TOKENS_PREFIX(Realm, IssuerOrSub),
    {<<Realm/binary, $., IssuerOrSub/binary>>, <<"refresh_tokens">>}
).

-define(REFRESH_TOKENS_PREFIX(Realm, Issuer, Sub),
    {<<Realm/binary, $., Issuer/binary, $., Sub/binary>>, <<"refresh_tokens">>}
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

-type token()           ::  #bondy_oauth2_token{}.
-type grant_type()      ::  client_credentials | password | authorization_code.
-type error()           ::  oauth2_invalid_grant | unknown_realm.
-type token_type()      ::  access_token | refresh_token.

-export_type([error/0]).

-export([issue_token/6]).
-export([refresh_token/3]).
-export([lookup_token/3]).
-export([revoke_token/4]).
-export([revoke_token/5]).
-export([revoke_refresh_token/2]).
-export([revoke_refresh_token/3]).
-export([revoke_refresh_token/4]).
-export([revoke_tokens/4]).
-export([revoke_refresh_tokens/2]).
-export([revoke_refresh_tokens/3]).
-export([decode_jwt/1]).
-export([verify_jwt/2]).
-export([verify_jwt/3]).




%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% Generates an access token and a refresh token. The access token is a JWT
%% whereas the refresh token is a binary.
%% The function stores the refresh token in the store.
%% @end
%% -----------------------------------------------------------------------------
-spec issue_token(
    token_type(), bondy_realm:uri(), binary(), binary(), [binary()], map()) ->
    {ok, AccessToken :: binary(), RefreshToken :: binary(), Claims :: map()}
    | {error, any()}.

issue_token(GrantType, RealmUri, Issuer, Username, Groups, Meta) ->
    Data = #bondy_oauth2_token{
        issuer = Issuer,
        username = Username,
        groups = Groups,
        meta = Meta
    },
    issue_token(GrantType, RealmUri, Data).


%% -----------------------------------------------------------------------------
%% @doc
%% Generates an access token and a refresh token. The access token is a JWT
%% whereas the refresh token is a binary.
%% The function stores the refresh token in the store.
%% @end
%% -----------------------------------------------------------------------------
-spec issue_token(grant_type(), bondy_realm:uri(), token()) ->
    {ok, AccessToken :: binary(), RefreshToken :: binary(), Claims :: map()}
    | {error, any()}.

issue_token(GrantType, RealmUri, Data0) ->
   case bondy_realm:lookup(RealmUri) of
        {error, not_found} ->
           {error, unknown_realm};
        Realm ->
            do_issue_token(Realm, Data0, supports_refresh_token(GrantType))
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
lookup_token(RealmUri, Issuer, Token) ->
    case plum_db:get(?REFRESH_TOKENS_PREFIX(RealmUri, Issuer), Token) of
        #bondy_oauth2_token{} = Data -> Data;
        undefined -> {error, not_found}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% After refreshing a token, the previous refresh token will be revoked
%% @end
%% -----------------------------------------------------------------------------
refresh_token(RealmUri, Issuer, Token) ->
    Now = erlang:system_time(seconds),
    Secs = ?REFRESH_TOKEN_TTL,
    case lookup_token(RealmUri, Issuer, Token) of
        #bondy_oauth2_token{issued_at = Ts}
        when ?EXPIRY_TIME_SECS(Ts, Secs) =< Now  ->
            %% The refresh token expired, the user will need to login again and
            %% get a new one
            {error, oauth2_invalid_grant};
        #bondy_oauth2_token{username = Username} = Data0 ->
            %% We double check the user still exists
            case bondy_security_user:lookup(RealmUri, Username) of
                {error, not_found} ->
                    _ = lager:warning(
                        "Removing dangling refresh_token; "
                        "refresh_token=~p, "
                        "realm_uri=~p, ",
                        "issuer=~p",
                        [Token, RealmUri, Issuer]
                    ),
                    _ = revoke_tokens(refresh_token, RealmUri, Username),
                    {error, oauth2_invalid_grant};
                _ ->
                    %% Issue new tokens
                    case
                        do_issue_token(bondy_realm:fetch(RealmUri), Data0, true)
                    of
                        {ok, _, _, _} = OK ->
                            %% We revoke the prev refresh token
                            ok = revoke_refresh_token(RealmUri, Issuer, Token),
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
%% @doc Removes the refresh token from store.
%% This also removes all store indices.
%% @end
%% -----------------------------------------------------------------------------
revoke_refresh_token(RealmUri, #bondy_oauth2_token{} = Token) ->
    Issuer = Token#bondy_oauth2_token.issuer,
    Username = Token#bondy_oauth2_token.username,
    Meta = Token#bondy_oauth2_token.meta,

    %% Delete token
    _ = plum_db:delete(?REFRESH_TOKENS_PREFIX(RealmUri, Issuer), Token),

    %% Delete indices
    _ = plum_db:delete(
        ?REFRESH_TOKENS_PREFIX(RealmUri, Username), Issuer),

    case maps:get(<<"client_device_id">>, Meta, <<>>) of
        <<>> ->
            ok;
        DeviceId ->
            plum_db:delete(
                ?REFRESH_TOKENS_PREFIX(RealmUri, Issuer, Username),
                DeviceId
            )
    end.


%% -----------------------------------------------------------------------------
%% @doc Removes a refresh token from store using an index to match the function
%% arguments.
%% This also removes all store indices.
%% @end
%% -----------------------------------------------------------------------------
revoke_refresh_token(RealmUri, Issuer, Token) ->
    Prefix = ?REFRESH_TOKENS_PREFIX(RealmUri, Issuer),
    case plum_db:get(Prefix, Token) of
        undefined ->
            undefined;
        Data ->
            revoke_refresh_token(RealmUri, Data)
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
    DeviceId :: binary()) -> ok | {error, oauth2_invalid_grant}.
revoke_refresh_token(RealmUri, Issuer, Username, DeviceId) ->
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
    bondy_realm:uri(),
    Username :: binary()) ->
        ok | {error, unsupported_operation | oauth2_invalid_grant}.

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
        ok | {error, unsupported_operation | oauth2_invalid_grant}.

revoke_tokens(refresh_token, RealmUri, Issuer, Username) ->
    revoke_refresh_tokens(RealmUri, Issuer, Username);

revoke_tokens(access_token, _RealmUri, _Issuer, _Username) ->
    {error, unsupported_operation}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_refresh_tokens(bondy_realm:uri(), Username :: binary()) ->
    ok | {error, oauth2_invalid_grant}.
revoke_refresh_tokens(RealmUri, Username) ->
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
        || {Issuer, Token} <- UserTokens
    ],
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_refresh_tokens(
    bondy_realm:uri(), Issuer :: binary(), Username :: binary()) ->
    ok | {error, oauth2_invalid_grant}.
revoke_refresh_tokens(RealmUri, Issuer, Username) ->
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
-spec verify_jwt(binary(), binary()) ->
    {ok, map()} | {error, error()}.

verify_jwt(RealmUri, JWT) ->
    verify_jwt(RealmUri, JWT, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec verify_jwt(binary(), binary(), map()) ->
    {ok, map()} | {error, error()}.

verify_jwt(RealmUri, JWT, Match0) ->
    Match1 = Match0#{<<"aud">> => RealmUri},
    case bondy_cache:get(RealmUri, JWT) of
        {ok, Claims} ->
            %% We skip verification as we found the JWT
            maybe_expired(matches(Claims, Match1), JWT);
        {error, not_found} ->
            %% We do verify the JWT and if valid we cache it
            maybe_cache(maybe_expired(do_verify_jwt(JWT, Match1), JWT), JWT)
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
    Now = erlang:system_time(seconds),
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
    JWT = sign(Key, Claims),
    RefreshToken = maybe_issue_refresh_token(RefreshTokenFlag, Uri, Now, Data0),
    ok = bondy_cache:put(
        Uri, JWT, Claims , #{exp => ?EXPIRY_TIME_SECS(Now, Secs)}),
    {ok, JWT, RefreshToken, Claims}.


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
    Iss = Data0#bondy_oauth2_token.issuer,
    Sub = Data0#bondy_oauth2_token.username,
    Meta = Data0#bondy_oauth2_token.meta,
    Data1 = Data0#bondy_oauth2_token{
        expires_in = ?REFRESH_TOKEN_TTL,
        issued_at = IssuedAt
    },

    %% The refresh token representation as a string
    Token = bondy_utils:generate_fragment(?REFRESH_TOKEN_LEN),

    %% We store the token under de Iss prefix
    ok = plum_db:put(?REFRESH_TOKENS_PREFIX(Uri, Iss), Token, Data1),

    %% We store various indices to be able to implement the revoke actions
    %% 1. An index to find all refresh tokens issued for Sub
    %% A Sub (user) can have one active token per Iss
    ok = plum_db:put(?REFRESH_TOKENS_PREFIX(Uri, Sub), Iss, Token),
    %% 2. An index to find the refresh token matching {Iss, Sub, DeviceId}
    ok = case maps:get(<<"client_device_id">>, Meta, undefined) of
        undefined ->
            ok;
        <<>> ->
            ok;
        DeviceId ->
            plum_db:put(
                ?REFRESH_TOKENS_PREFIX(Uri, Iss, Sub), DeviceId, Token)
    end,

    Token.


%% @private
supports_refresh_token(client_credentials) -> true; %% should be false
supports_refresh_token(application_code) -> true;
supports_refresh_token(password) -> true;
supports_refresh_token(Grant) -> error({oauth2_unsupported_grant_type, Grant}).


%% @private
sign(Key, Claims) ->
    Signed = jose_jwt:sign(Key, Claims),
    element(2, jose_jws:compact(Signed)).


%% @private
-spec do_verify_jwt(binary(), map()) ->
    {ok, map()} | {error, error()}.

do_verify_jwt(JWT, Match) ->
    try
        {jose_jwt, Map} = jose_jwt:peek(JWT),
        #{
            <<"aud">> := RealmUri,
            <<"kid">> := Kid
        } = Map,
        case bondy_realm:lookup(RealmUri) of
            {error, not_found} ->
                {error, unknown_realm};
            Realm ->
                case bondy_realm:get_public_key(Realm, Kid) of
                    undefined ->
                        {error, oauth2_invalid_grant};
                    JWK ->
                        case jose_jwt:verify(JWK, JWT) of
                            {true, {jose_jwt, Claims}, _} ->
                                matches(Claims, Match);
                            {false, {jose_jwt, _Claims}, _} ->
                                {error, oauth2_invalid_grant}
                        end
                end
        end
    catch
        error:_ ->
            {error, oauth2_invalid_grant}
    end.


%% @private
maybe_cache({ok, Claims} = OK, JWT) ->
    #{<<"aud">> := RealmUri, <<"exp">> := Secs} = Claims,
    Now = erlang:system_time(seconds),
    ok = bondy_cache:put(
        RealmUri, JWT, Claims , #{exp => ?EXPIRY_TIME_SECS(Now, Secs)}),
    OK;

maybe_cache(Error, _) ->
    Error.


%% @private
maybe_expired({ok, #{<<"iat">> := Ts, <<"exp">> := Secs} = Claims}, _JWT) ->
    Now = erlang:system_time(seconds),
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
matches(Claims, Match) ->
    Keys = maps:keys(Match),
    case maps_utils:collect(Keys, Claims) =:= maps_utils:collect(Keys, Match) of
        true ->
            {ok, Claims};
        false ->
            {error, oauth2_invalid_grant}
    end.



