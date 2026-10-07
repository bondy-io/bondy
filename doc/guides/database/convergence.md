# Understanding convergence in bondy_db

`bondy_db` replicates without consensus. Any replica accepts a write, and the
cluster reconciles afterwards. In an eventually consistent store the useful
question is not *whether* replicas converge but how you know they have. This
document explains what "converged" means in `bondy_db`, what a replica does to
get there, what it refuses to do on the way, and which signals tell an operator
where a replica stands.

Each database shard runs as one **instance**: an operation log, its Merkle
search tree (MST), and the materialised tables built from it. Every node holds a
**replica** of each instance. The code calls an operation an *event*; this
document says *operation* throughout.

The ordering property every replica keeps, per-origin prefix closure, has its
own document: [Understanding per-origin prefix closure](prefix_closure.md).

## What converges: the applied frontier

Every replicated operation carries a key `{HLC, Origin, Seq}`. A replica's
**applied frontier** is the per-origin `Seq` it reports as applied: a version
vector over origins.

The applied frontier is the unit of comparison because it states what a
replica *has*, independently of how it got there. Two replicas that hold the
same applied frontier hold the same operations. `bondy_prometheus_db` exports a
stable hash of it as `bondy_oplog_instance_frontier_hash`. Each node computes
the hash locally, so PromQL derives cluster-wide convergence with no network
traffic at scrape time: an instance is converged when every node reports the
same hash.

