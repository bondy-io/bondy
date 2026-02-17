-module(mock_auth_http_server).

-moduledoc """
Cowboy-based HTTP mock server for testing OAuth2, OIDC, and custom
token authentication schemes.

Designed for use in Common Test suites. Start in `init_per_suite/1`,
stop in `end_per_suite/1`. Behavior is configurable at runtime via
ETS so individual test cases can inject failures, custom tokens,
or latency.

## Supported auth schemes

### OAuth2 (client_credentials)

    POST /oauth2/token
    Authorization: Basic base64(client_id:client_secret)
    Content-Type: application/x-www-form-urlencoded
    Body: grant_type=client_credentials

    Response 200:
    {"access_token":"...","token_type":"Bearer","expires_in":3600}

### OIDC (OpenID Connect)

    GET  /.well-known/openid-configuration  -> discovery document
    GET  /oidc/jwks                         -> JWKS
    POST /oidc/token                        -> token (same flow as OAuth2)
    GET  /oidc/userinfo                     -> userinfo

### Custom token scheme (GIS-style)

    POST /portal/sharing/rest/generateToken
    Content-Type: application/x-www-form-urlencoded
    Body: username=...&password=...&f=json&referer=...

    Response 200 (success):
    {"token":"...","expires":1234567890}

    Response 200 (error — GIS returns 200 with error in body):
    {"error":{"code":400,"message":"Invalid credentials","details":[]}}

### Upstream echo (for proxy integration testing)

    ANY /api/[...]

    Response 200:
    {"method":"GET","path":"/api/...","headers":{...},
     "body":"...","query":{...}}

## Usage

    init_per_suite(Config) ->
        {ok, Port} = mock_auth_http_server:start(),
        [{mock_port, Port} | Config].

    end_per_suite(_Config) ->
        mock_auth_http_server:stop().

    my_test_case(_Config) ->
        %% Force a 401 on the next OAuth2 token request
        mock_auth_http_server:set_failure(oauth2, 401),
        ...
        mock_auth_http_server:reset().

    my_gis_test(_Config) ->
        %% Require specific GIS credentials
        mock_auth_http_server:set_credentials(gis, <<"admin">>, <<"s3cret">>),
        ...
        %% Verify what was sent
        [Req] = mock_auth_http_server:get_requests(gis),
        <<"POST">> = maps:get(method, Req).
""".

%% Public API
-export([start/0, start/1, stop/0]).
-export([port/0, base_url/0]).

%% Token configuration
-export([set_token/2, set_token/3]).
-export([set_token_type/2]).
-export([set_expires_in/2]).

%% Failure injection
-export([set_failure/2, set_failure/3]).
-export([clear_failure/1]).

%% Latency injection
-export([set_latency/2]).

%% Credential validation (for negative testing)
-export([set_credentials/3]).

%% Upstream echo configuration
-export([set_upstream_response/2]).

%% Request inspection
-export([get_requests/0, get_requests/1, clear_requests/0]).

%% Reset all config
-export([reset/0]).

%% Cowboy handler callback
-export([init/2]).

-include_lib("kernel/include/logger.hrl").

-define(TABLE, mock_auth_http_state).
-define(LISTENER, mock_auth_http_listener).
-define(ETS_OWNER, mock_auth_http_ets_owner).

-define(DEFAULT_OAUTH2_TOKEN, <<"mock-oauth2-access-token">>).
-define(DEFAULT_OIDC_TOKEN, <<"mock-oidc-access-token">>).
-define(DEFAULT_GIS_TOKEN, <<"mock-gis-token-abc123">>).
-define(DEFAULT_EXPIRES_IN, 3600).
-define(DEFAULT_GIS_EXPIRES, 1893456000). %% 2030-01-01
-define(DEFAULT_TOKEN_TYPE, <<"Bearer">>).


%% ===================================================================
%% Public API
%% ===================================================================

