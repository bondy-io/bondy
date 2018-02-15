%% =============================================================================
%%  bondy_api_oauth2_handler.erl -
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

-module(bondy_api_oauth2_handler).
-include("bondy.hrl").

% -type state() :: #{
%     api_context => map()
% }.

%% AUTH CODE GRANT FLOW
% curl -v -X POST http://localhost/v1.0.0/oauth/token -d \
% "grant_type=authorization_code&client_id=test&client_secret=test&redirect_uri=http://localhost&code=6nZNUuYeBM7dfD0k45VF8ZnVKTZJRe2C"

-define(GRANT_TYPE, <<"grant_type">>).

-define(CORS_HEADERS, #{
    <<"access-control-allow-origin">> => <<"*">>,
    <<"access-control-allow-credentials">> => <<"true">>,
    <<"access-control-allow-methods">> => <<"HEAD,OPTIONS,POST">>,
    <<"access-control-allow-headers">> => <<"origin,x-requested-with,content-type,accept,authorization,accept-language">>,
    <<"access-control-max-age">> => <<"86400">>
}).

-define(OPTIONS_HEADERS, ?CORS_HEADERS#{
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

% curl -v -X POST http://192.168.1.41/api/0.2.0/oauth/token -d \
% "grant_type=password&username=admin&password=admin&scope=*"


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

% curl -v -X POST http://192.168.1.41/api/0.2.0/oauth/token -d \
% "grant_type=client_credentials&client_id=test&client_secret=test&scope=*"


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
% curl -v -X POST http://192.168.1.41/api/0.2.0/oauth/token -d \
% "grant_type=refresh_token&client_id=test&client_secret=test&refresh_token=gcSwNN369G2Ks8cet2CQTzYdlebpQtkD&scope=*"

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
    client_id           ::  binary() | undefined,
    device_id           ::  binary() | undefined,
    token_path          ::  binary(),
    revoke_path         ::  binary()
}).



