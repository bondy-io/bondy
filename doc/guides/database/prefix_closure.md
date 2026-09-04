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

- The **applied frontier** — the per-origin maximum `Seq` a replica has
  applied — is the convergence oracle: equal frontiers on two replicas are
  taken to mean the same operations were applied. A maximum identifies a set
  only when the set is a prefix.
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
tree. Folding that batch applies operation 7 over missing 5 and 6, and the
applied frontier — a per-origin *maximum* — advances to 7 with nothing left
to flag the hole.

This is not hypothetical: the interleaving was found by model-checking the
anti-entropy layer, then reproduced on a live cluster before the enforcement
existed. The machinery in this document is what that finding produced.

## The hold

The replay that folds synced operations into a table's materialised state
enforces closure at the fold. Each batch is partitioned per remote origin
into the contiguous run rising from that origin's applied frontier and the
non-contiguous remainder. The run folds; the remainder is **held**:

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

Four counters, all labelled by instance:

- `bondy_oplog_events_held_total` — operations a replay held. A burst on a
  replica rejoining after truncation is the mechanism working; a sustained
  rate on a healthy cluster means a gap is not filling and the rebootstrap
  chain deserves a look.
- `bondy_oplog_prefix_holes_total` — contiguity gaps that *materialised*
  into a fold. Only transient own-origin gaps from concurrent local commit
  reordering should register; exclude those before alerting. Any
  remote-origin count is a fold path the hold does not cover and warrants
  investigation.
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
addition the writer never saw. The frontier is a per-origin maximum, so it
cannot represent a hole and cannot report one either: the loss is silent.

The one cost of enforcement is that a permanently missing operation becomes a
catalogue rebootstrap instead of a silent gap — a repair, in place of a loss.

## See also

- [Understanding convergence in bondy_db](convergence.md) — the sync round, the
  watermark door, the compaction witness rule, and how the gap verdict escalates
  to that rebootstrap.
- [Deletion and reclamation](deletion_and_reclamation.md) — the other decision
  causal stability licenses.
