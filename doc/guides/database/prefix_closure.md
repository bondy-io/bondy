# Understanding per-origin prefix closure in bondy_db

Every replicated `bondy_db` table converges because every replica eventually
applies the same set of operations. The observed-remove (add-wins) tables rely
on something stronger: that each replica applies any single origin's
operations as an unbroken prefix — operation 7 never lands where operations 5
and 6 are missing. This property is **per-origin prefix closure**, and the
fold enforces it unconditionally. This document explains what breaks without
it, how the hold works, and how its repair chain and metrics behave in
operation.

## Why a prefix matters

Each operation carries a key `{HLC, Origin, Seq}`: a hybrid logical clock, the
identity of the replica that minted it, and that origin's monotonically
increasing sequence number. Two mechanisms read `Seq` as if the applied set
had no holes:

- The **applied frontier** — the per-origin `Seq` a replica reports as
  applied — is the convergence oracle: equal frontiers on two replicas are
  taken to mean the same operations were applied. One number identifies a set
  only when the set is a prefix, so the number a replica reports is a *prefix
  bound*: the largest `Seq` below which nothing is missing. Operations folded
  above a hole are not discarded — they are kept in a per-origin pending set
  and absorbed into the bound the moment the hole closes — but until then they
  are not reported, because reporting them would be a claim about operations
  the replica does not have.
- The observed-remove tables decide "did the writer of this remove observe
  that add?" with a compact test: the add's dot `{Origin, Seq}` counts as
  observed when the remove's context holds `Ctx[Origin] >= Seq`. The test is
  exact only under prefix closure. With a hole beneath the maximum, a skipped
  add is misreported as observed, and the remove deletes an add its writer
  never saw — a silent, convergent loss: every replica agrees on the wrong
  value.

## How a hole forms

Anti-entropy is pull-only: a replica integrates a peer's whole tree once it
holds every page of that tree. Compaction, meanwhile, truncates history that
every *confirmed* peer has applied — and the confirmation set is
recency-filtered, so a replica silent past `db.aae.peer_timeout` no longer
holds truncation back.

The hazardous interleaving needs three steps. A replica falls silent; the
live peers write and then truncate past operations the silent replica never
pulled; the peers keep writing, so their trees retain those origins' later
operations. When the silent replica rejoins and integrates a peer's tree, it
receives the later operations with the earlier ones gone from every live
tree. Folding that batch applies operation 7 over missing 5 and 6. That is the
hole; what made it *silent* was a frontier that took the maximum, advanced to
7, and left nothing to flag it. The rest of this document is the machinery
that removes both halves — the fold holds where it can, and what it does fold
above a hole is recorded rather than claimed.

This is not hypothetical: the interleaving was found by model-checking the
anti-entropy layer, then reproduced on a live cluster before the enforcement
existed. The machinery in this document is what that finding produced.

A hole also forms with no peer ever falling silent. A shard instance
multiplexes several tables onto one operation log, and the first table opened
on it founds the instance; siblings register as they open, so the set of
buckets the instance can route *grows while it is already serving
anti-entropy*. An operation addressed to a table that has not registered yet
cannot be folded — there is no materialised state to fold it into. That is a
hole in exactly the sense above, and it is the ordinary one: it needs no
truncation and no unreachable replica, only a restart.

## The hold

The replay that folds synced operations into a table's materialised state
enforces closure at the fold. Each batch is partitioned per remote origin
into the contiguous run rising from that origin's applied frontier and the
remainder. The run is drawn only from operations the instance can route, so
an unregistered bucket stops it exactly as a missing sequence number does:
both causes above are one case here. The run folds; the remainder is
**held**:

- Held operations are excluded from the fold, so no table state ever
  reflects an operation whose predecessors are missing.
- Held operations are excluded from the frontier advance, so the applied
  frontier keeps telling the truth — it never counts past a hole.
- The replay keeps its cursor instead of advancing past the batch, so held
  operations re-present on the next replay. Re-folding is idempotent; a
  gap that fills in the meantime folds through on the next pass.

Holding applies only where a re-presentation path exists. A full
projection re-derivation has no cursor at all; on that path a hold would be
a silent drop, so it folds as before and relies on the detector below.
Compaction is not a fold path: it truncates only operations the applied
frontier already witnesses, and holds its truncation point below anything
still un-applied. A replica's own operations are never held: the local
write-ahead log delivers them in sequence order already.

## Readiness, and why the hold does not replace it

The hold is honest about a hole it cannot avoid. It does not stop the hole
forming, and on one path being honest is not enough.

A replica joining a cluster does not replay operations — it installs the
peer's materialised cells, which carry a key and a value but no origin or
sequence number at all. There is nothing in a shipped cell from which to
derive a per-origin bound, so the joiner can only adopt the peer's applied
frontier or adopt nothing. If its own routing directory was incomplete while
it installed, the cells for the unregistered tables were skipped and a
wholesale adoption claims them anyway. The same gap runs the other way: the
snapshot a replica *serves* enumerates the tables that have registered, so a
partially registered peer ships an incomplete catalogue while still reporting
its whole frontier.

Two mechanisms close this, one per direction, and **neither subsumes the
other** — removing either one alone is a proved over-claim
(`MuxBucketSkip_Minus_ServeGate`, `MuxBucketSkip_Minus_AdoptIfComplete`).

The serving direction is removed at the cause: a shard instance does no
bootstrap work, in either direction, until the catalogue has opened every
table it declares. Declared is the operative word — a bucket belonging to a
table this build has no declaration for was never expected here, so the gate
is bounded and always reached.

