# Storage Rationale: Invariants and Verification

The storage stack's correctness argument, stated as the small set of
invariants the views rely on, with the method by which each is checked.
This is the page to read before modifying anything the other views name,
and the page an evaluator reads to judge how much of the design is proven
rather than asserted.

## The invariant stack

Each invariant assumes the ones above it; together they carry the stack's
one-sentence guarantee — *replicas that hold the same event set hold the
same values, the event sets converge, and forgetting never changes a
value*.

| # | Invariant | Where enforced | How checked |
| --- | --- | --- | --- |
| 1 | **Clock monotonicity.** Each instance's HLC is strictly monotone and, after receiving any timestamp, exceeds it forever after — so local events always sort after everything already received. | The HLC's two CAS steps, including the logical-overflow clamp | Mechanized proof (Isabelle/HOL) |
| 2 | **Sequence density.** An origin's minted sequence numbers are contiguous: ranges are reserved atomically and returned on WAL rejection when still topmost; an unreturnable range is counted and backfilled with signed no-op `seq_fill` events that occupy the seqs everywhere while folding to nothing. | The minting core, its rollback, and the backfill | Property tests; burn counter validated at zero under record load; backfill covered end to end (local install and cross-replica sync) |
| 3 | **Deterministic interpretation.** Every event folds through one materialisation path via its table's CRDT module; the same event set yields the same projection on every replica. | `cell_apply` as the single fold | The behaviour's stated determinism contract; property tests per CRDT (permutation, idempotent redelivery, oracle equivalence) |
| 4 | **Per-origin prefix closure.** No replica materialises an origin's later event while an earlier one is missing; the applied frontier counts only contiguous prefixes. This is the hypothesis under which the observed-remove test (`Ctx[O] ≥ S`) is exact. | The prefix hold at the fold, on every path with re-presentation; instrumented on the paths without | Exactness: mechanized proof. The hypothesis itself: model-checked (TLA+ — violated unenforced, exhaustively clean with the hold), cluster-tested in both polarities, field-validated with fault injection |
| 5 | **Whole-round confirmation.** A sync round records nothing unless it completed against the peer's whole tree; every cluster-wide license reads only confirmations. | The sync session's single checkpoint site | Cluster tests (stale-peer rejoin; truncation chase) |
| 6 | **Stability before forgetting.** Reclamation and compaction act only at or below a frontier certified by containment in every confirmed peer's tree — and the license extends exactly to clock-governed reductions, provably not to context-governed ones. | The stability point; each CRDT's `stabilize/2` | Mechanized proof of the stability theorem and of the license boundary (with the refuting counterexample machine-checked) |
| 7 | **Repair completes the trade.** Where the recency filter lets history be forgotten past a silent replica, the hold + honest frontier + gap verdicts + rebootstrap chain restores convergence without silent loss. | Scheduler escalation; catalogue install | Model-checked with the hold; cluster-tested end to end; field-validated (two-minute node kill at record load: zero silent gaps, self-heal in ~3 min) |
| 8 | **Folds run where the pages live.** A store whose pages are read through a process-bound resource — the pack store's raw sealed-pack file descriptors — may be folded only by the process that opened it; every cross-process consumer (cold replay, catalogue catch-up, the reclamation cell directory) delegates the fold to the owner. The store *declares* the constraint (`process_bound_reads` capability) rather than consumers inferring it from the backend's identity, and memory backends fold in the caller so the constraint never taxes them. | The store capability; the owner-side delegating calls (`bondy_oplog_instance:replay_pairs/2`, `cell_directory/1`) | Regression tests proven red without the delegation (cold replay; GC sweep, each reproducing `not_on_controlling_process`); the ephemeral counterpart pinned caller-side by a suspended-owner test |

## Why the proofs sit where they do

The mechanized effort concentrates on invariants 1, the exactness side of
4, and 6 — the clock, the observed-remove test, and the forgetting
license — because these are the properties whose violation is *silent*:
nothing crashes, replicas agree, and the wrong value survives. Everything
that fails loudly (a crashed process, an incomplete round, a refused
topology) is left to supervision and tests, which handle loud failures
well. The model checker owns invariant 4's *reachability* question because
interleavings of truncation, lag, and rejoin defeat both intuition and
example-based testing — the violating interleaving was found by the model
first, confirmed on hardware second.

## Failure design in one paragraph

Every process in these views restarts clean under supervision, and every
restart has a resupply path that assumes nothing about the failed run: the
log replays, the projection re-derives, the ephemeral database refills from
peers, the lagging node rebootstraps. Backpressure is explicit at every
boundary (admission caps on the log's overlay, node-wide page budgets in
sync, concurrency caps on sessions and GC), and where the stack cannot keep
a promise it refuses loudly — a topology mismatch, an unservable page, a
frontier it cannot back — rather than approximating.

## Standing limits

- Cross-node reads are eventually consistent; the stack's freshness
  exception (authentication) is fenced above it, not hidden inside it.
- The prefix hold does not cover folds with no re-presentation path (the
  compaction catch-up, one-shot re-derivations); these are instrumented
  (`bondy_oplog_prefix_holes_total`) rather than enforced.
- A burned sequence range is backfilled by the origin with no-op events;
  only a backfill that itself fails after retries leaves a gap, which then
  converts into a rebootstrap on peers — noise traded for correctness.
  Burns measured at zero in validation.
- Model-checking of the hold is exhaustive at pairwise scope; the
  three-replica space is beyond practical bounds. The protocol is
  pairwise, and the cluster tests run three nodes.

## Related

- [Storage roadmap](db_architecture.md) · [Per-origin prefix closure](../database/prefix_closure.md) · [Deletion and reclamation](../database/deletion_and_reclamation.md) · [Platform rationale](architecture_rationale.md)
