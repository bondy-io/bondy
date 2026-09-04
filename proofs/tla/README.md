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

Increment 2 — BUILT, CT-validated, Fly-validated, and **unconditional**:

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
enforcement ON cluster-wide. Workload: s21-shaped 50k pub VUs (8 LGs) + 1k×1k subs, ramp 120s, hold 300s;
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

The hold is unconditional — there is no key that disables it — so there is
no sibling case exercising the unenforced polarity. What gives the "zero
holes" assertion its meaning is the fourth-iteration run above, on the same
scenario and the same detector, before enforcement existed.

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

## Origin reaping: can the frontier be reaped without agreement?

`OriginReaping.tla`. The frontier is a join-semilattice element (per-origin
max, merged by `merge_frontier/2`); reaping is the only operation that moves
it DOWN, so it is the only one that can break the lattice discipline the
convergence oracle rests on.

```
java -cp tla2tools.jar tlc2.TLC -workers 4 -deadlock -config OriginReaping_Off.cfg        OriginReaping.tla
java -cp tla2tools.jar tlc2.TLC -workers 4 -deadlock -config OriginReaping_Unilateral.cfg OriginReaping.tla
java -cp tla2tools.jar tlc2.TLC -workers 4 -deadlock -config OriginReaping_Solo.cfg       OriginReaping.tla
java -cp tla2tools.jar tlc2.TLC -workers 4 -deadlock -config OriginReaping_SoloJoin.cfg   OriginReaping.tla
```

`-deadlock` because a terminal state (every origin minted out, all but one
replica departed) is expected here and is not a safety failure.

| Configuration | Result |
| --- | --- |
| `Off` — frontier never reaped (today) | exhaustive clean: 425,614 states, 104,447 distinct |
| `Unilateral` — any member may reap a dead origin it has fully applied | **`SpuriousGap` violated in 6 steps** |
| `Solo` — reap only when this replica is the sole member | clean: 527,785 states, 155,240 distinct — but see the join result below, which retires this row as a licence |

The precondition granted to `Unilateral` is the strongest one a node can
check locally: the origin is claimed by no member, and this replica holds
every event that origin ever minted. It is still not enough.

### The counterexample

```
1. Init
2. Mint(r1)              -- (r1,1)
3. Sync(r2, r1)          -- r2 applies it; both claim r1 |-> 1
4. Depart(r1)            -- r1 leaves; origin r1 is now dead
5. Sync(r3, r2)          -- r3 applies it; claims r1 |-> 1
6. Reap(r2)              -- r2 drops its r1 entry, having applied everything
```

Final state: `applied` is IDENTICAL at r2 and r3 (both hold `(r1,1)`), but
`claim[r3][r1] = 1` while `claim[r2][r1] = 0`. The next round r2 takes from
r3 reads that as a deficit, raises `{frontier_gap, _}` and flags a catalogue
rebootstrap — for data r2 already has. The rebootstrap re-merges r3's
frontier, restoring the entry, and the next retirement pass reaps it again:
the cost recurs once per retirement interval per disagreeing pair until every
node has reaped.

`NoDataLoss` holds throughout, which is the useful discrimination: reaping
does not corrupt state, it desynchronises the ORACLE. The failure is
expensive and self-inflicted, not silent.

### The solo carve-out does not survive the cluster growing again

`Solo` is clean at 527,785 states — but only because that configuration has no
way for membership to GROW. Partisan membership changes by a deliberate
join/leave in both directions, and a one-node deployment that later gains a
node is ordinary operation, not an edge case. `MembershipGrows` adds the
missing `Join` action.

| Configuration | Result |
| --- | --- |
| `OffJoin` — join enabled, no reaping | exhaustive clean: 104,447 distinct — identical to `Off`, so `Join` adds no reachable state by itself |
| `SoloJoin` — solo carve-out, join enabled | **`SpuriousGap` violated in 7 steps** |

```
1. Depart(r1)
2. Mint(r2)          -- (r2,1)
3. Sync(r3, r2)      -- r3 applies it
4. Depart(r2)        -- r3 is now the sole member
5. Reap(r3)          -- solo, so the carve-out licenses dropping the r2 entry
6. Join(r2)          -- r2 returns
```

