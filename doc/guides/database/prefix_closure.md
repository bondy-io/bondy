# Understanding per-origin prefix closure in bondy_db

Every replicated `bondy_db` table converges because every replica eventually
applies the same set of operations. The observed-remove (add-wins) tables need
something stronger: each replica applies the operations of any single origin as
an unbroken prefix. Operation 7 never lands where operations 5 and 6 are
missing. This property is **per-origin prefix closure**, and the fold enforces
it unconditionally.

This document explains what breaks without the property, how a hole forms, how
the fold holds operations back, and how the repair and its signals behave in
operation. It uses the terms that
[Understanding convergence](convergence.md) defines: instance, replica, member,
applied frontier, durable frontier, watermark, compaction and truncation. The
code calls an operation an *event*; this document says *operation* throughout.

## Why a prefix matters

Each operation carries a key `{HLC, Origin, Seq}`: a hybrid logical clock, the
identity of the replica that minted it, and a sequence number that increases
monotonically per origin. Two mechanisms read `Seq` as if the applied set had
no holes.

The first is the **applied frontier**, the per-origin `Seq` a replica reports as
applied. Replicas compare it to decide convergence: equal frontiers are taken to
mean that the same operations were applied. One number identifies a set only
when the set is a prefix. The number a replica reports is therefore a *prefix
bound*, the largest `Seq` below which nothing is missing. Operations folded
above a hole are not discarded. The replica keeps them in a per-origin pending
set and absorbs them into the bound when the hole closes. Until then it does not
report them, because that report would claim operations the replica does not
have.

The second is the observed-remove tables. They decide "did the writer of this
remove observe that add?" with a compact test: the add's dot `{Origin, Seq}`
counts as observed when the remove's context holds `Ctx[Origin] >= Seq`. The
test is exact only under prefix closure. With a hole beneath the maximum, a
skipped add is misreported as observed. The remove then deletes an add its
writer never saw. That loss is silent and convergent: every replica agrees on
the wrong value.

## How a hole forms

