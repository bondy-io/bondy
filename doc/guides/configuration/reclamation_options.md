# Reclamation configuration reference

The configuration surface for projection-cell reclamation and origin
retirement. Reclamation and retirement are **on by default**; deletion
itself (`bondy_db:delete/3`) is always available and needs no configuration.
Every option below has a `bondy.conf` key (`db.*`) as well as the
underlying `bondy_oplog` application-environment key it maps to; either way,
the value is read at node start — changing it requires a restart. These are
global, node-wide settings — not scoped to a specific `bondy_db` database
(`main` or `registry`).

> **Concept:** [Understanding deletion and reclamation →](../database/deletion_and_reclamation.md)

## Enabling reclamation

### `db.reclaim` (`bondy_oplog.reclaim_enabled`)

`on | off`, default `on`.

Whether the reclamation scheduler ticks. When `off`, the scheduler process
runs idle: deletes still converge, and tombstones are kept indefinitely.

### `db.reclaim.interval` (`bondy_oplog.reclaim_interval_ms`)

Duration, default `1m`.

Interval between reclamation passes. Deliberately much larger than the
compaction scheduler's cadence: reclamation is a space concern, not a
liveness one, and each pass re-derives stability from peer state that only
changes as anti-entropy rounds complete. `0` disables periodic passes.

### `db.reclaim.batch_cells` (`bondy_oplog.reclaim_batch_cells`)

`pos_integer()`, default `500`.

Cells scanned per sweep call within a pass. The sweep runs inside the
process that writes the shard's projection: the applier, or the instance
itself on a shard without an applier. This bound therefore caps how long one
batch can delay a concurrent write. A pass loops batches to completion, and
writes interleave between batches.

## Origin retirement

### `db.origin_retirement` (`bondy_oplog.origin_retirement`)

`on | off`, default `on`.

Whether the origin-retirement pass runs. When enabled, a node runs the pass
on each membership change it observes, once at boot (to cover removals that
happened while it was down), and every `db.origin_retirement.interval`. Each
pass:

- forgets departed peers from the node's peer state;
- pulls the retirement set of every member that answers and unions it into
  its own;
- drops the applied-frontier entry of an origin when every member has
  answered and every answer holds the retirement;
- reaps dead origins from cell states by complement.

The reaps are fail-closed. If any current member cannot be queried, the pass
reaps nothing and retries on the next trigger. Retirements learned from the
members that did answer still apply. The pass never retires an origin by
itself: see *Retiring a decommissioned node* below.

### `db.origin_retirement.path` (`bondy_oplog.retirement_path`)

Path, default `origin_retirement` relative to `platform_data_dir`.

Where this node stores its retirement set. A retirement is permanent, so it
has to survive a restart. A node that forgot one would re-learn the origin's
frontier entry from a peer and then read its own absence as a deficit. A node
that cannot write this file refuses to retire and refuses to reap. Nothing
else is affected.

The node writes the file **before** the retirement takes effect, so a failed
write retires nothing and the operation can be retried
(`bondy_oplog_origin_bans_test`: `a_failed_persist_enforces_nothing`). The
write goes to a temporary file, which is synced and then renamed over the
previous one, so a failed write leaves the previous file in place. A node
whose write fails stops reaping until a later write succeeds.

Reaping requires **every** member to hold the retirement, so one node that
cannot persist stops the whole cluster from reclaiming frontier entries. A
path that cannot be read or written therefore raises the
`bondy_oplog_retirement_not_persistent` alarm and logs at error level. The
alarm is raised once per episode and cleared by the next successful write. An
application that embeds `bondy_oplog` without a path logs this once at info
level and raises no alarm.

### `db.origin_retirement.interval` (`bondy_oplog.origin_retirement_interval_ms`)

Duration, default `10m`.

Interval between periodic retirement passes, in addition to the
membership-event trigger. The periodic pass covers origin turnover that
produces no membership event. A node that loses its storage and rejoins
under the same name mints fresh origins without any member joining or
leaving, and only a periodic pass on the surviving nodes reaps the old ones.
The interval is also the cadence at which retirements propagate between
nodes.

### Retiring a decommissioned node

Removing a node from the Partisan membership stops it participating; it does
not release the applied-frontier entries its origins hold on every surviving
replica. Those entries are permanent claims — one per durable shard, so the
cost of a departure scales with `db.main.shard_count` — and only a
retirement releases them.

Retirement is an operator act, never derived from membership, because
membership is reversible: a departed node returns with the disk it left with
and resumes minting under the same origin, and survivors that had reaped it
on absence alone would silently skip its new events.

After removing the node from the membership, on any remaining node:

```erlang
{ok, Retired} = bondy_oplog_origin_retirement:retire_dead().
```

The call takes the origins no current member claims and retires them. Each
retirement is persisted, then banned, and the retirement passes of the other
nodes replicate it. Once every member holds it, each node drops the
corresponding frontier entries on its own next pass.

Retiring bans the origin cluster-wide, and a ban is permanent. **Retire only
once the cluster has converged on that node's events** — any of its events a
replica has not yet applied become permanently unreachable to it. A reap
taken over replicas that disagree on the origin's sequence logs a WARNING
and emits `[bondy_oplog, retirement, reaped_unconverged]`, which is the
signal that retirement happened too early.

An unreachable peer is still a member, because Partisan membership changes
only through a join or a leave. A member that cannot answer aborts the
complement, so a partitioned node does not retire the origins of the rest of
the cluster.

