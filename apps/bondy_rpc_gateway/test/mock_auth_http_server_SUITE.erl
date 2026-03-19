-module(mock_auth_http_server_SUITE).

-moduledoc """
Tests for `mock_auth_http_server`.

Verifies all three auth scheme endpoints (OAuth2, OIDC, GIS) and the
upstream echo handler, including failure injection, credential validation,
latency injection, and request logging.
""".

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    %% OAuth2
    oauth2_client_credentials/1,
    oauth2_basic_auth/1,
    oauth2_bad_grant_type/1,
    oauth2_custom_token/1,
    oauth2_invalid_credentials/1,
    oauth2_failure_injection/1,

    %% OIDC
    oidc_discovery/1,
    oidc_jwks/1,
    oidc_token/1,

    %% GIS
    gis_generate_token/1,
    gis_invalid_credentials/1,
    gis_error_in_body/1,
    gis_custom_token/1,

    %% Upstream echo
    upstream_echo_get/1,
    upstream_echo_post/1,
    upstream_custom_response/1,
    upstream_failure_injection/1,

    %% Cross-cutting
    request_log/1,
    request_log_filtered/1,
    latency_injection/1,
    failure_count/1,
    failure_infinity/1,
    reset_clears_all/1
]).


%% ===================================================================
%% CT callbacks
%% ===================================================================

all() ->
    [{group, oauth2},
     {group, oidc},
     {group, gis},
     {group, upstream},
     {group, cross_cutting}].

