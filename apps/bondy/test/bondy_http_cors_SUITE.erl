%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_cors_SUITE).
-moduledoc """
Unit tests for bondy_http_cors.

Tests CORS header generation logic with various configurations and request
scenarios. Uses meck to mock cowboy_req functions so that Bondy does not
need to be running.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).



all() ->
    [
        disabled_returns_empty,
        wildcard_origin,
        wildcard_credentials_false,
        wildcard_no_vary,
        list_match,
        list_match_credentials_true,
        list_match_vary_origin,
        list_no_match,
        list_no_origin_header,
        auto_with_port,
        auto_default_http_port,
        auto_default_https_port,
        custom_methods_and_headers,
        custom_max_age
    ].


init_per_suite(Config) ->
    ok = meck:new(cowboy_req, [passthrough, no_link]),
    Config.


end_per_suite(_Config) ->
    meck:unload(cowboy_req),
    ok.


init_per_testcase(_TestCase, Config) ->
    meck:reset(cowboy_req),
    Config.


end_per_testcase(_TestCase, _Config) ->
    ok.



%% =============================================================================
%% TEST CASES
%% =============================================================================



disabled_returns_empty(_Config) ->
    Config = config(#{enabled => false}),
    Req = fake_req(<<"https://evil.com">>),
    ?assertEqual(#{}, bondy_http_cors:headers(Req, Config)).


wildcard_origin(_Config) ->
    Config = config(#{allowed_origins => '*'}),
    Req = fake_req(<<"https://any.example.com">>),
    Headers = bondy_http_cors:headers(Req, Config),
    ?assertEqual(<<"*">>, maps:get(<<"access-control-allow-origin">>, Headers)).


wildcard_credentials_false(_Config) ->
    Config = config(#{allowed_origins => '*'}),
    Req = fake_req(<<"https://any.example.com">>),
    Headers = bondy_http_cors:headers(Req, Config),
    ?assertEqual(
        <<"false">>,
        maps:get(<<"access-control-allow-credentials">>, Headers)
    ).


wildcard_no_vary(_Config) ->
    Config = config(#{allowed_origins => '*'}),
    Req = fake_req(<<"https://any.example.com">>),
    Headers = bondy_http_cors:headers(Req, Config),
    ?assertNot(maps:is_key(<<"vary">>, Headers)).


list_match(_Config) ->
    Allowed = [<<"https://app.example.com">>, <<"https://admin.example.com">>],
    Config = config(#{allowed_origins => Allowed}),
    Req = fake_req(<<"https://app.example.com">>),
    Headers = bondy_http_cors:headers(Req, Config),
    ?assertEqual(
        <<"https://app.example.com">>,
        maps:get(<<"access-control-allow-origin">>, Headers)
    ).


list_match_credentials_true(_Config) ->
    Allowed = [<<"https://app.example.com">>],
    Config = config(#{allowed_origins => Allowed}),
    Req = fake_req(<<"https://app.example.com">>),
    Headers = bondy_http_cors:headers(Req, Config),
    ?assertEqual(
        <<"true">>,
        maps:get(<<"access-control-allow-credentials">>, Headers)
    ).


list_match_vary_origin(_Config) ->
    Allowed = [<<"https://app.example.com">>],
    Config = config(#{allowed_origins => Allowed}),
    Req = fake_req(<<"https://app.example.com">>),
    Headers = bondy_http_cors:headers(Req, Config),
    ?assertEqual(<<"Origin">>, maps:get(<<"vary">>, Headers)).


list_no_match(_Config) ->
    Allowed = [<<"https://app.example.com">>],
    Config = config(#{allowed_origins => Allowed}),
    Req = fake_req(<<"https://evil.com">>),
    ?assertEqual(#{}, bondy_http_cors:headers(Req, Config)).


list_no_origin_header(_Config) ->
    Allowed = [<<"https://app.example.com">>],
    Config = config(#{allowed_origins => Allowed}),
    Req = fake_req(undefined),
    ?assertEqual(#{}, bondy_http_cors:headers(Req, Config)).


auto_with_port(_Config) ->
    Config = config(#{allowed_origins => auto}),
    Req = fake_req_auto(<<"http">>, <<"localhost">>, 18080),
    Headers = bondy_http_cors:headers(Req, Config),
    ?assertEqual(
        <<"http://localhost:18080">>,
        maps:get(<<"access-control-allow-origin">>, Headers)
    ).


auto_default_http_port(_Config) ->
    Config = config(#{allowed_origins => auto}),
    Req = fake_req_auto(<<"http">>, <<"example.com">>, 80),
    Headers = bondy_http_cors:headers(Req, Config),
    ?assertEqual(
        <<"http://example.com">>,
        maps:get(<<"access-control-allow-origin">>, Headers)
    ).


auto_default_https_port(_Config) ->
    Config = config(#{allowed_origins => auto}),
    Req = fake_req_auto(<<"https">>, <<"example.com">>, 443),
    Headers = bondy_http_cors:headers(Req, Config),
    ?assertEqual(
        <<"https://example.com">>,
        maps:get(<<"access-control-allow-origin">>, Headers)
    ).


custom_methods_and_headers(_Config) ->
    Config = config(#{
        allowed_origins => '*',
        allowed_methods => <<"GET,POST">>,
        allowed_headers => <<"content-type">>
    }),
    Req = fake_req(<<"https://any.com">>),
    Headers = bondy_http_cors:headers(Req, Config),
    ?assertEqual(<<"GET,POST">>, maps:get(<<"access-control-allow-methods">>, Headers)),
    ?assertEqual(<<"content-type">>, maps:get(<<"access-control-allow-headers">>, Headers)).


custom_max_age(_Config) ->
    Config = config(#{allowed_origins => '*', max_age => <<"3600">>}),
    Req = fake_req(<<"https://any.com">>),
    Headers = bondy_http_cors:headers(Req, Config),
    ?assertEqual(<<"3600">>, maps:get(<<"access-control-max-age">>, Headers)).



%% =============================================================================
%% HELPERS
%% =============================================================================



config(Overrides) ->
    maps:merge(bondy_http_cors:default_config(), Overrides).


fake_req(Origin) ->
    meck:expect(cowboy_req, header,
        fun(<<"origin">>, _Req) -> Origin end),
    #{ref => test_listener}.


fake_req_auto(Scheme, Host, Port) ->
    meck:expect(cowboy_req, scheme, fun(_) -> Scheme end),
    meck:expect(cowboy_req, host, fun(_) -> Host end),
    meck:expect(cowboy_req, port, fun(_) -> Port end),
    #{ref => test_listener}.
