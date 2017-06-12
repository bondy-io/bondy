-module(bondy_rest_oauth2_handler).
-include("bondy.hrl").

% -type state() :: #{
%     api_context => map()
% }.

%% AUTH CODE GRANT FLOW
% curl -v -X POST http://localhost/v1.0.0/oauth/token -d \
% "grant_type=authorization_code&client_id=test&client_secret=test&redirect_uri=http://localhost&code=6nZNUuYeBM7dfD0k45VF8ZnVKTZJRe2C"

-define(GRANT_TYPE, <<"grant_type">>).

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
        datatype => binary
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
        datatype => binary
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
    Methods = [
        <<"GET">>,
        <<"HEAD">>,
        <<"OPTIONS">>,
        <<"POST">>
    ],
    {Methods, Req, St}.


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


is_authorized(Req0, St0) ->
    %% TODO at the moment the flows that we support required these vals
    %% but not sure all flows do.
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
            lager:info("API Consumer login failed, error = ~p", [Reason]),
            Req1 = cowboy_req:set_resp_header(
                <<"www-authenticate">>, 
                <<"Basic realm=", $", Realm/binary, $">>, 
                Req0
            ),
            Req2 = cowboy_req:reply(401, Req1),
            {stop, Req2, St0}
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

provide(_, _, _) -> ok.


%% @private
accept(Req0, St) ->
    try
        {ok, PList, Req1} = cowboy_req:read_urlencoded_body(Req0),
        accept_flow(maps:from_list(PList), json, Req1, St)
    catch
        error:Reason ->
            %% reply error in body (check OAUTH)
            io:format("Error ~p,~nTrace:~p~n", [Reason, erlang:get_stacktrace()]),
            {false, Req0, St}
    end.


%% @private
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
            Issuer = maps:get(client_id, St0),
            G0 = bondy_security:get_grants(AuthCtxt),
            %% TODO Scope intersection
            G1 = G0,
            case bondy_oauth2:issue_token(RealmUri, Issuer, U, G1) of
                {ok, JWT, RefreshToken, Claims} ->
                    Req1 = token_response(JWT, RefreshToken, Claims, Enc, Req0),
                    {true, Req1, St0};
                {error, Error} ->
                    Req1 = reply(Error, Enc, Req0),
                    {stop, Req1, St0}
            end;
        {error, Error} ->
            Req1 = reply(Error, Enc, Req0),
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
    error({unsupported_grant_type, <<"authorization_code">>});

accept_flow(#{?GRANT_TYPE := <<"client_credentials">>} = _Map, _, _, _) ->
    %% TODO
    error({unsupported_grant_type, <<"client_credentials">>});

accept_flow(Map, _, _, _) ->
    error({invalid_request, Map}).



%% @private
-spec reply(integer(), atom(), cowboy_req:req()) -> 
    cowboy_req:req().

reply(invalid_request, Enc, Req) ->
    Error = bondy_error:error_map(invalid_request),
    cowboy_req:reply(
        400, prepare_request(Enc, Error, #{}, Req));

reply(invalid_client = Error, Enc, Req) ->
    Headers = #{<<"www-authenticate">> => <<"Basic">>},
    cowboy_req:reply(
        400, prepare_request(Enc, bondy_error:error_map(Error), Headers, Req));

reply(unauthorized_client = Error, Enc, Req) ->
    cowboy_req:reply(
        401, prepare_request(Enc, bondy_error:error_map(Error), #{}, Req));

reply(unknown_user = Error, Enc, Req) ->
    cowboy_req:reply(
        401, prepare_request(Enc, bondy_error:error_map(Error), #{}, Req));

reply(missing_password = Error, Enc, Req) ->
    cowboy_req:reply(
        401, prepare_request(Enc, bondy_error:error_map(Error), #{}, Req));

reply(bad_password = Error, Enc, Req) ->
    cowboy_req:reply(
        401, prepare_request(Enc, bondy_error:error_map(Error), #{}, Req));

reply(unknown_source = Error, Enc, Req) ->
    cowboy_req:reply(
        401, prepare_request(Enc, bondy_error:error_map(Error), #{}, Req));

reply(Error, Enc, Req) ->
    cowboy_req:reply(
        400, prepare_request(Enc, bondy_error:error_map(Error), #{}, Req)).



%% @private
-spec prepare_request(atom(), map(), map(), cowboy_req:req()) -> 
    cowboy_req:req().

prepare_request(Enc, Body, Headers, Req0) ->
    Req1 = cowboy_req:set_resp_headers(Headers, Req0),
    cowboy_req:set_resp_body(bondy_utils:maybe_encode(Enc, Body), Req1).


token_response(JWT, RefreshToken, Claims, Enc, Req0) ->
    Body = #{
        <<"token_type">> => <<"jwt">>,
        <<"access_token">> => JWT,
        <<"refresh_token">> => RefreshToken,
        <<"scope">> => maps:get(<<"scope">>, Claims),
        <<"expires_in">> => maps:get(<<"exp">>, Claims)
    },
    cowboy_req:set_resp_body(bondy_utils:maybe_encode(Enc, Body), Req0).