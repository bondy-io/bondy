---------------------------- MODULE ReplayReanchor ----------------------------
(***************************************************************************)
(* THIS WAS BUILT BY CLAUDE OPUS and it is not verified.                   *)
(*                                                                         *)
(* Can a compaction move the applier's replay cursor past an event the     *)
(* applier has not folded, so that no later replay presents it?            *)
(*                                                                         *)
(* What the code does, established by reading it:                          *)
(*                                                                         *)
(*   - The applier keeps `last_replayed_root`. A replay asks the instance   *)
(*     for the pairs of the CURRENT tree not under that root (the whole    *)
(*     tree when it is undefined: `bondy_oplog_applier:diff_pairs/3`) and  *)
(*     folds them with the causal hold (`bondy_oplog_cell_apply:           *)
(*     partition_contiguous/4`): a remote event above its origin's         *)
(*     contiguity gap is not folded. The cursor moves to the current root  *)
(*     only when nothing was held (`replay_diff/1`).                       *)
(*   - Local writes are folded by the WAL drain and installed into the     *)
(*     tree; they never move the cursor, so a later diff re-presents them *)
(*     to an idempotent fold.                                              *)
(*   - A remote delivery installs into the tree and casts                  *)
(*     `replay_cell_events` from the instance (`deliver_remote/1`); the    *)
(*     compaction commit casts `advance_replayed_root(NewRoot)` from the   *)
(*     same process (`advance_projection_watermark/2`). Erlang keeps the   *)
(*     order of messages between two processes, so the applier handles    *)
(*     them in that order: `mbox` below.                                   *)
(*   - Compaction truncates a key-order prefix of the tree that stops      *)
(*     strictly below the first key the applied frontier does not claim   *)
(*     (`capped_truncation_point/2`). Peer confirmation is abstracted:     *)
(*     any such prefix may go.                                             *)
(*   - The shipped applier sets the cursor to NewRoot unconditionally      *)
(*     (`handle_cast({advance_replayed_root, _}, _)`).                     *)
(*   - A restart loses the mailbox; the new applier anchors on the current *)
(*     root when the frontier claims every tree event, else undefined      *)
(*     (`bondy_oplog_instance:compute_replay_anchor/1`), and casts itself  *)
(*     a replay at init, or, when founded `drain_gated` (durable `main`),  *)
(*     only at `open_drain_gate/1`. Casts are handled while gated.         *)
(*                                                                         *)
(* Reanchor = "always" is the shipped rule; "guarded" re-anchors only when *)
(* the cursor is defined and the last replay held nothing, and otherwise   *)
(* leaves it undefined so the next replay folds the whole tree. `defined`  *)
(* is not the code's `last_replayed_root =/= undefined`: an anchor that    *)
(* found nothing unclaimed is defined even over an empty tree, whose root  *)
(* is `undefined`. The code carries ~defined \/ holding as one flag,       *)
(* `owed` (`bondy_oplog_applier`).                                         *)
(*                                                                         *)
(* NOT modelled: the fused instance (same rule, applied inline), several   *)
(* cells, peers (an environment delivers remote events in any order),      *)
(* page GC (the "guarded" rule does not read an old root's pages).         *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Local,      \* the local origin
    Remotes,    \* remote origins
    MaxSeq,     \* events per origin
    Reanchor,   \* "always" | "guarded"
    MaxCompact, \* compaction commits a behaviour may make
    MaxRestart, \* restarts a behaviour may make
    Gated       \* TRUE: the boot replay waits for `open_drain_gate/1`

ASSUME Reanchor \in {"always", "guarded"} /\ Gated \in BOOLEAN
ASSUME Local \in Nat /\ Remotes \subseteq Nat /\ Local \notin Remotes

Origins == {Local} \cup Remotes
Event   == [org : Origins, seq : 1..MaxSeq]
Ev(o, s) == [org |-> o, seq |-> s]

\* Key order: HLCs grow per origin, so a key-order prefix holds a per-origin
\* prefix; across origins any fixed interleaving is one schedule of HLCs.
Below(a, b) == a.seq < b.seq \/ (a.seq = b.seq /\ a.org < b.org)

\* The applied frontier's prefix bound per origin (`merge_applied/2`).
Prefix(S, o) ==
    LET ok(n) == \A i \in 1..n : Ev(o, i) \in S
    IN CHOOSE n \in 0..MaxSeq : ok(n) /\ (n = MaxSeq \/ ~ok(n + 1))

Claimed(S) == {e \in Event : e.seq =< Prefix(S, e.org)}

\* What a fold of `Diff` onto `Applied` materialises: local events always,
\* a remote event only when its whole origin prefix is then present.
Fold(Applied, Diff) ==
    LET U == Applied \cup Diff
    IN Applied \cup {e \in Diff :
                       e.org = Local \/ \A i \in 1..e.seq : Ev(e.org, i) \in U}

VARIABLES
    tree,      \* events in the local MST
    applied,   \* events folded into the projection
    gone,      \* events compaction truncated
    delivered, \* remote events received so far
    cursor,    \* the tree under `last_replayed_root`
    defined,   \* `last_replayed_root =/= undefined`
    holding,   \* the last replay held something
    mbox,      \* instance -> applier casts, in order
    gate,      \* the boot replay is still deferred behind the drain gate
    minted, compactions, restarts

vars == <<tree, applied, gone, delivered, cursor, defined, holding, mbox,
          gate, minted, compactions, restarts>>

TypeOK ==
    /\ tree \subseteq Event /\ applied \subseteq Event /\ gone \subseteq Event
    /\ cursor \subseteq Event /\ defined \in BOOLEAN /\ holding \in BOOLEAN

Init ==
    /\ tree = {} /\ applied = {} /\ gone = {} /\ delivered = {}
    /\ cursor = {} /\ defined = TRUE /\ holding = FALSE /\ mbox = <<>>
    /\ gate = FALSE
    /\ minted = 0 /\ compactions = 0 /\ restarts = 0

Mint ==
    /\ minted < MaxSeq
    /\ LET e == Ev(Local, minted + 1)
       IN /\ tree' = tree \cup {e}
          /\ applied' = applied \cup {e}
    /\ minted' = minted + 1
    /\ UNCHANGED <<gone, delivered, cursor, defined, holding, mbox, gate,
                   compactions, restarts>>

Deliver(e) ==
    /\ e.org \in Remotes
    /\ e \notin delivered
    /\ delivered' = delivered \cup {e}
    /\ tree' = tree \cup {e}
    /\ mbox' = Append(mbox, [kind |-> "replay"])
    /\ UNCHANGED <<applied, gone, cursor, defined, holding, gate, minted,
                   compactions, restarts>>

Replay ==
    /\ mbox # <<>> /\ Head(mbox).kind = "replay"
    /\ LET diff == IF defined THEN tree \ cursor ELSE tree
           na   == Fold(applied, diff)
           held == diff \ na
       IN /\ applied' = na
          /\ holding' = (held # {})
          /\ IF held = {}
               THEN cursor' = tree /\ defined' = TRUE
               ELSE UNCHANGED <<cursor, defined>>
    /\ mbox' = Tail(mbox)
    /\ UNCHANGED <<tree, gone, delivered, gate, minted, compactions, restarts>>

Advance ==
    /\ mbox # <<>> /\ Head(mbox).kind = "advance"
    /\ LET nr == Head(mbox).root
       IN IF Reanchor = "always" \/ (defined /\ ~holding)
            THEN cursor' = nr /\ defined' = TRUE
            ELSE cursor' = {} /\ defined' = FALSE
    /\ mbox' = Tail(mbox)
    /\ UNCHANGED <<tree, applied, gone, delivered, holding, gate, minted,
                   compactions, restarts>>

\* A non-empty key-order prefix of the tree, every key of it claimed and
\* strictly below the first unclaimed key.
Compact ==
    /\ compactions < MaxCompact
    /\ \E cut \in SUBSET tree :
         /\ cut # {}
         /\ \A e \in cut : \A f \in tree : Below(f, e) => f \in cut
         /\ cut \subseteq Claimed(applied)
         /\ tree' = tree \ cut
         /\ gone' = gone \cup cut
         /\ mbox' = Append(mbox, [kind |-> "advance", root |-> tree \ cut])
    /\ compactions' = compactions + 1
    /\ UNCHANGED <<applied, delivered, cursor, defined, holding, gate, minted,
                   restarts>>

Restart ==
    /\ restarts < MaxRestart
    /\ mbox' = IF Gated THEN <<>> ELSE <<[kind |-> "replay"]>>
    /\ gate' = Gated
    /\ IF tree \subseteq Claimed(applied)
         THEN cursor' = tree /\ defined' = TRUE
         ELSE cursor' = {} /\ defined' = FALSE
    /\ holding' = FALSE
    /\ restarts' = restarts + 1
    /\ UNCHANGED <<tree, applied, gone, delivered, minted, compactions>>

OpenGate ==
    /\ gate
    /\ gate' = FALSE
    /\ mbox' = Append(mbox, [kind |-> "replay"])
    /\ UNCHANGED <<tree, applied, gone, delivered, cursor, defined, holding,
                   minted, compactions, restarts>>

Next ==
    \/ Mint
    \/ \E e \in Event : Deliver(e)
    \/ Replay \/ Advance \/ Compact \/ Restart \/ OpenGate

Spec == Init /\ [][Next]_vars

\* The environment eventually delivers every remote event and the applier
\* drains its mailbox. A restart is never forced.
Fairness ==
    /\ WF_vars(Mint)
    /\ \A e \in Event : WF_vars(Deliver(e))
    /\ WF_vars(Replay) /\ WF_vars(Advance) /\ WF_vars(OpenGate)

FairSpec == Spec /\ Fairness

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* Once the mailbox is drained and the gate released, every tree event the
\* projection lacks is still re-presentable: the next replay's diff
\* contains it.
Presentable ==
    (mbox = <<>> /\ ~gate) =>
        \A e \in tree \ applied : ~defined \/ e \notin cursor

\* Every event received or minted is eventually folded.
EventuallyApplied ==
    <>[](\A e \in delivered \cup {x \in Event : x.org = Local /\ x.seq =< minted} :
            e \in applied)

=============================================================================