Anti-entropy is pull-only. A replica integrates a peer's tree only once it holds
every page of that tree. Compaction truncates only history that every cluster
member has confirmed, however long a member has been silent, so it opens no
hole for a member (see
[The compaction witness rule](convergence.md#the-compaction-witness-rule-and-the-truncation-cap)).
A hole forms where a replica meets a truncation it did not witness:

- registry retention (`db.registry.retention.*`) truncates by local policy,
  without the witnesses;
- a replica that joins after the members truncated was never one of their
  witnesses.

The hazardous interleaving has three steps:

1. A replica falls silent, or has not joined yet.
2. The other replicas write, and then truncate past operations that replica
   never pulled.
3. The other replicas keep writing, so their trees keep the later operations of
   those origins.

When the replica integrates a peer's tree, it receives the later operations
while the earlier ones are gone from every tree it can reach. A fold of that
batch applies operation 7 over missing 5 and 6. That is the hole. A frontier
that took the maximum would advance to 7 and leave nothing to flag the hole, and
that is what would make it *silent*. The rest of this document removes both
halves: the fold holds where it can, and an operation it does fold above a hole
is recorded but not claimed.

A hole also forms when no replica falls silent. An instance multiplexes several
tables onto one operation log. The first table opened on it founds the
instance, and sibling tables register as they open. The set of buckets the
instance can route therefore *grows while the instance already serves
anti-entropy*. An operation addressed to a table that has not registered cannot
be folded, because there is no materialised state to fold it into. That is a
hole in the same sense, and it is the ordinary one: it needs no truncation and
no unreachable replica, only a restart.

## The hold

The replay that folds synced operations into a table's materialised state
enforces closure at the fold. It partitions each batch, per remote origin, into
the contiguous run that rises from the origin's applied frontier, and the
remainder. The run is drawn only from operations the instance can route, so an
unregistered bucket stops it exactly as a missing sequence number does. Both
causes of a hole are one case here. An operation whose causal context names an
operation not yet applied is held too (`bondy_oplog_cell_apply`,
`partition_contiguous/4`; `proofs/isabelle/Aw_Kernel.thy`,
`causal_hold_delivers_causally`).

The run folds, and the remainder is **held**:

- The fold excludes held operations, so no table state reflects an operation
  whose predecessors are missing.
- The frontier advance excludes held operations, so the applied frontier never
  counts past a hole.
- The replay keeps its cursor instead of advancing past the batch, so held
  operations are presented again on the next replay. A re-fold is idempotent,
  and a gap that fills in the meantime folds through on the next pass.

Holding applies only where a path exists that presents the operations again. A
full re-derivation of the projection has no cursor. On that path a hold would be
a silent drop, so the path folds without holding and relies on the
`bondy_oplog_prefix_holes_total` detector (see [Observing it](#observing-it)).
Compaction is not a fold path. It truncates only operations that every member's
durable frontier confirms, and it caps its truncation point below any operation
this replica has not applied. A replica's own operations are never held; a
transient gap among them counts in `bondy_oplog_prefix_holes_total` instead.

## Readiness, and why the hold does not replace it

The hold is honest about a hole it cannot avoid. It does not stop the hole from
forming, and on one path honesty is not enough.

A replica that joins a cluster does not replay operations. It installs the
peer's materialised cells, which carry a key and a value but no origin and no
sequence number. Nothing in a shipped cell gives a per-origin bound, so the
joiner can only adopt the peer's applied frontier or adopt nothing. If its own
routing directory was incomplete during the install, it skipped the cells of the
unregistered tables, and a wholesale adoption claims them anyway. The same gap
runs the other way. The snapshot a replica *serves* lists the tables that have
registered, so a partially registered peer ships an incomplete catalogue while
it still reports its whole frontier.

Two mechanisms close this gap, one per direction, and **neither subsumes the
other**. TLC finds an over-claim when either one is removed
(`MuxBucketSkip_Minus_ServeGate`, `MuxBucketSkip_Minus_AdoptIfComplete`).

The serving direction is removed at the cause. An instance does no bootstrap
work, in either direction, until the catalogue has opened every table it
declares. *Declared* is the operative word: a bucket of a table this build does
not declare was never expected here, so the gate is bounded and always reached.

The installing direction cannot be removed at the cause. Its residue is a cell
for a table this build does not declare, which is exactly what the gate cannot
wait for. The claim is withheld instead. The install reports the buckets it
could not route, and the replica adopts the peer's frontier only when that set
is empty. Refusing the bootstrap outright is also sound, but it is the wrong
trade. The condition never resolves by itself, so the replica would retry
forever and never receive the data it *can* route. Withholding installs
everything routable and declines to claim what the replica does not hold.

A withheld claim leaves the replica behind that peer. The replica raises a
frontier gap verdict and re-bootstraps about once per sync interval. That cycle
is intended, not a loop to suppress. The catalogue install is the only writer of
applied state that does not pass through the fold, so it is the only delivery
path for the operations the hold parks. An operator ends the cycle, which is why
the condition raises `bondy_oplog_bucket_unroutable` with the buckets to
declare.

Readiness removes one cause. The withheld claim bounds what readiness cannot
remove. The hold bounds what remains. None substitutes for another.

## The repair chain

A held remainder means a peer applied operations that this replica cannot
obtain by page sync, because the pages are truncated on every replica it can
reach. The hold does not repair that. It makes the existing repair fire
deterministically:

1. The frontier does not advance past the hole, so the peer's frontier stays
   ahead after every complete sync round.
2. The session ends with a frontier gap verdict.
3. Two consecutive verdicts schedule a **catalogue re-bootstrap**: the replica
   reinstalls the peer's materialised cells and adopts its frontier.

The re-bootstrap supplies the missing values and the frontier in one act. Held
operations at or below the adopted frontier become ordinary re-folds. For the
debounce and the install itself, see
[Detecting a replica that is behind](convergence.md#detecting-a-replica-that-is-behind)
and [Re-bootstrap](convergence.md#re-bootstrap).

The frontier half is conditional on the install landing everything the peer
shipped (see [Readiness](#readiness-and-why-the-hold-does-not-replace-it)). When
it does not, the values still arrive, the frontier is withheld, and the chain
repeats instead of completing.

The one input a re-bootstrap cannot recover is a sequence number that no
replica holds: a *burned* seq. A seq burns when its write-ahead append fails
after a concurrent reservation landed on top of it. The mint path returns the
sequence range of a rejected batch to the counter whenever that range is still
the topmost reservation. A burn therefore needs a lost race against a concurrent
writer during a storage failure.

When a burn occurs, the origin repairs it. It backfills each burned seq with a
signed **`seq_fill`** operation: a no-op that occupies the sequence number,
replicates like any operation, and advances every replica's frontier past the
gap while it folds to nothing. Peers never see the burn. A backfill that itself
fails, after retries against the same backpressure that caused the burn, leaves
the gap to the re-bootstrap chain above.

## Observing it

Two gauges and four counters, all labelled by instance, report on prefix
closure. The gauges say what is true **now**; the counters say what happened.

- `bondy_oplog_instance_frontier_holes` — the number of holes the instance
  carries now. It is `0` on a healthy replica. It reads the per-origin pending
  sets directly, so it reports the standing condition instead of inferring it.
- `bondy_oplog_instance_frontier_pending_seqs` — the operations folded above
  those holes and therefore not reported yet. It grows with traffic behind a
  stuck hole while the hole count does not, so the ratio of the two says how far
  past the hole the instance has run.

A hole that persists longer than `db.frontier.hole_alarm` (default 5 minutes,
`0` disables) raises `{bondy_oplog_frontier_hole, InstanceId}`. Its details name
the origins, the sequence number where each gap starts, and how much is stranded
above it. The alarm is on the *age* of the condition, not its occurrence:
short-lived holes are routine.

- `bondy_oplog_events_held_total` — operations a replay held. A burst on a
  replica that rejoins after truncation is the mechanism working. A sustained
  rate on a healthy cluster means a gap is not filling, and the re-bootstrap
  chain needs a look.
- `bondy_oplog_prefix_holes_total` — contiguity gaps that *materialised* into a
  fold, counted in operations. Only transient own-origin gaps, from concurrent
  local commits that reorder, are expected; exclude those before you alert. Any
  remote-origin count is a fold path the hold does not cover and needs
  investigation. The counter counts what a fold found *absent*, so an operation
  already folded above the hole is not counted twice: presence is the reported
  bound plus the pending set, not the bound alone.
- `bondy_oplog_seqs_burned_total` — sequence numbers that a rejected append
  could not return to the counter. The origin backfills each one immediately.
- `bondy_oplog_seqs_filled_total` — burned seqs whose `seq_fill` backfill landed
  durably. In healthy operation it equals the burn counter. A persistent
  shortfall is a permanent gap that becomes a re-bootstrap on peers.

The frontier gap verdict and re-bootstrap counters,
`bondy_oplog_frontier_gap_verdicts_total` and
`bondy_oplog_rebootstraps_scheduled_total`, complete the picture. A hold episode
shows as held operations, then gap verdicts, then a scheduled re-bootstrap, then
quiet.

## Why it is not optional

Without enforcement, a rejoining replica integrates a peer's truncated history
as it is, and the applied frontier merges past any hole by maximum. The
exactness argument for observed-remove tables then fails: a remove can drop an
add its writer never saw. A single per-origin maximum cannot represent a hole,
so it cannot report one either. The loss is silent, and every replica agrees on
the wrong value. The prefix bound and its pending set replace that maximum. The
bound stops below the hole, and that stop is what makes the condition visible
to the frontier comparison at all.

The one cost of enforcement is that a permanently missing operation becomes a
catalogue re-bootstrap instead of a silent gap: a repair in place of a loss.

## See also

- [Understanding convergence in bondy_db](convergence.md) — the sync round, the
  watermark door, the compaction witness rule, and how the frontier gap verdict
  escalates to a re-bootstrap.
- [Deletion and reclamation](deletion_and_reclamation.md) — the other decision
  that the member witnesses license.
