------------------------------ MODULE FrontierPending ------------------------------
(***************************************************************************)
(* THIS WAS BUILT BY CLAUDE OPUS and it is not verified.                   *)
(*                                                                         *)
(* Can the applied frontier be maintained correctly by ONE INTEGER per     *)
(* origin, given that it is maintained INCREMENTALLY across batches whose  *)
(* boundaries nobody chooses?                                              *)
(*                                                                         *)
(* `MuxBucketSkip.tla` asked which candidate fix closes the bucket-skip    *)
(* over-claim, and selected the per-origin contiguous prefix bound. What   *)
(* it did not model is that the bound is computed once per BATCH, from     *)
(* that batch's contents, and joined into a stored integer -- so a fact    *)
(* established by one batch (`seq 2 folded`) is representable only if the  *)
(* integer can hold it. It cannot, while seq 1 is missing.                 *)
(*                                                                         *)
(* The shipped code is `bondy_oplog_cell_apply:claim/2` (`MaxCap` below):  *)
(* the highest materialised seq strictly below the lowest seq THIS BATCH   *)
(* observed failing, max-merged by `bondy_oplog_registry:merge_frontier/2`.*)
(* Its docstring states the limit; this module measures it, and measures   *)
(* the two candidates against the same interleavings:                      *)
(*                                                                         *)
(*   MaxCap   -- shipped. Sound only when every absent seq below the claim *)
(*               is visible to the same call as a failure.                 *)
(*   Contig   -- the prefix bound alone: walk up from the stored integer   *)
(*               through THIS batch's materialised seqs. Sound always.     *)
(*   Pending  -- the prefix bound plus the applied seqs above it, which is *)
(*               `_design/applied_frontier.md` increment 9.                *)
(*                                                                         *)
(* Read with `proofs/isabelle/Frontier_Pending.thy`, which discharges the  *)
(* UNIVERSAL statement TLC cannot: no single-integer writer whatever its   *)
(* arithmetic is both sound and eventually complete                        *)
(* (`no_scalar_writer_sound_and_complete`). This module checks the three   *)
(* concrete rules under concurrency, restarts and the compaction door,     *)
(* which the theory does not model.                                        *)
(*                                                                         *)
(* Modelled, from reading the code:                                        *)
(*                                                                         *)
(*   - RECEIPT IS NOT APPLICATION. `oplog` is the MST -- what              *)
(*     `install_event/5` recorded. `applied` is the projection's reach.    *)
(*     `bondy_oplog_instance:deliver_remote/1` folds AFTER the tree        *)
(*     advance, through a best-effort cast, so the two differ.             *)
(*                                                                         *)
(*   - BATCH BOUNDARIES ARE NOT CHOSEN. `ApplyBatch` takes any non-empty   *)
(*     subset of what has been drained. `WholeBatchOnly` restricts it to   *)
(*     the whole inbox -- and does NOT save `MaxCap`, because arrival      *)
(*     timing splits batches anyway.                                       *)
(*                                                                         *)
(*   - AN UNROUTABLE BUCKET IS SKIPPED, NOT HELD.                          *)
(*     `apply_cell_batch_mux/3` logs `log_missing_ctx/3` and drops the     *)
(*     group; the cells re-present only if something replays them.        *)
(*                                                                         *)
(*   - THE DOOR JUDGES AGAINST THE FRONTIER. `watermark_door/3` and        *)
(*     `capped_truncation_point/2` hold un-applied events from truncation  *)
(*     and decide `never applied` with `never_applied/2`, which is         *)
(*     `key_seq(K) > VV[Origin]`. `Truncate` is that predicate, so an      *)
(*     over-claim licenses truncating the very event it lied about.        *)
(*                                                                         *)
(* NOT modelled: the MST itself, HLCs, compaction checkpoints, more than   *)
(* one replica (the frontier is per-origin and pointwise, and the theory   *)
(* carries the pointwise argument), and re-delivery of a truncated event   *)
(* -- once truncated it is gone, which is the worst case and the one the   *)
(* watermark door exists to prevent.                                       *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Origins,            \* remote origins whose events this replica folds
    Buckets,            \* entity types multiplexed onto the shard instance
    MaxSeq,             \* how many events each origin mints
    Unroutable,         \* the bucket with no cell-apply context at boot. Set
                        \* it to a value outside `Buckets` for the
                        \* everything-routable runs.

    ClaimRule,          \* "MaxCap" | "Contig" | "Pending" -- see the header

    InOrderDelivery,    \* TRUE means an origin's seqs arrive in order, the
                        \* hypothesis `AaeCausalClosure.tla` shows anti-entropy
                        \* does not provide. Separates the two over-claim
                        \* channels: delivery holes from bucket skips.

    WholeBatchOnly,     \* TRUE means a batch is the whole inbox, never a
                        \* subset.

    CanHeal,            \* TRUE means the missing table may register
                        \* (`bondy_oplog_instance:register_table/4`).

    CanRefold,          \* TRUE means the applier may re-present the whole
                        \* oplog to the fold -- `replay_cell_events/1`, and at
                        \* boot `replay_anchor/1` returning `undefined`.

    CanRestart,         \* TRUE means the instance may restart: in-flight work
                        \* is lost and any VOLATILE claim state is dropped.
                        \* The prefix survives in the checkpoint.

    DoorTruncates,      \* TRUE enables the compaction door.

    TruncatePrefixOnly, \* TRUE is what the code does: BOTH truncation sites
                        \* stop below the smallest key the frontier does not
                        \* claim (`watermark_door/3` truncates below
                        \* `MinHeld`; `capped_truncation_point/2` below the
                        \* first never-applied key), so a hole holds
                        \* everything above it. FALSE is per-entry
                        \* truncation -- not the code, and the run that shows
                        \* what the cap is buying.

    DoorUsesPending     \* TRUE sharpens the door's `never_applied/2` to the
                        \* EXACT test `s <= prefix \/ s \in pending`, so an
                        \* already-folded event above a hole stops being held.
                        \* Tempting, and unsafe across a restart: see the
                        \* `Pending_ExactDoor_Restart` run.

MaxOf(a, b) == IF a > b THEN a ELSE b
MaxSet(S)   == IF S = {} THEN 0 ELSE CHOOSE x \in S : \A y \in S : y <= x

Seqs   == 1..MaxSeq
Events == [o : Origins, s : Seqs, b : Buckets]

SeqsOf(S, o) == {e.s : e \in {x \in S : x.o = o}}

(* The largest c >= p with (p+1)..c entirely inside S: the prefix bound
   advanced through S. This is the walk `claim` would do from the stored
   entry, and it is the ONLY way a sound writer may raise it. *)
Absorb(p, S) ==
    LET R == {c \in p..MaxSeq : \A k \in (p + 1)..c : k \in S}
    IN  CHOOSE c \in R : \A d \in R : d <= c

(* `bondy_oplog_cell_apply:claim/2`, for one origin: the highest materialised
   seq strictly below the lowest failure this batch saw. *)
Cap(mat, fail) == MaxSet({s \in mat : \A t \in fail : s < t})

VARIABLES
    seen,       \* [Origins -> SUBSET Seqs]: ever received. Never shrinks, so
                \* truncation cannot make an event arrive again.
    oplog,      \* SUBSET Events: the MST's contents
    inbox,      \* SUBSET Events: drained, not yet presented to the fold
    applied,    \* [Origins -> SUBSET Seqs]: GROUND TRUTH -- the projection
    claimP,     \* [Origins -> 0..MaxSeq]: the frontier entry, on the wire
    claimS,     \* [Origins -> SUBSET Seqs]: the pending set. Empty unless
                \* ClaimRule = "Pending". VOLATILE across a restart.
    routable,   \* SUBSET Buckets: which buckets have a cell-apply context
    gone        \* SUBSET Events: truncated by the door, unrecoverable

vars == <<seen, oplog, inbox, applied, claimP, claimS, routable, gone>>

TypeOK ==
    /\ seen \in [Origins -> SUBSET Seqs]
    /\ oplog \subseteq Events
    /\ inbox \subseteq oplog
    /\ applied \in [Origins -> SUBSET Seqs]
    /\ claimP \in [Origins -> 0..MaxSeq]
    /\ claimS \in [Origins -> SUBSET Seqs]
    /\ routable \subseteq Buckets
    /\ gone \subseteq Events

Init ==
    /\ seen = [o \in Origins |-> {}]
    /\ oplog = {}
    /\ inbox = {}
    /\ applied = [o \in Origins |-> {}]
    /\ claimP = [o \in Origins |-> 0]
    /\ claimS = [o \in Origins |-> {}]
    /\ routable = Buckets \ {Unroutable}
    /\ gone = {}

-----------------------------------------------------------------------------
(* Anti-entropy hands the instance an event. `InOrderDelivery` is the
   prefix-closure hypothesis; without it a later seq may arrive first, which is
   the channel `AaeCausalClosure.tla` established is real. *)
Receive(o, s, b) ==
    /\ s \notin seen[o]
    /\ InOrderDelivery => (s = 1 \/ (s - 1) \in seen[o])
    /\ LET e == [o |-> o, s |-> s, b |-> b] IN
       /\ oplog' = oplog \cup {e}
       /\ inbox' = inbox \cup {e}
    /\ seen' = [seen EXCEPT ![o] = @ \cup {s}]
    /\ UNCHANGED <<applied, claimP, claimS, routable, gone>>

(* The claim this batch makes, under each rule. Note what `Pending` does NOT
   read: the failure set. It reports what folded and nothing else, so the
   `Failed` accumulator of `apply_cell_batch_mux/3` becomes dead code. *)
UpdateClaim(Mat, Fail) ==
    LET matS(o)  == SeqsOf(Mat, o)
        failS(o) == SeqsOf(Fail, o)
    IN  IF ClaimRule = "MaxCap"
        THEN /\ claimP' = [o \in Origins |->
                    MaxOf(claimP[o], Cap(matS(o), failS(o)))]
             /\ UNCHANGED claimS
        ELSE IF ClaimRule = "Contig"
        THEN /\ claimP' = [o \in Origins |-> Absorb(claimP[o], matS(o))]
             /\ UNCHANGED claimS
        ELSE /\ claimP' = [o \in Origins |->
                    Absorb(claimP[o], claimS[o] \cup matS(o))]
             /\ claimS' = [o \in Origins |->
                    {s \in claimS[o] \cup matS(o) :
                        s > Absorb(claimP[o], claimS[o] \cup matS(o))}]

(* The applier drains its queue in arrival order, so a batch is a PREFIX of
   what is queued, not an arbitrary subset. Under `InOrderDelivery` arrival
   order is seq order and the constraint is exact. Without it the two orders
   differ and this model over-approximates -- an arbitrary subset stands in for
   an arrival-order prefix, which admits behaviours the drain would not
   produce. Every result below that depends on the difference is stated for the
   in-order runs. *)
PrefixBatch(B) ==
    InOrderDelivery =>
        \A e \in B : \A f \in inbox : (f.o = e.o /\ f.s < e.s) => f \in B

(* One call of `apply_cell_batch_mux/3`. A group whose bucket resolves folds;
   one that does not is logged and dropped. The claim is made once, after every
   group has reported. *)
ApplyBatch(B) ==
    /\ B # {}
    /\ B \subseteq inbox
    /\ PrefixBatch(B)
    /\ WholeBatchOnly => B = inbox
    /\ LET Mat  == {e \in B : e.b \in routable}
           Fail == {e \in B : e.b \notin routable}
       IN /\ applied' = [o \in Origins |-> applied[o] \cup SeqsOf(Mat, o)]
          /\ UpdateClaim(Mat, Fail)
    /\ inbox' = inbox \ B
    /\ UNCHANGED <<seen, oplog, routable, gone>>

(* The sibling table registers. *)
Register ==
    /\ CanHeal
    /\ Unroutable \in Buckets
    /\ Unroutable \notin routable
    /\ routable' = Buckets
    /\ UNCHANGED <<seen, oplog, inbox, applied, claimP, claimS, gone>>

(* `replay_cell_events/1`: re-present the whole live oplog to the fold. The
   fold is idempotent, so already-applied events are re-presented too -- which
   is what lets a rule that lost information recover it. *)
Refold ==
    /\ CanRefold
    /\ inbox # oplog
    /\ inbox' = oplog
    /\ UNCHANGED <<seen, oplog, applied, claimP, claimS, routable, gone>>

(* A restart. The checkpoint carries the prefix; the pending set is volatile
   and is dropped; in-flight batches are lost. `replay_anchor/1` decides
   whether the boot re-presents the oplog. *)
Restart ==
    /\ CanRestart
    /\ claimS' = [o \in Origins |-> {}]
    /\ inbox' = IF CanRefold THEN oplog ELSE {}
    /\ UNCHANGED <<seen, oplog, applied, claimP, routable, gone>>

(* THE COMPACTION DOOR. `never_applied/2` is `key_seq(K) > VV[Origin]`, so an
   event the frontier claims is truncatable. Once truncated nothing replays it:
   `gone` is permanent. *)
Claims(o, s) ==
    IF ClaimRule = "Pending" /\ DoorUsesPending
    THEN s <= claimP[o] \/ s \in claimS[o]
    ELSE s <= claimP[o]

(* The hold. `never_applied/2` is judged against the FRONTIER, not against
   ground truth -- which is why an over-claim disarms the hold that would have
   saved the event it lied about. *)
Truncatable(e) ==
    /\ Claims(e.o, e.s)
    /\ TruncatePrefixOnly =>
         ~\E f \in oplog : f.o = e.o /\ f.s < e.s /\ ~Claims(f.o, f.s)

Truncate(e) ==
    /\ DoorTruncates
    /\ e \in oplog
    /\ Truncatable(e)
    /\ oplog' = oplog \ {e}
    /\ inbox' = inbox \ {e}
    /\ gone' = gone \cup {e}
    /\ UNCHANGED <<seen, applied, claimP, claimS, routable>>

Quiescent ==
    /\ \A o \in Origins : seen[o] = Seqs
    /\ inbox = {}

Next ==
    \/ \E o \in Origins, s \in Seqs, b \in Buckets : Receive(o, s, b)
    \/ \E B \in SUBSET inbox : ApplyBatch(B)
    \/ Register
    \/ Refold
    \/ Restart
    \/ \E e \in oplog : Truncate(e)
    \/ (Quiescent /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

(* Fairness for the runs that ask whether a rule RECOVERS. Delivery, the
   sibling table's registration and the replay all eventually happen; a restart
   and the door do not have to.

   The fold's fairness is STRONG and is on the FULL DRAIN, not on the
   existential `\E B : ApplyBatch(B)`. Weak fairness on the existential is
   satisfied by an adversary that presents the same proper subset forever --- a
   scheduling artifact of the subset over-approximation above, not a behaviour
   the applier has, since it drains what is queued. *)
FairSpec ==
    /\ Spec
    /\ WF_vars(\E o \in Origins, s \in Seqs, b \in Buckets : Receive(o, s, b))
    /\ SF_vars(ApplyBatch(inbox))
    /\ WF_vars(Register)
    /\ WF_vars(Refold)
-----------------------------------------------------------------------------
(* THE ORACLE CONTRACT. Every seq at or below the reported entry was folded.
   `bondy_oplog_responder:get_frontier` ships this integer; four readers
   discard or refuse data on it. *)
NoOverClaim ==
    \A o \in Origins : \A s \in 1..claimP[o] : s \in applied[o]

(* The same contract for a reader that sees both components -- the sharpened
   door of the design note. *)
PendingSound ==
    \A o \in Origins : \A s \in Seqs :
        (s <= claimP[o] \/ s \in claimS[o]) => s \in applied[o]

(* The consequence the door exists to prevent: an event dropped from the tree
   that the projection never folded. Nothing can fold it now. *)
NoLoss == \A e \in gone : e.s \in applied[e.o]

(* Exactness: the entry denotes the folded set, neither more nor less. Holds
   for `Pending` in the absence of a restart; a restart drops the volatile half
   and exactness returns only after the re-fold. *)
Exact ==
    ClaimRule = "Pending" =>
        \A o \in Origins : \A s \in Seqs :
            (s <= claimP[o] \/ s \in claimS[o]) <=> s \in applied[o]

(* COMPLETENESS. Soundness alone is satisfied by the writer that claims
   nothing, and an entry that under-claims makes `frontier_deficit/2`
   re-request forever, holds the event against `capped_truncation_point/2`
   forever, and keeps `Instances DIVERGED` red forever. So: once everything has
   arrived, every bucket routes, and the projection holds everything, the
   entry must say so. *)
Complete ==
    (/\ Quiescent
     /\ routable = Buckets
     /\ \A o \in Origins : applied[o] = Seqs)
        => \A o \in Origins : claimP[o] = MaxSeq

(* The same requirement weakened to allow a REPAIR STEP. `Complete` asks the
   entry to be right the moment the projection is; this asks only that it
   eventually becomes right and stays right, which is what a rule that needs a
   re-fold can achieve. The gap between the two is exactly what the re-fold
   costs: an O(live MST) fold that `Pending` does not need. *)
EventuallyComplete == <>[](\A o \in Origins : claimP[o] = MaxSeq)

=============================================================================
