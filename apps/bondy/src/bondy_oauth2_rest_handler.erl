%% =============================================================================
%%  bondy_oauth2_resource_handler.erl -
%%
%%  Copyright (c) 2016-2023 Leapsight. All rights reserved.
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
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_oauth2_rest_handler).

-include_lib("kernel/include/logger.hrl").
-include("http_api.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").
-include("bondy_security.hrl").



%% AUTH CODE GRANT FLOW
% curl -v -X POST http://localhost/v1.0.0/oauth/token -d \
% "grant_type=authorization_code&client_id=test&client_secret=test&redirect_uri=http://localhost&code=6nZNUuYeBM7dfD0k45VF8ZnVKTZJRe2C"

-define(GRANT_TYPE, <<"grant_type">>).

-define(HEADERS, ?CORS_HEADERS#{
    <<"content-type">> => <<"application/json; charset=utf-8">>
}).

-define(OPTIONS_HEADERS, ?HEADERS#{
    <<"access-control-allow">> => <<"HEAD,OPTIONS,POST">>
}).

-define(AUTH_CODE_SPEC, #{
    ?GRANT_TYPE => #{
        required => true,
        allow_null => false,
        datatype => {in, [<<"authorization_code">>]}
    },
    <<"client_id">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"client_secret">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"redirect_uri">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"code">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    }
}).


%% Resource Owner Password Credentials Grant
%% curl -v -X POST http://192.168.1.41/api/0.2.0/oauth/token -d \
%% "grant_type=password&username=admin&password=admin&scope=*"
-define(RESOURCE_OWNER_SPEC, #{
    ?GRANT_TYPE => #{
        required => true,
        allow_null => false,
        datatype => {in, [<<"password">>]}
    },
    <<"username">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"password">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"scope">> => #{
        required => true,
        allow_null => false,
        datatype => binary,
        default => <<"all">>
    },
    <<"client_device_id">> => #{
        required => true,
        allow_null => false,
        allow_undefined => true,
        datatype => binary,
        default => undefined
    }
}).

%% Client Credentials Grant
%% curl -v -X POST http://192.168.1.41/api/0.2.0/oauth/token -d \
%% "grant_type=client_credentials&client_id=test&client_secret=test&scope=*"
-define(CLIENT_CREDENTIALS_SPEC, #{
    ?GRANT_TYPE => #{
        required => true,
        allow_null => false,
        datatype => {in, [<<"client_credentials">>]}
    },
    <<"client_id">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"client_secret">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"scope">> => #{
        required => true,
        allow_null => false,
        datatype => binary,
        default => <<"all">>
    }
}).

%% Refresh Token
%% curl -v -X POST http://192.168.1.41/api/0.2.0/oauth/token -d \
%% "grant_type=refresh_token&client_id=test&client_secret=test&refresh_token=gcSwNN369G2Ks8cet2CQTzYdlebpQtkD&scope=*"
-define(REFRESH_TOKEN_SPEC, #{
    ?GRANT_TYPE => #{
        required => true,
        allow_null => false,
        datatype => {in, [<<"refresh_token">>]}
    },
    <<"refresh_token">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    }
}).

-define(REVOKE_TOKEN_SPEC, #{
    <<"token">> => #{
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"token_type_hint">> => #{
        required => true,
        allow_null => false,
        allow_undefined => true,
        default => undefined,
        validator => fun
            (<<"access_token">>) ->
                {ok, access_token};
            (<<"refresh_token">>) ->
                {ok, refresh_token};
            (_) ->
                error
        end
    }
}).

-define(OPTS_SPEC, #{
    realm_uri => #{
        required => true,
        allow_null => false,
        validator => fun wamp_uri:is_valid/1
    },
    client_id => #{
        required  => false,
        datatype => binary
    },
    token_path => #{
        required  => true,
        datatype => binary
    },
    revoke_path => #{
        required  => true,
        datatype => binary
    }
}).

