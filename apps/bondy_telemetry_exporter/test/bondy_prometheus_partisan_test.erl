%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Unit tests for the Partisan inter-node telemetry sink in `bondy_prometheus`
%% (`handle_partisan_event/4`). Each test drives one Partisan event through the
%% handler with a synthetic measurements/metadata pair — exactly the shapes in
%% Partisan's `doc_extras/telemetry.md` — and asserts the corresponding
%% `bondy_metrics` family moved, without needing a live Partisan cluster.
-module(bondy_prometheus_partisan_test).

-include_lib("eunit/include/eunit.hrl").

partisan_metrics_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"heartbeat records RTT + send-pending", fun heartbeat/0},
        {"connection up/down counters, with reason", fun conn_churn/0},
        {"membership change deltas + size gauge", fun membership/0},
        {"channel connection size + target gauges", fun channel_conns/0},
        {"connect + TLS handshake latency, by result", fun connect_handshake/0}
    ]}.

heartbeat() ->
    Meta = #{peer_node => 'p2@h', channel => data, socket => sock},
    ok = bondy_prometheus:handle_partisan_event(
        [partisan, connection, client, heartbeat],
        #{latency => 7, send_pend => 42, recv_oct => 100, send_oct => 90},
        Meta,
        undefined
    ),
    L = #{peer => 'p2@h', channel => data, side => client},
    ?assert(hist_count(bondy_cluster_peer_rtt_milliseconds, L) >= 1),
    ?assertEqual(42, gauge(bondy_cluster_peer_send_pending_bytes, L)).

conn_churn() ->
    Up = #{peer => 'p3@h', channel => default},
    Before = counter(bondy_cluster_connection_up_total, Up),
    ok = bondy_prometheus:handle_partisan_event(
        [partisan, connection, up],
        #{count => 1},
        #{peer_node => 'p3@h', channel => default},
        undefined
    ),
    ?assertEqual(Before + 1, counter(bondy_cluster_connection_up_total, Up)),
    ok = bondy_prometheus:handle_partisan_event(
        [partisan, connection, down],
        #{count => 1},
        #{peer_node => 'p3@h', channel => default, reason => noconnection},
        undefined
    ),
    Down = #{peer => 'p3@h', channel => default, reason => noconnection},
    ?assert(counter(bondy_cluster_connection_down_total, Down) >= 1).

membership() ->
    ok = bondy_prometheus:handle_partisan_event(
        [partisan, membership, changed],
        #{added => 2, removed => 1, total => 5},
        #{version => 9},
        undefined
    ),
    ?assert(
        counter(bondy_cluster_membership_changes_total, #{direction => added}) >=
            2
    ),
    ?assert(
        counter(bondy_cluster_membership_changes_total, #{
            direction => removed
        }) >= 1
    ),
    ?assertEqual(5, gauge(bondy_cluster_membership_size, #{})).

channel_conns() ->
    L = #{peer => 'p4@h', channel => wamp_relay},
    ok = bondy_prometheus:handle_partisan_event(
        [partisan, channel, connections],
        #{size => 1, target => 2},
        #{peer_node => 'p4@h', channel => wamp_relay},
        undefined
    ),
    ?assertEqual(1, gauge(bondy_cluster_channel_connections, L)),
    ?assertEqual(2, gauge(bondy_cluster_channel_connections_target, L)).

connect_handshake() ->
    ok = bondy_prometheus:handle_partisan_event(
        [partisan, connection, client, connect],
        #{latency => 3},
        #{result => ok},
        undefined
    ),
    ?assert(
        hist_count(bondy_cluster_connect_latency_milliseconds, #{result => ok}) >=
            1
    ),
    ok = bondy_prometheus:handle_partisan_event(
        [partisan, socket, server, handshake],
        #{latency => 12},
        #{result => error, reason => timeout},
        undefined
    ),
    ?assert(
        hist_count(bondy_cluster_tls_handshake_milliseconds, #{
            result => error
        }) >= 1
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

counter(Name, Label) -> value(Name, Label).
gauge(Name, Label) -> value(Name, Label).

value(Name, Label) ->
    case bondy_metrics:value(#{name => Name, label => Label}) of
        N when is_integer(N) -> N;
        _ -> 0
    end.

hist_count(Name, Label) ->
    case bondy_metrics:histogram_snapshot(#{name => Name, label => Label}) of
        {ok, #{count := C}} -> C;
        _ -> 0
    end.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_metrics),
    _ =
        case bondy_metrics:start_link() of
            {ok, _} -> ok;
            {error, {already_started, _}} -> ok
        end,
    ok.

cleanup(_) ->
    ok.