-export([init/2]).
-export([allowed_methods/2]).
-export([options/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([is_authorized/2]).
-export([resource_exists/2]).
-export([resource_existed/2]).
-export([accept/2]).
-export([provide/2]).



%% =============================================================================
%% API
%% =============================================================================



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
    {ok, cowboy_req:set_resp_headers(?OPTIONS_HEADERS, Req), State}.


is_authorized(Req0, St0) ->
    %% TODO at the moment the flows that we support required these vals
    %% but not sure all flows do.
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            {true, Req0, St0};
        _ ->
            Val = cowboy_req:parse_header(<<"authorization">>, Req0),
            Peer = cowboy_req:peer(Req0),
            case
                bondy_security_utils:authenticate(
                    basic, Val, St0#state.realm_uri, Peer)
            of
                {ok, AuthCtxt} ->
                    ClientId = ?CHARS2BIN(
                        bondy_security:get_username(AuthCtxt)),
                    {true, Req0, St0#state{client_id = ClientId}};
                {error, Reason} ->
                    _ = lager:info(
                        "API Client login failed due to invalid client, "
                        "reason=~p", [Reason]),
                    Req1 = reply(oauth2_invalid_client, Req0),
                    {stop, Req1, St0}
            end
    end.


resource_exists(Req, St) ->
    {true, Req, St}.


resource_existed(Req, St) ->
    {false, Req, St}.


provide(Req, St) ->
    %% This is just to support OPTIONS
    {ok, cowboy_req:set_resp_header(?CORS_HEADERS, Req), St}.


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
                revoke_token_flow(Data, Req1, St)
        end
    catch
        error:Reason ->
            _ = lager:error(
                "type=error, reason=~p, stacktrace:~p",
                [Reason, erlang:get_stacktrace()]),
            Req2 = reply(Reason, Req0),
            {false, Req2, St}
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private

token_flow(#{?GRANT_TYPE := <<"client_credentials">>}, Req, St) ->
    issue_token(client_credentials, St#state.client_id, Req, St);

token_flow(#{?GRANT_TYPE := <<"password">>} = Map, Req0, St0) ->
    #{
        <<"username">> := U,
        <<"password">> := P,
        <<"scope">> := _Scope,
        <<"client_device_id">> := DeviceId
    } = maps_utils:validate(Map, ?RESOURCE_OWNER_SPEC),

    RealmUri = St0#state.realm_uri,
    {IP, _Port} = cowboy_req:peer(Req0),
    St1 = St0#state{device_id = DeviceId},

    case bondy_security:authenticate(RealmUri, U, P, [{ip, IP}]) of
        {ok, AuthCtxt} ->
            %% Username in right case
            Username = bondy_security:get_username(AuthCtxt),
            issue_token(password, Username, Req0, St1);
        {error, Error} ->
            _ = lager:info(
                "Resource Owner login failed, error=invalid_grant, reason=~p, username=~s, client_device_id=~s, realm_uri=~s, ip=~s",
                [Error, U, DeviceId, RealmUri, inet_utils:ip_address_to_binary(IP)]
            ),
            {stop, reply(oauth2_invalid_grant, Req0), St1}
    end;

token_flow(#{?GRANT_TYPE := <<"refresh_token">>} = Map0, Req0, St0) ->
    %% According to RFC6749:
    %% The authorization server MAY issue a new refresh token, in which case
    %% the client MUST discard the old refresh token and replace it with the
    %% new refresh token.  The authorization server MAY revoke the old
    %% refresh token after issuing a new refresh token to the client.  If a
    %% new refresh token is issued, the refresh token scope MUST be
    %% identical to that of the refresh token included by the client in the
    %% request.
    #{
        <<"refresh_token">> := RT0
    } = maps_utils:validate(Map0, ?REFRESH_TOKEN_SPEC),
    Realm = St0#state.realm_uri,
    Issuer = St0#state.client_id,
    case bondy_oauth2:refresh_token(Realm, Issuer, RT0) of
        {ok, JWT, RT1, Claims} ->
            Req1 = token_response(JWT, RT1, Claims, Req0),
            {true, Req1, St0};
        {error, Error} ->
            Req1 = reply(Error, Req0),
            {stop, Req1, St0}
    end;

token_flow(#{?GRANT_TYPE := <<"authorization_code">>} = _Map, _, _) ->
    %% TODO
    error({oauth2_unsupported_grant_type, <<"authorization_code">>});

token_flow(Map, _, _) ->
    error({oauth2_invalid_request, Map}).


%% @private
issue_token(Type, Username, Req0, St0) ->
    RealmUri = St0#state.realm_uri,
    Issuer = St0#state.client_id,
    User = bondy_security_user:fetch(RealmUri, Username),
    Gs = bondy_security_user:groups(User),
    Meta = prepare_meta(Type, maps:get(<<"meta">>, User, #{}), St0),

    case bondy_oauth2:issue_token(Type, RealmUri, Issuer, Username, Gs, Meta) of
        {ok, JWT, RefreshToken, Claims} ->
            Req1 = token_response(JWT, RefreshToken, Claims, Req0),
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
        {true, cowboy_req:set_resp_body(<<"true">>, Req0), St}
    catch
        error:#{code := invalid_datatype, key := <<"token_type_hint">>} ->
            {stop, reply(unsupported_token_type, Req0), St}
    end.


%% @private

prepare_meta(password, Meta, #state{device_id = DeviceId})
when DeviceId =/= undefined ->
     maps:put(<<"client_device_id">>, DeviceId, Meta);

prepare_meta(_, Meta, _) ->
    Meta.


%% @private
-spec reply(integer(), cowboy_req:req()) -> cowboy_req:req().

reply(unknown_realm, Req) ->
    reply(oauth2_invalid_client, Req);

reply({unknown_user, _}, Req) ->
    reply(oauth2_invalid_client, Req);

reply(missing_password, Req) ->
    reply(oauth2_invalid_client, Req);

reply(bad_password, Req) ->
    reply(oauth2_invalid_client, Req);

reply(unknown_source, Req) ->
    reply(oauth2_invalid_client, Req);

reply(no_common_name, Req) ->
    reply(oauth2_invalid_client, Req);

reply(common_name_mismatch, Req) ->
    reply(oauth2_invalid_client, Req);

reply(oauth2_invalid_client = Error, Req) ->
    Headers = #{<<"www-authenticate">> => <<"Basic">>},
    cowboy_req:reply(
        401, prepare_request(bondy_error:map(Error), Headers, Req));

reply(unsupported_token_type = Error, Req) ->
    #{<<"status_code">> := Code} = Map = bondy_error:map(Error),
    cowboy_req:reply(Code, prepare_request(Map, #{}, Req));

reply(Error, Req) ->
    Map =  bondy_error:map(Error),
    Status = maps:get(<<"status_code">>, Map, 400),
    cowboy_req:reply(Status, prepare_request(Map, #{}, Req)).



%% @private
-spec prepare_request(map(), map(), cowboy_req:req()) -> cowboy_req:req().

prepare_request(Body, Headers, Req0) ->
    Req1 = cowboy_req:set_resp_headers(
        maps:merge(?CORS_HEADERS, Headers), Req0),
    cowboy_req:set_resp_body(bondy_utils:maybe_encode(json, Body), Req1).


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
    Req1 = cowboy_req:set_resp_headers(?CORS_HEADERS, Req0),
    cowboy_req:set_resp_body(bondy_utils:maybe_encode(json, Body1), Req1).
