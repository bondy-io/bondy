# TLA+: AAE round causal closure

**THIS WAS BUILT BY CLAUDE OPUS and it is not verified.**

Model-checks whether bondy_db's anti-entropy layer delivers a per-origin
**prefix-closed** set of events to each replica — the hypothesis two things in
`../isabelle/` take for granted.

```
java -cp tla2tools.jar tlc2.TLC -workers 4 -config AaeCausalClosure.cfg       AaeCausalClosure.tla   # baseline: violated in 6 steps
java -cp tla2tools.jar tlc2.TLC -workers 4 -config AaeCausalClosure_Gated.cfg AaeCausalClosure.tla   # gated: exhaustive, clean
```

TLC 2.19; `tla2tools.jar` is not vendored here — fetch it from the
[tlaplus releases](https://github.com/tlaplus/tlaplus/releases/latest).

## Two questions answered

**1. Can a budget-capped round deliver a non-closed set? No — it delivers
nothing.** Established by reading, not by checking: `pull_until_complete/6`
pulls pages in bounded batches (`lists:sublist(Missing, PerRound)`) but calls
`integrate_peer_root/2` only when `missing_set` is empty. An incomplete round
transfers pages into the local store and installs no root, folds no items,
and checkpoints nothing. It is a stutter step, which is why no action models
it. This retires the open obligation carried in `../README.md` — the budget
caps bound page *transfer*, not *delivery*.

Also relevant: replication is pull-only (`sync_session.erl:48`) and the public
`append_remote/2` has no production sender, so whole-root integrate is the
only remote delivery path.

**2. Is the delivered set prefix-closed? Only if compaction is gated.**

| Configuration | Result |
| --- | --- |
| `GatedCompaction = TRUE` | Exhaustive: 12,952,590 states, 311,845 distinct, queue drained. `NoOverClaim` and `PrefixClosed` both hold. |
| `GatedCompaction = FALSE` | `NoOverClaim` violated in 6 steps (`PrefixClosed` too). |

`GatedCompaction = FALSE` is not a strawman. It models what
`sync_session.erl:145-160` says the system does by design: *"BOTH compaction
flavours can break that implication by design: `mst_retention` truncates by
local policy with no confirmation at all, and the durable peer-confirmed
frontier is RECENCY-FILTERED — a replica silent past `peer_timeout_ms` is
dropped so compaction can proceed without it."*

## The counterexample

```
1. Init
2. Bootstrap(r2 from r1)   -- r2 joins while the cluster is still empty
3. Mint(r1)                -- (r1,1)
4. Mint(r1)                -- (r1,2)
5. Compact(r1)             -- truncates the prefix {(r1,1)} from r1's tree;
                              r1 still has both APPLIED
6. SyncComplete(r2, r1)    -- r2 integrates r1's whole (truncated) tree
```

Final state:

```
applied = (r1 :> {(r1,1), (r1,2)},  r2 :> {(r1,2)},  r3 :> {})
claim   = (r1 :> [r1 |-> 2],        r2 :> [r1 |-> 2], r3 :> [r1 |-> 0])
gapFlag = (r1 :> FALSE, r2 :> FALSE, r3 :> FALSE)
```

`r2` holds `(r1,2)` without `(r1,1)`, and reports frontier `r1 |-> 2`.

**Why the gap check does not fire.** `frontier_deficit/2` is strictly
max-based — it folds the peer frontier and keeps origins where
`Seq > Cur`, per origin. Here the peer's max is 2 and `r2`'s post-round max
is also 2, so the deficit is empty, no `{frontier_gap, _}` is raised, and
`maybe_adopt_peer_frontier/4` adopts. A per-origin maximum is structurally
blind to a hole *strictly below* that maximum.

That matters because `maybe_frontier_gap/5`'s own comment states its purpose
as preventing exactly this outcome: *"adopting would flip the convergence
oracle to CONVERGED over silently missing data."* The check catches the case
where the stale replica's max lags the peer's. It does not catch the case
where a single whole-root integrate delivers the peer's truncated suffix, so
both maxima agree while the prefix is missing.

## Consequences if reachable

- `PrefixClosed` is the hypothesis `Dot_Exactness.compact_test_exact` needs.
  Without it the compact test `Ctx[O] >= S` reports a **skipped** dot as
  observed, so `drop_observed/2` removes an add the writer never saw —
  add-wins is violated and the add is silently lost.
- `NoOverClaim` is the convergence oracle's soundness. `get_frontier`'s own
  docstring concedes the dependency: *"causal delivery makes a per-origin max
  Seq identify the applied prefix"*. Equal frontiers would report CONVERGED
  over a hole.

## What has NOT been established

Honest limits of this result:

- **Reachability in the running system is unconfirmed.** The model says the
  scenario is consistent with the code as read. It has not been reproduced on
  a cluster, and no CT case here demonstrates it.
- `mst_retention` is an opt-in backstop and defaults OFF, so the live premise
  is the recency-filtered confirmed frontier, not retention.
- There may be a guard elsewhere that the model omits. Candidates not yet
  chased: `maybe_unservable_behind/3` (runs before the gap check),
  `watermark_door/3` on the page-sync side, whatever
  `deficit_presence/2` feeds, and the bootstrap/rebootstrap paths in
  `bondy_oplog_bootstrap_lifecycle`.
- The model abstracts the MST to its item set. Page-level structure, HLC
  values, cells, and concurrency are all absent; truncation is modelled as
  removing a per-origin prefix, which is what key-order truncation plus
  per-origin HLC monotonicity gives.

The next step to settle it is a CT case in the shape of the six-step trace,
against `bondy_oplog_compaction_cluster_SUITE`'s existing stale-peer rejoin
fixture.
