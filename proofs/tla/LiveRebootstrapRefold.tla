------------------------- MODULE LiveRebootstrapRefold -------------------------
(***************************************************************************)
(* THIS WAS BUILT BY CLAUDE OPUS and it is not verified.                   *)
(*                                                                         *)
(* Does a LIVE catalogue re-bootstrap leave a cell missing the effect of   *)
(* an event the replica holds in its MST and has replayed past?            *)
(*                                                                         *)
(* What the code does, established by reading it:                         *)
(*                                                                         *)
(*   - The install is skip-if-older by cell HLC, else REPLACE the whole    *)
(*     cell (`bondy_oplog_applier:handle_cell/12`). A peer cell with the   *)
(*     higher HLC that lacks a local origin's event drops that event's     *)
(*     effect from the local cell.                                         *)
(*                                                                         *)
(*   - `finalize_catalogue_bootstrap/5` then adopts the peer's frontier    *)
(*     and persists it; the trailing round (`run/3`) pulls and replays;    *)
(*     only if it returns `{ok, _}` (or `root_unservable`) does            *)
(*     `finish_bootstrap/4` call `rederive_projection`, which resets the   *)
(*     replay cursor and re-folds the whole MST onto the current cells.    *)
(*                                                                         *)
(*   - A replay presents only `tree \ cursor`. Local writes fold on the    *)
(*     WAL drain and never move the cursor.                                *)
(*                                                                         *)
(*   - On restart the cursor is the current root when the restored         *)
(*     frontier claims every MST event, else undefined (a full re-fold)    *)
(*     (`bondy_oplog_instance:compute_replay_anchor/1`). The re-bootstrap  *)
(*     flag lives in the scheduler's ETS and does not survive a crash.     *)
(*                                                                         *)
(* One cell, add-only effects: a cell's state is the set of events folded  *)
(* into it, and folding an event already present is a no-op. Its HLC is   *)
(* the highest event HLC it holds.                                         *)
(*                                                                         *)
(* NOT modelled: compaction, holds (no action here creates a seq gap),     *)
(* removes, multiple cells, the frontier-gap verdict. What starts a        *)
(* re-bootstrap is an environment fault, bounded by MaxFaults, so a        *)
(* repair that depends on the trigger firing again is not assumed.         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Replicas,       \* replica ids, also used as origin ids
    MaxSeq,         \* how many events each origin may mint
    RederiveEarly,  \* TRUE: re-fold right after the install, before the
                    \* frontier is adopted. FALSE: re-fold after a
                    \* successful trailing round only.
    DurableMarker,  \* TRUE: a durable "re-fold owed" mark is written before
                    \* the first install batch and cleared once a full re-fold
                    \* has run; a restart that finds it re-anchors the cursor
                    \* to undefined.
    MaxFaults,      \* re-bootstrap triggers
    MaxTrailFails,  \* trailing rounds that fail
    MaxCrashes      \* replica crashes

Origins == Replicas

Event == [org : Origins, seq : 1..MaxSeq]

Ev(o, s) == [org |-> o, seq |-> s]

Max2(a, b) == IF a > b THEN a ELSE b

Phases == {"idle", "installed", "rederived", "finalized"}

VARIABLES
    cell,     \* [Replica -> SUBSET Event]  events whose effect is in the cell
    tree,     \* [Replica -> SUBSET Event]  events in the local MST
    cursor,   \* [Replica -> SUBSET Event]  events the replay has diffed past
    claim,    \* [Replica -> [Origin -> Nat]]  the applied frontier
    hlc,      \* [Origin -> [1..MaxSeq -> Nat]]  HLC each event was minted at
    clock,    \* Nat  the last HLC minted anywhere
    minted,   \* [Origin -> Nat]
    gapFlag,  \* [Replica -> BOOLEAN]  re-bootstrap pending
    phase,    \* [Replica -> Phases]  where a bootstrap session is
    sess,     \* [Replica -> Replicas]  the peer of that session
    owed,     \* [Replica -> BOOLEAN]  the durable re-fold mark
    pfront,   \* [Replica -> [Origin -> Nat]]  the peer frontier the session
              \* read before streaming (`request_peer_frontier/4`)
    faults, trailFails, crashes

vars ==
    <<cell, tree, cursor, claim, hlc, clock, minted, gapFlag, phase, sess,
      owed, pfront, faults, trailFails, crashes>>

CellHlc(S) ==
    IF S = {} THEN 0
    ELSE CHOOSE h \in {hlc[e.org][e.seq] : e \in S} :
             \A e \in S : hlc[e.org][e.seq] =< h

MaxSeqOf(S, o) ==
    LET seqs == {e.seq : e \in {x \in S : x.org = o}}
    IN IF seqs = {} THEN 0 ELSE CHOOSE m \in seqs : \A n \in seqs : n =< m

AllMinted == {Ev(o, s) : o \in Origins, s \in 1..MaxSeq} \cap
             {e \in Event : e.seq =< minted[e.org]}

Seed == CHOOSE r \in Replicas : TRUE

TypeOK ==
    /\ cell    \in [Replicas -> SUBSET Event]
    /\ tree    \in [Replicas -> SUBSET Event]
    /\ cursor  \in [Replicas -> SUBSET Event]
    /\ claim   \in [Replicas -> [Origins -> 0..MaxSeq]]
    /\ minted  \in [Origins -> 0..MaxSeq]
    /\ gapFlag \in [Replicas -> BOOLEAN]
    /\ phase   \in [Replicas -> Phases]
    /\ sess    \in [Replicas -> Replicas]
    /\ owed    \in [Replicas -> BOOLEAN]
    /\ pfront  \in [Replicas -> [Origins -> 0..MaxSeq]]

Init ==
    /\ cell    = [r \in Replicas |-> {}]
    /\ tree    = [r \in Replicas |-> {}]
    /\ cursor  = [r \in Replicas |-> {}]
    /\ claim   = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ hlc     = [o \in Origins |-> [s \in 1..MaxSeq |-> 0]]
    /\ clock   = 0
    /\ minted  = [o \in Origins |-> 0]
    /\ gapFlag = [r \in Replicas |-> FALSE]
    /\ phase   = [r \in Replicas |-> "idle"]
    /\ sess    = [r \in Replicas |-> Seed]
    /\ owed    = [r \in Replicas |-> FALSE]
    /\ pfront  = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ faults = 0 /\ trailFails = 0 /\ crashes = 0

(* A local write: folds on the WAL drain, so it reaches the cell and the   *)
(* MST and claims its own seq, but does not move the replay cursor.        *)
Mint(r) ==
    /\ minted[r] < MaxSeq
    /\ LET s == minted[r] + 1
           e == Ev(r, s)
       IN /\ hlc'    = [hlc EXCEPT ![r][s] = clock + 1]
          /\ cell'   = [cell  EXCEPT ![r] = @ \cup {e}]
          /\ tree'   = [tree  EXCEPT ![r] = @ \cup {e}]
          /\ claim'  = [claim EXCEPT ![r][r] = s]
    /\ clock'  = clock + 1
    /\ minted' = [minted EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<pfront, cursor, gapFlag, phase, sess, owed, faults, trailFails, crashes>>

(* A live anti-entropy round merges the peer's MST. Not dispatched while a *)
(* bootstrap session is in flight (`rebootstrap_state/1` = inflight).      *)
Pull(r, p) ==
    /\ r # p
    /\ phase[r] = "idle"
    /\ ~gapFlag[r]
    /\ ~(tree[p] \subseteq tree[r])
    /\ tree' = [tree EXCEPT ![r] = @ \cup tree[p]]
    /\ UNCHANGED <<pfront, cell, cursor, claim, hlc, clock, minted, gapFlag, phase,
                   sess, owed, faults, trailFails, crashes>>

(* The applier's diff replay: folds `tree \ cursor` onto the current cell  *)
(* and moves the cursor to the current root.                               *)
FoldPresented(r, T) ==
    /\ cell'   = [cell   EXCEPT ![r] = @ \cup (T \ cursor[r])]
    /\ cursor' = [cursor EXCEPT ![r] = T]
    /\ claim'  = [claim  EXCEPT ![r] =
                    [o \in Origins |-> Max2(@[o], MaxSeqOf(T, o))]]

\* A replay from an undefined cursor is a full re-fold, which pays the mark,
\* but not while a session is still installing.
Replay(r) ==
    /\ tree[r] \ cursor[r] # {}
    /\ FoldPresented(r, tree[r])
    /\ owed' = [owed EXCEPT ![r] =
                  IF cursor[r] = {} /\ phase[r] = "idle" THEN FALSE ELSE @]
    /\ UNCHANGED <<pfront, tree, hlc, clock, minted, gapFlag, phase, sess, faults,
                   trailFails, crashes>>

(* Whatever makes the scheduler flag a re-bootstrap: the peer reclaimed     *)
(* pages, a standing frontier gap, an unservable root.                      *)
Fault(r) ==
    /\ faults < MaxFaults
    /\ phase[r] = "idle"
    /\ ~gapFlag[r]
    /\ gapFlag' = [gapFlag EXCEPT ![r] = TRUE]
    /\ faults'  = faults + 1
    /\ UNCHANGED <<pfront, cell, tree, cursor, claim, hlc, clock, minted, phase, sess,
                   owed, trailFails, crashes>>

(* The catalogue install: skip-if-older, else replace the whole cell. The   *)
(* flag is consumed at dispatch.                                            *)
Install(r, p) ==
    /\ r # p
    /\ gapFlag[r]
    /\ phase[r] = "idle"
    /\ cell'    = [cell EXCEPT ![r] =
                     IF CellHlc(cell[p]) > CellHlc(cell[r]) THEN cell[p] ELSE @]
    /\ phase'   = [phase   EXCEPT ![r] = "installed"]
    /\ sess'    = [sess    EXCEPT ![r] = p]
    /\ gapFlag' = [gapFlag EXCEPT ![r] = FALSE]
    /\ owed'    = [owed EXCEPT ![r] = DurableMarker]
    /\ pfront'  = [pfront EXCEPT ![r] = claim[p]]
    /\ UNCHANGED <<tree, cursor, claim, hlc, clock, minted, faults, trailFails,
                   crashes>>

(* `rederive_projection`: the cursor is reset, so the whole MST is folded   *)
(* onto the cells as they are now.                                          *)
Rederive(r) ==
    /\ RederiveEarly
    /\ phase[r] = "installed"
    /\ cell'   = [cell   EXCEPT ![r] = @ \cup tree[r]]
    /\ cursor' = [cursor EXCEPT ![r] = tree[r]]
    /\ claim'  = [claim  EXCEPT ![r] =
                    [o \in Origins |-> Max2(@[o], MaxSeqOf(tree[r], o))]]
    /\ phase'  = [phase  EXCEPT ![r] = "rederived"]
    /\ owed'   = [owed   EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<pfront, tree, hlc, clock, minted, gapFlag, sess, faults, trailFails,
                   crashes>>

(* `finalize_catalogue_bootstrap/5`: adopt the peer frontier read before   *)
(* the install, and persist it.                                             *)
Finalize(r) ==
    /\ phase[r] = IF RederiveEarly THEN "rederived" ELSE "installed"
    /\ claim' = [claim EXCEPT ![r] =
                   [o \in Origins |-> Max2(@[o], pfront[r][o])]]
    /\ phase' = [phase EXCEPT ![r] = "finalized"]
    /\ UNCHANGED <<pfront, cell, tree, cursor, hlc, clock, minted, gapFlag, sess,
                   owed, faults, trailFails, crashes>>

(* The trailing round succeeds: pull, replay, and (late order) re-fold.    *)
TrailOk(r) ==
    /\ phase[r] = "finalized"
    /\ LET T == tree[r] \cup tree[sess[r]]
       IN /\ tree'   = [tree   EXCEPT ![r] = T]
          /\ cursor' = [cursor EXCEPT ![r] = T]
          /\ cell'   = [cell   EXCEPT ![r] =
                          IF RederiveEarly THEN @ \cup (T \ cursor[r])
                          ELSE @ \cup T]
          /\ claim'  = [claim  EXCEPT ![r] =
                          [o \in Origins |-> Max2(@[o], MaxSeqOf(T, o))]]
    /\ phase' = [phase EXCEPT ![r] = "idle"]
    /\ owed'  = [owed  EXCEPT ![r] = IF RederiveEarly THEN @ ELSE FALSE]
    /\ UNCHANGED <<pfront, hlc, clock, minted, gapFlag, sess, faults, trailFails,
                   crashes>>

