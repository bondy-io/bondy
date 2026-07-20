# Reclamation configuration reference

The configuration surface for projection-cell reclamation and origin
retirement. All options are `bondy_oplog` application-environment keys, read
at node start. Reclamation and retirement are **on by default**; deletion
itself (`bondy_db:delete/3`) is always available and needs no configuration.

> **Concept:** [Understanding deletion and reclamation →](../database/deletion_and_reclamation.md)

## Enabling reclamation

### `reclaim_enabled`

`boolean()`, default `true`.

Whether the reclamation scheduler ticks. When `false` the scheduler process
runs idle: deletes still converge and tombstones are retained indefinitely,
exactly as before the feature existed. Requires a node restart to change.

### `reclaim_interval_ms`

`non_neg_integer()`, default `60000`.

Milliseconds between reclamation passes. Deliberately much larger than the
compaction scheduler's cadence: reclamation is a space concern, not a
liveness one, and each pass re-derives stability from peer state that only
changes as anti-entropy rounds complete. `0` disables periodic passes.

### `reclaim_batch_cells`

`pos_integer()`, default `500`.

Cells scanned per applier call within a pass. The sweep executes inside the
applier — the sole writer to a shard's projection — so this bound is the cap
on how long one batch can stall a concurrent write. A pass loops batches to
completion; writes interleave between batches.

## Origin retirement

### `origin_retirement`

`boolean()`, default `true`.

Whether the origin-retirement pass auto-reacts to Partisan membership
changes. When enabled, each node reacts to an observed membership removal —
and reconciles once at boot, covering removals that happened while it was
down — by forgetting departed peers from its peer state and reaping dead
origins from cell states by complement. The pass is fail-closed: if any
current member cannot be queried for the origins it claims, nothing is
reaped and the pass retries on the next trigger. The pass never bans an
origin.

### `origin_retirement_interval_ms`

`non_neg_integer()`, default `600000`.

Milliseconds between periodic retirement passes, in addition to the
membership-event trigger. The periodic pass covers origin-epoch turnover
that produces no membership event — a node that loses its storage and
rejoins under the same name mints fresh origins without any member joining
or leaving, and only a periodic pass on the surviving nodes reaps the dead
epoch.

## Shared scheduler machinery

The reclamation scheduler is an instance of the same scheduler that drives
compaction, registered as `bondy_oplog_reclaim_scheduler`. One option is
shared; the compaction options are listed here only to state that they do
**not** govern reclamation.

### `gc_max_concurrency`

`pos_integer()`, default `4`.

Cap on concurrently running trigger workers, per scheduler instance. Applies
to both the compaction scheduler and the reclamation scheduler. Instances
over the cap on a tick are skipped that round and retried on the next.

### `gc_scheduler`, `gc_interval_ms`

These govern the **compaction** scheduler only (defaults `true` and `1000`).
Reclamation has its own enablement and cadence above; disabling compaction
does not disable reclamation, and vice versa.

### `peer_timeout_ms`

`non_neg_integer()`, default `30000`.

Listed to state a boundary: this recency filter applies to **compaction**'s
reading of peer state only. Reclamation uses the strict, membership-based
reading with no recency filter — a silent member holds reclamation down
until retired by a membership act, and no timeout changes that.

## Telemetry

Reclamation fails silently in both directions, so its observability surface
is part of the contract. Events, with their measurement and metadata keys:

### `[bondy_oplog, applier, cells_swept]`

Emitted per sweep batch. Measurements: `scanned`, `discarded`,
`reduction_skipped`, `skipped`. Metadata: `instance_id`, `stable_hlc` — the
stability point the batch ran at.

### `[bondy_oplog, reclamation, stalled]`

Emitted on every reclamation attempt that reclaims nothing, naming why.
Measurement: `count`. Metadata: `instance_id`, `reason` (`unconfirmed`,
`membership_unavailable`, `no_frontier`, `non_event_frontier`,
`no_applier`), and `missing_members` — for `unconfirmed`, the members
holding stability down. Never rate-limited.

### `[bondy_oplog, scheduler, gc, trigger_outcome]`

Emitted per trigger run by every scheduler instance. Measurement: `count`.
Metadata: `scheduler` (e.g. `bondy_oplog_reclaim_scheduler`), `instance_id`,
`outcome`. A permanently failing instance is visible here even if nothing
else surfaces it.

### `[bondy_oplog, retirement, completed]` and `[bondy_oplog, retirement, skipped]`

One `completed` per retirement pass, with measurements `dead_origins` and
`origins_reaped` and metadata `forgotten_peers`; one `skipped` per aborted
pass with the abort `reason` in metadata (an unreachable member, an
unavailable membership service).

### `[bondy_oplog, applier, origins_reaped]`

Emitted when a reap pass rewrites cells. Measurements: `cells`, `origins`.
Metadata: `instance_id`.

### `[bondy_oplog, peer_state, excluded]`

Emitted when compaction's recency-filtered read drops an aged-out peer.
Telemetry only, by design — it fires on every compaction tick for as long as
a peer stays silent, and a log line at that rate would storm.

### The stall log

Alongside the telemetry, a scheduler-driven reclamation stall produces a
warning log naming the instance and the missing members, rate-limited to one
line per instance per 60 seconds. The log states the operational fact that
matters: a member in this state never ages out, and must be retired by a
deliberate membership act.

## See also

- [Understanding deletion and reclamation](../database/deletion_and_reclamation.md)
  — the model these options control.
- The generated module reference for `bondy_db` (`delete/3`) and
  `bondy_oplog_gc_scheduler` (named scheduler instances).