Run the call with every instance up. The complement is built from what nodes
advertise, and an instance that has been stopped does not advertise its
origin, so a live origin could fall into the complement. The call checks this
node's own instances: while any local instance is down, it refuses with
`{error, {instances_down, Ids}}`. The call cannot detect a peer that
under-advertises, so the instruction applies on every node. A notice log names
the retired origins. Retirement cannot be undone.

## Shared scheduler machinery

The reclamation scheduler is an instance of the same scheduler that drives
compaction, registered as `bondy_oplog_reclaim_scheduler`. One option is
shared; `gc_scheduler`/`gc_interval_ms` (the compaction scheduler's own
enablement and cadence) are internal-only — they have no `bondy.conf` key —
and are listed here only to state that they do **not** govern reclamation.

### `db.gc_max_concurrency` (`bondy_oplog.gc_max_concurrency`)

`pos_integer()`, default `4`.

The cap on trigger workers that one scheduler runs at once. The compaction
scheduler and the reclamation scheduler each apply this value to their own
workers. Instances over the cap on a tick are skipped and retried on the next
tick. The option is unrelated to `db.gc_interval` and `db.gc_heap_delta`,
which configure each instance's BEAM heap monitor.

## Telemetry

Reclamation fails silently in both directions, so its observability surface
is part of the contract. Events, with their measurement and metadata keys:

### `[bondy_oplog, applier, cells_swept]`

Emitted per sweep batch. Measurements: `scanned`, `discarded` (cells
physically reclaimed), `rewritten` (cells whose causally stable operations
were folded into fewer operations without changing the value), `skipped`.
Metadata: `instance_id`, and `stable_hlc`, the stability point the batch
ran at.

### `[bondy_oplog, reclamation, stalled]`

Emitted on every reclamation attempt that reclaims nothing, naming why.
Measurement: `count`. Metadata: `instance_id`, `reason` (`idle`,
`unconfirmed`, `no_members`, `membership_unavailable`, `no_frontier`,
`non_event_frontier`, `no_applier`), and `missing_members` — for
`unconfirmed`, the members holding stability down. Never rate-limited.

`idle` is the steady state of a converged, quiet shard: this replica's tree
is empty (fully compacted or never written), so there is nothing whose
stability needs certifying. It is the only reason that never produces the
stall log line, because no operator action applies to it. It ends on the
shard's next local event. The
[deletion and reclamation guide](../database/deletion_and_reclamation.md)
lists every reason.

### `[bondy_oplog, scheduler, gc, trigger_outcome]`

Emitted per trigger run by every scheduler instance. Measurement: `count`.
Metadata: `scheduler` (e.g. `bondy_oplog_reclaim_scheduler`), `instance_id`,
`outcome`. A permanently failing instance is visible here even if nothing
else surfaces it. `unconfirmed`, `no_members` and `membership_unavailable`
from the compaction scheduler (`bondy_oplog_gc_scheduler`) mean compaction is
waiting on members. The Prometheus counter
`bondy_oplog_gc_scheduler_events_total` carries `scheduler` and `event` (here
`trigger_<outcome>`).

### `[bondy_oplog, retirement, completed]` and `[bondy_oplog, retirement, skipped]`

One `completed` per retirement pass, with measurements `dead_origins`,
`origins_reaped`, `origins_scanned`, `retirements_learned` (retirements
pulled from members this pass) and `frontiers_reaped`, and metadata
`forgotten_peers`.

One `skipped` per pass whose reap by complement aborted, with the abort
`reason` in metadata: an unreachable member, an unavailable membership, or
`no_members`. Measurements: `count`, `retirements_learned` and
`frontiers_reaped`. When the membership was read, retirement replication ran
before the abort, and the two counts report it. When the membership could
not be read or listed no other member, both counts are `0`.

### `[bondy_oplog, retirement, reaped_unconverged]`

Emitted when a frontier entry is dropped for an origin whose sequence still
differs across members — the origin was retired before the cluster had
converged on its events, and the ban has frozen that difference permanently.
Measurement: `count`. Metadata: `instance_id`. The accompanying WARNING log
carries the per-member sequences.

### `[bondy_oplog, applier, retired_pairs_dropped]`

Emitted when a page merge carries events authored by a retired origin, which
are dropped before anything folds them. Measurement: `count`. Metadata:
`instance_id`. A steady non-zero rate means a retired node is still being
replicated from.

### `[bondy_oplog, applier, origins_reaped]`

Emitted when a reap pass rewrites cells. Measurements: `cells`, `origins`.
Metadata: `instance_id`.

### The stall log

Alongside the telemetry, a scheduler-driven stall produces a warning log
naming the scheduler, the instance and the missing members, rate-limited to
one line per scheduler and instance per 60 seconds. Both schedulers report
every error their trigger returns. For the reclamation scheduler that includes
stability not advancing. For the compaction scheduler it includes compaction
waiting on a member this node has no confirmed row for (`unconfirmed`), on an
unreadable membership, or on a membership that lists no other node while
clustering is enabled (`no_members`; see
[Clustering](clustering.md#running-a-single-node)). A member that confirmed and
then went down does not produce a compaction warning: its stale row only stops
the frontier advancing, which looks the same as a peer that has not synced
yet. The reclamation scheduler reports it as `no_frontier`, naming it in
`member_status`. For a member, the log states the operational fact that
matters: a member in this state never ages out, and must be retired by a
deliberate membership act.

## See also

- [Understanding deletion and reclamation](../database/deletion_and_reclamation.md)
  — the model these options control.
- The generated module reference for `bondy_db` (`delete/3`) and
  `bondy_oplog_gc_scheduler` (named scheduler instances).
