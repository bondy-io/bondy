# Architecture Rationale: Robustness

The views describe what Bondy is; this page argues why it holds. It collects
the cross-cutting decisions about faults, overload, and consistency, and
states which properties a proof, a model or a test checks. The audience is
anyone deciding whether to trust the system: an evaluating operator, or an
engineer about to modify something these properties rest on.

## Fault design: crash, restart, reconcile

Bondy is an OTP system: every element of the runtime views lives in a
supervision tree, and the response to an inconsistent process is to crash it
and restart clean, not to patch it in place. Each restart has a resupply
path: a session's client reconnects, a `main` shard replays its write-ahead
log into the projection, a `registry` shard refills from peers, and a node
that lost too much history rebootstraps. The design intent is that recovery
re-derives from durable or replicated state and does not depend on the failed
party having behaved well. The [deployment view](view_deployment.md)
tabulates what each failure affects.

Cross-node forwarding does not assume a reliable network either. The relay
treats Partisan channels as TCP connections that can drop. WAMP's delivery
contract — order per pair, at-most-once events — is carried by a chain of
stages that are each serial already: the sender's connection process, one
pinned channel connection per flow, and one keyed worker on ingress.

## Overload design: refuse early, shed nothing silently

The system's posture under load is asymmetric on purpose:

- **Admission is the throttle.** When `bondy_regulator_load` reports the node
  busy, or `bondy_regulator_memory` reports memory high, new sessions are
  refused at HELLO with a retryable ABORT — before authentication, before RIB
  writes, before any real cost. Admitted sessions are protected at the
  expense of unadmitted ones.
- **The data plane backpressures rather than queues, and counts what it
  drops.** Client-submitted messages are routed synchronously in the
  connection process that received them, so a loaded router slows that
  connection instead of accumulating work. The regulated pool, with its
  synchronous fallback, carries only the meta-API calls. The one place the
  data plane discards is relay *ingress*: a message whose flow worker is at
  its share of the pool's capacity is shed and counted
  (`bondy_wamp_dropped_total{reason="shed"}`). WAMP events are at-most-once,
  so shedding is a legitimate response to saturation.
- **Background work yields to foreground work.** Anti-entropy runs under a
  node-wide concurrency cap and a node-wide page budget (independent of shard
  count), backs off on converged shards, and can yield its dispatches when
  the run queue is long (`db.aae.load_adaptive`, off by default). Replication
  lag is recoverable; a saturated node is not.

## Consistency design: eventual, with explicit exceptions

Cross-node consistency is eventual, and the architecture spends its effort on
making that safe:

- **Convergence rests on deterministic folds.** Replicas fold the same events
  through the same per-table CRDT module, so agreement on the event set is
  meant to give agreement on values. The remaining problem — event-set
  agreement — belongs to anti-entropy, and the [convergence
  view](view_convergence.md) shows its detection and repair.
- **Where staleness is dangerous, it is fenced, not tolerated.**
  Authentication refuses on a node whose view of the security tables is
  older than a bound (`db.aae.fence.max_lag`), or that cannot confirm
  freshness while clustering is enabled (`db.aae.fence.on_isolation`, which
  refuses by default). A node with clustering disabled (`cluster.enabled =
  off`) is exempt because it has no peer to lag.
- **Garbage collection is licensed, never assumed.** Tombstone reclamation
  and history truncation happen only at or below the largest key that every
  member's reported durable frontier covers ([deletion and
  reclamation](../database/deletion_and_reclamation.md)). Two paths truncate
  without waiting for a silent peer — registry retention, and the rebuild of
  a `registry` tree that lost pages — and the frontier-gap and rebootstrap
  chain is their repair.

## What is verified, and how

Several of the properties above are checked by machine. The artifacts live in
the repository: Isabelle/HOL theories under `proofs/isabelle/`, TLA+ models
under `proofs/tla/`, and tests under `apps/*/test/`. `proofs/README.md` is the
index, with each result's scope and assumptions.

| Property | Evidence |
| --- | --- |
| Hybrid-logical-clock monotonicity, and domination of received timestamps, including the clamp on logical overflow | `proofs/isabelle/Hlc.thy` (`run_dominates_received`), a model of `bondy_connect_hlc` |
| Compaction confirmed by every member's durable frontier loses and drops no event | `proofs/isabelle/Confirmed_Compaction.thy` (`no_loss`, `no_drop`); `proofs/tla/ConfirmedCompaction.tla` with `_3R.cfg` and `_3R_Partition.cfg` |
| The reclamation license covers clock-governed state reductions and does not cover context-governed ones | `proofs/isabelle/Stabilization.thy` (`hlc_governed_reduction_sound`) and `proofs/isabelle/Aw_Counterexample.thy` (`aw_fold_not_sound_above`) |
| Exactness of the compact observed-remove test under per-origin prefix closure | `proofs/isabelle/Dot_Exactness.thy` (`compact_test_exact`) |
| Per-origin prefix closure under compaction and rejoin, with the shipped [prefix hold](../database/prefix_closure.md) | `proofs/tla/AaeCausalClosure_Shipped.cfg` and `_Shipped_3R.cfg` (`PrefixClosed`), with `AaeCausalClosure.cfg` as the ablation with the hold off |
| The same, on a real cluster | `bondy_oplog_compaction_cluster_SUITE:truncated_prefix_is_held_and_repaired_by_rebootstrap/1`: no hole folds, and the returning node converges after a rebootstrap |

The point of the table is its placement: the properties checked are the ones
every view leans on — the clock, the forgetting license, the observed-remove
test, and the fold order. An engineer changing code near any of these should
expect a proof, a model or a test to catch a mistake before an operator does.

## Standing limits

The architecture does not cover these edges:

- Cross-node reads are eventually consistent. An application that needs
  read-your-writes across *different* nodes has to route the read to the
  writing node or tolerate the lag.
- The prefix hold cannot cover fold paths with no re-presentation (one-shot
  re-derivations). Those paths are instrumented, and the detector's telemetry
  (`bondy_oplog_prefix_holes_total`) is the tripwire. Compaction folds
  nothing: it truncates only what the applied frontier records as folded.
- A sequence range that can neither be returned nor backfilled becomes a
  rebootstrap on peers rather than a silent gap — a deliberate trade of
  noise for correctness.

## Related

- [Documentation roadmap](architecture.md) · [Convergence and repair](view_convergence.md) · [Per-origin prefix closure](../database/prefix_closure.md) · [Load regulation](../configuration/load_regulation_and_rate_limiting.md)
