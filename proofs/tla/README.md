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

## CT attempt — does not yet exercise the blind spot

`bondy_oplog_compaction_cluster_SUITE:truncated_prefix_below_peer_max_is_not_silently_adopted`
implements the six-step trace on a real 3-node cluster: seed and converge all
three, silence N3, write EARLY, age N3 out of the recency filter, truncate,
then write LATE *after* the truncation so the peer's tree keeps its maximum,
then one complete round from N3.

### Fourth iteration — PROVEN, by the fold-time detector

An error in the third iteration's reasoning first, for the record: origins
and seqs are **per instance**, and each key routes to one shard — so "late
key readable + early key missing" proves nothing unless both keys share an
instance, which one key per band per phase left to chance. The third
iteration's "airtight" prefix-closure claim was **invalid**; its runs are
fully explained by cross-instance staleness with the deficit visible.

What settles it is increment 1 of the fix plan (see below): a telemetry-only
contiguity detector at the cell-apply mux fronts
(`bondy_oplog_cell_apply:detect_prefix_holes/2`,
`[bondy_oplog, applier, prefix_hole]`) that compares each batch's per-origin
seqs against the pre-batch applied frontier — the same-origin, same-instance
judgment read-backs cannot make. The CT forces co-sharding
(`?HOLE_TAGS_PER_BAND` early/late keys per band) and cross-checks every
firing against the writer node's per-instance origin.

**Result: per-origin prefix closure is VIOLATED on a real 3-node cluster.**
Six same-origin fold-time holes in one run, e.g.:

```
main/1  origin <writer>  applied_seq 12  gaps [{13,15}]
main/14 origin <writer>  applied_seq 1   gaps [{2,4}]
main/15 origin <writer>  applied_seq 0   gaps [{1,2}]
```

The rejoining node folded an origin's later seq while earlier seqs —
truncated at every live peer before it ever pulled them — were neither
applied locally nor in the batch, and `merge_frontier/2` then max-merged the
frontier past the hole. This falsifies the unqualified "causal (per-origin
FIFO) delivery" precondition in `bondy_oplog_crdt_aw_map.erl` and the
hypothesis `Dot_Exactness.compact_test_exact` assumes; inside the window the
compact `Ctx[O] >= S` test reports a skipped dot as observed.

**Adoption remained flagged in every run** (the deficit stayed visible; the
probe never reached the max-blind state), so the demonstrated defect is the
window plus the frontier over-merge, not a silent CONVERGED verdict.

### Fix status (per the independent review's plan)

Increment 1 — landed, zero behaviour change:

- **Seq-density fix**: a rejected WAL batch's seq range is returned via CAS
  when still the topmost reservation (`release_seq_range/3` in
  `bondy_oplog_instance`); overtaken ranges are counted by
  `[bondy_oplog, instance, seq_burned]`. All three mint sites now share one
  minting core (`do_build_events/6`) with single-range reservation — which
  is what makes the rollback safe.
- **Contiguity detector**: above; measures the field mix of true holes,
  transient WAL-order inversions, and residual burned seqs before any
  enforcement.
- **CT lock**: the case hard-fails on a proven same-origin hole and skips
  (never silently passes) when the scenario is not reached. It is
  **red by design** until increment 2 lands.

Increment 2 — BUILT, CT-validated, Fly-validated, and now the **shipped
default** (`db.aae.prefix_hold = on`; the knob remains as an emergency
opt-out):

- `apply_cell_pairs_mux/5` partitions each replay batch per remote origin
  into the contiguous-foldable prefix and a HELD remainder, excluded from
  the fold and therefore from the applied-frontier merge. `prefix_hole` now
  means a gap *materialised*; a presented-but-held gap is
  `[bondy_oplog, applier, events_held]`.
- Hold-safe call sites gate their replay cursors (applier replay + replayed
  pairs, fused replay, watermark-door fold — the door's VV re-check is its
  re-presentation path). The compaction catch-up and `rederive_projection`
  stay on the non-holding mux: they have no re-presentation path, so a hold
  there would be a silent drop.