The installing direction cannot be removed at the cause, because that residue
— a cell for a table this build genuinely does not declare — is exactly what
the gate cannot wait for. So the claim is withheld instead: the install
reports the buckets it could not route, and the peer's frontier is adopted
only when that set is empty. Refusing the bootstrap outright is also sound
and is the wrong trade: the condition never resolves on its own, so the
replica would retry forever and never receive the data it *can* route.
Withholding installs everything routable and simply declines to claim what it
does not hold.

A withheld claim leaves the replica behind that peer, which raises a
frontier-gap verdict and re-bootstraps roughly every sync interval. That is
the intended behaviour and not a loop to suppress: the catalogue install is
the only writer of applied state that does not pass through the fold, so it
is the sole delivery path for the operations the hold below parks. What ends
it is an operator, which is why the condition raises
`bondy_oplog_bucket_unroutable` naming the buckets to declare.

Readiness removes one cause; the withheld claim bounds what readiness cannot
remove; the hold bounds what remains. None substitutes for another.

## The repair chain

A held remainder means the peer applied operations this replica can no longer
obtain by page sync — the pages are truncated everywhere. The hold does not
repair that; it makes the existing repair fire deterministically. Because the
frontier no longer advances past the hole, the peer's frontier stays ahead
after every complete sync round, the session ends with a frontier-gap
verdict, and two consecutive verdicts schedule a **catalogue rebootstrap**:
the replica reinstalls the peer's materialised cells and adopts its frontier,
which supplies both the missing values and the bookkeeping in one act. Held
operations at or below the adopted frontier become ordinary re-folds.

The frontier half of that is conditional on the install landing everything the
peer shipped — see above. When it does not, the values still arrive and only
the bookkeeping is withheld, so the chain repeats rather than completing.

The one input a rebootstrap cannot recover is a sequence number that no
replica holds — a *burned* seq, minted for a write whose write-ahead append
failed after a concurrent reservation landed on top. The mint path returns a
rejected batch's sequence range to the counter whenever it is still the
topmost reservation, so burns require a lost race against a concurrent
writer during a storage failure; a validation run at full load measured
zero. When one does occur, the origin repairs it itself: it backfills each
burned seq with a signed **`seq_fill`** event — a no-op that occupies the
sequence number, replicates like any operation, and advances every replica's
frontier past the gap while folding to nothing. Peers never see the burn; a
backfill that itself fails (after retries against the same backpressure that
caused the burn) leaves the gap to the rebootstrap chain above.

## Observing it

Two gauges and four counters, all labelled by instance. The gauges say what is
true **now**; the counters say what happened.

- `bondy_oplog_instance_frontier_holes` — how many holes the instance is
  carrying right now. `0` on a healthy replica. This is the standing condition
  the rest of this document is about, read directly from the per-origin
  pending sets rather than inferred.
- `bondy_oplog_instance_frontier_pending_seqs` — operations folded above those
  holes and therefore not yet reported. It grows with traffic behind a stuck
  hole while the hole count does not, so the ratio says how far past the hole
  the instance has run.

A hole that persists longer than `db.frontier.hole_alarm` (default 5 minutes,
`0` disables) raises `{bondy_oplog_frontier_hole, InstanceId}`, whose details
name the origins, the sequence each gap starts at, and how much is stranded
above it. The alarm is on the *age* of the condition, not its occurrence:
short-lived holes are routine.

- `bondy_oplog_events_held_total` — operations a replay held. A burst on a
  replica rejoining after truncation is the mechanism working; a sustained
  rate on a healthy cluster means a gap is not filling and the rebootstrap
  chain deserves a look.
- `bondy_oplog_prefix_holes_total` — contiguity gaps that *materialised*
  into a fold, counted in operations. Only transient own-origin gaps from
  concurrent local commit reordering should register; exclude those before
  alerting. Any remote-origin count is a fold path the hold does not cover and
  warrants investigation. It counts what a fold found *absent*, so an
  operation already folded above the hole is not counted twice — presence is
  the reported bound plus the pending set, not the bound alone.
- `bondy_oplog_seqs_burned_total` — sequence numbers a rejected append could
  not return to the counter. Each is immediately backfilled.
- `bondy_oplog_seqs_filled_total` — burned seqs whose `seq_fill` backfill
  landed durably. Healthy operation keeps this equal to the burn counter; a
  persistent shortfall is a permanent gap that will convert into a
  rebootstrap on peers.

The `frontier-gap verdicts` and `re-bootstraps scheduled` counters complete
the picture: a hold episode shows as held events, then gap verdicts, then a
scheduled rebootstrap, then quiet.

## Why it is not optional

Without enforcement a rejoining replica integrates a peer's truncated history
as-is, the applied frontier max-merges past any hole, and the
observed-remove exactness argument no longer holds — a removal can drop an
addition the writer never saw. A single per-origin maximum cannot represent a
hole and so cannot report one either: the loss is silent, and every replica
agrees on the wrong value. That is what the prefix bound and its pending set
replace — the bound stops below the hole, which is what makes the condition
visible to the oracle at all.

The one cost of enforcement is that a permanently missing operation becomes a
catalogue rebootstrap instead of a silent gap — a repair, in place of a loss.

## See also

- [Understanding convergence in bondy_db](convergence.md) — the sync round, the
  watermark door, the compaction witness rule, and how the gap verdict escalates
  to that rebootstrap.
- [Deletion and reclamation](deletion_and_reclamation.md) — the other decision
  causal stability licenses.
