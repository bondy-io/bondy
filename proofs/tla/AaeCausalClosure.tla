---------------------------- MODULE AaeCausalClosure ----------------------------
(***************************************************************************)
(* THIS WAS BUILT BY CLAUDE OPUS and it is not verified.                   *)
(*                                                                         *)
(* Does bondy_db's anti-entropy layer deliver a per-origin PREFIX-CLOSED   *)
(* set of events to each replica?                                          *)
(*                                                                         *)
(* Why it matters. Two things in the Isabelle development assume it:       *)
(*                                                                         *)
(*   - Dot_Exactness.compact_test_exact needs per-origin prefix closure    *)
(*     WITHIN a cell, or the compact test Ctx[O] >= S reports a skipped    *)
(*     dot as observed.                                                    *)
(*   - bondy_oplog_responder.erl's get_frontier calls the applied VV a     *)
(*     convergence oracle "(causal delivery makes a per-origin max Seq     *)
(*     identify the applied prefix)". A max identifies a prefix only if    *)
(*     the applied set has no holes.                                       *)
(*                                                                         *)
(* What the code does, established by reading it:                          *)
(*                                                                         *)
(*   - Replication is PULL-ONLY (bondy_oplog_sync_session.erl:48). The     *)
(*     public append_remote/2 has no production sender, so whole-root      *)
(*     integrate is the only remote delivery path.                         *)
(*   - A sync round pulls pages in bounded batches, but                    *)
(*     integrate_peer_root runs ONLY when missing_set is empty             *)
(*     (pull_until_complete). An incomplete round transfers pages and      *)
(*     delivers NOTHING: no items folded, no root installed. It is         *)
(*     therefore a stutter step here, which is why no action models it --  *)
(*     and it is the answer to "can a budget-capped round deliver a        *)
(*     non-closed set?". It cannot: it delivers nothing.                   *)
(*   - Compaction truncates the MST below a frontier key. Keys order by    *)
(*     (hlc, origin, seq) and HLCs are per-origin monotone, so truncation  *)
(*     removes a per-origin PREFIX. Two flavours can truncate data a peer  *)
(*     never received: mst_retention truncates "by local policy with no    *)
(*     confirmation at all", and the peer-confirmed frontier is            *)
(*     RECENCY-FILTERED, dropping a replica silent past peer_timeout_ms    *)
(*     (bondy_oplog_sync_session.erl:145-160).                             *)
(*   - The remedy is a frontier-GAP check on complete rounds: if the       *)
(*     peer's pre-round frontier is still ahead of ours afterwards, fail   *)
(*     with {frontier_gap, Origins} and flag a catalogue rebootstrap.      *)
(*                                                                         *)
(* The model deliberately keeps `claim` (the reported applied-frontier VV, *)
(* which adoption can raise) separate from `applied` (ground truth), so    *)
(* over-claiming is expressible and therefore checkable.                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Replicas,          \* set of replica ids, also used as origin ids
    MaxSeq,            \* how many events each origin may mint
    GapCheckEnabled,   \* TRUE models maybe_frontier_gap/5; FALSE is the differential
    GatedCompaction,   \* TRUE = truncate only what every replica applied
                       \* FALSE = mst_retention / recency-filtered frontier
    PrefixHold         \* TRUE models db.aae.prefix_hold (the increment-2 fix):
                       \* a sync applies only the per-origin CONTIGUOUS closure
                       \* of local-applied + peer-tree; the held remainder stays
                       \* in the (fully merged) tree and out of the frontier

Origins == Replicas

Event == [org : Origins, seq : 1..MaxSeq]

Ev(o, s) == [org |-> o, seq |-> s]

Max2(a, b) == IF a > b THEN a ELSE b

\* The per-origin contiguous-from-1 closure of an event set: keep an event
\* iff every earlier seq of its origin is also in the set. This is what the
\* prefix-hold fold materialises (bondy_oplog_cell_apply:partition_contiguous
\* keeps seqs at-or-below the applied VV plus the contiguous run above it;
\* over applied \cup tree that composes to exactly this closure, because
\* applied is inductively prefix-closed under the hold).
ContigClosure(S) == {e \in S : \A i \in 1..e.seq : Ev(e.org, i) \in S}

\* Highest seq of origin o present in S (0 if none). NOT a claim that
\* everything below it is present -- that is exactly what we are checking.
MaxSeqOf(S, o) ==
    LET seqs == {e.seq : e \in {x \in S : x.org = o}}
    IN IF seqs = {} THEN 0
       ELSE CHOOSE m \in seqs : \A n \in seqs : n =< m

VARIABLES
    applied,   \* [Replica -> SUBSET Event]  events actually folded here
    tree,      \* [Replica -> SUBSET Event]  items reachable from the local MST root
    claim,     \* [Replica -> [Origin -> Nat]] what get_frontier reports
    minted,    \* [Origin -> Nat]
    gapFlag,   \* [Replica -> BOOLEAN] catalogue rebootstrap pending
    booted     \* [Replica -> BOOLEAN] has completed catalogue bootstrap

vars == <<applied, tree, claim, minted, gapFlag, booted>>

TypeOK ==
    /\ applied \in [Replicas -> SUBSET Event]
    /\ tree    \in [Replicas -> SUBSET Event]
    /\ claim   \in [Replicas -> [Origins -> 0..MaxSeq]]
    /\ minted  \in [Origins -> 0..MaxSeq]
    /\ gapFlag \in [Replicas -> BOOLEAN]
    /\ booted  \in [Replicas -> BOOLEAN]

\* Seed is booted by construction (it IS the cluster); everyone else must
\* bootstrap before it may page-sync. This models the real join path:
\* a fresh node takes a catalogue bootstrap, not a plain AAE round.
Seed == CHOOSE r \in Replicas : TRUE

Init ==
    /\ applied = [r \in Replicas |-> {}]
    /\ tree    = [r \in Replicas |-> {}]
    /\ claim   = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ minted  = [o \in Origins |-> 0]
    /\ gapFlag = [r \in Replicas |-> FALSE]
    /\ booted  = [r \in Replicas |-> r = Seed]

(***************************************************************************)
(* Catalogue bootstrap on join: install the peer's snapshot AND its        *)
(* frontier (finalize_catalogue_bootstrap/4 merges the peer frontier).     *)
(***************************************************************************)
Bootstrap(r) ==
    /\ ~booted[r]
    /\ \E p \in Replicas \ {r} :
         /\ booted[p]
         /\ applied' = [applied EXCEPT ![r] = applied[p]]
         /\ tree'    = [tree    EXCEPT ![r] = tree[p]]
         /\ claim'   = [claim   EXCEPT ![r] = claim[p]]
    /\ booted' = [booted EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<minted, gapFlag>>

(***************************************************************************)
(* A replica mints its next event: applied, in its tree, and reflected in  *)
(* its own frontier entry.                                                 *)
(***************************************************************************)
Mint(r) ==
    /\ minted[r] < MaxSeq
    /\ ~gapFlag[r]
    /\ booted[r]
    /\ LET e == Ev(r, minted[r] + 1) IN
         /\ applied' = [applied EXCEPT ![r] = @ \cup {e}]
         /\ tree'    = [tree    EXCEPT ![r] = @ \cup {e}]
         /\ claim'   = [claim   EXCEPT ![r][r] = minted[r] + 1]
    /\ minted' = [minted EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<gapFlag, booted>>

(***************************************************************************)
(* A COMPLETE sync round: r holds every page of p's root, so it integrates *)
(* p's whole item set atomically. Then the frontier-gap check, then        *)
(* adoption. Both require the complete round modelled here.                *)
(***************************************************************************)
SyncComplete(r, p) ==
    /\ r # p
    /\ ~gapFlag[r]
    /\ booted[r]
    /\ booted[p]
    /\ LET union      == applied[r] \cup tree[p]
           newApplied == IF PrefixHold THEN ContigClosure(union) ELSE union
           base == [o \in Origins |-> Max2(claim[r][o], MaxSeqOf(newApplied, o))]
           gap  == \E o \in Origins : claim[p][o] > base[o]
       IN /\ applied' = [applied EXCEPT ![r] = newApplied]
          /\ tree'    = [tree    EXCEPT ![r] = @ \cup tree[p]]
          /\ IF GapCheckEnabled /\ gap
               THEN /\ claim'   = [claim   EXCEPT ![r] = base]
                    /\ gapFlag' = [gapFlag EXCEPT ![r] = TRUE]
               ELSE /\ claim'   = [claim EXCEPT ![r] =
                                     [o \in Origins |-> Max2(base[o], claim[p][o])]]
                    /\ UNCHANGED gapFlag
    /\ UNCHANGED <<minted, booted>>

(***************************************************************************)
(* Compaction truncates a per-origin prefix out of the local tree. The     *)
(* events stay APPLIED here; they simply become unshippable to peers.      *)
(***************************************************************************)
Compact(r) ==
    /\ \E cut \in [Origins -> 0..MaxSeq] :
         /\ GatedCompaction =>
              (\A o \in Origins : \A j \in 1..cut[o] :
                 \A q \in Replicas : Ev(o, j) \in applied[q])
         /\ tree' = [tree EXCEPT ![r] = {e \in @ : e.seq > cut[e.org]}]
    /\ UNCHANGED <<applied, claim, minted, gapFlag, booted>>

(***************************************************************************)
(* Catalogue rebootstrap: clobber and re-derive from a peer. Supplies BOTH *)
(* the data and the frontier, per maybe_frontier_gap/5's comment.          *)
(***************************************************************************)
Rebootstrap(r) ==
    /\ gapFlag[r]
    /\ \E p \in Replicas \ {r} :
         \* The catalogue install supplies the peer's data and frontier;
         \* the replica's OWN events survive in its local WAL and are
         \* re-delivered by the drain/rederive after any clobber, so the
         \* model must retain them — dropping them manufactured a spurious
         \* own-origin non-contiguity (a later Mint atop a forgotten own
         \* prefix) that no real replica exhibits.
         /\ applied' = [applied EXCEPT
                          ![r] = applied[p] \cup {e \in applied[r] : e.org = r}]
         /\ tree'    = [tree    EXCEPT
                          ![r] = tree[p] \cup {e \in tree[r] : e.org = r}]
         /\ claim'   = [claim   EXCEPT
                          ![r] = [o \in Origins |->
                                    IF o = r THEN Max2(claim[p][o], claim[r][o])
                                    ELSE claim[p][o]]]
    /\ gapFlag' = [gapFlag EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<minted, booted>>

Next ==
    \/ \E r \in Replicas : Bootstrap(r)
    \/ \E r \in Replicas : Mint(r)
    \/ \E r \in Replicas, p \in Replicas : SyncComplete(r, p)
    \/ \E r \in Replicas : Compact(r)
    \/ \E r \in Replicas : Rebootstrap(r)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* The hypothesis Dot_Exactness.compact_test_exact needs, and the one that
\* makes a per-origin max identify the applied prefix.
PrefixClosed ==
    \A r \in Replicas : \A o \in Origins : \A j \in 1..MaxSeq :
        (Ev(o, j) \in applied[r]) => (\A i \in 1..j : Ev(o, i) \in applied[r])

\* The convergence oracle never reports more than it can back with data.
NoOverClaim ==
    \A r \in Replicas : \A o \in Origins : \A j \in 1..MaxSeq :
        (j =< claim[r][o]) => (Ev(o, j) \in applied[r])

=============================================================================
