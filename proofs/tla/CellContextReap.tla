---------------------------- MODULE CellContextReap ---------------------------
(***************************************************************************)
(* Does reaping a dead origin's CAUSAL CONTEXT entry from a tier_2 cell     *)
(* change what any replica computes?                                       *)
(*                                                                         *)
(* `bondy_oplog_crdt_aw_map:reap_origins/2` drops a retired origin's `CC`   *)
(* entry when that origin holds no live dot in any key's dot-store. The     *)
(* automatic driver (`bondy_oplog_origin_retirement:reap_complement/3`)     *)
(* establishes only that the origin is claimed by no current member; it     *)
(* never consults the stability oracle.                                    *)
(*                                                                         *)
(* WHAT THE CELL CONTEXT IS AND IS NOT                                     *)
(*                                                                         *)
(* `CC` is not a delivery filter. Every call site of                        *)
(* `bondy_oplog_crdt_aw_core:drop_observed/2` — `nested_core:put/5`,        *)
(* `nested_core:rmv/3`, `crdt_ew_flag` — is passed the OPERATION's stamped  *)
(* context, threaded from the event `meta` through                          *)
(* `bondy_oplog_cell_kernel:apply/6` and                                    *)
(* `bondy_oplog_crdt_commutative:apply_op/5`. `put/5` adds its dot          *)
(* unconditionally; it never asks whether `CC` already observed it. The     *)
(* only readers of `CC` are `cc_absorb/3` and `context_of/1`, which hands   *)
(* it to the stamp site for the NEXT write.                                *)
(*                                                                         *)
(* Re-delivery is filtered upstream of the CRDT entirely, by the           *)
(* applied-frontier VV — which the reaper does not touch:                  *)
(*                                                                         *)
(*   - `bondy_oplog_instance:append_remote_install/3` — `bondy_mst:get/2`   *)
(*     on the event key: a key already in the local MST is an idempotent    *)
(*     re-receive and is not delivered.                                     *)
(*   - `append_remote_below_watermark/3` and `watermark_door/3` — an event  *)
(*     at or below the compaction watermark is dropped unless the applied   *)
(*     VV says this replica never applied it.                              *)
(*                                                                         *)
(* This module therefore models the cell as the code implements it: ops     *)
(* carry their own stamped context, `CC` feeds only the stamp, and the two  *)
(* doors above gate delivery. `ReapEnabled` toggles the reap; the           *)
(* comparison between the two runs is the whole experiment.                *)
(*                                                                         *)
(* `CausalDelivery` is orthogonal and is varied independently so a          *)
(* violation caused by out-of-order delivery — a property of the substrate  *)
(* with or without reaping — cannot be mistaken for one caused by the reap. *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Replicas,
    MaxSeq,
    ReapEnabled,     \* TRUE = `reap_origins/2` may drop a dead origin's CC entry
    CausalDelivery   \* TRUE = an op is delivered only once its author's
                     \*        observed context is fully applied here

Origins == Replicas

VV == [Origins -> 0..MaxSeq]
Dot == [org : Origins, seq : 1..MaxSeq]
D(o, s) == [org |-> o, seq |-> s]

\* An operation exactly as it travels: its own dot, its kind, and the
\* context its author stamped into `meta` at mint time. Replicated
\* verbatim, and interpreted at every replica against THAT context.
Op == [dot : Dot, kind : {"put", "rmv"}, ctx : VV]

Max2(a, b) == IF a > b THEN a ELSE b

\* Replica identity is opaque here — nothing in the spec or the invariants
\* orders or distinguishes replicas — so the checker may quotient by
\* permutation. Used with model values at the 3-replica scale.
Symm == Permutations(Replicas)

VARIABLES
    dots,      \* [Replicas -> SUBSET Dot]  one key's live dot-store
    cc,        \* [Replicas -> VV]          the cell context: stamp source only
    frontier,  \* [Replicas -> VV]          the applied VV (never reaped)
    tree,      \* [Replicas -> SUBSET Op]   MST content: what AAE can still ship
    minted,    \* [Origins -> Nat]
    live,      \* SUBSET Origins            origins owned by a current member
    removed,   \* [Replicas -> SUBSET Dot]  dots this replica has dropped
    applied    \* [Replicas -> SUBSET Op]   ops folded into this projection

vars ==
    <<dots, cc, frontier, tree, minted, live, removed, applied>>

TypeOK ==
    /\ \A r \in Replicas : dots[r] \subseteq Dot
    /\ cc \in [Replicas -> VV]
    /\ frontier \in [Replicas -> VV]
    /\ \A r \in Replicas : \A o \in tree[r] : o \in Op
    /\ minted \in [Origins -> 0..MaxSeq]
    /\ live \subseteq Origins
    /\ \A r \in Replicas : removed[r] \subseteq Dot
    /\ \A r \in Replicas : \A o \in applied[r] : o \in Op

Init ==
    /\ dots     = [r \in Replicas |-> {}]
    /\ cc       = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ frontier = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ tree     = [r \in Replicas |-> {}]
    /\ minted   = [o \in Origins |-> 0]
    /\ live     = Origins
    /\ removed  = [r \in Replicas |-> {}]
    /\ applied  = [r \in Replicas |-> {}]

(***************************************************************************)
(* THE CRDT STEP, as `bondy_oplog_crdt_aw_map:apply_op/4` implements it.   *)
(***************************************************************************)

\* `dot_observed({O,S}, Ctx)`: exactly `Ctx[O] >= S`.
Observed(d, Ctx) == Ctx[d.org] >= d.seq

\* `drop_observed/2`.
DropObserved(DS, Ctx) == {d \in DS : ~Observed(d, Ctx)}

\* `cc_absorb/3`: pointwise max of the cell context, the writer's context
\* and the op's own dot.
Absorb(C, Ctx, d) ==
    [o \in Origins |->
        IF o = d.org
            THEN Max2(Max2(C[o], Ctx[o]), d.seq)
            ELSE Max2(C[o], Ctx[o])]

\* `nested_core:put/5` adds its dot UNCONDITIONALLY after dropping what the
\* WRITER's context observed. `rmv/3` only drops. Neither consults `CC`.
NewDots(r, op) ==
    IF op.kind = "put"
        THEN DropObserved(dots[r], op.ctx) \cup {op.dot}
        ELSE DropObserved(dots[r], op.ctx)

\* `bondy_oplog_cell_apply` merges the batch's per-origin max into the
\* applied frontier after a successful projection write
\* (`batch_frontier/1` -> `bondy_oplog_registry:merge_frontier/2`).
BumpFrontier(F, d) ==
    [F EXCEPT ![d.org] = Max2(@, d.seq)]

\* One fold of `op` into `r`'s projection. Shared by the local mint and the
\* remote delivery, because the code shares it too.
Fold(r, op) ==
    /\ dots'     = [dots     EXCEPT ![r] = NewDots(r, op)]
    /\ removed'  = [removed  EXCEPT ![r] = @ \cup (dots[r] \ NewDots(r, op))]
    /\ cc'       = [cc       EXCEPT ![r] = Absorb(@, op.ctx, op.dot)]
    /\ frontier' = [frontier EXCEPT ![r] = BumpFrontier(@, op.dot)]
    /\ applied'  = [applied  EXCEPT ![r] = @ \cup {op}]
    /\ tree'     = [tree     EXCEPT ![r] = @ \cup {op}]

(***************************************************************************)
(* ACTIONS                                                                 *)
(***************************************************************************)

\* A local write. The stamp is `context_of/1` — the cell's CURRENT context,
\* which is precisely what the reap shrinks.
Mint(r, kind) ==
    /\ r \in live
    /\ minted[r] < MaxSeq
    /\ LET d  == D(r, minted[r] + 1)
           op == [dot |-> d, kind |-> kind, ctx |-> cc[r]]
       IN Fold(r, op)
    /\ minted' = [minted EXCEPT ![r] = @ + 1]
    /\ UNCHANGED live

\* Remote delivery through both doors:
\*   - the event key is not already in the local MST
\*     (`append_remote_install/3`);
\*   - the applied VV does not already witness it
\*     (`append_remote_below_watermark/3`, `watermark_door/3`).
\* Under `CausalDelivery` the author's observed context must also be
\* applied here first.
Deliver(r, op) ==
    /\ \E p \in Replicas : p # r /\ op \in tree[p]
    /\ ~(\E q \in tree[r] : q.dot = op.dot)
    /\ ~(frontier[r][op.dot.org] >= op.dot.seq)
    /\ CausalDelivery =>
         (\A o \in Origins : op.ctx[o] =< frontier[r][o])
    /\ Fold(r, op)
    /\ UNCHANGED <<minted, live>>

\* MST compaction. Deliberately weaker than the real truncation (which
\* removes an HLC-ordered prefix): any applied op may leave the tree, which
\* is a superset of the reachable states, so a clean result is stronger.
Compact(r, op) ==
    /\ op \in tree[r]
    /\ frontier[r][op.dot.org] >= op.dot.seq
    /\ tree' = [tree EXCEPT ![r] = @ \ {op}]
    /\ UNCHANGED <<dots, cc, frontier, minted, live, removed, applied>>

\* A deliberate Partisan removal. The departed origin's events stay in
\* whoever's tree already holds them.
Depart(o) ==
    /\ o \in live
    /\ Cardinality(live) > 1
    /\ live' = live \ {o}
    /\ UNCHANGED <<dots, cc, frontier, tree, minted, removed, applied>>

\* THE OPERATION UNDER REVIEW: `reap_origins/2` under the membership-only
\* driver. Both of its guards are modelled — the origin is claimed by no
\* current member, and it holds no live dot here — and nothing else.
ReapCell(r, o) ==
    /\ ReapEnabled
    /\ o \notin live
    /\ cc[r][o] > 0
    /\ ~(\E d \in dots[r] : d.org = o)
    /\ cc' = [cc EXCEPT ![r][o] = 0]
    /\ UNCHANGED <<dots, frontier, tree, minted, live, removed, applied>>

Next ==
    \/ \E r \in Replicas, k \in {"put", "rmv"} : Mint(r, k)
    \/ \E r \in Replicas, op \in Op : Deliver(r, op)
    \/ \E r \in Replicas, op \in Op : Compact(r, op)
    \/ \E o \in Origins : Depart(o)
    \/ \E r \in Replicas, o \in Origins : ReapCell(r, o)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* THE HARM the reap was suspected of. A dot this replica dropped must
\* never reappear in its dot-store. A dot re-enters only by re-applying its
\* own `put`, so add-wins concurrency cannot account for it.
NoResurrection ==
    \A r \in Replicas : removed[r] \cap dots[r] = {}

\* THE CRDT LAW. Two replicas that have folded the same operation set hold
\* the same value. This is what a per-replica context divergence would
\* break, and it is why the reap is checked against it rather than against
\* a bookkeeping equality.
Convergence ==
    \A r, p \in Replicas :
        applied[r] = applied[p] => dots[r] = dots[p]

\* The value never contains a dot whose operation was never folded here.
NoPhantomDot ==
    \A r \in Replicas :
        \A d \in dots[r] : \E op \in applied[r] : op.dot = d

\* Internal consistency of the cell: every live dot is covered by the
\* context, which is what makes the stamp a truthful statement of the
\* writer's causal past. Reaping moves the context DOWN, so this is the
\* invariant a mis-specified reap guard breaks first.
ContextCoversDots ==
    \A r \in Replicas :
        \A d \in dots[r] : cc[r][d.org] >= d.seq

=============================================================================
