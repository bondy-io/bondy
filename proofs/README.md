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
`axiomatization`. Scope is the stabilization argument and the
observed-remove kernel step; datatype convergence is covered only at the step
level (see [Scope](#scope)). The session builds on the vendored AFP `CRDT`
entry, which `isabelle/ROOTS` registers.

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
| `Seq_Seed.thy` | Discharges the per-origin half of H1 across restarts: the counter seed `max(checkpoint, tree, WAL)` under watermark-keyed WAL retention keeps dots unique and gap-free |
| `Bucket_Skip_Soundness.thy` | The applied frontier when a bucket has no cell-apply context: the shipped per-origin `max` over the folded pairs is UNSOUND under a bucket skip; the contiguous prefix bound is sound for an arbitrary applied set, is the largest sound claim, never regresses as holes fill, and is stopped by an unroutable bucket and by nothing else |
| `Frontier_Writers.thy` | Why the applied frontier needs ONE writer, not four: in a max-merge, unsoundness is upward-closed, so one over-claiming writer defeats every conservative one and a cap at another call site is void (`join_absorbs_unsound`, `cap_cannot_repair`); the sparse `#{Origin => Seq}` max is sound **iff** the underlying set is prefix-closed (`max_sound_iff_prefix`); folding behind a contiguity admission test evaluated AFTER bucket resolution preserves prefix-closure of the FOLDED set (the oplog keeps recording receipt) (`fold_preserves_prefix_closed`); and boot reconstruction equals the incremental value when boot RE-FOLDS rather than declares (`reconstruction_agrees`); a claim derived from the oplog is unsound w.r.t. the projection (`receipt_log_overclaims`). It also models the RESTART, which is where the defect lives: a four-set state (checkpoint, claimed, folded, received) with the invariant `claimed subset-of folded`. Declaring the oplog folded at restart breaks it (`shipped_restart_breaks_soundness`, `shipped_restart_overclaims`); re-folding from the checkpoint preserves it (`refold_restart_preserves_soundness`) and never regresses below the checkpoint (`refold_no_regression`). The same oplog-derived claim is SOUND for the replica's own origin (`own_origin_oplog_claim_is_sound`), which is why the writer must be split rather than removed. Design: `_design/applied_frontier.md` |
| `Frontier_Pending.thy` | The applied frontier ACROSS A SCHEDULE, which the two theories above cannot express. The shipped `claim/2` is sound exactly under batch visibility (`shipped_sound_when_visible`) and unsound the moment a batch boundary falls between the hole and the claim (`shipped_split_batch_overclaims`). The sharpening: **no writer whose state is one integer per origin is both sound and eventually complete** (`no_scalar_writer_sound_and_complete`) — a diagonal over two schedules that carry NO failures, so better failure reporting cannot close it. The prefix-plus-pending pair, carried across a schedule, denotes the folded set exactly (`pending_exact`), reports the largest sound claim (`pending_sound`, `pending_maximal`), never regresses (`pending_no_regression`), is complete once delivery ends prefix-closed (`pending_complete`), costs nothing when it is (`pending_zero_cost_when_healthy`) and one interval per hole when it is not (`pending_intervals_bounded_by_holes`). Also: one writer is still required (`union_absorbs_unsound`), the two columns need no atomic write (`torn_read_is_sound`), and the pending half may be volatile (`dropping_pending_is_sound`, `refold_restores_exactness`). Design: `_design/applied_frontier_pending.md` |
| `Confirmed_Compaction.thy` | Compaction by peer confirmation: certifying a peer by the frontier it last reported, with truncation limited to applied events, never makes an un-applied event unshippable (`no_loss`) and never drops one (`no_drop`) |
| `Aw_Kernel.thy` | Re-delivery to a dotted cell kernel, one whose causal context grows by exactly each applied operation's context and dot (the kernels built on `aw_core:cc_absorb/3`). The guard of `cell_kernel:apply/6`, skipping an operation whose dot the context covers, makes re-delivery a no-op under any delivery (`dotted_kernel.guarded_redelivery_noop`) and never fires on causal, at-most-once, per-origin-FIFO delivery (`dotted_kernel.guarded_eq_step`). It needs causal delivery (`guard_needs_causal_delivery`), which a hold gives when each batch folds in key order and only events whose context stays within per-origin tops that every later-folded event exceeds (`causal_hold_delivers_causally`, under H3 and distinct dots). The `aw_set`/`aw_map` cell (`nested_core:put/5`, `put_nested/7`, `rmv/3`) is an instance; without the guard a re-delivered add restores a removed key (`shipped_redelivery_resurrects`); per key each step is the AFP `ORSet` interpretation (`put_is_orset`, `putn_is_orset`, `rmv_is_orset`) |

| TLA+ module | Question |
| --- | --- |
| `AaeCausalClosure.tla` | Does anti-entropy deliver a per-origin prefix-closed set? |
| `CellContextReap.tla` | Does reaping a dead origin's tier_2 cell context change what replicas compute? Can the reap still find the cell once compaction has truncated the MST it enumerates cells from? |
| `OriginRetirementSet.tla` | Does a replicated grow-only retirement set license the reap across rejoins? |
| `SeqSeed.tla` | Does the per-origin sequence counter survive a restart? Which durable sources must seed it, in what compaction order? |
| `MuxBucketSkip.tla` | Can the applied-frontier VV claim an event whose cell was never installed because its BUCKET had no context? Two independent channels — the fold and the bootstrap adoption — and which mechanisms are load-bearing for each. |
| `FrontierPending.tla` | Can the applied frontier be maintained by ONE INTEGER per origin, given that batch boundaries are set by drain timing? Which of the three claim rules survives restarts, the compaction door and every interleaving? |
| `ConfirmedCompaction.tla` | Does compaction confirmed by every member's durable frontier, the replica's own included, lose or strand an event, and does it converge? |
| `LiveRebootstrapRefold.tla` | Does a live catalogue re-bootstrap lose a local event, or leave a frontier claiming an event no cell reflects, under trailing-round failures, crashes and replicas re-bootstrapping from each other? |
| `JoinInstall.tla` | Can the catalogue install, a session that stages the source's cells and swaps them in at its re-fold, leave a cell that differs from the fold of every event, once cells are deleted by the sweep, truncated by compaction or reaped of a retired origin? Can a truncation record strand a member across clustering turned off and on, or a leave and return? |
| `ReplayReanchor.tla` | Can a compaction move the applier's replay cursor past an event the applier has not folded, so that no later replay presents it? |

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
| `origin_unique` (H1) | Two halves. Distinct origin ids: operator obligation, `bondy_oplog_crdt_aw_map.erl` precondition 1. Distinct seqs under one origin across the minter's restarts: **NOT supplied by the shipped code** — `bondy_oplog_instance:init/1` seeds the counter from the live tree only, which is empty once compaction has run (Jepsen, 2026-09-03). `Seq_Seed.thy` **proves** the seed rule `max(checkpoint frontier, tree, retained WAL)` under watermark-keyed WAL retention discharges it; `SeqSeed.tla` refutes the shipped rule and the checkpoint-only fix — see [Results — TLA+](#seqseedtla--the-sequence-counter-across-restarts). **BUILT** 2026-09-03: `init/1` seeds from the restored frontier; the WAL writer records `max_seq` in its manifest, recovers it on open and seeds the instance before publishing its pid; the fast paths resolve the WAL before reserving. Pinned by `bondy_oplog_seq_seed_restart_test` (both cases red against the shipped code) |
| `causal_delivery` (H2) | **Per-origin** half enforced by `bondy_oplog_cell_apply:partition_contiguous/4`; **cross-origin** half NOT supplied by anything — see [Open obligations](#open-obligations) |
| `hlc_respects_hb` (H3) | **Proved** in `Hlc.thy` from `bondy_connect_hlc:update/2` |
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
(`Hlc.thy`) — a faithful model of `bondy_connect_hlc.erl` (48-bit physical /
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

**`seed_exact` / `dot_unique` / `log_distinct` / `h1_for_origin`**
(`Seq_Seed.thy`) — the minter's persistence protocol as an unbounded state
machine (one replica, one origin; reserve, WAL append + ack, apply + install,
root flush, watermark-keyed WAL retention, frontier persist, two-step
compaction in the shipped order, stop, crash, restart), over-approximating
`SeqSeed.tla` (no read cursor, any interleaving, every crash point). Under
the seed rule `max(checkpoint frontier, durable tree, retained WAL)` *read at
init*, the inductive invariant gives: whenever the instance is up, `acked ∪ inflight = 1..seqRef` — the
counter is the acknowledged maximum plus its live reservations, gap-free and
never behind, including in the first state after a restart before any WAL
replay. `log_distinct` is the history form: the sequence of acknowledged
writes never repeats a seq, across any number of stops, crashes and
restarts; `h1_for_origin` restates it as `origin_unique` over the events
those writes produced, for arbitrary payloads. The load-bearing conjuncts are
COVER — the acknowledged maximum is in the checkpoint, the tree or the WAL at
all times — and RETAINED — everything installed is still in the WAL or at or
below the durable watermark, which is what watermark-keyed retention buys and
what commit-keyed retention breaks.

What it does not establish: that `init/1` implements the rule. That is the
falsifier's job.

**`no_loss` / `no_drop`** (`Confirmed_Compaction.thy`) — compaction by
peer confirmation for any number of members and events. The state machine
over-approximates `ConfirmedCompaction.tla`: no key order (a truncation
removes ANY subset of the tree that is applied locally and confirmed by every
other member; the door drops ANY applied subset, own events only if truncated
before), any prefix-closed fold, and a `report` step, independent of any
merge, that records for a peer the frontier of ANY prefix-closed subset of
what the peer has applied. A reported durable frontier is one, and since the
applied set only grows, so is one recorded late, out of order, or kept
because the new report was empty (`record_sync_complete` is a cast, and the
initiator reads its own frontier after the round). The rule: `confirmed r p e` iff `e`'s seq is at or
below the frontier recorded for `p` at `e`'s origin. The inductive
invariant's main conjuncts: VV (a recorded entry bounds a prefix the peer
applied — `vv_of_witness`: the per-origin maximum of a finite prefix-closed
set is a contiguous bound, which is where the prefix hold becomes a
precondition), TRUNC (what a replica truncated every other member holds) and
SHIP (a minted event is in its minter's tree, was truncated by its minter, or
is held by the member in question). `no_loss`: an event a member has not
applied is in some member's tree. `no_drop`: no step removes an event from a
tree without it being applied there. With `confirmed` replaced by `True` the
proof fails (`confirmed_holds`).

What it does not establish: liveness (`ConfirmedCompaction_*_Live.cfg`),
anything under `mst_retention`, a retired origin's keys (every witness
counts them as confirmed), membership change (the member set is fixed), the
unservable-root rebuild (`rebuild_frontier/2` truncates the whole tree on a
cover check; `ConfirmedCompaction_*_Lost*.cfg` model it), crashes (a member that restarts with less applied
than it reported keeps its old row until it reports a non-empty frontier),
and that the code implements the rule.

**`no_scalar_writer_sound_and_complete`** (`Frontier_Pending.thy`) — the
impossibility that motivates the pending set. For ANY writer `w` with one
integer of state, if `w` is sound on every schedule then on
`[({2}, {}), ({1}, {})]` it ends at 1 while the projection holds `{1, 2}`. The
proof is a diagonal: soundness on the one-batch schedule `[({2}, {})]` forces
the state to 0, and the second batch is then handed exactly the state that
`[({1}, {})]` hands it, where soundness caps the answer at 1. Neither schedule
contains a failure, so the `Failed` reporting built in
`_design/applied_frontier.md` increment 3 cannot help. Determinism of the writer
is the only hypothesis.

**`pending_exact`** (same theory) — the prefix-plus-pending state denotes the
folded set exactly, at every point of every schedule, with no hypothesis on
batch boundaries, delivery order or failure visibility. Every other positive
result about the representation is a corollary of this plus the arithmetic
already proved in `Bucket_Skip_Soundness.thy`.

The counterexample was mutation-checked: with the second batch's failure made
visible (`[({}, {1}), ({2}, {1})]`) the session fails to build, so
`shipped_split_batch_overclaims` is about the batch boundary and not an
artefact of the encoding.

## Results — TLA+

Verdicts only; `tla/README.md` carries the traces and the reasoning.

### `FrontierPending.tla` — one integer, or a prefix and a pending set

One replica, `Origins = {o1}`, `MaxSeq = 3`, two buckets, the compaction door
prefix-capped as the code caps it, unless noted. `NoOverClaim` is the oracle
contract; `NoLoss` says nothing un-folded was truncated; `Complete` says the
entry is right the moment the projection is; `EventuallyComplete` allows a
repair step.

| Config | Rule | Result |
| --- | --- | --- |
| `_MaxCap` | shipped `claim/2` | **`NoOverClaim` violated** |
| `_Contig_Dead` | prefix bound alone | **`Complete` violated** — sound, not complete on the spot |
| `_Pending` | prefix + pending | clean — `NoOverClaim`, `PendingSound`, `NoLoss`, `Exact`, `Complete` |
| `_Pending_TwoOrigins` | prefix + pending, 2 origins, `MaxSeq = 2` | clean — the pointwise reduction the theory assumes |
| `_Pending_Restart` | prefix + pending, restarts, replay | clean — arbitrarily many restarts |
| `_Pending_Restart_NoRefold` | restarts, no replay | **`EventuallyComplete` violated** — the boot re-fold is still required |

What it does not establish: more than one replica, the MST, HLCs, re-delivery of
a truncated event (forbidden here, the worst case), and that the code implements
any of it — nothing of this is built.

### `SeqSeed.tla` — the sequence counter across restarts

One replica, one origin, `MaxSeq = 3`; invariants `SeedExact` (counter =
acknowledged max + reservations, evaluated wherever a mint is possible),
`DotUnique`, `DurableSound`, `TypeOK`.

| Config | Seed rule | WAL retention keyed on | Mint may precede replay | Result |
| --- | --- | --- | --- | --- |
| `_Shipped` | live tree (+ WAL replay top-up) | durable checkpoint watermark (as shipped) | no (granted) | **`SeedExact` violated in 7 steps** — mint, ack, apply, compact, clean stop, restart: tree empty, checkpoint carries the seq, counter 0. The Jepsen finding. |
| `_CkptCommitKeyedRetention` | + checkpoint frontier | committed offset only (differential) | no (granted) | **violated in 8 steps** — crash between the durable truncated root and the checkpoint write, after the WAL dropped the segment. The obligation retention must keep. |
| `_CkptEarlyMint` | + checkpoint frontier | durable checkpoint watermark | **yes (what ships)** | **violated in 4 steps** — the WAL tail is durable but unreplayed when the fast path mints; nothing gates minting on the boot drain. |
| `_CkptWal` | + checkpoint + **retained WAL, read at open** | durable checkpoint watermark | yes | clean (548 distinct states; 5,304 at `MaxSeq = 5`) — **the fix** |

Two things the model taught before any Erlang changed:

- The one-line fix ("seed from the restored frontier") is sound **only
  because** WAL retention is keyed on the durable checkpoint watermark
  (`bondy_oplog_wal:compute_deletable/1`: a segment goes only below the
  committed offset AND below the snapshot watermark). Everything above the
  last durable checkpoint is still in the WAL and replays after a restart,
  which is what closes the crash window between a truncated root's flush and
  its checkpoint write. A first version of this model dropped WAL segments on
  commit alone and reported that window as reachable; the differential config
  keeps that result as the statement of the obligation. (Found on the way:
  nothing in production called `advance_snapshot_watermark/2`, so the sweep
  never dropped a segment and the WAL grew to `max_total_wal_size`, after
  which appends failed with `wal_full`. **FIXED 2026-09-03**: compaction now
  advances the watermark *after* its checkpoint is durable
  (`bondy_oplog_instance:advance_wal_snapshot_watermark/2`); the sweep is
  pinned by `bondy_oplog_compaction_durable_test:compaction_advances_wal_watermark_and_sweeps`
  and the order by `…:wal_watermark_advances_only_after_the_checkpoint`,
  which observes the WAL's watermark at every checkpoint write — the order
  has no black-box consequence, since the WAL head always retains the latest
  own append.)
- The seed must also read the retained WAL's maximum at open, not wait for
  the applier's replay to bump it: the fast path is published in `init/1`
  and nothing awaits the boot drain.

`Seq_Seed.thy` proves the `_CkptWal` rule for unbounded runs.

### `AaeCausalClosure.tla` — per-origin prefix closure

Flags: `GapCheckEnabled`, `GatedCompaction`, `PrefixHold`, `ContigClaim`.

A budget-capped round cannot deliver a non-closed set: it delivers *nothing*.
`pull_until_complete/6` calls `integrate_peer_root/2` only when `missing_set`
is empty, so an incomplete round is a stutter step. Established by reading,
not by checking; it retires the capped-round obligation.

| Configuration | Result |
| --- | --- |
| `AaeCausalClosure_Shipped.cfg` — the shipped combination: prefix hold, contiguous claim, gap check, compaction ungated; 2 replicas, `MaxSeq = 2` | `TypeOK`, `NoOverClaim`, `PrefixClosed` exhaustive clean: 1,523 distinct states, depth 15 |
| `AaeCausalClosure_Shipped_3R.cfg` — the same, 3 replicas | no violation in 18,922,940 distinct states before the time guard; not exhaustive |
| `AaeCausalClosure.cfg` — ablation: hold and contiguous claim off, compaction ungated; 3 replicas | `NoOverClaim` and `PrefixClosed` **violated in 6 steps** (the regression pin) |

The exhaustive result covers two replicas, the scope its config header argues
for (sync, hold and frontier logic are pairwise); the three-replica run is
bounded by the time guard.

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
`bondy_oplog_crdt_aw_map.erl`. Fixed by the hold, which is
unconditional and Fly-validated (s24, 5×performance-8x, enforcement on, one
node killed for 2m01s mid-run).

### `CellContextReap.tla` — tier_2 cell-context reaping

3 replicas, one origin each, symmetry reduction, exhaustive. `Compact` is
deliberately weaker than real truncation, so a clean result covers a superset
of reachable states.

| Configuration | `NoResurrection`, `NoPhantomDot`, `ContextCoversDots` | `Convergence` |
| --- | --- | --- |
| `_R3S1_ReapTRUE_CausalTRUE` — reap on, causal delivery | clean, 5,046,890 distinct | clean |
| `_R3S1_ReapTRUE_CausalFALSE` — reap on, out-of-order delivery | clean, 10,570,826 distinct | **violated in 6 steps** |

Two replicas at `MaxSeq = 2`, reap on, causal delivery
(`_R2_ReapTRUE_CausalTRUE`) are exhaustively clean on every invariant.

**The cell directory.** The reap enumerates cells through
`bondy_oplog_cell_utils:primary_cell_directory/4`: the adapter's `cell_keys/2`
where the adapter exports it, else the `cell_apply` keys the MST still holds.
`bondy_oplog_compaction_cluster_SUITE` locks registry history to drain to
quiescent, so a registry adapter without `cell_keys/2` leaves the reap an
empty directory once compaction has run.
`bondy_rib_reclamation_cluster_SUITE:departed_node_rib_state_is_reclaimed_after_compaction`
pins the consequence: it compacts the survivors explicitly before the
departure and asserts the departed node's registration and subscription
cells and stubs are gone after retirement. Without an ETS `cell_keys/2` it
fails on the registration cell with every registry instance reporting
`cells_scanned => 0`. The `Directory` constant models the source: `"projection"` lists every cell the
projection holds, `"tree"` only a cell the MST still has an event of. Two
invariants: `DirectoryComplete` (every held cell is listed) and
`DeadContextReachable` (a departed origin's unreaped context is in a listed
cell). `_R2_DirTree` **violates `DirectoryComplete` in 3 steps**: two
mints and one compaction, no departure needed (22 states generated, 20
distinct). `_R2_DirTree_Dead`, the same cfg without `DirectoryComplete`,
**violates `DeadContextReachable` in 3 steps**: replica 1 mints, compacts
its own op, and origin 1 departs; its context entry `cc[1][1] = 1` is now
in a cell no directory lists (95 states generated, 75 distinct). Under
`"projection"` the old reap guard is unchanged on every reachable state (a
context entry is nonzero only after a fold, and a fold is what lists the
cell): `_R2_ReapTRUE_CausalTRUE` is exhaustively clean on all seven
invariants, 1,354,631 distinct, and `_R3S1_ReapTRUE_CausalTRUE` clean at
its recorded 5,046,890 distinct, and `_R3S1_ReapTRUE_CausalFALSE` still
stops on `Convergence` at the same depth with both new invariants silent
before it. Under `"projection"` `DirectoryComplete` is a tautology, so
these runs show the directory constant did not disturb the earlier results;
they do not verify the adapter. `bondy_oplog_projection_ets:cell_keys/2`
(an `ets:select` over the bound entity bucket, scope from
`bondy_db_topology_memory:primary_cell_scope/1`) puts the registry under the
`"projection"` directory; the eunit group `cell_keys_test_` in
`bondy_oplog_projection_ets_test` and the CT case above are the evidence.

**Verdict on the reap: safe.** It does not resurrect and does not break
convergence. It moves the stamped context down, so a later remove drops fewer
dots — an error toward FALSE concurrency (extra siblings the CRDT resolves),
never toward lost causality. The cell context is *not* what makes re-delivery
idempotent: every `drop_observed/2` call site is handed the **operation's**
stamped context, and re-delivery is filtered upstream by the applied-frontier
VV, which the reaper does not touch.

**The finding that is orthogonal to reaping, and is the important one.**
`Convergence` fails when delivery is not causal, and `ReapCell` never fires
in the counterexample. The shape is a three-party
inversion: `r2` folds `r1`'s put and mints a put observing it; `r3` folds
`r2`'s op first (dropping nothing, since it has not seen `r1`'s dot) and
`r1`'s afterwards, whose `put/5` adds the dot back. Both dots survive at `r3`,
one at `r2`, permanently. **The requirement is cross-origin causal delivery,
and no per-origin mechanism supplies it** — `partition_contiguous/4` holds per
origin, and in this trace each origin delivers exactly one event with no
per-origin gap, so nothing is held.

### `OriginRetirementSet.tla` — the shipped design

Membership-derived reaping fails on one action: `bondy_oplog_origin:load_or_create/1`
reuses the persisted id, so a departed node resumes minting under the very
origin the survivors reaped. Membership-derived "dead" is not dead; it is
"away". Reaping on a membership-derived meet, whether recomputed from an
absent frontier entry or recorded as a scalar HLC watermark, is rejected and
not implemented. The replacement is a **replicated grow-only retirement set**,
operator-driven. 3 replicas, `Join` enabled.

| Configuration | Result |
| --- | --- |
| `_UniversalS1` — the shipped guard | exhaustive clean: 17,013,691 states, 2,538,102 distinct |
| `_UnbannedS1` — ban NOT enforced | `RetiredSkipIsSafe` **violated in 5 steps** |
| `_ForgetfulS1` — enforce first, persist may fail | `SpuriousGap` **violated in 9 steps** |
| `_Universal` — shipped guard, `MaxSeq = 2` | exhaustive clean: 685,709,113 states, 95,684,190 distinct |

Which precondition licenses the drop, judged with survivors stable, where
`CompactionModelled` makes the three guards distinguishable:

| Guard | `NoStuckEvent` | Can every member clear the entry? |
| --- | --- | --- |
| `"none"` — retirement alone (`_NoneCompactS1`) | **violated in 7 steps** | — |
| `"meet"` — every member level on it (`_MeetProbe`) | not recorded | **no** — exhaustive, 4,035 distinct |
| `"universal"` — every member has retired it (`_UniversalCompactS1`, `_UniversalProbe`) | clean: 662,464 distinct | **yes**, in 10 steps |

The right-hand column is `NotAllMembersReaped`, an inverted invariant: a
*violation* is the desired outcome. **The meet rule never finishes** — only
a reap lowers a claim and a retired origin's claim never rises, so the first replica to reap leaves every other replica permanently
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

### `ConfirmedCompaction.tla` — compaction confirmed by every member

The code's rule — every member's recorded durable frontier and the
replica's own as witnesses, the confirmed watermark door, the cap — holds
`NoLoss`, `NoGap`, `ConfirmedHeld` and `NoDrop` exhaustively at two replicas
applier-backed (`ConfirmedCompaction_2R_Async.cfg`, 948,191 states) and at
three fused (`_3R.cfg`), under two link cuts (`_3R_Partition.cfg`), a member
removed (`_3R_Retire.cfg`) and both (`_2R_Async_Partition_Retire.cfg`), and
converges (`_2R_Async_Live.cfg`). A door that drops unconfirmed events
violates `NoGap` (`_3R_DoorDrop.cfg`), a door that drops nothing violates
`Convergence` (`_2R_Async_DoorKeep_Live.cfg`), and a recency filter on the
witnesses violates `NoLoss` under a partition (`_3R_Fresh_Partition.cfg`).
Without the cap no violation is found (`_2R_Async_NoCap.cfg`): the
replica's own durable frontier covers only what it applied. The cap still
guards the retention frontier, which no witness confirms and the model does
not represent. Results and traces: `tla/README.md`.

### `LiveRebootstrapRefold.tla` — the live catalogue re-bootstrap

A cell is the set of events folded into it, which the guarded fold of
`Aw_Kernel.thy` licenses (`guarded_redelivery_noop`, `putn_is_orset`). The
frontier is durable only in the checkpoint; a crash is either a node crash
(the frontier is the checkpoint's) or a one_for_all subtree restart (the
registry row survives and the checkpoint is merged into it). Two invariants:
`NoStrandedEvent` (no event the replay has passed is missing from the cell)
and `ClaimSound` (the frontier claims only what the cell reflects or a pending
full re-fold will fold). Two replicas, `MaxSeq = 2` unless noted.

| Config | Order | Result |
|---|---|---|
| `_Proposed_TrailFail` | proposed | clean, liveness included (282,532 states) |
| `_Proposed_Crash` | proposed | clean (935,875 states) |
| `_Proposed_TrailFail_Crash` | proposed | clean (1,094,565 states) |
| `_Proposed_TwoFaults_TwoCrashes` | proposed, `MaxSeq = 1` | clean (398,073 states) |
| `_Proposed_3R_Safety` | proposed, 3 replicas, `MaxSeq = 1` | exhaustive run exceeds a 6 GB state cap; **19.3M simulated traces clean** |
| `_NoMarker_Crash` | no re-fold mark | **`NoStrandedEvent` violated** |
| `_SkipIfOlder_TrailFail` | a newer local cell is kept | **`ClaimSound` violated** |
| `_LateRederive_TrailFail` | re-fold after the trailing round | **`NoStrandedEvent` violated** |
| `_NoServeGuard_TwoFaults` | a replica serves while re-bootstrapping | **`ClaimSound` violated** — two replicas re-bootstrapping from each other |
| `_MergeFrontier_3R_Safety` | frontier max-merged across the re-fold | **`ClaimSound` violated** (simulation, 3 replicas) |
| `_Proposed_WriteFailCounted` | proposed, a failed install write counted installed | **`ClaimSound` violated** in 8 steps — the peer frontier adopted over a cell the write missed |
| `_Proposed_WriteFailAborts` | proposed, a failed install write fails the batch (failed-stream path) | clean, liveness included (1,384,623 states) |

The proposed order: an unconditional install; a durable re-fold mark written
before the first install batch; a re-fold that resets the frontier and runs
before finalize, clearing the mark with the checkpoint of what it rebuilt; a
replica that serves neither snapshot nor frontier while the mark is set; an
install write that fails ends the session without a finalize. Each
ingredient has an ablation above that fails. Not modelled: compaction,
holds, several cells, chunked installs, and a peer reading the frontier other
than at session start.

### `JoinInstall.tla` — the catalogue install against stabilization, compaction and reap

One add-wins cell. Receipt (the MST) is separate from application (the cell);
an anti-entropy round merges the peer's whole MST; the replay folds causally,
as `causal_tops/4` holds it, and skips an event the frontier claims; the sweep
deletes an empty cell below the HLC stability point once the replay has caught
up, the point being the HLC of the first tree key some member's durable
frontier does not cover, or past every event when every held key is covered
(`BoundMode = "first_unconfirmed"`, the code's
`bondy_oplog_instance:clustered_stability_point/2`); a retired origin's
events never fold. An install is the code's session:
read the source's frontier, stream its cells into a stage, then swap them in
and re-fold the MST events that frontier does not claim, in one step
(`bondy_oplog_applier:stage_cells/3`, `commit_stage/4`); finalize reads the
source's frontier again, the target the replica's claims must reach.
Compaction confirms a truncation by every other member's claims.

Invariants: `SettledSound` (once a replica has received and folded every
event, its cell is the fold of all of them); `SomeoneServes` (while two
replicas or more are live, some replica can still serve a session or clear
its mark); `CompactedClaimed` (every event whose truncation a replica recorded
stays claimed); `NoStrandedRecord` (below); `NoStuckTombstone` (an emptied
cell whose every event is received, covered and folded is below the sweep's
bound), on `_Truncation_CompactMembers` and `_Reap`.

`_Truncation_CompactMembers` is the code: every guard (`mark`, `serve`,
`replayed`, `target`, `early`, `busy`, `token`, `trunc`, `coverbegin`,
`floor`), no local fold before the boot replay (`RefoldFirst`), staged
installs, and compaction by members. Each ablation removes one mechanism from
it, at the bound named. A violated row's depth is the search level at which
TLC stopped, which varies by one between runs.

| Config | Bound, and what is removed | Result |
|---|---|---|
| `_Truncation_CompactMembers` | 2 replicas, 2 events, 1 install | clean (2,075,539 states, depth 29) |
| `_Truncation_CompactMembers_LastConfirmed` | the point one key earlier: the HLC of the last key before the first uncovered one | **violated** `NoStuckTombstone`, depth 9 — an emptied cell every member confirms, whose HLC is the tree's last key's, is never below the bound |
| `_Truncation_CompactMembers_3R` | 3 replicas | no violation in 11,963,287 states (depth 17) before the time guard; not exhaustive |
| `_Stage_2I`, `_Stage_Crash_2I` | no compaction; 2 installs; without and with a crash | clean (4,882,159 states, depth 35; and 32,994,964 states, depth 37) |
| `_Stage_3E_1I` | no compaction; 3 events, `MaxSeq = 2` | clean (28,027,166 states, depth 31) |
| `_NoTrunc` | a truncation runs while the mark is held | **violated** `CompactedClaimed`, depth 10 |
| `_NoCover` | the session begins whether or not the source's frontier covers the replica's truncation record | **violated** `CompactedClaimed`, depth 10 |
| `_NoServe` | 2 installs; a marked source serves | **violated** `SomeoneServes`, depth 6 |
| `_NoReplayed` | 3 events, a crash; a source serves before its boot replay | **violated** `SettledSound`, depth 18 |
| `_NoTarget` | the mark clears at adoption, before the replica claims the target | **violated** `SettledSound`, depth 20 |
| `_NoEarly` | 2 installs; the mark is written at install, not when the session begins | **violated** `CompactedClaimed`, depth 10 |
| `_NoBusy` | 2 installs; a replica starts installing while it serves an open session | **violated** `SomeoneServes`, depth 5 |
| `_Replace` | 3 events, `MaxSeq = 2`; the batches are written over the cells and re-folded later | **violated** `SettledSound`, depth 10 — a local write folds onto the installed cell, lifting its context over an own event the source lacks, and the re-fold skips that event |
| `_NoRefoldFirst` | 3 events, `MaxSeq = 2`, a crash; a local write folds before the boot replay | **violated** `SettledSound`, depth 8 |
| `_NoMark` | 3 events, a crash; the sweep does not wait on the mark | clean (13,169,895 states, depth 33) |
| `_NoToken` | 3 events, a crash; the replica takes a detached session's finalize and target | clean (12,685,374 states, depth 33) |
| `_CompactReceipt` | 3 events, a crash; a peer confirms by receipt (a root, or a reported claim) | clean (13,100,798 states, depth 33) |
| `_Reap` | 3 events, a crash; retired origins reaped, and counted as confirmed by every member (`RetiredExempt`) | no violation in 19,666,863 states (depth 21) before the state guard, nor in 19,600,521 states (depth 21) at `MaxEvents = 2`; not exhaustive |
| `_Truncation_CompactOwn_Stranded` | no witnesses: the replica truncates on its own claims | **violated** `NoStrandedRecord`, depth 5 |
| `_Truncation_CompactRecorded_Stranded_3R` | some set of the other members confirms, as a recency filter would | **violated** `NoStrandedRecord`, depth 9 |
| `_Truncation_CompactDurable_Crash` | every member, the replica included, confirms by its checkpoint; a crash | clean (1,841,177 states, depth 32) |
| `_Truncation_CompactDurable_Crash_NoFloor` | same, a restore of the claims drops the recorded events | **violated** `CompactedClaimed`, depth 12 |

Every guard but two has a violated ablation. The sweep's wait on the mark and
the install token are not shown necessary at these bounds; the code keeps
both, and the mark still gates serving, truncation and the durable claims.
Nor is confirmation by checkpointed claims rather than receipt: the code
confirms by them, and `_Truncation_CompactDurable_Crash` holds with them.

A session that "busy" refuses releases its cursor at its source (`Refuse`). The
model has no cursor expiry and no retry, so the livelock the release prevents,
two refused sessions renewing each other's busy cursor, is argued from the code
and not checked here (`bondy_oplog_instance:begin_install/3`,
`bondy_oplog_catalogue_snapshot:release/2`). A crash drops what was staged and
ends the replica's own session; in the code the session outlives the crash, and
up to its rederive the restarted folder refuses its install token
(`bondy_oplog_applier:open_stage/3`; `bondy_oplog_bootstrap_rederive_test`,
the superseded-install cases). The model, with one session per replica that a
crash always ends, does not check a second install after the rederive. A lone
survivor that owes an install, its only peer having departed mid-session,
waits for a new member; `SomeoneServes` does not ask more. Not modelled:
several cells, other kernels and reduced rewrites, pending claims, a crash
that loses MST receipts, the applier claiming an event after writing its cell
rather than in the same step, and liveness, which `SomeoneServes`
approximates as a safety invariant.

#### Clustering disabled, joins and leaves

`HlcGuards` "solo" and "soloclean" start every replica alone, its
own cluster (`cluster.enabled = off`), compacting on its own frontier, until
the replicas are joined; "leave" lets a member leave, restart alone and come
back. A join or a return is allowed only while at most one side holds a
truncation record (`CleanJoin`). Invariant `NoStrandedRecord`: every event a
replica's truncation record holds is, at every other member, claimed, still
in its tree, or reachable by an install from that replica.

| Config | Joins | Result |
|---|---|---|
| `_Truncation_CompactMembers_SoloClean` | replicas alone, joined while at most one has truncated | clean (2,146,568 states, depth 30) |
| `_Truncation_CompactMembers_SoloClean_3R` | same, three replicas | no violation in 13,221,147 states (depth 18) before the time guard; not exhaustive |
| `_Truncation_CompactMembers_SoloJoinAny` | replicas alone, joined at any time | **violated** in 6 states — both truncate alone, and each refuses the other as a source |
| `_Truncation_CompactMembers_Leave` | members; one leaves (a Partisan leave), restarts alone and returns under `CleanJoin` | clean (12,398,770 states, depth 34) |
| `_Truncation_CompactMembers_Leave_3R`, `_Leave_Crash` | same, three replicas; same, with crashes | no violation in 14,110,286 and 21,448,322 states (depth 16 and 21) before the state guard; not exhaustive |
| `_Truncation_CompactMembers_Leave_Kept` | same, the others keep counting the member that went alone (no leave) | **violated** in 7 states |
| `_Truncation_CompactMembers_Leave_JoinAny` | same, it returns without `CleanJoin` | **violated** in 7 states |

The code holds `CleanJoin` as an operator rule, not a check: an install whose
source has not seen this replica's truncated events is refused
(`source_behind_truncation`), so a join that breaks the rule leaves both sides
serving their own data and never converging
(`bondy_cluster_standalone_SUITE`, and
`doc/guides/configuration/clustering.md`).

### `ReplayReanchor.tla` — the replay cursor across a compaction

One replica, a local origin and remote origins whose events arrive in any
order, so some are held behind a gap. The applier's diff replay keeps its
cursor while it holds an event; local writes never move the cursor; the
instance's delivery and compaction casts reach the applier in order; a restart
loses the mailbox and anchors as `compute_replay_anchor/1` does, and a
drain-gated applier defers its boot replay to `open_drain_gate/1`. Invariant
`Presentable`: once the mailbox is drained, every tree event the projection
lacks is in the next replay's diff. Property `EventuallyApplied`.

| Config | Rule | Result |
|---|---|---|
| `_Shipped_NoRestart` | cursor := post-truncate root | **`Presentable` violated** in 7 steps — a held event under the new cursor |
| `_Shipped_Gated` | same, gated restart | **`Presentable` violated** in 7 steps — the owed full fold cancelled |
| `_Guarded_Open` | re-anchor unless a fold is owed (an unclaimed boot anchor, or a hold), else undefined; restart, ungated | clean, liveness included (52,140 states) |
| `_Guarded_Gated` | same, gated restart | clean, liveness included (97,610 states) |
| `_Guarded_Gated_2R_Safety` | same, two remote origins, `MaxSeq = 2` | clean (246,760 states) |

Without the anchor half of the guard, `_Guarded_Gated` violates
`Presentable`. Not modelled: the fused instance (same rule, applied
inline), several cells, page GC.

## Implementation status: proved vs built

Verified by reading `apps/bondy_oplog/src` at the time of writing.

| Mechanism | Formal status | Code status |
| --- | --- | --- |
| Per-origin prefix hold | `AaeCausalClosure_Shipped.cfg` clean (2 replicas) | **BUILT**, unconditional — `bondy_oplog_cell_apply:partition_contiguous/4`, `contiguous_run/2`; telemetry `[bondy_oplog, applier, events_held]` |
| Contiguity detector | — | **BUILT** — `detect_prefix_holes/2`, `[bondy_oplog, applier, prefix_hole]` |
| Universal-retirement reap guard | `_UniversalS1` / `_Universal` clean | **BUILT** — `bondy_oplog_origin_retirement:universal/1`, `reaped_unconverged` telemetry |
| Persist-before-enforce for bans | `_ForgetfulS1` refutes the alternative | **BUILT** — `bondy_oplog_origin_bans`, `{error, not_persistent}` |
| **Gapped causal context `(contig, exc)`** | **PROVED** (`Dot_Exactness_Gapped.thy`), wire-compatible by `join_degenerates_to_max` | **NOT BUILT** — no `first_gap` / `contig` / `exc` anywhere in `apps/*/src`; `bondy_oplog_crdt_aw_core:vv_merge/2` is still pointwise integer max and `dot_observed/2` is still `N >= S` |
| `ContigClaim` frontier bound | modelled; sound but not complete on the spot (`FrontierPending_Contig_Dead`); clean with the hold in `AaeCausalClosure_Shipped.cfg` | **BUILT** — `merge_applied/2` reports the contiguous prefix; the replay half is `bondy_oplog_instance:replay_anchor/1` |
| **Applied frontier as prefix + pending set** | **PROVED** (`Frontier_Pending.thy`); the one-integer alternative **refuted in general** (`no_scalar_writer_sound_and_complete`) and the earlier rule refuted concretely (`FrontierPending_MaxCap*`) | **BUILT** — `bondy_oplog_registry` carries a `pending` column beside `frontier` (`pending/1`, `frontier_and_pending/1`) and `merge_applied/2` writes the contiguous prefix, holding out-of-order seqs in `pending`. `merge_frontier/2` remains a pointwise max and is now the BOOTSTRAP writer only |
| **Bootstrap frontier adoption** | **PROVED** (`Bucket_Skip_Soundness.adopt_if_complete_sound`), with the responder gate as a HYPOTHESIS; both halves refuted individually (`unconditional_adoption_unsound`, `adoption_unsound_without_serve_gate`) and by TLC (`MuxBucketSkip_Minus_AdoptIfComplete`, `_Minus_ServeGate`) | **BUILT** — both halves: the responder gate, and `bondy_oplog_sync_session:adopt_frontier/3`, which hands `finalize_catalogue_bootstrap/5` the peer's vector only over an install that reported no unroutable bucket |
| Vector stability | `vector_stable` defined; **not certified by the substrate** | **NOT BUILT** |
| **Reap cell directory survives compaction** | `CellContextReap` with `Directory`: `_R2_DirTree` refutes the MST directory (`DirectoryComplete` falls in 3 steps), `_R2_DirTree_Dead` shows the consequence (`DeadContextReachable` falls in 3 steps), the three projection cfgs stay clean; under `"projection"` `DirectoryComplete` is a tautology, so the model refutes the tree, it does not verify the ETS adapter | **BUILT** — `bondy_oplog_projection_ets:cell_keys/2` (`ets:select` over the bound entity bucket) and `bondy_db_topology_memory:primary_cell_scope/1`; checked by `bondy_oplog_projection_ets_test` (`cell_keys_test_`) and `bondy_rib_reclamation_cluster_SUITE:departed_node_rib_state_is_reclaimed_after_compaction` |
| Cross-origin causal delivery | absence **refutes `Convergence`** (`CellContextReap`); a hold that folds nothing ahead of what it observed is causal (`Aw_Kernel.thy`, `causal_hold_delivers_causally`) | **BUILT** — `bondy_oplog_cell_apply:partition_contiguous/4` folds a batch in key order and holds an event whose stamped context names a seq past an origin's foldable top; pinned by `bondy_oplog_bootstrap_rederive_test:held_add_folds_after_a_later_add_that_saw_it` and `held_add_folds_after_its_remove`. `CellContextReap` is not re-run against the hold |
| **Compaction confirmed by every member's durable frontier** | model-checked (`ConfirmedCompaction_2R_Async`, `_3R`, `_3R_Partition`, `_3R_Retire`, `_2R_Async_Partition_Retire`, `_2R_Async_Live`); a recency filter **refuted** (`_3R_Fresh_Partition`, `NoLoss`); `Confirmed_Compaction.thy` proves `no_loss` and `no_drop` for it, for any number of members, with frontiers recorded independently of the merge (exclusions under its entry above) | **BUILT** — `bondy_oplog_instance:compaction_witnesses/1` supplies every member's recorded durable frontier and `member_vvs/2` adds the replica's own; `compute_frontier_for/2` confirms a key every witness covers (`bondy_oplog_event:covered/2`); pinned by `bondy_oplog_compaction_fused_test:peer_compaction_does_not_stall_ours` and `rootless_live_peer_holds_compaction`, rule table in `bondy_oplog_compaction_frontier_test:frontier_scenarios_test_` |
| **Truncation capped below the first un-applied key** | **not shown necessary** on the confirmed frontier (`ConfirmedCompaction_2R_Async_NoCap`, clean); `Confirmed_Compaction.thy`'s `compact` rule truncates only applied events, which the replica's own durable frontier as a witness gives | **BUILT** — `capped_truncation_point/2` in `finalize_catalogue_compaction/4`, on the confirmed and the retention frontier; the below-watermark trim (`trim_below_watermark/3`) and the watermark door hold through `door_truncate/4`. `bondy_oplog_compaction_fused_test` passes with the cap disabled, so no test pins it. Retired origins are exempt (`compaction_truncates_held_event_of_retired_origin`) — not in the model. Compaction has no fold path: `bondy_oplog_catalogue_compaction_test:compaction_makes_no_synchronous_applier_call` pins the only applier call left as the `advance_replayed_root/2` cast |
| **Live re-bootstrap order** | model-checked (`LiveRebootstrapRefold_Proposed_*`, two replicas exhaustive, three simulated); each ingredient's ablation **refuted** (`_NoMarker_Crash`, `_SkipIfOlder_TrailFail`, `_LateRederive_TrailFail`, `_NoServeGuard_TwoFaults`) | **BUILT** — `bondy_oplog_instance:begin_install/3` writes the re-fold mark before the session's first batch request and opens an install token, discarding an earlier install's staging (`bondy_oplog_applier:open_stage/3`); `bondy_oplog_instance:install_catalogue_batch/3` stages every batch; `bondy_oplog_instance:rederive_projection/2` installs the staged batches, replacing every routable cell, resets the frontier (`bondy_oplog_registry:reset_frontier/1`) and re-folds in one call, and the session adopts the peer's frontier on that install's counts, before `finalize_catalogue_bootstrap/5`; a failed stream drops its staging (`bondy_oplog_instance:abort_install/2`); a boot that finds the mark resets the frontier (`boot_frontier/2`); `bondy_oplog_instance:serving/1` gates snapshot init and `get_frontier`; a failed projection write fails the rederive, which still re-folds (`bondy_oplog_applier:commit_stage/4`). Each counterexample is replayed in `bondy_oplog_bootstrap_rederive_test` |
| **Replay cursor across compaction** | model-checked (`ReplayReanchor_Guarded_*`); shipped rule **refuted** (`_Shipped_NoRestart`, `_Shipped_Gated`) | **BUILT** — `bondy_oplog_applier:advance_replayed_root/2` re-anchors unless a fold is `owed` (a boot anchor that found an unclaimed event, or a hold), else drops the cursor to `undefined`; the fused twin is `fused_reanchor_cursor/2`. Pinned by `bondy_oplog_catalogue_compaction_test:held_event_folds_after_compaction/0`, `_fused/0` and `owed_refold_survives_compaction_before_gate/0` |
| **Counter seed across restarts** | **PROVED** (`Seq_Seed.thy`); shipped rule **refuted** (`SeqSeed_Shipped.cfg`) | **BUILT** 2026-09-03 — `init/1` seeds from the restored frontier; `bondy_oplog_wal` records/recovers `max_seq` and calls `bondy_oplog_instance:seed_seq/2` before `set_wal_pid/2`; `fast_wal_target/1` resolves the WAL before the seq is reserved |

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

1. **Cross-origin causal delivery: built, model re-run open.** Its absence is
   a proved convergence violation: `CellContextReap` shows `Convergence`
   failing in 6 steps under out-of-order delivery, with the reap never
   firing, via a three-party inversion in which no origin has a per-origin gap.
   `partition_contiguous/4` now also holds an event whose context observes past
   an origin's foldable top, which `causal_hold_delivers_causally` shows is a
   causal schedule; `CellContextReap` has not been re-run with that hold. This is the
   same distinction as the vector-vs-HLC stability gap recorded in
   `bondy_oplog_crdt_nested_core`'s moduledoc, and it is the sharpest open
   safety question in the development. Note the scope: origins and seqs are
   **per instance**, so nothing here reasons across instances either — a
   cluster-wide causal guarantee is a strictly larger problem than the one
   modelled.
2. ~~**Per-origin prefix closure.**~~ **Closed.** Reproduced on a 3-node
   cluster by the fold-time detector, fixed unconditionally by the hold,
   model-verified (`AaeCausalClosure_Shipped.cfg`, 2 replicas) and
   Fly-validated. Independently, and
   still available, `Dot_Exactness_Gapped.thy` discharges the *exactness*
   obligation by representation rather than by protocol — which is what a
   deployment that cannot preserve prefix closure would need.
3. ~~**The bootstrap adopts a frontier it did not materialise.**~~ **Closed.**
   The unconditional max-merge was proved unsound
   (`unconditional_adoption_unsound`) and violated by TLC in 4 steps
   (`MuxBucketSkip_Minus_AdoptIfComplete`); the sound rule — adopt only when
   the install skipped nothing the joiner could observe — is proved
   (`adopt_if_complete_sound`), model-checked (`MuxBucketSkip_Final_Skew`) and
   now BUILT. No wire change was needed: the install already knew the
   unroutable bucket at the skip site and now returns it as `unclaimable`,
   which is what tells that skip apart from the benign HLC-older one sharing
   the same `skipped` counter. Two things the models decided that taste would
   not have: refusing the bootstrap instead violates `Live`, and so does
   suppressing the frontier-gap verdict the withheld claim provokes
   (`MuxBucketSkip_Minus_GapVerdict`) — the re-bootstrap cycle is the only
   writer of applied state that does not pass through the fold, so it is the
   delivery path for the events the per-origin hold parks, and what ends it is
   an operator acting on the `bondy_oplog_bucket_unroutable` alarm.
4. **Vector stability.** Not certified. Blocks context-governed reduction;
   keeps `stabilize_fold` refused for the add-wins family.
5. **Membership completeness.** I2 quantifies over the confirmed set. A
   replica outside it that can still mint below the frontier breaks the
   argument. `reclamation_members/0` and the stale-peer rejoin work bear on
   this; neither is modelled.
6. **Datatype convergence.** Partial. `Aw_Kernel.thy` relates each kernel
   step to the AFP `ORSet` interpretation (Gomes/Kleppmann/Mulligan/Beresford,
   entry `CRDT`, vendored in `isabelle/afp/CRDT` under its BSD licence), whose
   convergence assumes causal, at-most-once delivery — it consumes
   obligation 1. The network-level instantiation of the locale is not done.

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
