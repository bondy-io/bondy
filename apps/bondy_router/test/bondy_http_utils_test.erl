%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_utils_test).
-moduledoc """
`bondy_http_utils:peer/1`, the single source of truth for a request's peer
address, and the header parsers that must not raise on malformed input.
""".

-include_lib("eunit/include/eunit.hrl").

%% A connection over a Unix domain socket has no network peer, so
%% `cowboy_req:peer/1` answers `{local, <<>>}` for it. `peer/1` maps that to
%% loopback with port 0, and port 0 is what tells it apart from a real
%% loopback client: an accepted TCP connection always carries a bound,
%% non-zero source port.
uds_peer_is_loopback_on_port_zero_test() ->
    ?assertEqual(
        {{127, 0, 0, 1}, 0}, bondy_http_utils:peer(#{peer => {local, <<>>}})
    ),
    ?assertEqual(
        {{127, 0, 0, 1}, 54321},
        bondy_http_utils:peer(#{peer => {{127, 0, 0, 1}, 54321}})
    ).

%% `cowboy_req` raises `{request_error, {header, <<"cookie">>}, _}` for this
%% header. `safe_parse_cookies/1` reads it as no cookies.
malformed_cookie_header_reads_as_no_cookies_test() ->
    ?assertEqual(
        [], bondy_http_utils:safe_parse_cookies(req(#{~"cookie" => ~"=x"}))
    ),
    ?assertEqual(
        [{~"a", ~"b"}],
        bondy_http_utils:safe_parse_cookies(req(#{~"cookie" => ~"a=b"}))
    ).

%% A bare `Bearer`, with or without the space, makes `cowboy_req` raise
%% `{request_error, {header, <<"authorization">>}, _}`.
malformed_authorization_header_reads_as_no_token_test() ->
    Token = fun(V) ->
        bondy_http_utils:safe_bearer_token(req(#{~"authorization" => V}))
    end,
    ?assertEqual(undefined, Token(~"Bearer")),
    ?assertEqual(undefined, Token(~"Bearer ")),
    ?assertEqual(undefined, Token(~"Basic dXNlcjpwYXNz")),
    ?assertEqual(undefined, Token(~"Digest a=b")),
    ?assertEqual(~"abc", Token(~"Bearer abc")),
    ?assertEqual(undefined, bondy_http_utils:safe_bearer_token(req(#{}))).

req(Headers) ->
    #{ref => ?MODULE, headers => Headers}.