groups() ->
    [{oauth2, [], [
        oauth2_client_credentials,
        oauth2_basic_auth,
        oauth2_bad_grant_type,
        oauth2_custom_token,
        oauth2_invalid_credentials,
        oauth2_failure_injection
    ]},
    {oidc, [], [
        oidc_discovery,
        oidc_jwks,
        oidc_token
    ]},
    {gis, [], [
        gis_generate_token,
        gis_invalid_credentials,
        gis_error_in_body,
        gis_custom_token
    ]},
    {upstream, [], [
        upstream_echo_get,
        upstream_echo_post,
        upstream_custom_response,
        upstream_failure_injection
    ]},
    {cross_cutting, [], [
        request_log,
        request_log_filtered,
        latency_injection,
        failure_count,
        failure_infinity,
        reset_clears_all
    ]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hackney),
    {ok, Port} = mock_auth_http_server:start(),
    BaseUrl = mock_auth_http_server:base_url(),
    [{mock_port, Port}, {base_url, BaseUrl} | Config].

end_per_suite(_Config) ->
    mock_auth_http_server:stop(),
    ok.

init_per_testcase(_TC, Config) ->
    mock_auth_http_server:reset(),
    Config.

end_per_testcase(_TC, _Config) ->
    ok.


%% ===================================================================
%% OAuth2 tests
%% ===================================================================

oauth2_client_credentials(Config) ->
    Url = <<(base(Config))/binary, "/oauth2/token">>,
    Body = <<"grant_type=client_credentials">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    {ok, 200, _RH, RespBody} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    Decoded = json:decode(RespBody),
    ?assertEqual(<<"mock-oauth2-access-token">>,
                 maps:get(<<"access_token">>, Decoded)),
    ?assertEqual(<<"Bearer">>, maps:get(<<"token_type">>, Decoded)),
    ?assertEqual(3600, maps:get(<<"expires_in">>, Decoded)).

oauth2_basic_auth(Config) ->
    Url = <<(base(Config))/binary, "/oauth2/token">>,
    Body = <<"grant_type=client_credentials">>,
    Creds = base64:encode(<<"myclient:mysecret">>),
    Headers = [
        {<<"Content-Type">>, <<"application/x-www-form-urlencoded">>},
        {<<"Authorization">>, <<"Basic ", Creds/binary>>}
    ],
    %% No credentials configured — should accept anything
    {ok, 200, _RH, _RespBody} =
        hackney:request(post, Url, Headers, Body, [with_body]).

oauth2_bad_grant_type(Config) ->
    Url = <<(base(Config))/binary, "/oauth2/token">>,
    Body = <<"grant_type=password&username=a&password=b">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    {ok, 400, _RH, RespBody} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    Decoded = json:decode(RespBody),
    ?assertEqual(<<"unsupported_grant_type">>,
                 maps:get(<<"error">>, Decoded)).

oauth2_custom_token(Config) ->
    mock_auth_http_server:set_token(oauth2, <<"custom-tok-123">>, 900),
    Url = <<(base(Config))/binary, "/oauth2/token">>,
    Body = <<"grant_type=client_credentials">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    {ok, 200, _RH, RespBody} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    Decoded = json:decode(RespBody),
    ?assertEqual(<<"custom-tok-123">>,
                 maps:get(<<"access_token">>, Decoded)),
    ?assertEqual(900, maps:get(<<"expires_in">>, Decoded)).

oauth2_invalid_credentials(Config) ->
    mock_auth_http_server:set_credentials(
        oauth2, <<"good-id">>, <<"good-secret">>
    ),
    Url = <<(base(Config))/binary, "/oauth2/token">>,
    Body = <<"grant_type=client_credentials"
             "&client_id=bad-id&client_secret=bad-secret">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    {ok, 401, _RH, RespBody} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    Decoded = json:decode(RespBody),
    ?assertEqual(<<"invalid_client">>, maps:get(<<"error">>, Decoded)).

oauth2_failure_injection(Config) ->
    mock_auth_http_server:set_failure(oauth2, 503),
    Url = <<(base(Config))/binary, "/oauth2/token">>,
    Body = <<"grant_type=client_credentials">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    {ok, 503, _RH, _} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    %% Second request should succeed (failure was one-shot)
    {ok, 200, _RH2, _} =
        hackney:request(post, Url, Headers, Body, [with_body]).


%% ===================================================================
%% OIDC tests
%% ===================================================================

oidc_discovery(Config) ->
    Url = <<(base(Config))/binary,
            "/.well-known/openid-configuration">>,
    {ok, 200, _RH, RespBody} =
        hackney:request(get, Url, [], <<>>, [with_body]),
    Decoded = json:decode(RespBody),
    Base = base(Config),
    ?assertEqual(Base, maps:get(<<"issuer">>, Decoded)),
    ?assertMatch(<<_/binary>>,
                 maps:get(<<"token_endpoint">>, Decoded)),
    ?assertMatch(<<_/binary>>,
                 maps:get(<<"jwks_uri">>, Decoded)).

oidc_jwks(Config) ->
    Url = <<(base(Config))/binary, "/oidc/jwks">>,
    {ok, 200, _RH, RespBody} =
        hackney:request(get, Url, [], <<>>, [with_body]),
    Decoded = json:decode(RespBody),
    Keys = maps:get(<<"keys">>, Decoded),
    ?assert(length(Keys) > 0),
    [Key | _] = Keys,
    ?assertEqual(<<"RSA">>, maps:get(<<"kty">>, Key)).

oidc_token(Config) ->
    Url = <<(base(Config))/binary, "/oidc/token">>,
    Body = <<"grant_type=client_credentials">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    {ok, 200, _RH, RespBody} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    Decoded = json:decode(RespBody),
    ?assertEqual(<<"mock-oidc-access-token">>,
                 maps:get(<<"access_token">>, Decoded)),
    ?assertMatch(<<_/binary>>, maps:get(<<"id_token">>, Decoded)).


%% ===================================================================
%% GIS tests
%% ===================================================================

gis_generate_token(Config) ->
    Url = <<(base(Config))/binary,
            "/portal/sharing/rest/generateToken">>,
    Body = <<"username=testuser&password=testpass"
             "&f=json&referer=https://www.example.com">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    {ok, 200, _RH, RespBody} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    Decoded = json:decode(RespBody),
    ?assertEqual(<<"mock-gis-token-abc123">>,
                 maps:get(<<"token">>, Decoded)),
    ?assert(is_integer(maps:get(<<"expires">>, Decoded))),
    %% Should NOT have an error key
    ?assertEqual(error, maps:find(<<"error">>, Decoded)).

gis_invalid_credentials(Config) ->
    mock_auth_http_server:set_credentials(
        gis, <<"admin">>, <<"s3cret">>
    ),
    Url = <<(base(Config))/binary,
            "/portal/sharing/rest/generateToken">>,
    Body = <<"username=wrong&password=wrong&f=json">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    %% GIS returns 200 even on auth errors
    {ok, 200, _RH, RespBody} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    Decoded = json:decode(RespBody),
    ErrorObj = maps:get(<<"error">>, Decoded),
    ?assertEqual(400, maps:get(<<"code">>, ErrorObj)),
    ?assertMatch(<<_/binary>>, maps:get(<<"message">>, ErrorObj)).

gis_error_in_body(Config) ->
    %% Even with correct credentials, GIS returns errors in body with 200
    mock_auth_http_server:set_credentials(
        gis, <<"admin">>, <<"s3cret">>
    ),
    Url = <<(base(Config))/binary,
            "/portal/sharing/rest/generateToken">>,
    %% Send correct credentials
    Body = <<"username=admin&password=s3cret&f=json">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    {ok, 200, _RH, RespBody} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    Decoded = json:decode(RespBody),
    %% Should have token, no error
    ?assertMatch(<<_/binary>>, maps:get(<<"token">>, Decoded)),
    ?assertEqual(error, maps:find(<<"error">>, Decoded)).

gis_custom_token(Config) ->
    mock_auth_http_server:set_token(gis, <<"custom-gis-tok">>),
    mock_auth_http_server:set_expires_in(gis, 9999999999),
    Url = <<(base(Config))/binary,
            "/portal/sharing/rest/generateToken">>,
    Body = <<"username=any&password=any&f=json">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    {ok, 200, _RH, RespBody} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    Decoded = json:decode(RespBody),
    ?assertEqual(<<"custom-gis-tok">>, maps:get(<<"token">>, Decoded)),
    ?assertEqual(9999999999, maps:get(<<"expires">>, Decoded)).


%% ===================================================================
%% Upstream echo tests
%% ===================================================================

upstream_echo_get(Config) ->
    Url = <<(base(Config))/binary, "/api/invoices?status=paid">>,
    {ok, 200, _RH, RespBody} =
        hackney:request(get, Url, [], <<>>, [with_body]),
    Decoded = json:decode(RespBody),
    ?assertEqual(<<"GET">>, maps:get(<<"method">>, Decoded)),
    ?assertEqual(<<"/api/invoices">>, maps:get(<<"path">>, Decoded)),
    Query = maps:get(<<"query">>, Decoded),
    ?assertEqual(<<"paid">>, maps:get(<<"status">>, Query)).

upstream_echo_post(Config) ->
    Url = <<(base(Config))/binary, "/api/invoices">>,
    ReqBody = iolist_to_binary(json:encode(#{<<"amount">> => 100})),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    {ok, 200, _RH, RespBody} =
        hackney:request(post, Url, Headers, ReqBody, [with_body]),
    Decoded = json:decode(RespBody),
    ?assertEqual(<<"POST">>, maps:get(<<"method">>, Decoded)),
    %% Body is echoed back as-is (binary)
    EchoedBody = maps:get(<<"body">>, Decoded),
    ?assertEqual(#{<<"amount">> => 100},
                 json:decode(EchoedBody)).

upstream_custom_response(Config) ->
    ErrBody = iolist_to_binary(json:encode(#{<<"error">> => <<"forbidden">>})),
    mock_auth_http_server:set_upstream_response(403, ErrBody),
    Url = <<(base(Config))/binary, "/api/anything">>,
    {ok, 403, _RH, RespBody} =
        hackney:request(get, Url, [], <<>>, [with_body]),
    Decoded = json:decode(RespBody),
    ?assertEqual(<<"forbidden">>, maps:get(<<"error">>, Decoded)).

upstream_failure_injection(Config) ->
    mock_auth_http_server:set_failure(upstream, 500),
    Url = <<(base(Config))/binary, "/api/test">>,
    {ok, 500, _RH, _} =
        hackney:request(get, Url, [], <<>>, [with_body]),
    %% One-shot: next request succeeds
    {ok, 200, _RH2, _} =
        hackney:request(get, Url, [], <<>>, [with_body]).


%% ===================================================================
%% Cross-cutting tests
%% ===================================================================

request_log(Config) ->
    mock_auth_http_server:clear_requests(),
    Url = <<(base(Config))/binary, "/oauth2/token">>,
    Body = <<"grant_type=client_credentials">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    {ok, 200, _, _} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    Requests = mock_auth_http_server:get_requests(),
    ?assertEqual(1, length(Requests)),
    [Req] = Requests,
    ?assertEqual(oauth2, maps:get(scheme, Req)),
    ?assertEqual(<<"POST">>, maps:get(method, Req)).

request_log_filtered(Config) ->
    mock_auth_http_server:clear_requests(),
    %% Hit two different endpoints
    OAuthUrl = <<(base(Config))/binary, "/oauth2/token">>,
    GisUrl = <<(base(Config))/binary,
               "/portal/sharing/rest/generateToken">>,
    Body = <<"grant_type=client_credentials">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    {ok, 200, _, _} =
        hackney:request(post, OAuthUrl, Headers, Body, [with_body]),
    {ok, 200, _, _} =
        hackney:request(post, GisUrl, Headers,
                        <<"username=a&password=b&f=json">>, [with_body]),
    ?assertEqual(1, length(mock_auth_http_server:get_requests(oauth2))),
    ?assertEqual(1, length(mock_auth_http_server:get_requests(gis))),
    ?assertEqual(2, length(mock_auth_http_server:get_requests())).

latency_injection(Config) ->
    mock_auth_http_server:set_latency(oauth2, 200),
    Url = <<(base(Config))/binary, "/oauth2/token">>,
    Body = <<"grant_type=client_credentials">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    T0 = erlang:monotonic_time(millisecond),
    {ok, 200, _, _} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assert(Elapsed >= 150). %% Allow some slack

failure_count(Config) ->
    %% Fail exactly 2 times, then succeed
    mock_auth_http_server:set_failure(oauth2, 503, 2),
    Url = <<(base(Config))/binary, "/oauth2/token">>,
    Body = <<"grant_type=client_credentials">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    {ok, 503, _, _} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    {ok, 503, _, _} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    {ok, 200, _, _} =
        hackney:request(post, Url, Headers, Body, [with_body]).

failure_infinity(Config) ->
    mock_auth_http_server:set_failure(oauth2, 500, infinity),
    Url = <<(base(Config))/binary, "/oauth2/token">>,
    Body = <<"grant_type=client_credentials">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    %% Should keep failing
    {ok, 500, _, _} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    {ok, 500, _, _} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    {ok, 500, _, _} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    %% Clear and verify recovery
    mock_auth_http_server:clear_failure(oauth2),
    {ok, 200, _, _} =
        hackney:request(post, Url, Headers, Body, [with_body]).

reset_clears_all(Config) ->
    mock_auth_http_server:set_token(oauth2, <<"temp">>),
    mock_auth_http_server:set_failure(gis, 500, infinity),
    mock_auth_http_server:set_latency(oidc, 1000),
    mock_auth_http_server:set_credentials(
        oauth2, <<"id">>, <<"secret">>
    ),
    mock_auth_http_server:reset(),
    %% OAuth2 should use default token, no credentials required
    Url = <<(base(Config))/binary, "/oauth2/token">>,
    Body = <<"grant_type=client_credentials">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    {ok, 200, _, RespBody} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    Decoded = json:decode(RespBody),
    ?assertEqual(<<"mock-oauth2-access-token">>,
                 maps:get(<<"access_token">>, Decoded)).


%% ===================================================================
%% Helpers
%% ===================================================================

base(Config) ->
    proplists:get_value(base_url, Config).
