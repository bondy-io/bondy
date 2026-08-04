%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_prometheus_db_test).
-moduledoc """
EUnit coverage for the `bondy_prometheus_db` telemetry→Prometheus bridge:
declaration idempotence, event-to-metric mapping, handler crash-immunity
(telemetry silently detaches raising handlers) and text exposition.
""".

-include_lib("eunit/include/eunit.hrl").

-define(ID, <<"test_instance">>).

%% =============================================================================
%% FIXTURE
%% =============================================================================

bridge_test_() ->
    {setup, fun test_setup/0, fun test_cleanup/1, [
        fun setup_is_idempotent/0,
        fun wal_events_are_counted/0,
        fun applier_stage_events_are_counted/0,
        fun sync_events_are_counted/0,
        fun ae_health_events_are_counted/0,
        fun scheduler_events_are_counted/0,
        fun mst_events_are_counted/0,
        fun core_refresh_sets_gauges/0,
        fun write_latency_sets_quantile_gauges/0,
        fun aae_conflict_is_counted/0,
        fun malformed_event_does_not_detach_handler/0,
        fun exposition_formats/0
    ]}.

test_setup() ->
    {ok, Started1} = application:ensure_all_started(telemetry),
    {ok, Started2} = application:ensure_all_started(prometheus),
    %% A sync scheduler left running by an earlier eunit module in the same
    %% VM emits the same global scheduler telemetry these tests assert EXACT
    %% counter values on; suspend its periodic tick for the duration.
    Interval =
        case erlang:whereis(bondy_oplog_sync_scheduler) of
            undefined ->
                undefined;
            _Pid ->
                #{interval_ms := I} = bondy_oplog_sync_scheduler:info(),
                ok = bondy_oplog_sync_scheduler:set_interval_ms(0),
                I
        end,
    ok = bondy_prometheus_db:setup(),
    {Started1 ++ Started2, Interval}.

test_cleanup({Started, Interval}) ->
    ok = bondy_prometheus_db:teardown(),
    is_integer(Interval) andalso
        (ok = bondy_oplog_sync_scheduler:set_interval_ms(Interval)),
    _ = [application:stop(App) || App <- lists:reverse(Started)],
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

setup_is_idempotent() ->
    ?assertEqual(ok, bondy_prometheus_db:setup()),
    ?assertEqual(ok, bondy_prometheus_db:setup()).

wal_events_are_counted() ->
    Meta = #{instance_id => ?ID, segment => 1, offset => 0},
    ok = telemetry:execute(
        [bondy_oplog, wal, append],
        #{frame_len => 512, body_len => 480, batch_size => 4, hlc => 1},
        Meta
    ),
    ok = telemetry:execute(
        [bondy_oplog, wal, append],
        #{frame_len => 256, body_len => 240, batch_size => 2, hlc => 2},
        Meta
    ),
    ?assertEqual(
        2, prometheus_counter:value(bondy_oplog_wal_appends_total, [?ID])
    ),
    ?assertEqual(
        6, prometheus_counter:value(bondy_oplog_wal_appended_ops_total, [?ID])
    ),
    ?assertEqual(
        768,
        prometheus_counter:value(bondy_oplog_wal_appended_bytes_total, [?ID])
    ),
    ok = telemetry:execute(
        [bondy_oplog, wal, fsync],
        #{bytes_synced => 1024, duration_us => 250},
        Meta#{mode => batched}
    ),
    ?assertEqual(
        1,
        prometheus_counter:value(
            bondy_oplog_wal_fsyncs_total, [?ID, batched]
        )
    ),
    {BucketCounts, Sum} = prometheus_histogram:value(
        bondy_oplog_wal_fsync_duration_microseconds, [batched]
    ),
    ?assertEqual(1, lists:sum(BucketCounts)),
    ?assertEqual(250, round(Sum)).

