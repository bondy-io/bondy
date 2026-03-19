-module(bondy_rpc_gateway_auth_integration_SUITE).

-moduledoc """
Integration tests for `bondy_rpc_gateway_auth_generic` against
`mock_auth_http_server`.

Exercises `fetch_token/1` and `apply_auth/4` for two auth schemes:

- **OAuth2 (client_credentials)** — `client_credentials` grant with Basic auth
  on the token request, token placed as `Authorization: Bearer {token}` header
  on forwarded requests.

- **Custom token (form-encoded)** — Form-encoded username/password token
  request, token placed as a `?token={token}` query parameter.

These tests use `mock_auth_http_server` as the upstream token endpoint
and verify the full round-trip: config -> HTTP fetch -> token extraction ->
header/URL placement.

### OAuth2 config equivalent (bondy.conf)

    rpc_gateway.services.my_api.auth.fetch.method = post
    rpc_gateway.services.my_api.auth.fetch.url = {{token_endpoint}}
    rpc_gateway.services.my_api.auth.fetch.body_encoding = form
    rpc_gateway.services.my_api.auth.fetch.body.grant_type = client_credentials
    rpc_gateway.services.my_api.auth.fetch.token_path = access_token
    rpc_gateway.services.my_api.auth.fetch.expires_in_path = expires_in
    rpc_gateway.services.my_api.auth.fetch.basic_auth.username = {{client_id}}
    rpc_gateway.services.my_api.auth.fetch.basic_auth.password = {{client_secret}}

    rpc_gateway.services.my_api.auth.apply.placement = header
    rpc_gateway.services.my_api.auth.apply.name = Authorization
    rpc_gateway.services.my_api.auth.apply.format = Bearer {{token}}

    rpc_gateway.services.my_api.auth.vars.token_endpoint = https://idp.example.com/token
    rpc_gateway.services.my_api.auth.vars.client_id = my-app
    rpc_gateway.services.my_api.auth.vars.client_secret = s3cret

### Custom token config equivalent (bondy.conf)

    rpc_gateway.services.gis.auth.fetch.method = post
    rpc_gateway.services.gis.auth.fetch.url = {{base_url}}/portal/sharing/rest/generateToken
    rpc_gateway.services.gis.auth.fetch.body_encoding = form
    rpc_gateway.services.gis.auth.fetch.body.username = {{username}}
    rpc_gateway.services.gis.auth.fetch.body.password = {{password}}
    rpc_gateway.services.gis.auth.fetch.body.f = json
    rpc_gateway.services.gis.auth.fetch.body.referer = https://www.example.com
    rpc_gateway.services.gis.auth.fetch.token_path = token
    rpc_gateway.services.gis.auth.fetch.error_path = error.message

    rpc_gateway.services.gis.auth.apply.placement = query_param
    rpc_gateway.services.gis.auth.apply.name = token

    rpc_gateway.services.gis.auth.vars.base_url = https://gis.example.com
    rpc_gateway.services.gis.auth.vars.username = admin
    rpc_gateway.services.gis.auth.vars.password = hunter2
""".

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    %% OAuth2 client_credentials scheme
    cc_fetch_token/1,
    cc_fetch_token_with_expires_in/1,
    cc_apply_auth_bearer_header/1,
    cc_fetch_basic_auth_sent/1,
    cc_fetch_invalid_credentials/1,
    cc_fetch_server_error/1,
    cc_custom_token_type/1,

    %% GIS custom scheme
    gis_fetch_token/1,
    gis_apply_auth_query_param/1,
    gis_fetch_error_in_body/1,
    gis_fetch_no_token_in_response/1
]).


%% ===================================================================
%% CT callbacks
%% ===================================================================

all() ->
    [{group, cc_oauth2},
     {group, gis_custom}].

