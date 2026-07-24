# Understanding deletion and reclamation in bondy_db

In a replicated, operation-based store, deleting a value and reclaiming its
space are two different acts, licensed by two different kinds of evidence.
Deletion is an ordinary operation: it converges across the cluster like any
other write, and it must leave a **tombstone** behind, because the tombstone is
the only thing that can reject a concurrent, older write arriving later.
Reclamation — physically removing the cell — is licensed only by **causal
stability**: proof that no operation old enough to care about the tombstone can
ever be delivered again. `bondy_db` keeps these two acts separate on purpose,
and this document explains the machinery that makes the second one safe.

## The problem: you cannot simply erase

Every `bondy_db` table is backed by an operation-based CRDT. Replicas converge
because every replica eventually applies the same set of operations, in any
order. Erasing a cell outright would break that: a replica that erased "user
alice" and then received a *concurrent* write to alice — one issued before the
delete was known — would resurrect her, because nothing would remain to say the
delete happened, or to compare timestamps against.

So a register's removal is itself an operation (`clear`), and applying it
leaves the cell in a `cleared` state carrying the removal's hybrid logical
clock (HLC). Readers see `{error, not_found}` immediately — a cleared cell and
an absent cell are indistinguishable through the read API — but the cell still
occupies a row. Its one remaining job is to reject any concurrent `set` with a
lower HLC that has not arrived yet.

Without reclamation, that row lives forever, and cell count grows monotonically
with every key ever written regardless of how many are live. The rest of this
document is about when the tombstone's job is provably finished.

## Deleting through the API

`bondy_db:delete/3` issues the removal operation the table's CRDT declares.
Callers never spell `apply(Table, Realm, Key, clear)` themselves; they state
intent and the fold supplies the mechanics.

```erlang
ok = bondy_db:delete(Table, RealmUri, Key),
{error, not_found} = bondy_db:read(Table, RealmUri, Key).
```

Whether — and when — the cell is physically reclaimed is the CRDT's business,
declared through two optional callbacks on the `bondy_oplog_crdt` behaviour:

- `removal_op/0` names the whole-cell removal operation. The LWW register
  returns `clear`. A CRDT that does not export it has no whole-cell removal,
  and `delete/3` returns `{error, {no_removal_op, Module}}` — a set or map
  removes its entries individually, and a counter has no removal at all.
- `stabilize/2` answers, for a given stability point, what remains of the
  cell's state: `keep`, `{keep, Reduced}`, or `discard`. The LWW register
  discards a tombstone whose HLC lies strictly below the stability point, and
  keeps a live value unconditionally — stability says nothing older can
  arrive; it does not say the value is unwanted.

Today the LWW register — the fold class of most catalogue tables — implements
both callbacks. A table whose CRDT declares neither simply retains its cells;
the sweep treats "no opinion" as "reclaim nothing", never the reverse.

## Causal stability: the licence to reclaim

A timestamp is **causally stable** at a node when every operation that could
ever still be delivered there is newer than it (Baquero, Almeida and Shoker,
*Pure Operation-Based Replicated Data Types*, arXiv:1710.04469, Definition
5.1). Once the tombstone's HLC is causally stable, the concurrent write it
exists to reject is impossible by construction, and the tombstone is pure
overhead.

Bondy derives stability from three ingredients, all of which run on the
ordinary anti-entropy (AAE) machinery:

**The confirmed-root swap.** When a node completes a pull from a peer, both
sides record the *same* root — the peer's advertised MST root, every page of
which the puller now demonstrably holds. This is the swap from McCrary's
*Canteen*: one shared object per peer pair, reached without any push path. A
root recorded this way is evidence about what *both* replicas hold, which is
what a stability computation needs; a node's own root would only measure its
own sync recency.

**The strict membership frontier.** The stability point for an instance is
computed against **every** member of the Partisan membership — including
currently unreachable ones — and a member leaves that set only by a
deliberate membership act, never by timeout. Each member must have a confirmed
root; the frontier is the newest local event covered by all of them, and its
HLC is the stability point. One silent member holds stability down for the
whole cluster. That is the correct trade: an unreclaimed tombstone costs disk,
while a wrongly reclaimed one costs data, permanently and silently.

**Absorbing clocks.** Every path that delivers remote events — live sync,
direct append, and catalogue-snapshot bootstrap — advances the local HLC past
the delivered timestamps. This is what upgrades "every replica already holds
these events" into "no replica can ever *mint* an event below this point": a
freshly bootstrapped replica's first write is guaranteed to sort after
everything it received in its snapshot.

