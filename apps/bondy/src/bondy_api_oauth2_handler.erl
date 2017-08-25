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

-define(ALLOWED_METHODS, [
    <<"HEAD">>,
    <<"OPTIONS">>,
    <<"POST">>
]).

-define(CORS_HEADERS, #{
    <<"access-control-allow-origin">> => <<"*">>,
    <<"access-control-allow-credentials">> => <<"true">>,
    <<"access-control-allow-methods">> => <<"HEAD,OPTIONS,POST">>,
    <<"access-control-allow-headers">> => <<"origin,x-requested-with,content-type,accept">>,
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

-define(STATE_SPEC, #{
    realm_uri => #{
        required => true,
        allow_null => false,
        validator => fun wamp_uri:is_valid/1
    },
    client_id => #{
        required  => false,
        datatype => binary
    }
}).

-type state() :: #{
    realm_uri => binary(),
    client_id => binary()
}.

-export_type([state/0]).

-export([init/2]).
-export([allowed_methods/2]).
-export([options/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([is_authorized/2]).
-export([resource_exists/2]).
-export([resource_existed/2]).
-export([to_json/2]).
-export([to_msgpack/2]).
-export([accept/2]).



%% =============================================================================
%% API
%% =============================================================================



init(Req, St) ->
    {cowboy_rest, Req, maps_utils:validate(St, ?STATE_SPEC)}.


allowed_methods(Req, St) ->
    {?ALLOWED_METHODS, Req, St}.


content_types_accepted(Req, St) ->
    L = [
        {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, accept}
    ],
    {L, Req, St}.


content_types_provided(Req, St) ->
    L = [
        {{<<"application">>, <<"json">>, '*'}, to_json},
        {{<<"application">>, <<"msgpack">>, '*'}, to_msgpack}
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
    Realm = maps:get(realm_uri, St0),
    Peer = cowboy_req:peer(Req0),
    case bondy_security_utils:authenticate(basic, Val, Realm, Peer) of
        {ok, AuthCtxt} ->
            St1 = St0#{
                client_id => ?CHARS2BIN(bondy_security:get_username(AuthCtxt))
            },
            {true, Req0, St1};
        {error, Reason} ->
            _ = lager:info(
                "API Client login failed due to invalid client, "
                "reason=~p", [Reason]),
                    Req1 = reply(oauth2_invalid_client, json, Req0),
                    {stop, Req1, St0}
            end
    end.


resource_exists(Req, St) ->
    {true, Req, St}.


resource_existed(Req, St) ->
    {false, Req, St}.


to_json(Req, St) ->
    provide(json, Req, St).


to_msgpack(Req, St) ->
    provide(msgpack, Req, St).




%% =============================================================================
%% PRIVATE
%% =============================================================================

provide(_, Req, St) ->
    {ok, cowboy_req:set_resp_header(?CORS_HEADERS, Req), St}.


%% @private
accept(Req0, St) ->
    try
        {ok, PList, Req1} = cowboy_req:read_urlencoded_body(Req0),
        accept_flow(maps:from_list(PList), json, Req1, St)
    catch
        error:Reason ->
            _ = lager:error(
                "type=error, reason=~p, stacktrace:~p",
                [Reason, erlang:get_stacktrace()]),
            Req2 = reply(Reason, json, Req0),
            {false, Req2, St}
    end.


%% @private

accept_flow(#{?GRANT_TYPE := <<"client_credentials">>}, Enc, Req, St) ->
    RealmUri = maps:get(realm_uri, St),
    Username = maps:get(client_id, St),
    issue_token(RealmUri, Username, Enc, Req, St);

accept_flow(#{?GRANT_TYPE := <<"password">>} = Map, Enc, Req0, St0) ->
    RealmUri = maps:get(realm_uri, St0),
    #{
        <<"username">> := U,
        <<"password">> := P,
        <<"scope">> := _Scope
    } = maps_utils:validate(Map, ?RESOURCE_OWNER_SPEC),

    {IP, _Port} = cowboy_req:peer(Req0),
    case bondy_security:authenticate(RealmUri, U, P, [{ip, IP}]) of
        {ok, AuthCtxt} ->
            Username = bondy_security:get_username(AuthCtxt),
            issue_token(RealmUri, Username, Enc, Req0, St0);
        {error, Error} ->
            _ = lager:info(
                "Resource Owner login failed, error=invalid_grant, reason=~p", [Error]),
            Req1 = reply(oauth2_invalid_grant, Enc, Req0),
            {stop, Req1, St0}
    end;

accept_flow(#{?GRANT_TYPE := <<"refresh_token">>} = Map0, Enc, Req0, St0) ->
    #{
        <<"refresh_token">> := RT0
    } = maps_utils:validate(Map0, ?REFRESH_TOKEN_SPEC),
    Realm = maps:get(realm_uri, St0),
    ClientId = maps:get(client_id, St0),
    case bondy_oauth2:refresh_token(Realm, ClientId, RT0) of
        {ok, JWT, RT1, Claims} ->
            Req1 = token_response(JWT, RT1, Claims, Enc, Req0),
            {true, Req1, St0};
        {error, Error} ->
            Req1 = reply(Error, Enc, Req0),
            {stop, Req1, St0}
    end;

accept_flow(#{?GRANT_TYPE := <<"authorization_code">>} = _Map, _, _, _) ->
    %% TODO
    error({oauth2_unsupported_grant_type, <<"authorization_code">>});

accept_flow(Map, _, _, _) ->
    error({oauth2_invalid_request, Map}).


%% @private
issue_token(RealmUri, Username, Enc, Req0, St0) ->
    Issuer = maps:get(client_id, St0),
    User = bondy_security_user:fetch(RealmUri, Username),
    Meta = maps:get(<<"meta">>, User, #{}),
    Gs = bondy_security_user:groups(User),

    case bondy_oauth2:issue_token(RealmUri, Issuer, Username, Gs, Meta) of
        {ok, JWT, RefreshToken, Claims} ->
            Req1 = token_response(JWT, RefreshToken, Claims, Enc, Req0),
            {true, Req1, St0};
        {error, Error} ->
            Req1 = reply(Error, Enc, Req0),
            {stop, Req1, St0}
    end.



%% @private
-spec reply(integer(), atom(), cowboy_req:req()) ->
    cowboy_req:req().

reply(unknown_realm, Enc, Req) ->
    reply(oauth2_invalid_client, Enc, Req);

reply(unknown_user, Enc, Req) ->
    reply(oauth2_invalid_client, Enc, Req);

reply(missing_password, Enc, Req) ->
    reply(oauth2_invalid_client, Enc, Req);

reply(bad_password, Enc, Req) ->
    reply(oauth2_invalid_client, Enc, Req);

reply(unknown_source, Enc, Req) ->
    reply(oauth2_invalid_client, Enc, Req);

reply(no_common_name, Enc, Req) ->
    reply(oauth2_invalid_client, Enc, Req);

reply(common_name_mismatch, Enc, Req) ->
    reply(oauth2_invalid_client, Enc, Req);

reply(oauth2_invalid_client = Error, Enc, Req) ->
    Headers = #{<<"www-authenticate">> => <<"Basic">>},
    cowboy_req:reply(
        401, prepare_request(Enc, bondy_error:map(Error), Headers, Req));

reply(Error, Enc, Req) ->
    Map =  bondy_error:map(Error),
    Status = maps:get(<<"status_code">>, Map, 400),
    cowboy_req:reply(
        Status, prepare_request(Enc, Map, #{}, Req)).



%% @private
-spec prepare_request(atom(), map(), map(), cowboy_req:req()) ->
    cowboy_req:req().

prepare_request(Enc, Body, Headers, Req0) ->
    Req1 = cowboy_req:set_resp_headers(
        maps:merge(?CORS_HEADERS, Headers), Req0),
    cowboy_req:set_resp_body(bondy_utils:maybe_encode(Enc, Body), Req1).


token_response(JWT, RefreshToken, Claims, Enc, Req0) ->
    Body = #{
        <<"token_type">> => <<"bearer">>,
        <<"access_token">> => JWT,
        <<"refresh_token">> => RefreshToken,
        <<"scope">> => iolist_to_binary(
            lists:join(<<$,>>, maps:get(<<"groups">>, Claims))),
        <<"expires_in">> => maps:get(<<"exp">>, Claims)
    },
    Req1 = cowboy_req:set_resp_headers(?CORS_HEADERS, Req0),
    cowboy_req:set_resp_body(bondy_utils:maybe_encode(Enc, Body), Req1).