applier_stage_events_are_counted() ->
    Meta = #{instance_id => ?ID},
    ok = telemetry:execute(
        [bondy_oplog, applier, batch_verify],
        #{duration_us => 100, count => 10},
        Meta
    ),
    ok = telemetry:execute(
        [bondy_oplog, applier, batch_cell_apply],
        #{duration_us => 300, count => 10},
        Meta
    ),
    ?assertEqual(
        10,
        prometheus_counter:value(
            bondy_oplog_applier_batch_items_total, [?ID, <<"verify">>]
        )
    ),
    ?assertEqual(
        10,
        prometheus_counter:value(
            bondy_oplog_applier_batch_items_total, [?ID, <<"cell_apply">>]
        )
    ),
    ok = telemetry:execute(
        [bondy_oplog, applier, applied], #{count => 9, rejected => 1}, Meta
    ),
    ?assertEqual(
        9, prometheus_counter:value(bondy_oplog_applier_applied_total, [?ID])
    ),
    ?assertEqual(
        1, prometheus_counter:value(bondy_oplog_applier_rejected_total, [?ID])
    ).

sync_events_are_counted() ->
    Meta = #{instance_id => ?ID, peer => 'peer@127.0.0.1'},
    Duration = erlang:convert_time_unit(1500, microsecond, native),
    ok = telemetry:execute(
        [bondy_oplog, sync, ok], #{duration => Duration}, Meta
    ),
    ?assertEqual(
        1,
        prometheus_counter:value(
            bondy_oplog_sync_sessions_total, [?ID, 'peer@127.0.0.1', ok]
        )
    ),
    {BucketCounts, _} = prometheus_histogram:value(
        bondy_oplog_sync_duration_microseconds, [ok]
    ),
    ?assertEqual(1, lists:sum(BucketCounts)).

ae_health_events_are_counted() ->
    Peer = 'peer@127.0.0.1',
    ok = telemetry:execute(
        [bondy_oplog, sync_session, frontier_gap],
        #{count => 1, origins => 1},
        #{instance_id => ?ID, peer => Peer, deficit => #{}}
    ),
    ?assertEqual(
        1,
        prometheus_counter:value(
            bondy_oplog_frontier_gap_verdicts_total, [?ID, Peer]
        )
    ),
    ok = telemetry:execute(
        [bondy_oplog, sync_scheduler, rebootstrap_scheduled],
        #{count => 1},
        #{instance_id => ?ID, peer => Peer, reason => frontier_gap}
    ),
    ?assertEqual(
        1,
        prometheus_counter:value(
            bondy_oplog_rebootstraps_scheduled_total, [?ID, Peer]
        )
    ),
    ok = telemetry:execute(
        [bondy_oplog, instance, integrate_doored],
        #{count => 3},
        #{instance_id => ?ID, action => folded, doored => []}
    ),
    ok = telemetry:execute(
        [bondy_oplog, instance, integrate_doored],
        #{count => 1},
        #{instance_id => ?ID, action => held, doored => []}
    ),
    ?assertEqual(
        3,
        prometheus_counter:value(
            bondy_oplog_doored_events_total, [?ID, folded]
        )
    ),
    ?assertEqual(
        1,
        prometheus_counter:value(
            bondy_oplog_doored_events_total, [?ID, held]
        )
    ).

scheduler_events_are_counted() ->
    ok = telemetry:execute(
        [bondy_oplog, scheduler, sync, tick], #{instances => 3}, #{}
    ),
    ok = telemetry:execute(
        [bondy_oplog, sync_scheduler, bootstrap, started],
        #{current => 1},
        #{instance_id => ?ID, pid => self()}
    ),
    ?assertEqual(
        1,
        prometheus_counter:value(
            bondy_oplog_sync_scheduler_events_total, [tick]
        )
    ),
    ?assertEqual(
        1,
        prometheus_counter:value(
            bondy_oplog_sync_scheduler_events_total, [<<"bootstrap_started">>]
        )
    ).

