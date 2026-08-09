%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_proxy_protocol_test).
-moduledoc """
the trusted-proxy gate `bondy_http_proxy_protocol:is_trusted_peer/2`
that decides whether client-supplied forwarding headers may be believed.
""".

-include_lib("eunit/include/eunit.hrl").

-define(M, bondy_http_proxy_protocol).

%% Secure default: with no (or empty) trusted_proxies, NO peer is trusted, so
%% spoofed forwarding headers can never move the source IP.
untrusted_by_default_test() ->
    ?assertNot(?M:is_trusted_peer({10, 0, 0, 5}, #{})),
    ?assertNot(?M:is_trusted_peer({10, 0, 0, 5}, #{trusted_proxies => []})),
    ?assertNot(?M:is_trusted_peer({10, 0, 0, 5}, #{trusted_proxies => ""})).

trusted_in_cidr_test() ->
    Opts = #{trusted_proxies => "10.0.0.0/8"},
    ?assert(?M:is_trusted_peer({10, 1, 2, 3}, Opts)),
    ?assertNot(?M:is_trusted_peer({8, 8, 8, 8}, Opts)).

multiple_cidrs_test() ->
    Opts = #{trusted_proxies => "10.0.0.0/8, 172.16.0.0/12"},
    ?assert(?M:is_trusted_peer({172, 16, 5, 5}, Opts)),
    ?assert(?M:is_trusted_peer({10, 9, 9, 9}, Opts)),
    ?assertNot(?M:is_trusted_peer({192, 168, 1, 1}, Opts)).

preparsed_cidr_tuples_test() ->
    Opts = #{trusted_proxies => [{{10, 0, 0, 0}, 8}]},
    ?assert(?M:is_trusted_peer({10, 0, 0, 1}, Opts)),
    ?assertNot(?M:is_trusted_peer({11, 0, 0, 1}, Opts)).

%% An IPv4 CIDR must never trust an IPv6 peer (address-family mismatch).
family_mismatch_test() ->
    Opts = #{trusted_proxies => "10.0.0.0/8"},
    ?assertNot(?M:is_trusted_peer({0, 0, 0, 0, 0, 0, 0, 1}, Opts)).

%% Malformed CIDR entries are skipped, not fatal.
invalid_entries_skipped_test() ->
    Opts = #{trusted_proxies => "not-a-cidr, 10.0.0.0/8, "},
    ?assert(?M:is_trusted_peer({10, 0, 0, 1}, Opts)),
    ?assertNot(?M:is_trusted_peer({8, 8, 8, 8}, Opts)).

%% =============================================================================
%% G-2 refinement: rightmost-untrusted chain selection
%% =============================================================================

%% Helper: the trusted-proxy CIDR list used by the chain tests.
proxies() ->
    ?M:trusted_proxies(#{trusted_proxies => "10.0.0.0/8"}).

%% Standard forward: `X-Forwarded-For: client, proxy1` where proxy1 is trusted.
%% The real client is the leftmost, reached by skipping the trusted rightmost.
rightmost_skips_trusted_tail_test() ->
    Chain = [<<"203.0.113.7">>, <<"10.0.0.1">>],
    ?assertEqual(
        {ok, {203, 0, 113, 7}}, ?M:rightmost_untrusted(Chain, proxies())
    ).

%% ATTACK: a client BEHIND the trusted proxy prepends a spoofed hop. The proxy
%% appends the real client IP, so the spoofed value sits to the LEFT and must be
%% ignored — we return the rightmost UNTRUSTED entry (the real client).
rightmost_ignores_prepended_spoof_test() ->
    Chain = [<<"1.2.3.4">>, <<"198.51.100.9">>, <<"10.0.0.1">>],
    ?assertEqual(
        {ok, {198, 51, 100, 9}}, ?M:rightmost_untrusted(Chain, proxies())
    ).

%% Multiple trusted hops at the tail are all skipped.
rightmost_skips_multiple_trusted_hops_test() ->
    Chain = [<<"198.51.100.9">>, <<"10.0.0.1">>, <<"10.0.0.2">>],
    ?assertEqual(
        {ok, {198, 51, 100, 9}}, ?M:rightmost_untrusted(Chain, proxies())
    ).

%% A single untrusted client with no trusted hop in the chain.
rightmost_single_untrusted_test() ->
    ?assertEqual(
        {ok, {203, 0, 113, 7}},
        ?M:rightmost_untrusted([<<"203.0.113.7">>], proxies())
    ).

%% A chain of ONLY trusted proxies yields no client → not_found (caller falls
%% back to the socket peer).
rightmost_all_trusted_test() ->
    Chain = [<<"10.0.0.1">>, <<"10.0.0.2">>],
    ?assertEqual({error, not_found}, ?M:rightmost_untrusted(Chain, proxies())).

%% Unparseable entries are skipped while scanning inward.
rightmost_skips_garbage_test() ->
    Chain = [<<"198.51.100.9">>, <<"garbage">>, <<"10.0.0.1">>],
    ?assertEqual(
        {ok, {198, 51, 100, 9}}, ?M:rightmost_untrusted(Chain, proxies())
    ).

%% An empty chain is not_found.
rightmost_empty_test() ->
    ?assertEqual({error, not_found}, ?M:rightmost_untrusted([], proxies())).
