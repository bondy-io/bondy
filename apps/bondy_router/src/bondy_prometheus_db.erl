%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_prometheus_db).
-moduledoc """
Bridges the `bondy_db` / `bondy_oplog` / `bondy_mst` storage stack onto the
Prometheus `/metrics` endpoint served by the Admin API listener.

Two mechanisms are combined:

- **Telemetry handler** — `setup/0` attaches `handle_event/4` (via
  `telemetry:attach_many/4`) to the storage stack's `telemetry:execute/3`
  events (WAL, applier, sync/AAE, schedulers, MST page store, secondary
  indexes) and folds them into pre-declared Prometheus counters and
  histograms. Per-cell and per-read hot-path events
  (`[bondy_oplog_core, read]`, `[bondy_oplog, applier, cell_read]`, …) are
  deliberately NOT attached: their totals are already accumulated wait-free
  by `bondy_oplog_core_metrics` / `bondy_metrics`, and attaching a second
  handler would tax the hot path (observer effect). Histogram families keep
  low-cardinality labels only (stage/kind/outcome, never `instance_id`);
  counters may carry `instance_id` (one series per instance).

- **Collector** — this module is also a `prometheus_collector` producing
  scrape-time gauges from runtime state, mirroring what the
  `bondy_observer_cli` Cluster and Sync panes show: Partisan
  membership/connectivity, per-instance lifecycle and applied-frontier
  signature, WAL writer state, per-(instance, peer) sync recency, substrate
  AE freshness lag, scheduler state, plus a passthrough of every
  counter/gauge registered in `bondy_metrics` (e.g.
  `bondy_oplog_core_reads_total`).

Cross-node convergence is derivable in PromQL without any scrape-time
network traffic: `bondy_oplog_instance_frontier_hash` is a stable hash of
the applied-frontier version vector, so an instance is converged
cluster-wide when every node reports the same hash
(`count(count_values(...)) == 1`).

All runtime reads are defensive: a failing source degrades to an absent
metric family, never a scrape error.
""".

-behaviour(prometheus_collector).

-include_lib("kernel/include/logger.hrl").

-define(HANDLER_ID, ?MODULE).

%% Log-spaced microsecond buckets covering 50us .. 5s.
-define(DURATION_BUCKETS_US, [
    50,
    100,
    250,
    500,
    1000,
    2500,
    5000,
    10000,
    25000,
    50000,
    100000,
    250000,
    500000,
    1000000,
    2500000,
    5000000
]).

%% Overall deadline for gathering per-instance WAL writer snapshots on
%% scrape. A slow or wedged writer must not stall the whole scrape.
-define(WAL_INFO_DEADLINE_MS, 1500).

%% API
-export([setup/0]).
-export([teardown/0]).

%% TELEMETRY CALLBACKS
-export([handle_event/4]).

