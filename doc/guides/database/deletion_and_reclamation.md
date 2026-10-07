# Understanding deletion and reclamation in bondy_db

In a replicated, operation-based store, deleting a value and reclaiming its
space are two different acts, licensed by two different kinds of evidence.
Deletion is an ordinary operation: it converges across the cluster like any
other write, and it leaves a **tombstone** behind, because the tombstone is the
only thing that can reject a concurrent, older write that arrives later.
Reclamation, the physical removal of the cell, is licensed only by **causal
stability**: evidence that no operation old enough to matter to the tombstone
can be delivered again. `bondy_db` keeps the two acts separate, and this
document explains the machinery that makes the second one safe.

## The problem: you cannot simply erase

Every `bondy_db` table is backed by an operation-based CRDT. Replicas converge
because every replica eventually applies the same set of operations, in any
order. Erasing a cell outright breaks that. Suppose a replica erases "user
alice" and then receives a *concurrent* write to alice, one issued before the
delete was known. The write resurrects her, because nothing remains to say
that the delete happened, or to compare timestamps against.

So the removal of a register is itself an operation (`clear`). Applying it
leaves the cell in a `cleared` state that carries the hybrid logical clock
(HLC) of the removal. Readers see `{error, not_found}` at once: the read API
does not distinguish a cleared cell from an absent one. The cell still
occupies a row, and its one remaining job is to reject any concurrent `set`
with a lower HLC that has not arrived yet.

Without reclamation, that row stays forever, and the cell count grows with
every key ever written, however few of them are live. The rest of this
document is about when the job of the tombstone is finished.

## Deleting through the API

`bondy_db:delete/3` issues the removal operation that the table's CRDT
declares. Callers do not spell `apply(Table, Realm, Key, clear)` themselves:
they state the intent, and the fold supplies the mechanics.

```erlang
ok = bondy_db:delete(Table, RealmUri, Key),
{error, not_found} = bondy_db:read(Table, RealmUri, Key).
```

Whether and when the cell is physically reclaimed is the CRDT's decision. The
CRDT declares it through two optional callbacks of the `bondy_oplog_crdt`
behaviour:

- `removal_op/0` names the whole-cell removal operation. The LWW register
  returns `clear`; the enable-wins and disable-wins flags return `disable`. A
  CRDT that does not export the callback has no whole-cell removal, and
  `delete/3` returns `{error, {no_removal_op, Module}}`. A set or a map removes
  its entries one by one, and a counter has no removal at all.
- `stabilize/2` decides, for a given stability point, what remains of the
  cell's state: `keep`, `{keep, Reduced}`, or `discard`. The LWW register
  discards a tombstone whose HLC is strictly below the stability point. It
  keeps a live value unconditionally: stability says that nothing older can
  arrive, not that the value is unwanted.

The LWW register, the fold of most catalogue tables, and the two flags
implement both callbacks. The PN counter, the struct and the owned reading
implement `stabilize/2` only. The counter and the owned reading discard a
stable cell whose value is zero. The struct discards one when every field its
schema gives a zero value holds that zero. A table whose CRDT declares neither callback keeps its
cells. The sweep reads "no opinion" as "reclaim nothing", never the reverse.

## Causal stability: the licence to reclaim

A timestamp is **causally stable** at a node when every operation that can
still be delivered there is newer than it (Baquero, Almeida and Shoker, *Pure
Operation-Based Replicated Data Types*, arXiv:1710.04469, Definition 5.1).
Once the HLC of a tombstone is causally stable, the concurrent write that the
tombstone exists to reject cannot arrive, and the tombstone is overhead.

Bondy derives stability from three ingredients. All of them run on the
ordinary anti-entropy (AAE) machinery.

### Witnesses: every member's durable frontier

A replica's **applied frontier** is a version vector, `#{Origin => Seq}`: for
each origin, the highest sequence number this replica has applied. Its
**durable frontier** is the applied frontier a restart would restore. On a
durable backend that is the frontier in the last checkpoint. On an ephemeral
backend, which writes no checkpoint, it is the live applied frontier
(`bondy_oplog_instance:durable_frontier/1`).

Each replica records the durable frontier of every peer it syncs with, in the
peer-state table (`bondy_oplog_peer_state`). The record is two-sided:

- Before a sync round, the initiator asks the peer for its frontiers
  (`get_frontier`). When the round completes, the initiator records the
  durable frontier the peer reported.
- The initiator then reports its own durable frontier to the peer
  (`confirm_frontier`), and the peer records it. Sync is pull-only, so without
  this report the peer learns what the initiator holds only when it pulls in
  turn.