mst_events_are_counted() ->
    Meta = #{instance_id => ?ID},
    ok = telemetry:execute(
        [bondy_mst, page_store, put],
        #{page_bytes => 4096, duration_us => 30, content_hit => 0},
        Meta
    ),
    ?assertEqual(
        1,
        prometheus_counter:value(bondy_mst_page_store_ops_total, [?ID, put])
    ),
    ?assertEqual(
        4096,
        prometheus_counter:value(bondy_mst_page_store_bytes_total, [?ID, put])
    ),
    ok = telemetry:execute(
        [bondy_mst, page_store, seal_incoming],
        #{record_count => 100, pack_bytes => 65536, duration_us => 900},
        Meta#{new_pack_id => 7}
    ),
    ?assertEqual(
        1,
        prometheus_counter:value(bondy_mst_seals_total, [?ID, <<"incoming">>])
    ),
    ?assertEqual(
        65536,
        prometheus_counter:value(
            bondy_mst_seal_bytes_total, [?ID, <<"incoming">>]
        )
    ).

core_refresh_sets_gauges() ->
    ok = telemetry:execute(
        [bondy_oplog_core, metrics, refresh],
        #{
            cache_hit_rate => 0.85,
            read_rps => 120,
            range_rps => 4,
            subscriber_count => 2,
            current_freshness_lag_max_ms => 40
        },
        #{namespace => test_ns, interval_ms => 5000}
    ),
    ?assertEqual(
        0.85,
        prometheus_gauge:value(bondy_oplog_core_cache_hit_ratio, [test_ns])
    ),
    ?assertEqual(
        120, prometheus_gauge:value(bondy_oplog_core_read_rps, [test_ns])
    ),
    ?assertEqual(
        40,
        prometheus_gauge:value(
            bondy_oplog_core_freshness_lag_max_milliseconds, [test_ns]
        )
    ).

write_latency_sets_quantile_gauges() ->
    ok = telemetry:execute(
        [bondy_oplog, instance, write_latency],
        #{
            count => 100,
            mean_us => 500,
            p50_us => 400,
            p95_us => 900,
            p99_us => 1200,
            max_us => 3000
        },
        #{instance_id => ?ID, interval_ms => 1000}
    ),
    ?assertEqual(
        400,
        prometheus_gauge:value(
            bondy_oplog_write_readable_latency_microseconds, [?ID, p50]
        )
    ),
    ?assertEqual(
        1200,
        prometheus_gauge:value(
            bondy_oplog_write_readable_latency_microseconds, [?ID, p99]
        )
    ).

aae_conflict_is_counted() ->
    ok = telemetry:execute(
        [bondy, aae, merge_conflict],
        #{count => 1},
        #{table => security_grants, realm_uri => <<"com.example.realm">>}
    ),
    ?assertEqual(
        1,
        prometheus_counter:value(
            bondy_aae_merge_conflicts_total, [<<"security_grants">>]
        )
    ).

malformed_event_does_not_detach_handler() ->
    %% Measurements/metadata with unexpected shapes must be swallowed:
    %% telemetry silently detaches a handler whose callback raises.
    ok = telemetry:execute(
        [bondy_oplog, wal, append], #{frame_len => not_a_number}, #{}
    ),
    ok = telemetry:execute([bondy_oplog, sync, ok], #{}, #{}),
    Ids = [
        maps:get(id, H)
     || H <- telemetry:list_handlers([bondy_oplog, wal, append])
    ],
    ?assert(lists:member(bondy_prometheus_db, Ids)).

exposition_formats() ->
    Output = prometheus_text_format:format(),
    ?assert(is_binary(Output)),
    ?assertNotEqual(
        nomatch, binary:match(Output, <<"bondy_oplog_wal_appends_total">>)
    ),
    ?assertNotEqual(
        nomatch, binary:match(Output, <<"bondy_oplog_sync_sessions_total">>)
    ).