%% PROMETHEUS_COLLECTOR CALLBACKS
-export([collect_mf/2]).
-export([deregister_cleanup/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Declares all metric families, attaches the telemetry handler and registers
the collector. Idempotent; called from `bondy_prometheus:setup/0` at boot.
""".
-spec setup() -> ok.

setup() ->
    ok = declare_metrics(),
    case
        telemetry:attach_many(
            ?HANDLER_ID, events(), fun ?MODULE:handle_event/4, undefined
        )
    of
        ok -> ok;
        {error, already_exists} -> ok
    end,
    ok = prometheus_registry:register_collector(?MODULE).

-doc "Detaches the telemetry handler and deregisters the collector.".
-spec teardown() -> ok.

teardown() ->
    _ = telemetry:detach(?HANDLER_ID),
    _ = prometheus_registry:deregister_collector(default, ?MODULE),
    ok.

%% =============================================================================
%% TELEMETRY CALLBACKS
%% =============================================================================

-doc """
Maps a storage-stack telemetry event onto the Prometheus families declared
in `declare_metrics/0`. Never raises: `telemetry` silently detaches a
handler whose callback fails, which would turn one malformed event into a
permanent loss of all storage metrics.
""".
-spec handle_event(
    Event :: telemetry:event_name(),
    Measurements :: map(),
    Metadata :: map(),
    Config :: term()
) -> ok.

handle_event(Event, Meas, Meta, _Config) ->
    try
        do_handle_event(Event, Meas, Meta)
    catch
        Class:Reason ->
            ?LOG_DEBUG(#{
                description => "Failed to record storage telemetry event",
                event => Event,
                class => Class,
                reason => Reason
            }),
            ok
    end.

%% =============================================================================
%% PROMETHEUS_COLLECTOR CALLBACKS
%% =============================================================================

-spec collect_mf(
    prometheus_registry:registry(), prometheus_collector:callback()
) -> ok.

collect_mf(_Registry, CB) ->
    case lists:keymember(bondy_oplog, 1, application:which_applications()) of
        true ->
            lists:foreach(
                fun({Name, Help, Type, Fun}) ->
                    Metrics =
                        try
                            Fun()
                        catch
                            _:_ -> []
                        end,
                    case Metrics of
                        [] ->
                            ok;
                        _ ->
                            CB(
                                prometheus_model_helpers:create_mf(
                                    Name, Help, Type, Metrics
                                )
                            )
                    end
                end,
                families()
            ),
            collect_wal(CB),
            collect_sync_scheduler(CB),
            collect_bondy_metrics(CB);
        false ->
            ok
    end.

deregister_cleanup(_) -> ok.

%% =============================================================================
%% PRIVATE: TELEMETRY EVENT MAPPING
%% =============================================================================

%% @private
%% The exact set of event names this module attaches to. Events with
%% runtime-computed atoms (sync outcome, scheduler kind) are expanded here.
events() ->
    [
        %% WAL
        [bondy_oplog, wal, append],
        [bondy_oplog, wal, fsync],
        [bondy_oplog, wal, rotate],
        [bondy_oplog, wal, retention_sweep],
        [bondy_oplog, wal, recovery],
        [bondy_oplog, wal, recovery, rescan],
        [bondy_oplog, wal, wal_full],
        [bondy_oplog, wal_mem, wal_full],
        [bondy_oplog, wal, codec, compress],
        [bondy_oplog, wal, codec, decompress],
        [bondy_oplog, wal, codec, encrypt],
        [bondy_oplog, wal, codec, decrypt],
        [bondy_oplog, wal, scrub, run],
        %% Applier (batch pipeline stages + outcomes)
        [bondy_oplog, applier, batch_verify],
        [bondy_oplog, applier, batch_fold],
        [bondy_oplog, applier, batch_cell_apply],
        [bondy_oplog, applier, batch_cell_put],
        [bondy_oplog, applier, batch_publish],
        [bondy_oplog, applier, batch_install_cast],
        [bondy_oplog, applier, applied],
        [bondy_oplog, applier, published],
        [bondy_oplog, applier, context_regression],
        [bondy_oplog, applier, verify_failed],
        [bondy_oplog, applier, cells_swept],
        [bondy_oplog, applier, origins_reaped],
        [bondy_oplog, applier, replay_cell_events],
        [bondy_oplog, applier, validator_refresh],
        %% Instance
        [bondy_oplog, instance, append],
        [bondy_oplog, instance, backpressure],
        [bondy_oplog, instance, mst_install],
        [bondy_oplog, instance, apply_event, ok],
        [bondy_oplog, instance, append_remote, ok],
        [bondy_oplog, instance, append_remote, banned],
        [bondy_oplog, instance, append_remote, filtered],
        [bondy_oplog, instance, append_remote, equivocation],
        [bondy_oplog, instance, overlay, backpressure_drop],
        [bondy_oplog, instance, write_latency],
        [bondy_oplog, compaction, ok],
        [bondy_oplog, reclamation, stalled],
        %% Sync / AAE
        [bondy_oplog, sync, ok],
        [bondy_oplog, sync, error],
        [bondy_oplog, sync, catalogue_bootstrap, ok],
        [bondy_oplog, sync, catalogue_bootstrap, error],
        [bondy_oplog, sync, catalogue_bootstrap, complete],
        [bondy_oplog, scheduler, sync, tick],
        [bondy_oplog, sync_scheduler, dispatch_bootstrap],
        [bondy_oplog, sync_scheduler, bootstrap, started],
        [bondy_oplog, sync_scheduler, bootstrap, ended],
        [bondy_oplog, sync_scheduler, live, started],
        [bondy_oplog, sync_scheduler, live, ended],
        [bondy_oplog, sync_scheduler, load_yield],
        [bondy_oplog, sync_scheduler, bootstrap_load_deferred],
        [bondy_oplog, sync_scheduler, bootstrap_backoff_deferred],
        [bondy_oplog, sync_scheduler, bootstrap_capped],
        [bondy_oplog, sync_scheduler, bootstrap_retry_scheduled],
        [bondy_oplog, sync_scheduler, live_load_deferred],
        [bondy_oplog, sync_scheduler, live_sync_poll],
        [bondy_oplog, sync_scheduler, live_sync_skipped],
        [bondy_oplog, sync_scheduler, live_capped],
        [bondy_oplog, scheduler, gc, tick],
        [bondy_oplog, scheduler, gc, skipped],
        [bondy_oplog, scheduler, gc, trigger_outcome],
        %% Peer state / origin retirement
        [bondy_oplog, peer_state, excluded],
        [bondy_oplog, retirement, completed],
        [bondy_oplog, retirement, skipped],
        %% Secondary indexes
        [bondy_oplog, secondary_writer, flush],
        [bondy_oplog, secondary_writer, saturated],
        [bondy_oplog, secondary_index, rebuild],
        %% Core substrate periodic gauges (emitted by bondy_oplog_core_metrics)
        [bondy_oplog_core, metrics, refresh],
        %% MST
        [bondy_mst, merge, stop],
        [bondy_mst, merge, exception],
        [bondy_mst, merge, abandoned],
        [bondy_mst, gc, stop],
        [bondy_mst, gc, exception],
        [bondy_mst, broadcast, recv],
        [bondy_mst, broadcast, sent],
        [bondy_mst, page_store, put],
        [bondy_mst, page_store, get],
        [bondy_mst, page_store, seal_incoming],
        [bondy_mst, page_store, seal_roll],
        [bondy_mst, page_store, gc],
        [bondy_mst, page_store, recovery],
        [bondy_mst, page_store, idx_rebuild]
    ].

%% @private
declare_metrics() ->
    Counters = [
        {bondy_oplog_wal_appends_total, "WAL frame appends.", [instance_id]},
        {bondy_oplog_wal_appended_ops_total,
            "Operations appended to the WAL (batch sizes summed).", [
                instance_id
            ]},
        {bondy_oplog_wal_appended_bytes_total,
            "Bytes appended to the WAL (frame lengths summed).", [instance_id]},
        {bondy_oplog_wal_fsyncs_total, "WAL fsync calls.", [instance_id, mode]},
        {bondy_oplog_wal_fsync_bytes_total, "Bytes made durable by WAL fsyncs.",
            [instance_id, mode]},
        {bondy_oplog_wal_rotations_total, "WAL segment rotations.", [
            instance_id
        ]},
        {bondy_oplog_wal_retention_deleted_segments_total,
            "WAL segments deleted by retention sweeps.", [instance_id]},
        {bondy_oplog_wal_retention_freed_bytes_total,
            "Bytes freed by WAL retention sweeps.", [instance_id]},
        {bondy_oplog_wal_recoveries_total, "WAL recovery scans on open.", [
            instance_id
        ]},
        {bondy_oplog_wal_recovery_truncated_bytes_total,
            "Bytes truncated by WAL recovery.", [instance_id]},
        {bondy_oplog_wal_full_total, "WAL hard-backpressure activations.", [
            instance_id, reason
        ]},
        {bondy_oplog_wal_codec_ops_total, "WAL codec operations.", [
            instance_id, op, algorithm
        ]},
        {bondy_oplog_wal_codec_input_bytes_total, "WAL codec input bytes.", [
            instance_id, op, algorithm
        ]},
        {bondy_oplog_wal_codec_output_bytes_total, "WAL codec output bytes.", [
            instance_id, op, algorithm
        ]},
        {bondy_oplog_wal_scrub_runs_total, "WAL scrubber runs.", [instance_id]},
        {bondy_oplog_wal_scrub_frames_checked_total,
            "Frames checked by the WAL scrubber.", [instance_id]},
        {bondy_oplog_wal_scrub_corruption_total,
            "Corrupt frames found by the WAL scrubber.", [instance_id, kind]},
        {bondy_oplog_applier_batch_items_total,
            "Items processed per applier pipeline stage.", [instance_id, stage]},
        {bondy_oplog_applier_applied_total,
            "Events applied by the applier (incl. fused path).", [instance_id]},
        {bondy_oplog_applier_rejected_total, "Events rejected by the applier.",
            [instance_id]},
        {bondy_oplog_applier_published_total,
            "Apply-path notifications published.", [instance_id]},
        {bondy_oplog_applier_publish_skipped_total,
            "Apply-path notifications skipped.", [instance_id]},
        {bondy_oplog_applier_faults_total,
            "Applier fault signals (context regression, verify failure).", [
                instance_id, kind
            ]},
        {bondy_oplog_applier_sweep_cells_total, "Stable-cell sweep results.", [
            instance_id, result
        ]},
        {bondy_oplog_applier_origins_reaped_total,
            "Origins reaped from cell contexts.", [instance_id]},
        {bondy_oplog_applier_replayed_cells_total,
            "Cells applied by projection replay.", [instance_id, outcome]},
        {bondy_oplog_applier_validator_refreshes_total,
            "Validator refresh attempts.", [outcome]},
        {bondy_oplog_instance_appends_total,
            "Local append operations accepted by instances.", [instance_id]},
        {bondy_oplog_instance_backpressure_total,
            "Append rejections due to instance backpressure.", [instance_id]},
        {bondy_oplog_instance_mst_install_items_total,
            "Events installed into the MST.", [instance_id]},
        {bondy_oplog_remote_appends_total,
            "Remote (replicated) append outcomes.", [instance_id, outcome]},
        {bondy_oplog_apply_events_total,
            "Locally applied events installed into instance state.", [
                instance_id
            ]},
        {bondy_oplog_overlay_backpressure_drops_total,
            "Overlay writes dropped by backpressure.", [instance_id]},
        {bondy_oplog_compactions_total, "MST compactions completed.", [
            instance_id
        ]},
        {bondy_oplog_reclamation_stalled_total, "Reclamation attempts stalled.",
            [instance_id, reason]},
        {bondy_oplog_sync_sessions_total, "AAE sync sessions.", [
            instance_id, peer, outcome
        ]},
        {bondy_oplog_bootstrap_sessions_total, "Catalogue bootstrap sessions.",
            [instance_id, peer, outcome]},
        {bondy_oplog_bootstrap_cells_total,
            "Catalogue bootstrap cell outcomes.", [instance_id, result]},
        {bondy_oplog_sync_scheduler_events_total,
            "Sync scheduler activity by event kind.", [event]},
        {bondy_oplog_gc_scheduler_events_total,
            "GC scheduler activity by event kind.", [event]},
        {bondy_oplog_peer_exclusions_total,
            "Sync peer exclusions (stale peer_state).", [instance_id]},
        {bondy_oplog_retirements_total, "Origin retirement outcomes.", [
            outcome
        ]},
        {bondy_oplog_secondary_flush_ops_total, "Secondary index ops flushed.",
            [namespace, index]},
        {bondy_oplog_secondary_saturated_dropped_total,
            "Secondary index ops dropped due to writer saturation.", [
                namespace, index
            ]},
        {bondy_oplog_secondary_rebuilds_total, "Secondary index rebuilds.", [
            namespace, index
        ]},
        {bondy_mst_merges_total, "MST merges.", [result]},
        {bondy_mst_merges_abandoned_total, "MST exchange merges abandoned.",
            []},
        {bondy_mst_gc_runs_total, "MST store GC runs.", [result]},
        {bondy_mst_broadcasts_total, "MST CRDT gossip messages.", [direction]},
        {bondy_mst_broadcast_bytes_total, "MST CRDT gossip bytes.", [direction]},
        {bondy_mst_page_store_ops_total, "Page store operations.", [
            instance_id, op
        ]},
        {bondy_mst_page_store_bytes_total, "Page store bytes read/written.", [
            instance_id, op
        ]},
        {bondy_mst_seals_total, "Pack seals.", [instance_id, kind]},
        {bondy_mst_seal_records_total, "Records sealed into packs.", [
            instance_id, kind
        ]},
        {bondy_mst_seal_bytes_total, "Bytes sealed into packs.", [
            instance_id, kind
        ]},
        {bondy_mst_page_store_gc_runs_total, "Page store GC runs.", [
            instance_id, reason
        ]},
        {bondy_mst_page_store_gc_pages_dropped_total,
            "Pages dropped by page store GC.", [instance_id]},
        {bondy_mst_page_store_gc_packs_retired_total,
            "Packs retired by page store GC.", [instance_id]},
        {bondy_mst_page_store_gc_freed_bytes_total,
            "Bytes freed by page store GC.", [instance_id]},
        {bondy_mst_page_store_recoveries_total,
            "Page store incoming-pack recoveries.", [instance_id, result]},
        {bondy_mst_pack_idx_rebuilds_total, "Sealed-pack index rebuilds.", [
            instance_id, result
        ]}
    ],
    lists:foreach(
        fun({Name, Help, Labels}) ->
            _ = prometheus_counter:declare([
                {name, Name}, {help, Help}, {labels, Labels}
            ])
        end,
        Counters
    ),
    Histograms = [
        {bondy_oplog_wal_fsync_duration_microseconds, "WAL fsync duration.", [
            mode
        ]},
        {bondy_oplog_applier_batch_duration_microseconds,
            "Applier pipeline stage duration per batch.", [stage]},
        {bondy_oplog_instance_mst_install_duration_microseconds,
            "MST batch install duration.", []},
        {bondy_oplog_compaction_duration_microseconds,
            "MST compaction duration.", []},
        {bondy_oplog_sync_duration_microseconds, "AAE sync session duration.", [
                outcome
            ]},
        {bondy_oplog_bootstrap_duration_microseconds,
            "Catalogue bootstrap session duration.", [outcome]},
        {bondy_oplog_secondary_flush_duration_microseconds,
            "Secondary index flush duration.", []},
        {bondy_mst_merge_duration_microseconds, "MST merge duration.", []},
        {bondy_mst_seal_duration_microseconds, "Pack seal duration.", [kind]}
    ],
    lists:foreach(
        fun({Name, Help, Labels}) ->
            %% duration_unit false: values arrive already in microseconds;
            %% otherwise prometheus infers the unit from the `_microseconds`
            %% suffix and converts values from native time units.
            _ = prometheus_histogram:declare([
                {name, Name},
                {help, Help},
                {labels, Labels},
                {buckets, ?DURATION_BUCKETS_US},
                {duration_unit, false}
            ])
        end,
        Histograms
    ),
    Gauges = [
        {bondy_oplog_core_cache_hit_ratio,
            "Substrate cache hit ratio over the last refresh interval.", [
                namespace
            ]},
        {bondy_oplog_core_read_rps,
            "Substrate point reads per second (last refresh interval).", [
                namespace
            ]},
        {bondy_oplog_core_range_rps,
            "Substrate range reads per second (last refresh interval).", [
                namespace
            ]},
        {bondy_oplog_core_subscribers, "Substrate pub/sub subscribers.", [
            namespace
        ]},
        {bondy_oplog_core_freshness_lag_max_milliseconds,
            "Max AE freshness lag across the namespace's shards.", [namespace]},
        {bondy_oplog_write_readable_latency_microseconds,
            "Write-to-readable latency (rolling window quantiles).", [
                instance_id, quantile
            ]}
    ],
    lists:foreach(
        fun({Name, Help, Labels}) ->
            _ = prometheus_gauge:declare([
                {name, Name},
                {help, Help},
                {labels, Labels},
                {duration_unit, false}
            ])
        end,
        Gauges
    ),
    ok.

%% @private
do_handle_event([bondy_oplog, wal, append], Meas, Meta) ->
    Id = instance_id(Meta),
    counter(bondy_oplog_wal_appends_total, [Id], 1),
    counter(bondy_oplog_wal_appended_ops_total, [Id], num(batch_size, Meas)),
    counter(bondy_oplog_wal_appended_bytes_total, [Id], num(frame_len, Meas));
do_handle_event([bondy_oplog, wal, fsync], Meas, Meta) ->
    Id = instance_id(Meta),
    Mode = maps:get(mode, Meta, undefined),
    counter(bondy_oplog_wal_fsyncs_total, [Id, Mode], 1),
    counter(
        bondy_oplog_wal_fsync_bytes_total, [Id, Mode], num(bytes_synced, Meas)
    ),
    histogram(
        bondy_oplog_wal_fsync_duration_microseconds,
        [Mode],
        num(duration_us, Meas)
    );
do_handle_event([bondy_oplog, wal, rotate], _Meas, Meta) ->
    counter(bondy_oplog_wal_rotations_total, [instance_id(Meta)], 1);
do_handle_event([bondy_oplog, wal, retention_sweep], Meas, Meta) ->
    Id = instance_id(Meta),
    counter(
        bondy_oplog_wal_retention_deleted_segments_total,
        [Id],
        num(deleted_segments, Meas)
    ),
    counter(
        bondy_oplog_wal_retention_freed_bytes_total,
        [Id],
        num(freed_bytes, Meas)
    );
do_handle_event([bondy_oplog, wal, recovery], Meas, Meta) ->
    Id = instance_id(Meta),
    counter(bondy_oplog_wal_recoveries_total, [Id], 1),
    counter(
        bondy_oplog_wal_recovery_truncated_bytes_total,
        [Id],
        num(truncated_bytes, Meas)
    );
do_handle_event([bondy_oplog, wal, recovery, rescan], _Meas, _Meta) ->
    ok;
do_handle_event([bondy_oplog, wal, wal_full], _Meas, Meta) ->
    counter(
        bondy_oplog_wal_full_total,
        [instance_id(Meta), maps:get(reason, Meta, undefined)],
        1
    );
do_handle_event([bondy_oplog, wal_mem, wal_full], _Meas, Meta) ->
    counter(
        bondy_oplog_wal_full_total,
        [instance_id(Meta), max_live_events],
        1
    );
do_handle_event([bondy_oplog, wal, codec, Op], Meas, Meta) ->
    Id = instance_id(Meta),
    Algo = maps:get(algorithm, Meta, undefined),
    counter(bondy_oplog_wal_codec_ops_total, [Id, Op, Algo], 1),
    counter(
        bondy_oplog_wal_codec_input_bytes_total,
        [Id, Op, Algo],
        num(input_bytes, Meas)
    ),
    counter(
        bondy_oplog_wal_codec_output_bytes_total,
        [Id, Op, Algo],
        num(output_bytes, Meas)
    );
do_handle_event([bondy_oplog, wal, scrub, run], Meas, Meta) ->
    Id = instance_id(Meta),
    counter(bondy_oplog_wal_scrub_runs_total, [Id], 1),
    counter(
        bondy_oplog_wal_scrub_frames_checked_total,
        [Id],
        num(frames_checked, Meas)
    ),
    lists:foreach(
        fun(Kind) ->
            case num(Kind, Meas) of
                0 ->
                    ok;
                N ->
                    counter(
                        bondy_oplog_wal_scrub_corruption_total, [Id, Kind], N
                    )
            end
        end,
        [bad_crc, bad_magic, truncated_segment]
    );
do_handle_event([bondy_oplog, applier, Stage], Meas, Meta) when
    Stage == batch_verify orelse
        Stage == batch_fold orelse
        Stage == batch_cell_apply orelse
        Stage == batch_cell_put orelse
        Stage == batch_publish orelse
        Stage == batch_install_cast
->
    <<"batch_", StageBin/binary>> = atom_to_binary(Stage),
    counter(
        bondy_oplog_applier_batch_items_total,
        [instance_id(Meta), StageBin],
        num(count, Meas)
    ),
    histogram(
        bondy_oplog_applier_batch_duration_microseconds,
        [StageBin],
        num(duration_us, Meas)
    );
do_handle_event([bondy_oplog, applier, applied], Meas, Meta) ->
    Id = instance_id(Meta),
    counter(bondy_oplog_applier_applied_total, [Id], num(count, Meas)),
    case num(rejected, Meas) of
        0 -> ok;
        R -> counter(bondy_oplog_applier_rejected_total, [Id], R)
    end;
do_handle_event([bondy_oplog, applier, published], Meas, Meta) ->
    Id = instance_id(Meta),
    counter(bondy_oplog_applier_published_total, [Id], num(count, Meas)),
    case num(skipped, Meas) of
        0 -> ok;
        S -> counter(bondy_oplog_applier_publish_skipped_total, [Id], S)
    end;
do_handle_event([bondy_oplog, applier, context_regression], _Meas, Meta) ->
    counter(
        bondy_oplog_applier_faults_total,
        [instance_id(Meta), context_regression],
        1
    );
do_handle_event([bondy_oplog, applier, verify_failed], _Meas, Meta) ->
    counter(
        bondy_oplog_applier_faults_total,
        [instance_id(Meta), verify_failed],
        1
    );
do_handle_event([bondy_oplog, applier, cells_swept], Meas, Meta) ->
    Id = instance_id(Meta),
    lists:foreach(
        fun(Result) ->
            case num(Result, Meas) of
                0 ->
                    ok;
                N ->
                    counter(
                        bondy_oplog_applier_sweep_cells_total, [Id, Result], N
                    )
            end
        end,
        [scanned, discarded, reduction_skipped, skipped]
    );
do_handle_event([bondy_oplog, applier, origins_reaped], Meas, Meta) ->
    counter(
        bondy_oplog_applier_origins_reaped_total,
        [instance_id(Meta)],
        num(origins, Meas)
    );
do_handle_event([bondy_oplog, applier, replay_cell_events], Meas, Meta) ->
    counter(
        bondy_oplog_applier_replayed_cells_total,
        [instance_id(Meta), maps:get(outcome, Meta, undefined)],
        num(cells_applied, Meas)
    );
do_handle_event([bondy_oplog, applier, validator_refresh], _Meas, Meta) ->
    counter(
        bondy_oplog_applier_validator_refreshes_total,
        [maps:get(outcome, Meta, undefined)],
        1
    );
do_handle_event([bondy_oplog, instance, append], Meas, Meta) ->
    counter(
        bondy_oplog_instance_appends_total,
        [instance_id(Meta)],
        num(count, Meas)
    );
do_handle_event([bondy_oplog, instance, backpressure], _Meas, Meta) ->
    counter(
        bondy_oplog_instance_backpressure_total, [instance_id(Meta)], 1
    );
do_handle_event([bondy_oplog, instance, mst_install], Meas, Meta) ->
    counter(
        bondy_oplog_instance_mst_install_items_total,
        [instance_id(Meta)],
        num(count, Meas)
    ),
    histogram(
        bondy_oplog_instance_mst_install_duration_microseconds,
        [],
        num(duration_us, Meas)
    );
do_handle_event([bondy_oplog, instance, apply_event, ok], Meas, Meta) ->
    counter(
        bondy_oplog_apply_events_total,
        [instance_id(Meta)],
        num(count, Meas)
    );
do_handle_event([bondy_oplog, instance, append_remote, Outcome], Meas, Meta) ->
    counter(
        bondy_oplog_remote_appends_total,
        [instance_id(Meta), Outcome],
        max(1, num(count, Meas))
    );
do_handle_event(
    [bondy_oplog, instance, overlay, backpressure_drop], _Meas, Meta
) ->
    counter(
        bondy_oplog_overlay_backpressure_drops_total, [instance_id(Meta)], 1
    );
do_handle_event([bondy_oplog, instance, write_latency], Meas, Meta) ->
    Id = instance_id(Meta),
    lists:foreach(
        fun({Key, Quantile}) ->
            gauge(
                bondy_oplog_write_readable_latency_microseconds,
                [Id, Quantile],
                num(Key, Meas)
            )
        end,
        [
            {mean_us, mean},
            {p50_us, p50},
            {p95_us, p95},
            {p99_us, p99},
            {max_us, max}
        ]
    );
do_handle_event([bondy_oplog, compaction, ok], Meas, Meta) ->
    Id = instance_id(Meta),
    counter(bondy_oplog_compactions_total, [Id], 1),
    histogram(
        bondy_oplog_compaction_duration_microseconds,
        [],
        num(duration_us, Meas)
    );
do_handle_event([bondy_oplog, reclamation, stalled], _Meas, Meta) ->
    counter(
        bondy_oplog_reclamation_stalled_total,
        [instance_id(Meta), label(maps:get(reason, Meta, undefined))],
        1
    );
do_handle_event([bondy_oplog, sync, Outcome], Meas, Meta) when
    Outcome == ok orelse Outcome == error
->
    counter(
        bondy_oplog_sync_sessions_total,
        [instance_id(Meta), maps:get(peer, Meta, undefined), Outcome],
        1
    ),
    histogram(
        bondy_oplog_sync_duration_microseconds,
        [Outcome],
        native_to_us(num(duration, Meas))
    );
do_handle_event(
    [bondy_oplog, sync, catalogue_bootstrap, complete], Meas, Meta
) ->
    Id = instance_id(Meta),
    counter(
        bondy_oplog_bootstrap_cells_total,
        [Id, installed],
        num(installed, Meas)
    ),
    counter(
        bondy_oplog_bootstrap_cells_total, [Id, skipped], num(skipped, Meas)
    );
do_handle_event([bondy_oplog, sync, catalogue_bootstrap, Outcome], Meas, Meta) ->
    counter(
        bondy_oplog_bootstrap_sessions_total,
        [instance_id(Meta), maps:get(peer, Meta, undefined), Outcome],
        1
    ),
    histogram(
        bondy_oplog_bootstrap_duration_microseconds,
        [Outcome],
        native_to_us(num(duration, Meas))
    );
do_handle_event([bondy_oplog, scheduler, sync, tick], _Meas, _Meta) ->
    counter(bondy_oplog_sync_scheduler_events_total, [tick], 1);
do_handle_event([bondy_oplog, sync_scheduler, Kind, Suffix], _Meas, _Meta) when
    Kind == bootstrap orelse Kind == live
->
    Event = <<
        (atom_to_binary(Kind))/binary, "_", (atom_to_binary(Suffix))/binary
    >>,
    counter(bondy_oplog_sync_scheduler_events_total, [Event], 1);
do_handle_event([bondy_oplog, sync_scheduler, Event], _Meas, _Meta) ->
    counter(bondy_oplog_sync_scheduler_events_total, [Event], 1);
do_handle_event([bondy_oplog, scheduler, gc, trigger_outcome], _Meas, Meta) ->
    Event = <<"trigger_", (label(maps:get(outcome, Meta, undefined)))/binary>>,
    counter(bondy_oplog_gc_scheduler_events_total, [Event], 1);
do_handle_event([bondy_oplog, scheduler, gc, Event], _Meas, _Meta) ->
    counter(bondy_oplog_gc_scheduler_events_total, [Event], 1);
do_handle_event([bondy_oplog, peer_state, excluded], Meas, Meta) ->
    counter(
        bondy_oplog_peer_exclusions_total,
        [instance_id(Meta)],
        max(1, num(count, Meas))
    );
do_handle_event([bondy_oplog, retirement, completed], _Meas, _Meta) ->
    counter(bondy_oplog_retirements_total, [completed], 1);
do_handle_event([bondy_oplog, retirement, skipped], _Meas, _Meta) ->
    counter(bondy_oplog_retirements_total, [skipped], 1);
do_handle_event([bondy_oplog, secondary_writer, flush], Meas, Meta) ->
    NS = maps:get(namespace, Meta, undefined),
    Index = maps:get(index_name, Meta, undefined),
    counter(
        bondy_oplog_secondary_flush_ops_total, [NS, Index], num(ops, Meas)
    ),
    histogram(
        bondy_oplog_secondary_flush_duration_microseconds,
        [],
        num(duration_us, Meas)
    );
do_handle_event([bondy_oplog, secondary_writer, saturated], Meas, Meta) ->
    counter(
        bondy_oplog_secondary_saturated_dropped_total,
        [
            maps:get(namespace, Meta, undefined),
            maps:get(index_name, Meta, undefined)
        ],
        max(1, num(dropped_ops, Meas))
    );
do_handle_event([bondy_oplog, secondary_index, rebuild], _Meas, Meta) ->
    counter(
        bondy_oplog_secondary_rebuilds_total,
        [
            maps:get(namespace, Meta, undefined),
            maps:get(index_name, Meta, undefined)
        ],
        1
    );
do_handle_event([bondy_oplog_core, metrics, refresh], Meas, Meta) ->
    NS = maps:get(namespace, Meta, undefined),
    gauge(bondy_oplog_core_cache_hit_ratio, [NS], num(cache_hit_rate, Meas)),
    gauge(bondy_oplog_core_read_rps, [NS], num(read_rps, Meas)),
    gauge(bondy_oplog_core_range_rps, [NS], num(range_rps, Meas)),
    gauge(bondy_oplog_core_subscribers, [NS], num(subscriber_count, Meas)),
    gauge(
        bondy_oplog_core_freshness_lag_max_milliseconds,
        [NS],
        num(current_freshness_lag_max_ms, Meas)
    );
do_handle_event([bondy_mst, merge, stop], Meas, _Meta) ->
    counter(bondy_mst_merges_total, [ok], 1),
    histogram(
        bondy_mst_merge_duration_microseconds,
        [],
        native_to_us(num(duration, Meas))
    );
do_handle_event([bondy_mst, merge, exception], _Meas, _Meta) ->
    counter(bondy_mst_merges_total, [error], 1);
do_handle_event([bondy_mst, merge, abandoned], _Meas, _Meta) ->
    counter(bondy_mst_merges_abandoned_total, [], 1);
do_handle_event([bondy_mst, gc, stop], _Meas, _Meta) ->
    counter(bondy_mst_gc_runs_total, [ok], 1);
do_handle_event([bondy_mst, gc, exception], _Meas, _Meta) ->
    counter(bondy_mst_gc_runs_total, [error], 1);
do_handle_event([bondy_mst, broadcast, Direction], Meas, _Meta) ->
    counter(bondy_mst_broadcasts_total, [Direction], 1),
    counter(bondy_mst_broadcast_bytes_total, [Direction], num(bytes, Meas));
do_handle_event([bondy_mst, page_store, Op], Meas, Meta) when
    Op == put orelse Op == get
->
    Id = instance_id(Meta),
    counter(bondy_mst_page_store_ops_total, [Id, Op], 1),
    counter(bondy_mst_page_store_bytes_total, [Id, Op], num(page_bytes, Meas));
do_handle_event([bondy_mst, page_store, SealKind], Meas, Meta) when
    SealKind == seal_incoming orelse SealKind == seal_roll
->
    Id = instance_id(Meta),
    <<"seal_", Kind/binary>> = atom_to_binary(SealKind),
    counter(bondy_mst_seals_total, [Id, Kind], 1),
    counter(
        bondy_mst_seal_records_total, [Id, Kind], num(record_count, Meas)
    ),
    counter(bondy_mst_seal_bytes_total, [Id, Kind], num(pack_bytes, Meas)),
    histogram(
        bondy_mst_seal_duration_microseconds, [Kind], num(duration_us, Meas)
    );
do_handle_event([bondy_mst, page_store, gc], Meas, Meta) ->
    Id = instance_id(Meta),
    counter(
        bondy_mst_page_store_gc_runs_total,
        [Id, maps:get(reason, Meta, undefined)],
        1
    ),
    counter(
        bondy_mst_page_store_gc_pages_dropped_total,
        [Id],
        num(pages_dropped, Meas)
    ),
    counter(
        bondy_mst_page_store_gc_packs_retired_total,
        [Id],
        num(packs_retired, Meas)
    ),
    counter(
        bondy_mst_page_store_gc_freed_bytes_total,
        [Id],
        num(bytes_freed, Meas)
    );
do_handle_event([bondy_mst, page_store, recovery], _Meas, Meta) ->
    counter(
        bondy_mst_page_store_recoveries_total,
        [instance_id(Meta), result_label(maps:get(result, Meta, undefined))],
        1
    );
do_handle_event([bondy_mst, page_store, idx_rebuild], _Meas, Meta) ->
    counter(
        bondy_mst_pack_idx_rebuilds_total,
        [instance_id(Meta), result_label(maps:get(result, Meta, undefined))],
        1
    );
do_handle_event(_Event, _Meas, _Meta) ->
    ok.

%% =============================================================================
%% PRIVATE: COLLECTOR GAUGE FAMILIES
%% =============================================================================

%% @private
%% Scrape-time gauge families. Each fun returns `[{Labels, Value}]`; an
%% empty list (or a crash, caught by the caller) skips the family.
families() ->
    [
        {bondy_cluster_members, "Size of the Partisan membership view.", gauge,
            fun cluster_members/0},
        {bondy_cluster_connected_peers, "Number of connected Partisan peers.",
            gauge, fun cluster_connected/0},
        {bondy_cluster_all_members_connected,
            "1 when every member of the Partisan view is reachable.", gauge,
            fun cluster_all_connected/0},
        {bondy_cluster_peer_connected,
            "Per-peer Partisan connectivity (1 connected, 0 not).", gauge,
            fun cluster_peer_rows/0},
        {bondy_oplog_aae_enabled, "1 when AAE is enabled on this node.", gauge,
            fun aae_enabled/0},
        {bondy_oplog_instances, "Oplog instances by bootstrap lifecycle state.",
            gauge, fun instances_by_lifecycle/0},
        {bondy_oplog_instance_lifecycle_code,
            "Per-instance lifecycle (0 starting, 1 pre_bootstrap, 2 live).",
            gauge, fun instance_lifecycle_rows/0},
        {bondy_oplog_instance_live_size,
            "Per-instance live (unapplied overlay) size.", gauge,
            fun instance_live_size_rows/0},
        {bondy_oplog_instance_frontier_hash,
            "Stable hash of the applied-frontier version vector. Equal "
            "across nodes iff the instance is converged.", gauge,
            fun frontier_hash_rows/0},
        {bondy_oplog_instance_frontier_origins,
            "Number of origins in the applied-frontier version vector.", gauge,
            fun frontier_origin_rows/0},
        {bondy_oplog_instance_frontier_seq_total,
            "Sum of per-origin max sequence numbers in the applied "
            "frontier. Monotone; cross-node differences show replication "
            "lag.", gauge, fun frontier_seq_rows/0},
        {bondy_oplog_peer_last_sync_age_seconds,
            "Seconds since the last completed sync with a peer, per "
            "(instance, peer).", gauge, fun() -> peer_age_rows(last_sync) end},
        {bondy_oplog_peer_last_seen_age_seconds,
            "Seconds since a peer was last seen, per (instance, peer).", gauge,
            fun() -> peer_age_rows(last_seen) end},
        {bondy_oplog_peer_state_entries, "Rows in the peer sync-state table.",
            gauge, fun peer_state_size/0},
        {bondy_oplog_core_ae_lag_milliseconds,
            "Per-shard AE freshness lag of the substrate.", gauge,
            fun ae_lag_rows/0},
        {bondy_oplog_gc_scheduler_inflight, "In-flight MST GC/compaction runs.",
            gauge, fun gc_scheduler_inflight/0}
    ].

%% @private
cluster_members() ->
    [{[], length(members())}].

%% @private
cluster_connected() ->
    [{[], length(connected())}].

%% @private
cluster_all_connected() ->
    Members = members(),
    Reachable = lists:usort([self_node() | connected()]),
    [{[], bool_to_int(Members -- Reachable == [])}].

%% @private
cluster_peer_rows() ->
    Self = self_node(),
    Members = members(),
    Connected = connected(),
    Nodes = lists:usort(Members ++ Connected ++ [Self]),
    [
        {
            [
                {peer, N},
                {member, bool_to_int(lists:member(N, Members))},
                {self, bool_to_int(N =:= Self)}
            ],
            bool_to_int(N =:= Self orelse lists:member(N, Connected))
        }
     || N <- Nodes
    ].

%% @private
aae_enabled() ->
    Enabled = application:get_env(bondy_oplog, aae_enabled, false) == true,
    [{[], bool_to_int(Enabled)}].

%% @private
instances_by_lifecycle() ->
    Counts = lists:foldl(
        fun(Id, Acc) ->
            maps:update_with(lifecycle(Id), fun(N) -> N + 1 end, 1, Acc)
        end,
        #{},
        instances()
    ),
    [{[{lifecycle, State}], N} || {State, N} <- maps:to_list(Counts)].

%% @private
instance_lifecycle_rows() ->
    [
        {[{instance_id, Id}], lifecycle_code(lifecycle(Id))}
     || Id <- instances()
    ].

%% @private
instance_live_size_rows() ->
    lists:filtermap(
        fun(Id) ->
            case catch bondy_oplog_registry:live_size(Id) of
                N when is_integer(N) ->
                    {true, {[{instance_id, Id}], N}};
                _ ->
                    false
            end
        end,
        instances()
    ).

%% @private
frontier_hash_rows() ->
    [
        {[{instance_id, Id}], erlang:phash2(frontier(Id))}
     || Id <- instances()
    ].

%% @private
frontier_origin_rows() ->
    [{[{instance_id, Id}], map_size(frontier(Id))} || Id <- instances()].

%% @private
frontier_seq_rows() ->
    [
        {
            [{instance_id, Id}],
            lists:sum([S || S <- maps:values(frontier(Id)), is_integer(S)])
        }
     || Id <- instances()
    ].

%% @private
%% Emits the per-instance WAL writer gauges from ONE parallel gather of
%% `bondy_oplog_wal:info/1` snapshots per scrape.
collect_wal(CB) ->
    Infos =
        try
            wal_infos()
        catch
            _:_ -> []
        end,
    Families = [
        {bondy_oplog_wal_size_bytes, "Total bytes across live WAL segments.",
            bytes_total},
        {bondy_oplog_wal_live_segments, "Live WAL segments.",
            live_segments_count},
        {bondy_oplog_wal_pending_fsync_bytes,
            "Bytes appended but not yet fsynced.", pending_fsync_bytes},
        {bondy_oplog_wal_waiters, "Callers blocked awaiting WAL durability.",
            waiter_count},
        {bondy_oplog_wal_head_lag_milliseconds,
            "Age of the newest unfsynced append.", head_lag_ms}
    ],
    lists:foreach(
        fun({Name, Help, Key}) ->
            Metrics = lists:filtermap(
                fun({Id, Info}) ->
                    case maps:get(Key, Info, undefined) of
                        V when is_integer(V) ->
                            {true, {[{instance_id, Id}], V}};
                        _ ->
                            false
                    end
                end,
                Infos
            ),
            emit_gauge_mf(CB, Name, Help, Metrics)
        end,
        Families
    ),
    Backpressure = [
        {[{instance_id, Id}], bp_to_int(maps:get(backpressure, Info, ok))}
     || {Id, Info} <- Infos
    ],
    emit_gauge_mf(
        CB,
        bondy_oplog_wal_backpressure,
        "1 when the WAL is in hard backpressure.",
        Backpressure
    ).

%% @private
%% Emits the sync-scheduler gauges from ONE `info/0` call per scrape.
collect_sync_scheduler(CB) ->
    Info =
        case catch bondy_oplog_sync_scheduler:info() of
            #{} = M -> M;
            _ -> #{}
        end,
    Scalars = [
        {bondy_oplog_sync_scheduler_enabled,
            "1 when the AAE sync scheduler is enabled.", enabled},
        {bondy_oplog_sync_scheduler_interval_milliseconds,
            "Sync scheduler tick interval.", interval_ms},
        {bondy_oplog_sync_scheduler_load,
            "Sync scheduler run-queue load sample.", current_load},
        {bondy_oplog_sync_scheduler_yielding,
            "1 when the sync scheduler is load-yielding.", load_yielding}
    ],
    lists:foreach(
        fun({Name, Help, Key}) ->
            Metrics =
                case maps:get(Key, Info, undefined) of
                    true -> [{[], 1}];
                    false -> [{[], 0}];
                    N when is_number(N) -> [{[], N}];
                    _ -> []
                end,
            emit_gauge_mf(CB, Name, Help, Metrics)
        end,
        Scalars
    ),
    Inflight = lists:filtermap(
        fun({Kind, Key}) ->
            case maps:get(Key, Info, undefined) of
                N when is_integer(N) -> {true, {[{kind, Kind}], N}};
                _ -> false
            end
        end,
        [
            {total, current_inflight_total},
            {bootstrap, current_inflight_bootstraps}
        ]
    ),
    emit_gauge_mf(
        CB,
        bondy_oplog_sync_scheduler_inflight,
        "In-flight sync sessions by kind.",
        Inflight
    ).

%% @private
emit_gauge_mf(_CB, _Name, _Help, []) ->
    ok;
emit_gauge_mf(CB, Name, Help, Metrics) ->
    CB(prometheus_model_helpers:create_mf(Name, Help, gauge, Metrics)).

%% @private
bp_to_int(ok) -> 0;
bp_to_int(_) -> 1.

%% @private
peer_age_rows(Key) ->
    Now = os:system_time(millisecond),
    lists:flatmap(
        fun(Id) ->
            Entries =
                case
                    catch bondy_oplog_peer_state:get_instance_peer_states(
                        Id, 0
                    )
                of
                    L when is_list(L) -> L;
                    _ -> []
                end,
            [
                {
                    [{instance_id, Id}, {peer, maps:get(peer, E)}],
                    max(0, Now - maps:get(Key, E)) div 1000
                }
             || E <- Entries, is_integer(maps:get(Key, E, undefined))
            ]
        end,
        instances()
    ).

%% @private
peer_state_size() ->
    case catch bondy_oplog_peer_state:info() of
        #{table_size := N} when is_integer(N) -> [{[], N}];
        _ -> []
    end.

%% @private
ae_lag_rows() ->
    Namespaces =
        case catch bondy_oplog_core_registry:namespaces() of
            L when is_list(L) -> L;
            _ -> []
        end,
    lists:flatmap(
        fun(NS) ->
            case catch bondy_oplog_core:freshness(NS) of
                Map when is_map(Map) ->
                    [
                        {
                            [
                                {namespace, NS},
                                {index, Index},
                                {shard, Shard}
                            ],
                            max(0, Lag)
                        }
                     || {{Index, Shard}, Lag} <- maps:to_list(Map),
                        is_integer(Lag)
                    ];
                _ ->
                    []
            end
        end,
        Namespaces
    ).

%% @private
gc_scheduler_inflight() ->
    case catch bondy_oplog_gc_scheduler:info() of
        #{in_flight := N} when is_integer(N) -> [{[], N}];
        _ -> []
    end.

%% @private
%% Re-exposes every counter/gauge accumulated in `bondy_metrics` (the
%% storage stack's wait-free registry, e.g. `bondy_oplog_core_reads_total`)
%% under its own name. Histogram-typed entries are skipped: their quantiles
%% are already exported as gauges from the periodic
%% `[bondy_oplog, instance, write_latency]` roll-up event.
collect_bondy_metrics(CB) ->
    Rows =
        try
            bondy_metrics:all()
        catch
            _:_ -> []
        end,
    ByName = lists:foldl(
        fun
            (#{type := histogram}, Acc) ->
                Acc;
            (#{name := N, label := L, type := T, value := V}, Acc) ->
                Row = {label_map_to_list(L), V},
                maps:update_with(
                    {N, T}, fun(Acc1) -> [Row | Acc1] end, [Row], Acc
                )
        end,
        #{},
        Rows
    ),
    maps:foreach(
        fun({Name, Type}, Metrics) ->
            PromType =
                case Type of
                    counter -> counter;
                    _ -> gauge
                end,
            CB(
                prometheus_model_helpers:create_mf(
                    Name,
                    "bondy_metrics registry passthrough.",
                    PromType,
                    Metrics
                )
            )
        end,
        ByName
    ).

%% =============================================================================
%% PRIVATE: RUNTIME STATE READERS
%% =============================================================================

%% @private
instances() ->
    case catch bondy_oplog:list_instances() of
        L when is_list(L) -> lists:sort(L);
        _ -> []
    end.

%% @private
frontier(Id) ->
    case catch bondy_oplog_registry:frontier(Id) of
        F when is_map(F) -> F;
        _ -> #{}
    end.

%% @private
lifecycle(Id) ->
    case catch bondy_oplog_instance:lifecycle_state(Id) of
        live -> live;
        pre_bootstrap -> pre_bootstrap;
        _ -> starting
    end.

%% @private
lifecycle_code(starting) -> 0;
lifecycle_code(pre_bootstrap) -> 1;
lifecycle_code(live) -> 2.

%% @private
self_node() ->
    try
        partisan:node()
    catch
        _:_ -> node()
    end.

%% @private
members() ->
    case catch partisan_peer_service:members() of
        {ok, M} when is_list(M) -> M;
        M when is_list(M) -> M;
        _ -> []
    end.

%% @private
connected() ->
    case catch partisan:nodes() of
        N when is_list(N) -> N;
        _ -> []
    end.

%% @private
%% Gathers `bondy_oplog_wal:info/1` snapshots for every instance with a WAL
%% writer, in parallel and under a global deadline so one slow writer cannot
%% stall the scrape. Replies are addressed to an alias so stragglers
%% arriving after `unalias/1` are dropped instead of leaking into the
%% scraping process's mailbox.
wal_infos() ->
    Alias = alias(),
    Pending = lists:foldl(
        fun(Id, Acc) ->
            case catch bondy_oplog_registry:wal_pid(Id) of
                Pid when is_pid(Pid) ->
                    _ = spawn(fun() ->
                        Info =
                            try
                                bondy_oplog_wal:info(Pid)
                            catch
                                _:_ -> undefined
                            end,
                        Alias ! {Alias, Id, Info}
                    end),
                    Acc + 1;
                _ ->
                    Acc
            end
        end,
        0,
        instances()
    ),
    Deadline =
        erlang:monotonic_time(millisecond) + ?WAL_INFO_DEADLINE_MS,
    Infos = await_wal_infos(Alias, Pending, Deadline, []),
    _ = unalias(Alias),
    flush_wal_infos(Alias),
    Infos.

%% @private
await_wal_infos(_Alias, 0, _Deadline, Acc) ->
    Acc;
await_wal_infos(Alias, Pending, Deadline, Acc) ->
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Alias, Id, Info} when is_map(Info) ->
            await_wal_infos(Alias, Pending - 1, Deadline, [{Id, Info} | Acc]);
        {Alias, _Id, _} ->
            await_wal_infos(Alias, Pending - 1, Deadline, Acc)
    after Timeout ->
        Acc
    end.

%% @private
flush_wal_infos(Alias) ->
    receive
        {Alias, _, _} -> flush_wal_infos(Alias)
    after 0 ->
        ok
    end.

%% =============================================================================
%% PRIVATE: HELPERS
%% =============================================================================

%% @private
counter(Name, LabelValues, Value) when is_integer(Value), Value >= 0 ->
    prometheus_counter:inc(Name, LabelValues, Value);
counter(_, _, _) ->
    ok.

%% @private
gauge(Name, LabelValues, Value) when is_number(Value) ->
    prometheus_gauge:set(Name, LabelValues, Value);
gauge(_, _, _) ->
    ok.

%% @private
histogram(Name, LabelValues, Value) when is_number(Value), Value >= 0 ->
    prometheus_histogram:observe(Name, LabelValues, round(Value));
histogram(_, _, _) ->
    ok.

%% @private
num(Key, Map) ->
    case maps:get(Key, Map, 0) of
        N when is_number(N) -> N;
        _ -> 0
    end.

%% @private
native_to_us(N) when is_integer(N) ->
    erlang:convert_time_unit(N, native, microsecond);
native_to_us(_) ->
    0.

%% @private
instance_id(Meta) ->
    case maps:get(instance_id, Meta, undefined) of
        Id when is_binary(Id) orelse is_atom(Id) -> Id;
        Other -> label(Other)
    end.

%% @private
%% Renders an arbitrary term as a bounded, printable label value.
label(V) when is_atom(V) ->
    atom_to_binary(V);
label(V) when is_binary(V) ->
    V;
label(V) ->
    unicode:characters_to_binary(io_lib:format("~0p", [V])).

%% @private
result_label(ok) -> ok;
result_label({error, _}) -> error;
result_label(_) -> unknown.

%% @private
bool_to_int(true) -> 1;
bool_to_int(false) -> 0.

%% @private
label_map_to_list(L) when is_map(L) ->
    lists:keysort(1, [{K, label_value(V)} || {K, V} <- maps:to_list(L)]).

%% @private
label_value(V) when is_atom(V) orelse is_binary(V) -> V;
label_value(V) when is_integer(V) -> integer_to_binary(V);
label_value(V) -> label(V).
