------------------------------- MODULE OriginReaping ---------------------------
(***************************************************************************)
(* Can a replica drop a dead origin's entry from its applied-frontier VV    *)
(* WITHOUT cluster-wide agreement?                                         *)
(*                                                                         *)
(* The frontier is a join-semilattice element (per-origin max, merged by    *)
(* `bondy_oplog_registry:merge_frontier/2`). Reaping is the only operation  *)
(* in the system that moves it DOWN, so it is the only one that can break   *)
(* the lattice discipline the convergence oracle depends on.                *)
(*                                                                         *)
(* Two consumers decide whether a drop is safe, both read from the code:    *)
(*                                                                         *)
(*   - `bondy_oplog_sync_session:frontier_deficit/2` reads a MISSING local  *)
(*     origin as seq 0 (`maps:get(Origin, Local, 0)`), so a dropped entry   *)
(*     is indistinguishable from "never seen anything from this origin".    *)
(*     A residual deficit after a complete round becomes                    *)
(*     `{frontier_gap, _}` and flags a catalogue rebootstrap.               *)
(*   - `merge_frontier/2` max-merges over the UNION of keys, so a peer that *)
(*     still carries the entry re-adds it.                                  *)
(*                                                                         *)
(* The question is not whether reaping converges — it does, once everyone   *)
(* reaps. The question is whether the transient disagreement is HARMLESS.   *)
(* `SpuriousGap` below is the harm: a replica that holds every event a      *)
(* dead origin ever produced is nonetheless told it is missing data, and    *)
(* pays a full catalogue rebootstrap for it, repeatedly.                    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Replicas,        \* replica ids, also origin ids (one origin per replica)
    MaxSeq,          \* events each origin may mint
    ReapEnabled,     \* FALSE = today's behaviour (frontier never reaped)
    MeetGated,       \* TRUE  = the containment-frontier discipline: reap only
                     \*         what EVERY member is already known to hold at
                     \*         the same value (a meet over confirmed peers,
                     \*         the same shape MST compaction uses), and let
                     \*         the deficit check apply the same predicate.
                     \*         Coordination-free: a monotone function of
                     \*         confirmed peer state, fail-closed when a peer
                     \*         cannot be reached.
    SoloOnly         \* TRUE  = reap only when this replica is the sole member
                     \*         (`reclamation_members/0` returning {ok, []},
                     \*          which the source already calls the case that
                     \*          "licenses maximal reclamation")

Origins == Replicas

Event == [org : Origins, seq : 1..MaxSeq]
Ev(o, s) == [org |-> o, seq |-> s]

Max2(a, b) == IF a > b THEN a ELSE b

\* Highest seq of origin o in S (0 if none).
MaxSeqOf(S, o) ==
    LET seqs == {e.seq : e \in {x \in S : x.org = o}}
    IN IF seqs = {} THEN 0 ELSE CHOOSE m \in seqs : \A n \in seqs : n =< m

VARIABLES
    applied,    \* [Replica -> SUBSET Event]      ground truth
    claim,      \* [Replica -> [Origin -> Nat]]   the frontier VV
    minted,     \* [Origin -> Nat]
    member,     \* [Replica -> BOOLEAN]           Partisan membership
    gapFlag     \* [Replica -> BOOLEAN]           catalogue rebootstrap pending

vars == <<applied, claim, minted, member, gapFlag>>

TypeOK ==
    /\ applied \in [Replicas -> SUBSET Event]
    /\ claim   \in [Replicas -> [Origins -> 0..MaxSeq]]
    /\ minted  \in [Origins -> 0..MaxSeq]
    /\ member  \in [Replicas -> BOOLEAN]
    /\ gapFlag \in [Replicas -> BOOLEAN]

Init ==
    /\ applied = [r \in Replicas |-> {}]
    /\ claim   = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ minted  = [o \in Origins |-> 0]
    /\ member  = [r \in Replicas |-> TRUE]
    /\ gapFlag = [r \in Replicas |-> FALSE]

\* An origin is DEAD when no current member claims it. This is exactly
\* `reap_complement/3`: dead = frontier origins - (own origins U members').
\* It is computed from node-local state plus the membership, with no
\* agreement about the RESULT -- which is the whole point at issue.
Dead(o) == ~member[o]

Mint(r) ==
    /\ member[r]
    /\ ~gapFlag[r]
    /\ minted[r] < MaxSeq
    /\ LET e == Ev(r, minted[r] + 1) IN
         /\ applied' = [applied EXCEPT ![r] = @ \cup {e}]
         /\ claim'   = [claim EXCEPT ![r][r] = minted[r] + 1]
    /\ minted' = [minted EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<member, gapFlag>>

\* A deliberate Partisan removal (`partisan_peer_service:leave/1`). The
\* departed replica's events stay applied at whoever already holds them;
\* only its membership goes away.
Depart(r) ==
    /\ member[r]
    /\ Cardinality({q \in Replicas : member[q]}) > 1
    /\ member' = [member EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<applied, claim, minted, gapFlag>>

\* A complete AAE round: r integrates everything p holds, then compares
\* frontiers. `frontier_deficit/2` reads an absent local origin as 0.
Sync(r, p) ==
    /\ r # p
    /\ member[r] /\ member[p]
    /\ ~gapFlag[r]
    /\ LET newApplied == applied[r] \cup applied[p]
           \* merge_frontier/2: pointwise max over the UNION of keys.
           merged == [o \in Origins |-> Max2(claim[r][o], claim[p][o])]
           \* The deficit is judged BEFORE adoption, against what r holds.
           \* Under the meet discipline an origin this replica has REAPED is
           \* excluded: it only reaped because every member was known to hold
           \* the same value, and a dead origin mints nothing further, so no
           \* member's value for it can ever exceed what this replica already
           \* applied. The exclusion is therefore not "ignore dead origins"
           \* (which would be unsound -- it would hide a genuine shortfall on
           \* a node that never had the data); it is "ignore what I verified
           \* I was level on before dropping".
           reaped(o) == MeetGated /\ Dead(o) /\ claim[r][o] = 0
           deficit == \E o \in Origins :
                        /\ claim[p][o] > claim[r][o]
                        /\ ~reaped(o)
       IN /\ applied' = [applied EXCEPT ![r] = newApplied]
          /\ IF deficit
               THEN /\ gapFlag' = [gapFlag EXCEPT ![r] = TRUE]
                    /\ claim'   = [claim EXCEPT ![r] = merged]
               ELSE /\ claim'   = [claim EXCEPT ![r] = merged]
                    /\ UNCHANGED gapFlag
    /\ UNCHANGED <<minted, member>>

\* THE OPERATION UNDER TEST. Drop a dead origin's frontier entry.
\* `SoloOnly` gates it on this replica being the only member, which is the
\* carve-out the code already licenses elsewhere for reclamation.
Reap(r) ==
    /\ ReapEnabled
    /\ member[r]
    /\ SoloOnly => (\A q \in Replicas : q # r => ~member[q])
    /\ \E o \in Origins :
         /\ Dead(o)
         /\ claim[r][o] > 0
         \* THE MEET. Every member is already at the same value for this
         \* origin, so dropping it cannot make this replica the odd one out
         \* about DATA -- only about bookkeeping, which the deficit check
         \* above now understands.
         /\ MeetGated =>
              (\A q \in Replicas : member[q] => claim[q][o] = claim[r][o])
         \* Only reap what this replica has fully applied: it holds every
         \* event that origin ever minted. Weaker than this is obviously
         \* unsound, so the model grants the strongest local precondition
         \* a node can actually check.
         /\ MaxSeqOf(applied[r], o) = minted[o]
         /\ claim' = [claim EXCEPT ![r][o] = 0]
    /\ UNCHANGED <<applied, minted, member, gapFlag>>

Rebootstrap(r) ==
    /\ gapFlag[r]
    /\ \E p \in Replicas \ {r} :
         /\ member[p]
         /\ applied' = [applied EXCEPT ![r] = applied[r] \cup applied[p]]
         /\ claim'   = [claim EXCEPT ![r] =
                          [o \in Origins |-> Max2(claim[r][o], claim[p][o])]]
    /\ gapFlag' = [gapFlag EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<minted, member>>

Next ==
    \/ \E r \in Replicas : Mint(r)
    \/ \E r \in Replicas : Depart(r)
    \/ \E r \in Replicas : Reap(r)
    \/ \E r \in Replicas : Rebootstrap(r)
    \/ \E r, p \in Replicas : Sync(r, p)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* The oracle never claims more than it can back with data. Reaping LOWERS
\* the claim, so this cannot be broken by reaping alone -- it is here to
\* confirm the model still pins the property the other spec checks.
NoOverClaim ==
    \A r \in Replicas : \A o \in Origins : \A j \in 1..MaxSeq :
        (j =< claim[r][o]) => (Ev(o, j) \in applied[r])

\* THE HARM. A replica is told it is missing data from an origin whose
\* every event it already holds. Downstream this is `{frontier_gap, _}`
\* and a full catalogue rebootstrap -- for nothing, and repeatedly, since
\* the rebootstrap re-merges the peer's frontier and the next retirement
\* pass reaps it again.
SpuriousGap ==
    \A r, p \in Replicas :
        (member[r] /\ member[p] /\ r # p) =>
            \A o \in Origins :
                (claim[p][o] > claim[r][o])
                    => (MaxSeqOf(applied[r], o) < MaxSeqOf(applied[p], o))

\* THE PROPERTY THE MEET DISCIPLINE MUST EARN. Whenever a replica would
\* skip a deficit because it reaped the origin, it really does hold
\* everything the peer holds for that origin. If this can be violated the
\* exclusion is hiding real divergence, which is far worse than the
\* spurious rebootstrap it exists to avoid.
ReapedMeansLevel ==
    \A r, p \in Replicas :
        (member[r] /\ member[p] /\ r # p) =>
            \A o \in Origins :
                (Dead(o) /\ claim[r][o] = 0 /\ claim[p][o] > 0)
                    => (MaxSeqOf(applied[r], o) >= MaxSeqOf(applied[p], o))

\* Reaping must not lose data: whatever a replica applied, it keeps.
\* Checked to separate "the drop corrupts state" from "the drop merely
\* confuses the oracle" -- they have very different fixes.
NoDataLoss ==
    \A r \in Replicas : \A o \in Origins :
        (claim[r][o] > 0) => (MaxSeqOf(applied[r], o) >= claim[r][o])

=============================================================================
