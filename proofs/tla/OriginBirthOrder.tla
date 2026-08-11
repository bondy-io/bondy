---------------------------- MODULE OriginBirthOrder --------------------------
(***************************************************************************)
(* Does the watermark reap need a MONOTONE birth order, or is any total     *)
(* order enough?                                                           *)
(*                                                                         *)
(* `OriginReapingWatermark.tla` proves the meet-as-scalar discipline sound  *)
(* with every origin present from the start, so it never explores an origin *)
(* coming into existence BELOW an established watermark. That is precisely  *)
(* the case a wall-clock-prefixed id admits: UUIDv7, ULID and KSUID all     *)
(* sort by wall clock, so a node whose clock lags -- or rolls back -- mints *)
(* an id that sorts beneath ids already born elsewhere.                    *)
(*                                                                         *)
(* `Below(r,o)` is a pure rank comparison; it does not re-check liveness.   *)
(* So an origin that lands under the watermark is treated as reaped and     *)
(* verified: its entries are dropped, not re-learned on merge, and its      *)
(* deficits ignored. This module asks whether that is reachable.            *)
(*                                                                         *)
(* `MonotoneBirth = TRUE` models Bondy's HLC, which dominates every         *)
(* timestamp it has observed (mechanized in ../isabelle/Hlc.thy), so a      *)
(* newly minted origin sorts strictly above every origin already born.      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Ranks,           \* 1..N -- candidate birth ranks, also the origin ids
    Replicas,
    MaxSeq,
    NoOwner,         \* model value: an origin not yet born has no owner
    MonotoneBirth    \* TRUE = HLC (a new origin outranks every existing one)
                     \* FALSE = wall clock (any unborn rank may be taken)

Origins == Ranks
Birth(o) == o

Event == [org : Origins, seq : 1..MaxSeq]
Ev(o, s) == [org |-> o, seq |-> s]
Max2(a, b) == IF a > b THEN a ELSE b

MaxSeqOf(S, o) ==
    LET seqs == {e.seq : e \in {x \in S : x.org = o}}
    IN IF seqs = {} THEN 0 ELSE CHOOSE m \in seqs : \A n \in seqs : n =< m

VARIABLES
    born,         \* SUBSET Origins          origins that exist
    owner,        \* [Origins -> Replicas \cup {none}]
    applied,      \* [Replicas -> SUBSET Event]
    claim,        \* [Replicas -> [Origins -> Nat]]
    minted,       \* [Origins -> Nat]
    live,         \* SUBSET Origins          origins whose owner is a member
    reapedBefore  \* [Replicas -> Nat]

vars == <<born, owner, applied, claim, minted, live, reapedBefore>>

TypeOK ==
    /\ born \subseteq Origins
    /\ owner \in [Origins -> Replicas \cup {NoOwner}]
    /\ applied \in [Replicas -> SUBSET Event]
    /\ claim \in [Replicas -> [Origins -> 0..MaxSeq]]
    /\ minted \in [Origins -> 0..MaxSeq]
    /\ live \subseteq Origins
    /\ reapedBefore \in [Replicas -> 0..(Cardinality(Ranks) + 1)]

Init ==
    /\ born = {}
    /\ owner = [o \in Origins |-> NoOwner]
    /\ applied = [r \in Replicas |-> {}]
    /\ claim = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ minted = [o \in Origins |-> 0]
    /\ live = {}
    /\ reapedBefore = [r \in Replicas |-> 0]

Below(r, o) == Birth(o) < reapedBefore[r]

\* A replica takes a fresh origin epoch (a boot, or a rebuilt instance dir).
\* Under MonotoneBirth the new rank outranks every rank already born, which
\* is what an HLC gives. Without it, ANY unborn rank is admissible -- the
\* wall-clock case.
Create(r, o) ==
    /\ o \notin born
    /\ MonotoneBirth => (\A q \in born : o > q)
    /\ born' = born \cup {o}
    /\ owner' = [owner EXCEPT ![o] = r]
    /\ live' = live \cup {o}
    /\ UNCHANGED <<applied, claim, minted, reapedBefore>>

Mint(o) ==
    /\ o \in live
    /\ minted[o] < MaxSeq
    /\ LET r == owner[o] e == Ev(o, minted[o] + 1) IN
         /\ applied' = [applied EXCEPT ![r] = @ \cup {e}]
         /\ claim' = [claim EXCEPT ![r][o] = minted[o] + 1]
    /\ minted' = [minted EXCEPT ![o] = @ + 1]
    /\ UNCHANGED <<born, owner, live, reapedBefore>>

Retire(o) ==
    /\ o \in live
    /\ live' = live \ {o}
    /\ UNCHANGED <<born, owner, applied, claim, minted, reapedBefore>>

Sync(r, p) ==
    /\ r # p
    /\ LET merged == [o \in Origins |->
                        IF Below(r, o) THEN 0
                        ELSE Max2(claim[r][o], claim[p][o])]
       IN /\ applied' = [applied EXCEPT ![r] = applied[r] \cup applied[p]]
          /\ claim' = [claim EXCEPT ![r] = merged]
    /\ UNCHANGED <<born, owner, minted, live, reapedBefore>>

AdvanceWatermark(r) ==
    /\ \E k \in 1..(Cardinality(Ranks) + 1) :
         /\ k > reapedBefore[r]
         \* Every rank below k must ALREADY BE BORN. Skipping an unborn
         \* rank is what lets a later origin land under the watermark and
         \* be mistaken for reaped-and-verified. Requiring born-ness makes
         \* the rule safe under ANY total order; whether it can advance at
         \* all then depends on the order being gap-free, which is the
         \* difference between an HLC and a wall clock.
         /\ \A o \in Origins :
              Birth(o) < k =>
                /\ o \in born
                /\ o \notin live
                /\ \A q \in Replicas : claim[q][o] = claim[r][o]
         /\ reapedBefore' = [reapedBefore EXCEPT ![r] = k]
         /\ claim' = [claim EXCEPT ![r] =
                        [o \in Origins |->
                           IF Birth(o) < k THEN 0 ELSE claim[r][o]]]
    /\ UNCHANGED <<born, owner, applied, minted, live>>

Next ==
    \/ \E r \in Replicas, o \in Origins : Create(r, o)
    \/ \E o \in Origins : Mint(o)
    \/ \E o \in Origins : Retire(o)
    \/ \E r \in Replicas : AdvanceWatermark(r)
    \/ \E r, p \in Replicas : Sync(r, p)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* THE HAZARD. A LIVE origin must never fall below a watermark: everything
\* below it is treated as reaped-and-verified, so a live origin there has
\* its entries dropped, is not re-learned on merge, and its deficits are
\* ignored -- data loss, not a bookkeeping wart.
NoLiveOriginBelowWatermark ==
    \A r \in Replicas : \A o \in Origins :
        (o \in live /\ o \in born) => ~Below(r, o)

\* Anything below the watermark really is fully held here.
ReapedMeansLevel ==
    \A r, p \in Replicas : \A o \in Origins :
        (Below(r, o) /\ o \in born) =>
            MaxSeqOf(applied[r], o) >= MaxSeqOf(applied[p], o)

=============================================================================