-doc """
Start the mock server on a random port.

Returns `{ok, Port}` where `Port` is the actual TCP port.
""".
-spec start() -> {ok, pos_integer()}.
start() ->
    start(#{}).

-doc """
Start the mock server with options.

Options:
- `port` — TCP port to listen on (default: 0 = random)
""".
-spec start(map()) -> {ok, pos_integer()}.
start(Opts) ->
    %% Ensure cowboy and its deps are running
    {ok, _} = application:ensure_all_started(cowboy),

    start_ets_owner(),

    %% Initialize defaults
    init_defaults(),

    Port = maps:get(port, Opts, 0),

    Dispatch = cowboy_router:compile([
        {'_', [
            {"/oauth2/token", ?MODULE, {oauth2, token}},
            {"/.well-known/openid-configuration", ?MODULE, {oidc, discovery}},
            {"/oidc/jwks", ?MODULE, {oidc, jwks}},
            {"/oidc/token", ?MODULE, {oidc, token}},
            {"/oidc/userinfo", ?MODULE, {oidc, userinfo}},
            {"/portal/sharing/rest/generateToken", ?MODULE, {gis, token}},
            {"/api/[...]", ?MODULE, {upstream, echo}}
        ]}
    ]),

    {ok, _} = cowboy:start_clear(?LISTENER,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),

    ActualPort = ranch:get_port(?LISTENER),
    ets:insert(?TABLE, {port, ActualPort}),
    {ok, ActualPort}.

-doc "Stop the mock server and clean up.".
-spec stop() -> ok.
stop() ->
    cowboy:stop_listener(?LISTENER),
    case whereis(?ETS_OWNER) of
        undefined -> ok;
        Pid -> Pid ! stop
    end,
    ok.

-doc "Return the port the mock server is listening on.".
-spec port() -> pos_integer().
port() ->
    case ets:lookup(?TABLE, port) of
        [{port, P}] -> P;
        [] -> error(not_started)
    end.

-doc "Return `http://localhost:Port` for the running mock server.".
-spec base_url() -> binary().
base_url() ->
    iolist_to_binary(
        io_lib:format("http://localhost:~B", [port()])
    ).


%% ===================================================================
%% Token configuration
%% ===================================================================

-doc """
Set the token returned by the given scheme.

Scheme is `oauth2 | oidc | gis`.
""".
-spec set_token(atom(), binary()) -> true.
set_token(oauth2, Token) -> ets:insert(?TABLE, {oauth2_token, Token});
set_token(oidc, Token)   -> ets:insert(?TABLE, {oidc_token, Token});
set_token(gis, Token)    -> ets:insert(?TABLE, {gis_token, Token}).

-doc "Set the token and expiry for the given scheme.".
-spec set_token(atom(), binary(), integer()) -> true.
set_token(Scheme, Token, ExpiresIn) ->
    set_token(Scheme, Token),
    set_expires_in(Scheme, ExpiresIn).

-doc "Set the expires_in (or expires for GIS) value.".
-spec set_expires_in(atom(), integer()) -> true.
set_expires_in(oauth2, V) -> ets:insert(?TABLE, {oauth2_expires_in, V});
set_expires_in(oidc, V)   -> ets:insert(?TABLE, {oidc_expires_in, V});
set_expires_in(gis, V)    -> ets:insert(?TABLE, {gis_expires, V}).

-doc """
Set the token_type returned in OAuth2/OIDC token responses.

Default is `<<"Bearer">>` per RFC 6750. Use this to test clients
that read token_type from the response (e.g. some OAuth2 providers).
""".
-spec set_token_type(atom(), binary()) -> true.
set_token_type(oauth2, V) -> ets:insert(?TABLE, {oauth2_token_type, V});
set_token_type(oidc, V)   -> ets:insert(?TABLE, {oidc_token_type, V}).


%% ===================================================================
%% Failure injection
%% ===================================================================

-doc """
Force the next request for this scheme to fail with `StatusCode`.

Equivalent to `set_failure(Scheme, StatusCode, 1)`.
""".
-spec set_failure(atom(), integer()) -> true.
set_failure(Scheme, StatusCode) ->
    set_failure(Scheme, StatusCode, 1).

-doc """
Force the next `Count` requests for this scheme to fail.

Use `infinity` to fail indefinitely until `clear_failure/1` or `reset/0`.
Scheme can be `oauth2 | oidc | gis | upstream`.
""".
-spec set_failure(atom(), integer(), pos_integer() | infinity) -> true.
set_failure(Scheme, StatusCode, Count) ->
    ets:insert(?TABLE, {{failure, Scheme}, {StatusCode, Count}}).

-doc "Clear any injected failure for the given scheme.".
-spec clear_failure(atom()) -> true.
clear_failure(Scheme) ->
    ets:delete(?TABLE, {failure, Scheme}).


%% ===================================================================
%% Latency injection
%% ===================================================================

-doc "Inject `Ms` milliseconds of latency before responding.".
-spec set_latency(atom(), non_neg_integer()) -> true.
set_latency(Scheme, Ms) ->
    ets:insert(?TABLE, {{latency, Scheme}, Ms}).


%% ===================================================================
%% Credential validation
%% ===================================================================

-doc """
Require specific credentials for the given scheme.

By default any credentials are accepted. Use this to test
invalid-credential paths.

For `oauth2` and `oidc`: `Id` is the client_id, `Secret` the client_secret.
For `gis`: `Id` is the username, `Secret` the password.
""".
-spec set_credentials(atom(), binary(), binary()) -> true.
set_credentials(Scheme, Id, Secret) ->
    ets:insert(?TABLE, {{credentials, Scheme}, {Id, Secret}}).


%% ===================================================================
%% Upstream echo configuration
%% ===================================================================

-doc """
Override the upstream echo handler response.

By default the echo handler returns 200 with request details.
Use this to test upstream error handling (e.g. 401/403 retry logic).
""".
-spec set_upstream_response(integer(), binary()) -> true.
set_upstream_response(StatusCode, Body) ->
    ets:insert(?TABLE, {upstream_response, {StatusCode, Body}}).


%% ===================================================================
%% Request inspection
%% ===================================================================

-doc "Return all logged requests in chronological order.".
-spec get_requests() -> [map()].
get_requests() ->
    case ets:lookup(?TABLE, requests) of
        [{requests, Rs}] -> lists:reverse(Rs);
        [] -> []
    end.

-doc "Return logged requests filtered by scheme.".
-spec get_requests(atom()) -> [map()].
get_requests(Scheme) ->
    [R || R = #{scheme := S} <- get_requests(), S =:= Scheme].

-doc "Clear the request log.".
-spec clear_requests() -> true.
clear_requests() ->
    ets:insert(?TABLE, {requests, []}).


%% ===================================================================
%% Reset
%% ===================================================================

-doc "Reset all configuration to defaults and clear the request log.".
-spec reset() -> ok.
reset() ->
    init_defaults(),
    lists:foreach(
        fun(Scheme) ->
            ets:delete(?TABLE, {failure, Scheme}),
            ets:delete(?TABLE, {latency, Scheme}),
            ets:delete(?TABLE, {credentials, Scheme})
        end,
        [oauth2, oidc, gis, upstream]
    ),
    ets:delete(?TABLE, upstream_response),
    ok.


%% ===================================================================
%% Cowboy handler
%% ===================================================================

-doc false.
init(Req, {Scheme, Action} = State) ->
    log_request(Scheme, Req),
    maybe_inject_latency(Scheme),
    case check_failure(Scheme) of
        {fail, StatusCode} ->
            Body = iolist_to_binary(json:encode(#{<<"error">> => <<"injected_failure">>})),
            Req2 = cowboy_req:reply(StatusCode,
                #{<<"content-type">> => <<"application/json">>},
                Body, Req),
            {ok, Req2, State};
        ok ->
            handle(Scheme, Action, Req, State)
    end.


%% --- OAuth2 client_credentials ---

handle(oauth2, token, Req0, State) ->
    {ok, RawBody, Req} = cowboy_req:read_body(Req0),
    Params = cow_qs:parse_qs(RawBody),
    GrantType = proplists:get_value(<<"grant_type">>, Params),

    case GrantType of
        <<"client_credentials">> ->
            case check_credentials(oauth2, Req, Params) of
                ok ->
                    [{oauth2_token, Token}] =
                        ets:lookup(?TABLE, oauth2_token),
                    [{oauth2_expires_in, Exp}] =
                        ets:lookup(?TABLE, oauth2_expires_in),
                    [{oauth2_token_type, TType}] =
                        ets:lookup(?TABLE, oauth2_token_type),
                    RespBody = iolist_to_binary(json:encode(#{
                        <<"access_token">> => Token,
                        <<"token_type">> => TType,
                        <<"expires_in">> => Exp
                    })),
                    reply_json(200, RespBody, Req, State);
                {error, Msg} ->
                    RespBody = iolist_to_binary(json:encode(#{
                        <<"error">> => <<"invalid_client">>,
                        <<"error_description">> => Msg
                    })),
                    reply_json(401, RespBody, Req, State)
            end;
        _ ->
            RespBody = iolist_to_binary(json:encode(#{
                <<"error">> => <<"unsupported_grant_type">>,
                <<"error_description">> =>
                    <<"Only client_credentials is supported">>
            })),
            reply_json(400, RespBody, Req, State)
    end;


%% --- OIDC discovery ---

handle(oidc, discovery, Req, State) ->
    Base = base_url(),
    Doc = iolist_to_binary(json:encode(#{
        <<"issuer">> => Base,
        <<"authorization_endpoint">> =>
            <<Base/binary, "/oidc/authorize">>,
        <<"token_endpoint">> =>
            <<Base/binary, "/oidc/token">>,
        <<"userinfo_endpoint">> =>
            <<Base/binary, "/oidc/userinfo">>,
        <<"jwks_uri">> =>
            <<Base/binary, "/oidc/jwks">>,
        <<"response_types_supported">> =>
            [<<"code">>, <<"token">>],
        <<"subject_types_supported">> =>
            [<<"public">>],
        <<"id_token_signing_alg_values_supported">> =>
            [<<"RS256">>],
        <<"grant_types_supported">> =>
            [<<"authorization_code">>, <<"client_credentials">>],
        <<"token_endpoint_auth_methods_supported">> =>
            [<<"client_secret_basic">>, <<"client_secret_post">>]
    })),
    reply_json(200, Doc, Req, State);