- Local-origin events are never held (delivered in seq order by the local
  WAL drain; holding a replica's own echoes could park them behind its own
  burned seq).

**Fly-validated (s24, 2026-08-05).** 5×performance-8x `bondy-fleet-1` (lhr),
enforcement ON cluster-wide via the new `db.aae.prefix_hold` conf knob
(verified live: `application:get_env(bondy_oplog, prefix_hold) = {ok,true}`).
Workload: s21-shaped 50k pub VUs (8 LGs) + 1k×1k subs, ramp 120s, hold 300s;
fault injection at steady state: one node stopped 11:58:45Z → restarted
12:00:46Z (2m01s, past `peer_timeout`, live compaction truncating).

- **Throughput: 14.89M publishes, aggregate 32.4k pub/s — at/above the s21
  record (28.7k) with enforcement on AND a 2-minute node kill mid-run.**
  Subscribe med 233ms ≈ s21's 221ms. Delivery tails (p95 14.6s) reflect the
  outage+recovery, not comparable to no-fault runs.
- **Enforcement engaged exactly where designed:** 119 `Prefix-closure hold`
  events, concentrated on the victim in the 3 minutes after its restart —
  the rejoin pulling truncated trees. Zero holds needed on `main/*`.
- **Zero remote-origin holes.** 258 `prefix_hole` detections, ALL on
  `registry/*`, ALL own-origin: 219 local WAL-order inversions under 32k/s
  concurrency (the transient the detector was predicted to measure; benign
  for the registry's lww/struct semantics and outside the hold's scope by
  design), and 39 on the victim pre-restart under its first-boot identity
  (same class; classified apart only because its origin rotated at restart).
  **No gap of a foreign origin ever materialised — the holding paths caught
  everything the fix exists to catch.**
- **`seq_burned` = 0** across the run — the seq-density fix held at full load.
- **Self-heal:** frontier gaps and rebootstraps quiesced by 12:04 (~3 min
  after restart); log capture silent thereafter. The only crash reports were
  shutdown/reconnect noise on and around the stopped machine.

Remaining before defaulting ON: nothing observed argues against it; the
one watchpoint is the local-inversion `prefix_hole` rate (219 in ~8 min at
peak load) — measurement noise today, but any future consumer of `prefix_hole`
as an alert must exclude own-origin firings first.