A node with no members is the degenerate case: nothing can contradict it, so
everything it holds is stable, and a solo node reclaims against a fresh tick
of its own clock.

## The sweep

Reclamation is a sweep over the projection, executed inside the applier — the
sole writer to the projection — so a delete can never interleave with a
concurrent apply to the same cell. The sweep walks each registered table's
cells through that table's own CRDT kernel, asks `stabilize/2` for a verdict,
and physically removes discarded cells through the projection adapter, where
the storage engine's own compaction can finally reclaim the bytes.

Two guards apply to every discard:

- **The overlay fence.** A read of an absent cell replays pending events from
  the beginning of time, so removing a cell widens its replay window. The
  sweep discards a cell only when nothing at all is pending for its key.
- **The strict boundary.** A tombstone whose HLC *equals* the stability point
  is kept. Event keys order by HLC first and origin second, so a dot with the
  same HLC and a higher origin may still be unconfirmed — and at equal HLC the
  register's tie-break relies on the tombstone being materialised.

The boundary rule has a visible consequence worth knowing: a tombstone that is
the newest event on its shard stays in place until any later write lands on
that shard. Under ordinary traffic this is momentary; on an idle shard the
last tombstone persists, bounded to one cell. It is retained because the proof
requires it, not because the sweep missed it.

The sweep is bounded and resumable: each pass runs in batches of
`reclaim_batch_cells`, so concurrent writes interleave between batches rather
than waiting out a whole-shard scan. A scheduler
(`bondy_oplog_reclaim_scheduler`) drives passes on its own cadence, entirely
separate from — and much slower than — the compaction scheduler.

## Origins, retirement, and departed nodes

Because one silent member freezes reclamation, a *permanently* departed node
must be retired, and retirement is a deliberate membership act: removing the
node from the Partisan membership (`partisan_peer_service:leave/1`). The
moment the membership no longer contains the node, stability computes without
it. Nothing ages out on a timer — a node that is merely partitioned keeps its
seat, and keeps reclamation honest, until an operator decides otherwise.

