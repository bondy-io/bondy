------------------------- MODULE OriginRetirementSet --------------------------
(***************************************************************************)
(* Frontier reaping driven by a REPLICATED retirement set rather than by    *)
(* membership.                                                             *)
(*                                                                          *)
(* Every membership-derived design fails for one reason: membership is      *)
(* reversible. `OriginReaping_SoloJoin` and `OriginWatermarkReap_HlcJoin`   *)
(* both violate once a `Join` action exists, because a departed node's      *)
(* origin is not permanently dead — `bondy_oplog_origin:load_or_create/1`   *)
(* reuses the persisted id, so the node returns minting under the very      *)
(* origin the survivors reaped. The survivors then skip its new events.     *)
(*                                                                          *)
(* So the reap needs a decision that (a) every replica agrees on and (b)    *)
(* cannot be undone by a node coming back. A grow-only set of retired       *)
(* origins, replicated like any other CRDT and driven by an operator        *)
(* decommissioning a node, is both. It is also already half-built:          *)
(* `bondy_oplog_origin_bans` is the fencing half, and the retirement        *)
(* moduledoc already calls bans "an operator tool".                        *)
(*                                                                          *)
(* The bet this module checks: retiring an origin makes skipping its        *)
(* deficit SAFE, because a retired origin is banned, so no replica will     *)
(* ever accept another event from it — there is no future data to be blind  *)
(* to. `BanEnforced = FALSE` checks that the ban is load-bearing rather     *)
(* than decorative.                                                        *)
(*                                                                          *)
(* `ReapRule` selects the precondition a replica applies before dropping a  *)
(* retired origin's frontier entry, and `CompactionModelled` supplies the   *)
(* mechanism that tells the three rules apart. Without compaction every     *)
(* event can always flow by ordinary page sync, so the frontier is a pure   *)
(* oracle and no guard is needed; with it, an event reclaimed from every    *)
(* holder's log moves ONLY when the frontier deficit flags a catalogue      *)
(* rebootstrap, so a claim dropped too early is data a replica can never    *)
(* obtain again.                                                           *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Replicas,
    MaxSeq,
    ReapEnabled,   \* FALSE = today (frontier never reaped)
    BanEnforced,   \* TRUE  = a replica refuses events from origins it has
                   \*         retired (`bondy_oplog_origin_bans`)
    ReapRule,      \* "none" | "meet" | "universal" — see ReapGuard
    CompactionModelled,
    RetirementDurable,
                   \* TRUE  = a retirement is DURABLE the moment it is
                   \*         enforced, so a restart keeps it.
                   \* FALSE = a replica can enforce a retirement it has not
                   \*         persisted, and lose it on restart. This is what
                   \*         "insert into the table, then write the file"
                   \*         admits when the write fails.
    StableMembership
                   \* TRUE = the survivors stay put once a retirement exists:
                   \*        no rejoins, and departures only before the first
                   \*        retirement. This is the deployment the reap is
                   \*        FOR — an operator removes a node and the rest of
                   \*        the cluster carries on — and the setting under
                   \*        which the reachability probe means anything,
                   \*        because a `Depart` makes any "every member ..."
                   \*        guard vacuous for the replicas that left.

Origins == Replicas

Event == [org : Origins, seq : 1..MaxSeq]
Ev(o, s) == [org |-> o, seq |-> s]
Max2(a, b) == IF a > b THEN a ELSE b

MaxSeqOf(S, o) ==
    LET seqs == {e.seq : e \in {x \in S : x.org = o}}
    IN IF seqs = {} THEN 0 ELSE CHOOSE m \in seqs : \A n \in seqs : n =< m

VARIABLES
    applied,   \* [Replicas -> SUBSET Event]
    durable,   \* [Replicas -> SUBSET Origins]  the part of `retired` that
               \*   survives a restart
    compacted, \* [Replicas -> SUBSET Event]  reclaimed from the log; still
               \*   in the projection, so a catalogue rebootstrap ships them
               \*   and ordinary page sync does not
    claim,     \* [Replicas -> [Origins -> Nat]]   the applied-frontier VV
    minted,    \* [Origins -> Nat]
    member,    \* [Replicas -> BOOLEAN]
    retired,   \* [Replicas -> SUBSET Origins]  this replica's view of the
               \*   replicated grow-only retirement set
    gapFlag    \* [Replicas -> BOOLEAN]

vars ==
    <<applied, compacted, claim, minted, member, retired, durable, gapFlag>>

TypeOK ==
    /\ \A r \in Replicas : applied[r] \subseteq Event
    /\ \A r \in Replicas : compacted[r] \subseteq applied[r]
    /\ claim \in [Replicas -> [Origins -> 0..MaxSeq]]
    /\ minted \in [Origins -> 0..MaxSeq]
    /\ member \in [Replicas -> BOOLEAN]
    /\ \A r \in Replicas : retired[r] \subseteq Origins
    /\ \A r \in Replicas : durable[r] \subseteq retired[r]
    /\ gapFlag \in [Replicas -> BOOLEAN]

Init ==
    /\ applied   = [r \in Replicas |-> {}]
    /\ compacted = [r \in Replicas |-> {}]
    /\ claim     = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ minted    = [o \in Origins |-> 0]
    /\ member    = [r \in Replicas |-> TRUE]
    /\ retired   = [r \in Replicas |-> {}]
    /\ durable   = [r \in Replicas |-> {}]
    /\ gapFlag   = [r \in Replicas |-> FALSE]

Mint(r) ==
    /\ member[r] /\ ~gapFlag[r] /\ minted[r] < MaxSeq
    /\ LET e == Ev(r, minted[r] + 1) IN
         /\ applied' = [applied EXCEPT ![r] = @ \cup {e}]
         /\ claim'   = [claim EXCEPT ![r][r] = minted[r] + 1]
    /\ minted' = [minted EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<compacted, member, retired, durable, gapFlag>>

\* Log reclamation. `mst_retention` truncates by local policy and the durable
\* peer-confirmed frontier is recency-filtered, so a replica can reclaim an
\* event a peer has not seen. The event survives in the projection, which is
\* what a catalogue rebootstrap ships — so reclamation removes it from page
\* sync only.
Compact(r) ==
    /\ CompactionModelled
    /\ \E e \in applied[r] \ compacted[r] :
         compacted' = [compacted EXCEPT ![r] = @ \cup {e}]
    /\ UNCHANGED <<applied, claim, minted, member, retired, durable, gapFlag>>

NoRetirementYet == \A q \in Replicas : retired[q] = {}

Depart(r) ==
    /\ member[r]
    /\ Cardinality({q \in Replicas : member[q]}) > 1
    /\ StableMembership => NoRetirementYet
    /\ member' = [member EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<applied, compacted, claim, minted, retired, durable, gapFlag>>

\* A node returns with the disk it left with, so it keeps its persisted
\* origin and resumes minting under it. This is the action every
\* membership-derived reap fails on.
Join(r) ==
    /\ ~StableMembership
    /\ ~member[r]
    /\ member' = [member EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<applied, compacted, claim, minted, retired, durable, gapFlag>>

\* THE OPERATOR ACT. Decommissioning a departed node retires its origin.
\* Recorded at one replica and replicated like any other grow-only set.
Retire(r, o) ==
    /\ ReapEnabled
    /\ member[r]
    /\ ~member[o]
    /\ o \notin retired[r]
    /\ retired' = [retired EXCEPT ![r] = @ \cup {o}]
    /\ durable' = IF RetirementDurable
                     THEN [durable EXCEPT ![r] = @ \cup {o}]
                     ELSE durable
    /\ UNCHANGED <<applied, compacted, claim, minted, member, gapFlag>>

\* Grow-only replication of the retirement set: one replica pulls a member's
\* set and unions it in. Monotone, so it converges with no ordering
\* requirement and cannot conflict. Only members are consulted, matching the
\* implementation, which reads the set over the sync transport.
Propagate(r, p) ==
    /\ r # p /\ member[r] /\ member[p]
    /\ ~(retired[p] \subseteq retired[r])
    /\ retired' = [retired EXCEPT ![r] = @ \cup retired[p]]
    /\ durable' = IF RetirementDurable
                     THEN [durable EXCEPT ![r] = @ \cup retired[p]]
                     ELSE durable
    /\ UNCHANGED <<applied, compacted, claim, minted, member, gapFlag>>

\* A complete AAE round. Under `BanEnforced` the receiver refuses every
\* event whose origin it has retired, which is what makes skipping that
\* origin's deficit safe: there is no future data to be blind to.
Admissible(r, e) == (~BanEnforced) \/ (e.org \notin retired[r])

Sync(r, p) ==
    /\ r # p /\ member[r] /\ member[p] /\ ~gapFlag[r]
    /\ LET incoming ==
                {e \in applied[p] \ compacted[p] : Admissible(r, e)}
           newApplied == applied[r] \cup incoming
           \* The claim rises from the events actually FOLDED
           \* (`bondy_oplog_cell_apply:batch_frontier/1` ->
           \* `bondy_oplog_registry:merge_frontier/2`).
           \*
           \* A retired origin's claim NEVER rises. Filtering the events
           \* while still max-merging the claim would leave the VV asserting
           \* events this replica refused to accept.
           folded == [o \in Origins |->
                        IF o \in retired[r]
                            THEN claim[r][o]
                            ELSE Max2(claim[r][o], MaxSeqOf(newApplied, o))]
           \* The deficit check skips an origin this replica has retired.
           \* Every replica converges on the same retirement set, so the
           \* skip is symmetric rather than a private opinion.
           deficit == \E o \in Origins :
                        /\ o \notin retired[r]
                        /\ claim[p][o] > folded[o]
           \* Adoption of the peer's advertised vector is GATED on the gap
           \* check (`maybe_frontier_gap/5` turns a residual deficit into a
           \* session error, so `maybe_record/6` never adopts). Adopting
           \* through a deficit is exactly the over-claim the check exists
           \* to prevent.
           merged == IF deficit
                        THEN folded
                        ELSE [o \in Origins |->
                                IF o \in retired[r]
                                    THEN claim[r][o]
                                    ELSE Max2(folded[o], claim[p][o])]
       IN /\ applied' = [applied EXCEPT ![r] = newApplied]
          /\ claim'   = [claim EXCEPT ![r] = merged]
          /\ IF deficit
               THEN gapFlag' = [gapFlag EXCEPT ![r] = TRUE]
               ELSE UNCHANGED gapFlag
    /\ UNCHANGED <<compacted, minted, member, retired, durable>>

\* THE REAP. Drop a retired origin's frontier entry. `ReapRule` selects the
\* precondition:
\*
\*   "none"      — retirement alone. Checks that SOME guard is needed.
\*   "meet"      — every member confirmed level on the origin, read fresh.
\*   "universal" — every member has the origin in its retirement set.
\*
\* "meet" is safe and NOT LIVE: the first replica to reap leaves every other
\* replica unequal to it forever, since only a reap lowers a claim and a
\* retired origin's claim never rises again. At most one replica per origin
\* ever reaps, so the entry the reap exists to remove survives everywhere
\* else.
ReapGuard(r, o) ==
    CASE ReapRule = "none" -> TRUE
      [] ReapRule = "meet" ->
            \A q \in Replicas : member[q] => claim[q][o] = claim[r][o]
      [] ReapRule = "universal" ->
            \A q \in Replicas : member[q] => o \in retired[q]

Reap(r) ==
    /\ ReapEnabled
    /\ member[r]
    /\ \E o \in Origins :
         /\ o \in retired[r]
         /\ claim[r][o] > 0
         /\ ReapGuard(r, o)
         /\ claim' = [claim EXCEPT ![r][o] = 0]
    /\ UNCHANGED <<applied, compacted, minted, member, retired, durable, gapFlag>>

\* Catalogue rebootstrap: the peer ships its PROJECTION, which is complete
\* whatever its log has reclaimed, and the finalize adopts its frontier.
Rebootstrap(r) ==
    /\ gapFlag[r]
    /\ \E p \in Replicas \ {r} :
         /\ member[p]
         /\ LET newApplied ==
                    applied[r] \cup {e \in applied[p] : Admissible(r, e)}
            IN /\ applied' = [applied EXCEPT ![r] = newApplied]
               /\ claim'   = [claim EXCEPT ![r] =
                                [o \in Origins |->
                                   IF o \in retired[r]
                                       THEN claim[r][o]
                                       ELSE Max2(
                                              Max2(claim[r][o], claim[p][o]),
                                              MaxSeqOf(newApplied, o))]]
    /\ gapFlag' = [gapFlag EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<compacted, minted, member, retired, durable>>

\* A restart keeps only what was persisted. `applied`, `claim` and the
\* frontier survive by other means (compaction checkpoint, MST, WAL replay),
\* so the retirement set is the only thing a restart can take away — and it
\* is the one thing the whole design needs to be monotone.
Restart(r) ==
    /\ retired[r] # durable[r]
    /\ retired' = [retired EXCEPT ![r] = durable[r]]
    /\ UNCHANGED <<applied, compacted, claim, minted, member, durable,
                   gapFlag>>

Next ==
    \/ \E r \in Replicas : Mint(r)
    \/ \E r \in Replicas : Restart(r)
    \/ \E r \in Replicas : Compact(r)
    \/ \E r \in Replicas : Depart(r)
    \/ \E r \in Replicas : Join(r)
    \/ \E r \in Replicas, o \in Origins : Retire(r, o)
    \/ \E r \in Replicas : Reap(r)
    \/ \E r \in Replicas : Rebootstrap(r)
    \/ \E r, p \in Replicas : Propagate(r, p)
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
                (o \notin retired[r] /\ claim[p][o] > claim[r][o])
                    => (MaxSeqOf(applied[r], o) < MaxSeqOf(applied[p], o))

\* THE PROPERTY THE SKIP MUST EARN. Whenever a replica skips an origin's
\* deficit because it retired it, it is not blind to data it would
\* otherwise have taken — which holds only because the ban means it would
\* never have taken that data anyway.
RetiredSkipIsSafe ==
    \A r, p \in Replicas :
        (member[r] /\ member[p]) =>
            \A o \in Origins :
                (o \in retired[r] /\ claim[r][o] = 0)
                    => (\A e \in applied[p] :
                            e.org = o => ~Admissible(r, e))

\* A replica never holds an event from an origin it has retired and reaped
\* — the ban and the reap agree about what this replica's history contains.
NoDataLoss ==
    \A r \in Replicas : \A o \in Origins :
        (claim[r][o] > 0) => (MaxSeqOf(applied[r], o) >= claim[r][o])

Holders(e) == {p \in Replicas : member[p] /\ e \in applied[p]}

\* THE PROPERTY THE REAP GUARD MUST EARN, and the reason a guard exists at
\* all. An event is STUCK at `q` when every route to it is closed: `q` would
\* accept it, some member holds it, every holder has reclaimed it from its
\* log so page sync cannot ship it, and no member's frontier is ahead of
\* `q`'s on its origin, so no deficit will ever flag the catalogue
\* rebootstrap that could.
\*
\* Dropping a claim closes that last route, which is why the reap needs a
\* precondition under which no member still depends on it.
Stuck(q, e) ==
    /\ member[q]
    /\ e \notin applied[q]
    /\ Admissible(q, e)
    /\ Holders(e) # {}
    /\ \A p \in Holders(e) : e \in compacted[p]
    /\ \A p \in Replicas :
         member[p] =>
            ~(e.org \notin retired[q] /\ claim[p][e.org] > claim[q][e.org])

NoStuckEvent == \A q \in Replicas : \A e \in Event : ~Stuck(q, e)

(***************************************************************************)
(* REACHABILITY PROBE                                                      *)
(*                                                                          *)
(* Stated as an invariant so a VIOLATION is the proof: TLC's counterexample *)
(* is a run in which every member reaped an origin it genuinely held. Under *)
(* a rule that HOLDS this invariant, the reap cannot clear the entry        *)
(* cluster-wide and the leak survives on every replica but one.             *)
(***************************************************************************)
\* More than one member is required, or the probe is satisfied by a cluster
\* that shrank to a single replica — which proves nothing about a rule whose
\* whole difficulty is agreement between replicas.
NotAllMembersReaped ==
    ~ (\E o \in Origins :
         /\ Cardinality({r \in Replicas : member[r]}) > 1
         /\ \A r \in Replicas :
              member[r] =>
                /\ o \in retired[r]
                /\ claim[r][o] = 0
                /\ Ev(o, 1) \in applied[r])

=============================================================================
