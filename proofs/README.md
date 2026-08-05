# Formal verification: causal-stabilization soundness

**THIS WAS BUILD BY CLAUDE OPUS and it is not verified**

Machine-checked model of the claim `bondy_oplog_applier.erl` makes in its
PREPARE FENCE section — that invariants I1 and I2 recover TCSB-grade causal
stability in an anti-entropy architecture with no causal broadcast layer —
and of the exact boundary of the license that claim extends.

**Status:** builds clean under Isabelle2025-2. No `sorry`, no `oops`, no
`axiomatization`. Scope is the stabilization argument only; datatype
convergence is *not* covered (see [Scope](#scope)).

```
cd proofs/isabelle && isabelle build -D .
```

| Theory | Contents |
| --- | --- |
| `Oplog_Model.thy` | Events, dots, contexts, I1, I2, the stability theorem |
| `Stabilization.thy` | Reduction soundness; the HLC-governed reduction class |
| `Aw_Counterexample.thy` | The refutation for observed-remove, and the positive struct-field case |
| `Hlc.thy` | The hybrid logical clock; discharges hypothesis H3 |
| `Dot_Exactness.thy` | Exactness of the compact `Ctx[O] >= S` test under sparse seqs |

## Scope

Modelled: events `(origin, seq, hlc, cell, ctx)`, per-replica delivered
sets, the containment frontier, the observed-remove primitives, and
state reductions.

Not modelled: the Merkle search tree itself (it enters only through the
containment predicate it decides), compaction, WAL durability, the
projection/overlay, network failure, and datatype convergence.

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
| `causal_delivery` (H2) | Substrate-provided; `bondy_oplog_crdt_aw_map.erl` precondition 2 |
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

## Results

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

**`struct_fold_sound`** — the positive half, same representation and same
value function: any value-preserving reduction of an append-only (struct
field) interpretation is sound above *any* frontier.

This confirms the reasoning already written in
`bondy_oplog_crdt_nested_core.erl`; it does not report a defect. The code
already declines to fold collection types. The value is that the boundary is
now mechanically pinned, so enabling the fold for `aw_map`/`aw_set` would be
refuted rather than merely discouraged by a comment.

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
  would report a skipped dot as observed. That is the precise obligation the
  anti-entropy layer owes `dot_observed/2`, and it is the sharpest form of
  open obligation 1 below.

## The precise grade of the frontier

The headline finding, and the qualifier "TCSB-grade" needs:

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

1. ~~**Does the AAE layer actually establish causal delivery (H2)?**~~
   **Answered in `tla/` — see that README.** Budget-capped rounds are not the
   hazard: an incomplete round delivers *nothing* (`integrate_peer_root/2`
   runs only when `missing_set` is empty). But TLC found that per-origin
   prefix closure holds only when compaction is gated on every replica having
   applied the truncated prefix. Under the recency-filtered frontier the code
   documents, a replica can apply `(o,2)` without `(o,1)` and the max-based
   `frontier_deficit/2` cannot see it. Reachability in the running system is
   unconfirmed; the TLA+ README lists the guards not yet chased.
2. **Membership completeness.** I2 quantifies over the confirmed set. A
   replica outside it that can still mint below the frontier breaks the
   argument. `reclamation_members/0` and the stale-peer rejoin work bear on
   this; neither is modelled.
3. **Datatype convergence.** Not attempted. The natural next step is
   instantiating the Gomes/Kleppmann/Mulligan/Beresford locale (AFP entry
   `CRDT`) for `aw_core`/`nested_core`, which assumes causal delivery as a
   hypothesis — i.e. it consumes obligation 1.

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
