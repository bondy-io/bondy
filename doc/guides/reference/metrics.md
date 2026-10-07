# Metrics

A node exports Prometheus metrics at `/metrics` on every listener that carries
the `metrics` service. The built-in `admin` listener carries it. See
[Listeners](../configuration/listeners.md) for how services are assigned.

The bundled Prometheus, Grafana and Tempo stack that scrapes these families is
described in [`monitoring/README.md`](../../../monitoring/README.md).

This page lists the families Bondy declares. The labels given are the labels
each family carries on every series. A labelled family has no series until it
is first recorded, so a counter that has never been incremented can be absent
from a scrape rather than zero.

A family's unit, when it has one, is the suffix of its name: `_seconds`,
`_milliseconds`, `_microseconds` or `_bytes`.

## Storage: write-ahead log

Counters carry `instance_id`, one series per oplog instance.

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_oplog_wal_appends_total` | counter | `instance_id` | WAL frame appends. |
| `bondy_oplog_wal_appended_ops_total` | counter | `instance_id` | Operations appended (batch sizes summed). |
| `bondy_oplog_wal_appended_bytes_total` | counter | `instance_id` | Bytes appended (frame lengths summed). |
| `bondy_oplog_wal_fsyncs_total` | counter | `instance_id`, `mode` | WAL fsync calls. |
| `bondy_oplog_wal_fsync_bytes_total` | counter | `instance_id`, `mode` | Bytes made durable by fsyncs. |
| `bondy_oplog_wal_fsync_duration_microseconds` | histogram | `mode` | Fsync duration. |
| `bondy_oplog_wal_rotations_total` | counter | `instance_id` | Segment rotations. |
| `bondy_oplog_wal_retention_deleted_segments_total` | counter | `instance_id` | Segments deleted by retention sweeps. |
| `bondy_oplog_wal_retention_freed_bytes_total` | counter | `instance_id` | Bytes freed by retention sweeps. |
| `bondy_oplog_wal_recoveries_total` | counter | `instance_id` | Recovery scans on open. |
| `bondy_oplog_wal_recovery_truncated_bytes_total` | counter | `instance_id` | Bytes truncated by recovery. |
| `bondy_oplog_wal_full_total` | counter | `instance_id`, `reason` | Hard-backpressure activations. |
| `bondy_oplog_wal_codec_ops_total` | counter | `instance_id`, `op`, `algorithm` | Codec operations. |
| `bondy_oplog_wal_codec_input_bytes_total` | counter | `instance_id`, `op`, `algorithm` | Codec input bytes. |
| `bondy_oplog_wal_codec_output_bytes_total` | counter | `instance_id`, `op`, `algorithm` | Codec output bytes. |
| `bondy_oplog_wal_scrub_runs_total` | counter | `instance_id` | Scrubber runs. |
| `bondy_oplog_wal_scrub_frames_checked_total` | counter | `instance_id` | Frames checked by the scrubber. |
| `bondy_oplog_wal_scrub_corruption_total` | counter | `instance_id`, `kind` | Corrupt frames found by the scrubber. |
| `bondy_oplog_wal_size_bytes` | gauge | `instance_id` | Total bytes across live segments. |
| `bondy_oplog_wal_live_segments` | gauge | `instance_id` | Live segments. |
| `bondy_oplog_wal_pending_fsync_bytes` | gauge | `instance_id` | Bytes appended but not yet fsynced. |
| `bondy_oplog_wal_waiters` | gauge | `instance_id` | Callers blocked awaiting durability. |
| `bondy_oplog_wal_head_lag_milliseconds` | gauge | `instance_id` | Age of the newest unfsynced append. |
| `bondy_oplog_wal_consumer_lag_bytes` | gauge | `instance_id` | Bytes appended but not yet committed by the applier: the drain backlog. |
| `bondy_oplog_wal_backpressure` | gauge | `instance_id` | `1` while the WAL is in hard backpressure. |

## Storage: applier and instances

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_oplog_applier_batch_items_total` | counter | `instance_id`, `stage` | Items processed per pipeline stage. |
| `bondy_oplog_applier_batch_duration_microseconds` | histogram | `stage` | Stage duration per batch. |
| `bondy_oplog_applier_applied_total` | counter | `instance_id` | Events applied. |
| `bondy_oplog_applier_rejected_total` | counter | `instance_id` | Events rejected. |
| `bondy_oplog_applier_published_total` | counter | `instance_id` | Apply-path notifications published. |
| `bondy_oplog_applier_publish_skipped_total` | counter | `instance_id` | Apply-path notifications skipped. |
| `bondy_oplog_applier_faults_total` | counter | `instance_id`, `kind` | Context regression and verify-failure signals. |
| `bondy_oplog_applier_sweep_cells_total` | counter | `instance_id`, `result` | Stable-cell sweep results. |
| `bondy_oplog_applier_origins_reaped_total` | counter | `instance_id` | Origins reaped from cell contexts. |
| `bondy_oplog_applier_replayed_cells_total` | counter | `instance_id`, `outcome` | Cells applied by projection replay. |
| `bondy_oplog_applier_validator_refreshes_total` | counter | `outcome` | Validator refresh attempts. |
| `bondy_oplog_instance_appends_total` | counter | `instance_id` | Local appends accepted. |
| `bondy_oplog_instance_backpressure_total` | counter | `instance_id` | Appends rejected by instance backpressure. |
| `bondy_oplog_instance_mst_install_items_total` | counter | `instance_id` | Events installed into the MST. |
| `bondy_oplog_instance_mst_install_duration_microseconds` | histogram | — | MST batch install duration. |
| `bondy_oplog_remote_appends_total` | counter | `instance_id`, `outcome` | Replicated append outcomes. |
| `bondy_oplog_apply_events_total` | counter | `instance_id` | Locally applied events installed into instance state. |
| `bondy_oplog_overlay_backpressure_drops_total` | counter | `instance_id` | Overlay writes dropped by backpressure. |
| `bondy_oplog_write_readable_latency_microseconds` | gauge | `instance_id`, `quantile` | Write-to-readable latency, rolling-window quantiles. |
| `bondy_oplog_instances` | gauge | `lifecycle` | Instances per bootstrap lifecycle state. |
| `bondy_oplog_instance_lifecycle_code` | gauge | `instance_id` | `0` starting, `1` pre_bootstrap, `2` live. |
| `bondy_oplog_instance_live_size` | gauge | `instance_id` | Live (unapplied overlay) size. |