A recorded durable frontier is evidence about what that member has folded and
checkpointed. Stability counts a key only when every member holds its effect
durably, not merely when every member has received it. A member that applies
an event and crashes before its checkpoint loses the effect, so receipt alone
would let a replica reclaim on a claim the member no longer holds
(`proofs/tla/JoinInstall_Truncation_CompactDurable_Crash.cfg` holds the
durable rule).

Each member's recorded durable frontier is a **witness**, and this replica's
own durable frontier is a witness too.

### The strict membership frontier

The stability point of a shard is computed against **every** member of the
Partisan membership, including members that are unreachable at the time
(`bondy_oplog_instance:reclamation_members/0`). A member leaves that set only
through a deliberate membership act, never by timeout. Every member needs a
recorded durable frontier; until one is recorded, the member is
**unconfirmed** and the replica certifies nothing.

The **stability frontier** is the largest key in this replica's tree such that
every key at or below it is confirmed by every witness. A witness confirms a
key when its version vector covers the key's `{Origin, Seq}`, or when the
key's origin is retired (see [Origins, retirement, and departed
nodes](#origins-retirement-and-departed-nodes)). The HLC of the frontier key is
the stability point (`bondy_oplog_reclamation_test`:
`confirmed_frontier_is_hand_computed`).

One silent member holds stability down for the whole cluster. That is the
correct trade: an unreclaimed tombstone costs disk, while a wrongly reclaimed
one costs data, permanently and silently.

### Absorbing clocks

Every path that delivers remote events advances the local HLC past the
delivered timestamps: live sync, direct append, and the catalogue-snapshot
bootstrap. Absorption turns "every replica already holds these events" into
"no replica can *mint* an event below this point". A freshly bootstrapped
replica's first write sorts after everything it received in its snapshot.

### Which nodes count

One setting decides which nodes count: `cluster.enabled`.

- With clustering disabled (`off`), the node has no members to wait for.
  Nothing can contradict it, so everything it holds is stable, and it
  reclaims against a fresh tick of its own clock.
- With clustering enabled (`on`), a membership that lists no other node
  licenses nothing. A member that has just restarted lists only itself until
  it rejoins, and reclaiming then would discard cells the other members can
  still contradict. Reclamation reports `no_members` instead.

The tests `disabled_reclaims_the_tail_tombstone` and
`no_other_member_with_clustering_reclaims_nothing` in
`bondy_oplog_reclamation_test` cover the two cases. See
[Clustering](../configuration/clustering.md).

## The sweep

Reclamation is a sweep over the projection. The sweep runs in the process that
writes the projection: the applier, or the instance itself for a fused shard.
Because that process is the only writer, a delete cannot interleave with a
concurrent apply to the same cell. The sweep walks the cells of each
registered table through that table's CRDT, asks `stabilize/2` for a verdict,
and removes discarded cells through the projection adapter. The storage
engine's own compaction then reclaims the bytes.

Two guards apply to every discard:

- **The overlay fence.** A read of an absent cell replays pending events from
  the beginning of time, so removing a cell widens its replay window. The sweep
  discards a cell only when nothing at all is pending for its key.
- **The strict boundary.** A tombstone whose HLC *equals* the stability point
  is kept. Event keys order by HLC first and origin second, so a key with the
  same HLC and a higher origin can still be unconfirmed. At equal HLC, the
  register's tie-break also depends on the tombstone being materialised.

The boundary rule has a visible consequence. A tombstone that is the newest
event on its shard stays in place until a later event on that shard is
confirmed by every witness. Under ordinary traffic this is brief. On an idle
shard the last tombstone persists, bounded to one cell. The sweep keeps it
because the stability argument requires it.

The sweep is bounded and resumable. Each pass runs in batches of
`db.reclaim.batch_cells` cells, so concurrent writes interleave between
batches instead of waiting for a whole-shard scan. Passes run on their own
cadence, `db.reclaim.interval`, driven by a second instance of the GC
scheduler registered as `bondy_oplog_reclaim_scheduler`. That cadence is
separate from, and much slower than, the compaction cadence.

## Origins, retirement, and departed nodes

One silent member freezes reclamation, so a *permanently* departed node has to
leave the membership. Leaving is a deliberate act: the operator's
`bondy.cluster.leave`, or the node's own graceful shutdown under
`cluster.automatic_leave` (see [Clustering](../configuration/clustering.md#turning-clustering-off-for-a-member)).
As soon as the membership no longer lists the node, stability is computed
without it. Nothing ages out on a timer. A node that is merely partitioned
keeps its seat, and keeps reclamation honest, until an operator decides
otherwise.

Bondy identifies the *history* of a replica by an **origin**: an opaque 128-bit
identity created with the replica's storage and destroyed with it. A node that
loses its disk and rejoins under the same name therefore cannot collide with
its own past, the failure mode that Riak's kv679 made well known. The
consequence is that a node accumulates dead origins over its lifetime, and
their bookkeeping entries stay in cell states.

The origin-retirement pass (`db.origin_retirement`) removes these entries by
**complement**. It asks every current member for the origins it claims, which
is knowledge each node owns. An origin that appears in the local frontiers but
that no member claims is a dead epoch. The pass reaps its causal-context
entries from cell states. The pass is fail-closed: if any member cannot be
queried, nothing is reaped, and the pass retries later. It runs on membership
changes and on a slow periodic tick (`db.origin_retirement.interval`). The tick
covers an origin epoch that turns over without any membership change, such as
a Kubernetes pod that loses its volume and rejoins under the same name.

The pass never retires an origin on its own. **Retirement** is an operator
act, `bondy_oplog_origin_retirement:retire_dead/0`, that bans the origin
cluster-wide and permanently. Banning a live origin would silently refuse its
writes, which is divergence, not hygiene. A retired origin's keys count as
confirmed by every witness, and a node drops the origin's frontier entry once
every member has retired it. The [reclamation configuration
reference](../configuration/reclamation_options.md#retiring-a-decommissioned-node)
states when retirement is safe to run.

## Watching stability: outcomes and the idle state

Reclamation fails silently in both directions: nothing visibly breaks whether
it works or not. So every attempt that certifies no stability reports why.
Each such attempt emits the telemetry event `[bondy_oplog, reclamation,
stalled]`, exported as the Prometheus counter
`bondy_oplog_reclamation_stalled_total` with the labels `instance_id` and
`reason`. Neither is rate-limited. The scheduler also logs a warning that
names the members and their sync recency, at most once a minute per instance.

| Reason | Meaning | Action |
|---|---|---|
| `idle` | This replica's tree holds no events, so there is nothing to certify. | None. |
| `unconfirmed` | A member has no recorded durable frontier for this shard. | Revive the member, or remove it from the membership. |
| `no_frontier` | Every member has a recorded durable frontier, but the oldest event in this replica's tree is not covered by every witness. The usual cause is a member that stopped syncing, so its recorded frontier is stale. | Same as `unconfirmed`. The warning's `member_status` names the member with the highest `last_sync_age_ms`. |
| `no_members` | Clustering is enabled and the membership lists no other node. | None if the node has just restarted and will rejoin. A node meant to run alone needs `cluster.enabled = off`. |
| `membership_unavailable` | The membership service cannot be read. | Investigate this node, not the peers. |
| `unservable` | The walk of this replica's tree meets a page its store lacks, so it cannot tell what the members hold. | Investigate this node's storage. See [Unservable own root](convergence.md#unservable-own-root). |
| `no_applier` | The shard has no applier or fused instance to run the sweep. | Investigate this node, not the peers. |
| `non_event_frontier` | The frontier computation returned a key that is not an event key. | A bug; report it. |

Two distinctions behind this table keep a converged, quiescent cluster quiet.

**Recency is not confirmation.** A sync round in which the peer reports no
durable frontier, or an empty one, refreshes the peer's recency: `last_sync`,
and the `bondy_oplog_peer_last_sync_age_seconds` gauge built on it, stay
accurate. The round confirms
nothing new. The peer-state table keeps the durable frontier recorded before
(`bondy_oplog_peer_state_test`: `empty_report_refreshes_without_confirming`). A
member that has never reported a non-empty durable frontier stays
`unconfirmed`, however recently it synced. A durable frontier also survives
the member's own compaction, so a peer that compacts never moves the
stability frontier back (`bondy_oplog_compaction_fused_test`:
`peer_compaction_does_not_stall_ours`).

**An empty tree has nothing to certify.** The stability frontier is a key in
this replica's tree. MST compaction truncates the prefix every member has
confirmed, so the steady state of a shard nobody writes to is an *empty* tree.
With an empty tree, no stability frontier can exist, and no event needs
certifying. Reporting that as `unconfirmed` would give wrong advice, to revive
or remove members that are alive and converged, and the repetition would hide
the stalls that need action. The `idle` outcome names this state. It never
reaches the warning log, it stays visible in the counter, and it ends when the
next event lands in the tree (`bondy_oplog_reclamation_test`:
`empty_tree_is_idle_not_stalled`).

### A known, deliberate liveness gap

One narrow state is left unresolved by design. Suppose cells become
reclaimable on a shard, and the whole cluster then goes quiet on that shard
long enough for compaction to empty every replica's tree *before* stability
was certified past those cells. The shard now reports `idle` on every node,
and those cells stay unreclaimed for as long as the shard stays silent. They
are hidden from reads but still occupy space.

We tolerate this for three reasons.

1. The same asymmetry governs the whole design: an unreclaimed cell costs
   bytes, a wrongly reclaimed one costs data, permanently and silently.
2. The state is bounded and heals itself. The first write to the shard, on any
   node, puts an event back in every replica's tree. Once every member has
   applied and checkpointed it, and reported its durable frontier in a sync
   round, stability lands at that event's HLC, above the backlog. One sweep
   then discards all of the backlog. A shard that never receives that write is
   also a shard whose leftover bytes never grow.
3. The sound fix is not a patch. It would be a clustered analogue of the
   clustering-disabled case: "every member's durable frontier covers
   everything this replica holds, therefore a fresh tick is stable". That
   argument rests on the clock dominating events *this* node minted or
   absorbed. It does not transfer to other members without a new argument
   that bounds the HLCs a peer can still mint. That is an extension to the
   stability argument first, and an implementation second.

Two cheaper routes do not work. Ordering the collectors so that reclamation
always runs before compaction cannot be guaranteed, because compaction can be
licensed while stability is unreachable. Deferring compaction while a
reclamation backlog exists would couple the two collectors for no gain: both
already wait for every cluster member.

## When history may be removed

Compaction removes events from a shard's history. An event is removed only
once every cluster member, this node included, has applied it and written it
to its frontier checkpoint. The truncation point is bounded by this node's
checkpointed frontier and by the checkpointed frontier each other member last
reported (`bondy_oplog_compaction_test`: `unconfirmed_member_is_reported`;
`bondy_oplog_compaction_fused_test`: `fused_compaction_waits_for_every_member`).
A `registry` shard writes no checkpoint, so its applied frontier stands in for
one. These are the same witnesses that reclamation reads.
[Understanding convergence](convergence.md#the-compaction-witness-rule-and-the-truncation-cap)
describes the members that count and the cap below never-applied events.

Each compaction tick writes the shard's frontier checkpoint when the applied
frontier has moved since the last one, including on a tick that truncates
nothing. Ticks run every `bondy_oplog.gc_interval_ms` milliseconds, an
application environment key with no `bondy.conf` key, default `1000`. A member
whose ticks do not run stops advancing the durable frontier its peers record,
and so holds compaction and reclamation on every replica.

A checkpoint write that fails stops the shard's instance, which is then
started again with a backoff
(`bondy_oplog_compaction_checkpoint_file_test`:
`compaction_does_not_continue_past_an_unsynced_checkpoint_test`; see
[When a storage shard stops](../deployment/platform_directories.md#when-a-storage-shard-stops)).

## Alternatives and why not

Two simpler designs do not hold.

*Timeout-based peer exclusion.* Dropping peers unheard from for a timeout lets
a peer return holding state the others no longer account for. Reclamation
would resurrect deleted data. Compaction would lose the writes each side of a
partition accepted alone, once both sides had truncated
(`proofs/tla/ConfirmedCompaction_3R_Fresh_Partition.cfg` violates `NoLoss`).
Both therefore read the peer-state table strictly, with the members supplied
by the membership, on every database (`bondy_oplog_peer_state_test`:
`strict_read_ignores_recency`).

*Node names as origins.* Names are addresses, and they outlive the state they
point at. Every system whose correctness rests on per-actor monotonic counters
has either separated the two from the start (Cassandra's host UUID, etcd's
member IDs) or had to add the separation after silent data loss (Riak's
per-key actor epochs). Bondy's random origins apply that lesson from the
start. The complement-based reap makes their opacity cheap to operate: nobody
has to know which opaque ID belonged to which node.

## Consequences

- `delete/3` hides the value at once and everywhere. Space returns later, when
  stability licenses it. The two acts are decoupled.
- Reclamation is quiet when healthy and visible when stalled. A member that
  cannot confirm shows up within one scheduler interval in the stall counter
  (`bondy_oplog_reclamation_test`: `stall_is_observable_within_one_interval`)
  and in a rate-limited log line. An actionable stall that names members is a
  fact about membership, and its remedy is a membership decision. `idle`, the
  empty tree of a converged quiescent shard, is counted but never logged.
- Reclamation and the origin-retirement pass are on by default. Every setting
  mentioned here, including how to turn either off, is in the
  [reclamation configuration reference](../configuration/reclamation_options.md).

## See also

- [Reclamation configuration reference](../configuration/reclamation_options.md):
  every option, default, and telemetry event.
- [Understanding convergence in bondy_db](convergence.md): the witness rule
  that compaction and reclamation share.
- The generated module reference for `bondy_db` (`delete/3`),
  `bondy_oplog_crdt` (the `removal_op/0` and `stabilize/2` callbacks),
  `bondy_oplog_peer_state` (recorded durable frontiers) and
  `bondy_oplog_origin` (origin identity).