CT `truncated_prefix_is_held_and_repaired_by_rebootstrap` (enforcement on,
same scenario): **0 holes folded, 20 writer-origin holds** (e.g. `main/1`
held `[16,17]` — the exact gap the unenforced run folds through), then with
the schedulers restored the persisting frontier deficit drives the
frontier-gap → rebootstrap chain to **full convergence of all 52 keys**
(seed + early + late; the truncated EARLY values arrive via the catalogue
bootstrap's projection cells), with zero holes through the repair included.

With enforcement now the default, the sibling case
`truncated_prefix_below_peer_max_is_not_silently_adopted` forces the flag
OFF and **passes on detection**: it locks the detector's ability to see the
misfold (which is what gives the enforced case's "zero holes" assertion its
meaning) and documents the hazard the default closes. Its only remaining
hard failure is silent adoption.

### The model verifies the fix

`AaeCausalClosure.tla` gained a `PrefixHold` constant: integration applies
the per-origin CONTIGUOUS CLOSURE of local-applied ∪ peer-tree instead of
the raw union (the tree still merges fully — the hold is at the
applied/projection level, as implemented). Results:

| Configuration | Result |
| --- | --- |
| baseline (hold off, ungated compaction) | violates in 6 steps — unchanged, the regression pin |
| gated compaction (hold off) | exhaustive clean, 12.9M states — unchanged |
| **`AaeCausalClosure_Hold.cfg`** (hold ON, ungated compaction — the shipped default) | **exhaustive clean at pairwise scope** (2 replicas; 30,938 states) |
| `AaeCausalClosure_Hold3.cfg` (same, 3 replicas) | clean; full exhaustion impractical — bounded-exhaustive clean to depth 18 (25.2M distinct states; the unenforced baseline violates at depth 6), plus 800,000 random traces to depth 40 (mean 29), 321M states checked, no violation (seed −3719027508674266878) |

One model-fidelity lesson en route: the first hold run produced a spurious
`NoOverClaim` violation because the model's `Rebootstrap` discarded the
replica's OWN minted events — in reality they survive in the local WAL and
are re-delivered after any clobber. `Rebootstrap` now retains own-origin
events (commented in the spec). After that fidelity fix the 3-replica hold
state space exploded past practical bounds for full exhaustion, so the hold
configuration is exhaustive at the pairwise protocol scope (sync, hold, and
frontier logic are all pairwise). The 3-replica run
(`AaeCausalClosure_Hold3.cfg`) covers the triangular interleavings two ways,
both clean: breadth-first to depth 18 before being stopped for machine
resources (25.2M distinct states — three times the depth at which the
unenforced baseline violates), and simulation mode
(`-simulate num=200000 -depth 40`, which TLC multiplies per worker: 800k
traces, 321M states checked) with all three invariants checked at every
state.

### Second iteration — loops until the maxima meet

The first version passed for the wrong reason (it accepted *any*
`frontier_gap`). It now takes complete rounds in a loop and judges after each:
early writes readable → SAFE; deficit empty while early writes missing → the
blind spot, FAIL; deadline exhausted → INCONCLUSIVE, reported as a failure so
it can never pass silently.

**Result: INCONCLUSIVE, reproducibly.** Over 120s of continuous complete
rounds the deficit *never closes*:

```
4 early writes still missing
deficit still visible on 4 instances (reported by both live peers):
  main/6  -> origin => {peer 4, local 3}
  main/5  -> origin => {peer 1, local 0}
  main/12 -> origin => {peer 1, local 0}
  main/15 -> origin => {peer 1, local 0}
```

The three `{1, 0}` entries are the interesting ones: the peer's applied
frontier counts an event for that origin that is **no longer in its tree at
all**, so page-sync can never deliver it and the deficit is *permanent*. The
gap fires on every round, forever, until a rebootstrap.

That points at a safety property the TLA+ model does **not** have:
truncated events stay counted in the peer's applied frontier while being
absent from its shippable tree, so the deficit stays visible rather than
being closed by the very round that would create the hole. If that holds
generally, the max-blind state is unreachable by this route and the design is
sound — the opposite of the model's prediction. `Compact(r)` in the spec
truncates `tree` and leaves `claim` alone, but the model then lets a syncing
replica reach that claim by receiving the peer's retained maximum; the cluster
suggests the peer's maximum is frequently *itself* truncated.

Not yet established: `main/6`'s `{4, 3}` does not obviously fit that pattern,
and closing it needs per-event instrumentation (origin/seq → key) that the
suite does not currently emit.

### First iteration — passed for the wrong reason

Kept here because the failure mode is worth remembering:

```
frontier_gap raised: true
early writes missing: 4 of 4
late writes missing:  0 of 4
instances whose deficit is VISIBLE to the max comparison: 4
  main/6  -> origin ... => {peer 4, local 3}
  present_locally => #{{origin, 4} => false}
```

The deficit was **visible** — peer max 4 against local max 3 on every gapped
instance. So the maxima did not meet, the check saw an ordinary lag, and the
blind spot was never entered. The likely cause is background `main/*` traffic
on a live cluster: N1 keeps writing after the LATE batch, so its maximum
moves past what N3 pulled, restoring a detectable deficit by accident.

What this establishes and what it does not:

- The case is a valid regression lock for the truncate-then-rejoin path, and
  confirms the gap check fires there.
- It does **not** confirm or refute the TLA+ counterexample. Driving the two
  maxima into equality needs the origin quiescent after the LATE batch —
  e.g. loop complete rounds until `frontier_deficit` is empty *before*
  asserting, or pin the scenario to an instance with no background writers.

Until that is done, the finding stands as: the check is structurally
max-based (`frontier_deficit/2`, `merge_frontier/2` — both confirmed by
reading), the model says that is insufficient, and no cluster run has yet put
the system in the state where it matters.