-record(state, {
    realm_uri           ::  binary(),
    client_auth_ctxt    ::  bondy_auth:context() | undefined,
    owner_auth_ctxt     ::  bondy_auth:context() | undefined,
    client_id           ::  binary() | undefined,
    device_id           ::  binary() | undefined,
    token_path          ::  binary(),
    revoke_path         ::  binary()
}).

-type state()           ::  #state{}.

-export([accept/2]).
-export([allowed_methods/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([init/2]).
-export([is_authorized/2]).
-export([options/2]).
-export([provide/2]).
-export([rate_limited/2]).
-export([resource_existed/2]).
-export([resource_exists/2]).



%% =============================================================================
%% COWBOY CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
init(Req, Opts0) ->
    Opts1 = maps_utils:validate(Opts0, ?OPTS_SPEC),
    St = #state{
        realm_uri = maps:get(realm_uri, Opts1),
        client_id = maps:get(client_id, Opts1, undefined),
        token_path = maps:get(token_path, Opts1),
        revoke_path = maps:get(revoke_path, Opts1)
    },
    {cowboy_rest, Req, St}.


allowed_methods(Req, St) ->
    {[<<"HEAD">>, <<"OPTIONS">>, <<"POST">>], Req, St}.


content_types_accepted(Req, St) ->
    L = [
        {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, accept}
    ],
    {L, Req, St}.


content_types_provided(Req, St) ->
    L = [
        {{<<"application">>, <<"json">>, '*'}, provide}
    ],
    {L, Req, St}.


options(Req, State) ->
    {ok, set_resp_headers(?OPTIONS_HEADERS, Req), State}.


is_authorized(Req0, St0) ->
    %% TODO at the moment the flows that we support required these vals
    %% but not sure all flows do.
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            {true, Req0, St0};
        _ ->
            do_is_authorized(Req0, St0)
    end.


rate_limited(Req, St) ->
    %% Result :: false | {true, RetryAfter}
    {false, Req, St}.


resource_exists(Req, St) ->
    {true, Req, St}.


resource_existed(Req, St) ->
    {false, Req, St}.


provide(Req, St) ->
    %% This is just to support OPTIONS
    {ok, set_resp_headers(?HEADERS, Req), St}.


accept(Req0, St) ->
    try
        {ok, PList, Req1} = cowboy_req:read_urlencoded_body(Req0),
        Data = maps:from_list(PList),

        Token = St#state.token_path,
        TokenSize = byte_size(Token),

        Revoke = St#state.revoke_path,
        RevokeSize = byte_size(Revoke),


        case cowboy_req:path(Req1) of
            <<Token:TokenSize/binary, _/binary>> ->
                token_flow(Data, Req1, St);
            <<Revoke:RevokeSize/binary, _/binary>> ->
                revoke_token_flow(Data, Req1, St);
            <<"jwks">> ->
                jwks(Req1, St)
        end
    catch
        error:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => error,
                reason => Reason,
                stacktrace => Stacktrace
            }),

            Req2 = reply(Reason, Req0),
            {false, Req2, St}
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