Both replicas hold `(r2,1)`, but `claim[r2][r2] = 1` and `claim[r3][r2] = 0`.
The next round reads that as a deficit, raises `{frontier_gap, _}` and pays a
catalogue rebootstrap for data `r3` already has — and the rebootstrap restores
the entry, so the next retirement pass reaps it again.

This does not contradict `reclamation_members/0`'s own doc. That statement is
about the stability point for PROJECTION-CELL reclamation, where solo really
does license maximal reclamation: a fresh HLC tick dominates every event the
node holds, and a joiner brings its own state through a CRDT merge. The
frontier VV is different in kind — it is a CLAIM compared against peers, so
dropping an entry is only safe if no future member can hold a higher value for
it. Solitude at the moment of the reap does not establish that.

### What this licenses

Nothing node-local and unconditional. Removal from a join-semilattice is
non-monotonic, so it is safe only when coordinated, or when accompanied by a
record of what was removed — and per origin that record costs exactly what the
entry cost. The scalar watermark below is the only form that is both sound and
cheaper than what it replaces.

### The meet, and why the obvious form of it fails

`OriginReaping_Meet.cfg` models the natural reading of "use the meet, like
MST GC does": reap an origin when every member is known level on it, and let
`frontier_deficit/2` skip origins this replica has reaped. **`ReapedMeansLevel`
violated in 4 steps.** The predicate it must use to recognise a reaped origin,

```
Dead(o) /\ claim[r][o] = 0
```

cannot distinguish *"I reaped this after verifying I was level"* from *"I
never saw it"*. In the counterexample r3 never received the dead origin's
event at all, so it skips a deficit that was real. The meet is sound;
RECOMPUTING it from an absent entry is not.

### The meet recorded as a scalar — `OriginWatermarkReap.tla`

The fix is to record the meet rather than re-derive it. Per origin that is a
tombstone and costs what the entry cost. As a SCALAR it costs O(1) — which is
exactly how MST compaction gets away with a watermark. The prerequisite is an
ORDER on origins: compaction can use a scalar because keys sort by HLC, while
origins today are opaque 128-bit randoms with no order at all.

`reapedBefore[r]` advances past rank `k` only when every origin below `k` is
dead AND every member holds exactly what this replica holds for it. Below the
watermark, entries are dropped, not re-learned on merge, and excluded from the
deficit.

This module carries origins that are BORN over time — a node rebuilding its
instance directory takes a new epoch — rather than assuming the whole
population exists at `Init`, and it sources the meet from what an
implementation can actually read rather than from a live view of every peer.
Three replicas, four ranks (so one replica gets a later epoch), `MaxSeq = 1`.

| Configuration | Result |
| --- | --- |
| `Off` — never reap (control) | exhaustive clean: 105,483 distinct |
| `Hlc` — HLC ids, fresh strict meet | exhaustive clean: **3,038,590 distinct** |
| `Wallclock` — wall-clock ids | **`NoLiveOriginBelowWatermark` violated** in 6 steps |
| `Stale` — meet read from `peer_state.frontier` | **`ReapedMeansLevel` violated** in 8 steps |
| `Recency` — recency-filtered members | **`ReapedMeansLevel` violated** in 8 steps |
| `StaleRecency` — both | **`ReapedMeansLevel` violated** in 7 steps |

Invariants: `TypeOK`, `NoOverClaim`, `NoLiveOriginBelowWatermark`,
`ReapedMeansLevel`, `SpuriousGap`. `NeverReaps` is a reachability probe rather
than a safety property — checking it as an invariant makes TLC report the
trace in which the watermark first advances, which separates "reaping is safe"
from "reaping happens". It is violated under `Hlc` in 5 steps, so the rule
below is not vacuous.

**So consensus is not required**, and three things are.

**(1) The id scheme is load-bearing, and the reason is domination, not
gap-freedom.** The rule cannot be "every RANK below `k` is born": ids are
timestamps, the rank space is sparse, and the born set is never a contiguous
prefix — that rule is safe but can never advance past the first id ever
issued. The condition that actually holds is that no member can mint beneath
`k`. An HLC-derived id strictly exceeds its minter's clock and every clock
absorbs every clock it syncs with, so a member already at or above `k` cannot
mint below it. A wall clock offers no such guarantee, and the counterexample
is direct: replicas hold ranks 4, 2, 3, every clock is at or above 2, so `r1`
advances its watermark to 2 — and then mints origin **1**, live, beneath its
own watermark.

