%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_oidc_handler).
-moduledoc """
Cowboy handler for OIDC login, callback, and logout endpoints.

Dispatches on the `action` key in the handler state:
- `login`    — redirects to the IdP's authorization endpoint
- `callback` — exchanges the auth code for tokens, mints a bondy_ticket, sets
               a cookie, and redirects to the SPA
- `logout`   — revokes the bondy_ticket and clears the cookie
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("oidcc/include/oidcc_token.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").
-include("http_api.hrl").


-export([init/2]).


%% Default post-login redirect
-define(DEFAULT_REDIRECT, <<"/">>).



%% =============================================================================
%% COWBOY CALLBACKS
%% =============================================================================



init(Req0, State) ->
    Req = cowboy_req:set_resp_headers(cors_headers(Req0), Req0),
    case cowboy_req:method(Req) of
        <<"OPTIONS">> ->
            Req1 = cowboy_req:reply(?HTTP_OK, #{}, <<>>, Req),
            {ok, Req1, State};
        _ ->
            dispatch(Req, State)
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
dispatch(Req, #{action := login} = State) ->
    handle_login(Req, State);

dispatch(Req, #{action := callback} = State) ->
    handle_callback(Req, State);

dispatch(Req, #{action := logout} = State) ->
    handle_logout(Req, State).



%% @private
handle_login(Req0, #{realm_uri := RealmUri} = State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            do_handle_login(Req0, State, RealmUri);
        _ ->
            Req1 = cowboy_req:reply(?HTTP_METHOD_NOT_ALLOWED, #{}, <<>>, Req0),
            {ok, Req1, State}
    end.


%% @private
do_handle_login(Req0, State, RealmUri) ->
    Provider = provider_name(Req0, State),

    case bondy_oidc_provider:get_provider_config(RealmUri, Provider) of
        {ok, Config} ->
            do_login_redirect(Req0, State, RealmUri, Provider, Config);
        {error, not_found} ->
            Req1 = reply_json_error(
                ?HTTP_NOT_FOUND, <<"unknown_provider">>, Req0
            ),
            {ok, Req1, State}
    end.


%% @private
do_login_redirect(Req0, State, RealmUri, Provider, Config) ->
    StateToken = bondy_utils:uuid(),
    Nonce = bondy_utils:uuid(),
    CodeVerifier = base64:encode(crypto:strong_rand_bytes(32), #{
        mode => urlsafe, padding => false
    }),

    #{redirect_uri := RedirectUri} = Config,

    %% Store state for the callback
    QsVals0 = cowboy_req:parse_qs(Req0),
    SpaRedirect = proplists:get_value(
        <<"redirect_uri">>, QsVals0, ?DEFAULT_REDIRECT
    ),
    ClientId = proplists:get_value(
        <<"client_id">>, QsVals0, <<"all">>
    ),
    DeviceId = proplists:get_value(
        <<"device_id">>, QsVals0, <<"all">>
    ),
    ok = bondy_oidc_state:new(
        StateToken, Nonce, CodeVerifier, Provider, RealmUri, SpaRedirect,
        ClientId, DeviceId
    ),

    %% Get client context and create redirect URL
    case bondy_oidc_provider:get_client_context(RealmUri, Provider) of
        {ok, ClientCtx} ->
            Scopes = maps:get(scopes, Config, [<<"openid">>]),
            AuthOpts = #{
                redirect_uri => RedirectUri,
                state => StateToken,
                nonce => Nonce,
                pkce_verifier => CodeVerifier,
                scopes => Scopes,
                request_opts => bondy_oidc_provider:request_opts(Config)
            },

            case oidcc_authorization:create_redirect_url(ClientCtx, AuthOpts) of
                {ok, AuthUrl} ->
                    AuthUrlBin = iolist_to_binary(AuthUrl),
                    Req1 = cowboy_req:reply(
                        302,
                        #{<<"location">> => AuthUrlBin},
                        <<>>,
                        Req0
                    ),
                    {ok, Req1, State};
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        description => "Failed to create OIDC redirect URL",
                        realm_uri => RealmUri,
                        provider => Provider,
                        redirect_uri => RedirectUri,
                        reason => Reason
                    }),
                    Req1 = reply_json_error(
                        ?HTTP_INTERNAL_SERVER_ERROR,
                        <<"authorization_url_failed">>,
                        Req0
                    ),
                    {ok, Req1, State}
            end;
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Failed to get OIDC client context",
                realm_uri => RealmUri,
                provider => Provider,
                reason => Reason
            }),
            Req1 = reply_json_error(
                ?HTTP_INTERNAL_SERVER_ERROR,
                <<"provider_unavailable">>,
                Req0
            ),
            {ok, Req1, State}
    end.


%% @private
handle_callback(Req0, #{realm_uri := RealmUri} = State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            do_handle_callback(Req0, State, RealmUri);
        _ ->
            Req1 = cowboy_req:reply(?HTTP_METHOD_NOT_ALLOWED, #{}, <<>>, Req0),
            {ok, Req1, State}
    end.


%% @private
do_handle_callback(Req0, State, RealmUri) ->
    QsVals = cowboy_req:parse_qs(Req0),

    Code = proplists:get_value(<<"code">>, QsVals),
    StateToken = proplists:get_value(<<"state">>, QsVals),

    case is_binary(Code) andalso is_binary(StateToken) of
        false ->
            Req1 = reply_json_error(
                ?HTTP_BAD_REQUEST, <<"missing_code_or_state">>, Req0
            ),
            {ok, Req1, State};
        true ->
            do_validate_state(Req0, State, RealmUri, Code, StateToken)
    end.


%% @private
do_validate_state(Req0, State, RealmUri, Code, StateToken) ->
    case bondy_oidc_state:take(StateToken) of
        {ok, #{
            nonce := Nonce,
            code_verifier := CodeVerifier,
            provider_name := Provider,
            realm_uri := StoredRealmUri,
            redirect_uri := SpaRedirect,
            client_id := ClientId,
            device_id := DeviceId
        }} when StoredRealmUri == RealmUri ->
            TicketScope = #{client_id => ClientId, device_id => DeviceId},
            do_exchange_code(
                Req0, State, RealmUri, Provider,
                Code, Nonce, CodeVerifier, SpaRedirect, TicketScope
            );
        {ok, _} ->
            Req1 = reply_json_error(
                ?HTTP_BAD_REQUEST, <<"realm_mismatch">>, Req0
            ),
            {ok, Req1, State};
        {error, not_found} ->
            Req1 = reply_json_error(
                ?HTTP_BAD_REQUEST, <<"invalid_state">>, Req0
            ),
            {ok, Req1, State};
        {error, expired} ->
            Req1 = reply_json_error(
                ?HTTP_BAD_REQUEST, <<"state_expired">>, Req0
            ),
            {ok, Req1, State}
    end.


%% @private
do_exchange_code(
    Req0, State, RealmUri, Provider,
    Code, Nonce, CodeVerifier, SpaRedirect, TicketScope
) ->
    case bondy_oidc_provider:get_provider_config(RealmUri, Provider) of
        {ok, Config} ->
            case bondy_oidc_provider:get_client_context(RealmUri, Provider) of
                {ok, ClientCtx} ->
                    #{redirect_uri := RedirectUri} = Config,
                    RefreshJwks = case bondy_oidc_provider:get_refresh_jwks_fun(
                        RealmUri, Provider
                    ) of
                        {ok, Fun} -> Fun;
                        {error, _} -> undefined
                    end,
                    ReqOpts = bondy_oidc_provider:request_opts(Config),
                    RetrieveOpts = #{
                        redirect_uri => RedirectUri,
                        nonce => Nonce,
                        pkce_verifier => CodeVerifier,
                        refresh_jwks => RefreshJwks,
                        request_opts => ReqOpts
                    },
                    case oidcc_token:retrieve(Code, ClientCtx, RetrieveOpts) of
                        {ok, Token} ->
                            handle_token_success(
                                Req0, State, RealmUri, Provider,
                                Config, Token, ClientCtx, SpaRedirect,
                                TicketScope
                            );
                        {error, Reason} ->
                            ?LOG_ERROR(#{
                                description =>
                                    "Failed to exchange OIDC auth code",
                                realm_uri => RealmUri,
                                provider => Provider,
                                reason => Reason
                            }),
                            Req1 = reply_json_error(
                                ?HTTP_BAD_REQUEST,
                                <<"token_exchange_failed">>,
                                Req0
                            ),
                            {ok, Req1, State}
                    end;
                {error, _} ->
                    Req1 = reply_json_error(
                        ?HTTP_INTERNAL_SERVER_ERROR,
                        <<"provider_unavailable">>,
                        Req0
                    ),
                    {ok, Req1, State}
            end;
        {error, not_found} ->
            Req1 = reply_json_error(
                ?HTTP_NOT_FOUND, <<"unknown_provider">>, Req0
            ),
            {ok, Req1, State}
    end.


%% @private
handle_token_success(
    Req0, State, RealmUri, Provider, Config, Token, ClientCtx, SpaRedirect,
    TicketScope
) ->
    #oidcc_token{
        id = IdToken,
        access = AccessToken,
        refresh = RefreshToken
    } = Token,

    #oidcc_token_id{token = IdTokenJWT, claims = IdClaims} = IdToken,

    %% Fetch full claims from the userinfo endpoint. Many IdPs only include
    %% minimal claims in the ID token and serve custom claims (e.g. roles)
    %% via userinfo.
    UserinfoOpts = #{request_opts => bondy_oidc_provider:request_opts(Config)},
    AllClaims = case oidcc_userinfo:retrieve(Token, ClientCtx, UserinfoOpts) of
        {ok, UserinfoClaims} ->
            maps:merge(IdClaims, UserinfoClaims);
        {error, Reason} ->
            ?LOG_WARNING(#{
                description => "Failed to fetch OIDC userinfo, "
                    "using id_token claims only",
                realm_uri => RealmUri,
                provider => Provider,
                reason => Reason
            }),
            IdClaims
    end,

    %% Extract authid from configured claim
    AuthidClaim = maps:get(authid_claim, Config, <<"preferred_username">>),
    Authid = maps:get(
        AuthidClaim, AllClaims,
        maps:get(<<"sub">>, AllClaims, undefined)
    ),

    case is_binary(Authid) of
        false ->
            ?LOG_ERROR(#{
                description => "OIDC id_token missing authid claim",
                realm_uri => RealmUri,
                provider => Provider,
                authid_claim => AuthidClaim,
                id_claims => IdClaims
            }),
            Req1 = reply_json_error(
                ?HTTP_BAD_REQUEST, <<"missing_authid_claim">>, Req0
            ),
            {ok, Req1, State};
        true ->
            %% Extract roles from userinfo + token claims
            Authroles = extract_roles(AllClaims, AccessToken, Config),
            do_issue_ticket(
                Req0, State, RealmUri, Provider, Config,
                Authid, Authroles, IdTokenJWT, AccessToken, RefreshToken,
                SpaRedirect, TicketScope
            )
    end.


%% @private
do_issue_ticket(
    Req0, State, RealmUri, Provider, Config,
    Authid, Authroles, IdTokenJWT, AccessToken, RefreshToken,
    SpaRedirect, TicketScope
) ->
    %% Optionally provision a local user record
    case maps:get(auto_provision, Config, false) of
        true ->
            ok = ensure_user(RealmUri, Authid, Authroles);
        false ->
            ok
    end,

    %% Build OIDC tokens map for the ticket
    OidcTokensMap = build_oidc_tokens_map(IdTokenJWT, AccessToken, RefreshToken),

    %% Per-provider ticket_expiry_secs overrides the global default.
    %% We use maps:find/2 so that legacy configs with the old hardcoded
    %% default (3600) from the validator are not distinguished from an
    %% explicit setting — the validator no longer injects a default.
    ConfigExpirySecs = case maps:find(ticket_expiry_secs, Config) of
        {ok, Val} when is_integer(Val) -> Val;
        _ -> bondy_config:get([security, ticket, expiry_time_secs])
    end,

    %% Align ticket lifetime with the OIDC refresh token TTL.
    %% The Bondy ticket represents the OIDC session — it should last as long
    %% as the refresh token allows session renewal. Use the greater of the
    %% refresh token TTL and the configured ticket_expiry_secs.
    ExpirySecs = max(
        ConfigExpirySecs, refresh_token_ttl_secs(RefreshToken)
    ),

    case bondy_oidc_ticket:issue(
        RealmUri, Authid, Provider, OidcTokensMap,
        #{
            expiry_time_secs => ExpirySecs,
            authroles => Authroles,
            scope => TicketScope
        }
    ) of
        {ok, JWT, _Claims} ->
            BasePath = maps:get(base_path, State, <<>>),
            IsSecure = cowboy_req:scheme(Req0) =:= <<"https">>,
            CookieDomain = maps:get(cookie_domain, Config, undefined),
            CsrfToken = bondy_utils:uuid(),
            Req1 = set_ticket_cookie(
                Req0, RealmUri, JWT, BasePath, ExpirySecs, IsSecure,
                CookieDomain
            ),
            Req2 = set_csrf_cookie(
                Req1, RealmUri, CsrfToken, BasePath, ExpirySecs, IsSecure,
                CookieDomain
            ),
            Req3 = cowboy_req:reply(
                302,
                #{<<"location">> => SpaRedirect},
                <<>>,
                Req2
            ),
            {ok, Req3, State};
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Failed to issue OIDC ticket",
                realm_uri => RealmUri,
                provider => Provider,
                authid => Authid,
                reason => Reason
            }),
            Req1 = reply_json_error(
                ?HTTP_INTERNAL_SERVER_ERROR,
                <<"ticket_issue_failed">>,
                Req0
            ),
            {ok, Req1, State}
    end.


%% @private
handle_logout(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            do_handle_logout(Req0, State);
        <<"POST">> ->
            do_handle_logout(Req0, State);
        _ ->
            Req1 = cowboy_req:reply(?HTTP_METHOD_NOT_ALLOWED, #{}, <<>>, Req0),
            {ok, Req1, State}
    end.


%% @private
do_handle_logout(Req0, #{realm_uri := DefaultRealmUri} = State) ->
    Cookies = cowboy_req:parse_cookies(Req0),
    BasePath = maps:get(base_path, State, <<>>),
    QsVals = cowboy_req:parse_qs(Req0),
    RealmUri = proplists:get_value(
        <<"realm">>, QsVals, DefaultRealmUri
    ),
    RedirectUri = proplists:get_value(
        <<"redirect_uri">>, QsVals, ?DEFAULT_REDIRECT
    ),

    %% Find the realm-prefixed ticket cookie and try to revoke it.
    %% The realm may not exist on this node (e.g. after reconfiguration),
    %% so we catch errors to ensure cookies are always cleared.
    TicketCookieName = ticket_cookie_name(RealmUri),
    OidcClaims = case lists:keyfind(TicketCookieName, 1, Cookies) of
        {_, JWT} ->
            try bondy_ticket:verify(JWT) of
                {ok, Claims} ->
                    _ = bondy_ticket:revoke(Claims),
                    Claims;
                {error, _} ->
                    _ = catch bondy_ticket:revoke(JWT),
                    #{}
            catch
                _:_ ->
                    #{}
            end;
        false ->
            #{}
    end,

    %% Always clear realm-prefixed cookies regardless of verify outcome.
    %% cookie_domain may come from the provider config or as a query param.
    Provider = maps:get(oidc_provider, OidcClaims, undefined),
    CookieDomain = case proplists:get_value(<<"cookie_domain">>, QsVals) of
        undefined when is_binary(Provider) ->
            case bondy_oidc_provider:get_provider_config(RealmUri, Provider) of
                {ok, Cfg} -> maps:get(cookie_domain, Cfg, undefined);
                {error, _} -> undefined
            end;
        undefined ->
            undefined;
        Domain ->
            Domain
    end,
    IsSecure = cowboy_req:scheme(Req0) =:= <<"https">>,
    Req1 = clear_ticket_cookie(Req0, RealmUri, BasePath, IsSecure, CookieDomain),
    Req2 = clear_csrf_cookie(Req1, RealmUri, BasePath, IsSecure, CookieDomain),

    %% Build the redirect target. If the ticket contains OIDC claims, attempt
    %% RP-Initiated Logout at the IdP's end_session_endpoint so that both the
    %% Bondy session and the IdP session are terminated.
    Location = maybe_idp_logout_url(
        RealmUri, OidcClaims, RedirectUri
    ),

    Req3 = cowboy_req:reply(
        302,
        #{<<"location">> => Location},
        <<>>,
        Req2
    ),
    {ok, Req3, State}.


%% @private
provider_name(Req, State) ->
    case maps:find(provider, State) of
        {ok, Provider} ->
            Provider;
        error ->
            QsP = cowboy_req:parse_qs(Req),
            case proplists:get_value(<<"provider">>, QsP) of
                undefined ->
                    cowboy_req:binding(provider, Req, <<"default">>);
                Provider ->
                    Provider
            end
    end.


%% @private
ensure_user(RealmUri, Authid, Authroles) ->
    case bondy_rbac_user:lookup(RealmUri, Authid) of
        {ok, _User} ->
            ok;
        {error, not_found} ->
            User = bondy_rbac_user:new(#{
                <<"username">> => Authid,
                <<"groups">> => Authroles
            }),
            case bondy_rbac_user:add(RealmUri, User) of
                {ok, _} -> ok;
                {error, already_exists} -> ok;
                {error, Reason} -> error(Reason)
            end
    end.


%% @private
extract_roles(AllClaims, AccessToken, Config) ->
    RoleClaim = maps:get(role_claim, Config, <<"roles">>),
    FallbackClaim = maps:get(role_claim_fallback, Config, <<"role">>),
    RoleMapping = maps:get(role_mapping, Config, #{}),

    Roles = case extract_claim(RoleClaim, AllClaims) of
        [] ->
            case extract_claim(FallbackClaim, AllClaims) of
                [] ->
                    extract_roles_from_access_token(
                        RoleClaim, FallbackClaim, AccessToken
                    );
                Found ->
                    Found
            end;
        Found ->
            Found
    end,
    map_roles(Roles, RoleMapping).


%% @private
extract_claim(ClaimName, Claims) when is_map(Claims) ->
    case binary:split(ClaimName, <<".">>) of
        [Outer, Inner] ->
            %% Nested claim e.g. <<"realm_access.roles">>
            case maps:get(Outer, Claims, undefined) of
                Nested when is_map(Nested) ->
                    extract_claim(Inner, Nested);
                _ ->
                    []
            end;
        [_] ->
            case maps:get(ClaimName, Claims, undefined) of
                L when is_list(L) -> L;
                B when is_binary(B) -> [B];
                _ -> []
            end
    end.


%% @private
extract_roles_from_access_token(RoleClaim, FallbackClaim, AccessToken) ->
    case AccessToken of
        #oidcc_token_access{token = AT} when is_binary(AT) ->
            case decode_jwt_claims(AT) of
                {ok, ATClaims} ->
                    case extract_claim(RoleClaim, ATClaims) of
                        [] -> extract_claim(FallbackClaim, ATClaims);
                        Found -> Found
                    end;
                error ->
                    []
            end;
        _ ->
            []
    end.


%% @private
%% Extracts the remaining TTL in seconds from an OIDC refresh token.
%% If the refresh token is a JWT with an `exp` claim, returns the number of
%% seconds until expiry. Returns 0 for opaque tokens or if already expired.
refresh_token_ttl_secs(#oidcc_token_refresh{token = RT}) when is_binary(RT) ->
    case decode_jwt_claims(RT) of
        {ok, #{<<"exp">> := Exp}} when is_integer(Exp) ->
            max(0, Exp - erlang:system_time(second));
        _ ->
            0
    end;

refresh_token_ttl_secs(_) ->
    0.


%% @private
decode_jwt_claims(JWT) when is_binary(JWT) ->
    try
        {jose_jwt, Claims} = jose_jwt:peek(JWT),
        {ok, Claims}
    catch
        _:_ -> error
    end.


%% @private
map_roles(Roles, RoleMapping) when map_size(RoleMapping) == 0 ->
    Roles;

map_roles(Roles, RoleMapping) ->
    lists:filtermap(
        fun(Role) ->
            case maps:find(Role, RoleMapping) of
                {ok, MappedRole} -> {true, string:casefold(MappedRole)};
                error -> {true, string:casefold(Role)}
            end
        end,
        Roles
    ).


%% @private
build_oidc_tokens_map(IdTokenJWT, AccessToken, RefreshToken) ->
    Map0 = case is_binary(IdTokenJWT) of
        true -> #{id_token => IdTokenJWT};
        false -> #{}
    end,
    Map1 = case RefreshToken of
        #oidcc_token_refresh{token = RT} when is_binary(RT) ->
            Map0#{refresh_token => RT};
        _ ->
            Map0
    end,
    case AccessToken of
        #oidcc_token_access{token = AT, expires = Exp}
        when is_binary(AT) ->
            Map2 = Map1#{access_token => AT},
            case is_integer(Exp) of
                true -> Map2#{access_token_expires_at => Exp};
                false -> Map2
            end;
        _ ->
            Map1
    end.


%% @private
ticket_cookie_name(RealmUri) ->
    <<?TICKET_COOKIE_PREFIX/binary, RealmUri/binary>>.


%% @private
csrf_cookie_name(RealmUri) ->
    <<?CSRF_COOKIE_PREFIX/binary, RealmUri/binary>>.


%% @private
set_ticket_cookie(Req, RealmUri, JWT, BasePath, MaxAgeSecs, IsSecure,
                  CookieDomain) ->
    Opts = cookie_opts(BasePath, MaxAgeSecs, IsSecure, true, CookieDomain),
    cowboy_req:set_resp_cookie(ticket_cookie_name(RealmUri), JWT, Req, Opts).


%% @private
clear_ticket_cookie(Req, RealmUri, BasePath, IsSecure, CookieDomain) ->
    Opts = cookie_opts(BasePath, 0, IsSecure, true, CookieDomain),
    cowboy_req:set_resp_cookie(ticket_cookie_name(RealmUri), <<>>, Req, Opts).


%% @private
set_csrf_cookie(Req, RealmUri, CsrfToken, BasePath, MaxAgeSecs, IsSecure,
                CookieDomain) ->
    Opts = cookie_opts(BasePath, MaxAgeSecs, IsSecure, false, CookieDomain),
    cowboy_req:set_resp_cookie(
        csrf_cookie_name(RealmUri), CsrfToken, Req, Opts
    ).


%% @private
clear_csrf_cookie(Req, RealmUri, BasePath, IsSecure, CookieDomain) ->
    Opts = cookie_opts(BasePath, 0, IsSecure, false, CookieDomain),
    cowboy_req:set_resp_cookie(
        csrf_cookie_name(RealmUri), <<>>, Req, Opts
    ).


%% @private
cookie_opts(_BasePath, MaxAge, IsSecure, HttpOnly, CookieDomain) ->
    Opts0 = #{
        http_only => HttpOnly,
        secure => IsSecure,
        same_site => lax,
        path => <<"/">>,
        max_age => MaxAge
    },
    case CookieDomain of
        undefined -> Opts0;
        Domain when is_binary(Domain) -> Opts0#{domain => Domain}
    end.


%% @private
%% @doc Attempts to build an RP-Initiated Logout URL for the IdP. If the ticket
%% contains OIDC claims (provider name and id_token), uses
%% `oidcc_logout:initiate_url/3' to redirect to the IdP's end_session_endpoint
%% with the `post_logout_redirect_uri' pointing back to the SPA.
%%
%% Falls back to `RedirectUri' (direct SPA redirect) when:
%% - No OIDC provider is in the claims (non-OIDC session)
%% - The provider's client context cannot be obtained
%% - The IdP does not support `end_session_endpoint'
maybe_idp_logout_url(RealmUri, Claims, RedirectUri) ->
    case Claims of
        #{oidc_provider := Provider} when is_binary(Provider) ->
            IdTokenHint = maps:get(oidc_id_token, Claims, undefined),
            case bondy_oidc_provider:get_client_context(RealmUri, Provider) of
                {ok, ClientCtx} ->
                    Opts = #{post_logout_redirect_uri => RedirectUri},
                    case oidcc_logout:initiate_url(
                        IdTokenHint, ClientCtx, Opts
                    ) of
                        {ok, LogoutUrl} ->
                            LogoutUrl;
                        {error, end_session_endpoint_not_supported} ->
                            ?LOG_INFO(#{
                                description =>
                                    "IdP does not support "
                                    "end_session_endpoint, "
                                    "skipping RP-Initiated Logout",
                                provider => Provider,
                                realm_uri => RealmUri
                            }),
                            RedirectUri
                    end;
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        description =>
                            "Failed to get OIDC client context for "
                            "RP-Initiated Logout",
                        provider => Provider,
                        realm_uri => RealmUri,
                        reason => Reason
                    }),
                    RedirectUri
            end;
        _ ->
            RedirectUri
    end.


%% @private
reply_json_error(StatusCode, ErrorBin, Req) ->
    ReplyBody = json:encode(#{<<"error">> => ErrorBin}),
    cowboy_req:reply(
        StatusCode,
        #{<<"content-type">> => <<"application/json">>},
        ReplyBody,
        Req
    ).


%% @private
cors_headers(Req) ->
    Origin = cowboy_req:header(<<"origin">>, Req, <<"*">>),
    begin ?CORS_HEADERS end#{<<"access-control-allow-origin">> => Origin}.
