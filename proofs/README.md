# Formal verification: causal-stabilization soundness

**THIS WAS BUILT BY CLAUDE OPUS and it is not verified.**

Machine-checked model of the claim `bondy_oplog_applier.erl` makes in its
PREPARE FENCE section — that invariants I1 and I2 recover TCSB-grade causal
stability in an anti-entropy architecture with no causal broadcast layer —
and of the exact boundary of the license that claim extends.

Since the original development the scope has grown past that one claim. This
file is the **index of record** for everything under `proofs/`: it carries
every result, every verdict, and the proved-vs-built status of each, so that
answering "what has been established?" does not require reading the theories
or the TLA+ modules again. `tla/README.md` carries the long-form narrative
(counterexample traces, CT iterations, design rationale); this file carries
the conclusions.

**Status:** builds clean under Isabelle2025-2. No `sorry`, no `oops`, no
`axiomatization`. Scope is the stabilization argument only; datatype
convergence is *not* covered (see [Scope](#scope)).

```
cd proofs/isabelle && isabelle build -D .

# TLA+ (tla2tools.jar is NOT vendored — fetch from the tlaplus releases page)
java -cp tla2tools.jar tlc2.TLC -workers 4 -config <cfg> <module>.tla
```

| Theory | Contents |
| --- | --- |
| `Oplog_Model.thy` | Events, dots, contexts, I1, I2, the stability theorem |
| `Stabilization.thy` | Reduction soundness; the HLC-governed reduction class; `vector_stable` |
| `Aw_Counterexample.thy` | The refutation for observed-remove, and the positive struct-field case |
| `Hlc.thy` | The hybrid logical clock; discharges hypothesis H3 |
| `Dot_Exactness.thy` | Exactness of the compact `Ctx[O] >= S` test **under** per-origin FIFO |
| `Dot_Exactness_Gapped.thy` | Exactness of a gapped context **without** any FIFO hypothesis, and its join |

| TLA+ module | Question |
| --- | --- |
| `AaeCausalClosure.tla` | Does anti-entropy deliver a per-origin prefix-closed set? |
| `CellContextReap.tla` | Does reaping a dead origin's tier_2 cell context change what replicas compute? |
| `OriginReaping.tla` | May a replica drop a dead origin's applied-frontier entry without agreement? |
| `OriginWatermarkReap.tla` | Can the meet be recorded as a scalar watermark, with origins born over time? |
| `OriginRetirementSet.tla` | Does a replicated grow-only retirement set license the reap across rejoins? |

## Scope

Modelled: events `(origin, seq, hlc, cell, ctx)`, per-replica delivered
sets, the containment frontier, the observed-remove primitives, and
state reductions.

Not modelled: the Merkle search tree itself (it enters only through the
containment predicate it decides), WAL durability, the projection/overlay,
network failure, and datatype convergence. (Compaction *is* modelled in the
TLA+ layer, as truncation of a per-origin prefix.)

Why this and not a Zeller-style per-datatype proof (*Formal Specification and
Verification of CRDTs*, FORTE 2014): that framework verifies convergence and
spec-conformance of state-based datatypes and explicitly excludes timestamps.
bondy_db's datatypes are op-based, HLC-ordered, and already covered by PropEr
suites with a realistic causal-delivery simulator. The novel and
safety-critical claim here is the *stability oracle* — nobody has mechanized
"anti-entropy containment implies causal stability", and it is the input to
every irreversible act (`discard`, `stabilize_fold`, page GC).

## Hypotheses, and where the code establishes them

| Model | Code |
| --- | --- |
| `origin_unique` (H1) | Operator obligation; `bondy_oplog_crdt_aw_map.erl` precondition 1 |
| `causal_delivery` (H2) | **Per-origin** half enforced by `bondy_oplog_cell_apply:partition_contiguous/3`; **cross-origin** half NOT supplied by anything — see [Open obligations](#open-obligations) |
| `hlc_respects_hb` (H3) | **Proved** in `Hlc.thy` from `bondy_oplog_hlc:update/2` |
| `prepare_after_deliver` (I1) | `bondy_oplog_applier:ensure_remote_caught_up/1` |
| `certified_frontier` (I2) | `bondy_oplog_instance:compute_frontier_for/2` + `bondy_oplog_sync_session:pull_if_compatible/7` |

I2 is established by two containment directions that meet in the middle:

- `compute_frontier_for/2` — the frontier is the largest local key `K` such
  that every local key `=< K` is present in *every* peer's confirmed root.
  Everything I hold below the frontier, my peers hold.
- `pull_if_compatible/7` — a peer root is checkpointed only when the round
  completed against it (*held-in-full*); a benign-incomplete round "must
  checkpoint nothing". Everything a confirmed peer holds, I hold.

`held_in_full_certifies` proves the second direction alone suffices for the
model.

## Results — Isabelle

**`stability_without_causal_broadcast`** (`Oplog_Model.thy`) — the mechanized
form of the applier's proof sketch. Given I1 and I2, an event prepared at a
confirmed replica *after* certification carries a context dominating every dot
on its cell at or below the frontier.

Notable: the proof uses only I1 and I2. H1, H2 and H3 are modelled but not
load-bearing for stability — they become load-bearing at the datatype layer,
which this development does not reach. In particular **the stability theorem
does not depend on causal delivery**.

**`hlc_governed_reduction_sound`** (`Stabilization.thy`) — a reduction that
preserves the above-frontier observation is sound for any HLC-governed
interpretation. The frontier enters only through `governed_above`, which is
exactly why a *scalar* frontier suffices for this class.

**`aw_fold_not_sound_above` / `aw_not_governed_above`**
(`Aw_Counterexample.thy`) — a proved negative result. Witness: origin 1's
stable run at one key (HLCs 10, 20; frontier 30), folded into one synthetic op
at the run's max dot. The fold *is* value-preserving when applied, satisfying
the `{keep, State'}` contract in `bondy_oplog_crdt.erl`. A remove prepared
before certification, carrying HLC 40 (above the frontier) but a context
observing only `{(1,1)}`, then yields 2 against the folded store and 1 against
the unfolded one.

This confirms the reasoning already written in
`bondy_oplog_crdt_nested_core.erl`; it does not report a defect. The code
already declines to fold collection types. The value is that the boundary is
now mechanically pinned, so enabling the fold for `aw_map`/`aw_set` would be
refuted rather than merely discouraged by a comment.

**`struct_fold_sound`** — the positive half, same representation and same
value function: any value-preserving reduction of an append-only (struct
field) interpretation is sound above *any* frontier.

**`local_next_gt`, `peer_next_gt_old`, `peer_next_gt_peer`, `run_dominates_received`**
(`Hlc.thy`) — a faithful model of `bondy_oplog_hlc.erl` (48-bit physical /
16-bit logical packing, the overflow clamp, the three-way peer merge). Both
steps are proved strictly monotone, and `run_dominates_received` proves that
once a replica has absorbed a peer HLC its clock exceeds that value for the
rest of the run. That is hypothesis H3, discharged rather than assumed: every
event a replica mints sorts strictly after every event it has received.

The logical field's 16-bit bound is modelled, because the clamp
(`bump_logical(Phys, _) -> encode(Phys + 1, 0)`) is what the monotonicity
argument turns on. Physical is unbounded `nat` where the encoding gives it
48 bits — the model therefore permits the clamp to walk physical past a
millisecond boundary, which is exactly what the Erlang does.

**`compact_test_exact` / `dot_observed_exact`** (`Dot_Exactness.thy`) — the
"harmless" argument in `bondy_oplog_crdt_aw_map.erl:222-232`, made a theorem.
Because `Seq` is a per-origin *global* sequence, an origin's dots on any one
cell are sparse, and `Ctx[O] >= S` can be numerically true for a dot that
never touched the cell. Modelled head-on: the set of seqs an origin spent on
a cell is arbitrary, with no contiguity assumed. Under per-origin FIFO —
stated exactly as needed, that an observed seq drags in every earlier seq
*of this cell* — the compact test is exact on dots actually in the store.

Two hypotheses are worth noting because they are obligations on the
substrate, not modelling conveniences:

- seqs are positive. Discharged: `bondy_oplog_instance:build_events_fast/6`
  computes `StartSeq = EndSeq - N + 1` from `atomics:add_get` over a counter
  starting at 0, so the first minted seq is 1. Without it, the encoding of
  "observed nothing" as 0 would collide with a real dot.
- prefix closure *within the cell*. This is the only place per-origin FIFO is
  used. If delivery could skip a seq the origin spent on this cell, the
  right-to-left direction survives but left-to-right fails: the compact test
  would report a skipped dot as observed. `Dot_Exactness_Gapped.thy` below
  removes this obligation by changing the representation.

### `Dot_Exactness_Gapped.thy` — exactness without a delivery discipline

The result that matters most for any future partitioned/scaled deployment,
because it converts a **protocol obligation** into a **representation
choice**. `Dot_Exactness.thy` is exact only under its `prefix` hypothesis;
this theory is exact for an *arbitrary* observed set, holes and all — a hole
cannot be misread as observed, because a hole is representable.

Representation: the standard compact-but-exact causal context, a pair
`(contig, exc)` — a contiguous prefix bound plus the observed seqs above it.

| Result | Statement |
| --- | --- |
| `gapped_test_exact` | `observed_gapped (contig obs) (exc obs) s <-> s : obs`, for an **arbitrary** finite `obs` of positive seqs. **No `prefix` hypothesis.** |
| `gapped_degenerates` | Under downward-closed delivery, `exc = {}` and `contig = ctx_of` (the max) — the pair collapses to the single integer stored today. |
| `denote_repr` / `repr_faithful` | The pair is a faithful encoding: distinct observed sets have distinct representations, so a join defined on pairs cannot lose or invent a seq. |
| `join_denotes_union` | The join on representations denotes exactly the union of the operands' denotations — so join is computable on pairs, not on materialised sets. |
| `join_bound_no_regression` | `max (contig A) (contig B) <= contig (A Un B)`. The merge-safety property `merge_frontier/2` gets today from `max` being monotone; it survives the change of representation. |
| `join_commutative` / `join_associative` / `join_idempotent` | The semilattice laws, inherited from union through the faithful encoding — the obligation on any CRDT-merged value. |
| `join_degenerates_to_max` | **The compatibility theorem.** When both operands were delivered prefix-closed, `exc (A Un B) = {}` and `contig (A Un B) = max (contig A) (contig B)` — exactly the per-origin max the wire and registry carry today. A bare integer is the correct encoding precisely when the exception set is empty, which is precisely when an integer-only peer would have been right anyway. **No flag day.** |

The theory states its own consequence: with an exact context,
`drop_observed/2` can no longer remove an add the writer never saw, because a
seq strictly inside a hole tests as NOT observed. *"Prefix closure remains
desirable for the convergence oracle and for compactness, but it stops being
a correctness precondition of the observed-remove primitives."*

`AaeCausalClosure.tla` carries the same idea applied to the **frontier claim**
rather than the cell context, under the constant `ContigClaim` (the spec
comment names it as `contig` from this theory): the claim becomes the
contiguous prefix bound of what the replica *applied*, read from `applied`
and never from `tree`, so compaction cannot lower it and peer-claim adoption
becomes unnecessary. Same wire type — one integer per origin — but sound by
construction.

## Results — TLA+

Verdicts only; `tla/README.md` carries the traces and the reasoning.

### `AaeCausalClosure.tla` — per-origin prefix closure

Flags: `GapCheckEnabled`, `GatedCompaction`, `PrefixHold`, `ContigClaim`.

A budget-capped round cannot deliver a non-closed set: it delivers *nothing*.
`pull_until_complete/6` calls `integrate_peer_root/2` only when `missing_set`
is empty, so an incomplete round is a stutter step. Established by reading,
not by checking; it retires the capped-round obligation.

| Configuration | Result |
| --- | --- |
| baseline (`AaeCausalClosure.cfg`) — hold off, compaction ungated | `NoOverClaim` and `PrefixClosed` **violated in 6 steps** (the regression pin) |
| `_Gated` — compaction gated on every replica having applied the prefix | exhaustive clean: 12,952,590 states, 311,845 distinct |
| `_Hold` — the shipped prefix hold, 2 replicas | exhaustive clean: 30,938 states |
| `_Hold3` — same, 3 replicas | bounded-exhaustive clean to depth 18 (25.2M distinct; the unenforced baseline violates at depth 6), plus 800,000 random traces to depth 40, 321M states, no violation (seed −3719027508674266878) |
| `_Contig`, `_Contig2` — `ContigClaim = TRUE`, hold off, compaction ungated | **result not recorded** — see [Unrecorded](#unrecorded) |

The counterexample the baseline finds: `r2` bootstraps into an empty cluster,
`r1` mints `(r1,1)` and `(r1,2)`, `r1` compacts away `{(r1,1)}`, `r2`
integrates `r1`'s whole truncated tree. `r2` now holds `(r1,2)` without
`(r1,1)` and reports frontier `r1 |-> 2`. `frontier_deficit/2` is strictly
max-based, so it is structurally blind to a hole *below* the maximum.

**Confirmed on real hardware.** A 3-node CT case plus a fold-time contiguity
detector (`bondy_oplog_cell_apply:detect_prefix_holes/2`, telemetry
`[bondy_oplog, applier, prefix_hole]`) reproduced six same-origin holes in one
run, e.g. `main/1 origin <writer> applied_seq 12 gaps [{13,15}]`. This
falsified the unqualified "causal (per-origin FIFO) delivery" precondition in
`bondy_oplog_crdt_aw_map.erl`. Fixed by the hold (increment 2), which is
unconditional and Fly-validated (s24, 5×performance-8x, enforcement on, one
node killed for 2m01s mid-run).

### `CellContextReap.tla` — tier_2 cell-context reaping

3 replicas, one origin each, symmetry reduction, exhaustive. `Compact` is
deliberately weaker than real truncation, so a clean result covers a superset
of reachable states.

| Configuration | `NoResurrection`, `NoPhantomDot`, `ContextCoversDots` | `Convergence` |
| --- | --- | --- |
| reap off, causal delivery | clean, 426,389 distinct | clean |
| reap **on**, causal delivery | clean, 5,046,890 distinct | clean |
| reap off, out-of-order delivery | clean, 751,829 distinct | **violated in 6 steps** |
| reap **on**, out-of-order delivery | clean, 10,570,826 distinct | **violated in 6 steps** |

Two replicas at `MaxSeq = 2` are exhaustively clean on every invariant in all
four configurations (724k / 526k / 1.86M / 1.35M distinct) — the inversion
needs three parties.

**Verdict on the reap: safe.** It does not resurrect and does not break
convergence. It moves the stamped context down, so a later remove drops fewer
dots — an error toward FALSE concurrency (extra siblings the CRDT resolves),
never toward lost causality. The cell context is *not* what makes re-delivery
idempotent: every `drop_observed/2` call site is handed the **operation's**
stamped context, and re-delivery is filtered upstream by the applied-frontier
VV, which the reaper does not touch.

**The finding that is orthogonal to reaping, and is the important one.**
`Convergence` fails whenever delivery is not causal, reap on or off, with
`ReapCell` never firing in either counterexample. The shape is a three-party
inversion: `r2` folds `r1`'s put and mints a put observing it; `r3` folds
`r2`'s op first (dropping nothing, since it has not seen `r1`'s dot) and
`r1`'s afterwards, whose `put/5` adds the dot back. Both dots survive at `r3`,
one at `r2`, permanently. **The requirement is cross-origin causal delivery,
and no per-origin mechanism supplies it** — `partition_contiguous/3` holds per
origin, and in this trace each origin delivers exactly one event with no
per-origin gap, so nothing is held.

### `OriginReaping.tla` — reaping the applied-frontier entry

| Configuration | Result |
| --- | --- |
| `_Off` — never reap (control) | clean |
| `_Unilateral` — node-local unconditional reap | unsafe |
| `_Solo` / `_SoloJoin` — solo carve-out | `SpuriousGap` **violated in 7 steps** once `Join` exists |
| `_Meet` — reap when every member is level, deficit skips reaped origins | `ReapedMeansLevel` **violated in 4 steps** |

The meet is sound; *recomputing* it from an absent entry is not. The predicate
`Dead(o) /\ claim[r][o] = 0` cannot distinguish "I reaped after verifying I
was level" from "I never saw it". Removal from a join-semilattice is
non-monotonic, so it is safe only when coordinated or accompanied by a record
of what was removed.

### `OriginWatermarkReap.tla` — the meet recorded as a scalar

3 replicas, 4 ranks, `MaxSeq = 1`, origins born over time.

| Configuration | Result |
| --- | --- |
| `_Off` — never reap (control) | exhaustive clean: 105,483 distinct |
| `_Hlc` — HLC-derived ids, fresh strict meet | exhaustive clean: 3,038,590 distinct |
| `_Wallclock` — wall-clock ids | `NoLiveOriginBelowWatermark` **violated in 6 steps** |
| `_Stale` — meet read from `peer_state.frontier` snapshot | `ReapedMeansLevel` **violated in 8 steps** |
| `_Recency` — recency-filtered members | `ReapedMeansLevel` **violated in 8 steps** |
| `_StaleRecency` — both | `ReapedMeansLevel` **violated in 7 steps** |
| `_HlcJoin` — HLC watermark, with `Join` | `NoLiveOriginBelowWatermark` **violated**, 1,894 distinct |

`NeverReaps` is a reachability probe, violated under `_Hlc` in 5 steps, so the
rule is not vacuous. Three requirements, all load-bearing:

1. **The id scheme matters, for domination not gap-freedom.** An HLC-derived
   id strictly exceeds its minter's clock and every clock absorbs every clock
   it syncs with, so a member at or above `k` cannot mint below it. A wall
   clock offers no such guarantee — counterexample: replicas hold ranks 4, 2,
   3; every clock is at or above 2; `r1` advances its watermark to 2 and then
   mints origin **1**, live, beneath its own watermark.
2. **The meet must be read fresh.** `bondy_oplog_peer_state`'s `frontier`
   column is the peer's vector *as observed at the start of the last completed
   round* — a snapshot. The fix is the round trip `origin_retirement` already
   does for `get_origins`: ask every member at reap time via `get_frontier`,
   and fail closed if any cannot answer.
3. **The read must be strict, not recency-filtered.** `bondy_oplog_peer_state`
   already asserts this in prose; the `_Recency` row is that assertion failing
   under a checker.

### `OriginRetirementSet.tla` — the shipped design

Membership-derived reaping fails on one action: `bondy_oplog_origin:load_or_create/1`
reuses the persisted id, so a departed node resumes minting under the very
origin the survivors reaped. Membership-derived "dead" is not dead; it is
"away". The replacement is a **replicated grow-only retirement set**, operator-
driven. 3 replicas, `Join` enabled.

| Configuration | Result |
| --- | --- |
| `_OffS1` — never reap (control) | exhaustive clean: 861 distinct |
| `_BannedS1` — retire + ban + reap | exhaustive clean: 16,529,485 states, 2,538,102 distinct |
| `_UniversalS1` — the shipped guard | exhaustive clean: 17,013,691 states, 2,538,102 distinct |
| `_UnbannedS1` — ban NOT enforced | `RetiredSkipIsSafe` **violated in 5 steps** |
| `_ForgetfulS1` — enforce first, persist may fail | `SpuriousGap` **violated in 9 steps** |
| `_Universal` — shipped guard, `MaxSeq = 2` | exhaustive clean: 685,709,113 states, 95,684,190 distinct |
| `_Banned` — `MaxSeq = 2` | exhaustive clean: 649,547,353 states, 95,684,190 distinct |

Which precondition licenses the drop, judged with survivors stable, where
`CompactionModelled` makes the three guards distinguishable:

| Guard | `NoStuckEvent` | Can every member clear the entry? |
| --- | --- | --- |
| never reap (`_OffCompactS1`) | clean: 124,558 distinct | n/a |
| `"none"` — retirement alone | **violated in 7 steps** | — |
| `"meet"` — every member level on it | clean: 654,082 distinct | **no** — exhaustive, 4,035 distinct |
| `"universal"` — every member has retired it | clean: 662,464 distinct | **yes**, in 10 steps |

The right-hand column is `NotAllMembersReaped`, an inverted invariant: a
*violation* is the desired outcome. **The meet rule is safe and never
finishes** — only a reap lowers a claim and a retired origin's claim never
rises, so the first replica to reap leaves every other replica permanently
unequal to it, and the entry survives on every replica but one. That is the
leak the reap was written to remove. Hence **universal retirement, not a level
meet**.

Six requirements, three of which an implementation would get wrong by default:

1. The retirement set is replicated and grow-only (converges by union, no
   ordering requirement), so every replica skips the same origins.
2. **It must be persisted, and persisted BEFORE it is enforced.** A durable
   retirement not yet enforced is harmless and self-corrects; an enforced
   retirement that is not durable is the `_ForgetfulS1` counterexample — the
   restart forgets the retirement while the reap it licensed already removed
   the frontier entry, leaving a permanent unfillable deficit. This reverses
   the ordering the code originally argued for.
3. Retirement is operator-driven, never derived from membership.
4. **The ban is load-bearing** — skipping a retired origin's deficit is safe
   only because no replica will ever accept another event from it.
5. **Ban the claim, not just the events.** Filtering incoming events while
   still max-merging the peer's vector leaves the frontier asserting events
   the replica refused (`NoOverClaim` violated in 8 steps before this fix).
6. **The claim rises from the events actually folded**, not only from the
   peer's advertised vector (`SpuriousGap` violated in 10 steps before this
   fix). The real code already had this shape (`batch_frontier/1` ->
   `merge_frontier/2`); the model did not, which is what surfaced it.

**What the universal guard does not cover.** `_UniversalChurnS1` (membership
churn allowed): `NoStuckEvent` **violated in 9 steps** — the trace shrinks the
cluster to one member, reaps there, then rejoins a replica holding neither the
retirement nor the reclaimed event. The window closes as soon as the returning
node pulls the retirement set. Operator contract: **retire an origin only once
the cluster has converged on its events.** The implementation reports rather
than prevents, on `[bondy_oplog, retirement, reaped_unconverged]`, because
refusing to reap over unequal claims is the meet rule and inherits its
deadlock.

## Implementation status: proved vs built

Verified by reading `apps/bondy_oplog/src` at the time of writing.

| Mechanism | Formal status | Code status |
| --- | --- | --- |
| Per-origin prefix hold | `_Hold` / `_Hold3` clean | **BUILT**, unconditional — `bondy_oplog_cell_apply:partition_contiguous/3`, `contiguous_run/2`; telemetry `[bondy_oplog, applier, events_held]` |
| Contiguity detector | — | **BUILT** — `detect_prefix_holes/2`, `[bondy_oplog, applier, prefix_hole]` |
| Universal-retirement reap guard | `_UniversalS1` / `_Universal` clean | **BUILT** — `bondy_oplog_origin_retirement:universal/1`, `reaped_unconverged` telemetry |
| Persist-before-enforce for bans | `_ForgetfulS1` refutes the alternative | **BUILT** — `bondy_oplog_origin_bans`, `{error, not_persistent}` |
| **Gapped causal context `(contig, exc)`** | **PROVED** (`Dot_Exactness_Gapped.thy`), wire-compatible by `join_degenerates_to_max` | **NOT BUILT** — no `first_gap` / `contig` / `exc` anywhere in `apps/*/src`; `bondy_oplog_crdt_aw_core:vv_merge/2` is still pointwise integer max and `dot_observed/2` is still `N >= S` |
| `ContigClaim` frontier bound | modelled; **result unrecorded** | **NOT BUILT** |
| Vector stability | `vector_stable` defined; **not certified by the substrate** | **NOT BUILT** |
| Cross-origin causal delivery | absence **refutes `Convergence`** (`CellContextReap`) | **NOT BUILT** — no mechanism exists |

## The precise grade of the frontier

The headline finding, and why the qualifier "TCSB-grade" is needed:

> A containment frontier bounds the **HLCs** of events that can still arrive.
> It does **not** bound their **contexts**, because a context is fixed at
> prepare time and prepare time is not ordered by certification.

Hence a reduction may depend on the former and not on the latter. This is why
`stability_without_causal_broadcast` and `aw_not_governed_above` coexist
without contradiction: the theorem is conditioned on `prepare_after_deliver`
against the delivered map *at prepare time*, and the counterexample's remove
is above the frontier yet simply not covered by it.

A context-governed reduction needs **vector stability** — a certified lower
bound that every context still to arrive already observes (`vector_stable`,
with `vector_stable_dots_observed` discharging the obligation directly). The
substrate does not certify this today.

## Open obligations

1. **Cross-origin causal delivery is not supplied by anything, and its absence
   is a proved convergence violation.** `CellContextReap` shows `Convergence`
   failing in 6 steps under out-of-order delivery, reap on or off, via a
   three-party inversion in which no origin has a per-origin gap. The shipped
   `partition_contiguous/3` hold is per-origin and cannot see it. This is the
   same distinction as the vector-vs-HLC stability gap recorded in
   `bondy_oplog_crdt_nested_core`'s moduledoc, and it is the sharpest open
   safety question in the development. Note the scope: origins and seqs are
   **per instance**, so nothing here reasons across instances either — a
   cluster-wide causal guarantee is a strictly larger problem than the one
   modelled.
2. ~~**Per-origin prefix closure.**~~ **Closed.** Reproduced on a 3-node
   cluster by the fold-time detector, fixed unconditionally by the hold,
   model-verified (`_Hold`, `_Hold3`) and Fly-validated. Independently, and
   still available, `Dot_Exactness_Gapped.thy` discharges the *exactness*
   obligation by representation rather than by protocol — which is what a
   deployment that cannot preserve prefix closure would need.
3. **Vector stability.** Not certified. Blocks context-governed reduction;
   keeps `stabilize_fold` refused for the add-wins family.
4. **Membership completeness.** I2 quantifies over the confirmed set. A
   replica outside it that can still mint below the frontier breaks the
   argument. `reclamation_members/0` and the stale-peer rejoin work bear on
   this; neither is modelled.
5. **Datatype convergence.** Not attempted. The natural next step is
   instantiating the Gomes/Kleppmann/Mulligan/Beresford locale (AFP entry
   `CRDT`) for `aw_core`/`nested_core`, which assumes causal delivery as a
   hypothesis — i.e. it consumes obligation 1.

### Unrecorded

`AaeCausalClosure_Contig.cfg` (3 replicas) and `_Contig2.cfg` (2 replicas)
check `TypeOK` + `NoOverClaim` with `ContigClaim = TRUE`, `PrefixHold = FALSE`
and `GatedCompaction = FALSE` — i.e. whether the contiguous-prefix claim alone
makes the oracle sound with no hold and ungated compaction. The configs exist;
no result is recorded in either README. Re-run them before relying on the
answer.

**These two configs are on the critical path for the `bondy_ddb` delivery
design** (`_design/ddb/`, section 3): that design retires the per-origin hold
and replaces the max-based claim with the contiguous prefix bound, which is
exactly `ContigClaim = TRUE, PrefixHold = FALSE, GatedCompaction = FALSE`. If
`NoOverClaim` holds there, the design's central safety claim is model-checked
before implementation; if not, the design changes. Fetch `tla2tools.jar` and run
them before the spec is written.

## Maintenance

Isabelle extracts to SML/OCaml/Haskell/Scala, not Erlang, so this proves
properties of a hand-translated model, not of the beam files. The model will
drift the moment `drop_observed/2` or `stabilize_fold/2` changes. The
mitigation that would make it durable rather than decorative: extract the
model to Haskell or OCaml and run it as the oracle in the existing PropEr
suites, so the model-to-code gap is continuously tested even though it is
never proven.

Note for editors: this Isabelle installation rejects literal Unicode in theory
files — use ASCII symbol notation (`\<open>`, `\<forall>`, `\<Longrightarrow>`).
