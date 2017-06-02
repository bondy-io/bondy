-module(juno_rest_oauth2_handler).
-include("juno.hrl").

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
    <<"refresh_token">> => #{
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
-export([from_json/2]).
-export([from_msgpack/2]).



%% =============================================================================
%% API
%% =============================================================================



init(Req, St0) ->
    {cowboy_rest, Req, St0}.


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
        {{<<"application">>, <<"json">>, '*'}, to_json},
        {{<<"application">>, <<"msgpack">>, '*'}, to_msgpack}
    ],
    {L, Req, St}.


content_types_provided(Req, St) ->
    L = [
        {{<<"application">>, <<"json">>, '*'}, from_json},
        {{<<"application">>, <<"msgpack">>, '*'}, from_msgpack}
    ],
    {L, Req, St}.


is_authorized(Req, St0) ->
    %% TODO at the moment the flows that we support required these vals
    %% but not sure all flows do.
    Val = cowboy_req:parse_header(<<"authorization">>, Req),
    Realm = maps:get(realm_uri, St0),
    Peer = cowboy_req:peer(Req),
    case juno_security_utils:authenticate(Val, Realm, Peer) of
        {ok, AuthCtxt} ->
            St1 = St0#{
                client_id => ?CHARS2BIN(juno_security:get_username(AuthCtxt))
            },
            {true, Req, St1};
        {error, _Reason} ->
            {false, Req, St0}
    end.

    


resource_exists(Req, St) ->
    {true, Req, St}.


resource_existed(Req, St) ->
    {false, Req, St}.


to_json(Req, St) ->
    provide(json, Req, St).


to_msgpack(Req, St) ->
    provide(msgpack, Req, St).


from_json(Req, St) ->
    accept(json, Req, St).


from_msgpack(Req, St) ->
    accept(msgpack, Req, St).





%% =============================================================================
%% PRIVATE
%% =============================================================================

provide(_, _, _) -> ok.


%% @private
accept(Encoding, Req, St) ->
    try
        accept_flow(maps:from_list(cowboy_req:parse_qs(Req)), Encoding, Req, St)
    catch
        error:_Reason ->
            %% reply error in body
            {false, Req, St}
    end.


%% @private
accept_flow(#{?GRANT_TYPE := <<"refresh_token">>} = Map, _, _, _) ->
    maps_utils:validate(Map, ?REFRESH_TOKEN_SPEC);

accept_flow(#{?GRANT_TYPE := <<"password">>} = Map, Encoding, Req0, St0) ->
    RealmUri = maps:get(realm_uri, St0),
    #{
        <<"username">> := U,
        <<"password">> := P,
        <<"scope">> := _Scope
    } = maps_utils:validate(Map, ?RESOURCE_OWNER_SPEC),
    
    {IP, _Port} = cowboy_req:peer(Req0),
    case juno_security:authenticate(RealmUri, U, P, [{ip, IP}]) of
        {ok, {RealmUri, U, Grants, _}} ->
            %% TODO Scope intersection
            {JWT, Claims} = juno_oauth2:issue_jwt(RealmUri, U, Grants),
            RefreshToken = <<>>,
            #{
                <<"exp">> := Exp,
                <<"scope">> := TScope
            } = Claims,
            Body = #{
                <<"access_token">> => JWT,
                <<"token_type">> => <<"jwt">>,
                <<"expires_in">> => Exp,
                <<"refresh_token">> => RefreshToken,
                <<"scope">> => TScope
            },
            Req1 = cowboy_req:set_resp_body(juno_utils:maybe_encode(Body)),
            {true, Req1, St0};
        {error, Error} ->
            Req1 = reply(Error, Encoding, Req0),
            {stop, Req1, St0}
    end;


accept_flow(#{?GRANT_TYPE := <<"authorization_code">>} = _Map, _, _, _) ->
    error({oauth_flow_not_yet_implemented, <<"authorization_code">>});

accept_flow(#{?GRANT_TYPE := <<"client_credentials">>} = _Map, _, _, _) ->
    error({oauth_flow_not_yet_implemented, <<"client_credentials">>}).



%% @private
-spec reply(integer(), atom(), cowboy_req:req()) -> 
    cowboy_req:req().

reply(invalid_client = Error, Encoding, Req) ->
    Headers = #{<<"www-authenticate">> => <<"Basic">>},
    cowboy_req:reply(
        400, prepare_request(Encoding, error_map(Error), Headers, Req));

reply(unauthorized_client = Error, Encoding, Req) ->
    cowboy_req:reply(
        401, prepare_request(Encoding, error_map(Error), #{}, Req));

reply(unknown_user = Error, Encoding, Req) ->
    cowboy_req:reply(
        401, prepare_request(Encoding, error_map(Error), #{}, Req));

reply(missing_password = Error, Encoding, Req) ->
    cowboy_req:reply(
        401, prepare_request(Encoding, error_map(Error), #{}, Req));

reply(bad_password = Error, Encoding, Req) ->
    cowboy_req:reply(
        401, prepare_request(Encoding, error_map(Error), #{}, Req));

reply(unknown_source = Error, Encoding, Req) ->
    cowboy_req:reply(
        401, prepare_request(Encoding, error_map(Error), #{}, Req));

reply(Error, Encoding, Req) ->
    cowboy_req:reply(
        400, prepare_request(Encoding, error_map(Error), #{}, Req)).






%% @private
error_map(Error) ->
    juno:error_map({Error, <<"TBD">>, <<"TBD">>}).


%% @private
-spec prepare_request(atom(), map(), map(), cowboy_req:req()) -> 
    cowboy_req:req().

prepare_request(Encoding, Body, Headers, Req0) ->
    Req1 = cowboy_req:set_resp_headers(Headers, Req0),
    cowboy_req:set_resp_body(juno_utils:maybe_encode(Encoding, Body), Req1).