Each entry is a **prefix bound**, not a maximum. It is the largest `Seq` below
which nothing from that origin is missing. A report of 7 therefore asserts that
5 and 6 arrived, and that assertion is what makes equal frontiers mean equal
operation sets. An operation folded above a hole is neither lost nor reported.
The replica keeps it in a per-origin pending set and absorbs it into the bound
when the hole closes. For why the bound has to be a prefix, see
[Why a prefix matters](prefix_closure.md#why-a-prefix-matters).

A replica that carries a hole reports a *lower* frontier than one that does not.
Its frontier hash differs while it is behind and matches again when the hole
fills. That is the intended reading.

The applied frontier changes with every fold. The **durable frontier** is the
applied frontier as the replica last checkpointed it; on an in-memory instance
the two are the same (`bondy_oplog_instance:durable_frontier_of/1`). Peers
exchange durable frontiers, and compaction trusts only those.

## The sync round

Anti-entropy is pull-based. On each `db.aae.interval` tick,
`bondy_oplog_sync_scheduler` sorts the instances and rotates the list by a
monotonic tick counter, so that a scarce `db.aae.max_concurrency` cap starves no
instance. It picks peers for the instances that win a slot, and
`bondy_oplog_sync_session` runs one round against each peer:

1. **Fetch the peer's frontier.** The responder answers `get_frontier` only
   after an installed-consistency barrier. The frontier it reports therefore
   counts operations it can serve, not operations still in flight through its
   own pipeline. The session fetches the frontier *before* the root, so the
   tree of the round is the same as or newer than the frontier it is judged
   against.
2. **Fetch the peer's MST root.** Equal roots end the round, and nothing moves.
3. **Pull the differing pages.** The tree structure localises the difference,
   so the bytes moved are proportional to divergence, not to data size.
4. **Integrate.** `bondy_oplog_instance:integrate_peer_root/2` merges the
   pulled pages and delivers the operations to the projection.

A round that pulled everything it set out to pull is a **complete round**. A
round that its page budget capped is not. Two decisions require a complete
round: frontier adoption and the frontier gap verdict. A capped round has not
seen enough to justify either.

## Three ways a completed round can still lose data

Each of the steps above can succeed while an operation goes missing, and the
round still records success. A replica that concludes "we agree" from such a
round then acts on it: it lets the cluster truncate history, and the loss
becomes permanent. A frontier taken as a per-origin maximum would also hide the
loss, because a maximum merges past a hole.

Three mechanisms close the loss itself. The prefix bound makes visible whatever
is left.

### The watermark door

**Compaction** removes from the MST the prefix of operations that every member
has confirmed. That removal is a **truncation**, and a replica's **watermark**
records how far it has truncated. The rule "an operation at or below the
watermark has already been folded" is false for an operation a peer wrote while
a round was in flight. That operation sorts below the watermark, yet this
replica has never applied it.

`watermark_door/2` in `bondy_oplog_instance` runs after every merge and tests
application directly instead of inferring it from the watermark. It truncates
an operation at or below the watermark only when this replica has applied it and
every compaction witness confirms it (see
[The compaction witness rule](#the-compaction-witness-rule-and-the-truncation-cap)).
A never-applied operation stays:

- A fused instance folds it into the projection inline through
  `apply_cell_pairs_mux`, then truncates.
- An applier-backed instance holds it for the applier's replay and truncates
  strictly below the smallest held key.

The same door runs on the live-push path in `do_append_remote`. A
never-applied live operation at or below the watermark is installed like any
other, and an already-applied one is dropped as a duplicate. Both MST entry
paths deliver through the shared `deliver_remote/1`.

Counter: `bondy_oplog_doored_events_total`, labelled `action` (`folded` or
`held`). It counts the operations the door kept on the page-sync path. A steady
non-zero rate under sustained write load is expected, not an anomaly.

### Pinned roots

Pages pulled from a peer are unreachable from the local root until the session
integrates them. Between pull and integrate they look like garbage, and a page
collection that sweeps in that window removes them. `bondy_mst:merge/3` then
treats the missing subtree as empty and continues, so the round completes and
silently drops it.

A sync session therefore pins the root it pulls (`pin_peer_root/2`). A
successful integrate consumes the pin, and an unconsumed pin expires after 120
seconds. `truncate_below_or_equal/4` passes the pins to `bondy_mst:gc/2` as
roots to keep. `integrate_peer_root` also re-checks `missing_set/2` atomically
with the merge, in the same process as the page collection. When pages are
missing it answers the retryable `{error, {peer_pages_missing, N}}`, and the
session pulls again within its budget.

When a sweep finds the current root unservable for any other reason, it aborts
instead of sweeping around the hole and enlarging it. Counter:
`bondy_mst_gc_aborted_total`, labelled `classification` (`deleted`,
`tombstoned`, `transient`). The per-hash evidence outlives the log:
`bondy_oplog_instance:gc_aborts/0,1`.

### The compaction witness rule and the truncation cap

Compaction truncates only what it has evidence that every member holds. Each
cluster **member** is a **witness**, and its evidence is the durable frontier it
last reported, recorded in `bondy_oplog_peer_state`. This replica's own durable
frontier is a witness too. A member with no recorded frontier confirms nothing.
A durable frontier survives the member's own compaction, so two replicas that
both compact keep confirming each other's prefix
(`bondy_oplog_compaction_fused_test`: `peer_compaction_does_not_stall_ours`).
Reclamation of deleted data reads the same witnesses
(`confirmed_stability_point/2` in `bondy_oplog_instance`).

`finalize_catalogue_compaction/3` also caps the truncation point below the first
**never-applied** key at or below the frontier. A key is never-applied when its
`Seq` is above the applied frontier and its origin is not retired. A cycle can
therefore truncate less than its frontier allows, or nothing
(`{ok, no_change}`). The retired-origin exemption matters: the applier drops the
operations of a retired origin, so without the exemption the cap would hold
forever.

Counter: `bondy_oplog_compaction_holds_total`. Sustained growth means the
applier's replay is not keeping up with delivery for that instance. Convergence
stays protected, but disk does not. Check `bondy_oplog_wal_consumer_lag_bytes`
alongside it.

Every cluster member is a witness, on every database, `registry` included. A
member that is down or partitioned keeps the frontier it last confirmed, and
compaction does not truncate past it however long it stays silent. There is no
timeout (`bondy_oplog_peer_state_test`: `strict_read_ignores_recency`;
`bondy_oplog_compaction_fused_test`: `fused_compaction_waits_for_every_member`;
`bondy_oplog_compaction_cluster_SUITE`:
`silent_member_holds_compaction_and_rejoins`). A member that has never confirmed
holds compaction the same way. A member stops holding compaction only when it
leaves the cluster, through `bondy.cluster.leave` or `cluster.automatic_leave`
(see
[Clustering](../configuration/clustering.md#turning-clustering-off-for-a-member)).

Until then, history grows on every shard: on disk for `main`, in memory for
`registry`. For `registry`, the only bound is `db.registry.retention.*`, which
is off by default (see the
[database configuration reference](../configuration/database_options.md#registry-history-retention)).
Retention truncates by local policy, without the witnesses, so it is one of the
ways a hole forms ([How a hole forms](prefix_closure.md#how-a-hole-forms)).

## Detecting a replica that is behind

With those three mechanisms in place, a complete round that leaves the peer's
frontier strictly ahead of the local one after settle is evidence, not noise.
That outcome is a **frontier gap verdict**
(`bondy_oplog_frontier_gap_verdicts_total`, by instance and peer). Settle means
the instance's `await_apply` *and* `bondy_oplog_applier:barrier/1`. The instance
barrier alone drains only the overlay, not the applier. Without the applier
barrier, replay lag would raise a false verdict on almost every first sync.

A single verdict is still not actionable. When a peer door-*folds* an in-flight
operation, its applied frontier advances past what its truncated MST can serve.
A third replica whose complete round lands in that window records a deficit
that only the origin can cover, one round later. The origin cannot have
compacted that operation away, because compaction waits for the lagging
replica's durable frontier to cover it. The transient therefore heals by
itself.

`bondy_oplog_sync_scheduler` therefore debounces the verdict. A gap has to
strike twice for the same `(instance, peer)` inside the gap-strike window (120
seconds) before the remedy fires, and a successful round clears the count. A
standing gap cannot heal by syncing, so it strikes again on the next round.
Detection is delayed by one round, never lost.

The remedy is a **catalogue re-bootstrap**: the peer streams its whole
projection and the local one is re-derived (see [Re-bootstrap](#re-bootstrap)).
It is correct for the case that matters, because history compacted past this
replica is gone and no amount of syncing recovers it. It is also expensive,
which is why a transient never triggers it. Counter:
`bondy_oplog_rebootstraps_scheduled_total`.

Frontier **adoption** is separate and stricter. A replica adopts a peer's
frontier only when it finalizes a bootstrap, or on a complete round with no
deficit. Adopting a peer's frontier on any other live round would claim
operations the replica never applied.

### Unservable own root

A replica whose own tree has lost pages can neither serve its root nor repair
by pulling. While its compaction walk meets a missing page, its compaction
truncates nothing: it cannot tell whether the members hold what it cannot read.
Its peers recover what it applied from its projection by re-bootstrap, after
three consecutive refusals inside the gap-strike window while its frontier is
ahead of theirs.

Once every member's durable frontier covers what the replica applied, its
compaction rebuilds the tree: it truncates the tree through its ordinary
compaction, but never past the first operation the replica has not applied.
When the truncation leaves no lost page, anti-entropy resumes on the tree.
Counter: `bondy_oplog_mst_rebuilt_total`. An operation that sat on a lost page
and was not applied comes back from the peers that hold it.

`bondy_oplog_mst_rebuilt_total` is zero on a healthy cluster. Any occurrence
means pages went missing, and that is the question to chase, not the rebuild.

## Re-bootstrap

A re-bootstrap replaces the state of one shard with a peer's snapshot of that
shard. The scheduler dispatches one when:

- a frontier gap stands (two strikes, above);
- a peer cannot serve pages this replica needs, because it reclaimed
  them;
- a peer's root is persistently unservable while its frontier is ahead;
- a shard holds the re-fold mark (below) with no session left to clear it.

### Staging

The session streams the peer's snapshot into `catalogue_install.spool` in the
WAL directory of the shard. The projection does not change until the stream
ends. The spool grows to the encoded size of the peer's snapshot of that shard.
It is deleted when the install is written or abandoned. A spool left by a crash
is deleted when the next install on the shard begins. For the location of the
WAL directory, see
[Platform directories](../deployment/platform_directories.md#install-spool).

### Installing

When the stream ends, the folding process of the shard does the following in
one call, so that no other write folds between the steps:

1. Every snapshot cell replaces the local cell, whatever its HLC. A local cell
   is deleted when the snapshot covers its table but does not contain the cell
   (`bondy_oplog_bootstrap_rederive_test`:
   `cell_the_snapshot_lacks_is_pruned`, `empty_source_table_prunes_every_cell`).
   Deletions count as `bondy_oplog_bootstrap_cells_total{result="pruned"}`. A
   table for which the source has no table keeps its cells
   (`table_the_source_lacks_keeps_its_cells`).
2. The applied frontier is set to the frontier the peer reported before the
   stream when every cell it shipped was installed, and to an empty frontier
   otherwise.
3. The shard re-folds its retained local history. The operations that frontier
   does not claim are folded onto the installed cells, so local writes the peer
   had not received are kept (`failed_stream_keeps_the_local_add`,
   `keeps_local_add_when_the_trailing_round_fails`).

The session then reads the peer's frontier again and hands it to the shard,
which adopts it. The shard keeps the re-fold mark until its own frontier claims
that frontier. The first compaction tick after that writes a checkpoint without
the mark (`install_holds_until_claims_cover_source`). An ordinary sync round
follows.

### Failures

- A projection write that fails ends the install with
  `{projection_write_failed, Reason}`. The batches after it are not written,
  none of the peer's frontier is adopted, and the session fails
  (`failed_install_write_adopts_nothing`). The shard keeps the re-fold mark, so
  the scheduler dispatches another re-bootstrap.
- A stream that fails drops what it staged. The shard keeps the re-fold mark,
  and the scheduler dispatches another re-bootstrap.
- `{source_behind_truncation, Uncovered}` refuses the install before anything
  is written, when the peer's frontier does not cover operations this shard has
  truncated. Those operations are in neither the snapshot nor the local tree.
  The shard keeps serving and compacting
  (`install_behind_truncation_is_refused`). A refusal that repeats means both
  nodes truncated history on their own; see
  [Clustering](../configuration/clustering.md#turning-clustering-on-for-a-node-that-ran-with-it-off).
- A shard that is serving its own snapshot to a peer does not start an install.
  The session is refused with `{serving_snapshot, Id}` and retried later
  (`serving_replica_does_not_install`). Without this guard, two replicas that
  re-bootstrap from each other can each adopt a frontier the other's cells do
  not reflect (`proofs/tla/LiveRebootstrapRefold_NoServeGuard_TwoFaults.cfg`
  violates `ClaimSound`).

### The re-fold mark

The shard sets the mark when the install begins, before anything is staged. On
a `main` shard the mark is written to the frontier checkpoint. While the shard
holds the mark:

- it refuses to serve a snapshot or its frontier to a peer, with
  `{error, {refold_owed, Id}}` (`installing_source_refuses_to_serve`). After a
  restart it also refuses until its replay has presented every operation its
  frontier does not claim (`nothing_served_before_the_boot_replay`);
- compaction truncates nothing (`no_truncation_under_the_mark`), and
  `bondy_oplog:truncate_prefix/2` returns `{error, {refold_owed, Id}}`.

A node that crashes while a `main` shard holds the mark restarts that shard
with an empty applied frontier. It keeps only its truncation record and re-folds
the retained history of the shard. The scheduler then dispatches a re-bootstrap
(`restart_under_the_mark_keeps_truncated_claim`,
`crash_after_the_stream_keeps_local_add`,
`crash_before_finalize_keeps_no_stale_claim`;
`proofs/tla/LiveRebootstrapRefold_Proposed_Crash.cfg`).

## Frontiers that over-claim receipt

Releases up to and including `1.0.0-rc.lime` derived part of the applied
frontier at every start by folding the event keys of the live tree into it. The
tree records **receipt**, not materialisation, so an operation whose cell did
not resolve counted as applied. A frontier that such a release persisted can
therefore assert an applied prefix over an operation that never reached the
projection.

An instance that restores one of those checkpoints raises
`bondy_oplog_frontier_receipt_derived` (major, does not affect readiness). The
alarm names the instance and the remote origins whose entries are suspect. The
own-origin entry is not suspect: a local write folds before its operation is
minted, so the same derivation is sound for it.

The alarm reports a **loss of detection**, not a loss of data. The node serves
exactly what it served before the upgrade. What it cannot do reliably is
notice that it is behind, because the suspect entries are the ones the deficit
check reads (see [Detecting a replica that is behind](#detecting-a-replica-that-is-behind)).
A replica that over-claims an origin reports no deficit for it, and so never
escalates to a re-bootstrap.

There is no in-place repair, and the alarm does not offer one. Both available
moves fail:

- *Keep the value.* No merge lowers an entry, so nothing later corrects it.
- *Drop the suspect entries.* The compacted prefix cannot be re-derived
  locally, so the entry returns to zero, not to its true value. The sequence
  numbers still held in the live tree become a permanent gap above it. That
  trades a silent over-claim for a standing hole that only a re-bootstrap
  closes.

The sound remedy replaces the value: the affected instance's data directory is
removed while the node is stopped, and the instance bootstraps from a peer.
Provenance is sticky. A node that inherits a suspect frontier stamps every
checkpoint it writes as suspect, so one clean shutdown does not clear it.

## Recovery timing

Recovery has three stages, and each costs more than the last:

| Situation | What has to happen | Bounded by |
|---|---|---|
| Ordinary lag | One sync round for that instance | `db.aae.interval`, times the ticks the instance waits for a slot under `db.aae.max_concurrency`, plus transfer |
| Standing gap | Two complete rounds to strike twice, then the remedy | Two rounds plus settle |
| Re-bootstrap | Full projection transfer for the instance | Instance size |

A replica that has just returned from a fault and still lacks operations is
normally inside the detection window, not faulty. The signal worth an alert is
the *persistence* of disagreement, not its presence: a verdict rate that stays
non-zero for one `(instance, peer)`, or a re-bootstrap count that keeps climbing
for the same pair.

## See also

- [Understanding per-origin prefix closure](prefix_closure.md) — the ordering
  property the fold enforces, and the `bondy_oplog_events_held_total` and
  `bondy_oplog_prefix_holes_total` signals.
- [Deletion and reclamation](deletion_and_reclamation.md) — the other decision
  that the member witnesses license.
- [Reclamation options](../configuration/reclamation_options.md) — retirement
  and reclamation tunables.
