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

-define(REFRESH_TOKENS_PREFIX(Realm, Issuer),
    {<<Realm/binary, $., Issuer/binary>>, <<"refresh_tokens">>}
).

-define(ISS_ACCESS_TOKENS_PREFIX(Realm, Issuer),
    {<<Realm/binary, $., Issuer/binary>>, <<"access_tokens">>}
).

-define(SUB_ACCESS_TOKENS_PREFIX(Realm, Sub),
    {<<Realm/binary, $., Sub/binary>>, <<"access_tokens">>}
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

-type grant_type()      ::   client_credentials | password | authorization_code.
-type error()           ::   oauth2_invalid_grant | unknown_realm.
-type token_type()      ::   access_token | refresh_token.

-export_type([error/0]).

-export([issue_token/6]).
-export([refresh_token/3]).
-export([revoke_token/4]).
-export([revoke_refresh_token/3]).
-export([revoke_access_token/3]).
-export([revoke_all_tokens/2]).
-export([decode_jwt/1]).
-export([verify_jwt/2]).
-export([verify_jwt/3]).

-export([generate_fragment/1]).




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
-spec issue_token(grant_type(), bondy_realm:uri(), #bondy_oauth2_token{}) ->
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
%% After refreshing a token, the previous refresh token will be revoked
%% @end
%% -----------------------------------------------------------------------------
refresh_token(RealmUri, Issuer, RefreshToken) ->
    Prefix = ?REFRESH_TOKENS_PREFIX(RealmUri, Issuer),
    Now = erlang:monotonic_time(seconds),
    case plumtree_metadata:get(Prefix, RefreshToken) of
        #bondy_oauth2_token{issued_at = Ts, expires_in = Secs}
        when ?EXPIRY_TIME_SECS(Ts, Secs) =< Now  ->
            %% The refresh token expired, the user will need to login again and
            %% get a new one
            {error, oauth2_invalid_grant};
        #bondy_oauth2_token{} = Data0 ->
            %% Issue new tokens
            %% TODO Refresh grants by querying the User data
            case issue_token(RealmUri, Data0, true) of
                {ok, _, _, _} = OK ->
                    %% We revoke the existing refresh token
                    ok = plumtree_metadata:delete(Prefix, RefreshToken),
                    OK;
                {error, _} = Error ->
                    Error
            end;
        undefined ->
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
    Token :: binary()) -> ok.

revoke_token(_Hint, RealmUri, Issuer, Token) ->
    Len = ?REFRESH_TOKEN_LEN,
    case byte_size(Token) =:= Len of
        true ->
            %% At the moment we do not use the provided Type Hint
            %% we decided based on token length
            revoke_refresh_token(RealmUri, Issuer, Token);
        false ->
            %% At the moment we do not use the provided Type Hint
            %% we decided based on token length
            revoke_access_token(RealmUri, Issuer, Token)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
revoke_refresh_token(RealmUri, Issuer, Token) ->
    %% From https://tools.ietf.org/html/rfc7009#page-3
    %% The authorization server responds with HTTP status code
    %% 200 if the token has been revoked successfully or if the
    %% client submitted an invalid token.
    plumtree_metadata:delete(?REFRESH_TOKENS_PREFIX(RealmUri, Issuer), Token).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_access_token(
    bondy_realm:uri(), Issuer :: binary(), JWT :: binary()) -> ok.

revoke_access_token(RealmUri, Issuer, JWT) ->
    %% From https://tools.ietf.org/html/rfc7009#page-3
    %% The authorization server responds with HTTP status code
    %% 200 if the token has been revoked successfully or if the
    %% client submitted an invalid token.
    plumtree_metadata:delete(
        ?REFRESH_TOKENS_PREFIX(RealmUri, Issuer), JWT).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
revoke_all_tokens(_RealmUri, _Username) ->
    error(not_implemented).


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
    Now = erlang:monotonic_time(seconds),
    Secs = ?PASSWORD_GRANT_TTL,

    %% We generate and sign the JWT
    Claims = #{
        <<"id">> => Id,
        <<"exp">> => Secs,
        <<"iat">> => Now,
        <<"kid">> => Kid,
        <<"sub">> => Sub,
        <<"iss">> => Iss,
        <<"aud">> => Uri,
        <<"groups">> => Data0#bondy_oauth2_token.groups,
        <<"meta">> => Data0#bondy_oauth2_token.meta
    },
    %% We create the JWT used as access token
    JWT = sign(Key, Claims),


    RefreshToken = maybe_issue_refresh_token(
        RefreshTokenFlag, Uri, Iss, Sub, Now, Data0),
    ok = bondy_cache:put(
        Uri, JWT, Claims ,#{exp => ?EXPIRY_TIME_SECS(Now, Secs)}),
    {ok, JWT, RefreshToken, Claims}.


%% @private
%% @TODO Commented to avoid breaking current apps, we will activate
%% this in next major release
maybe_issue_refresh_token(false, _, _, _, _, _) ->
    %% The client credentials flow should not return a refresh token
    undefined;

maybe_issue_refresh_token(true, Uri, Iss, Sub, IssuedAt, Data0) ->
    %% We create the refresh token data by cloning the access token
    %% and changing only the expires_in property
    RefreshToken = generate_fragment(?REFRESH_TOKEN_LEN),
    Data1 = Data0#bondy_oauth2_token{
        expires_in = ?REFRESH_TOKEN_TTL,
        issued_at = IssuedAt
    },
    %% We store various indices to be able to implement the revoke action with
    %% different arguments
    %% * {realm_uri(), issuer(), id()} -> #bondy_oauth2_token{} - to be able to
    %% implement
    %% * {realm_uri(), issuer(), refresh_token()} -> #bondy_oauth2_token{}  - to be able to implement
    %% refresh_token/3
    %% * {Realm, Iss, Sub} -> Id
    ok = plumtree_metadata:put(
        ?REFRESH_TOKENS_PREFIX(Uri, Iss), RefreshToken, Data1),
    ok = plumtree_metadata:put(
        ?ISS_ACCESS_TOKENS_PREFIX(Uri, Iss), RefreshToken, Data1),
    ok = plumtree_metadata:put(
        ?SUB_ACCESS_TOKENS_PREFIX(Uri, Sub), RefreshToken, Data1),
    RefreshToken.


