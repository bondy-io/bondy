------------------------- MODULE ConfirmedCompaction -------------------------
(***************************************************************************)
(* Compaction by peer confirmation: what a replica may truncate from its   *)
(* MST once its members have reported what they hold, and whether every    *)
(* member still receives every event.                                      *)
(*                                                                         *)
(* The mechanism, read from the code (bondy_oplog_sync_session,            *)
(* bondy_oplog_responder, bondy_oplog_peer_state, bondy_oplog_compaction,  *)
(* bondy_oplog_instance):                                                  *)
(*                                                                         *)
(*   - A round is a PULL. r reads p's durable frontier (`get_frontier`),   *)
(*     merges p's tree into its own, records that frontier against p       *)
(*     (`record_sync_complete/3`), then reports its own durable frontier   *)
(*     to p, which records it against r (`confirm_frontier`).              *)
(*   - A replica's durable frontier (`durable_frontier/1`) is the frontier *)
(*     of its last checkpoint on a durable backend, and its applied        *)
(*     frontier on the ETS backend. A fused instance is ETS only           *)
(*     (`bondy_db:assert_fused_requires_ephemeral/2`); an applier-backed   *)
(*     one checkpoints its applied frontier at the start of every          *)
(*     compaction cycle. Checkpoint below fires at any time, which covers  *)
(*     both backends.                                                      *)
(*   - The witnesses are every member's recorded frontier and the          *)
(*     replica's own durable frontier (`compaction_witnesses/1`,           *)
(*     `member_vvs/2`). A witness confirms a key whose seq is at or below  *)
(*     its entry for the key's origin (`bondy_oplog_event:covered/2`).     *)
(*     Compaction truncates up to the largest key K such that every key    *)
(*     =< K is confirmed by every witness (`compute_frontier_for/2`),      *)
(*     capped strictly below the first key the replica has not applied     *)
(*     (`capped_truncation_point/2`).                                      *)
(*   - After a merge the watermark door truncates the key prefix at or     *)
(*     below the watermark that every witness confirms and the replica     *)
(*     has applied (`watermark_door/2`); a compaction cycle whose frontier *)
(*     does not pass the watermark does the same (`trim_below_watermark`). *)
(*                                                                         *)
(* Scope. All replicas are members from the start and every peer row      *)
(* exists, recording nothing, before any write. No mst_retention, no       *)
(* catalogue rebootstrap, no crash, no origin retirement. Keys carry an    *)
(* explicit HLC so truncation is by key order. Rounds are atomic and every *)
(* report reaches its peer.                                                *)
(*                                                                         *)
(* Partitions and the witness set. A link between two replicas can be cut *)
(* and healed; a round needs the link. Every member's row bounds          *)
(* compaction until the member leaves (Retire), however long it has been   *)
(* silent. Witnesses = "fresh" is the ablation: a recency filter that      *)
(* drops a row no round has refreshed (Expire). Retire is the operator's   *)
(* permanent removal of a member; its own unsynced events are given up, so *)
(* NoLoss and NoGap exclude them.                                          *)
(*                                                                         *)
(* Lost pages (fused only). Lose is the fault of a page missing from a     *)
(* replica's own tree: its keys stay under the root but nothing can read   *)
(* them, so the replica cannot fold them and its responder refuses every   *)
(* pull (`aae_root/1`, `root_unservable`). What it applied reaches a peer  *)
(* only through the catalogue re-bootstrap from its projection             *)
(* (Rebootstrap; `maybe_unservable_behind/3`). The frontier walk stops at *)
(* a lost page (`compute_frontier_for/2`, `bondy_mst:fold/4` with          *)
(* `{missing, throw}`), so compaction and the door truncate nothing on a   *)
(* cycle whose walk meets one. Heal is the rebuild that cycle turns to     *)
(* instead (`rebuild_frontier/2`): with every member's recorded frontier   *)
(* covering the replica's applied one, it truncates the tree through the   *)
(* compaction cap and advances the watermark past it. It may fire on any   *)
(* cycle.                                                                  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Replicas,    \* a set of naturals (also the origin ids); 0 is reserved
    MaxSeq,      \* events each origin may mint
    Skew,        \* how far past what it has seen a replica's clock may run
                 \* at a mint: 0 is a global clock (skew only from a replica
                 \* not having seen a peer's events yet), each extra unit
                 \* admits a mint that sorts above that many unseen events
    AsyncApply,  \* TRUE: remote events are folded by a separate Replay step
                 \* and the durable frontier is the checkpointed one (the
                 \* applier-backed instance); FALSE: folded inline in the
                 \* round, and the durable frontier is the applied one (the
                 \* fused instance)
    Witnesses,   \* "members" (the code) | "fresh" (recency filter)
    MaxCuts,     \* link cuts a behaviour may make
    MaxRetire,   \* members the operator may retire
    DoorRule,    \* "confirmed" (the code): the door drops only a key prefix
                 \* of applied events at or below the watermark that every
                 \* witness confirms, as recorded before this round, and
                 \* compaction truncates the confirmed prefix wherever it
                 \* sits relative to the watermark, never lowering it.
                 \* "keep": as "confirmed", but the door drops nothing.
                 \* "drop": the door drops the applied events at or below
                 \* the watermark whether confirmed or not, and a cycle
                 \* below the watermark truncates at the watermark.
    MaxDepth,    \* bound for WithinDepth; unused unless a config constrains
    CapAtUnapplied, \* TRUE (the code): a truncation point is capped strictly
                 \* below the first local key this replica has not applied.
                 \* FALSE: truncation reaches the frontier or the watermark
                 \* regardless, folding what lies above the watermark first.
    MaxLost,     \* pages a behaviour may lose (one key each)
    WalkLost,    \* FALSE (the code): a walk that meets a lost page truncates
                 \* nothing; what lies past it goes only through Heal. TRUE:
                 \* the ablation, compaction and the door walk past a lost
                 \* page, judging only the readable keys, and a truncation
                 \* point drops the lost keys below it.
    HealGate,    \* "dominate" (the code): Heal needs every member's recorded
                 \* frontier to cover the replica's applied one. "none": the
                 \* ablation, no gate. "off": the ablation, no Heal.
    FusedHold,   \* TRUE (the code): a fused round may hold back the events it
                 \* merged (`fused_replay_diff/3`'s causal hold), and a later
                 \* Replay folds them. Holding the whole round over-
                 \* approximates the per-event hold. FALSE: a fused round
                 \* folds every event it can.
    HealCap      \* TRUE (the code): Heal stops strictly below the first
                 \* readable key the replica has not applied, as compaction
                 \* does. FALSE: the ablation, Heal truncates the whole tree.

ASSUME Replicas \subseteq Nat /\ 0 \notin Replicas
ASSUME Skew \in Nat
ASSUME AsyncApply \in BOOLEAN
ASSUME CapAtUnapplied \in BOOLEAN
ASSUME DoorRule \in {"drop", "keep", "confirmed"}
ASSUME Witnesses \in {"fresh", "members"}
ASSUME MaxCuts \in Nat /\ MaxRetire \in Nat /\ MaxLost \in Nat
ASSUME WalkLost \in BOOLEAN /\ HealCap \in BOOLEAN
ASSUME HealGate \in {"dominate", "none", "off"}
ASSUME FusedHold \in BOOLEAN

Origins == Replicas
Event   == [org : Origins, seq : 1..MaxSeq]
\* Every HLC a mint can reach: each mint adds at most Skew + 1.
MaxHlc  == Cardinality(Replicas) * MaxSeq * (Skew + 1)
Ev(o, s) == [org |-> o, seq |-> s]
NoEvent == [org |-> 0, seq |-> 0]
VVs     == [Origins -> 0..MaxSeq]
ZeroVV  == [o \in Origins |-> 0]

VARIABLES
    hlc,      \* [Origin -> [1..MaxSeq -> Nat]]  0 = not minted yet
    minted,   \* [Origin -> 0..MaxSeq]
    tree,     \* [Replica -> SUBSET Event]  items under the local root
    applied,  \* [Replica -> SUBSET Event]  events folded into the projection
    durable,  \* [Replica -> VVs]  checkpointed frontier (AsyncApply only)
    wm,       \* [Replica -> Event \cup {NoEvent}]  compaction watermark key
    vv,       \* [Replica -> [Replica -> VVs]]  recorded peer frontier
    link,     \* [Replica -> [Replica -> BOOLEAN]]  the two can reach each other
    fresh,    \* [Replica -> [Replica -> BOOLEAN]]  row seen within the timeout
    retired,  \* SUBSET Replica  members the operator removed
    cuts,     \* link cuts made so far
    lost,     \* [Replica -> SUBSET Event]  keys of tree[r] on a lost page
    losses    \* pages lost so far

net  == <<link, fresh, retired, cuts, losses>>
vars == <<hlc, minted, tree, applied, durable, wm, vv, lost, net>>
Live == Replicas \ retired

Readable(r)  == tree[r] \ lost[r]
Servable(r)  == lost[r] = {}

Minted == {e \in Event : e.seq =< minted[e.org]}

(***************************************************************************)
(* Keys order by (hlc, origin, seq), the MST's term order on event keys.   *)
(***************************************************************************)
KeyOf(e)  == <<hlc[e.org][e.seq], e.org, e.seq>>
WmKey(r)  == IF wm[r] = NoEvent THEN <<0, 0, 0>> ELSE KeyOf(wm[r])
Lex(a, b) ==
    \/ a[1] < b[1]
    \/ a[1] = b[1] /\ a[2] < b[2]
    \/ a[1] = b[1] /\ a[2] = b[2] /\ a[3] =< b[3]
Below(e, f)       == Lex(KeyOf(e), KeyOf(f))     \* key(e) =< key(f)
AtOrBelowWm(r, e) == Lex(KeyOf(e), WmKey(r))
MaxKey(S) == CHOOSE e \in S : \A f \in S : Below(f, e)


MaxSeqOf(S, o) ==
    LET seqs == {e.seq : e \in {x \in S : x.org = o}}
    IN IF seqs = {} THEN 0 ELSE CHOOSE m \in seqs : \A n \in seqs : n =< m

\* What get_frontier reports: the per-origin max of the applied set.
VV(S) == [o \in Origins |-> MaxSeqOf(S, o)]

\* The prefix hold (bondy_oplog_cell_apply, AaeCausalClosure.tla): a fold
\* materialises only the per-origin contiguous closure.
ContigClosure(S) == {e \in S : \A i \in 1..e.seq : Ev(e.org, i) \in S}

\* r's durable frontier when its applied set is `A`.
DurableOf(r, A) == IF AsyncApply THEN durable[r] ELSE VV(A)
Durable(r)      == DurableOf(r, applied[r])

(***************************************************************************)
(* The confirmation rule.                                                  *)
(***************************************************************************)
Peers(r) ==
    LET members == Replicas \ ({r} \cup retired)
    IN IF Witnesses = "fresh"
         THEN {p \in members : fresh[r][p]}
         ELSE members

\* With no peer, nothing is confirmed: the code's rule with clustering
\* enabled (member_vvs/2).
Witness(r) == IF Peers(r) = {} THEN {} ELSE Peers(r) \cup {r}

\* r's own witness is its durable frontier as it stands; the door reads it
\* before the round's fold (do_integrate_peer_root/2).
Confirmed(r, p, e) ==
    e.seq =< (IF p = r THEN Durable(r) ELSE vv[r][p])[e.org]

\* The frontier walk (compute_frontier_for/2) reads the keys of `T` in order
\* up to the first one some witness has not confirmed. Unless WalkLost, a walk
\* that meets a lost key on the way truncates nothing.
Stops(r, T) ==
    LET open == {h \in T \ lost[r] : \E q \in Witness(r) : ~Confirmed(r, q, h)}
    IN /\ ~WalkLost
       /\ \E l \in lost[r] : \A h \in open : Below(l, h)

\* The confirmed down-set of r's tree: local keys every readable local key
\* at or below which is confirmed by every witness. compute_frontier_for/2
\* returns its maximum (the predecessor of the first unconfirmed key).
Down(r) ==
    {e \in Readable(r) :
        \A f \in Readable(r) :
            Below(f, e) => \A p \in Witness(r) : Confirmed(r, p, f)}

TypeOK ==
    /\ hlc     \in [Origins -> [1..MaxSeq -> 0..MaxHlc]]
    /\ minted  \in [Origins -> 0..MaxSeq]
    /\ tree    \in [Replicas -> SUBSET Event]
    /\ applied \in [Replicas -> SUBSET Event]
    /\ durable \in [Replicas -> VVs]
    /\ wm      \in [Replicas -> Event \cup {NoEvent}]
    /\ vv      \in [Replicas -> [Replicas -> VVs]]
    /\ link    \in [Replicas -> [Replicas -> BOOLEAN]]
    /\ fresh   \in [Replicas -> [Replicas -> BOOLEAN]]
    /\ retired \in SUBSET Replicas
    /\ cuts    \in 0..MaxCuts
    /\ lost    \in [Replicas -> SUBSET Event]
    /\ losses  \in 0..MaxLost

Init ==
    /\ hlc     = [o \in Origins |-> [s \in 1..MaxSeq |-> 0]]
    /\ minted  = [o \in Origins |-> 0]
    /\ tree    = [r \in Replicas |-> {}]
    /\ applied = [r \in Replicas |-> {}]
    /\ durable = [r \in Replicas |-> ZeroVV]
    /\ wm      = [r \in Replicas |-> NoEvent]
    /\ vv      = [r \in Replicas |-> [p \in Replicas |-> ZeroVV]]
    /\ link    = [r \in Replicas |-> [p \in Replicas |-> TRUE]]
    /\ fresh   = [r \in Replicas |-> [p \in Replicas |-> p # r]]
    /\ retired = {}
    /\ cuts    = 0
    /\ lost    = [r \in Replicas |-> {}]
    /\ losses  = 0

(***************************************************************************)
(* Mint: the new key sorts above every key this replica has seen (the HLC  *)
(* is advanced past every merged key and past the watermark), which is    *)
(* what keeps a fresh local event above any future watermark; how far     *)
(* above is the clock's business (Skew). Local events are applied at mint *)
(* (the applier writes them before their MST install).                    *)
(***************************************************************************)
Mint(r) ==
    /\ r \in Live
    /\ minted[r] < MaxSeq
    /\ LET s    == minted[r] + 1
           e    == Ev(r, s)
           seen == {hlc[f.org][f.seq] : f \in tree[r] \cup applied[r]}
                     \cup {WmKey(r)[1]}
           maxH == CHOOSE m \in seen : \A n \in seen : n =< m
       IN \E h \in (maxH + 1)..(maxH + 1 + Skew) :
            /\ hlc'     = [hlc EXCEPT ![r][s] = h]
            /\ minted'  = [minted EXCEPT ![r] = s]
            /\ tree'    = [tree EXCEPT ![r] = @ \cup {e}]
            /\ applied' = [applied EXCEPT ![r] = @ \cup {e}]
    /\ UNCHANGED <<durable, wm, vv, lost, net>>

(***************************************************************************)
(* A complete round of r pulling from p. Every round records p's durable   *)
(* frontier as read before it against p, and r's as of its end against r; *)
(* both rows are freshened.                                                *)
(*                                                                         *)
(* Empty peer tree, or equal trees: no merge and no door.                  *)
(*                                                                         *)
(* Otherwise: merge, fold inline unless AsyncApply, and the watermark      *)
(* door: drop the applied key prefix at or below the watermark strictly    *)
(* below the first held (un-applied) key there, under "confirmed" only    *)
(* where every witness confirms it as recorded before this round.          *)
(*                                                                         *)
(* A peer with a lost page refuses the pull. On r, a lost key is neither   *)
(* folded nor judged by the door, and goes with the readable key the door  *)
(* truncates at.                                                           *)
(***************************************************************************)
Record(r, p, na) ==
    /\ vv'    = [vv EXCEPT ![r][p] = Durable(p), ![p][r] = DurableOf(r, na)]
    /\ fresh' = [fresh EXCEPT ![r][p] = TRUE, ![p][r] = TRUE]

Sync(r, p) ==
    /\ r # p
    /\ {r, p} \subseteq Live
    /\ link[r][p]
    /\ Servable(p)
    /\ UNCHANGED <<hlc, minted, durable, wm, link, retired, cuts, losses>>
    /\ IF tree[p] = {} \/ tree[p] = tree[r] THEN
         /\ Record(r, p, applied[r])
         /\ UNCHANGED <<tree, applied, lost>>
       ELSE
         \E hold \in IF FusedHold /\ ~AsyncApply THEN BOOLEAN ELSE {FALSE} :
         LET union   == tree[r] \cup tree[p]
             na      == IF AsyncApply \/ hold
                          THEN applied[r]
                          ELSE ContigClosure(applied[r] \cup (union \ lost[r]))
             held    == {e \in union \ lost[r] :
                           AtOrBelowWm(r, e) /\ e \notin na}
             byAll(e) == \A q \in Witness(r) : Confirmed(r, q, e)
             door(e) ==
                 \/ e \in lost[r]
                 \/ /\ DoorRule # "keep"
                    /\ AtOrBelowWm(r, e)
                    /\ e \in na
                    /\ \A h \in held : Below(e, h) /\ e # h
                    /\ DoorRule = "confirmed" => byAll(e)
             points  == {k \in union \ lost[r] :
                           \A f \in union : Below(f, k) => door(f)}
             dropped == IF Stops(r, union)
                          THEN {}
                          ELSE {e \in union : \E k \in points : Below(e, k)}
         IN
         /\ tree'    = [tree    EXCEPT ![r] = union \ dropped]
         /\ applied' = [applied EXCEPT ![r] = na]
         /\ lost'    = [lost    EXCEPT ![r] = @ \ dropped]
         /\ Record(r, p, na)

(***************************************************************************)
(* The applier folds what the rounds delivered, with the prefix hold; so   *)
(* does a later fused replay under FusedHold. Neither can read a lost key.  *)
(***************************************************************************)
Replay(r) ==
    /\ r \in Live
    /\ AsyncApply \/ FusedHold
    /\ LET na == ContigClosure(applied[r] \cup Readable(r))
       IN /\ na # applied[r]
          /\ applied' = [applied EXCEPT ![r] = na]
    /\ UNCHANGED <<hlc, minted, tree, durable, wm, vv, lost, net>>

\* The applier-backed instance checkpoints its applied frontier.
Checkpoint(r) ==
    /\ r \in Live
    /\ AsyncApply
    /\ durable[r] # VV(applied[r])
    /\ durable' = [durable EXCEPT ![r] = VV(applied[r])]
    /\ UNCHANGED <<hlc, minted, tree, applied, wm, vv, lost, net>>

(***************************************************************************)
(* One compaction cycle. Under "confirmed" and "keep": truncate the        *)
(* confirmed down-set, folding under AsyncApply what lies above the        *)
(* watermark, and advance the watermark only upward. Under "drop": with a  *)
(* frontier strictly above the watermark, truncate at or below it and      *)
(* advance the watermark; otherwise truncate at or below the watermark.    *)
(*                                                                         *)
(* With the cap, a truncation point never reaches the first key this       *)
(* replica has not applied, which makes the fold vacuous.                  *)
(***************************************************************************)
Unapplied(r) == {e \in Readable(r) : e \notin applied[r]}

\* The keys at or below `k` a truncation may reach: all of them, or under
\* the cap those strictly below the first un-applied key at or below `k`.
Cut(r, k) ==
    LET blocked == {h \in Unapplied(r) : Lex(KeyOf(h), k)}
    IN {e \in tree[r] :
          /\ Lex(KeyOf(e), k)
          /\ (CapAtUnapplied => \A h \in blocked : Below(e, h) /\ e # h)}

Truncate(r, cut, nwm) ==
    /\ cut # {}
    /\ tree'    = [tree EXCEPT ![r] = @ \ cut]
    /\ applied' = IF AsyncApply
                    THEN [applied EXCEPT ![r] =
                            @ \cup {e \in cut \ lost[r] : ~AtOrBelowWm(r, e)}]
                    ELSE applied
    /\ wm'      = [wm EXCEPT ![r] = nwm]
    /\ lost'    = [lost EXCEPT ![r] = @ \ cut]

Compact(r) ==
    /\ r \in Live
    /\ Witness(r) # {}
    /\ ~Stops(r, tree[r])
    /\ LET D == Down(r)
       IN IF DoorRule # "drop" THEN
            LET cut == IF D = {} THEN {} ELSE Cut(r, KeyOf(MaxKey(D)))
            IN Truncate(r, cut,
                        IF cut # {} /\ ~AtOrBelowWm(r, MaxKey(cut))
                          THEN MaxKey(cut) ELSE wm[r])
          ELSE IF D # {} /\ ~AtOrBelowWm(r, MaxKey(D)) THEN
            LET cut == Cut(r, KeyOf(MaxKey(D)))
            IN Truncate(r, cut, IF cut = {} THEN wm[r] ELSE MaxKey(cut))
          ELSE
            /\ Truncate(r, Cut(r, WmKey(r)), wm[r])
    /\ UNCHANGED <<hlc, minted, durable, vv, net>>

(***************************************************************************)
(* The network and the operator.                                           *)
(***************************************************************************)
CutLink(r, p) ==
    /\ r # p /\ link[r][p] /\ cuts < MaxCuts
    /\ link' = [link EXCEPT ![r][p] = FALSE, ![p][r] = FALSE]
    /\ cuts' = cuts + 1
    /\ UNCHANGED <<hlc, minted, tree, applied, durable, wm, vv, fresh, retired,
                   lost, losses>>

HealLink(r, p) ==
    /\ r # p /\ ~link[r][p]
    /\ link' = [link EXCEPT ![r][p] = TRUE, ![p][r] = TRUE]
    /\ UNCHANGED <<hlc, minted, tree, applied, durable, wm, vv, fresh, retired,
                   cuts, lost, losses>>

\* The recency filter's timeout passes without a completed round between
\* them. Only the "fresh" ablation reads `fresh`.
Expire(r, p) ==
    /\ Witnesses = "fresh"
    /\ r # p /\ fresh[r][p]
    /\ fresh' = [fresh EXCEPT ![r][p] = FALSE]
    /\ UNCHANGED <<hlc, minted, tree, applied, durable, wm, vv, link, retired,
                   cuts, lost, losses>>

Retire(p) ==
    /\ p \in Live /\ Cardinality(retired) < MaxRetire
    /\ retired' = retired \cup {p}
    /\ UNCHANGED <<hlc, minted, tree, applied, durable, wm, vv, link, fresh,
                   cuts, lost, losses>>

(***************************************************************************)
(* Lost pages and their recovery.                                          *)
(***************************************************************************)
Lose(r) ==
    /\ r \in Live /\ losses < MaxLost
    /\ \E e \in Readable(r) : lost' = [lost EXCEPT ![r] = @ \cup {e}]
    /\ losses' = losses + 1
    /\ UNCHANGED <<hlc, minted, tree, applied, durable, wm, vv, link, fresh,
                   retired, cuts>>

\* r is behind an unservable p: the catalogue re-bootstrap installs p's
\* projection, so r applies what p applied.
Rebootstrap(r, p) ==
    /\ r # p /\ {r, p} \subseteq Live /\ link[r][p]
    /\ ~Servable(p)
    /\ ~(applied[p] \subseteq applied[r])
    /\ applied' = [applied EXCEPT ![r] = @ \cup applied[p]]
    /\ UNCHANGED <<hlc, minted, tree, durable, wm, vv, lost, net>>

\* Every witness covers r's applied frontier: each member's recorded frontier
\* and r's own durable frontier (`rebuild_frontier/2` over `member_vvs/2`).
MembersCover(r) ==
    \A q \in Witness(r) : \A o \in Origins :
        (IF q = r THEN Durable(r) ELSE vv[r][q])[o] >= VV(applied[r])[o]

\* The cycle whose walk stops at a lost page cuts at the largest readable key,
\* or the watermark when that is higher or nothing is readable; with neither
\* it truncates nothing (`max_key/2` returns `empty`). With nothing blocked, the cut takes
\* the whole tree: the lost keys above the point sit on a dangling subtree
\* that the truncation drops. A biting cap keeps the keys from the first
\* blocked key up, lost ones included.
Heal(r) ==
    /\ r \in Live
    /\ Peers(r) # {}
    /\ Stops(r, tree[r])
    /\ HealGate # "off"
    /\ HealGate = "dominate" => MembersCover(r)
    /\ LET R     == Readable(r)
           top   == IF R = {} THEN wm[r]
                    ELSE IF wm[r] # NoEvent /\ Below(MaxKey(R), wm[r])
                         THEN wm[r] ELSE MaxKey(R)
           k     == IF top = NoEvent THEN <<0, 0, 0>> ELSE KeyOf(top)
           block == {h \in Unapplied(r) : Lex(KeyOf(h), k)}
           cut   == IF HealCap /\ block # {} THEN Cut(r, k) ELSE tree[r]
       IN /\ top # NoEvent
          /\ Truncate(r, cut, top)
    /\ UNCHANGED <<hlc, minted, durable, vv, net>>

Next ==
    \/ \E r \in Replicas : Mint(r)
    \/ \E r \in Replicas, p \in Replicas : Sync(r, p)
    \/ \E r \in Replicas : Replay(r)
    \/ \E r \in Replicas : Checkpoint(r)
    \/ \E r \in Replicas : Compact(r)
    \/ \E r \in Replicas, p \in Replicas : CutLink(r, p)
    \/ \E r \in Replicas, p \in Replicas : HealLink(r, p)
    \/ \E r \in Replicas, p \in Replicas : Expire(r, p)
    \/ \E p \in Replicas : Retire(p)
    \/ \E r \in Replicas : Lose(r)
    \/ \E r \in Replicas, p \in Replicas : Rebootstrap(r, p)
    \/ \E r \in Replicas : Heal(r)

Spec == Init /\ [][Next]_vars

\* Every scheduled activity keeps running; nothing else is assumed. A
\* compaction tick that finds nothing to truncate is a stutter, so weak
\* fairness on Compact forces a truncation only while one is CONTINUOUSLY
\* possible.
Fairness ==
    /\ \A r \in Replicas : WF_vars(Mint(r))
    /\ \A r \in Replicas, p \in Replicas : WF_vars(Sync(r, p))
    /\ \A r \in Replicas : WF_vars(Replay(r))
    /\ \A r \in Replicas : WF_vars(Checkpoint(r))
    /\ \A r \in Replicas : WF_vars(Compact(r))
    /\ \A r \in Replicas, p \in Replicas : WF_vars(Rebootstrap(r, p))
    /\ \A r \in Replicas : WF_vars(Heal(r))

FairSpec == Spec /\ Fairness

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* An event some replica has not applied is still shippable: it sits in a
\* tree somewhere. Its violation is the state the frontier-gap check and
\* the catalogue rebootstrap exist to repair.
\* A retired member's own events are excluded: retiring it gives them up.
NoLoss ==
    \A q \in Live : \A e \in {x \in Minted : x.org \in Live} :
        e \notin applied[q] => \E r \in Live : e \in tree[r]

\* No live replica is ever left needing a catalogue re-bootstrap: once a
\* live replica has truncated an event of a live origin, every live replica
\* has applied it or still holds it to apply. Stronger than NoLoss, which
\* only asks that some tree still holds it.
NoGap ==
    \A p, q \in Live : \A e \in {x \in Minted : x.org \in Live} :
        (e \in applied[p] /\ e \notin tree[p])
            => (e \in applied[q] \/ e \in tree[q])

\* With lost pages, the projection is a copy too (Rebootstrap reads it), so
\* NoLoss and NoGap, which count only trees, give way to these two.
\* No event leaves the system: some live replica has applied it or holds it
\* readable.
NoErase ==
    \A e \in {x \in Minted : x.org \in Live} :
        \E r \in Live : e \in applied[r] \/ e \in Readable(r)

\* A truncation of an event the replica applied leaves every live member
\* holding or having applied it, so none needs a re-bootstrap for it.
NoStrand ==
    [][\A r \in Live : \A e \in {x \in Minted : x.org \in Live} :
         (e \in tree[r] /\ e \notin tree'[r] /\ e \in applied[r])
            => \A q \in Live : e \in tree'[q] \/ e \in applied'[q]]_vars

\* The hypothesis the VV witness rests on (and Dot_Exactness needs).
PrefixClosed ==
    \A r \in Replicas : \A o \in Origins : \A j \in 1..MaxSeq :
        Ev(o, j) \in applied[r] => \A i \in 1..j : Ev(o, i) \in applied[r]

\* Truncation never discards a readable event this replica has not applied.
NoDrop ==
    [][\A r \in Replicas : \A e \in Minted :
         (e \in Readable(r) /\ e \notin tree'[r]) => e \in applied'[r]]_vars

\* The lemma NoGap rests on: a witness that confirms an event still holds it
\* in its tree or has applied it.
ConfirmedHeld ==
    \A r \in Live : \A q \in Witness(r) \cap Live : \A e \in Minted :
        Confirmed(r, q, e) => (e \in tree[q] \/ e \in applied[q])

\* A reachability control, expected to be violated: a truncation drops an
\* event this replica has not applied. Only Heal can, by dropping a lost one.
DropsOnlyApplied ==
    [][\A r \in Replicas : \A e \in Minted :
         (e \in tree[r] /\ e \notin tree'[r]) => e \in applied'[r]]_vars

\* Bounded exploration: no state deeper than MaxDepth steps.
WithinDepth == TLCGet("level") < MaxDepth

\* Once minting is exhausted every tree empties and every replica has
\* applied everything.
Converged ==
    /\ \A o \in Origins : minted[o] = MaxSeq
    /\ \A r \in Replicas : tree[r] = {}
    /\ \A r \in Replicas : \A e \in Minted : e \in applied[r]

Convergence == <>[]Converged

=============================================================================
