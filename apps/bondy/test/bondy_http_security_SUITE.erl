%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_security_SUITE).
-moduledoc """
Integration tests for CORS and security headers.

Starts a full Bondy node and sends real HTTP requests via hackney to verify
that CORS and security response headers are correctly set on all handler types.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).


-define(API_PORT, 18080).
-define(ADMIN_PORT, 18081).



all() ->
    [
        sse_options_cors,
        longpoll_options_cors,
        admin_ping_security_headers,
        admin_ping_server_header,
        admin_ready_security_headers
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.


end_per_suite(Config) ->
    {save_config, Config}.



%% =============================================================================
%% TEST CASES
%% =============================================================================



sse_options_cors(_Config) ->
    Url = api_url("/wamp/sse/open"),
    Headers = [{<<"origin">>, <<"https://test.example.com">>}],
    {ok, Status, RespHeaders, _Ref} = hackney:request(
        options, Url, Headers, <<>>, []
    ),
    ?assertEqual(200, Status),
    Origin = header_value(<<"access-control-allow-origin">>, RespHeaders),
    ?assertNotEqual(undefined, Origin),
    Credentials = header_value(
        <<"access-control-allow-credentials">>, RespHeaders
    ),
    %% With default wildcard config, credentials must be false
    ?assertEqual(<<"false">>, Credentials),
    Methods = header_value(
        <<"access-control-allow-methods">>, RespHeaders
    ),
    ?assertNotEqual(undefined, Methods),
    MaxAge = header_value(<<"access-control-max-age">>, RespHeaders),
    ?assertNotEqual(undefined, MaxAge).


longpoll_options_cors(_Config) ->
    Url = api_url("/wamp/longpoll/open"),
    Headers = [{<<"origin">>, <<"https://test.example.com">>}],
    {ok, Status, RespHeaders, _Ref} = hackney:request(
        options, Url, Headers, <<>>, []
    ),
    ?assertEqual(200, Status),
    Origin = header_value(<<"access-control-allow-origin">>, RespHeaders),
    ?assertNotEqual(undefined, Origin),
    Credentials = header_value(
        <<"access-control-allow-credentials">>, RespHeaders
    ),
    ?assertEqual(<<"false">>, Credentials).


admin_ping_security_headers(_Config) ->
    Url = admin_url("/ping"),
    {ok, Status, RespHeaders, _Ref} = hackney:request(
        get, Url, [], <<>>, []
    ),
    ?assertEqual(204, Status),
    %% X-Frame-Options should be set
    FrameOpts = header_value(<<"x-frame-options">>, RespHeaders),
    ?assertEqual(<<"SAMEORIGIN">>, FrameOpts),
    %% X-Content-Type-Options should be set
    ContentTypeOpts = header_value(
        <<"x-content-type-options">>, RespHeaders
    ),
    ?assertEqual(<<"nosniff">>, ContentTypeOpts),
    %% HSTS should NOT be set for HTTP listener
    Hsts = header_value(<<"strict-transport-security">>, RespHeaders),
    ?assertEqual(undefined, Hsts).


admin_ping_server_header(_Config) ->
    Url = admin_url("/ping"),
    {ok, _Status, RespHeaders, _Ref} = hackney:request(
        get, Url, [], <<>>, []
    ),
    Server = header_value(<<"server">>, RespHeaders),
    ?assertNotEqual(undefined, Server),
    ?assertMatch(<<"bondy/", _/binary>>, Server).


admin_ready_security_headers(_Config) ->
    Url = admin_url("/ready"),
    {ok, _Status, RespHeaders, _Ref} = hackney:request(
        get, Url, [], <<>>, []
    ),
    FrameOpts = header_value(<<"x-frame-options">>, RespHeaders),
    ?assertEqual(<<"SAMEORIGIN">>, FrameOpts),
    ContentTypeOpts = header_value(
        <<"x-content-type-options">>, RespHeaders
    ),
    ?assertEqual(<<"nosniff">>, ContentTypeOpts).



%% =============================================================================
%% HELPERS
%% =============================================================================



api_url(Path) ->
    iolist_to_binary([
        "http://localhost:", integer_to_list(?API_PORT), Path
    ]).


admin_url(Path) ->
    iolist_to_binary([
        "http://localhost:", integer_to_list(?ADMIN_PORT), Path
    ]).


header_value(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> Value;
        false -> undefined
    end.