%% --- OIDC JWKS ---

handle(oidc, jwks, Req, State) ->
    %% Static placeholder JWKS. The gateway doesn't validate JWTs
    %% itself — it just passes tokens through — so a stub is fine.
    JWKS = iolist_to_binary(json:encode(#{
        <<"keys">> => [#{
            <<"kty">> => <<"RSA">>,
            <<"use">> => <<"sig">>,
            <<"kid">> => <<"mock-key-1">>,
            <<"alg">> => <<"RS256">>,
            <<"n">> => <<"0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbW"
                         "hM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc"
                         "_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ">>,
            <<"e">> => <<"AQAB">>
        }]
    })),
    reply_json(200, JWKS, Req, State);


%% --- OIDC token ---

handle(oidc, token, Req0, State) ->
    {ok, RawBody, Req} = cowboy_req:read_body(Req0),
    Params = cow_qs:parse_qs(RawBody),
    GrantType = proplists:get_value(<<"grant_type">>, Params),

    case GrantType of
        <<"client_credentials">> ->
            case check_credentials(oidc, Req, Params) of
                ok ->
                    [{oidc_token, Token}] =
                        ets:lookup(?TABLE, oidc_token),
                    [{oidc_expires_in, Exp}] =
                        ets:lookup(?TABLE, oidc_expires_in),
                    [{oidc_token_type, TType}] =
                        ets:lookup(?TABLE, oidc_token_type),
                    RespBody = iolist_to_binary(json:encode(#{
                        <<"access_token">> => Token,
                        <<"token_type">> => TType,
                        <<"expires_in">> => Exp,
                        <<"id_token">> => <<"mock-id-token">>
                    })),
                    reply_json(200, RespBody, Req, State);
                {error, Msg} ->
                    RespBody = iolist_to_binary(json:encode(#{
                        <<"error">> => <<"invalid_client">>,
                        <<"error_description">> => Msg
                    })),
                    reply_json(401, RespBody, Req, State)
            end;
        _ ->
            RespBody = iolist_to_binary(json:encode(#{
                <<"error">> => <<"unsupported_grant_type">>
            })),
            reply_json(400, RespBody, Req, State)
    end;


