# Storage Rationale: Invariants and Verification

The storage stack's correctness argument, stated as the small set of
invariants the views rely on, with the evidence that checks each one. Read
this page before modifying anything the other views name. An evaluator reads
it to judge which parts of the design a proof, a model or a test checks, and
which parts rest on argument.

## The invariant stack

Each invariant assumes the ones above it. Together they are meant to carry
the stack's one-sentence guarantee: *replicas that hold the same event set
hold the same values, the event sets converge, and forgetting never changes a
value*.

The proofs are Isabelle/HOL theories under `proofs/isabelle/`; the models are
TLA+ specifications under `proofs/tla/`, each configuration (`.cfg`) naming
the invariants TLC checks. `proofs/README.md` indexes them with their scope
and the hypotheses each one assumes.

| # | Invariant | Where enforced | Evidence |
| --- | --- | --- | --- |
| 1 | **Clock monotonicity.** Each instance's HLC is strictly monotone and, after receiving any timestamp, exceeds it forever after, so local events sort after everything already received. | The two compare-and-swap steps of `bondy_connect_hlc` (local tick and peer merge), including the clamp on logical overflow | `proofs/isabelle/Hlc.thy`: `local_next_gt`, `peer_next_gt_peer`, `run_dominates_received` |
| 2 | **Sequence density.** An origin's minted sequence numbers are contiguous. Ranges are reserved atomically and returned on WAL rejection when still topmost; an unreturnable range is counted and backfilled with signed no-op `seq_fill` events that occupy the seqs everywhere and fold to nothing. The counter is seeded across restarts from the checkpoint, the tree and the retained WAL. | `bondy_oplog_instance` (minting, release, backfill) | `bondy_oplog_instance_seq_atomic_test:burned_range_is_backfilled_locally/0`; `bondy_oplog_seq_seed_restart_test`; `proofs/isabelle/Seq_Seed.thy`; `proofs/tla/SeqSeed.tla` |
| 3 | **Deterministic interpretation.** Every event folds through one materialisation path via its table's CRDT module, so the same event set is meant to yield the same projection on every replica. | `bondy_oplog_cell_apply`, shared by the applier and the fused instance | Per-CRDT property tests in `apps/bondy_oplog/test/*_proper_test.erl`, including `prop_permutation_invariant` and `prop_idempotent_redelivery` |
| 4 | **Per-origin prefix closure.** No replica materialises an origin's later event while an earlier one is missing on the replication path, and the applied frontier claims only what was folded. This is the hypothesis under which the observed-remove test (`Ctx[O] ≥ S`) is exact. | The prefix hold of the replication fold (`bondy_oplog_cell_apply`); instrumented, not enforced, on the paths with no re-presentation | Exactness: `proofs/isabelle/Dot_Exactness.thy` (`compact_test_exact`). The hold: `proofs/tla/AaeCausalClosure_Shipped.cfg` and `_Shipped_3R.cfg` check `PrefixClosed`, with `AaeCausalClosure.cfg` as the ablation that turns the hold off. On a cluster: `bondy_oplog_compaction_cluster_SUITE:truncated_prefix_is_held_and_repaired_by_rebootstrap/1` |
| 5 | **Whole-round confirmation.** A sync round records the peer's durable frontier only when it completed against the peer's whole tree, and every cluster-wide license reads only those records. | `bondy_oplog_sync_session` | Exercised end to end by `bondy_oplog_compaction_cluster_SUITE:silent_member_holds_compaction_and_rejoins/1`; no test isolates an incomplete round |
| 6 | **Confirmation before forgetting.** Compaction and reclamation act only at or below the largest key that every member's durable frontier covers, and the reclamation license extends to clock-governed reductions only. | The stability frontier (`bondy_oplog_instance`); each CRDT's `stabilize/2` | `proofs/isabelle/Confirmed_Compaction.thy` (`no_loss`, `no_drop`); `proofs/tla/ConfirmedCompaction.tla` (`_3R.cfg`, `_3R_Partition.cfg`); `proofs/isabelle/Stabilization.thy` (`hlc_governed_reduction_sound`) and `proofs/isabelle/Aw_Counterexample.thy` (`aw_fold_not_sound_above`) for the license boundary; `bondy_oplog_compaction_fused_test:fused_compaction_waits_for_every_member/0` |
| 7 | **Repair completes the trade.** Where registry retention lets history be forgotten past a silent replica, the hold, the honest frontier, the gap verdicts and the rebootstrap are meant to restore convergence without silent loss. | Scheduler escalation (`bondy_oplog_sync_scheduler`); catalogue install and re-fold (`bondy_oplog_applier`) | `bondy_oplog_compaction_cluster_SUITE:truncated_prefix_is_held_and_repaired_by_rebootstrap/1`; `proofs/tla/JoinInstall.tla` and `proofs/tla/LiveRebootstrapRefold.tla` for the install and re-fold |
| 8 | **Folds run where the pages live.** A store whose pages are read through a process-bound resource — the pack store's raw sealed-pack file descriptors — may be folded only by the process that opened it. Every cross-process consumer (cold replay, the reclamation cell directory) delegates the fold to the owner. The store *declares* the constraint (`process_bound_reads` capability) instead of consumers inferring it from the backend's identity, and memory backends fold in the caller. | The store capability (`bondy_mst_store`, `bondy_mst_pack_store`); the owner-side calls `bondy_oplog_instance:replay_pairs/2` and `cell_directory/1`, dispatched by `bondy_oplog_cell_utils` | `bondy_oplog_replay_sealed_pack_test`: `cold_replay_of_sealed_packs_runs_off_applier_test_/0`, `sweep_cell_directory_of_sealed_packs_runs_off_owner_test_/0`, `ephemeral_cell_directory_folds_in_caller_test_/0` |