## Storage: frontier, prefix closure and sequences

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_oplog_instance_frontier_hash` | gauge | `instance_id` | Hash (`erlang:phash2/1`) of the applied-frontier version vector. Compare it across nodes to check that an instance has converged. |
| `bondy_oplog_instance_frontier_origins` | gauge | `instance_id` | Origins in the applied frontier. |
| `bondy_oplog_instance_frontier_seq_total` | gauge | `instance_id` | Sum of per-origin maximum sequence numbers in the applied frontier. |
| `bondy_oplog_instance_frontier_holes` | gauge | `instance_id` | Per-origin contiguity holes the instance carries. |
| `bondy_oplog_instance_frontier_pending_seqs` | gauge | `instance_id` | Sequence numbers folded above a hole and not yet claimed. |
| `bondy_oplog_prefix_holes_total` | counter | `instance_id` | Contiguity gaps that reached a projection fold. |
| `bondy_oplog_events_held_total` | counter | `instance_id` | Remote events a replay excluded from the fold to keep per-origin prefix closure. See "Causal hold" in [Log messages](log_messages.md). |
| `bondy_oplog_doored_events_total` | counter | `instance_id`, `action` | Never-applied peer events at or below the local watermark, folded inline or held for replay. |
| `bondy_oplog_seqs_burned_total` | counter | `instance_id` | Sequence numbers a rejected WAL batch could not return to the counter. |
| `bondy_oplog_seqs_filled_total` | counter | `instance_id` | Burned sequence numbers backfilled with no-op events. |

## Storage: compaction, reclamation and scheduling

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_oplog_compactions_total` | counter | `instance_id` | MST compactions completed. |
| `bondy_oplog_compaction_duration_microseconds` | histogram | — | Compaction duration. |
| `bondy_oplog_compaction_holds_total` | counter | `instance_id` | Cycles whose truncation point was capped below a key the projection has not applied. |
| `bondy_oplog_reclamation_stalled_total` | counter | `instance_id`, `reason` | Reclamation attempts that stalled. |
| `bondy_oplog_gc_scheduler_events_total` | counter | `scheduler`, `event` | Compaction and reclamation scheduler activity. See below. |
| `bondy_oplog_gc_scheduler_inflight` | gauge | — | In-flight compaction runs of `bondy_oplog_gc_scheduler`. Reclamation runs are not counted. |
| `bondy_oplog_retirements_total` | counter | `outcome` | Origin retirement outcomes: `completed`, `skipped`. |

