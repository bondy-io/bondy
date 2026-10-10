# Database configuration reference

The configuration surface of `bondy_db`: how the two databases are sharded,
how the durable write-ahead log reaches the disk, how anti-entropy (AAE)
replicates, the authentication freshness fence that AAE feeds, and the
thresholds of the storage alarms. Each option is listed with its `bondy.conf`
key, the application-environment key it maps to, its type and its default.
Values are read at node start.

`bondy_db` has two databases. `main` is durable and lives under
`platform_data_dir`. `registry` is ephemeral: it is held in memory and rebuilt
from peers after a restart.

> **Related:** [Reclamation configuration reference](reclamation_options.md) ·
> [Clustering](clustering.md) ·
> [Storage topology](../architecture/db_topology.md)

## Sharding and topology

### `db.main.shard_count` (`bondy_db.databases`)

Integer, default `16`.

The number of shards of the `main` database. The value is recorded in the
on-disk topology manifest at first provision; see
`db.main.on_topology_mismatch` for what a later change does.

### `db.main.partition_strategy` (`bondy_db.databases`)

`aggregate | realm | entity`, default `aggregate`.

How a `(realm, key)` write maps to a `main` shard, which also sets which
records are written in one atomic batch. `aggregate` places a subject's
records on one shard and spreads subjects over every shard. `realm` places a
whole realm, or realm prefix, on one shard. `entity` hashes each record on its
own. Recorded in the manifest. The strategies are compared in
[Storage topology](../architecture/db_topology.md).

### `db.main.realm_prefix_depth` (`bondy_db.databases`)

Integer, default `1`.

Used only with `db.main.partition_strategy = realm`: the number of leading
dot-separated realm URI components that share a shard. Recorded in the
manifest.

### `db.main.on_topology_mismatch` (`bondy_db.databases`)

`warn | stop`, default `warn`.

What a node does when the configured topology differs from the manifest on
disk. The check compares, among other values, the partition strategy, shard
count, realm prefix depth, the per-table attributes, and one sample output of
the runtime's placement hash function. A runtime whose hash function places
keys differently is therefore reported as a mismatch too
(`bondy_db_manifest_test`: `hash_probe_divergence_detected`).

- `warn` logs the diverging keys and boots on the **on-disk** topology. The
  configuration you changed is not in effect
  (`bondy_db_manifest_test`: `warn_mismatch_returns_on_disk_effective`).
- `stop` logs the diverging keys at error level, and the node does not
  start.

Changing the topology of a populated node means export, empty the data
directory, and import. This option itself is not recorded in the manifest and
can be changed at any time.

### `db.registry.shard_count` (`bondy_db.databases`)

Integer, default `16`.

The number of shards of the `registry` database. `registry` has no manifest;
the value applies at each start.

## Registry history retention

