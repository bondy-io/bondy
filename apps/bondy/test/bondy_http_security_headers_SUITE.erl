%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_security_headers_SUITE).
-moduledoc """
Unit tests for bondy_http_security_headers.

Tests static security header generation and persistent_term caching.
Uses meck to mock bondy_config so that Bondy does not need to be running.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).


all() ->
    [
        all_headers_enabled,
        disabled_returns_empty_security,
        hsts_only,
        no_csp_when_undefined,
        custom_values,
        server_header_bondy,
        server_header_suppressed,
        server_header_custom,
        headers_from_req_extracts_ref,
        cleanup_removes_persistent_term
    ].


init_per_suite(Config) ->
    ok = meck:new(bondy_config, [passthrough, no_link]),
    Config.


end_per_suite(_Config) ->
    meck:unload(bondy_config),
    ok.


init_per_testcase(_TestCase, Config) ->
    meck:reset(bondy_config),
    Config.


end_per_testcase(TestCase, _Config) ->
    bondy_http_security_headers:cleanup(TestCase),
    ok.



%% =============================================================================
%% TEST CASES
%% =============================================================================



all_headers_enabled(_Config) ->
    Name = all_headers_enabled,
    mock_config(Name, #{
        enabled => true,
        hsts => <<"max-age=31536000">>,
        frame_options => <<"SAMEORIGIN">>,
        content_type_options => <<"nosniff">>,
        content_security_policy => <<"default-src 'self'">>
    }, <<"bondy">>),
    ok = bondy_http_security_headers:init(Name),
    Headers = bondy_http_security_headers:headers(Name),
    ?assertEqual(<<"max-age=31536000">>, maps:get(<<"strict-transport-security">>, Headers)),
    ?assertEqual(<<"SAMEORIGIN">>, maps:get(<<"x-frame-options">>, Headers)),
    ?assertEqual(<<"nosniff">>, maps:get(<<"x-content-type-options">>, Headers)),
    ?assertEqual(<<"default-src 'self'">>, maps:get(<<"content-security-policy">>, Headers)),
    ?assert(maps:is_key(<<"server">>, Headers)).


disabled_returns_empty_security(_Config) ->
    Name = disabled_returns_empty_security,
    mock_config(Name, #{enabled => false}, <<"bondy">>),
    ok = bondy_http_security_headers:init(Name),
    Headers = bondy_http_security_headers:headers(Name),
    %% When disabled, only server header should be present
    ?assertNot(maps:is_key(<<"strict-transport-security">>, Headers)),
    ?assertNot(maps:is_key(<<"x-frame-options">>, Headers)),
    ?assertNot(maps:is_key(<<"x-content-type-options">>, Headers)),
    ?assertNot(maps:is_key(<<"content-security-policy">>, Headers)).


hsts_only(_Config) ->
    Name = hsts_only,
    mock_config(Name, #{
        enabled => true,
        hsts => <<"max-age=31536000; includeSubDomains">>,
        frame_options => undefined,
        content_type_options => undefined,
        content_security_policy => undefined
    }, <<>>),
    ok = bondy_http_security_headers:init(Name),
    Headers = bondy_http_security_headers:headers(Name),
    ?assert(maps:is_key(<<"strict-transport-security">>, Headers)),
    ?assertNot(maps:is_key(<<"x-frame-options">>, Headers)),
    ?assertNot(maps:is_key(<<"x-content-type-options">>, Headers)),
    ?assertNot(maps:is_key(<<"content-security-policy">>, Headers)),
    ?assertNot(maps:is_key(<<"server">>, Headers)).


no_csp_when_undefined(_Config) ->
    Name = no_csp_when_undefined,
    mock_config(Name, #{
        enabled => true,
        hsts => undefined,
        frame_options => <<"DENY">>,
        content_type_options => <<"nosniff">>,
        content_security_policy => undefined
    }, <<"bondy">>),
    ok = bondy_http_security_headers:init(Name),
    Headers = bondy_http_security_headers:headers(Name),
    ?assertNot(maps:is_key(<<"content-security-policy">>, Headers)),
    ?assertNot(maps:is_key(<<"strict-transport-security">>, Headers)),
    ?assertEqual(<<"DENY">>, maps:get(<<"x-frame-options">>, Headers)),
    ?assertEqual(<<"nosniff">>, maps:get(<<"x-content-type-options">>, Headers)).


custom_values(_Config) ->
    Name = custom_values,
    mock_config(Name, #{
        enabled => true,
        hsts => <<"max-age=600">>,
        frame_options => <<"DENY">>,
        content_type_options => <<"nosniff">>,
        content_security_policy => <<"script-src 'none'">>
    }, <<"custom-server">>),
    ok = bondy_http_security_headers:init(Name),
    Headers = bondy_http_security_headers:headers(Name),
    ?assertEqual(<<"max-age=600">>, maps:get(<<"strict-transport-security">>, Headers)),
    ?assertEqual(<<"DENY">>, maps:get(<<"x-frame-options">>, Headers)),
    ?assertEqual(<<"script-src 'none'">>, maps:get(<<"content-security-policy">>, Headers)),
    ?assertEqual(<<"custom-server">>, maps:get(<<"server">>, Headers)).


server_header_bondy(_Config) ->
    Name = server_header_bondy,
    mock_config(Name, bondy_http_security_headers:default_config(), <<"bondy">>),
    ok = bondy_http_security_headers:init(Name),
    Headers = bondy_http_security_headers:headers(Name),
    Server = maps:get(<<"server">>, Headers),
    ?assertMatch(<<"bondy/", _/binary>>, Server).


server_header_suppressed(_Config) ->
    Name = server_header_suppressed,
    mock_config(Name, bondy_http_security_headers:default_config(), <<>>),
    ok = bondy_http_security_headers:init(Name),
    Headers = bondy_http_security_headers:headers(Name),
    ?assertNot(maps:is_key(<<"server">>, Headers)).


server_header_custom(_Config) ->
    Name = server_header_custom,
    mock_config(Name, bondy_http_security_headers:default_config(), <<"my-server/1.0">>),
    ok = bondy_http_security_headers:init(Name),
    Headers = bondy_http_security_headers:headers(Name),
    ?assertEqual(<<"my-server/1.0">>, maps:get(<<"server">>, Headers)).


headers_from_req_extracts_ref(_Config) ->
    Name = headers_from_req_extracts_ref,
    mock_config(Name, bondy_http_security_headers:default_config(), <<"bondy">>),
    ok = bondy_http_security_headers:init(Name),
    Req = #{ref => Name},
    Headers = bondy_http_security_headers:headers_from_req(Req),
    ?assert(maps:is_key(<<"x-frame-options">>, Headers)).


cleanup_removes_persistent_term(_Config) ->
    Name = cleanup_removes_persistent_term,
    mock_config(Name, bondy_http_security_headers:default_config(), <<"bondy">>),
    ok = bondy_http_security_headers:init(Name),
    ?assertNotEqual(#{}, bondy_http_security_headers:headers(Name)),
    ok = bondy_http_security_headers:cleanup(Name),
    ?assertEqual(#{}, bondy_http_security_headers:headers(Name)).



%% =============================================================================
%% HELPERS
%% =============================================================================



mock_config(ListenerName, SecurityConfig, ServerHeader) ->
    meck:expect(bondy_config, get,
        fun([N, security_headers], _Default) when N =:= ListenerName ->
                SecurityConfig;
           ([N, server_header], _Default) when N =:= ListenerName ->
                ServerHeader;
           (Key, Default) ->
                meck:passthrough([Key, Default])
        end).