%% --- OIDC userinfo ---

handle(oidc, userinfo, Req, State) ->
    RespBody = iolist_to_binary(json:encode(#{
        <<"sub">> => <<"mock-user-001">>,
        <<"name">> => <<"Mock User">>,
        <<"email">> => <<"mock@example.com">>
    })),
    reply_json(200, RespBody, Req, State);


%% --- GIS custom scheme ---

handle(gis, token, Req0, State) ->
    {ok, RawBody, Req} = cowboy_req:read_body(Req0),
    Params = cow_qs:parse_qs(RawBody),

    Username = proplists:get_value(<<"username">>, Params),
    Password = proplists:get_value(<<"password">>, Params),

    case check_gis_credentials(Username, Password) of
        ok ->
            [{gis_token, Token}] = ets:lookup(?TABLE, gis_token),
            [{gis_expires, Expires}] = ets:lookup(?TABLE, gis_expires),
            RespBody = iolist_to_binary(json:encode(#{
                <<"token">> => Token,
                <<"expires">> => Expires
            })),
            %% GIS always returns 200 for the token endpoint
            reply_json(200, RespBody, Req, State);
        {error, Msg} ->
            %% GIS returns 200 with error in body (not an HTTP error)
            RespBody = iolist_to_binary(json:encode(#{
                <<"error">> => #{
                    <<"code">> => 400,
                    <<"message">> => Msg,
                    <<"details">> => []
                }
            })),
            reply_json(200, RespBody, Req, State)
    end;


