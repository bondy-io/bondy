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

-define(REFRESH_TOKEN_PREFIX(Realm, Issuer),
    {<<Realm/binary, $., Issuer/binary>>, <<"refresh_tokens">>}
).

% -define(ACCESS_TOKEN, PREFIX(Realm, Issuer, Type),
%     {<<Realm/binary, $., Issuer/binary>>, <<"access_tokens">>}
% ).

-record(bondy_oauth2_token, {
    issuer                  ::  binary(), %% aka client_id
    username                ::  binary(),
    groups = []             ::  [binary()],
    meta = #{}              ::  map(),
    expires_in              ::  pos_integer(),
    issued_at               ::  pos_integer(),
    is_active = true        ::  boolean
}).


-define(REFRESH_TOKEN_LEN, 46).
-define(DEFAULT_TTL, 900). % 15mins
-define(DEFAULT_REFRESH_TTL, 2592000). % 1month
-define(EXP_LEEWAY, 2*60). % 2mins

-type error()      ::   oauth2_invalid_grant | unknown_realm.

-export_type([error/0]).

-export([issue_token/5]).
-export([refresh_token/3]).
-export([revoke_token/3]).
-export([decode_jwt/1]).
-export([verify_jwt/2]).
-export([verify_jwt/3]).

-export([generate_fragment/1]).




%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec issue_token(
    bondy_realm:uri(), binary(), binary(), [binary()], map()) ->
    {ok, AccessToken :: binary(), RefreshToken :: binary(), Claims :: map()}
    | {error, any()}.

issue_token(RealmUri, Issuer, Username, Groups, Meta) ->
    Data = #bondy_oauth2_token{
        issuer = Issuer,
        username = Username,
        groups = Groups,
        meta = Meta
    },
    issue_token(RealmUri, Data).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec issue_token(bondy_realm:uri(), #bondy_oauth2_token{}) ->
    {ok, AccessToken :: binary(), RefreshToken :: binary(), Claims :: map()}
    | {error, any()}.

issue_token(RealmUri, Data0) ->
   case bondy_realm:lookup(RealmUri) of
        {error, not_found} ->
           {error, unknown_realm};
        Realm ->
            do_issue_token(Realm, Data0)
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% After refreshing a token, the previous refresh token will be revoked
%% @end
%% -----------------------------------------------------------------------------
refresh_token(RealmUri, Issuer, RefreshToken) ->
    Prefix = ?REFRESH_TOKEN_PREFIX(RealmUri, Issuer),
    Now = os:system_time(seconds) + ?EXP_LEEWAY,
    case plumtree_metadata:get(Prefix, RefreshToken) of
        #bondy_oauth2_token{issued_at = Ts, expires_in = Exp}
        when Ts + Exp =< Now ->
            {error, oauth2_invalid_grant};
        #bondy_oauth2_token{} = Data0 ->
            %% Issue new tokens
            %% TODO Refresh grants by querying the User data
            case issue_token(RealmUri, Data0) of
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
    bondy_realm:uri(), Issuer :: binary(), RefreshToken :: binary()) -> ok.

revoke_token(RealmUri, Issuer, RefreshToken) ->
    %% From https://tools.ietf.org/html/rfc7009#page-3
    %% The authorization server responds with HTTP status code
    %% 200 if the token has been revoked successfully or if the
    %% client submitted an invalid token.
    plumtree_metadata:delete(
        ?REFRESH_TOKEN_PREFIX(RealmUri, Issuer), RefreshToken).


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
    Now = os:system_time(seconds) + ?EXP_LEEWAY,
    case bondy_cache:get(RealmUri, JWT) of
        {ok, #{<<"iat">> := Ts, <<"exp">> := Exp}} when Ts + Exp =< Now ->
            ok = bondy_cache:remove(JWT),
            {error, oauth2_invalid_grant};
        {ok, Claims} ->
            matches(Claims, Match1);
        {error, not_found} ->
            do_verify_jwt(JWT, Match1, Now)
    end.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_issue_token(Realm, Data0) ->
    Uri = bondy_realm:uri(Realm),
    Kid = bondy_realm:get_random_kid(Realm),
    Key = bondy_realm:get_private_key(Realm, Kid),
    Now = os:system_time(seconds),
    Exp = ?DEFAULT_TTL,
    Iss = Data0#bondy_oauth2_token.issuer,
    %% We generate and sign the JWT
    Claims = #{
        <<"id">> => wamp_utils:rand_uniform(),
        <<"exp">> => Exp,
        <<"iat">> => Now,
        <<"kid">> => Kid,
        <<"sub">> => Data0#bondy_oauth2_token.username,
        <<"iss">> => Iss,
        <<"aud">> => Uri,
        <<"groups">> => Data0#bondy_oauth2_token.groups,
        <<"meta">> => Data0#bondy_oauth2_token.meta
    },
    JWT = sign(Key, Claims),
    %% We generate and store the refresh token
    RefreshToken = generate_fragment(?REFRESH_TOKEN_LEN),
    %% We create the refresh token data by cloning the access token
    %% and changing only the expires_in property
    Data1 = Data0#bondy_oauth2_token{
        expires_in = ?DEFAULT_REFRESH_TTL,
        issued_at = Now
    },
    ok = plumtree_metadata:put(
        ?REFRESH_TOKEN_PREFIX(Uri, Iss), RefreshToken, Data1),
    ok = bondy_cache:put(Uri, JWT, Claims ,#{exp => Now + Exp + ?EXP_LEEWAY}),
    {ok, JWT, RefreshToken, Claims}.


%% @private
sign(Key, Claims) ->
    Signed = jose_jwt:sign(Key, Claims),
    element(2, jose_jws:compact(Signed)).


%% @private
-spec do_verify_jwt(binary(), map(), integer()) ->
    {ok, map()} | {error, error()}.

do_verify_jwt(JWT, Match, Now) ->
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
                        {
                            true,
                            {jose_jwt, #{<<"iat">> := Ts, <<"exp">> := Exp}},
                            _
                        } when Ts + Exp =< Now ->
                            {error, oauth2_invalid_grant};
                        {true, {jose_jwt, Claims}, _} ->
                            matches(Claims, Match);
                        {false, {jose_jwt, _Claims}, _} ->
                            {error, oauth2_invalid_grant}
                    end
            end
    end.


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