Retirement has a second, subtler half. Bondy identifies a replica's *history*
by an **origin** — an opaque 128-bit identity minted with the replica's
storage and destroyed with it — precisely so that a node which loses its disk
and rejoins under the same name cannot collide with its own past (the failure
mode Riak's kv679 made famous). The corollary is that a node accumulates dead
origins over its lifetime, and their bookkeeping entries linger in cell
states.

The origin-retirement pass cleans these up by **complement**: it asks every
current member for the origins it presently claims — knowledge each node
authoritatively owns — and whatever appears in the local frontiers but is
claimed by nobody is a dead epoch, reaped from every table's cell states. The
pass is fail-closed: if any member cannot be queried, nothing is reaped and
the pass retries later. It runs automatically on membership changes and on a
slow periodic tick, the latter covering the case where an origin epoch turns
over with no membership change at all — a Kubernetes pod that loses its
volume and rejoins under the same name.

The pass deliberately never bans an origin on its own. Banning a live origin
would silently refuse its writes — divergence, not hygiene — and the
membership plane already refuses connections from non-members.

## Watching stability: stall reasons, recency, and the idle state

Reclamation fails silently in both directions — nothing visibly breaks
whether it is working or wedged — so every attempt that certifies no
stability reports why. The telemetry
(`bondy_oplog_reclamation_stalled_total`, labelled by instance and reason)
is emitted on every attempt; the log line naming the members involved is
rate-limited per instance. The reasons, and what each asks of you:

| Reason | Meaning | Action |
|---|---|---|
| `idle` | This replica's tree is empty: nothing to certify. | None. |
| `unconfirmed` | A member has never confirmed a root for this shard while this replica holds events. | Revive the member, or retire it via a membership removal. |
| `no_frontier` | Members confirmed, but no local event is covered by every confirmed root — typically a stale root from a member that has stopped syncing. | Same as `unconfirmed`. |
| `membership_unavailable` | The membership service cannot be read. | Investigate the node, not the peers. |
| `non_event_frontier` | The frontier computation returned a non-event key. | A bug; report it. |

Two distinctions behind this table are worth understanding, because both
exist to keep a converged, quiescent cluster *quiet*.

**Sync recency is not confirmation.** MST compaction truncates a fully
checkpointed tree, so the steady state of a shard nobody writes to is an
*empty* tree on every replica — and a sync round between two empty trees
completes with no root to swap. Such a round still refreshes the peer's
recency (`last_sync`, and the last-sync-age gauge built on it, stay
truthful), but it confirms nothing: only a concrete root is evidence about
what both replicas hold, so only a concrete root participates in
stability. A root confirmed *before* the peer compacted is kept — the peer
checkpointed that content, so preserving it is conservative — which is why
a peer's compaction never regresses the frontier.

**An empty tree has nothing to certify.** When this replica's own tree is
empty, no frontier over local events can exist by construction, and there
is no event whose stability needs certifying. Reporting that as
`unconfirmed` would be worse than noise: the prescribed remedy — revive or
retire the member — is wrong advice about members that are alive and
converged, and the repetition would bury the stalls that do need it. The
`idle` outcome names this state precisely, never reaches the warning log,
remains visible in the telemetry, and ends the moment a local event lands.

### A known, deliberate liveness gap

One narrow state is left unresolved by design, and it is worth stating
exactly. Suppose cells become reclaimable on a shard, and then the whole
cluster goes quiescent on that shard long enough for compaction to empty
every replica's tree *before* stability was ever certified past them. The
shard now reports `idle` on every node, and those cells sit unreclaimed —
correct, hidden from reads, but still occupying space — for as long as the
shard stays silent.

This is tolerated for three reasons. First, the asymmetry that governs this
whole design: an unreclaimed cell costs bytes, a wrongly reclaimed one
costs data, permanently and silently. Second, the state is bounded and
self-healing: the first write to the shard — on any node — regrows a root,
the next sync round confirms it, stability lands beyond the backlog, and
one sweep discards all of it. A shard that never receives that write is
also a shard whose leftover bytes never grow. Third, the sound fix is not a
patch. It would be a clustered analogue of the solo carve-out — "every
member confirmed-empty, therefore a fresh tick is stable" — and the solo
argument rests on clock domination over events *this* node minted or
absorbed, which does not transfer to other members without a new
argument bounding the HLCs a peer may still mint after its confirmed-empty
round. That is an extension to the stability theorem first, an
implementation second.

Two cheaper routes were considered and rejected. Ordering the collectors so
reclamation always runs before compaction cannot be guaranteed — compaction
can be licensed while stability is unreachable. And deferring compaction
while a reclamation backlog exists inverts the trade this design is built
on: a silent member would then block *compaction* too, turning bounded
projection bytes into unbounded log and tree growth.

## What could have been, and why not

Two simpler designs were rejected, and the reasons are instructive.

*Timeout-based peer exclusion.* The compaction machinery drops peers unheard
from for `peer_timeout_ms`, and for compaction that is right: a dropped peer
pays with a resync, not with correctness. Reclamation has no such fallback — a
peer dropped by timeout and returning later would resurrect deleted data — so
reclamation uses a strict, membership-supplied reading of the same table, and
the two readings are deliberately separate functions rather than one function
with a flag.

*Node names as origins.* Names are addresses; they outlive the state they
point at. Every system whose correctness rests on per-actor monotonic
counters has either separated the two from the start (Cassandra's host UUID,
etcd's member ids) or been forced to retrofit the separation after silent
data loss (Riak's per-key actor epochs). Bondy's random origins are that
lesson applied at design time, and the complement-based retirement is what
makes their opacity operationally free: nobody ever has to know which opaque
id belonged to which node.

## Consequences

- `delete/3` hides the value immediately and everywhere; space returns later,
  when stability licenses it. The two are decoupled by design.
- Reclamation is quiet when healthy and loud when stalled: a member that
  cannot confirm surfaces within one scheduler interval as telemetry naming
  the missing member, and as a rate-limited log line. An *actionable* stall
  is always a fact about membership, and the remedy is always a membership
  decision; the one non-actionable outcome — `idle`, the empty tree of a
  converged quiescent shard — is counted but never logged (see "Watching
  stability" above).
- Everything here is on by default. Every knob mentioned — including how to
  disable reclamation or retirement — is covered in the
  [reclamation configuration reference](../configuration/reclamation_options.md).

## See also

- [Reclamation configuration reference](../configuration/reclamation_options.md)
  — every option, default, and telemetry event.
- The generated module reference for `bondy_db` (`delete/3`),
  `bondy_oplog_crdt` (the `removal_op/0` and `stabilize/2` callbacks) and
  `bondy_oplog_origin` (origin identity).
