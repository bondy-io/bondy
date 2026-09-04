------------------------- MODULE ConfirmedCompaction -------------------------
(***************************************************************************)
(* Compaction by peer confirmation: what a completed anti-entropy round    *)
(* lets a replica truncate, and whether that knowledge survives the next   *)
(* round.                                                                  *)
(*                                                                         *)
(* The mechanism as shipped, established by reading the code               *)
(* (bondy_oplog_sync_session, bondy_oplog_peer_state,                      *)
(* bondy_oplog_compaction, bondy_oplog_instance):                          *)
(*                                                                         *)
(*   - A round is a PULL: r asks p for the pages it lacks under p's        *)
(*     advertised root, merges the whole root into its own tree, then       *)
(*     RECORDS that root against p (peer_state row {p, instance}) and      *)
(*     CONFIRMS it to p, which records the same root against r. Each side  *)
(*     also records the other's applied-frontier VV as read before the     *)
(*     round (peer_state `frontier`; today it feeds only the unservable-   *)
(*     root self-heal).                                                    *)
(*   - Compaction truncates the largest local key K such that every local  *)
(*     key =< K is present in EVERY recorded peer ROOT                     *)
(*     (compute_frontier_for/2). A row whose root is undefined constrains  *)
(*     nothing; a recorded root whose pages the local page GC has swept    *)
(*     certifies nothing (peer_first_hole/2's catch clause).               *)
(*   - After a merge the WATERMARK DOOR re-truncates everything at or      *)
(*     below the local watermark that is already applied, holding a never- *)
(*     applied event and the keys above it (watermark_door/3). On the ETS   *)
(*     backend every truncation runs the page GC, which sweeps each page    *)
(*     unreachable from the current root — including the pages that make a *)
(*     recorded peer root readable.                                        *)
(*                                                                         *)
(* The defect this model pins (Rule = "root"): a root is a statement about *)
(* p's TREE, and p's tree loses exactly the events p has compacted. Once p *)
(* truncates a prefix, r's next round records a root without it, and r can *)
(* no longer certify that p holds a prefix p in fact APPLIED — r stalls    *)
(* until p's own next pull confirms r's root back, a window p's next pull  *)
(* closes again. Every round in between re-ships the prefix. Convergence   *)
(* is left to the scheduler's phase; on the ETS backend the page GC makes  *)
(* the stall the common case whenever the trees differ.                    *)
(*                                                                         *)
(* The rule under proof (Rule = "rootvv"): r certifies that p holds e if e *)
(* is in p's recorded root OR e.seq =< p's recorded applied VV at e's      *)
(* origin. The VV is the witness that survives p's compaction; under the   *)
(* shipped prefix hold it is a contiguous bound for remote origins, and    *)
(* p's own origin is contiguous by minting. Rows with a recorded VV        *)
(* constrain even when rootless.                                           *)
(*                                                                         *)
(* Scope. All replicas are members from the start and have completed one  *)
(* (empty) round with every peer before any write (rows exist). No         *)
(* recency filter, no mst_retention, no catalogue rebootstrap: the claim   *)
(* is that with every member live, confirmed compaction never needs any   *)
(* of them. Keys carry an explicit HLC so truncation is by KEY ORDER, as   *)
(* shipped, not per-origin. Sessions are atomic.                           *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Replicas,    \* a set of naturals (also the origin ids); 0 is reserved
    MaxSeq,      \* events each origin may mint
    Skew,        \* how far past what it has seen a replica's clock may run
                 \* at a mint: 0 is a global clock (skew only from a replica
                 \* not having seen a peer's events yet), each extra unit
                 \* admits a mint that sorts above that many unseen events
    Rule,        \* "root" (shipped) | "rootvv" (root OR applied-VV witness)
    AsyncApply,  \* TRUE: remote events are folded by a separate Replay step
                 \* (the applier-backed durable instance); FALSE: folded
                 \* inline in the round (the fused instance)
    Sweep,       \* "all": every truncation runs the page GC and a recorded
                 \* root differing from the current tree becomes unreadable
                 \* (ETS backend); "none": no GC between rounds (the pack
                 \* backend inside its hourly collection interval)
    CapAtUnapplied \* TRUE: a truncation point is capped strictly below the
                 \* first local key this replica has not applied — the
                 \* watermark door's hold, applied at every truncation site.
                 \* FALSE: as shipped, the compaction sites truncate at the
                 \* frontier or the watermark regardless.

ASSUME Replicas \subseteq Nat /\ 0 \notin Replicas
ASSUME Skew \in Nat
ASSUME Rule \in {"root", "rootvv"}
ASSUME Sweep \in {"all", "none"}
ASSUME CapAtUnapplied \in BOOLEAN

Origins == Replicas
Event   == [org : Origins, seq : 1..MaxSeq]
\* Every HLC a mint can reach: each mint adds at most Skew + 1.
MaxHlc  == Cardinality(Replicas) * MaxSeq * (Skew + 1)
Ev(o, s) == [org |-> o, seq |-> s]
NoEvent == [org |-> 0, seq |-> 0]

VARIABLES
    hlc,      \* [Origin -> [1..MaxSeq -> Nat]]  0 = not minted yet
    minted,   \* [Origin -> 0..MaxSeq]
    tree,     \* [Replica -> SUBSET Event]  items under the local root
    applied,  \* [Replica -> SUBSET Event]  events folded into the projection
    wm,       \* [Replica -> Event \cup {NoEvent}]  compaction watermark key
    root,     \* [Replica -> [Replica -> SUBSET Event]]  recorded peer root
    hasRoot,  \* [Replica -> [Replica -> BOOLEAN]]  row carries a root
    usable,   \* [Replica -> [Replica -> BOOLEAN]]  the root's pages are readable
    row,      \* [Replica -> [Replica -> BOOLEAN]]  peer_state row exists
    vv        \* [Replica -> [Replica -> [Origin -> 0..MaxSeq]]]  recorded VV

vars == <<hlc, minted, tree, applied, wm, root, hasRoot, usable, row, vv>>

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

(***************************************************************************)
(* The confirmation rule.                                                  *)
(***************************************************************************)
Confirmed(r, p, e) ==
    \/ hasRoot[r][p] /\ usable[r][p] /\ e \in root[r][p]
    \/ Rule = "rootvv" /\ e.seq =< vv[r][p][e.org]

\* The peers whose knowledge bounds r's compaction. Shipped: rows with a
\* root (bondy_oplog_compaction:compact/1 drops rootless rows). Under the
\* VV rule every row constrains: a rootless row with a zero VV holds
\* compaction until a round against that peer records what it applied.
Peers(r) ==
    IF Rule = "root"
        THEN {p \in Replicas \ {r} : hasRoot[r][p]}
        ELSE {p \in Replicas \ {r} : row[r][p]}

\* The confirmed down-set of r's tree: local keys every local key at or
\* below which is confirmed by every peer. compute_frontier_for/2 returns
\* its maximum (the predecessor of the global first hole).
Down(r) ==
    {e \in tree[r] :
        \A f \in tree[r] : Below(f, e) => \A p \in Peers(r) : Confirmed(r, p, f)}

(***************************************************************************)
(* Page GC after a truncation at r that left `nt`: on the ETS backend the  *)
(* pages of a recorded root that differ from the current tree are          *)
(* unreachable and swept, and compute_frontier_for/2 needs exactly those   *)
(* pages (diff_to_list descends only into differing subtrees).             *)
(***************************************************************************)
SweptAt(r, nt) ==
    [q \in Replicas |->
        usable[r][q] /\ (Sweep = "none" \/ root[r][q] = nt)]

TypeOK ==
    /\ hlc     \in [Origins -> [1..MaxSeq -> 0..MaxHlc]]
    /\ minted  \in [Origins -> 0..MaxSeq]
    /\ tree    \in [Replicas -> SUBSET Event]
    /\ applied \in [Replicas -> SUBSET Event]
    /\ wm      \in [Replicas -> Event \cup {NoEvent}]
    /\ root    \in [Replicas -> [Replicas -> SUBSET Event]]
    /\ hasRoot \in [Replicas -> [Replicas -> BOOLEAN]]
    /\ usable  \in [Replicas -> [Replicas -> BOOLEAN]]
    /\ row     \in [Replicas -> [Replicas -> BOOLEAN]]
    /\ vv      \in [Replicas -> [Replicas -> [Origins -> 0..MaxSeq]]]

Init ==
    /\ hlc     = [o \in Origins |-> [s \in 1..MaxSeq |-> 0]]
    /\ minted  = [o \in Origins |-> 0]
    /\ tree    = [r \in Replicas |-> {}]
    /\ applied = [r \in Replicas |-> {}]
    /\ wm      = [r \in Replicas |-> NoEvent]
    /\ root    = [r \in Replicas |-> [p \in Replicas |-> {}]]
    /\ hasRoot = [r \in Replicas |-> [p \in Replicas |-> FALSE]]
    /\ usable  = [r \in Replicas |-> [p \in Replicas |-> FALSE]]
    /\ row     = [r \in Replicas |-> [p \in Replicas |-> p # r]]
    /\ vv      = [r \in Replicas |-> [p \in Replicas |-> [o \in Origins |-> 0]]]

(***************************************************************************)
(* Mint: the new key sorts above every key this replica has seen (the HLC  *)
(* is advanced past every merged key and past the watermark), which is    *)
(* what keeps a fresh local event above any future watermark; how far     *)
(* above is the clock's business (Skew). Local events are applied at mint *)
(* (the applier writes them before their MST install).                    *)
(***************************************************************************)
Mint(r) ==
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
    /\ UNCHANGED <<wm, root, hasRoot, usable, row, vv>>

(***************************************************************************)
(* A complete round of r pulling from p.                                   *)
(*                                                                         *)
(* Empty peer tree: nothing is pulled and no root is confirmed; the row is *)
(* freshened and (under both rules) the peer's VV recorded — the shipped   *)
(* code stores it, only the VV rule reads it. A previously recorded root   *)
(* is preserved (record_sync_complete/5).                                  *)
(*                                                                         *)
(* Equal trees: no merge, no door, no GC; record and confirm.              *)
(*                                                                         *)
(* Otherwise: merge, watermark door (fold inline unless AsyncApply; drop   *)
(* the applied prefix at or below the watermark strictly below the first   *)
(* held key), page GC when a watermark exists, record p's root and VV,     *)
(* confirm p's root back to p.                                             *)
(***************************************************************************)
Sync(r, p) ==
    /\ r # p
    /\ IF tree[p] = {} THEN
         /\ vv' = [vv EXCEPT ![r][p] = VV(applied[p])]
         /\ UNCHANGED <<hlc, minted, tree, applied, wm, root, hasRoot,
                        usable, row>>
       ELSE IF tree[p] = tree[r] THEN
         /\ root'    = [root    EXCEPT ![r][p] = tree[p], ![p][r] = tree[p]]
         /\ hasRoot' = [hasRoot EXCEPT ![r][p] = TRUE, ![p][r] = TRUE]
         /\ usable'  = [usable  EXCEPT ![r][p] = TRUE, ![p][r] = TRUE]
         /\ vv'      = [vv EXCEPT ![r][p] = VV(applied[p])]
         /\ UNCHANGED <<hlc, minted, tree, applied, wm, row>>
       ELSE
         LET union   == tree[r] \cup tree[p]
             na      == IF AsyncApply
                          THEN applied[r]
                          ELSE ContigClosure(applied[r] \cup union)
             held    == {e \in union : AtOrBelowWm(r, e) /\ e \notin na}
             dropped == {e \in union :
                           /\ AtOrBelowWm(r, e)
                           /\ e \in na
                           /\ \A h \in held : Below(e, h) /\ e # h}
             nt      == union \ dropped
             gcRan   == wm[r] # NoEvent /\ Sweep = "all"
         IN
         /\ tree'    = [tree    EXCEPT ![r] = nt]
         /\ applied' = [applied EXCEPT ![r] = na]
         /\ root'    = [root    EXCEPT ![r][p] = tree[p], ![p][r] = tree[p]]
         /\ hasRoot' = [hasRoot EXCEPT ![r][p] = TRUE, ![p][r] = TRUE]
         /\ usable'  = [usable  EXCEPT
                          ![r] = [q \in Replicas |->
                                    IF q = p
                                      THEN ~gcRan \/ tree[p] = nt
                                      ELSE usable[r][q]
                                             /\ (~gcRan \/ root[r][q] = nt)],
                          ![p][r] = TRUE]
         /\ vv'      = [vv EXCEPT ![r][p] = VV(applied[p])]
         /\ UNCHANGED <<hlc, minted, wm, row>>

(***************************************************************************)
(* The applier folds what the rounds delivered, with the prefix hold.      *)
(***************************************************************************)
Replay(r) ==
    /\ AsyncApply
    /\ LET na == ContigClosure(applied[r] \cup tree[r])
       IN /\ na # applied[r]
          /\ applied' = [applied EXCEPT ![r] = na]
    /\ UNCHANGED <<hlc, minted, tree, wm, root, hasRoot, usable, row, vv>>

(***************************************************************************)
(* One compaction cycle. With a frontier strictly above the watermark:     *)
(* fold the remote events in (watermark, frontier] (the async catch-up,    *)
(* non-holding — only under AsyncApply; the fused instance has nothing     *)
(* pending), truncate at or below the frontier, advance the watermark.     *)
(* Otherwise the watermark catch-up: truncate what still sits at or below  *)
(* the existing watermark, without advancing it.                           *)
(*                                                                         *)
(* As shipped (CapAtUnapplied = FALSE) neither site checks for a held      *)
(* (never-applied) event: the catch-up range excludes everything at or     *)
(* below the watermark, so an event the door held there is dropped un-     *)
(* folded. With the cap, a truncation point never reaches the first key    *)
(* this replica has not applied; under AsyncApply that also makes the      *)
(* catch-up fold vacuous — there is nothing un-applied below the point.    *)
(***************************************************************************)
Unapplied(r) == {e \in tree[r] : e \notin applied[r]}

\* The largest key at or below `k` a truncation may reach: `k` itself, or
\* under the cap the predecessor of the first un-applied key at or below it.
Cut(r, k) ==
    LET blocked == {h \in Unapplied(r) : Lex(KeyOf(h), k)}
    IN {e \in tree[r] :
          /\ Lex(KeyOf(e), k)
          /\ (CapAtUnapplied => \A h \in blocked : Below(e, h) /\ e # h)}

Compact(r) ==
    /\ Peers(r) # {}
    /\ LET D == Down(r)
       IN IF D # {} /\ ~AtOrBelowWm(r, MaxKey(D)) THEN
            LET F   == MaxKey(D)
                cut == Cut(r, KeyOf(F))
                nt  == tree[r] \ cut
                fld == {e \in cut : ~AtOrBelowWm(r, e)}
                nwm == IF cut = {} THEN wm[r] ELSE MaxKey(cut)
            IN /\ cut # {}
               /\ tree'    = [tree EXCEPT ![r] = nt]
               /\ applied' = IF AsyncApply
                               THEN [applied EXCEPT ![r] = @ \cup fld]
                               ELSE applied
               /\ wm'      = [wm EXCEPT ![r] = nwm]
               /\ usable'  = [usable EXCEPT ![r] = SweptAt(r, nt)]
          ELSE
            LET cut == Cut(r, WmKey(r))
                nt  == tree[r] \ cut
            IN /\ cut # {}
               /\ tree'   = [tree EXCEPT ![r] = nt]
               /\ usable' = [usable EXCEPT ![r] = SweptAt(r, nt)]
               /\ UNCHANGED <<applied, wm>>
    /\ UNCHANGED <<hlc, minted, root, hasRoot, row, vv>>

Next ==
    \/ \E r \in Replicas : Mint(r)
    \/ \E r \in Replicas, p \in Replicas : Sync(r, p)
    \/ \E r \in Replicas : Replay(r)
    \/ \E r \in Replicas : Compact(r)

Spec == Init /\ [][Next]_vars

\* Every scheduled activity keeps running; nothing else is assumed. A
\* compaction tick that finds nothing to truncate is a stutter, so weak
\* fairness on Compact forces a truncation only while one is CONTINUOUSLY
\* possible — the difference between the two rules.
Fairness ==
    /\ \A r \in Replicas : WF_vars(Mint(r))
    /\ \A r \in Replicas, p \in Replicas : WF_vars(Sync(r, p))
    /\ \A r \in Replicas : WF_vars(Replay(r))
    /\ \A r \in Replicas : WF_vars(Compact(r))

FairSpec == Spec /\ Fairness

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* An event some replica has not applied is still shippable: it sits in a
\* tree somewhere. Its violation is the state the frontier-gap check and
\* the catalogue rebootstrap exist to repair.
NoLoss ==
    \A q \in Replicas : \A e \in Minted :
        e \notin applied[q] => \E r \in Replicas : e \in tree[r]

\* The hypothesis the VV witness rests on (and Dot_Exactness needs).
PrefixClosed ==
    \A r \in Replicas : \A o \in Origins : \A j \in 1..MaxSeq :
        Ev(o, j) \in applied[r] => \A i \in 1..j : Ev(o, i) \in applied[r]

\* Nothing at or below a watermark is ever held un-applied. Establishes,
\* for this scope, that the truncation sites' missing never-applied guard
\* has nothing to guard (a hold needs a recency-filtered or retention
\* truncation upstream, both out of scope here).
NoHeld ==
    \A r \in Replicas : \A e \in tree[r] :
        AtOrBelowWm(r, e) => e \in applied[r]

\* Truncation never discards an event this replica has not applied.
NoDrop ==
    [][\A r \in Replicas : \A e \in Minted :
         (e \in tree[r] /\ e \notin tree'[r]) => e \in applied'[r]]_vars

\* THE DIFFERENTIAL. A completed round against p certifies everything p had
\* applied before it. Under the shipped rule a round records p's TREE, and a
\* peer that compacted a prefix it applied leaves r unable to certify it.
RoundConfirmsApplied ==
    [][\A r \in Replicas : \A p \in Replicas \ {r} : \A e \in Minted :
         (Sync(r, p) /\ e \in applied[p] /\ e \in tree'[r])
            => Confirmed(r, p, e)']_vars

\* Once minting is exhausted every tree empties and every replica has
\* applied everything.
Converged ==
    /\ \A o \in Origins : minted[o] = MaxSeq
    /\ \A r \in Replicas : tree[r] = {}
    /\ \A r \in Replicas : \A e \in Minted : e \in applied[r]

Convergence == <>[]Converged


=============================================================================