%% @private
supports_refresh_token(client_credentials) -> false;
supports_refresh_token(application_code) -> false;
supports_refresh_token(password) -> false;
supports_refresh_token(Grant) -> error({oauth2_unsupported_grant_type, Grant}).


%% @private
sign(Key, Claims) ->
    Signed = jose_jwt:sign(Key, Claims),
    element(2, jose_jws:compact(Signed)).


%% @private
-spec do_verify_jwt(binary(), map()) ->
    {ok, map()} | {error, error()}.

do_verify_jwt(JWT, Match) ->
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
    end.


%% @private
maybe_cache({ok, Claims} = OK, JWT) ->
    #{<<"aud">> := RealmUri, <<"exp">> := Secs} = Claims,
    Now = erlang:monotonic_time(seconds),
    ok = bondy_cache:put(
        RealmUri, JWT, Claims ,#{exp => ?EXPIRY_TIME_SECS(Now, Secs)}),
    OK;

maybe_cache(Error, _) ->
    Error.


%% @private
maybe_expired({ok, #{<<"iat">> := Ts, <<"exp">> := Secs} = Claims}, JWT) ->
    Now = erlang:monotonic_time(seconds),
    case ?EXPIRY_TIME_SECS(Ts, Secs) =< Now of
        true ->
            ok = bondy_cache:remove(JWT),
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


%% Borrowed from
%% https://github.com/kivra/oauth2/blob/master/src/oauth2_token.erl
-spec generate_fragment(non_neg_integer()) -> binary().

generate_fragment(0) ->
    <<>>;

generate_fragment(N) ->
    Rand = base64:encode(crypto:strong_rand_bytes(N)),
    Frag = << <<C>> || <<C>> <= <<Rand:N/bytes>>, is_alphanum(C) >>,
    <<Frag/binary, (generate_fragment(N - byte_size(Frag)))/binary>>.


%% @doc Returns true for alphanumeric ASCII characters, false for all others.
-spec is_alphanum(char()) -> boolean().

is_alphanum(C) when C >= 16#30 andalso C =< 16#39 -> true;
is_alphanum(C) when C >= 16#41 andalso C =< 16#5A -> true;
is_alphanum(C) when C >= 16#61 andalso C =< 16#7A -> true;
is_alphanum(_)                                    -> false.