(* The trailing round fails (`{partisan_call_failed, timeout}`, ...).      *)
TrailFail(r) ==
    /\ trailFails < MaxTrailFails
    /\ phase[r] = "finalized"
    /\ phase'      = [phase EXCEPT ![r] = "idle"]
    /\ trailFails' = trailFails + 1
    /\ UNCHANGED <<pfront, cell, tree, cursor, claim, hlc, clock, minted, gapFlag,
                   sess, owed, faults, crashes>>

(* A crash keeps cell, tree and claim; the session and the flag are lost;  *)
(* the cursor is re-anchored by `compute_replay_anchor/1`, or to undefined *)
(* when the durable mark is set.                                           *)
Crash(r) ==
    /\ crashes < MaxCrashes
    /\ cursor'  = [cursor EXCEPT ![r] =
                     IF ~owed[r] /\ \A e \in tree[r] : e.seq =< claim[r][e.org]
                       THEN tree[r] ELSE {}]
    /\ phase'   = [phase   EXCEPT ![r] = "idle"]
    /\ gapFlag' = [gapFlag EXCEPT ![r] = FALSE]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<pfront, cell, tree, claim, hlc, clock, minted, sess, owed, faults,
                   trailFails>>

Next ==
    \/ \E r \in Replicas : Mint(r) \/ Replay(r) \/ Fault(r) \/ Rederive(r)
                          \/ Finalize(r) \/ TrailOk(r) \/ TrailFail(r)
                          \/ Crash(r)
    \/ \E r, p \in Replicas : Pull(r, p) \/ Install(r, p)

Spec == Init /\ [][Next]_vars

Fairness ==
    /\ \A r, p \in Replicas : WF_vars(Pull(r, p)) /\ WF_vars(Install(r, p))
    /\ \A r \in Replicas :
          /\ WF_vars(Replay(r)) /\ WF_vars(Rederive(r))
          /\ WF_vars(Finalize(r)) /\ WF_vars(TrailOk(r))

FairSpec == Spec /\ Fairness

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* Eventually every replica's cell holds every minted event's effect, and
\* keeps it.
Converges == <>[](\A r \in Replicas : AllMinted \subseteq cell[r])

\* Outside a bootstrap session, the cell holds every event the replay has
\* diffed past: no replay will present such an event again.
NoStrandedEvent ==
    \A r \in Replicas :
        phase[r] = "idle" => cursor[r] \subseteq cell[r]

=============================================================================