%% --- Upstream echo ---

handle(upstream, echo, Req0, State) ->
    case ets:lookup(?TABLE, upstream_response) of
        [{upstream_response, {StatusCode, Body}}] ->
            Req = cowboy_req:reply(StatusCode,
                #{<<"content-type">> => <<"application/json">>},
                Body, Req0),
            {ok, Req, State};
        [] ->
            Method = cowboy_req:method(Req0),
            Path = cowboy_req:path(Req0),
            QsPairs = cowboy_req:parse_qs(Req0),
            Headers = cowboy_req:headers(Req0),

            {ok, Body, Req} = cowboy_req:read_body(Req0),

            QueryMap = maps:from_list(QsPairs),

            RespBody = iolist_to_binary(json:encode(#{
                <<"method">> => Method,
                <<"path">> => Path,
                <<"query">> => QueryMap,
                <<"headers">> => Headers,
                <<"body">> => Body
            })),
            reply_json(200, RespBody, Req, State)
    end.


%% ===================================================================
%% Internal helpers
%% ===================================================================

start_ets_owner() ->
    case whereis(?ETS_OWNER) of
        undefined ->
            Parent = self(),
            Pid = spawn(fun() ->
                ets:new(?TABLE, [named_table, public, set]),
                Parent ! {ets_ready, self()},
                ets_owner_loop()
            end),
            register(?ETS_OWNER, Pid),
            receive {ets_ready, Pid} -> ok end;
        _ ->
            ets:delete_all_objects(?TABLE)
    end.

ets_owner_loop() ->
    receive
        stop -> ok
    end.