do_is_authorized(Req0, St0) ->
    Peer = cowboy_req:peer(Req0),
    ClientIP = bondy_http_utils:client_ip(Req0),

    try
        Auth = bondy_http_utils:parse_authorization(Req0),

        {ClientId, Password} = case Auth of
            {basic, A, B} ->
                {A, B};
            _ ->
                Txt = <<"The authorization header should use the 'basic' scheme">>,
                throw({request_error, {header, <<"authorization">>}, Txt})
        end,

        RealmUri = St0#state.realm_uri,
        SessionId = bondy_session_id:new(),

        case bondy_auth:init(SessionId, RealmUri, ClientId, all, Peer) of
            {ok, AuthCtxt} ->
                St1 = St0#state{
                    client_id = ClientId,
                    client_auth_ctxt = AuthCtxt
                },
                St2 = authenticate(client, Password, St1),
                %% TODO Here we should check this principal belongs to
                %% "api_clients" group, to check the client_credentials flow
                %% can be used. Otherwise we should differentiate between the
                %% flows on the auth method and RBAC source
                {true, Req0, St2};
            {error, Reason} ->
                throw(Reason)
        end

    catch
        throw:EReason ->
            ?LOG_INFO(#{
                description => "API Client login failed due to invalid client ID",
                reason => EReason,
                realm => St0#state.realm_uri,
                client_ip => ClientIP
            }),
            Req1 = reply(oauth2_invalid_client, Req0),
            {stop, Req1, St0};

        _:{request_error, {header, H}, Desc} ->
            ?LOG_INFO(#{
                description => "API Client login failed due to invalid client ID",
                reason => badheader,
                header => H,
                realm => St0#state.realm_uri,
                client_ip => ClientIP
            }),

            Req1 = reply({badheader, H, Desc}, Req0),
            {stop, Req1, St0}
    end.


%% @private
authenticate(client, Password, #state{client_auth_ctxt = Ctxt} = St) ->
    NewCtxt = do_authenticate(Password, Ctxt),
    St#state{
        client_auth_ctxt = NewCtxt
    };

authenticate(
    resource_owner, Password, #state{owner_auth_ctxt = Ctxt} = St) ->
    NewCtxt = do_authenticate(Password, Ctxt),
    St#state{
        owner_auth_ctxt = NewCtxt
    }.


%% @private
do_authenticate(Password, Ctxt) ->
    %% TODO If the user configured realm authmethods with OAUTH2 but not
    %% PASSWORD this will fail.  We need to ask bondy_auth to authenticate using password even if password is not an allowed method (this)
    case bondy_auth:authenticate(?PASSWORD_AUTH, Password, undefined, Ctxt) of
        {ok, _, NewCtxt} ->
            NewCtxt;
        {error, Reason} ->
            throw(Reason)
    end.


%% @private
token_flow(
    #{?GRANT_TYPE := <<"client_credentials">>},
    Req,
    #state{client_auth_ctxt = Ctxt} = St) when Ctxt =/= undefined ->
    %% The context was set during the is_authorized callback
    issue_token(client_credentials, Req, St);

token_flow(#{?GRANT_TYPE := <<"password">>} = Map, Req0, St0) ->
    %% Resource Owner Password Credentials Flow
    #{
        <<"username">> := Username,
        <<"password">> := Password,
        <<"scope">> := _Scope,
        <<"client_device_id">> := DeviceId
    } = maps_utils:validate(Map, ?RESOURCE_OWNER_SPEC),

    RealmUri = St0#state.realm_uri,
    {IP, _Port} = Peer = cowboy_req:peer(Req0),

    %% This is ID will bot be used as the ID is already defined in the JWT
    SessionId = bondy_session_id:new(),

    try
        case bondy_auth:init(SessionId, RealmUri, Username, all, Peer) of
            {ok, Ctxt} ->
                St1 = St0#state{
                    device_id = DeviceId,
                    owner_auth_ctxt = Ctxt
                },
                St2 = authenticate(resource_owner, Password, St1),
                issue_token(password, Req0, St2);
            {error, Reason} ->
                throw(Reason)
        end
    catch
        throw:EReason ->
            BinIP = inet_utils:ip_address_to_binary(IP),
            ?LOG_INFO(#{
                description => "Resource Owner login failed. The grant is invalid",
                reason => EReason,
                client_device_id => DeviceId,
                realm_uri => RealmUri,
                cient_ip => BinIP
            }),
            {stop, reply(oauth2_invalid_grant, Req0), St0}
    end;

