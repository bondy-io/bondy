-------------------------- MODULE OriginReapingWatermark ----------------------
(***************************************************************************)
(* Frontier reaping as a MEET over confirmed peers -- the shape MST         *)
(* compaction already uses -- instead of an agreement protocol.             *)
(*                                                                         *)
(* `OriginReaping.tla` establishes two things. Unilateral reaping breaks    *)
(* `SpuriousGap`. And the obvious meet formulation -- "reap when every      *)
(* member is level, and let the deficit check skip origins I have reaped"   *)
(* -- breaks `ReapedMeansLevel`, because the predicate                      *)
(*                                                                         *)
(*     Dead(o) /\ claim[r][o] = 0                                          *)
(*                                                                         *)
(* cannot tell "I reaped this after verifying I was level" from "I never    *)
(* saw it". A replica that never received a dead origin's events skips a    *)
(* deficit that was real. The meet is sound; RECOMPUTING it from an absent  *)
(* entry is not.                                                           *)
(*                                                                         *)
(* So the meet has to be RECORDED. Recording it per origin is a tombstone   *)
(* and costs exactly what the entry cost. Recording it as a SCALAR costs    *)
(* O(1) -- which is precisely how MST compaction gets away with a           *)
(* watermark. The prerequisite is an ORDER on origins: compaction can use   *)
(* a scalar because keys are ordered by HLC, while origins today are        *)
(* opaque 128-bit randoms with no order at all.                            *)
(*                                                                         *)
(* This module models origins carrying a birth rank, and reaping as a       *)
(* per-replica scalar `reapedBefore` that advances only to a point every    *)
(* member is known to be level at. Everything below it is "reaped and       *)
(* verified", which is exactly the distinction the failed formulation       *)
(* could not express.                                                      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Replicas,
    MaxSeq,
    WatermarkGated   \* FALSE = never reap (baseline); TRUE = the discipline

Origins == Replicas

\* The birth rank. Replicas are modelled as the integers 1..N so the rank
\* is intrinsic; in the implementation this is the origin's birth HLC,
\* packed alongside the random component so the id stays unique but
\* becomes comparable. Any total order agreed by construction will do.
Birth(o) == o

Event == [org : Origins, seq : 1..MaxSeq]
Ev(o, s) == [org |-> o, seq |-> s]
Max2(a, b) == IF a > b THEN a ELSE b

MaxSeqOf(S, o) ==
    LET seqs == {e.seq : e \in {x \in S : x.org = o}}
    IN IF seqs = {} THEN 0 ELSE CHOOSE m \in seqs : \A n \in seqs : n =< m

VARIABLES applied, claim, minted, member, gapFlag, reapedBefore

vars == <<applied, claim, minted, member, gapFlag, reapedBefore>>

Ranks == 0..(Cardinality(Replicas) + 1)

TypeOK ==
    /\ applied      \in [Replicas -> SUBSET Event]
    /\ claim        \in [Replicas -> [Origins -> 0..MaxSeq]]
    /\ minted       \in [Origins -> 0..MaxSeq]
    /\ member       \in [Replicas -> BOOLEAN]
    /\ gapFlag      \in [Replicas -> BOOLEAN]
    /\ reapedBefore \in [Replicas -> Ranks]

Init ==
    /\ applied      = [r \in Replicas |-> {}]
    /\ claim        = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ minted       = [o \in Origins |-> 0]
    /\ member       = [r \in Replicas |-> TRUE]
    /\ gapFlag      = [r \in Replicas |-> FALSE]
    /\ reapedBefore = [r \in Replicas |-> 0]

Dead(o) == ~member[o]

\* Below the watermark: reaped AND verified level at reap time.
Below(r, o) == Birth(o) < reapedBefore[r]

Mint(r) ==
    /\ member[r] /\ ~gapFlag[r] /\ minted[r] < MaxSeq
    /\ LET e == Ev(r, minted[r] + 1) IN
         /\ applied' = [applied EXCEPT ![r] = @ \cup {e}]
         /\ claim'   = [claim EXCEPT ![r][r] = minted[r] + 1]
    /\ minted' = [minted EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<member, gapFlag, reapedBefore>>

Depart(r) ==
    /\ member[r]
    /\ Cardinality({q \in Replicas : member[q]}) > 1
    /\ member' = [member EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<applied, claim, minted, gapFlag, reapedBefore>>

Sync(r, p) ==
    /\ r # p /\ member[r] /\ member[p] /\ ~gapFlag[r]
    /\ LET newApplied == applied[r] \cup applied[p]
           \* An origin below MY watermark is not re-learned from a peer:
           \* I verified everyone was level before dropping it, so the
           \* peer's entry carries nothing I lack. This is what stops
           \* `merge_frontier/2` from simply undoing the reap.
           merged == [o \in Origins |->
                        IF Below(r, o) THEN 0
                        ELSE Max2(claim[r][o], claim[p][o])]
           deficit == \E o \in Origins :
                        /\ ~Below(r, o)
                        /\ claim[p][o] > claim[r][o]
       IN /\ applied' = [applied EXCEPT ![r] = newApplied]
          /\ claim'   = [claim EXCEPT ![r] = merged]
          /\ IF deficit
               THEN gapFlag' = [gapFlag EXCEPT ![r] = TRUE]
               ELSE UNCHANGED gapFlag
    /\ UNCHANGED <<minted, member, reapedBefore>>

\* THE MEET. Advance the scalar past rank k only when every origin at or
\* below k is dead AND every member holds exactly what this replica holds
\* for it. Both conjuncts are read from confirmed peer state -- no
\* agreement protocol, and fail-closed by construction: a member that
\* cannot be asked cannot satisfy the conjunct, so the watermark stalls.
AdvanceWatermark(r) ==
    /\ WatermarkGated
    /\ member[r]
    /\ \E k \in Ranks :
         /\ k > reapedBefore[r]
         /\ \A o \in Origins :
              Birth(o) < k =>
                /\ Dead(o)
                /\ \A q \in Replicas : member[q] => claim[q][o] = claim[r][o]
         /\ reapedBefore' = [reapedBefore EXCEPT ![r] = k]
         /\ claim' = [claim EXCEPT ![r] =
                        [o \in Origins |->
                           IF Birth(o) < k THEN 0 ELSE claim[r][o]]]
    /\ UNCHANGED <<applied, minted, member, gapFlag>>

Rebootstrap(r) ==
    /\ gapFlag[r]
    /\ \E p \in Replicas \ {r} :
         /\ member[p]
         /\ applied' = [applied EXCEPT ![r] = applied[r] \cup applied[p]]
         /\ claim'   = [claim EXCEPT ![r] =
                          [o \in Origins |->
                             IF Below(r, o) THEN 0
                             ELSE Max2(claim[r][o], claim[p][o])]]
    /\ gapFlag' = [gapFlag EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<minted, member, reapedBefore>>

Next ==
    \/ \E r \in Replicas : Mint(r)
    \/ \E r \in Replicas : Depart(r)
    \/ \E r \in Replicas : AdvanceWatermark(r)
    \/ \E r \in Replicas : Rebootstrap(r)
    \/ \E r, p \in Replicas : Sync(r, p)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

NoOverClaim ==
    \A r \in Replicas : \A o \in Origins : \A j \in 1..MaxSeq :
        (j =< claim[r][o]) => (Ev(o, j) \in applied[r])

\* No replica is told it is missing data it already holds.
SpuriousGap ==
    \A r, p \in Replicas :
        (member[r] /\ member[p] /\ r # p) =>
            \A o \in Origins :
                (~Below(r, o) /\ claim[p][o] > claim[r][o])
                    => (MaxSeqOf(applied[r], o) < MaxSeqOf(applied[p], o))

\* THE PROPERTY THE SCALAR MUST EARN, and the one the naive meet broke:
\* anything below the watermark really is fully held here.
ReapedMeansLevel ==
    \A r, p \in Replicas :
        (member[r] /\ member[p]) =>
            \A o \in Origins :
                Below(r, o) =>
                    MaxSeqOf(applied[r], o) >= MaxSeqOf(applied[p], o)

NoDataLoss ==
    \A r \in Replicas : \A o \in Origins :
        (claim[r][o] > 0) => (MaxSeqOf(applied[r], o) >= claim[r][o])

=============================================================================
