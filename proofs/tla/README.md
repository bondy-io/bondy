# TLA+: AAE round causal closure

**THIS WAS BUILT BY CLAUDE OPUS and it is not verified.**

Model-checks whether bondy_db's anti-entropy layer delivers a per-origin
**prefix-closed** set of events to each replica — the hypothesis two things in
`../isabelle/` take for granted.

```
java -cp tla2tools.jar tlc2.TLC -workers 4 -config AaeCausalClosure.cfg         AaeCausalClosure.tla   # ablation: violated in 6 steps
java -cp tla2tools.jar tlc2.TLC -workers 4 -config AaeCausalClosure_Shipped.cfg AaeCausalClosure.tla   # shipped: exhaustive, clean
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

**2. Is the delivered set prefix-closed? Not under ungated compaction without
the prefix hold.** `AaeCausalClosure.cfg` (`GatedCompaction = FALSE`, hold and
contiguous claim off) violates `NoOverClaim` in 6 steps (`PrefixClosed` too).
The hold closes it: see [The model verifies the fix](#the-model-verifies-the-fix).

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

Under `PrefixHold` integration applies the per-origin CONTIGUOUS CLOSURE of
local-applied ∪ peer-tree instead of the raw union (the tree still merges
fully — the hold is at the applied/projection level, as implemented). Under
`ContigClaim` the claim is the per-origin contiguous prefix, never adopted
from a peer.

| Configuration | Result |
| --- | --- |
| `AaeCausalClosure.cfg` — ablation: hold and contiguous claim off, ungated compaction, 3 replicas | violates in 6 steps — the regression pin |
| **`AaeCausalClosure_Shipped.cfg`** — the shipped combination: hold ON, contiguous claim ON, gap check ON, ungated compaction; 2 replicas, `MaxSeq = 2` | **exhaustive clean**: 1,523 distinct states, depth 15 |
| `AaeCausalClosure_Shipped_3R.cfg` — the same, 3 replicas | no violation in 18,922,940 distinct states before the 20-minute time guard; not exhaustive |

`Rebootstrap` retains the replica's OWN minted events, which survive in the
local WAL and are re-delivered after any clobber (commented in the spec); a
`Rebootstrap` that discards them reports a spurious `NoOverClaim` violation.
The shipped combination is checked at pairwise scope, the scope its config
header argues for (sync, hold and frontier logic are pairwise); no
three-replica run of it is recorded.

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
| `CellContextReap_R3S1_ReapTRUE_CausalTRUE.cfg` — reap on, causal delivery | clean, 5,046,890 distinct | clean |
| `CellContextReap_R3S1_ReapTRUE_CausalFALSE.cfg` — reap on, out-of-order delivery | clean, 10,570,826 distinct | **violated** in 6 steps |

Two replicas at `MaxSeq = 2`, reap on, causal delivery
(`CellContextReap_R2_ReapTRUE_CausalTRUE.cfg`) are exhaustively clean on
every invariant.

**Which cells the reap can see.** `ReapCell` only reaches a cell its
directory lists (`Listed`), as `primary_cell_directory/4` only hands
`reap_origins` the keys it enumerates. `Directory = "tree"` is the MST
walk the ETS adapter falls back to; `"projection"` is an adapter that
enumerates its own keys. `DirectoryComplete` and `DeadContextReachable` are
the properties the fix has to hold; `CellContextReap_R2_DirTree.cfg`
violates `DirectoryComplete` in 3 steps (mint, mint, compact; 20 distinct
states), the trace the registry is in after any compaction, and
`CellContextReap_R2_DirTree_Dead.cfg` violates `DeadContextReachable` in 3
steps (mint, compact, depart; 75 distinct states), which is the trace
`bondy_rib_reclamation_cluster_SUITE:departed_node_rib_state_is_reclaimed_after_compaction`
reproduces on a real cluster. The three earlier cfgs now pin
`Directory = "projection"`, the guard they ran under before it was named;
`_R2_ReapTRUE_CausalTRUE` is clean on all seven invariants at 1,354,631
distinct states and `_R3S1_ReapTRUE_CausalTRUE` at its recorded 5,046,890;
`_R3S1_ReapTRUE_CausalFALSE` still stops on `Convergence` at the same
depth, the new invariants silent before it.

**The reap does not resurrect and does not break convergence.** It moves the
stamped context down, so a later remove drops fewer dots at replicas that
still hold them — an error toward FALSE concurrency (extra siblings the CRDT
resolves), never toward lost causality, which is the direction
`bondy_oplog_applier`'s I1 note already names as acceptable. Nothing
interprets an existing event differently, because every event carries its own
context and is replicated verbatim.

**What the model did find is orthogonal to reaping.** `Convergence` — two
replicas that folded the same operation set hold the same value — fails
when delivery is not causal, and `ReapCell` never fires in the
counterexample. The shape is a three-party inversion: `r2`
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

Reaping a departed node's origin on a membership-derived condition (being
the sole surviving member, or a scalar HLC meet watermark) is rejected and not
implemented: `bondy_oplog_origin:load_or_create/1` reuses the persisted id,
so a node that rejoins resumes minting under the origin the survivors reaped.

`OriginRetirementSet.tla` replaces membership with a REPLICATED grow-only
retirement set, driven by an operator decommissioning a node. Three replicas,
`MaxSeq = 1` unless stated, `Join` enabled.

| Configuration | Result |
| --- | --- |
| `UniversalS1` — the shipped guard | **exhaustive clean: 17,013,691 states, 2,538,102 distinct** |
| `UnbannedS1` — retire + reap, ban NOT enforced | **`RetiredSkipIsSafe` violated in 5 steps** |
| `Universal` — the shipped guard, `MaxSeq = 2` | **exhaustive clean: 685,709,113 states, 95,684,190 distinct** |

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

What separates the candidate guards is log reclamation, which `CompactionModelled` adds: an event reclaimed from every
holder's log moves only by catalogue rebootstrap, and only a frontier deficit
flags one. `NoStuckEvent` says no replica is ever left wanting an event with
every route to it closed.

Judged with the survivors stable (`StableMembership = TRUE`), which is the
deployment the reap exists for — an operator removes one node and the rest
carry on:

| Guard (`ReapRule`) | `NoStuckEvent` | Can every member clear the entry? |
| --- | --- | --- |
| `"none"` — retirement alone (`NoneCompactS1`) | **violated in 7 steps** | — |
| `"meet"` — every member level on it (`MeetProbe`) | not recorded | **no** — exhaustive, 4,035 distinct |
| `"universal"` — every member has retired it (`UniversalCompactS1`, `UniversalProbe`) | clean: 662,464 distinct | **yes**, in 10 steps |

The right-hand column is `NotAllMembersReaped`, an inverted invariant: a
violation is a run in which every member dropped an entry it genuinely held,
so **holding** is the bad result. The meet rule holds it exhaustively, and the
reason is mechanical — only a reap lowers a claim, and a retired origin's
claim never rises again, so the first replica to reap leaves every other
replica permanently unequal to it. It never finishes: the entry
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
for c in Shipped CkptCommitKeyedRetention CkptEarlyMint CkptWal; do
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

Four configurations, `MaxSeq = 3`:

**`_Shipped`** — the code as read. Violated in 7 steps:

```
Reserve, Append(1), Apply(1), TruncateFlush(w=1), TruncateCheckpoint,
Stop, Restart
```

Final state: `tree = {}`, `wal = {1}` but `cursor = wm = 1` so it will not
replay, `ckpt = 1`, `acked = {1}`, `seqRef = 0`. The next mint is seq 1
again. A clean stop suffices; `Crash` gives the same.

**`_CkptCommitKeyedRetention`** — "seed from the restored frontier", but the WAL drops whatever
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

Commit-keyed retention with the frontier checkpointed before the truncated
root is flushed is not implemented: the checkpoint-after-root order is what
`resume_position/2` relies on.

**`_CkptEarlyMint`** — the restored-frontier seed, dropping the grant that no mint precedes the
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

## `ConfirmedCompaction.tla` — what a replica may truncate once its members have reported

```
for c in 2R_Async 2R_Async_Live 3R 3R_Async_Depth 3R_Partition 3R_Retire \
         2R_Async_Partition_Retire 2R_Async_NoCap 3R_DoorDrop \
         2R_Async_DoorKeep_Live 3R_Fresh_Partition \
         3R_Lost 3R_Lost_SkipWalk 3R_Lost_Ungated 3R_Lost_Uncapped \
         2R_Seq2_Lost 2R_Seq2_Lost_Uncapped 2R_Seq2_Lost_Live \
         2R_Seq2_Lost_NoHeal_Live; do
  java -cp tla2tools.jar tlc2.TLC -workers 4 -config ConfirmedCompaction_$c.cfg ConfirmedCompaction.tla