token_flow(#{?GRANT_TYPE := <<"refresh_token">>} = Map0, Req0, St0) ->
    %% According to RFC6749:
    %% The authorization server MAY issue a new refresh token, in which case
    %% the client MUST discard the old refresh token and replace it with the
    %% new refresh token. The authorization server MAY revoke the old
    %% refresh token after issuing a new refresh token to the client.
    %% If a new refresh token is issued, the refresh token scope MUST be
    %% identical to that of the refresh token included by the client in the
    %% request.
    try maps_utils:validate(Map0, ?REFRESH_TOKEN_SPEC) of
        #{<<"refresh_token">> := Val} -> refresh_token(Val, Req0, St0)
    catch
        error:Reason:Stacktrace->
            ?LOG_INFO(#{
                description => "Error while refreshing OAuth2 token",
                reason => Reason,
                stacktrace => Stacktrace
            }),
            error({oauth2_invalid_request, Map0})
    end;

token_flow(#{?GRANT_TYPE := <<"authorization_code">>} = _Map, _, _) ->
    %% TODO
    error({oauth2_unsupported_grant_type, <<"authorization_code">>});

token_flow(Map, _, _) ->
    error({oauth2_invalid_request, Map}).


%% @private
refresh_token(RefreshToken, Req0, St) ->
    Realm = St#state.realm_uri,
    Issuer = St#state.client_id,

    case bondy_oauth2:refresh_token(Realm, Issuer, RefreshToken) of
        {ok, JWT, RT1, Claims} ->
            Req1 = token_response(JWT, RT1, Claims, Req0),
            ok = on_login(Realm, Issuer, #{}),
            {true, Req1, St};
        {error, Error} ->
            Req1 = reply(Error, Req0),
            {stop, Req1, St}
    end.


- spec auth_context(TokenType :: client_credentials | password, state()) ->
    bondy_auth:context().

auth_context(client_credentials, #state{client_auth_ctxt = Val}) ->
    Val;
auth_context(password, #state{owner_auth_ctxt = Val}) ->
    Val.


%% @private
issue_token(Type, Req0, St0) ->
    RealmUri = St0#state.realm_uri,
    Issuer = bondy_auth:user_id(St0#state.client_auth_ctxt),

    AuthCtxt = auth_context(Type, St0),
    Authid = bondy_auth:user_id(AuthCtxt),
    User = bondy_auth:user(AuthCtxt),
    Gs = bondy_auth:roles(AuthCtxt),
    Meta0 = bondy_rbac_user:meta(User),
    Meta = prepare_meta(Type, Meta0, St0),

    case bondy_oauth2:issue_token(Type, RealmUri, Issuer, Authid, Gs, Meta) of
        {ok, JWT, RefreshToken, Claims} ->
            Req1 = token_response(JWT, RefreshToken, Claims, Req0),
            ok = on_login(RealmUri, Authid, Meta),
            {true, Req1, St0};
        {error, Reason} ->
            Req1 = reply(Reason, Req0),
            {stop, Req1, St0}
    end.


%% @private
revoke_token_flow(Data0, Req0, St) ->
    try
        Data1 = maps_utils:validate(Data0, ?REVOKE_TOKEN_SPEC),
        RealmUri = St#state.realm_uri,
        Issuer = St#state.client_id,
        Token = maps:get(<<"token">>, Data1),
        Type = maps:get(<<"token_type_hint">>, Data1),
        %% From https://tools.ietf.org/html/rfc7009#page-3
        %% The authorization server responds with HTTP status
        %% code 200 if the token has been revoked successfully
        %% or if the client submitted an invalid token.
        %% We set a body as Cowboy will otherwise use 204 code
        _ = bondy_oauth2:revoke_token(Type, RealmUri, Issuer, Token),
        Req1 = prepare_request(true, #{}, Req0),
        {true, Req1, St}
    catch
        error:#{code := invalid_datatype, key := <<"token_type_hint">>} ->
            {stop, reply(unsupported_token_type, Req0), St}
    end.


jwks(Req0, St) ->
    RealmUri = St#state.realm_uri,

    case bondy_realm:lookup(RealmUri) of
        {error, not_found} ->
            ErrorMap = maps:without(
                [<<"status_code">>],
                bondy_error:map({no_such_realm, RealmUri})
            ),
            Req1 = cowboy_req:reply(
                ?HTTP_NOT_FOUND,
                prepare_request(ErrorMap, #{}, Req0)
            ),
            {stop, Req1, St};
        Realm ->
            #{public_keys := Keys} = bondy_realm:to_external(Realm),
            KeySet = #{keys => Keys},
            Req1 = prepare_request(KeySet, #{}, Req0),
            {true, Req1, St}
    end.


%% @private
prepare_meta(password, Meta, #state{device_id = DeviceId})
when DeviceId =/= undefined ->
     maps:put(<<"client_device_id">>, DeviceId, Meta);

prepare_meta(_, Meta, _) ->
    Meta.


%% @private
-spec reply(atom() | integer(), cowboy_req:req()) -> cowboy_req:req().

reply(no_such_realm, Req) ->
    reply(oauth2_invalid_client, Req);

reply({no_such_user, _}, Req) ->
    reply(oauth2_invalid_client, Req);

reply(missing_signature, Req) ->
    reply(oauth2_invalid_client, Req);

reply(bad_signature, Req) ->
    reply(oauth2_invalid_client, Req);

reply(unknown_source, Req) ->
    reply(oauth2_invalid_client, Req);

reply(no_common_name, Req) ->
    reply(oauth2_invalid_client, Req);

reply(common_name_mismatch, Req) ->
    reply(oauth2_invalid_client, Req);

reply(oauth2_invalid_client = Error, Req) ->
    Headers = #{<<"www-authenticate">> => <<"Basic">>},
    ErrorMap = maps:without([<<"status_code">>], bondy_error:map(Error)),
    cowboy_req:reply(
        ?HTTP_UNAUTHORIZED, prepare_request(ErrorMap, Headers, Req));

reply(unsupported_token_type = Error, Req) ->
    {Code, Map} = maps:take(<<"status_code">>, bondy_error:map(Error)),
    cowboy_req:reply(Code, prepare_request(Map, #{}, Req));

reply(Error, Req) ->
    Map0 = bondy_error:map(Error),
    {Code, Map1} = case maps:take(<<"status_code">>, Map0) of
        error ->
            {?HTTP_BAD_REQUEST, Map0};
        Res ->
            Res
    end,
    cowboy_req:reply(Code, prepare_request(Map1, #{}, Req)).



%% @private
-spec prepare_request(term(), map(), cowboy_req:req()) -> cowboy_req:req().

prepare_request(Body, Headers, Req0) ->
    Req1 = set_resp_headers(maps:merge(?HEADERS, Headers), Req0),
    cowboy_req:set_resp_body(bondy_utils:maybe_encode(json, Body), Req1).


%% @private
token_response(JWT, RefreshToken, Claims, Req0) ->
    Scope = iolist_to_binary(
        lists:join(<<$,>>, maps:get(<<"groups">>, Claims))),
    Exp = maps:get(<<"exp">>, Claims),

    Body0 = #{
        <<"token_type">> => <<"bearer">>,
        <<"access_token">> => JWT,
        <<"scope">> => Scope,
        <<"expires_in">> => Exp
    },

    Body1 = case RefreshToken =:= undefined of
        true ->
            Body0;
        false ->
            Body0#{
                <<"refresh_token">> => RefreshToken
            }
    end,
    prepare_request(Body1, #{}, Req0).


%% @private
on_login(_RealmUri, _Username, _Meta) ->
    % bondy_event_manager:notify(
    %     {user_log_in, RealmUri, Username, Meta}).
    ok.


set_resp_headers(Headers, Req0) ->
    Req1 = cowboy_req:set_resp_headers(Headers, Req0),
    cowboy_req:set_resp_headers(bondy_http_utils:meta_headers(), Req1).