## Why the proofs sit where they do

The mechanised effort concentrates on invariants 1, the exactness side of 4,
and 6 — the clock, the observed-remove test, and the forgetting license —
because their violation is *silent*: nothing crashes, replicas agree, and the
wrong value survives. Failures that are loud (a crashed process, an
incomplete round, a refused topology) are left to supervision and tests,
which handle them well. The model checker owns invariant 4's
*reachability* question because interleavings of truncation, lag and rejoin
defeat both intuition and example-based testing.

## Failure design in one paragraph

Every process in these views restarts under supervision, and every restart
has a resupply path that assumes nothing about the failed run: the WAL
replays into the projection, the ephemeral database refills from peers, and
a lagging node rebootstraps. Backpressure is explicit at each boundary:
admission caps on the overlay, a node-wide page budget in sync, and
concurrency caps on sync sessions and on the GC sweeps. Where the stack cannot
keep a promise it refuses — a topology mismatch, an unservable root, a
frontier it cannot back — instead of approximating.

## Standing limits

- Cross-node reads are eventually consistent. The stack's freshness
  exception, authentication, is fenced above the stack, not inside it.
- The prefix hold does not cover folds with no re-presentation path
  (one-shot re-derivations such as a projection rebuild). Those folds are
  instrumented (`bondy_oplog_prefix_holes_total`) rather than enforced.
  Compaction folds nothing: it truncates only what the applied frontier
  records as folded.
- A burned sequence range is backfilled by its origin with no-op events.
  Only a backfill that itself fails after its retries leaves a gap, which
  peers then repair through a rebootstrap.
- The TLA+ configurations check small instances: two or three replicas and
  one or two sequence numbers per origin. The cluster tests run three nodes.
- When a `registry` tree loses a page that holds an event this replica has
  not applied, no model checks how that event is recovered.

## Related

- [Storage roadmap](db_architecture.md) · [Per-origin prefix closure](../database/prefix_closure.md) · [Deletion and reclamation](../database/deletion_and_reclamation.md) · [Platform rationale](architecture_rationale.md)