Registry history is bounded by compaction, which waits for every cluster
member (see [Convergence](../database/convergence.md#the-compaction-witness-rule-and-the-truncation-cap)).
While a member is down and has not been removed from the cluster, compaction
truncates nothing and the history of every `registry` shard grows in memory.
The two retention options are the only bound on that growth. Both are off by
default.

A retention bound truncates history that peers may not have received. A peer
that lags past the truncation point recovers through a catalogue
[re-bootstrap](../database/convergence.md#re-bootstrap), which transfers the
whole shard.

Retention applies only to `registry`. `main` history is never
retention-bounded.

### `db.registry.retention.max_age_ms` (`bondy_db.databases`)

Integer (milliseconds), default `0` (off).

When compaction truncates nothing, truncate the events older than this age
(`bondy_oplog_compaction_fused_test`: `retention_age_breach_truncates`).

### `db.registry.retention.max_events` (`bondy_db.databases`)

Integer, default `0` (off).

When compaction truncates nothing and a shard holds more than this many
events, truncate its whole applied history
(`bondy_oplog_compaction_fused_test`: `retention_size_breach_truncates`).
Checked on each compaction tick, independently of
`db.registry.retention.max_age_ms`.

## Write-ahead log

These options apply to the durable WAL of every `main` shard. The `registry`
WAL is in memory and does not use them.

### `db.wal.fsync_mode` (`bondy_oplog.wal_fsync_mode`)

`per_write | batched`, default `per_write`.

- `per_write` syncs every append before the append returns.
- `batched` returns from an append **before** the frame is synced. The frame
  is synced when the unsynced bytes reach `db.wal.batched_fsync_bytes`, or
  `db.wal.batched_fsync_interval` after the first unsynced append, whichever
  comes first. A power loss or operating-system crash in that window can
  lose the unsynced appends.

### `db.wal.batched_fsync_interval` (`bondy_oplog.wal_batched_fsync_interval_ms`)

Duration, default `50ms`. Used only with `batched`.

The longest time an appended frame stays unsynced.

### `db.wal.batched_fsync_bytes` (`bondy_oplog.wal_batched_fsync_bytes`)

Byte size, default `1MB`. Used only with `batched`.

The unsynced bytes at which the writer syncs.

### `db.wal.max_segment_bytes` (`bondy_oplog.wal_max_segment_bytes`)

Byte size, default `64MB`.

The writer starts a new segment when the next frame would take the current
one past this size. A frame larger than the limit is written whole, so a
segment can exceed it.

## Pack sealing

A durable shard's Merkle search tree accumulates pages in `incoming.pack` and
periodically rewrites them into a sealed pack.

### `db.pack_seal_mode` (`bondy_oplog.pack_seal_mode`)

`async | sync`, default `async`.

`async` rewrites the pack in a separate process, off the apply path. `sync`
rewrites it inline when a page write crosses the threshold, so that write
waits for the rewrite.

### `db.pack_auto_seal_bytes` (`bondy_oplog.pack_auto_seal_bytes`)

Byte size, default `2MB`.

The size of `incoming.pack` at which it is sealed.

## Anti-entropy

### `db.aae` (`bondy_oplog.aae_enabled`)

`on | off`, default `on`.

Whether shards replicate through anti-entropy. With `on` and
`cluster.enabled = on`, the sync scheduler takes its peers from the cluster
membership. With `off`, or with clustering disabled, no peer is wired and no
sync session runs.

### `db.aae.interval` (`bondy_oplog.sync_interval_ms`)

Duration, default `500ms`.

The interval between sync scheduler ticks. Each tick picks peers and starts
sync sessions.

### `db.aae.fanout` (`bondy_oplog.aae_fanout`)

Integer, default `3`.

The number of peers sampled from the cluster membership for a tick.

### `db.aae.live_sync` (`bondy_oplog.live_sync_adaptive`)

`on | off`, default `on`.

With `on`, a shard whose local tree has stopped changing syncs less often,
doubling its interval up to `db.aae.live_sync.max`, and returns to every tick
when its tree changes. With `off`, every shard syncs on every tick. Shards
that back the authentication fence always sync on every tick.

### `db.aae.live_sync.max` (`bondy_oplog.live_sync_max_ms`)

Duration, default `5s`.

The longest interval between syncs of a quiet shard under `db.aae.live_sync`.
Replication is pull-only, so this is also how long a write can take to reach
a quiet shard's peers.

### `db.aae.max_concurrency` (`bondy_oplog.aae_max_concurrency`)

Integer, default `3`.

The number of sync sessions that can run at once on this node. A shard that
backs the authentication fence starts its sessions even when the cap is
reached.

### `db.aae.max_pages_in_flight` (`bondy_oplog.aae_max_pages_in_flight`)

Integer, default `2048`.

The node-wide budget of tree pages that sync sessions hold in flight. Each
session pulls at most `max_pages_in_flight / max_concurrency` pages per round
(integer division, at least `1`). Raising `db.aae.max_concurrency` therefore
shrinks each session's batch and does not raise the budget. Sessions of the
shards that back the authentication fence bypass the concurrency cap, so each
of them adds one batch above the budget.

### `db.aae.load_adaptive` (`bondy_oplog.aae_load_adaptive`)

`on | off`, default `off`.

With `on`, while the node load signal is at or above
`db.aae.load_run_queue_threshold`, a tick skips bootstrap transfers and the
live syncs of shards that do not back the authentication fence. Sessions
already running are not stopped.

### `db.aae.load_run_queue_threshold` (`bondy_oplog.aae_load_run_queue_threshold`)

Float, default `2.0`.

The load at which `db.aae.load_adaptive` yields. The signal is the run queue
length divided by the online schedulers, smoothed across ticks.

## Storage alarm thresholds

These options set when two of the storage alarms in [Alarms](../router/alarms.md)
are raised. `0` disables the detector.

### `db.drain.stall_alarm` (`bondy_oplog.drain_stall_alarm_ms`)

Duration, default `1m`.

How long a shard's WAL drain can process frames without committing a new
position before the node raises `{bondy_oplog_drain_stalled, InstanceId}`.

### `db.frontier.hole_alarm` (`bondy_oplog.frontier_hole_alarm_ms`)

Duration, default `5m`.

How long a shard can carry a per-origin gap in its applied frontier before the
node raises `{bondy_oplog_frontier_hole, InstanceId}`. Short gaps occur in
normal operation, so the alarm measures the age of the gap. Keep the value well
above `db.aae.interval`. The gauge `bondy_oplog_instance_frontier_holes` shows
the gaps before the alarm fires.

## Authentication freshness fence

A node refuses new authentication, by any method, when its copy of the
security tables (users and grants) may be stale. A refused authentication
returns `{error, temporarily_unavailable}`, and a WAMP session is aborted with
`wamp.error.unavailable`; the client can retry.

The fence applies only when `db.aae` is `on`; with `off` it never refuses. A
node with `cluster.enabled = off` is always certified fresh, so the fence
does not refuse on it ([Clustering](clustering.md);
`bondy_auth_oauth2_SUITE`: `aae_fence_certifies_only_with_clustering_disabled`).

### `db.aae.fence.max_lag` (`bondy_router.auth_max_lag`)

Duration, default `60s`.

The fence refuses when any shard of the security tables has gone longer than
this without a sync round that certified it. A local write does not certify
a shard: it says nothing about changes made on other nodes.

### `db.aae.fence.on_isolation` (`bondy_oplog.aae_fence_on_isolation`)

`refuse | proceed | quorum`, default `refuse`.

Which sync activity certifies the security shards on a clustered node:

- `refuse` certifies only after a sync round with a peer. A node that
  reaches no peer, including a member that has just restarted and lists only
  itself, refuses once `db.aae.fence.max_lag` passes, however much it writes
  locally.
- `proceed` also certifies on a tick with no reachable peer. A node cut off
  from the cluster keeps authenticating against a view that may miss a
  revocation made elsewhere.
- `quorum` certifies only while this node is connected to a strict majority
  of the cluster membership, itself included. A node that lists only itself
  is never a majority.

`bondy_auth_oauth2_SUITE`: `aae_fence_isolation_policy`.

## See also

- [Understanding convergence in bondy_db](../database/convergence.md) — the
  sync round, compaction and re-bootstrap.
- [Storage topology](../architecture/db_topology.md) — choosing the
  partition strategy before the first start.
- [Platform directories](../deployment/platform_directories.md) — where the
  stores live and what happens when a shard stops.
