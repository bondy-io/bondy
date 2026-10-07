# bondy_oplog

Operation-log write and replication framework, read substrate and
operation-based CRDT catalogue for Bondy. It stores replicated events in a
Merkle Search Tree from the `bondy_mst` application.

`bondy_oplog` is the lower of the two database layers. It owns:

- the **write and replication framework**: instances, the WAL facade
  (`bondy_oplog_wal`, a `bondy_log` writer opened with the oplog adapter
  `bondy_oplog_log_adapter`), the in-memory WAL for fused instances, the
  applier, compaction, anti-entropy sync, bootstrap and peer state;
- the **operation-based CRDT catalogue** (`bondy_oplog_crdt_*`): counters,
  registers, sets, flags, maps, the fixed-schema struct and the
  secondary-index entry type;
- the **`bondy_oplog_core_*` read substrate**: the registry of per-shard read
  handles keyed by `(NS, Index, Shard)`, the read API, the change-notification
  dispatcher, events and metrics. The `bondy_db` facade reads through it.

Within the storage stack it depends on `bondy_log` (the segmented log core
under the WAL) and on `bondy_mst`. It also depends on `bondy_cluster` for
cluster membership, on Partisan for the sync transport that Bondy configures
(`bondy_oplog_transport_partisan`), and on `telemetry` and `bondy_metrics` for
instrumentation. The `leveled`-backed storage topologies and the table API are
in the `bondy_db` application, which depends on this one.