groups() ->
    [{cc_oauth2, [], [
        cc_fetch_token,
        cc_fetch_token_with_expires_in,
        cc_apply_auth_bearer_header,
        cc_fetch_basic_auth_sent,
        cc_fetch_invalid_credentials,
        cc_fetch_server_error,
        cc_custom_token_type
    ]},
    {gis_custom, [], [
        gis_fetch_token,
        gis_apply_auth_query_param,
        gis_fetch_error_in_body,
        gis_fetch_no_token_in_response
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
%% OAuth2 client_credentials tests
%% ===================================================================

cc_fetch_token(Config) ->
    %% POST token endpoint with Basic auth header,
    %% form body grant_type=client_credentials,
    %% extract access_token from response.
    Conf = cc_config(Config),
    {ok, {Token, _Meta}} = bondy_rpc_gateway_auth_generic:fetch_token(Conf),
    ?assertEqual(<<"mock-oauth2-access-token">>, Token).

cc_fetch_token_with_expires_in(Config) ->
    %% Verify expires_in metadata is extracted from the response
    mock_auth_http_server:set_token(oauth2, <<"tok-xyz">>, 900),
    Conf = cc_config(Config),
    {ok, {Token, Meta}} = bondy_rpc_gateway_auth_generic:fetch_token(Conf),
    ?assertEqual(<<"tok-xyz">>, Token),
    ?assertEqual(900, maps:get(expires_in, Meta)).

cc_apply_auth_bearer_header(_Config) ->
    %% Verify token is placed as Authorization: Bearer {token}
    Conf = cc_config_apply_only(),
    Url = <<"https://api.example.com/v1/resources">>,
    {ResultUrl, ResultHeaders} =
        bondy_rpc_gateway_auth_generic:apply_auth(
            <<"eyJabc123">>, Url, [], Conf
        ),
    %% URL should be unchanged (token goes in header, not query)
    ?assertEqual(Url, ResultUrl),
    %% Authorization header should have Bearer prefix
    ?assertEqual(
        [{<<"Authorization">>, <<"Bearer eyJabc123">>}],
        ResultHeaders
    ).

cc_fetch_basic_auth_sent(Config) ->
    %% Verify the mock received a Basic auth header on the token request
    mock_auth_http_server:set_credentials(
        oauth2, <<"test-client">>, <<"test-secret">>
    ),
    Conf = cc_config_with_creds(Config,
        <<"test-client">>, <<"test-secret">>
    ),
    {ok, {_Token, _Meta}} = bondy_rpc_gateway_auth_generic:fetch_token(Conf),
    %% Verify Basic auth was sent
    [Req] = mock_auth_http_server:get_requests(oauth2),
    Headers = maps:get(headers, Req),
    AuthHeader = maps:get(<<"authorization">>, Headers),
    Expected = <<"Basic ",
        (base64:encode(<<"test-client:test-secret">>))/binary>>,
    ?assertEqual(Expected, AuthHeader).

cc_fetch_invalid_credentials(Config) ->
    %% Mock requires specific credentials, but we send wrong ones
    mock_auth_http_server:set_credentials(
        oauth2, <<"good-id">>, <<"good-secret">>
    ),
    Conf = cc_config_with_creds(Config,
        <<"bad-id">>, <<"bad-secret">>
    ),
    Result = bondy_rpc_gateway_auth_generic:fetch_token(Conf),
    ?assertMatch({error, {http_status, 401}}, Result).

cc_fetch_server_error(Config) ->
    %% Token endpoint returns 500
    mock_auth_http_server:set_failure(oauth2, 500),
    Conf = cc_config(Config),
    Result = bondy_rpc_gateway_auth_generic:fetch_token(Conf),
    ?assertMatch({error, {http_status, 500}}, Result).

cc_custom_token_type(Config) ->
    %% Verify the mock returns token_type correctly and it can be used
    %% in the format string.
    mock_auth_http_server:set_token_type(oauth2, <<"Bearer">>),
    Conf = cc_config(Config),
    {ok, {Token, _Meta}} = bondy_rpc_gateway_auth_generic:fetch_token(Conf),
    %% Token itself is just the access_token, not token_type
    ?assertEqual(<<"mock-oauth2-access-token">>, Token),
    %% Verify the mock response includes token_type
    Url = <<(proplists:get_value(base_url, Config))/binary,
            "/oauth2/token">>,
    Body = <<"grant_type=client_credentials">>,
    Headers = [{<<"Content-Type">>,
                <<"application/x-www-form-urlencoded">>}],
    {ok, 200, _RH, RespBody} =
        hackney:request(post, Url, Headers, Body, [with_body]),
    Decoded = json:decode(RespBody),
    ?assertEqual(<<"Bearer">>, maps:get(<<"token_type">>, Decoded)).


%% ===================================================================
%% GIS custom scheme tests
%% ===================================================================

gis_fetch_token(Config) ->
    %% POST generateToken with form body username/password/f/referer,
    %% extract token from response.
    Conf = gis_config(Config),
    {ok, Token} = bondy_rpc_gateway_auth_generic:fetch_token(Conf),
    ?assertEqual(<<"mock-gis-token-abc123">>, Token).

gis_apply_auth_query_param(_Config) ->
    %% GIS places the token as a ?token= query parameter
    Conf = gis_config_apply_only(),
    Url = <<"https://maps.example.com/rest/services/MyService">>,
    {ResultUrl, ResultHeaders} =
        bondy_rpc_gateway_auth_generic:apply_auth(
            <<"gis-tok-123">>, Url, [], Conf
        ),
    %% Headers should be unchanged
    ?assertEqual([], ResultHeaders),
    %% URL should have ?token=... appended
    ?assertNotEqual(nomatch,
        binary:match(ResultUrl, <<"token=gis-tok-123">>)).

gis_fetch_error_in_body(Config) ->
    %% Returns 200 with error in body (not an HTTP error code).
    %% auth_generic's error_path detects this.
    mock_auth_http_server:set_credentials(
        gis, <<"admin">>, <<"s3cret">>
    ),
    Conf = gis_config_with_creds(Config,
        <<"wrong-user">>, <<"wrong-pass">>
    ),
    Result = bondy_rpc_gateway_auth_generic:fetch_token(Conf),
    ?assertMatch({error, {upstream_error, _}}, Result).

gis_fetch_no_token_in_response(Config) ->
    %% If the token is empty/missing in the response
    mock_auth_http_server:set_token(gis, <<>>),
    Conf = gis_config(Config),
    Result = bondy_rpc_gateway_auth_generic:fetch_token(Conf),
    ?assertMatch({error, no_token_in_response}, Result).


%% ===================================================================
%% Config builders
%% ===================================================================

%% --- OAuth2 (client_credentials with Basic auth) ---

cc_config(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    #{
        fetch => #{
            method => post,
            url => <<BaseUrl/binary, "/oauth2/token">>,
            body_encoding => form,
            body => #{
                <<"grant_type">> => <<"client_credentials">>
            },
            token_path => [<<"access_token">>],
            expires_in_path => [<<"expires_in">>]
        },
        apply => #{
            placement => header,
            name => <<"Authorization">>,
            format => <<"Bearer {{token}}">>
        },
        vars => #{}
    }.