init_defaults() ->
    ets:insert(?TABLE, [
        {oauth2_token, ?DEFAULT_OAUTH2_TOKEN},
        {oidc_token, ?DEFAULT_OIDC_TOKEN},
        {gis_token, ?DEFAULT_GIS_TOKEN},
        {oauth2_expires_in, ?DEFAULT_EXPIRES_IN},
        {oidc_expires_in, ?DEFAULT_EXPIRES_IN},
        {gis_expires, ?DEFAULT_GIS_EXPIRES},
        {oauth2_token_type, ?DEFAULT_TOKEN_TYPE},
        {oidc_token_type, ?DEFAULT_TOKEN_TYPE},
        {requests, []}
    ]).

reply_json(Status, Body, Req0, State) ->
    Req = cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>},
        Body, Req0),
    {ok, Req, State}.

log_request(Scheme, Req) ->
    Entry = #{
        scheme => Scheme,
        method => cowboy_req:method(Req),
        path => cowboy_req:path(Req),
        headers => cowboy_req:headers(Req),
        qs => cowboy_req:qs(Req),
        timestamp => erlang:system_time(millisecond)
    },
    case ets:lookup(?TABLE, requests) of
        [{requests, Rs}] ->
            ets:insert(?TABLE, {requests, [Entry | Rs]});
        [] ->
            ets:insert(?TABLE, {requests, [Entry]})
    end.

maybe_inject_latency(Scheme) ->
    case ets:lookup(?TABLE, {latency, Scheme}) of
        [{{latency, _}, Ms}] -> timer:sleep(Ms);
        [] -> ok
    end.

check_failure(Scheme) ->
    case ets:lookup(?TABLE, {failure, Scheme}) of
        [{{failure, _}, {StatusCode, infinity}}] ->
            {fail, StatusCode};
        [{{failure, _}, {StatusCode, Count}}] when Count > 1 ->
            ets:insert(?TABLE, {{failure, Scheme}, {StatusCode, Count - 1}}),
            {fail, StatusCode};
        [{{failure, _}, {StatusCode, _}}] ->
            ets:delete(?TABLE, {failure, Scheme}),
            {fail, StatusCode};
        [] ->
            ok
    end.

check_credentials(Scheme, Req, Params) ->
    case ets:lookup(?TABLE, {credentials, Scheme}) of
        [] ->
            %% No credentials configured — accept anything
            ok;
        [{{credentials, _}, {ExpectedId, ExpectedSecret}}] ->
            case parse_basic_auth(Req) of
                {ok, ClientId, ClientSecret} ->
                    case {ClientId, ClientSecret} of
                        {ExpectedId, ExpectedSecret} -> ok;
                        _ -> {error, <<"Invalid client credentials">>}
                    end;
                error ->
                    %% Fall back to form body params
                    FormId = proplists:get_value(
                        <<"client_id">>, Params
                    ),
                    FormSecret = proplists:get_value(
                        <<"client_secret">>, Params
                    ),
                    case {FormId, FormSecret} of
                        {ExpectedId, ExpectedSecret} -> ok;
                        _ -> {error, <<"Invalid client credentials">>}
                    end
            end
    end.

check_gis_credentials(Username, Password) ->
    case ets:lookup(?TABLE, {credentials, gis}) of
        [] ->
            ok;
        [{{credentials, gis}, {ExpectedUser, ExpectedPass}}] ->
            case {Username, Password} of
                {ExpectedUser, ExpectedPass} -> ok;
                _ -> {error, <<"Invalid username or password.">>}
            end
    end.

parse_basic_auth(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Basic ", Encoded/binary>> ->
            Decoded = base64:decode(Encoded),
            case binary:split(Decoded, <<":">>) of
                [User, Pass] -> {ok, User, Pass};
                _ -> error
            end;
        <<"basic ", Encoded/binary>> ->
            Decoded = base64:decode(Encoded),
            case binary:split(Decoded, <<":">>) of
                [User, Pass] -> {ok, User, Pass};
                _ -> error
            end;
        _ ->
            error
    end.