`bondy_oplog_gc_scheduler_events_total` has two schedulers, named by the
`scheduler` label: `bondy_oplog_gc_scheduler` runs compaction and
`bondy_oplog_reclaim_scheduler` runs reclamation. `event` is `tick`, `skipped`,
or `trigger_` followed by the outcome of one run: `trigger_ok`, or the reason
the run stalled, such as `trigger_unconfirmed` or `trigger_no_members`. The
stall reasons are the ones the "GC stalled" warning names; see
[Log messages](log_messages.md#gc-stalled).

Each `event` value therefore has one series per scheduler. A query that selects
by `event` and does not aggregate by `scheduler`, for example
`rate(bondy_oplog_gc_scheduler_events_total{event="trigger_no_members"}[5m])`,
returns one series for each scheduler that reported it. Aggregate with
`sum without (scheduler) (...)` to count across both, or select one scheduler.

## Storage: anti-entropy and bootstrap

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_oplog_aae_enabled` | gauge | — | `1` when anti-entropy is enabled on this node. |
| `bondy_oplog_sync_sessions_total` | counter | `instance_id`, `peer`, `outcome` | Sync sessions. |
| `bondy_oplog_sync_duration_microseconds` | histogram | `outcome` | Sync session duration. |
| `bondy_oplog_frontier_gap_verdicts_total` | counter | `instance_id`, `peer` | Completed sync rounds that left the peer's applied frontier ahead of ours. |
| `bondy_oplog_rebootstraps_scheduled_total` | counter | `instance_id`, `peer` | Catalogue re-bootstraps scheduled. |
| `bondy_oplog_bootstrap_sessions_total` | counter | `instance_id`, `peer`, `outcome` | Catalogue bootstrap sessions. |
| `bondy_oplog_bootstrap_cells_total` | counter | `instance_id`, `result` | Catalogue bootstrap cell outcomes. |
| `bondy_oplog_bootstrap_duration_microseconds` | histogram | `outcome` | Catalogue bootstrap session duration. |
| `bondy_oplog_mst_rebuilt_total` | counter | `instance_id`, `reason` | Compactions that truncated a tree whose own root lost pages, once every member covered this replica's applied frontier, and left a tree with every page. `reason` is `unservable_root`. See "MST rebuilt" in [Log messages](log_messages.md#mst-rebuilt). |
| `bondy_oplog_sync_scheduler_events_total` | counter | `event` | Sync scheduler activity. |
| `bondy_oplog_sync_scheduler_enabled` | gauge | — | `1` when the sync scheduler is enabled. |
| `bondy_oplog_sync_scheduler_interval_milliseconds` | gauge | — | Sync scheduler tick interval. |
| `bondy_oplog_sync_scheduler_load` | gauge | — | Run-queue load sample. |
| `bondy_oplog_sync_scheduler_yielding` | gauge | — | `1` while the scheduler yields to load. |
| `bondy_oplog_sync_scheduler_inflight` | gauge | `kind` | In-flight sync sessions: `total`, `bootstrap`. |
| `bondy_oplog_peer_last_sync_age_seconds` | gauge | `instance_id`, `peer` | Seconds since the last completed sync with a peer. |
| `bondy_oplog_peer_last_seen_age_seconds` | gauge | `instance_id`, `peer` | Seconds since a peer was last seen. |
| `bondy_oplog_peer_state_entries` | gauge | — | Rows in the peer sync-state table. |
| `bondy_oplog_sync_oversized_item_total` | counter | `kind` | Sync items (`page`, `cell`) skipped because one item exceeds the sync response ceiling. |
| `bondy_oplog_sync_oversized_item_last_bytes` | gauge | `kind` | Size of the most recently skipped oversized item. |
| `bondy_aae_merge_conflicts_total` | counter | `table` | Remote merges that replaced a differing local value of an authorization cell. |

## Storage: substrate reads and secondary indexes

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_oplog_core_reads_total` | counter | `namespace` | Point reads. |
| `bondy_oplog_core_cache_hits_total` | counter | `namespace` | Point-read cache hits. |
| `bondy_oplog_core_cache_misses_total` | counter | `namespace` | Point-read cache misses. |
| `bondy_oplog_core_ranges_total` | counter | `namespace` | Range reads. |
| `bondy_oplog_core_range_pages_total` | counter | `namespace` | Projection pages read by range reads. |
| `bondy_oplog_core_cache_hit_ratio` | gauge | `namespace` | Cache hit ratio over the last refresh interval. |
| `bondy_oplog_core_read_rps` | gauge | `namespace` | Point reads per second over the last refresh interval. |
| `bondy_oplog_core_range_rps` | gauge | `namespace` | Range reads per second over the last refresh interval. |
| `bondy_oplog_core_subscribers` | gauge | `namespace` | Substrate pub/sub subscribers. |
| `bondy_oplog_core_freshness_lag_max_milliseconds` | gauge | `namespace` | Maximum anti-entropy freshness lag across the namespace's primary shards: the shards the authentication freshness fence evaluates. |
| `bondy_oplog_core_ae_lag_milliseconds` | gauge | `namespace`, `index`, `shard` | Per-shard anti-entropy freshness lag. |
| `bondy_oplog_secondary_flush_ops_total` | counter | `namespace`, `index` | Secondary index operations flushed. |
| `bondy_oplog_secondary_flush_duration_microseconds` | histogram | — | Secondary index flush duration. |
| `bondy_oplog_secondary_saturated_dropped_total` | counter | `namespace`, `index` | Secondary index operations dropped because the writer was saturated. |
| `bondy_oplog_secondary_rebuilds_total` | counter | `namespace`, `index` | Secondary index rebuilds. |

Every range read reads at least one page. It reads another page when a full
page held cleared cells and so returned fewer live rows than the read's limit.
`bondy_oplog_core_range_pages_total` above `bondy_oplog_core_ranges_total` is
therefore the pages read past cleared cells.

## Storage: Merkle search trees

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_mst_merges_total` | counter | `result` | MST merges. |
| `bondy_mst_merge_duration_microseconds` | histogram | — | Merge duration. |
| `bondy_mst_merges_abandoned_total` | counter | — | Exchange merges abandoned. |
| `bondy_mst_gc_runs_total` | counter | `result` | Store GC runs. |
| `bondy_mst_gc_aborted_total` | counter | `instance_id`, `classification` | Page GCs aborted because the current root was missing pages: `deleted`, `tombstoned`, `transient`. |
| `bondy_mst_broadcasts_total` | counter | `direction` | Gossip messages. |
| `bondy_mst_broadcast_bytes_total` | counter | `direction` | Gossip bytes. |
| `bondy_mst_page_store_ops_total` | counter | `instance_id`, `op` | Page store operations. |
| `bondy_mst_page_store_bytes_total` | counter | `instance_id`, `op` | Page store bytes read and written. |
| `bondy_mst_seals_total` | counter | `instance_id`, `kind` | Pack seals. |
| `bondy_mst_seal_records_total` | counter | `instance_id`, `kind` | Records sealed into packs. |
| `bondy_mst_seal_bytes_total` | counter | `instance_id`, `kind` | Bytes sealed into packs. |
| `bondy_mst_seal_duration_microseconds` | histogram | `kind` | Pack seal duration. |
| `bondy_mst_page_store_gc_runs_total` | counter | `instance_id`, `reason` | Page store GC runs. |
| `bondy_mst_page_store_gc_pages_dropped_total` | counter | `instance_id` | Pages dropped by page store GC. |
| `bondy_mst_page_store_gc_packs_retired_total` | counter | `instance_id` | Packs retired by page store GC. |
| `bondy_mst_page_store_gc_freed_bytes_total` | counter | `instance_id` | Bytes freed by page store GC. |
| `bondy_mst_page_store_recoveries_total` | counter | `instance_id`, `result` | Incoming-pack recoveries. |
| `bondy_mst_pack_idx_rebuilds_total` | counter | `instance_id`, `result` | Sealed-pack index rebuilds. |

## Storage: leveled

Every family carries `namespace` and `shard`, one series per leveled store.

| Family | Type | Extra labels | Meaning |
| --- | --- | --- | --- |
| `bondy_leveled_ledger_cache_size` | gauge | — | Ledger (write) cache entries. |
| `bondy_leveled_penciller_cache_size` | gauge | — | Penciller in-memory (L0) cache size. |
| `bondy_leveled_active_journal_files` | gauge | — | Active journal files. |
| `bondy_leveled_journal_compaction_score` | gauge | — | Last journal compaction score. |
| `bondy_leveled_penciller_backlog` | gauge | — | Penciller work backlog. |
| `bondy_leveled_penciller_pending` | gauge | `kind` | `1` while an L0 flush (`l0`) or manifest change (`manifest`) is pending. |
| `bondy_leveled_level_files` | gauge | `level` | SST files per LSM level. |
| `bondy_leveled_fetches` | gauge | `level` | Sampled fetches by resolution level. |
| `bondy_leveled_mean_op_time_microseconds` | gauge | `op` | Mean sampled time of `get`, `head`, `put_ink`, `put_mem`, `put_prep`. |

## Node health and alarms

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_node_ready` | gauge | — | `1` when the node reports ready: the same `bondy_router_app:is_ready/0` the `/ready` probe serves. |
| `bondy_alarms` | gauge | — | Active alarms on the node. |
| `bondy_alarm_active` | gauge | `alarm_id` | `1` per active alarm. |
| `bondy_process_message_queue_len` | gauge | `name` | Mailbox depth of critical singleton processes. |

## Cluster

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_cluster_members` | gauge | — | Size of the Partisan membership view. |
| `bondy_cluster_connected_peers` | gauge | — | Connected Partisan peers. |
| `bondy_cluster_all_members_connected` | gauge | — | `1` when every member of the view is reachable. |
| `bondy_cluster_peer_connected` | gauge | `peer`, `member`, `self` | `1` connected, `0` not. |
| `bondy_cluster_connections` | gauge | `peer` | Partisan connections to each peer. |
| `bondy_cluster_channel_connections` | gauge | `peer`, `channel` | Partisan connections per peer and channel, read at scrape time. Below `bondy_cluster_channel_connections_target` the channel is under-provisioned. |
| `bondy_cluster_channel_connections_target` | gauge | `peer`, `channel` | Configured target connection count for a peer and channel. |
| `bondy_cluster_peer_rtt_milliseconds` | histogram | `peer`, `channel`, `side` | Heartbeat round-trip time. |
| `bondy_cluster_peer_send_pending_bytes` | gauge | `peer`, `channel`, `side` | Bytes queued but not yet flushed to the peer socket. |
| `bondy_cluster_connect_latency_milliseconds` | histogram | `result` | Outbound connection attempt latency, TLS handshake included. |
| `bondy_cluster_tls_handshake_milliseconds` | histogram | `result` | Inbound TLS handshake latency. |
| `bondy_cluster_connection_up_total` | counter | `peer`, `channel` | Connections established. |
| `bondy_cluster_connection_down_total` | counter | `peer`, `channel`, `reason` | Connections torn down. |
| `bondy_cluster_membership_changes_total` | counter | `direction` | Membership changes: `added`, `removed`. |
| `bondy_cluster_membership_size` | gauge | — | Member count. |

## Router: WAMP messages and sessions

The message families carry `node`, `realm_type`, `protocol`, `transport`,
`frame_type` and `encoding`.

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_wamp_messages_total` | counter | message labels | WAMP messages routed. |
| `bondy_wamp_message_bytes` | histogram | message labels | Encoded frame size of messages sent and received. |
| `bondy_wamp_<type>_messages_total` | counter | message labels | Messages of one type, for each of `abort`, `authenticate`, `call`, `cancel`, `challenge`, `error`, `event`, `goodbye`, `hello`, `interrupt`, `invocation`, `publish`, `published`, `register`, `registered`, `result`, `subscribe`, `subscribed`, `unregister`, `unregistered`, `unsubscribe`, `unsubscribed`, `welcome`, `yield`. `call` and `register` add `procedure_uri`, `publish` and `subscribe` add `topic_uri`, `error` adds `error_uri`. |
| `bondy_wamp_dropped_total` | counter | `reason`, `family` | Messages or events Bondy declined to deliver. |
| `bondy_wamp_hello_duration_microseconds` | histogram | `node` | In-process time handling a HELLO. |
| `bondy_wamp_egress_queue_depth` | histogram | `node`, `transport` | Connection mailbox depth when it dequeued an outbound message. |
| `bondy_wamp_egress_service_microseconds` | histogram | `node`, `transport` | Time a connection spent handling one outbound message. |
| `bondy_sockets_total` | gauge | `node`, `protocol`, `transport` | Open sockets. |
| `bondy_sockets_opened_total` | counter | `node`, `protocol`, `transport` | Sockets opened. |
| `bondy_sockets_closed_total` | counter | `node`, `protocol`, `transport` | Sockets closed. |
| `bondy_socket_errors_total` | counter | `node`, `protocol`, `transport` | Socket errors. |
| `bondy_socket_duration_seconds` | histogram | `node`, `protocol`, `transport` | Socket lifetime, in seconds. |
| `bondy_ping_rtt_milliseconds` | histogram | `node`, `protocol`, `transport` | Round trip of router-initiated transport pings. |
| `bondy_sessions_total` | gauge | `node`, `realm` | Open sessions. |
| `bondy_sessions_opened_total` | counter | `node`, `realm` | Sessions opened. |
| `bondy_sessions_closed_total` | counter | `node`, `realm`, `reason` | Sessions closed, by WAMP close reason. |
| `bondy_session_duration_seconds` | histogram | `node`, `realm` | Session lifetime, in seconds. |
| `bondy_session_manager_open_queue_microseconds` | histogram | `node` | Time a session open waited in a session manager worker's mailbox. |
| `bondy_session_manager_open_service_microseconds` | histogram | `node` | Time a session manager worker spent serving an open. |
| `bondy_session_manager_cleanup_microseconds` | histogram | `node`, `kind` | Time a session manager worker spent on teardown. |
| `bondy_realm_events_total` | counter | `node`, `realm`, `action` | Realm lifecycle events. |
| `bondy_user_events_total` | counter | `node`, `realm`, `action` | User lifecycle events. |

`bondy_socket_duration_seconds` and `bondy_session_duration_seconds` record
whole seconds: the emitters compute the duration with
`erlang:monotonic_time(second)` (sockets) and `erlang:system_time(second)`
(sessions). A connection shorter than one second records `0`.

## Router: RPC

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_wamp_call_latency_milliseconds` | histogram | `node`, `procedure_uri` | Time from the dealer processing a CALL to the first response, RESULT or ERROR. Includes router and callee time. |
| `bondy_wamp_invocation_latency_milliseconds` | histogram | `node`, `procedure_uri` | Time from INVOCATION to YIELD or ERROR: callee execution plus transport. |
| `bondy_rpc_promises_inflight` | gauge | — | Calls and invocations awaiting a response. |
| `bondy_rpc_inflight_invocations` | gauge | `procedure_uri` | Calls awaiting a response, per procedure. |
| `bondy_rpc_promise_timeouts_total` | counter | `type` | Promises evicted on expiry; the caller received a WAMP timeout error. |
| `bondy_rpc_rib_retries_total` | counter | `outcome` | Retries of a cluster CALL after an owner-side completion miss: `node`, `local`, `exhausted`. |
| `bondy_rpc_rib_completions_total` | counter | `outcome` | Owner-side completions of node-addressed cluster CALLs: `ok`, `miss`. |

The difference between `bondy_wamp_call_latency_milliseconds` and
`bondy_wamp_invocation_latency_milliseconds` for a procedure is the time spent
in the router.

## Router: registry and pub/sub

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_registry_events_total` | counter | `node`, `realm`, `type`, `action` | Registration and subscription lifecycle events. |
| `bondy_registry_size` | gauge | — | Registry substrate size. |
| `bondy_registry_memory` | gauge | — | Registry substrate memory. |
| `bondy_registry_rib_members` | gauge | — | Local registry entries feeding this node's routing summaries. |
| `bondy_registry_rib_stub_cells` | gauge | `type` | Remote routing-summary stubs held by this node. |
| `bondy_registry_rib_divergences` | gauge | — | Keys where the routing summaries disagreed with the registry at the last consistency sweep. |
| `bondy_registry_projection_miss_total` | counter | — | Index entries whose backing record was gone when resolved. |
| `bondy_registry_ptrie_cas_retries_total` | counter | `node` | Pattern-index write rounds retried after losing a root compare-and-swap. |
| `bondy_registry_ptrie_cas_exhausted_total` | counter | `node` | Pattern-index writes that exhausted their retry budget and failed. |
| `bondy_broker_publish_match_microseconds` | histogram | `node` | Time a PUBLISH spent finding matching subscriptions. |
| `bondy_broker_publish_fanout_microseconds` | histogram | `node` | Time a PUBLISH spent delivering to local subscribers and peer nodes. |
| `bondy_router_flow_queue_microseconds` | histogram | `node`, `family` | Time a task waited in a flow pool worker's mailbox (`router` tasks only). |
| `bondy_router_flow_service_microseconds` | histogram | `node`, `family` | Flow pool task execution time: `router`, `relay`. |
| `bondy_router_flow_queue_depth` | histogram | `node`, `family` | Flow pool worker mailbox depth at dequeue, recorded for relay ingress. |

## Router: listeners, load regulation and HTTP

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_listener_connections` | gauge | `listener` | Active connections. |
| `bondy_listener_max_connections` | gauge | `listener` | Connection limit. |
| `bondy_listener_accepts_total` | counter | `listener` | Connections accepted since start. |
| `bondy_listener_terminates_total` | counter | `listener` | Connections terminated since start. |
| `bondy_rate_limited_total` | counter | `class`, `scope` | Inbound requests denied by the rate limiter. |
| `bondy_rate_limiter_buckets` | gauge | `table` | Live rate-limiter entries. |
| `bondy_jobs_queue_depth` | gauge | `shard` | Queued jobs per load-regulation pool shard. |
| `bondy_jobs_enqueued_total` | counter | `shard` | Jobs enqueued per shard since start. |
| `bondy_oidc_flows_inflight` | gauge | — | OIDC login flows awaiting the callback. |
| `bondy_http_requests_total` | counter | `route`, `method`, `reason`, `status_class` | HTTP requests. |
| `bondy_http_spawned_processes_total` | counter | `route`, `method`, `reason`, `status_class` | HTTP handler processes spawned. |
| `bondy_http_errors_total` | counter | `method`, `reason`, `error` | HTTP request errors. |
| `bondy_http_early_errors_total` | counter | — | HTTP early errors. |
| `bondy_http_request_duration_microseconds` | histogram | `route`, `method`, `reason`, `status_class` | HTTP request duration. |
| `bondy_http_receive_body_duration_microseconds` | histogram | `route`, `method`, `reason`, `status_class` | Request body receive duration. |
| `bondy_protocol_upgrades_total` | counter | — | HTTP protocol upgrades. |

## HTTP connector

Every family carries `service`. See [HTTP connector](../configuration/http_connector.md).

| Family | Type | Extra labels | Meaning |
| --- | --- | --- | --- |
| `bondy_http_connector_requests_total` | counter | `procedure_uri`, `outcome` | Forwarded calls: `ok`, `redirect`, `client_error`, `server_error`, `unknown`. |
| `bondy_http_connector_request_duration_milliseconds` | histogram | `procedure_uri` | WAMP invocation to WAMP response. |
| `bondy_http_connector_retries_total` | counter | `procedure_uri` | Upstream retry attempts. |
| `bondy_http_connector_token_cache_total` | counter | `result` | Token cache lookups: `hit`, `miss`. |
| `bondy_http_connector_token_fetch_total` | counter | `outcome` | Token requests to the identity provider. |
| `bondy_http_connector_token_fetch_duration_milliseconds` | histogram | — | Token request duration. |
| `bondy_http_connector_token_refresh_total` | counter | `outcome` | Token refreshes. |
| `bondy_http_connector_secret_resolution_total` | counter | `outcome` | External secret resolution attempts. |
| `bondy_http_connector_service_ready` | gauge | — | `1` when the service's secrets are resolved; present only for a service with a secrets provider. |
| `bondy_http_connector_pool_up` | gauge | — | `1` while the upstream pool is up, `0` while down. |
| `bondy_http_connector_pool_status_changes_total` | counter | `status` | Pool up and down transitions. |
| `bondy_http_connector_liveness_probes_total` | counter | `outcome` | Periodic liveness probes: `ok`, `error`. |
| `bondy_http_connector_liveness_probe_duration_milliseconds` | histogram | — | Liveness probe duration. |

## Mail

Every family carries `relay`.

| Family | Type | Extra labels | Meaning |
| --- | --- | --- | --- |
| `bondy_mail_accepted_total` | counter | `surface` | Messages validated, authorized and queued: `rpc`, `bridge`. |
| `bondy_mail_sent_total` | counter | — | Messages a relay accepted. |
| `bondy_mail_failed_total` | counter | `nature`, `reason_class` | Messages that will not be delivered. |
| `bondy_mail_retried_total` | counter | `reason_class` | Delivery retries. |
| `bondy_mail_dead_letter_total` | counter | `reason_class` | Failed messages with no caller waiting for the result. |
| `bondy_mail_rate_limited_total` | counter | — | Messages refused by the relay's rate limiter. |
| `bondy_mail_rejected_total` | counter | `reason` | Messages refused before delivery was attempted. |
| `bondy_mail_send_duration_milliseconds` | histogram | — | SMTP conversation duration, retries included, queueing excluded. |
| `bondy_mail_queue_wait_milliseconds` | histogram | — | Time queued in front of a relay worker. |
| `bondy_mail_queue_depth` | gauge | — | Messages queued and not yet taken by a worker. |
| `bondy_mail_relay_up` | gauge | — | `1` while recent deliveries succeed. |

## MCP gateway

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_mcp_session_opened_total` | counter | `node`, `realm`, `listener` | Sessions created by `initialize`. |
| `bondy_mcp_session_closed_total` | counter | `node`, `realm`, `listener`, `reason` | Session terminations. |
| `bondy_mcp_active_sessions` | gauge | `node`, `realm`, `listener` | Open sessions. |
| `bondy_mcp_tool_calls_total` | counter | `node`, `realm`, `listener`, `name`, `status` | Dispatched `tools/call` requests. |
| `bondy_mcp_tool_call_duration_microseconds` | histogram | `node`, `realm`, `status` | `tools/call` WAMP call time. |
| `bondy_mcp_resource_reads_total` | counter | `node`, `realm`, `listener`, `name`, `status` | Dispatched `resources/read` requests. |
| `bondy_mcp_resource_read_duration_microseconds` | histogram | `node`, `realm`, `status` | `resources/read` WAMP call time. |
| `bondy_mcp_resource_subscribes_total` | counter | `node`, `realm`, `name` | Resource subscriptions honoured. |
| `bondy_mcp_notifications_emitted_total` | counter | `node`, `realm`, `type` | Client notifications produced. |
| `bondy_mcp_rbac_denied_total` | counter | `node`, `realm`, `surface` | Requests or list entries RBAC hid or refused. |
| `bondy_mcp_version_refused_total` | counter | `node`, `listener`, `version` | Requests refused for an unsupported protocol version. |
| `bondy_mcp_request_duration_microseconds` | histogram | `node`, `realm`, `method` | Gateway-side request handling time. |
| `bondy_mcp_inflight_calls` | gauge | `node`, `realm`, `listener` | WAMP calls in flight for MCP requests. |
| `bondy_mcp_manifest_rebuilds_total` | counter | `node`, `realm`, `trigger` | Manifest rebuilds. |
| `bondy_mcp_manifest_rebuild_duration_microseconds` | histogram | `node`, `realm` | Manifest rebuild time. |
| `bondy_mcp_manifest_entries` | gauge | `node`, `realm`, `kind` | Entries in the served manifest. |
| `bondy_mcp_manifest_collisions_total` | counter | `node`, `realm`, `kind` | Name collisions a rebuild reported. |
| `bondy_mcp_upstream_calls_total` | counter | `node`, `upstream`, `status` | Projected upstream tool calls. |
| `bondy_mcp_upstream_call_duration_microseconds` | histogram | `node`, `upstream` | Upstream tool-call round trip. |
| `bondy_mcp_upstream_drift_blocked_total` | counter | `node`, `upstream` | Upstream tools blocked by the definition pin. |

With `mcp.metrics.label_by_name = on`, the two duration histograms also carry
`name`.

## BEAM

| Family | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `bondy_sysmon_events_total` | counter | `type` | BEAM system-monitor events received, such as `long_gc`, `long_schedule`, `large_heap`, `busy_port`, `busy_dist_port`. Each event is also logged at notice level as "System event received." |
| `erlang_vm_memory_*` | — | — | VM memory, from `prometheus_vm_memory_collector`. |
| `erlang_vm_statistics_*` | — | — | VM statistics (reductions, context switches, run queues, I/O), from `prometheus_vm_statistics_collector`. |
| `erlang_vm_*` | — | — | VM system information (process, port, atom and ETS counts and limits, schedulers), from `prometheus_vm_system_info_collector`. |
| `erlang_vm_msacc_*_seconds_total` | counter | — | Microstate accounting: time the VM's threads spent in each state (`aux`, `check_io`, `emulator`, `gc`, `other`, `port`, `sleep`, and more on a VM built with extra microstate accounting). Bondy turns microstate accounting on at boot. |
| `erlang_vm_dist_*` | — | — | Erlang distribution sockets, from `prometheus_vm_dist_collector`. |
| `telemetry_scrape_duration_seconds`, `telemetry_scrape_size_bytes` | summary | `registry`, `content_type` | Cost of serving `/metrics`. |
| `telemetry_scrape_encoded_size_bytes` | summary | `registry`, `content_type`, `encoding` | Encoded size of a `/metrics` response. |

The `erlang_vm_*` families are defined by the `prometheus` library; its
collector modules list each family.

## See also

- [Log messages](log_messages.md): the log records that accompany several of
  these families.
- [Reclamation configuration reference](../configuration/reclamation_options.md):
  the settings behind the compaction and reclamation families.
- [`monitoring/README.md`](../../../monitoring/README.md): the bundled
  Prometheus and Grafana dashboards.