Counterexample depths are quoted rather than state counts: with parallel BFS
the number of states explored before a violation surfaces varies between runs,
while the minimal depth does not.

**(2) The meet must be read fresh, and `bondy_oplog_peer_state` cannot supply
it.** Its `frontier` column is documented as the peer's vector *"as observed
at the start of the last completed round"* — a snapshot. A dead origin's
events keep propagating between rounds, so a peer's value grows after the
snapshot is taken, and the meet is then computed against a number the peer has
already moved past. In the counterexample `r3` records `r2` at 0 for a dead
origin, reaps on that basis, and ends holding nothing of an origin `r2` has an
event from. The available fix is the round trip `origin_retirement` already
performs for `get_origins`: ask every member for its current frontier at reap
time — `get_frontier` is an existing responder verb — and fail closed if any
member cannot answer.

**(3) The read must be strict, not recency-filtered.** `bondy_oplog_peer_state`
already asserts this in prose (*"Reclamation MUST use the strict reading"*);
the `Recency` row is that assertion failing under a checker rather than a new
discovery. A member dropped for silence is a member whose value was never
compared.

Finally, the deficit check and the frontier merge must both honour the
watermark — a reap that only changes the stored VV is undone by the next
`merge_frontier/2`.

## Cell-context reaping: does the membership-only driver need a stability gate?

`CellContextReap.tla`. `bondy_oplog_crdt_aw_map:reap_origins/2` states its
own precondition — *"Safe only once the origin is permanently gone AND
causally stable cluster-wide — the operator's obligation"* — while
`bondy_oplog_origin_retirement:reap_complement/3` establishes only the first
conjunct, from membership alone. This asks what the second conjunct buys.

**It buys nothing, because the cell context is not what makes re-delivery
idempotent.** Every call site of `bondy_oplog_crdt_aw_core:drop_observed/2`
— `bondy_oplog_crdt_nested_core:put/5` and `rmv/3`,
`bondy_oplog_crdt_ew_flag` — is handed the OPERATION's stamped context,
threaded from the event `meta` through `bondy_oplog_cell_kernel:apply/6` and
`bondy_oplog_crdt_commutative:apply_op/5`. `put/5` adds its dot
unconditionally; it never asks whether `CC` already observed it. `CC`'s only
readers are `cc_absorb/3` and `context_of/1`, which supplies the stamp for
the NEXT write.

Re-delivery is filtered upstream of the CRDT entirely, by the
applied-frontier VV — which the reaper does not touch:
`append_remote_install/3` refuses an event key already in the local MST,
and `append_remote_below_watermark/3` / `watermark_door/3` drop an
at-or-below-watermark event unless the applied VV says this replica never
applied it.

So the model gives ops their own stamped contexts, gives `CC` only the stamp
role, and gates delivery on the two doors above — the code's actual shape.
`Compact` is deliberately weaker than the real truncation (any applied op may
leave the tree, not just an HLC-ordered prefix), so a clean result covers a
superset of reachable states. Three replicas, one origin each, symmetry
reduction, exhaustive.

| Configuration | `NoResurrection`, `NoPhantomDot`, `ContextCoversDots` | `Convergence` |
| --- | --- | --- |
| reap off, causal delivery | clean, 426,389 distinct | clean |
| reap **on**, causal delivery | clean, 5,046,890 distinct | clean |
| reap off, out-of-order delivery | clean, 751,829 distinct | **violated** in 6 steps |
| reap **on**, out-of-order delivery | clean, 10,570,826 distinct | **violated** in 6 steps |

Two replicas at `MaxSeq = 2` are exhaustively clean on every invariant in all
four configurations (724k / 526k / 1.86M / 1.35M distinct) — the inversion
below needs three parties.

**The reap does not resurrect and does not break convergence.** It moves the
stamped context down, so a later remove drops fewer dots at replicas that
still hold them — an error toward FALSE concurrency (extra siblings the CRDT
resolves), never toward lost causality, which is the direction
`bondy_oplog_applier`'s I1 note already names as acceptable. Nothing
interprets an existing event differently, because every event carries its own
context and is replicated verbatim.

