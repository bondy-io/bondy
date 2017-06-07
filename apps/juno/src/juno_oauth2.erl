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

-define(REFRESH_TOKEN_PREFIX(Realm, Issuer), 
    {<<Realm/binary, $., Issuer/binary>>, <<"refresh_tokens">>}
).

% -define(ACCESS_TOKEN, PREFIX(Realm, Issuer, Type), 
%     {<<Realm/binary, $., Issuer/binary>>, <<"access_tokens">>}
% ).

-record(juno_oauth2_token, {
    issuer                  ::  binary(), %% aka client_id or consumer_id
    username                ::  binary(),
    requested_grants        ::  list(),
    expires_in              ::  pos_integer(),
    issued_at               ::  pos_integer(),
    is_active = true        ::  boolean
}).


-define(REFRESH_TOKEN_LEN, 46).
-define(DEFAULT_TTL, 7200). % 2h
-define(DEFAULT_REFRESH_TTL, 86400). % 1d
-define(EXP_LEEWAY, 2*60). % 2m


-export([issue_token/4]).
-export([refresh_token/3]).
-export([revoke_token/3]).

-export([decode_jwt/1]).
-export([verify_jwt/2]).
-export([verify_jwt/3]).




%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec issue_token(juno_realm:uri(), binary(), binary(), [{any(), any()}]) -> 
    {ok, AccessToken :: binary(), RefreshToken :: binary(), Claims :: map()}
    | {error, any()}.

issue_token(RealmUri, Issuer, Username, Grants) ->    
    Data = #juno_oauth2_token{
        issuer = Issuer,
        username = Username,
        requested_grants = Grants
    },
    issue_token(RealmUri, Data).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec issue_token(juno_realm:uri(), #juno_oauth2_token{}) -> 
    {ok, AccessToken :: binary(), RefreshToken :: binary(), Claims :: map()}
    | {error, any()}.

issue_token(RealmUri, Data0) ->
   case juno_realm:fetch(RealmUri) of
       not_found ->
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
        #juno_oauth2_token{expires_in = Exp} when Exp =< Now ->
            {error, token_expired};
        #juno_oauth2_token{} = Data0 ->
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
        not_found ->
            {error, invalid_refresh_token}
    end.




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_token(
    juno_realm:uri(), Issuer :: binary(), RefreshToken :: binary()) -> any().

revoke_token(RealmUri, Issuer, RefreshToken) ->
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
    Match1 = Match0#{<<"aud">> => RealmUri},
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
do_issue_token(Realm, Data0) ->
    Uri = juno_realm:uri(Realm),
    #juno_oauth2_token{
        issuer = Issuer,
        username = Username,
        requested_grants = Grants
    } = Data0,
    Kid = juno_realm:get_random_kid(Realm),
    Key = juno_realm:get_private_key(Realm, Kid),
    Now = os:system_time(seconds),
    Exp = Now + ?DEFAULT_TTL,
    %% We generate and sign the JWT
    Scope = grants_to_scope(Grants),
    Claims = #{
        % <<"id">> => juno_utils:uuid(),
        <<"exp">> => Exp,
        <<"iat">> => Now,
        <<"kid">> => Kid,
        <<"sub">> => Username,
        <<"iss">> => Issuer,
        <<"aud">> => Uri,
        <<"scope">> => Scope
    },
    JWT = sign(Key, Claims),
    %% We generate and store the refresh token
    RefreshToken = generate_fragment(?REFRESH_TOKEN_LEN),
    Data1 = Data0#juno_oauth2_token{
        expires_in = Now + ?DEFAULT_REFRESH_TTL, 
        issued_at = Now
    },
    ok = plumtree_metadata:put(
        ?REFRESH_TOKEN_PREFIX(Uri, Issuer), RefreshToken, Data1),
    ok = juno_cache:put(Uri, JWT, Claims ,#{exp => Exp}),
    {ok, JWT, RefreshToken, Claims}.


%% @private
sign(Key, Claims) ->
    Signed = jose_jwt:sign(Key, Claims),
    element(2, jose_jws:compact(Signed)).


%% @private
-spec do_verify_jwt(binary(), map(), integer()) -> 
    {true, map()} | {expired, map()} | {false, map()}.

do_verify_jwt(JWT, Match, Now) ->     
    {jose_jwt, Map} = jose_jwt:peek(JWT),
    #{
        <<"aud">> := RealmUri,
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


%% @private
grants_to_scope([], Scope) ->
    Scope;

grants_to_scope([{_K, _V}|_T], Scope) ->
    % TODO
    Scope.


%% Borrowed from 
%% https://github.com/kivra/oauth2/blob/master/src/oauth2_token.erl
-spec generate_fragment(integer()) -> binary().
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