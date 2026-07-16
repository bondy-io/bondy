%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_app_peer_plane_test).
-moduledoc """
WP-G / C-1 — the pure peer-plane safety-gate decision
(`bondy_app:peer_plane_gate/1`).
""".

-include_lib("eunit/include/eunit.hrl").

gate(Clustering, Tls, SV, CV, Allow) ->
    bondy_app:peer_plane_gate(#{
        clustering => Clustering,
        tls => Tls,
        server_verify => SV,
        client_verify => CV,
        allow_insecure => Allow
    }).

%% A non-clustering node is never gated, whatever the TLS posture.
non_clustering_never_gated_test() ->
    ?assertEqual(ok, gate(false, false, verify_none, verify_none, false)),
    ?assertEqual(ok, gate(false, true, verify_none, verify_none, false)),
    ?assertEqual(ok, gate(false, false, verify_none, verify_none, true)).

%% Clustering + secure (TLS on, verify_peer both sides) → ok.
clustering_secure_ok_test() ->
    ?assertEqual(ok, gate(true, true, verify_peer, verify_peer, false)).

%% Clustering + TLS off → refuse (unless acknowledged).
clustering_tls_off_refuses_test() ->
    ?assertEqual(
        {refuse, tls_disabled},
        gate(true, false, verify_none, verify_none, false)
    ).

%% Clustering + TLS on but verify_none (either side) → refuse.
clustering_verify_none_refuses_test() ->
    ?assertEqual(
        {refuse, verify_none},
        gate(true, true, verify_none, verify_none, false)
    ),
    %% One side verify_peer, the other verify_none is still insufficient.
    ?assertEqual(
        {refuse, verify_none},
        gate(true, true, verify_peer, verify_none, false)
    ),
    ?assertEqual(
        {refuse, verify_none},
        gate(true, true, verify_none, verify_peer, false)
    ).

%% allow_insecure downgrades the refusal to a warning.
allow_insecure_downgrades_to_warn_test() ->
    ?assertEqual(
        {warn, tls_disabled},
        gate(true, false, verify_none, verify_none, true)
    ),
    ?assertEqual(
        {warn, verify_none},
        gate(true, true, verify_none, verify_none, true)
    ).

%% allow_insecure does NOT weaken an already-secure cluster (stays ok).
allow_insecure_noop_when_secure_test() ->
    ?assertEqual(ok, gate(true, true, verify_peer, verify_peer, true)).