**What the model did find is orthogonal to reaping.** `Convergence` — two
replicas that folded the same operation set hold the same value — fails
whenever delivery is not causal, with the reap on or off, and `ReapCell` never
fires in either counterexample. The shape is a three-party inversion: `r2`
folds `r1`'s put and then mints a put observing it; a third replica folds
`r2`'s op first (dropping nothing, because it has not seen `r1`'s dot) and
`r1`'s afterwards, whose `put/5` adds the dot back. Both dots survive at `r3`
and only one at `r2`, permanently.

Whole-root page sync supplies causal order in the common case — the peer's
tree carries both events and the replay folds them in MST key order, which is
HLC order. The inversion needs the peer to have compacted the earlier event
away, which is the prefix-closure hazard `AaeCausalClosure.tla` covers. The
hold that closes that hazard (`bondy_oplog_cell_apply:partition_contiguous/3`)
is **per-origin**: it computes a contiguous run per origin against the applied
frontier and holds beyond the first gap. In the inversion above each origin
delivers exactly one event with no per-origin gap, so nothing is held. The
requirement is cross-origin causal delivery, and no per-origin mechanism
supplies it — the same distinction as the vector-vs-HLC stability gap
`bondy_oplog_crdt_nested_core`'s moduledoc records for the stabilization fold.

## Frontier reaping: what survives a node coming back

Every membership-derived design fails on one action. `OriginReaping.tla` and
`OriginWatermarkReap.tla` were both checked without a `Join`, and both fall
over once it exists:

| Model | With `Join` |
| --- | --- |
| `OriginReaping_SoloJoin` — solo carve-out | **`SpuriousGap` violated in 7 steps** |
| `OriginWatermarkReap_HlcJoin` — HLC watermark | **`NoLiveOriginBelowWatermark` violated**, 1,894 distinct |

The watermark counterexample is the decisive one: `r2` departs, `r1` reaps
`r2`'s origin, `r2` rejoins — and because
`bondy_oplog_origin:load_or_create/1` reuses the persisted id, `r2` resumes
minting under the very origin the survivors reaped. They then skip its new
events. Membership-derived "dead" is not dead; it is "away".

`OriginRetirementSet.tla` replaces membership with a REPLICATED grow-only
retirement set, driven by an operator decommissioning a node. Three replicas,
`MaxSeq = 1` unless stated, `Join` enabled.

| Configuration | Result |
| --- | --- |
| `OffS1` — never reap (control) | exhaustive clean: 861 distinct |
| `BannedS1` — retire + ban + reap | **exhaustive clean: 16,529,485 states, 2,538,102 distinct** |
| `UniversalS1` — the shipped guard | **exhaustive clean: 17,013,691 states, 2,538,102 distinct** |
| `UnbannedS1` — retire + reap, ban NOT enforced | **`RetiredSkipIsSafe` violated in 5 steps** |
| `Universal` — the shipped guard, `MaxSeq = 2` | **exhaustive clean: 685,709,113 states, 95,684,190 distinct** |
| `Banned` — `MaxSeq = 2` | exhaustive clean: 649,547,353 states, 95,684,190 distinct |

Six requirements, and three of them are things an implementation would get
wrong by default:

1. **The retirement set is replicated and grow-only.** Monotone, so it
   converges by union with no ordering requirement — the `Propagate` action is
   just a set union over what a member currently holds. Every replica
   therefore skips the same origins, so the skip is symmetric rather than a
   private opinion.
2. **It must be persisted.** A node that forgets it retired an origin reads a
   peer's surviving entry as a deficit and pays a rebootstrap.
3. **Retirement must be operator-driven, not derived from membership** — that
   is the whole point of the module.
4. **The ban is load-bearing.** Skipping a retired origin's deficit is safe
   only because no replica will ever accept another event from it, so there is
   no future data to be blind to. `UnbannedS1` is that conjunct failing.
5. **Ban the claim, not just the events.** Filtering incoming events while
   still max-merging the peer's vector for that origin leaves the frontier
   asserting events the replica refused — `NoOverClaim` violated in 8 steps
   before this was fixed.