done
```

A round of `r` pulling from `p` reads `p`'s durable frontier
(`bondy_oplog_instance:durable_frontier/1`), merges `p`'s tree, records that
frontier against `p` (`bondy_oplog_peer_state:record_sync_complete/3`), then
reports `r`'s own durable frontier to `p`, which records it against `r`
(`confirm_frontier`). The durable frontier is the checkpointed one on a
durable backend and the applied one on ETS; a fused instance is ETS only.
Compaction truncates up to the largest key every key at or below which is
covered by every witness — every member's recorded frontier and the
replica's own durable frontier (`compute_frontier_for/2`, `member_vvs/2`) —
capped below the first key the replica has not applied
(`capped_truncation_point/2`). After a merge the watermark door truncates
the confirmed, applied prefix at or below the watermark (`watermark_door/2`).
Keys order by HLC (`Skew` bounds how far a mint may run past what its
replica has seen); folds run inline (fused) or in a separate replay
(`AsyncApply`, which also models the checkpoint as a separate step).

A page can go missing from a fused replica's own tree (`Lose`). Its keys stay
under the root, but nothing can read them. The replica's responder refuses
every pull, so its peers take what it applied from its projection by catalogue
re-bootstrap (`Rebootstrap`). The frontier walk stops at the missing page
(`compute_frontier_for/2`), so compaction and the door truncate nothing on a
cycle whose walk meets it. That cycle turns to the rebuild (`Heal`,
`rebuild_frontier/2`). Once every member's recorded frontier covers the
replica's applied frontier, the rebuild truncates the whole tree through the
compaction cap.

Properties: `NoLoss` (an event a member has not applied is in some tree),
`NoGap` (an event one member truncated, every member has applied or still
holds), `PrefixClosed`, `ConfirmedHeld` (a witness that confirms an event
holds it), `NoDrop` (a truncation never removes an un-applied event) and
`Convergence` (`<>[]` all trees empty and everything applied everywhere,
under weak fairness of every scheduled activity). With lost pages, a
projection is a copy too, so the lost-page configurations check two other
properties in place of `NoLoss` and `NoGap`:

- `NoErase`: some live replica has applied every event, or holds it on a
  readable page.
- `NoStrand`: when a replica truncates an event it applied, every live member
  holds or has applied that event, so no member needs a re-bootstrap for it.

| Configuration | Result |
| --- | --- |
| `_2R_Async` — the code, applier-backed, 2 replicas, `MaxSeq = 2`, `Skew = 1` | clean (948,191 states, depth 22) |
| `_2R_Async_Live` — as above, `Skew = 0`, `Convergence` | holds (83,666 states) |
| `_3R` — the code, fused, 3 replicas, `MaxSeq = 1` | clean (52,924 states, depth 16) |
| `_3R_Async_Depth` — the code, applier-backed, 3 replicas | no violation in 1,948,590 states to depth 14; bounded, not exhaustive |
| `_3R_Partition` — fused, two link cuts | clean (635,088 states, depth 20) |
| `_3R_Retire` — fused, one member removed | clean (296,223 states, depth 18) |
| `_2R_Async_Partition_Retire` — a link cut and a member removed | clean (8,533,719 states, depth 25) |
| `_2R_Async_NoCap` — no cap | clean (948,191 states, depth 22): the cap is not shown necessary |
| `_3R_DoorDrop` — the door drops unconfirmed events | **`NoGap` violated**, depth 8 |
| `_2R_Async_DoorKeep_Live` — the door drops nothing | **`Convergence` violated** |
| `_3R_Fresh_Partition` — a recency filter on the witnesses, two link cuts | **`NoLoss` violated**, depth 8 |
| `_3R_Lost` — the code, fused, 3 replicas, one page lost | clean (1,409,151 states, depth 19) |
| `_3R_Lost_SkipWalk` — the walk skips a lost page | **`NoStrand` violated**, depth 7 |
| `_3R_Lost_Ungated` — the rebuild needs no cover | **`NoStrand` violated**, depth 5 |
| `_3R_Lost_Uncapped` — the rebuild is not capped | clean (1,409,151 states): the cap is not shown necessary |
| `_2R_Seq2_Lost` — the code, 2 replicas, `MaxSeq = 2`, one page lost | clean (18,877 states, depth 14) |
| `_2R_Seq2_Lost_Uncapped` — as above, the rebuild is not capped | clean (18,877 states) |
| `_2R_Seq2_Lost_Live` — `_2R_Seq2_Lost`, `Convergence` | holds (18,877 states) |
| `_2R_Seq2_Lost_NoHeal_Live` — no rebuild, `Convergence` | **`Convergence` violated** |

**The door must confirm** (`_3R_DoorDrop`): `r2` compacts its own event once
`r1` and `r3` hold it, then pulls `r1`'s earlier event, whose key sorts below
`r2`'s watermark. A door that drops it on key order leaves `r3`, which never
received it, with nothing to pull it from.
`bondy_oplog_bootstrap_rederive_test:fused_door_keeps_what_a_member_lacks/0`
replays the trace against the code's door.

**The cap is not shown necessary** (`_2R_Async_NoCap`): the replica's own
durable frontier is a witness, and it covers only events the replica has
applied, so a confirmed frontier already stops below the first un-applied
key. `bondy_oplog_compaction_fused_test` also passes with the cap disabled.
The cap is the only guard on the retention frontier, which no witness
confirms and this model does not represent.

**Every member witnesses** (`_3R_Fresh_Partition`): two replicas cut off
from the third drop its row and compact with each other alone; once both
have truncated, the writes each side accepted alone are lost.

**A walk must not skip a lost page** (`_3R_Lost_SkipWalk`): `r1` loses the page
that holds its own `1:1` before `r2` has pulled it. A walk that skips the page
finds a later key that every member confirmed, and the truncation up to that key
takes `1:1` with it. `r2` can then receive `1:1` only by re-bootstrap.
`bondy_oplog_compaction_fused_test:unservable_own_root_holds_until_peers_dominate/0`
checks that the code truncates nothing in that state.

**The rebuild needs the cover and is needed** (`_3R_Lost_Ungated`,
`_2R_Seq2_Lost_NoHeal_Live`): without the cover, a rebuild drops an event a
member has not received. Without a rebuild, the lost page never clears and the
trees never empty. The cap changes no rebuild in these configurations
(`_3R_Lost_Uncapped`, `_2R_Seq2_Lost_Uncapped`), so they do not show it
necessary. The code keeps the cap so that one compaction tail serves both.

`../isabelle/Confirmed_Compaction.thy` proves `NoLoss` and `NoDrop` for the
same rule, for any number of replicas and events, over a model with no key
order, and with frontiers recorded independently of the merge: a report
records the frontier of any prefix-closed subset of what the peer has
applied, which covers a durable frontier recorded late, out of order, or not
at all.

Not modelled: crashes (the checkpointed frontier as a crash witness is
checked in `JoinInstall.tla`), `mst_retention`, origin retirement, the join
path, the frontier-gap check, a catalogue re-bootstrap from a servable peer, a
lost page on an applier-backed replica (it keeps its tree), the causal hold of
the fused replay (a held event on a lost page), a report that does not reach
its peer, and page transfer (a round is atomic).

## `MuxBucketSkip.tla` — can the frontier claim a cell whose BUCKET had no context?

`AaeCausalClosure.tla` models delivery as though every delivered event lands in
`applied`; its only loss channel is a per-origin contiguity hole. That
abstraction hides a second one. A shard instance multiplexes several tables
onto one oplog, each tagged with a **bucket**; the instance is founded by the
first table opened on it and siblings register later, so the routable bucket
set GROWS while the instance is already serving anti-entropy — and a restart
drops it back to the founding bucket while the durable frontier survives
intact. A cell whose bucket does not resolve is skipped, and both the fold and
the bootstrap can then report a frontier entry the projection does not hold.

**Yes — by two independent routes.** This module isolates them and checks the
five mechanisms that close them.

### The two channels

1. **The fold.** `apply_cell_pairs_mux/5` groups a replay batch by bucket,
   drops the groups that do not resolve, and merges the frontier per
   *surviving* group. A skipped sibling does not hold the merge back, and with
   `Held = 0` the replay cursor advances past the dropped cells, so nothing
   re-presents them.
2. **The bootstrap.** `finalize_catalogue_bootstrap/5` max-merges the peer's
   whole version vector after an install that skipped whatever it could not
   route. The peer's own `build_targets/2` enumerates the buckets to scan from
   the peer's registry, so a peer still opening its tables **under-ships while
   answering `get_frontier` in full** — the asymmetry is the defect, and a
   model whose `reg` only ever grows is structurally incapable of expressing
   it.

The second route is why closing the first is not enough: a claim rule that
bounds the fold says nothing about a vector adopted wholesale from a peer.

### The mechanisms, and which are load-bearing

TLC 2.19, `Spec`/`FairSpec`, 2 replicas, 2 buckets, `MaxSeq = 2`, one restart
per replica. Invariants `TypeOK`, `NoOverClaim`, `NoStrandedCell`; `Live`
where noted.

| Config | Mechanism removed | Result |
| --- | --- | --- |
| `Final_Skew` | — (all five, `VersionSkew = TRUE`) | clean + `Live`, 20,736 distinct |
| `Final_NoSkew` | — (all five, transient window only) | clean + `Live`, 126,529 distinct |
| `Final_3r` | — (all five, 3 replicas, `MaxSeq = 1`) | clean, 7,227,093 distinct |
| `Minus_AdoptIfComplete` | bootstrap adopts unconditionally — **the shipped rule** | **`NoOverClaim` violated** |
| `Minus_ServeGate` | responder serves before its directory is complete | **`NoOverClaim` violated** |
| `Minus_SkipHole_Contig` | fold hole **and** contiguous claim | **`NoOverClaim` violated** |
| `Minus_GateOnRegistration` | initiator gate | clean |
| `Minus_GapVerdict` | the frontier-gap verdict, for a deficit this replica cannot close | **`Live` violated** |

The `Minus_GapVerdict` row answers the question that comes up the moment the
claim is withheld. Withholding leaves the replica permanently behind that
peer, so every round raises a gap and schedules a re-bootstrap that installs
the same partial projection again — an obvious candidate for suppression, since
no re-bootstrap can ever close that deficit. **Suppressing it costs `Live`,**
and the counterexample says why in one step: r2 holds both events in its tree,
`Replay(r2)` is enabled and fires as a permanent no-op, and `applied[r2]` never
grows. The per-origin hold parks the routable seq behind the unroutable one,
and `CatalogueBootstrap` is the ONLY action in the module that writes `applied`
without passing through the fold. The cycle is not waste; it is the sole
delivery path for exactly the data the hold parks. What ends it is an operator
resolving the skew — which is why the condition must raise an alarm rather than
be optimised away.

**Removing both `SkipIsHole` and `ContigClaim` opens the fold channel**
(`Minus_SkipHole_Contig`); removing either alone is not recorded here. And
`GateOnRegistration`, the initiator half of the readiness
gate, is **not load-bearing for these invariants at these bounds**: once the
bootstrap withholds an unsound claim, gating the initiator buys no safety. Its
justification is that it avoids a bootstrap that installs a partial projection
and can then claim nothing — behaviour, not soundness. Say that, not more.

`Minus_AdoptIfComplete` is the shipped state and it violates in 4 steps: r1
registers `b2`, mints `(r1,1)` into it, r2 bootstraps. r2's declared set is
`{b1}` so the initiator gate is open; r1's directory is complete so the
responder gate is open. r2 installs nothing and claims `r1 |-> 1`.

### `Declared(r)`, not the global bucket set

An earlier version gated on `reg[r] = Buckets` and concluded the registration
gate was safe but DEAD under version skew. That was an artefact of the wrong
predicate: it modelled a gate no orchestrator would build.
`bondy_db:start_draining/1` releases the real gate once the catalogue has
opened every table **it declares**, which is bounded and always reached. The
model uses `Declared(r)` throughout.

### Why withhold the claim rather than refuse the bootstrap

Refusing to finalize a bootstrap that skipped anything is also sound, and it
**violates `Live`** under version skew: a bucket this build has no table for
never becomes routable, so the replica never bootstraps and never receives the
data it *can* route. Withholding only the claim keeps `Live` (`Final_Skew`).
The two rules differ in what they do with a permanent condition, and only one
of them terminates.

A rule that derives the claim from what *installed* is unavailable, not merely
worse: a shipped cell is `{Bucket, Key, Frame}` carrying no origin and no seq.
An earlier version of this module computed one anyway, under `ContigClaim`, and
it **masked the bootstrap channel** — every configuration pairing the shipped
fold fix with the shipped bootstrap came out clean for that reason alone. The
bootstrap claim now has only the two implementable options.

`Bucket_Skip_Soundness.thy` discharges both channels unbounded:
`contig_claim_sound` for the fold, `adopt_if_complete_sound` for the bootstrap
— the latter carrying the responder gate as a hypothesis, with
`unconditional_adoption_unsound` and `adoption_unsound_without_serve_gate`
refuting each half by a concrete witness.

### Code status

| Mechanism | Code |
| --- | --- |
| `SkipIsHole` | **BUILT** — `bondy_oplog_cell_apply:partition_contiguous/4` draws its contiguous run from the routable seqs |
| `ContigClaim` | **BUILT** — `bondy_oplog_registry:merge_applied/2` reports a prefix, out-of-order seqs held in `pending` |
| `ServeGate` | **BUILT** — `bondy_oplog_responder` refuses `get_catalogue_snapshot_init` while `bondy_oplog_registry:tables_registered/1` is false |
| `GateOnRegistration` | **BUILT** — `bondy_oplog_sync_scheduler:default_dispatch/2` |
| `AdoptIfComplete` | **BUILT** — the install returns `unclaimable`, the buckets whose cells did not land for a reason no local value covers, and `bondy_oplog_sync_session:adopt_frontier/3` passes the peer's vector to `finalize_catalogue_bootstrap/5` only when it is empty. `skipped` could not decide it: three causes (unroutable bucket, decode error, HLC-older) share that one integer and only the first two are unsound |

### Bounds

2 replicas, 2 buckets, `MaxSeq = 2`, one restart each; plus one 3-replica run
at `MaxSeq = 1`. Three replicas at `MaxSeq = 2` does **not** close — it passed
64M distinct states still at depth 18 and was abandoned, so the 3-replica
evidence covers one event per origin only. Compaction, the MST, HLCs and
network failure are not modelled — the loss needs none of them. No refinement
proof links this module to the Erlang.
---

## `FrontierPending.tla` — one integer per origin, or a prefix and a pending set?

The section above ends by recording what shipped: a cap on the claim itself.
That function (`merge_batch_frontier/4`) was reverted; its successor is
`bondy_oplog_cell_apply:claim/2`, built in `_design/applied_frontier.md`
increment 3 — per origin, the highest seq that materialised, strictly below the
lowest seq **this batch** observed failing. Its own docstring records the limit:
a failure in another batch is out of its reach. This module measures that limit
and the two candidate representations against the same interleavings.

What `MuxBucketSkip.tla` could not see is that the claim is computed **once per
batch** and joined into a stored integer, and that batch boundaries are set by
drain timing. So the question is not which arithmetic to use. It is whether a
single integer can carry what one batch learns to the batch that needs it.

### It cannot, and that is a theorem, not a config

`proofs/isabelle/Frontier_Pending.thy` discharges the universal statement TLC
cannot reach: for **any** writer whose state is one integer per origin, if it is
sound on every schedule then on `[({2}, {}), ({1}, {})]` it ends reporting 1
while the projection holds `{1, 2}` (`no_scalar_writer_sound_and_complete`).
Neither schedule contains a failure. This module supplies what the theory does
not model — concurrency, restarts, the compaction door, and the two channels
`MuxBucketSkip.tla` separated.

### Modelling corrections made during the run

Two results came back wrong the first time, and both were the model, not the
design:

1. **`ApplyBatch` took an arbitrary subset of the inbox**, so it could present
   seq 2 while seq 1 sat queued. The applier drains in arrival order. With
   `InOrderDelivery` (arrival order = seq order) a batch is now a per-origin
   prefix of the inbox, which is exact; without it the two orders differ and the
   arbitrary subset stands in for an arrival-order prefix, an over-approximation
   the module states. Before the fix, the shipped rule appeared unsound even
   with in-order delivery and every bucket routable — an artefact.
2. **`Truncate` dropped a single entry.** Both truncation sites truncate a
   PREFIX capped below the smallest key the frontier does not claim
   (`watermark_door/3` truncates below `MinHeld`; `capped_truncation_point/2`
   below the first never-applied key). `TruncatePrefixOnly = TRUE` is the code,
   and every configuration sets it.

Weak fairness on `\E B : ApplyBatch(B)` was also not enough for the liveness
runs: it is satisfied by an adversary that presents the same proper subset
forever. The fold's fairness is strong and on the full drain,
`SF_vars(ApplyBatch(inbox))`.

### Results

Exhaustive. `Origins = {o1}`, `MaxSeq = 3`, `Buckets = {b1, b2}`, door on and
prefix-capped, unless the row says otherwise.

| Configuration | Result |
| --- | --- |
| `FrontierPending_MaxCap.cfg` | `NoOverClaim` violated, 28 distinct states |
| `FrontierPending_Contig_Dead.cfg` | `Complete` violated, 354 distinct states |
| `FrontierPending_Pending.cfg` | clean, 532 distinct states |
| `FrontierPending_Pending_TwoOrigins.cfg` | clean, 4,160 distinct states |
| `FrontierPending_Pending_Restart.cfg` | clean, 1,476 distinct states |
| `FrontierPending_Pending_Restart_NoRefold.cfg` | `EventuallyComplete` violated, 1,194 distinct states |

```
java -cp tla2tools.jar tlc2.TLC -workers 4 -config FrontierPending_<c>.cfg FrontierPending.tla
```

### The trace worth reading

**The prefix bound is sound and dead** (`_Contig_Dead`). Everything arrives,
every bucket routes, the projection holds all three seqs — and the entry reports
1, because the seq folded while the hole was open was recorded nowhere.

A compaction door that reads the pending half is not implemented:
`never_applied/2` stays on the prefix, and the truncation cap already holds
everything above the hole.

## `RibAbs.tla`, `RibReading.tla` — a RIB cell's reading across reboots, reopens and restarts

**Question.** A registry RIB cell carries the owner's latest reading of its live
local entries, `{Stamp, Count}` (`bondy_oplog_crdt_owned_reading`), and a
replica's count is that of the highest-stamped reading it holds. Peers route by
a stub refreshed only by a merge event. When the owner reboots, when its
registry DB is reopened in a running VM, or when one oplog instance of that DB
restarts, do every replica's cell and every peer's stub settle on the owner's
live count?

```
java -Xmx8g -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC -workers 4 -config RibAbs_Shipped.cfg     RibAbs.tla
java -Xmx8g -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC -workers 4 -config RibReading_WallAhead.cfg RibReading.tla
```

**What the shipped configuration encodes.** Each flag names the code it stands
for:

- `Durable = FALSE`: the registry DB is in memory and takes a fresh origin on
  every open.
- `HealAlways = TRUE`: the owner answers every echo of its own cell with its
  current reading (`bondy_registry_rib`'s `restate/4`).
- `ReopenEnabled`, `RestartReopens = TRUE`: the death of any process the
  registry tables run on reopens the whole DB, and every open restores each
  group's reading (`bondy_namespace_catalog`, `bondy_registry_rib:restore/0`).
  An instance restart loses the events the instance had not shipped.
- `SweepOnce = TRUE`: a swept origin is never rescanned (`reap_complement/4`).
- `StubFollowsCell = FALSE`: the orphan-stub sweep acts only on departed
  nodes, and the owner here stays a member.

Properties hold on settled states (no action enabled); a run cut short by the
stamp bound is excluded (`Truncated`). All configurations: `MaxOps = 2`,
`MaxResets = 2`.

| Configuration | What changes | Result |
| --- | --- | --- |
| `RibAbs_Shipped` | shipped; 2 peers, stamps ≤ 4 | exhaustive clean: 115,078,878 distinct states, depth 38 |
| `RibAbs_Shipped_Stamp5_OnePeer` | shipped; 1 peer, stamps ≤ 5 | exhaustive clean: 15,538,045 distinct states, depth 37 |
| `RibAbs_NoRestart_Stamp5` | no instance restarts; 2 peers, stamps ≤ 5 | exhaustive clean: 76,851,033 distinct states, depth 42 |
| `RibAbs_RestartNoRestore` | a restart neither reopens nor restores | **`SettledCellIsTruth` violated at depth 8** |
| `RibAbs_HealOnAbsent` | restate only when the owner's cell is empty | **`SettledStubIsTruth` violated at depth 20** |
| `RibAbs_HealOnForeignTop` | restate only when the top reading is another origin's | **`SettledStubIsTruth` violated at depth 14** |
| `RibReading_WallAhead` | HLC; the wall clock may step back, but not past a held stamp; 1 peer | exhaustive clean: 6,882,826 distinct states, depth 36 |
| `RibReading_WallStepBack` | HLC; the wall clock may step back past a held stamp; 1 peer | **`SettledStubIsTruth` violated at depth 17** |

**The counterexamples.**

- `RestartNoRestore`: two registrations take their stamps, then the instance
  restarts before either reading is written. Nothing reached a peer, so no echo
  arrives to be answered, and the cell reads 0 against 2 live.
- `HealOnAbsent`, `HealOnForeignTop`: the owner reaps its own copy of an echoed
  reading before it restates, so the condition for restating is false, while
  the peers' stubs still hold the old count. A reap fires no merge event, so
  nothing refreshes them. What the owner's cell shows says nothing about what
  its peers route by, which is why the owner answers every echo.
- `WallStepBack`: the new incarnation's restatement is stamped
  no higher than the reading it must replace, so a peer keeps the old count in
  its stub, and the reap later empties the cell without refreshing it.

**The clock.** `RibAbs.tla` stamps with an integer counter; a reading is
compared only by the order of its stamp, so the counter stands for any clock
whose stamps strictly increase over the owner's lifetime. `RibReading.tla`
models the HLC itself (`bondy_connect_hlc:now/1`: a physical tick of `K` logical
values, the wall clock moving on or back by up to `StepBack` across a reboot),
with the same policy, to check that condition instead of assuming it. It holds
when the wall clock does not go back past a stamp a replica holds, and fails
when it does. That is the assumption `bondy_registry_rib`'s moduledoc states.
An instance restart does not restart the clock: it lives in the VM
(`bondy_registry_rib:init/0`), so `RibReading.tla` has no restart action.

**Not established.**

- `RibAbs_Shipped` with 2 peers and stamps ≤ 5 was stopped by the disk guard at
  230M distinct states with no violation; it is not a proof.
- Two writers, two operations, two resets. A third concurrent writer is covered
  by `bondy_registry_rib_test`'s concurrent-writer test, not by the model.
- The subscription cell (a bare reading) is covered by the same argument; only
  the count is modelled.
- End to end, the restores are exercised by `bondy_registry_SUITE`'s
  `rib_restored_after_*` cases, one per way the DB can lose state.

## `ReadCache.tla` — can a read-cache fill outlive the write it raced?

**Question.** A reader that misses the per-shard read cache reads the
projection and fills the cache; every projection write is followed by a
delete of that key from the cache. If the write and its delete both land
between the reader's projection read and its fill, the fill installs the older
value and nothing removes it. `bondy_db_read_cache_race_test` forces this
interleaving.

**Protocol modelled** (`bondy_oplog_cache_ets`, `bondy_oplog_core`). An
invalidation (`delete/3`, `invalidate_all/1`) advances a per-shard generation
and then deletes. A reader takes the generation as a ticket before its
projection read; `fill/5` inserts, re-reads the generation, and deletes its
own row if the generation moved.

**Model.** One key, readers that fill on a miss, writers that write the
projection then invalidate, and eviction at any time. `SettledCoherent`: once
every process is idle, the cache holds nothing or the projection's value.

| Config | Readers / writers / writes | Result |
|---|---|---|
| `ReadCache_Ship` | 3 / 2 / 4 | holds; 6,367,393 distinct states, depth 29 |
| `ReadCache_Head` (no ticket) | 3 / 2 / 4 | violated in 9 steps |
| `ReadCache_Swap` (delete, then advance) | 3 / 2 / 4 | violated in 10 steps |
| `ReadCache_RAW` (`WritersIdleCoherent`) | 3 / 2 / 4 | violated in 9 steps |

**Not established.**

- `WritersIdleCoherent` fails by design: a cache hit that runs while a
  raced fill is between its insert and its re-check returns the older value,
  after the write has returned. The window closes when that `fill/5` returns.
  Closing it would need hits to validate too.
- Eviction is modelled as a delete at any time, not as the `max_entries` policy.
- The swapped order (`ReadCache_Swap`) is caught by the model only; the
  deterministic test cannot place a fill between the two steps of one
  invalidation.

## `IndexIntents.tla` — can a node keep its secondary index without a rebuild after a crash?

**Question.** A node opens after an unclean shutdown. Must it rebuild every
secondary index from its primary, or can it re-apply only the index ops that
did not reach the index store? And does the index stay equal to the primary
after a catalogue install, which writes primary cells outside the WAL?

**Protocol modelled.**
- **Write path.** Each primary shard's applier folds a batch of events into one
  `put_batch` and computes each event's index ops from the cell's old and new
  value (`bondy_oplog_cell_apply`). It then dispatches the ops to the one
  secondary writer that serves every shard (`bondy_oplog_secondary_writer`).
- **Crash.** A store write is one leveled `book_mput`, kept or dropped whole. A
  crash keeps every synced entry of each store and either a prefix or any
  subset of the rest, independently per store.
- **Checkpoint and barrier.** A checkpoint syncs the stores, then records what
  the shard has applied. The compaction barrier flushes the writer first.
  After a crash, every event the checkpoint does not claim is presented again.
- **Install and rebuild.** A catalogue install writes or deletes cells
  directly. A rebuild clears the index, re-folds every primary, flushes, and
  marks the index trusted (`bondy_oplog_index_rebuild`).
- **Clean close** (`CleanReopen`). The primaries stop with nothing left to
  apply or dispatch, both stores sync, and the open that follows trusts the
  index and runs no rebuild. With `Intents = FALSE` the writer flushes first;
  with intents the close discards the writer's buffer
  (`bondy_oplog_secondary_writer:reset/1`) and the open replays it.

**Mechanism** (`Intents = TRUE`). The `Dispatched`, `InstallBatch` and
`UnmarkLost` configs are meant to model the code; they differ in their bounds
and in the failures they allow.
- **Intent in the cell's batch.** A batch that yields index ops stores them as
  an intent in the same `put_batch`. Each event takes the next version of its
  shard's counter.
- **Version recorded in the index batch.** Every index batch records, per
  shard, the highest version it writes.
- **Barrier clears per shard** (`ClearBound = "dispatched"`). After flushing
  the writer and syncing the index, the barrier clears a shard's intents up to
  the version the shard had dispatched when the barrier began. It clears
  nothing while a rebuild is due (`ClearMarked = FALSE`).
- **Replay after registering.** A restarted writer, and a node at open,
  registers for dispatch and then replays the leftover intents of every
  shard. A trusting open flushes the writer before it freshens the index, and
  does not freshen when that flush fails. A full rebuild runs only for an
  untrusted index.
- **Install.** An install writes intents with its cells. A group of cells
  syncs the primary before its first cell
  (`bondy_oplog_cell_apply:begin_install/1`) and, when the group has ops,
  syncs the primary again at its end and then dispatches them
  (`settle_install/3`).
- **Order by version.** Index cells are ordered by the version, not the cell
  HLC. After a crash, a shard's counter restarts at the highest version its
  primary or the index records.
- **Rebuild trust mark.** The first request removes the trust mark
  best-effort (`bondy_oplog_core_registry:index_mark_rebuild/1`). The rebuild
  removes it again and fails if it cannot (`index_untrust/1`), syncs the
  index, then wipes it. It marks the index trusted only if the writer that
  took its re-fold flushed it, and no new request arrived while it ran.

**Properties.** `IndexMatchesPrimary`: once nothing is in flight and the index
is trusted, the index holds exactly the terms of the primary.
`FreshMeansComplete`: an index the open freshened holds every op the open
replayed.

Unless a row says otherwise, these bounds apply: one shard, values
`{none, a, b}`, two events, batches of up to two, one install, one node crash.
A violated row gives the length of the counterexample in steps.

The code's mechanism:

| Config | Differs from | Result |
|---|---|---|
| `Dispatched` | `Intents`: clear up to what the shard had dispatched | holds; 762,961, depth 20 |
| `Dispatched_Subset` | `Dispatched`: a crash keeps any subset of unsynced entries | holds; 1,095,364, depth 20 |
| `Dispatched_2Shards` | `Intents_2Shards`, as `Dispatched` | holds; 792,427, depth 20 |
| `Dispatched_Writer` | `Intents_Writer`, as `Dispatched` | holds; 2,936,617, depth 27 |
| `Dispatched_Saturation` | `Intents_Saturation`, as `Dispatched` | holds; 1,403,547, depth 23 |
| `Dispatched_Clean` | `Intents_Clean`, as `Dispatched` | holds; 3,293,770, depth 23 |
| `Dispatched_Remark` | `Dispatched`: two backlog drops, so a request arrives during a rebuild | holds; 4,888,911, depth 26 |
| `Dispatched_Subset_Rebuild` | `Dispatched_Subset`: two shards, a backlog drop, values `{none, a}`, batches of one, no install; only the index keeps any subset | holds; 18,408,740, depth 27 |
| `InstallBatch` | `Dispatched`: two installs in one group | holds; 21,135,383, depth 23 |
| `UnmarkLost` | `Dispatched_Saturation`: a best-effort removal of the trust mark may be lost | holds; 2,224,775, depth 23 |
| `UnmarkLost_Remark` | `Dispatched_Remark`, as `UnmarkLost` | holds; 11,481,937, depth 26 |
| `UnmarkLost_2Shards` | `Dispatched_Subset_Rebuild`, as `UnmarkLost`, the index keeps a prefix | holds; 21,688,093, depth 27 |

Each mechanism with one part removed:

| Config | Differs from | Result |
|---|---|---|
| `DrawnBound` | `Dispatched`: clear up to the counter, undispatched ops included | violated in 4 steps |
| `OpenSeed` | `Dispatched`: a shard's dispatched version at open is its counter | violated in 5 steps |
| `OpenNoFlush` | `Dispatched_Clean`: the open freshens without flushing the writer | violated in 4 steps (`FreshMeansComplete`) |
| `FreshenWithoutFlush` | `Dispatched_Writer`: the open freshens after a failed flush | violated in 5 steps (`FreshMeansComplete`) |
| `ClearMarked` | `Dispatched_Remark`: the barrier clears while a rebuild is due | violated in 10 steps |
| `Dispatched_Saturation_NoWipe` | `Dispatched_Saturation`: the rebuild does not clear the index | violated in 8 steps (a dropped remove survives the rebuild) |
| `Dispatched_Saturation_NoRefold` | `Dispatched_Saturation`: the rebuild's re-fold dispatches nothing | violated in 5 steps |
| `NoSyncBeforeWipe` | `Dispatched_Subset_Rebuild`: no index sync between removing the mark and the wipe | violated in 11 steps |
| `NoSyncBeforeMark` | `Dispatched_Subset_Rebuild`: no index sync before the trust mark | violated in 14 steps |
| `UnmarkLost_2Shards_NoRebuildUnmark` | `UnmarkLost_2Shards`: the rebuild does not remove the mark itself | violated in 11 steps |
| `UnmarkLost_NoRebuildUnmark` | `UnmarkLost`, as above | holds; 1,313,679, depth 23 (one shard does not reach it) |
| `InstallBatch_NoSync` | `InstallBatch`: no sync at the end of an install group | violated in 8 steps |
| `Intents_Subset_NoInstallSync` | `Intents_Subset`: no sync before an install group's first cell | violated in 9 steps (an install survives a crash that loses an earlier write) |
| `MarkWithoutFlush` | `Intents_Rebuild` with two writer crashes: mark after a failed flush or writer restart | violated in 12 steps (one crash triggers the rebuild, the second loses its re-fold) |
| `DrainRequests` | `Intents_Rebuild`: mark and drop a request that arrived during the rebuild | violated in 10 steps |
| `IntentsVersion` | `Intents_Saturation`: recover the version from the primary only | violated in 11 steps (a rebuild's version is not in the primary) |
| `ReplayBeforeStamp` | `Intents_Writer`: replay before registering | violated in 5 steps |
| `WriterBound` | `Intents_2Shards`: clear up to the writer-wide highest version | violated in 8 steps |
| `HlcOrder` | `Intents`: order by the cell HLC | violated in 5 steps (an install at an older HLC) |
| `SeparateBatch` | `Intents`: the intent in the next batch | violated in 5 steps |
| `ClearBeforeSync` | `Intents`: clear without syncing the index | violated in 5 steps |
| `BatchVersion` | `Intents`: one version per batch | violated in 3 steps (put and remove of one batch tie) |
| `VersionReset` | `Intents`: the counter restarts at zero | violated in 7 steps |
| `InstallDispatch` | `Intents`: an install dispatches without syncing the primary | violated in 7 steps |
| `NoInstallIndex` | `Intents`: an install yields no index ops | violated in 2 steps |

The same mechanism with the barrier clearing up to the version the index
records (`ClearBound = "source"`):

| Config | Differs from | Result |
|---|---|---|
| `Intents` | — | holds; 781,864, depth 20 |
| `Intents_Subset` | `Intents`: a crash keeps any subset of unsynced entries | holds; 1,117,147, depth 20 |
| `Intents_2Shards` | `Intents`: two shards sharing the writer, batches of one, no install | holds; 1,033,739, depth 20 |
| `Intents_Writer` | `Intents`: a writer crash, batches of one, no install | holds; 3,043,052, depth 27 |
| `Intents_Saturation` | `Intents`: a backlog drop, batches of one, no install | holds; 1,407,969, depth 23 |
| `Intents_Rebuild` | `Intents_Saturation`: a writer crash, values `{none, a}` | holds; 26,681,686, depth 32 |
| `Intents_Clean` | `Intents`: one clean close and trusting open | holds; 3,412,587, depth 23 |

Without intents (`Intents = FALSE`): every open after a crash rebuilds.

| Config | Differs from | Result |
|---|---|---|
| `NoIntents` | no intents; a full rebuild at every open; batches of one, no install | holds; 86,000, depth 18 |
| `NoIntents_Install` | `NoIntents`: one install | violated in 3 steps |
| `NoIntents_NoRebuildAtOpen` | `NoIntents`: no rebuild at open | violated in 3 steps |
| `NoIntents_Writer` | `NoIntents`: a writer crash | violated in 8 steps |
| `NoIntents_Writer_MarkNeedsFlush` | `NoIntents_Writer`: the rebuild's mark checks the writer | holds; 3,635,337, depth 25 |
| `NoIntents_Version` | `NoIntents`: order by the version | holds; 86,000, depth 18 |
| `NoIntents_Version_Writer` | `NoIntents_Writer_MarkNeedsFlush`: order by the version | holds; 3,539,427, depth 25 |
| `NoIntents_Version_Clean` | `NoIntents_Version`: one clean close and trusting open | holds; 177,105, depth 19 |
| `NoIntents_Version_Clean_Reset` | `NoIntents_Version_Clean`: the counter restarts at zero | violated in 6 steps (a remove after the clean open ties the live entry) |

**Matching tests.** `bondy_db_shared_shards_clear_test:rebuild_restores_stale_index/1`
covers the rebuild's wipe and re-fold on co-located tables
(`Dispatched_Saturation_NoWipe`, `Dispatched_Saturation_NoRefold`). In
`bondy_db_index_coldstart_test`:
- `install_keeps_the_index/1` and `install_syncs_before_its_first_cell/1` for
  the install (`InstallBatch`, `Intents_Subset_NoInstallSync`);
- `failed_unmark_blocks_the_wipe/1` for the rebuild's removal of the trust
  mark (`UnmarkLost_2Shards`);
- `clean_reopen_orders_new_ops_above_old/1` for the counter seed
  (`NoIntents_Version_Clean_Reset`).

**Not established.**
- `Intents_Rebuild` allows one writer crash. `MarkWithoutFlush` needs two, so
  the rebuild's flush check is shown necessary but not shown sufficient with
  two writer crashes: `Intents_Rebuild` with two writer crashes found no
  violation in 19,967,449 states before the guard stopped it, incomplete.
- `UnmarkLost_NoRebuildUnmark` holds: with one shard, the lost removal is not
  reached. `UnmarkLost_2Shards_NoRebuildUnmark` shows it.
- `HlcOrder` fails only through an install. Without installs, ordering by the
  cell HLC is not shown to be wrong.
- The model has one index and gives each shard one key. A failed index
  computation (`index_ops_for_cell` raising) is not modelled.
- That a rolled leveled journal file can lose entries a later file keeps is
  read from `leveled_cdb:close_file`, not probed. The `_Subset` configs cover
  it either way.

## `AuthFence.tla` — can a node authenticate on a security view that misses a revocation?

**Question.** The authentication fence (`bondy_auth:security_fence/0`) lets a
node authenticate only while its view of the security tables was confirmed
within `max_lag`. Which events may confirm it?

**Protocol modelled.** Two nodes; `r1` revokes a user. A sync round pulls a
peer's view and confirms the puller. A round with no peer confirms a node with
clustering off, and a clustered one only under `Policy = "proceed"`. A
partition cuts the nodes apart. `CommitBumps` makes a local commit confirm too.

**Property.** `FenceSafe`: once the revocation is older than `MaxLag`, a node
whose fence passes has seen it.

Bounds: `MaxLag = 1`, `MaxTime = 5`.

| Config | Differs from | Result |
|---|---|---|
| `AuthFence_Refuse` | — two clustered nodes, policy `refuse` | holds; 1,022 distinct states |
| `AuthFence_Single` | one node, clustering off | holds; 91 |
| `AuthFence_Refuse_CommitBumps` | `AuthFence_Refuse`: a local commit confirms | violated in 5 steps (a cut-off node that writes passes without the revocation) |
| `AuthFence_Proceed` | `AuthFence_Refuse`: policy `proceed` | violated in 6 steps (the trade-off `proceed` accepts) |

`AuthFence_Refuse` is not vacuous: checked against an invariant that no node
passes after the revocation is older than `MaxLag`, TLC finds one that does,
by syncing after the revocation.

**Matching test.** `bondy_db_bookie_restart_test` (`assert_ae_targets_kept/3`):
local writes leave the shards stale, one anti-entropy round confirms them.

**Not established.** The model has two nodes and one revocation. `quorum` is
not modelled.
