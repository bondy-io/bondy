-module(juno_oauth2).


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



-define(DEFAULT_TTL, 7200). %secs
-define(DEFAULT_REFRESH_TTL, 7200). %secs
-define(EXP_LEEWAY, 2*60). %secs

-export([issue_jwt/3]).
-export([issue_refresh_jwt/2]).
-export([verify_jwt/2]).
-export([verify_jwt/3]).
-export([decode_jwt/1]).
-export([refresh_jwt/1]).




%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec issue_jwt(binary(), binary(), [{any(), any()}]) -> {binary(), map()}.

issue_jwt(RealmUri, Username, Grants) ->
    Realm = juno_realm:fetch(RealmUri),
    Kid = juno_realm:get_random_kid(Realm),
    Key = juno_realm:get_private_key(Realm, Kid),
    Now = os:system_time(seconds),
    Exp = Now + ?DEFAULT_TTL,
    Scope = grants_to_scope(Grants),
    Claims = #{
        <<"exp">> => Exp,
        <<"iat">> => Now,
        <<"kid">> => Kid,
        <<"sub">> => Username,
        <<"iss">> => RealmUri,
        <<"aud">> => [RealmUri],
        <<"scope">> => Scope
    },
    JWT = sign(Key, Claims),
    ok = juno_cache:put(RealmUri, JWT, Claims ,#{exp => Exp}),
    {JWT, Claims}.


-spec issue_refresh_jwt(binary(), binary()) -> 
    {binary(), map()}.

issue_refresh_jwt(RealmUri, Username) ->
    Realm = juno_realm:fetch(RealmUri),
    Kid = juno_realm:get_random_kid(Realm),
    Key = juno_realm:get_private_key(Realm, Kid),
    Now = os:system_time(seconds),
    Exp = Now + ?DEFAULT_REFRESH_TTL,
    Claims = #{
        <<"exp">> => Exp,
        <<"iat">> => Now,
        <<"kid">> => Kid,
        <<"sub">> => Username,
        <<"iss">> => RealmUri,
        <<"aud">> => [RealmUri]
    },
    JWT = sign(Key, Claims),
    ok = juno_cache:put(RealmUri, JWT, Claims ,#{exp => Exp}),
    {JWT, Claims}.

%% -----------------------------------------------------------------------------
%% @doc
%% The JWT is expected to be valid, no validation will be performed on it.
%% @end
%% -----------------------------------------------------------------------------
refresh_jwt(JWT0) ->
    Claims = decode_jwt(JWT0),
    #{
        <<"kid">> := Kid,
        <<"sub">> := Username,
        <<"iss">> := RealmUri
    } = Claims,
    Realm = juno_realm:fetch(RealmUri),
    Key = juno_realm:get_private_key(Realm, Kid),
    %% Get latest grants
    Grants = juno_security:user_grants(RealmUri, Username),
    Exp = os:system_time(seconds) + ?DEFAULT_TTL,
    Claims1 = Claims#{
        <<"exp">> => Exp,
        <<"scope">> => grants_to_scope(Grants)
    },
    JWT1 = sign(Key, Claims1),
    ok = juno_cache:put(RealmUri, JWT1, Claims ,#{exp => Exp}),
    JWT1.



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
    {true, map()} | {expired, map()} | {false, map()}.

verify_jwt(RealmUri, JWT) ->
    verify_jwt(RealmUri, JWT, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec verify_jwt(binary(), binary(), map()) -> 
    {true, map()} | {expired, map()} | {false, map()}.

verify_jwt(RealmUri, JWT, Match0) ->
    Match1 = Match0#{<<"iss">> => RealmUri},

    Now = os:system_time(seconds) + ?EXP_LEEWAY,
    case juno_cache:get(RealmUri, JWT) of
        {ok, #{<<"exp">> := Exp} = Claims} when Exp =< Now ->
            ok = juno_cache:remove(JWT),
            {expired, Claims};
        {ok, Claims} ->
            matches(Claims, Match1);
        not_found ->
            do_verify_jwt(JWT, Match1, Now)
    end.




%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
sign(Key, Claims) ->
    Signed = jose_jwt:sign(Key, Claims),
    element(2, jose_jws:compact(Signed)).


-spec do_verify_jwt(binary(), map(), integer()) -> 
    {true, map()} | {expired, map()} | {false, map()}.

do_verify_jwt(JWT, Match, Now) ->     
    {jose_jwt, Map} = jose_jwt:peek(JWT),
    #{
        <<"iss">> := RealmUri,
        <<"kid">> := Kid
    } = Map,
    Realm = juno_realm:fetch(RealmUri),
    JWK = juno_realm:get_public_key(Realm, Kid),
    case jose_jwt:verify(JWK, JWT) of
        {true, {jose_jwt, #{<<"exp">> := Exp} = Claims}, _} when Exp =< Now ->         {expired, Claims};
        {true, {jose_jwt, Claims}, _} -> 
            matches(Claims, Match);
        {false, {jose_jwt, Claims}, _} -> 
            {false, Claims}
    end.


%% @private
matches(Claims, Match) ->
    Keys = maps:keys(Match),
    case maps_utils:collect(Keys, Claims) =:= maps_utils:collect(Keys, Match) of
        true -> {true, Claims};
        false -> {false, Claims}
    end.



%% @private
grants_to_scope(L) ->
    grants_to_scope(L, []).


grants_to_scope([], Scope) ->
    Scope;

grants_to_scope([{_K, _V}|_T], Scope) ->
    % TODO
    Scope.