6. **The claim rises from the events actually folded**, not only from the
   peer's advertised vector. A peer that has already reaped advertises less
   than it just gave you; adopting only its number leaves this replica
   claiming less than it holds, and reading a permanent deficit against a
   third node — `SpuriousGap` violated in 10 steps before this was fixed. The
   real code already has this shape (`batch_frontier/1` ->
   `merge_frontier/2`); the model did not, which is what surfaced it.

### Which precondition licenses the drop

Three candidate guards, all of them safe against the invariants above, so
those invariants cannot choose between them. What separates them is log
reclamation, which `CompactionModelled` adds: an event reclaimed from every
holder's log moves only by catalogue rebootstrap, and only a frontier deficit
flags one. `NoStuckEvent` says no replica is ever left wanting an event with
every route to it closed.

Judged with the survivors stable (`StableMembership = TRUE`), which is the
deployment the reap exists for — an operator removes one node and the rest
carry on:

| Guard (`ReapRule`) | `NoStuckEvent` | Can every member clear the entry? |
| --- | --- | --- |
| — (`OffCompactS1`, never reap) | clean: 124,558 distinct | n/a |
| `"none"` — retirement alone | **violated in 7 steps** | — |
| `"meet"` — every member level on it | clean: 654,082 distinct | **no** — exhaustive, 4,035 distinct |
| `"universal"` — every member has retired it | clean: 662,464 distinct | **yes**, in 10 steps |

The right-hand column is `NotAllMembersReaped`, an inverted invariant: a
violation is a run in which every member dropped an entry it genuinely held,
so **holding** is the bad result. The meet rule holds it exhaustively, and the
reason is mechanical — only a reap lowers a claim, and a retired origin's
claim never rises again, so the first replica to reap leaves every other
replica permanently unequal to it. It is safe and it never finishes: the entry
survives on every replica but one, which is the leak it was written to remove.

`"none"` fails the other way. Its counterexample is six steps of ordinary
operation — mint, sync, compact, depart, retire, reap — and ends with a
surviving member that never retired the origin, is missing an event reclaimed
everywhere, and will never be told. So the guard has to be universal
retirement: a replica that has retired the origin refuses its events and has
no use for the signal, and one that has not still does.

### May a replica enforce a retirement it has not persisted?

No, and the model is what settles it. `RetirementDurable` splits the two
halves of recording a retirement — enforcing it (the ban, and the licence to
reap) and persisting it — and `Restart(r)` drops everything not persisted.
Nothing else a node holds regresses across a restart: `applied`, `claim` and
the frontier all survive by other means, so the retirement set is the only
thing a restart can take away, and it is the one thing the design needs to
be monotone.

| Configuration | Result |
| --- | --- |
| `ForgetfulS1` — enforce first, persist may fail | **`SpuriousGap` violated in 9 steps** |
| `UniversalS1` — durable when enforced | exhaustive clean: 2,538,102 distinct |

The counterexample is mint, depart, sync, depart, retire, **reap**,
**restart**, join. The restart forgets the retirement while the reap it
licensed has already removed the frontier entry, so the replica reads a
peer's surviving entry as a deficit for data it holds — on every round,
with no way to fill it, forever.

