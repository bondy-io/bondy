# bondy_oplog

Operation-log write/replication framework and op-based CRDT catalogue for
Bondy, built on the [`bondy_mst`](https://github.com/bondy-io/bondy_mst)
Merkle-Search-Tree library.

`bondy_oplog` is the lower of the two extracted database layers. It owns:

- the **write/replication framework** — WAL, applier, instances, compaction,
  anti-entropy sync, bootstrap, peer state;
- the **op-based CRDT catalogue** (`bondy_oplog_crdt_*`) — counters, registers,
  sets, flags, maps and the secondary-index entry type;
- the **`bondy_oplog_core_*` substrate** — the per-`(NS, Index, Shard)` read
  registry, dispatcher, events and metrics that the framework and the
  `bondy_db` facade both read through.

Within the storage stack its only dependency is `bondy_mst` (it also uses
`partisan` for the cluster sync transport and `telemetry` for instrumentation).
The `leveled`-backed storage topologies and the consumer-facing table API live
in the `bondy_db` application, which depends on this one.
