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
| 2 | **Sequence density.** An origin's minted sequence numbers are contiguous: ranges are reserved atomically and returned on WAL rejection when still topmost; unreturnable ranges are counted, not hidden. | The minting core and its rollback | Property tests; burn counter validated at zero under record load |
| 3 | **Deterministic interpretation.** Every event folds through one materialisation path via its table's CRDT module; the same event set yields the same projection on every replica. | `cell_apply` as the single fold | The behaviour's stated determinism contract; property tests per CRDT (permutation, idempotent redelivery, oracle equivalence) |
| 4 | **Per-origin prefix closure.** No replica materialises an origin's later event while an earlier one is missing; the applied frontier counts only contiguous prefixes. This is the hypothesis under which the observed-remove test (`Ctx[O] ≥ S`) is exact. | The prefix hold at the fold, on every path with re-presentation; instrumented on the paths without | Exactness: mechanized proof. The hypothesis itself: model-checked (TLA+ — violated unenforced, exhaustively clean with the hold), cluster-tested in both polarities, field-validated with fault injection |
| 5 | **Whole-round confirmation.** A sync round records nothing unless it completed against the peer's whole tree; every cluster-wide license reads only confirmations. | The sync session's single checkpoint site | Cluster tests (stale-peer rejoin; truncation chase) |
| 6 | **Stability before forgetting.** Reclamation and compaction act only at or below a frontier certified by containment in every confirmed peer's tree — and the license extends exactly to clock-governed reductions, provably not to context-governed ones. | The stability point; each CRDT's `stabilize/2` | Mechanized proof of the stability theorem and of the license boundary (with the refuting counterexample machine-checked) |
| 7 | **Repair completes the trade.** Where the recency filter lets history be forgotten past a silent replica, the hold + honest frontier + gap verdicts + rebootstrap chain restores convergence without silent loss. | Scheduler escalation; catalogue install | Model-checked with the hold; cluster-tested end to end; field-validated (two-minute node kill at record load: zero silent gaps, self-heal in ~3 min) |

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
- A burned sequence range converts a future silent gap into a rebootstrap
  on peers — noise traded for correctness, measured at zero in validation.
- Model-checking of the hold is exhaustive at pairwise scope; the
  three-replica space is beyond practical bounds. The protocol is
  pairwise, and the cluster tests run three nodes.

## Related

- [Storage roadmap](db_architecture.md) · [Per-origin prefix closure](../database/prefix_closure.md) · [Deletion and reclamation](../database/deletion_and_reclamation.md) · [Platform rationale](architecture_rationale.md)