cc_config_with_creds(Config, ClientId, ClientSecret) ->
    Conf = cc_config(Config),
    Fetch = maps:get(fetch, Conf),
    Conf#{
        fetch => Fetch#{
            auth => #{
                type => basic,
                username => <<"{{client_id}}">>,
                password => <<"{{client_secret}}">>
            }
        },
        vars => #{
            client_id => ClientId,
            client_secret => ClientSecret
        }
    }.

cc_config_apply_only() ->
    #{
        apply => #{
            placement => header,
            name => <<"Authorization">>,
            format => <<"Bearer {{token}}">>
        }
    }.


%% --- GIS custom token scheme ---

gis_config(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    #{
        fetch => #{
            method => post,
            url => <<"{{base_url}}/portal/sharing/rest/generateToken">>,
            body_encoding => form,
            body => #{
                <<"username">> => <<"{{username}}">>,
                <<"password">> => <<"{{password}}">>,
                <<"f">> => <<"json">>,
                <<"referer">> => <<"https://www.example.com">>
            },
            token_path => [<<"token">>],
            error_path => [<<"error">>, <<"message">>]
        },
        apply => #{
            placement => query_param,
            name => <<"token">>
        },
        vars => #{
            base_url => BaseUrl,
            username => <<"testuser">>,
            password => <<"testpass">>
        }
    }.

gis_config_with_creds(Config, Username, Password) ->
    BaseUrl = proplists:get_value(base_url, Config),
    #{
        fetch => #{
            method => post,
            url => <<"{{base_url}}/portal/sharing/rest/generateToken">>,
            body_encoding => form,
            body => #{
                <<"username">> => <<"{{username}}">>,
                <<"password">> => <<"{{password}}">>,
                <<"f">> => <<"json">>,
                <<"referer">> => <<"https://www.example.com">>
            },
            token_path => [<<"token">>],
            error_path => [<<"error">>, <<"message">>]
        },
        apply => #{
            placement => query_param,
            name => <<"token">>
        },
        vars => #{
            base_url => BaseUrl,
            username => Username,
            password => Password
        }
    }.

gis_config_apply_only() ->
    #{
        apply => #{
            placement => query_param,
            name => <<"token">>
        }
    }.
