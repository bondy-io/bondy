-------------------------- MODULE OriginWatermarkReap -------------------------
(***************************************************************************)
(* Frontier reaping as a recorded meet, with origins BORN over time and the *)
(* meet sourced from the peer-state table the implementation would actually *)
(* read.                                                                    *)
(*                                                                          *)
(* This merges two earlier modules and closes the gap between them.         *)
(* `OriginReapingWatermark.tla` proves the meet-as-scalar discipline sound   *)
(* with every origin present at `Init`, so it never explores an origin       *)
(* coming into existence below an established watermark.                    *)
(* `OriginBirthOrder.tla` explores exactly that, but in isolation. Composing *)
(* two results is not a result: here births and the watermark are one spec,  *)
(* so the born-prefix property is CHECKED rather than assumed.               *)
(*                                                                          *)
(* It also replaces the idealisation both earlier modules share. They read   *)
(* every peer's frontier as a live value. The implementation cannot: the     *)
(* meet's only available source is `bondy_oplog_peer_state`, whose           *)
(* `frontier` column is documented as "the peer's applied-frontier version   *)
(* vector as observed AT THE START OF THE LAST COMPLETED ROUND" — a          *)
(* snapshot, not a current read. Two flags model the two readings the module *)
(* offers:                                                                  *)
(*                                                                          *)
(*   `StalePeerState`  — the meet reads the recorded snapshot rather than    *)
(*                       the peer's current frontier.                       *)
(*   `RecencyFiltered` — members unheard-from past `peer_timeout_ms` are     *)
(*                       dropped from the conjunct                          *)
(*                       (`get_instance_peer_states/1,2`) instead of         *)
(*                       holding it down (`confirmed_peer_states/2`).       *)
(*                                                                          *)
(* `bondy_oplog_peer_state`'s own moduledoc already asserts the recency      *)
(* answer — *"Reclamation MUST use the strict reading"* — so `RecencyFiltered *)
(* = TRUE` is checked to confirm the assertion bites here too, not to        *)
(* discover it. `StalePeerState` is the genuinely open one.                  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Replicas,
    Ranks,           \* candidate birth ranks; an origin IS its rank
    MaxSeq,
    HlcIds,          \* TRUE  = origin ids are HLC-derived: a new id strictly
                     \*         exceeds the minter's clock, and a clock absorbs
                     \*         every clock it syncs with
                     \* FALSE = wall-clock ids: no absorption, so a lagging
                     \*         node can mint beneath ranks already in use
    WatermarkGated,  \* FALSE = never reap (baseline)
    StalePeerState,  \* TRUE = the meet reads the recorded snapshot
    RecencyFiltered, \* TRUE = silent members are dropped from the conjunct
    MembershipGrows  \* TRUE = a departed replica may rejoin, carrying whatever
                     \*        it held when it left. The meet consults MEMBERS,
                     \*        so a non-member is not consulted — and if it can
                     \*        come back holding more than the reaper verified,
                     \*        the watermark is a silent hole rather than a
                     \*        bookkeeping wart.

Origins == Ranks
Birth(o) == o

\* WHICH replica owns which epoch carries no information — the ranks are
\* what the watermark compares — so ownership is fixed by construction
\* rather than explored. `N < Cardinality(Ranks)` gives some replica a
\* later epoch, which is the case the birth order exists to cover.
N == Cardinality(Replicas)
Owner(o) == ((o - 1) % N) + 1

VV == [Origins -> 0..MaxSeq]
Event == [org : Origins, seq : 1..MaxSeq]
Ev(o, s) == [org |-> o, seq |-> s]
Max2(a, b) == IF a > b THEN a ELSE b

MaxSeqOf(S, o) ==
    LET seqs == {e.seq : e \in {x \in S : x.org = o}}
    IN IF seqs = {} THEN 0 ELSE CHOOSE m \in seqs : \A n \in seqs : n =< m

Levels == 0..(Cardinality(Ranks) + 1)

VARIABLES
    born,          \* SUBSET Origins            origins that exist
    current,       \* [Replicas -> Origins \cup {0}]  the live epoch
    member,        \* [Replicas -> BOOLEAN]     Partisan membership
    applied,       \* [Replicas -> SUBSET Event]
    claim,         \* [Replicas -> VV]          the applied-frontier VV
    minted,        \* [Origins -> Nat]
    clock,         \* [Replicas -> Levels]      the minting clock
    reapedBefore,  \* [Replicas -> Levels]      the recorded meet, as a scalar
    recorded,      \* [Replicas -> [Replicas -> VV]]  peer_state.frontier
    hasRecord,     \* [Replicas -> [Replicas -> BOOLEAN]]  a round completed
    silent,        \* [Replicas -> BOOLEAN]     unheard-from past the timeout
    gapFlag        \* [Replicas -> BOOLEAN]     catalogue rebootstrap pending

vars ==
    <<born, current, member, applied, claim, minted, clock,
      reapedBefore, recorded, hasRecord, silent, gapFlag>>

TypeOK ==
    /\ born \subseteq Origins
    /\ current \in [Replicas -> Origins \cup {0}]
    /\ member \in [Replicas -> BOOLEAN]
    /\ \A r \in Replicas : applied[r] \subseteq Event
    /\ claim \in [Replicas -> VV]
    /\ minted \in [Origins -> 0..MaxSeq]
    /\ clock \in [Replicas -> Levels]
    /\ reapedBefore \in [Replicas -> Levels]
    /\ recorded \in [Replicas -> [Replicas -> VV]]
    /\ hasRecord \in [Replicas -> [Replicas -> BOOLEAN]]
    /\ silent \in [Replicas -> BOOLEAN]
    /\ gapFlag \in [Replicas -> BOOLEAN]

Init ==
    /\ born         = {}
    /\ current      = [r \in Replicas |-> 0]
    /\ member       = [r \in Replicas |-> TRUE]
    /\ applied      = [r \in Replicas |-> {}]
    /\ claim        = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ minted       = [o \in Origins |-> 0]
    /\ clock        = [r \in Replicas |-> 0]
    /\ reapedBefore = [r \in Replicas |-> 0]
    /\ recorded     = [r \in Replicas |-> [q \in Replicas |->
                          [o \in Origins |-> 0]]]
    /\ hasRecord    = [r \in Replicas |-> [q \in Replicas |-> FALSE]]
    /\ silent       = [r \in Replicas |-> FALSE]
    /\ gapFlag      = [r \in Replicas |-> FALSE]

\* An origin is LIVE while it is a current member's current epoch. Anything
\* else is dead: a departed node's origins, and any epoch a surviving node
\* has rotated away from (a rebuilt instance directory).
Live(o) == \E r \in Replicas : member[r] /\ current[r] = o

\* Below the watermark: reaped AND verified level at reap time.
Below(r, o) == Birth(o) < reapedBefore[r]

(***************************************************************************)
(* THE MEET'S SOURCE — what a real implementation can actually read.        *)
(***************************************************************************)

PeerFrontier(r, q, o) ==
    IF StalePeerState THEN recorded[r][q][o] ELSE claim[q][o]

HasSource(r, q) == (~StalePeerState) \/ hasRecord[r][q]

Members(r) == {q \in Replicas : member[q] /\ q # r}

\* `confirmed_peer_states/2` returns `{ok, _}` only when EVERY member has a
\* checkpointed root, so a silent member holds the watermark down. The
\* recency-filtered reading drops it instead.
Consulted(r) ==
    IF RecencyFiltered
        THEN {q \in Members(r) : ~silent[q] /\ HasSource(r, q)}
        ELSE Members(r)

SourceComplete(r) ==
    RecencyFiltered \/ (\A q \in Members(r) : HasSource(r, q))

(***************************************************************************)
(* ACTIONS                                                                 *)
(***************************************************************************)

\* A replica takes a fresh origin epoch: a boot with a rebuilt instance
\* directory. Under `HlcIds` the new id strictly exceeds the minter's clock,
\* which is what an HLC-derived id gives.
Create(o) ==
    /\ LET r == Owner(o) IN
         /\ member[r]
         /\ HlcIds => o > clock[r]
         /\ clock' = [clock EXCEPT ![r] = Max2(@, o)]
    /\ o \notin born
    /\ born' = born \cup {o}
    /\ current' = [current EXCEPT ![Owner(o)] = o]
    /\ UNCHANGED <<member, applied, claim, minted, reapedBefore,
                   recorded, hasRecord, silent, gapFlag>>

Mint(o) ==
    /\ Live(o)
    /\ minted[o] < MaxSeq
    /\ LET r == Owner(o) IN
         /\ ~gapFlag[r]
         /\ applied' = [applied EXCEPT ![r] = @ \cup {Ev(o, minted[o] + 1)}]
         /\ claim' = [claim EXCEPT ![r][o] = minted[o] + 1]
    /\ minted' = [minted EXCEPT ![o] = @ + 1]
    /\ UNCHANGED <<born, current, member, clock, reapedBefore,
                   recorded, hasRecord, silent, gapFlag>>

\* A deliberate Partisan removal. Every origin the replica ever owned is
\* dead from here on; its events stay applied wherever they landed.
Depart(r) ==
    /\ member[r]
    /\ Cardinality({q \in Replicas : member[q]}) > 1
    /\ member' = [member EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<born, current, applied, claim, minted, clock,
                   reapedBefore, recorded, hasRecord, silent, gapFlag>>

\* A rejoin. Partisan membership changes by a deliberate join/leave in BOTH
\* directions, so this is the exact counterpart of `Depart`. The replica
\* returns with the state it left with.
Join(r) ==
    /\ MembershipGrows
    /\ ~member[r]
    /\ member' = [member EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<born, current, applied, claim, minted, clock,
                   reapedBefore, recorded, hasRecord, silent, gapFlag>>

\* A completed AAE round. It integrates the peer, records the peer's
\* frontier AS OBSERVED NOW — the snapshot `peer_state` keeps — and
\* freshens recency.
Sync(r, p) ==
    /\ r # p /\ member[r] /\ member[p] /\ ~gapFlag[r]
    /\ LET merged == [o \in Origins |->
                        IF Below(r, o) THEN 0
                        ELSE Max2(claim[r][o], claim[p][o])]
           deficit == \E o \in Origins :
                        /\ ~Below(r, o)
                        /\ claim[p][o] > claim[r][o]
       IN /\ applied' = [applied EXCEPT ![r] = @ \cup applied[p]]
          /\ claim' = [claim EXCEPT ![r] = merged]
          /\ IF deficit
               THEN gapFlag' = [gapFlag EXCEPT ![r] = TRUE]
               ELSE UNCHANGED gapFlag
    /\ IF StalePeerState
         THEN /\ recorded' = [recorded EXCEPT ![r][p] = claim[p]]
              /\ hasRecord' = [hasRecord EXCEPT ![r][p] = TRUE]
         ELSE UNCHANGED <<recorded, hasRecord>>
    /\ silent' = [silent EXCEPT ![p] = FALSE]
    /\ IF HlcIds
         THEN clock' = [clock EXCEPT ![r] = Max2(@, clock[p])]
         ELSE UNCHANGED clock
    /\ UNCHANGED <<born, current, member, minted, reapedBefore>>

\* Time passes without a completed round against this peer.
GoSilent(p) ==
    /\ RecencyFiltered
    /\ ~silent[p]
    /\ silent' = [silent EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<born, current, member, applied, claim, minted, clock,
                   reapedBefore, recorded, hasRecord, gapFlag>>

\* THE MEET. Two conjuncts, and the second is the one an earlier draft got
\* wrong.
\*
\* (1) Every origin ALREADY BORN below k is dead and held by every consulted
\*     member at exactly this replica's value — the meet itself.
\*
\* (2) No member can ever mint an origin below k. Requiring instead that
\*     every RANK below k be born is safe but VACUOUS: ids are timestamps,
\*     so the rank space is sparse and the born set is never a contiguous
\*     prefix, and the watermark could not advance past the first id ever
\*     issued. The condition that actually holds is clock domination — an
\*     HLC-derived id strictly exceeds its minter's clock, and every clock
\*     absorbs every clock it syncs with, so a member whose clock is already
\*     at or above k can never mint beneath it. This is what makes the id
\*     scheme load-bearing rather than cosmetic: a wall clock offers no
\*     domination, and a lagging node mints under an established watermark.
AdvanceWatermark(r) ==
    /\ WatermarkGated
    /\ member[r]
    /\ SourceComplete(r)
    /\ \E k \in Levels :
         /\ k > reapedBefore[r]
         /\ \A o \in born :
              Birth(o) < k =>
                /\ ~Live(o)
                /\ \A q \in Consulted(r) : PeerFrontier(r, q, o) = claim[r][o]
         /\ \A q \in Replicas : member[q] => clock[q] >= k
         /\ reapedBefore' = [reapedBefore EXCEPT ![r] = k]
         /\ claim' = [claim EXCEPT ![r] =
                        [o \in Origins |->
                           IF Birth(o) < k THEN 0 ELSE claim[r][o]]]
    /\ UNCHANGED <<born, current, member, applied, minted, clock,
                   recorded, hasRecord, silent, gapFlag>>

Rebootstrap(r) ==
    /\ gapFlag[r]
    /\ \E p \in Replicas \ {r} :
         /\ member[p]
         /\ applied' = [applied EXCEPT ![r] = @ \cup applied[p]]
         /\ claim' = [claim EXCEPT ![r] =
                        [o \in Origins |->
                           IF Below(r, o) THEN 0
                           ELSE Max2(claim[r][o], claim[p][o])]]
    /\ gapFlag' = [gapFlag EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<born, current, member, minted, clock, reapedBefore,
                   recorded, hasRecord, silent>>

Next ==
    \/ \E o \in Origins : Create(o)
    \/ \E o \in Origins : Mint(o)
    \/ \E r \in Replicas : Depart(r)
    \/ \E r \in Replicas : Join(r)
    \/ \E r \in Replicas : GoSilent(r)
    \/ \E r \in Replicas : AdvanceWatermark(r)
    \/ \E r \in Replicas : Rebootstrap(r)
    \/ \E r, p \in Replicas : Sync(r, p)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* The oracle never claims more than it can back with data.
NoOverClaim ==
    \A r \in Replicas : \A o \in Origins : \A j \in 1..MaxSeq :
        (j =< claim[r][o]) => (Ev(o, j) \in applied[r])

\* THE HAZARD the birth order introduces. A LIVE origin below a watermark
\* has its entries dropped, is not re-learned on merge, and its deficits
\* are ignored — data loss, not a bookkeeping wart.
NoLiveOriginBelowWatermark ==
    \A r \in Replicas : \A o \in Origins :
        (o \in born /\ Live(o)) => ~Below(r, o)

\* THE PROPERTY THE SCALAR MUST EARN: everything below the watermark really
\* is fully held here. This is what a stale or recency-filtered source
\* breaks, because it lets the meet be computed against a value the peer
\* has already moved past.
ReapedMeansLevel ==
    \A r, p \in Replicas :
        (member[r] /\ member[p]) =>
            \A o \in Origins :
                Below(r, o) =>
                    MaxSeqOf(applied[r], o) >= MaxSeqOf(applied[p], o)

\* REACHABILITY PROBE, not a safety property. Checked as an invariant so a
\* violation is TLC reporting the trace in which the watermark first
\* advances — which distinguishes a configuration where reaping is merely
\* SAFE from one where it actually happens. Safety and effectiveness are
\* different questions and the birth order separates them.
NeverReaps == \A r \in Replicas : reapedBefore[r] = 0

\* No replica is told it is missing data it already holds.
SpuriousGap ==
    \A r, p \in Replicas :
        (member[r] /\ member[p] /\ r # p) =>
            \A o \in Origins :
                (~Below(r, o) /\ claim[p][o] > claim[r][o])
                    => (MaxSeqOf(applied[r], o) < MaxSeqOf(applied[p], o))

=============================================================================