So `bondy_oplog_origin_bans` writes the file BEFORE inserting into its
table, and a failed write leaves nothing enforced. That reverses the
ordering the code originally argued for ("persisting first would leave a
durable retirement the running node does not enforce"): a durable retirement
not yet enforced is harmless and self-corrects, while an enforced retirement
that is not durable is the counterexample above.

It also settles what to do with a path whose write failed — keep it. With
persist-before-enforce a failure changes nothing, so there is no divergent
state to contain, and the only thing left is to let the next attempt retry.

### What the universal guard does not cover

`UniversalChurnS1` is the same configuration with membership churn allowed:
**`NoStuckEvent` violated in 9 steps**. The trace shrinks the cluster to one
member, reaps there, and then rejoins a replica that holds neither the
retirement nor the reclaimed event. A node absent at reap time was not
consulted by it.

That window closes as soon as the returning node pulls the retirement set,
after which it refuses those events anyway — so this is the ban's cost, not
the reap's. Both point at the same operator contract: **retire an origin only
once the cluster has converged on its events.** The implementation reports the
violation rather than preventing it, on
`[bondy_oplog, retirement, reaped_unconverged]`, because refusing to reap over
unequal claims is exactly the meet rule and inherits its deadlock.

## `SeqSeed.tla` — the per-origin sequence counter across restarts

```
for c in Shipped Ckpt CkptCommitKeyedRetention CkptBeforeCommitKeyedRetention \
         CkptEarlyMint CkptWal; do
  java -cp tla2tools.jar tlc2.TLC -workers 4 -config SeqSeed_$c.cfg SeqSeed.tla
done
```

Found by Jepsen (`jepsen/jepsen.bondy`, `combined` nemesis, 2026-09-03): after
a restart a node's post-restart writes carried sequence numbers already held
by every replica, so no peer ever saw a frontier deficit for them and a peer
that compacted them before a partitioned replica pulled lost them silently.
`AaeCausalClosure.tla` cannot exhibit this — its `minted[o]` is a global
counter that never regresses and it has no restart action — so this module
models the minter's own persistence protocol: reserve, WAL append + ack,
apply + install, root flush, WAL retention, two-step compaction, clean stop,
`kill -9`, restart. One replica, one origin. `SeedExact` is the invariant
`acked ∪ inflight = 1..seqRef` wherever a mint is possible; `DotUnique` is
`inflight ∩ acked = {}`.

Six configurations, `MaxSeq = 3`:

**`_Shipped`** — the code as read. Violated in 7 steps:

```
Reserve, Append(1), Apply(1), TruncateFlush(w=1), TruncateCheckpoint,
Stop, Restart
```

Final state: `tree = {}`, `wal = {1}` but `cursor = wm = 1` so it will not
replay, `ckpt = 1`, `acked = {1}`, `seqRef = 0`. The next mint is seq 1
again. A clean stop suffices; `Crash` gives the same.

**`_Ckpt`** — "seed from the restored frontier", everything else as shipped.
Clean: 624 distinct states; 6,081 at `MaxSeq = 5`.

**`_CkptCommitKeyedRetention`** — the same seed, but the WAL drops whatever
the durable root holds (retention keyed on the committed offset alone).
Violated in 8 steps:

```
Reserve, Append(1), Apply(1), FlushRoot, DropWal, TruncateFlush(w=1),
Crash, Restart
```

The truncated root is durable, the checkpoint was never written, the WAL
segment is gone: seq 1 is in no durable source. What ships does not do this:
`compute_deletable/1` drops a segment only below the committed offset AND
below the snapshot watermark — the durable compaction checkpoint's
watermark — so the event would still be in the WAL and would replay from
the resume position. A first version of this model had commit-keyed
retention and reported the window as reachable; this config keeps the
result as the statement of what retention must never do. Found on the way:
nothing in production called `advance_snapshot_watermark/2`, so the sweep
dropped nothing at all — fixed the same day: compaction advances the
watermark after its checkpoint is durable, and a test observes that order.

**`_CkptBeforeCommitKeyedRetention`** — commit-keyed retention made safe by
checkpointing the frontier before the truncated root is flushed. Clean. Not
taken: the shipped retention rule already carries the obligation, and the
checkpoint-after-root order is what `resume_position/2` relies on.

**`_CkptEarlyMint`** — `_Ckpt`, dropping the grant that no mint precedes the
WAL replay (the fast path is published in `init/1`; nothing awaits the boot
drain). Violated in 4 steps: `Reserve, Append(1), Stop, Restart` — the WAL
holds seq 1, the applier has not replayed it, the counter is 0.

**`_CkptWal`** — the retained WAL's maximum read at open as a third seed
source. Clean: 548 distinct states; 5,304 at `MaxSeq = 5`. This is the rule
`../isabelle/Seq_Seed.thy` proves for unbounded runs, and the one built.

Not modelled: `fsync_mode` other than `per_write` (the applier can then read
frames before they are durable; the model's `Append` makes ack and
durability one step), concurrent minters (WAL order = seq order here), and
the seq-range CAS rollback in `release_seq_range/3`.

## `ConfirmedCompaction.tla` — what a completed round lets a replica truncate

```
for c in Root2 RootVV2 Root2_AsyncSweep RootVV2_AsyncSweep RootVV2_AsyncSweep_NoCap \
         Root2_Live Root2_Live_NoSweep RootVV2_Live Root3 RootVV3; do
  java -cp tla2tools.jar tlc2.TLC -workers 4 -config ConfirmedCompaction_$c.cfg ConfirmedCompaction.tla
done
```

Compaction truncates the largest local key every local key at or below
which is present in EVERY recorded peer root (`compute_frontier_for/2`). A
round of `r` pulling from `p` records `p`'s advertised root against `p`
(`maybe_record/6`) and confirms it back so `p` records the same root against
`r` (`maybe_confirm_root/7`). The 2026-09-04 re-grounding of the compaction
ping-pong (a compacted node re-pulls the whole uncompacted prefix from a peer
every round, and the peer can only truncate while its recorded root for us
still holds the keys) asked whether the ROOT is the right witness. It is
not: a root is a statement about the peer's TREE, and the tree loses exactly
what the peer compacted. This module models the previously shipped rule
(`Rule = "root"`) and the rule now built (`Rule = "rootvv"`: root OR the
peer's recorded applied VV — `peer_state` stores it; `compute_frontier_for/2`
reads it since 2026-09-04), with keys in HLC order (`Skew` bounds how far
a mint may run past what its replica has seen), the watermark door, the ETS
page GC (`Sweep = "all"`: a recorded root differing from the current tree
becomes unreadable at every truncation, which is what `peer_first_hole/2`'s
catch clause reports), inline or applier-backed folds (`AsyncApply`), and the
compaction sites' handling of never-applied events (`CapAtUnapplied`). Rows
exist for every member from the start (the post-first-round state). No
recency filter, no `mst_retention`, no rebootstrap: the claim is that with
every member live, confirmed compaction needs none of them.

Properties: `NoLoss` (an event a member has not applied is in some tree),
`PrefixClosed`, `NoHeld` (nothing at or below a watermark is held un-applied
— true in this scope, so the missing never-applied guard at the compaction
sites has nothing to guard until the recency filter is in play), `NoDrop` (a
truncation never removes an un-applied event), `RoundConfirmsApplied` (after
a completed round against `p`, everything `p` had applied is confirmed) and
`Convergence` (`<>[]` all trees empty and everything applied everywhere,
under WEAK fairness of every scheduled activity). Two replicas, `MaxSeq = 2`,
`Skew = 1` unless stated.

| Configuration | Result |
| --- | --- |
| `_Root2` — shipped rule, fused, pack backend | `RoundConfirmsApplied` violated in 6 steps (below) |
| `_Root2_AsyncSweep` — shipped rule, applier-backed, ETS GC | same, 6 steps; safety clean to that depth |
| `_RootVV2` — rule under proof, fused, pack backend | exhaustive clean: 43,019 distinct states, depth 14 |
| `_RootVV2_AsyncSweep` — rule under proof, applier-backed, ETS GC, cap ON | exhaustive clean: 284,781 distinct states, depth 20 |
| `_RootVV2_AsyncSweep_NoCap` — as above, compaction sites as shipped | **`NoDrop` violated in 7 steps** (below) — independent of the rule |
| `_Root2_Live` — shipped rule, ETS GC, `Skew = 0`, weak fairness | `Convergence` violated: a two-round lasso (below) |
| `_Root2_Live_NoSweep` — shipped rule, no GC, weak fairness | clean: 4,227 distinct states — at quiescence the pack backend converges |
| `_RootVV2_Live` — rule under proof, applier-backed, ETS GC, cap ON, weak fairness | clean: 26,366 distinct states, depth 20 — weak fairness suffices |
| `_Root3` — shipped rule, 3 replicas, `MaxSeq = 1`, `Skew = 0` | `NoLoss` violated in 5 steps (below) |
| `_RootVV3` — rule under proof, 3 replicas, `MaxSeq = 1`, `Skew = 0` | exhaustive clean: 2,550,058 distinct states, depth 23 |

**The root witness does not survive the peer's compaction** (`_Root2`):

```
Mint(1)    (1,1)            Mint(1)  (1,2)          Mint(2)  (2,1) at hlc 1
Sync(2,1)  r2 holds all three; confirm: root[1][2] = {(1,1),(1,2)}
Compact(2) r2's peer root lacks (2,1), whose key sorts between (1,1) and
           (1,2): frontier (1,1), truncated
Sync(1,2)  r1 records r2's root {(1,2),(2,1)} — (1,1), which r2 APPLIED
           and r1 still holds, is no longer certified by anything r1 has
```

`r1` now cannot truncate (1,1) until `r2` pulls again and confirms `r1`'s
root back — a window `r2`'s next pull closes again by re-recording the
suffix. Every `r1` pull in between re-ships the pages under (1,1). Under the
VV rule the same round records `vv[1][2] = [1 |-> 2, 2 |-> 1]`, which
certifies (1,1) whatever `r2`'s tree looks like.

**The shipped rule needs strong fairness on the ETS backend** (`_Root2_Live`):
after `r2` compacts everything and `r1` writes two more events, the lasso is
`Sync(2,1)` — `r2` pulls, its door drops the compacted keys, the page GC
unreads the root it just recorded; the confirm hands `r1` a usable full
root — then `Sync(1,2)` — `r1` re-records `r2`'s suffix root, `r2`'s confirm
gives `r2` a usable root. Each replica's compaction is possible in exactly
one of the two states, so neither is continuously possible and weak
fairness forces nothing. Compaction happens only if the tick lands in the
right phase, and the traffic runs until it does. Without the page GC the
same interleaving converges (`_Root2_Live_NoSweep`): at quiescence the pack
backend's defect is the re-shipment and the intermittent window, not a
stall.

**The compaction sites drop a held event** (`_RootVV2_AsyncSweep_NoCap`,
independent of the rule):

```
Mint(1) (1,1), (1,2) at hlc 1, 2    Mint(2) (2,1) at hlc 1
Sync(2,1)   r2 pulls; applier-backed, nothing folded yet
Compact(1)  r1 truncates everything r2 confirmed: watermark (1,2)
Sync(1,2)   r1 pulls (2,1): key below the watermark, never applied at r1 —
            the door HOLDS it (watermark_door/3), as designed
Compact(1)  the frontier is at the watermark, so the watermark catch-up
            runs: begin_async_catch_up/3 folds the range (wm, wm] — empty —
            and finalize truncates at or below wm, DROPPING (2,1) un-folded
```

The same happens on the frontier path: the catch-up folds `(wm, F]`, a held
event at or below `wm` is outside the range and inside the truncation.
Reachable in production whenever the compaction tick beats the applier's
`replay_cell_events` cast to a just-delivered below-watermark event
(a busy applier; a durable instance's WAL drain). Fix under `CapAtUnapplied`,
built 2026-09-04 as `capped_truncation_point/2`: a truncation point is
capped strictly below the first local key this replica has not applied —
the door's own hold, applied at the catalogue truncation site (retired
origins exempt: the applier declines them by design, which the model does
not represent). Under `AsyncApply` that also makes the catch-up fold
vacuous: nothing un-applied is ever below the point, so the async catch-up
(its token, watchdog and `pending_compaction` bookkeeping) had nothing left
to do — removed the same day, together with the applier's
`catch_up_apply/3` (a non-holding fold path that could raise the VV past a
contiguity gap; the model's exact-prefix VV assumed it away).

**A rootless row constrains nothing** (`_Root3`): `r1` mints, `r2` pulls it,
`r1` and `r2` compact it between themselves — `r3`'s rows at both carry no
root (its tree was empty at every round) and `bondy_oplog_compaction:
compact/1` dropped rootless rows by design ("that peer, if it ever needs the
truncated prefix, takes the bootstrap path"). `r3` never applied the event
and no tree holds it: the frontier-gap check on `r3`'s next round is the
only way back. Under the VV rule (built) a row with a zero VV holds
compaction until that peer's first round records what it applied — the
bootstrap fallback is no longer the plan for a live member.

`../isabelle/Confirmed_Compaction.thy` proves `NoLoss` and `NoDrop` for the
rule under proof with the cap, for any number of replicas and events, over
a model that drops the key order (any confirmed, applied subset may be
truncated; the door drops any applied subset, own events only if truncated
before — the one place key order enters, as a hypothesis this module
discharges).

Not modelled: the recency filter and `mst_retention` (both truncate past an
unconfirmed member by design), the join path (`Bootstrap`), the frontier-gap
check and catalogue rebootstrap (the repair for what this module shows must
not be needed), origin retirement reaping a VV entry (a reaped entry
certifies nothing — conservative), and page transfer (a round is atomic; the
re-shipment cost is stated, not counted).
