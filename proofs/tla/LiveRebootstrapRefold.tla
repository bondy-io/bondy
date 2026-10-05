------------------------- MODULE LiveRebootstrapRefold -------------------------
(***************************************************************************)
(* THIS WAS BUILT BY CLAUDE OPUS and it is not verified.                   *)
(*                                                                         *)
(* Does a LIVE catalogue re-bootstrap leave a cell missing the effect of   *)
(* an event the replica holds, or a frontier claiming an event no cell     *)
(* reflects?                                                               *)
(*                                                                         *)
(* What the code does, established by reading it:                         *)
(*                                                                         *)
(*   - The session reads the peer's frontier (`request_peer_frontier/4`)  *)
(*     BEFORE streaming, and the stream is a live range scan of the peer  *)
(*     projection (`bondy_oplog_responder`, `get_catalogue_snapshot_      *)
(*     init`). The shipped responder serves both whatever the peer is      *)
(*     doing, including its own re-bootstrap.                              *)
(*                                                                         *)
(*   - The shipped install is skip-if-older by cell HLC, else REPLACE      *)
(*     (`bondy_oplog_applier:handle_cell/12`). `finalize_catalogue_        *)
(*     bootstrap/5` max-merges the peer frontier whether or not the cell   *)
(*     was skipped, and persists the frontier checkpoint. Only a trailing  *)
(*     round that returns `{ok, _}` (or `root_unservable`) is followed by  *)
(*     `rederive_projection` (`bondy_oplog_sync_session:finish_bootstrap/4`).*)
(*                                                                         *)
(*   - The install and the rederive run inside the applier process, as     *)
(*     the WAL drain does, so a local write is folded and inserted into    *)
(*     the MST as one step here.                                           *)
(*                                                                         *)
(*   - The frontier is durable only in the checkpoint, written by a clean  *)
(*     stop, by the bootstrap finalize and by a compaction commit, at any  *)
(*     time relative to a session. On restart the frontier is the          *)
(*     checkpoint's (`boot_frontier/2`) and the replay cursor is the       *)
(*     current root when that frontier claims every MST event, else        *)
(*     undefined, a full re-fold (`compute_replay_anchor/1`). The          *)
(*     re-bootstrap flag lives in the scheduler's ETS and is lost.         *)
(*                                                                         *)
(* A cell is the set of events folded into it, and folding an event it     *)
(* already reflects is a no-op. For the dotted kernels this is the         *)
(* guarded fold of `proofs/isabelle/Aw_Kernel.thy` under causal delivery   *)
(* (`guarded_redelivery_noop`, `putn_is_orset`); removes then need no      *)
(* separate modelling, since the value is a function of the event set.     *)
(* A cell's HLC is the highest event HLC it holds.                         *)
(*                                                                         *)
(* The proposed order is switched on by constants:                         *)
(*   - an unconditional install;                                           *)
(*   - a durable "re-fold owed" mark in the checkpoint, written before the *)
(*     first install batch and cleared only by the checkpoint write of a   *)
(*     frontier rebuilt by a full re-fold that ran after the install (the  *)
(*     rederive, or the boot re-fold after a crash);                       *)
(*     a restart that finds it trusts neither the cells nor the            *)
(*     checkpointed frontier;                                              *)
(*   - a full re-fold before the frontier is adopted;                      *)
(*   - a source that refuses to serve while it owes a re-fold, and whose   *)
(*     open snapshot sessions expire when it starts installing;            *)
(*   - a frontier the rederive resets before it re-folds, so after the     *)
(*     install it claims only the local MST and, at finalize, the peer     *)
(*     frontier, never an old claim.                                       *)
(*                                                                         *)
(* NOT modelled: compaction and its truncation, a peer reading this       *)
(* replica's frontier outside a session start (compaction witnesses, the   *)
(* oracle), holds, several cells, chunked installs, the frontier-gap       *)
(* verdict, loss of MST pages or of projection writes on a crash. What    *)
(* starts a re-bootstrap is an environment fault bounded by MaxFaults, so  *)
(* a repair that depends on the trigger firing again is not assumed.       *)
(*                                                                         *)
(* A projection write that fails during the install (`Adapter:put_batch/2` *)
(* returning an error in `bondy_oplog_applier:install_cell/9`) leaves the  *)
(* cell as it was. The shipped install logs it and counts the cell        *)
(* installed, so the session goes on to adopt the peer frontier. With      *)
(* WriteFailAborts the batch returns the error instead, and the session    *)
(* takes its failed-stream path (`refold_after_failure/1`): a rederive    *)
(* when the mark is set, no finalize, and no new re-bootstrap flag.        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Replicas,             \* replica ids, also used as origin ids
    MaxSeq,               \* how many events each origin may mint
    UnconditionalInstall, \* TRUE: every shipped cell replaces the local one
    RederiveEarly,        \* TRUE: a full re-fold after the install, before
                          \* the frontier is adopted. FALSE: after a
                          \* successful trailing round only.
    DurableMarker,        \* TRUE: the durable "re-fold owed" mark
    ServeGuard,           \* TRUE: a source owing a re-fold refuses to serve,
                          \* and its install expires open sessions on it
    ReplaceFrontier,      \* TRUE: the rederive resets the frontier before
                          \* it re-folds
    MaxFaults,            \* re-bootstrap triggers
    MaxTrailFails,        \* trailing rounds that fail
    MaxCrashes,           \* replica crashes
    MaxWriteFails,        \* install writes that fail
    WriteFailAborts       \* TRUE: a failed install write fails the batch

Origins == Replicas

Event == [org : Origins, seq : 1..MaxSeq]

Ev(o, s) == [org |-> o, seq |-> s]

Max2(a, b) == IF a > b THEN a ELSE b

Phases == {"idle", "streaming", "installed", "failed", "rederived",
           "finalized"}

VARIABLES
    cell,      \* [Replica -> SUBSET Event]  events whose effect is in the cell
    tree,      \* [Replica -> SUBSET Event]  events in the local MST
    cursor,    \* [Replica -> SUBSET Event]  events the replay has diffed past
    claim,     \* [Replica -> [Origin -> Nat]]  the in-memory applied frontier
    claimDur,  \* [Replica -> [Origin -> Nat]]  the checkpointed frontier
    hlc,       \* [Origin -> [1..MaxSeq -> Nat]]  HLC each event was minted at
    clock,     \* Nat  the last HLC minted anywhere
    minted,    \* [Origin -> Nat]
    gapFlag,   \* [Replica -> BOOLEAN]  re-bootstrap pending
    phase,     \* [Replica -> Phases]  where a bootstrap session is
    sess,      \* [Replica -> Replicas]  the peer of that session
    owed,      \* [Replica -> BOOLEAN]  the durable re-fold mark
    pfront,    \* [Replica -> [Origin -> Nat]]  the peer frontier the session
               \* read before streaming
    epoch,     \* [Replica -> Nat]  installs a replica has started
    sep,       \* [Replica -> Nat]  the source's epoch when the session began
    faults, trailFails, crashes, writeFails

vars ==
    <<cell, tree, cursor, claim, claimDur, hlc, clock, minted, gapFlag, phase,
      sess, owed, pfront, epoch, sep, faults, trailFails, crashes,
      writeFails>>

bootVars == <<gapFlag, phase, sess, owed, pfront, epoch, sep>>
faultVars == <<faults, trailFails, crashes, writeFails>>

CellHlc(S) ==
    IF S = {} THEN 0
    ELSE CHOOSE h \in {hlc[e.org][e.seq] : e \in S} :
             \A e \in S : hlc[e.org][e.seq] =< h

MaxSeqOf(S, o) ==
    LET seqs == {e.seq : e \in {x \in S : x.org = o}}
    IN IF seqs = {} THEN 0 ELSE CHOOSE m \in seqs : \A n \in seqs : n =< m

Claimed(VV) == {e \in Event : e.seq =< VV[e.org]}

AllMinted == {e \in Event : e.seq =< minted[e.org]}

Seed == CHOOSE r \in Replicas : TRUE

\* A source may serve a snapshot session.
Serves(p) == ~ServeGuard \/ ~owed[p]

TypeOK ==
    /\ cell     \in [Replicas -> SUBSET Event]
    /\ tree     \in [Replicas -> SUBSET Event]
    /\ cursor   \in [Replicas -> SUBSET Event]
    /\ claim    \in [Replicas -> [Origins -> 0..MaxSeq]]
    /\ claimDur \in [Replicas -> [Origins -> 0..MaxSeq]]
    /\ minted   \in [Origins -> 0..MaxSeq]
    /\ gapFlag  \in [Replicas -> BOOLEAN]
    /\ phase    \in [Replicas -> Phases]
    /\ sess     \in [Replicas -> Replicas]
    /\ owed     \in [Replicas -> BOOLEAN]
    /\ pfront   \in [Replicas -> [Origins -> 0..MaxSeq]]
    /\ epoch    \in [Replicas -> Nat]
    /\ sep      \in [Replicas -> Nat]

Init ==
    /\ cell     = [r \in Replicas |-> {}]
    /\ tree     = [r \in Replicas |-> {}]
    /\ cursor   = [r \in Replicas |-> {}]
    /\ claim    = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ claimDur = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ hlc      = [o \in Origins |-> [s \in 1..MaxSeq |-> 0]]
    /\ clock    = 0
    /\ minted   = [o \in Origins |-> 0]
    /\ gapFlag  = [r \in Replicas |-> FALSE]
    /\ phase    = [r \in Replicas |-> "idle"]
    /\ sess     = [r \in Replicas |-> Seed]
    /\ owed     = [r \in Replicas |-> FALSE]
    /\ pfront   = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ epoch    = [r \in Replicas |-> 0]
    /\ sep      = [r \in Replicas |-> 0]
    /\ faults = 0 /\ trailFails = 0 /\ crashes = 0 /\ writeFails = 0

(* A local write, folded on the WAL drain: it reaches the cell and the MST  *)
(* and claims its own seq, but does not move the replay cursor. HLCs are   *)
(* read only by the skip-if-older install, so they stay frozen when the    *)
(* install is unconditional, which shrinks the state space and nothing     *)
(* else.                                                                   *)
Mint(r) ==
    /\ minted[r] < MaxSeq
    /\ LET s == minted[r] + 1
           e == Ev(r, s)
       IN /\ hlc'   = IF UnconditionalInstall THEN hlc
                      ELSE [hlc EXCEPT ![r][s] = clock + 1]
          /\ cell'  = [cell  EXCEPT ![r] = @ \cup {e}]
          /\ tree'  = [tree  EXCEPT ![r] = @ \cup {e}]
          /\ claim' = [claim EXCEPT ![r][r] = s]
    /\ clock'  = IF UnconditionalInstall THEN clock ELSE clock + 1
    /\ minted' = [minted EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<claimDur, cursor, bootVars, faultVars>>

(* A live anti-entropy round merges the peer's MST. Not dispatched while a *)
(* bootstrap session is in flight.                                         *)
Pull(r, p) ==
    /\ r # p
    /\ phase[r] = "idle"
    /\ ~gapFlag[r]
    /\ ~(tree[p] \subseteq tree[r])
    /\ tree' = [tree EXCEPT ![r] = @ \cup tree[p]]
    /\ UNCHANGED <<claimDur, cell, cursor, claim, hlc, clock, minted,
                   bootVars, faultVars>>

(* The applier's diff replay: folds `tree \ cursor` onto the current cell  *)
(* and moves the cursor to the current root. One that started from an      *)
(* undefined cursor outside an install is a full re-fold: it pays the mark *)
(* with a checkpoint of the frontier it rebuilt.                           *)
Replay(r) ==
    /\ tree[r] \ cursor[r] # {}
    /\ LET C    == [o \in Origins |-> Max2(claim[r][o], MaxSeqOf(tree[r], o))]
           Pays == owed[r] /\ cursor[r] = {} /\ phase[r] = "idle"
       IN /\ claim'    = [claim    EXCEPT ![r] = C]
          /\ owed'     = [owed     EXCEPT ![r] = IF Pays THEN FALSE ELSE @]
          /\ claimDur' = [claimDur EXCEPT ![r] = IF Pays THEN C ELSE @]
    /\ cell'   = [cell   EXCEPT ![r] = @ \cup (tree[r] \ cursor[r])]
    /\ cursor' = [cursor EXCEPT ![r] = tree[r]]
    /\ UNCHANGED <<tree, hlc, clock, minted, gapFlag, phase, sess,
                   pfront, epoch, sep, faultVars>>

(* A checkpoint write by a clean stop or a compaction commit: the frontier *)
(* as it is in memory.                                                     *)
Checkpoint(r) ==
    /\ claimDur[r] # claim[r]
    /\ claimDur' = [claimDur EXCEPT ![r] = claim[r]]
    /\ UNCHANGED <<cell, tree, cursor, claim, hlc, clock, minted, bootVars,
                   faultVars>>

(* Whatever makes the scheduler flag a re-bootstrap.                        *)
Fault(r) ==
    /\ faults < MaxFaults
    /\ phase[r] = "idle"
    /\ ~gapFlag[r]
    /\ gapFlag' = [gapFlag EXCEPT ![r] = TRUE]
    /\ faults'  = faults + 1
    /\ UNCHANGED <<claimDur, cell, tree, cursor, claim, hlc, clock, minted,
                   phase, sess, owed, pfront, epoch, sep, trailFails, crashes,
                   writeFails>>

(* Session start: the flag is consumed at dispatch and the peer frontier   *)
(* is read.                                                                *)
Begin(r, p) ==
    /\ r # p
    /\ gapFlag[r]
    /\ phase[r] = "idle"
    /\ Serves(p)
    /\ pfront'  = [pfront  EXCEPT ![r] = claim[p]]
    /\ sep'     = [sep     EXCEPT ![r] = epoch[p]]
    /\ phase'   = [phase   EXCEPT ![r] = "streaming"]
    /\ sess'    = [sess    EXCEPT ![r] = p]
    /\ gapFlag' = [gapFlag EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<claimDur, cell, tree, cursor, claim, hlc, clock, minted,
                   owed, epoch, faultVars>>

\* The source can still serve this session's next batch.
SessionValid(r) ==
    ~ServeGuard \/ (Serves(sess[r]) /\ epoch[sess[r]] = sep[r])

(* The install of the peer's cell as the live scan reads it now. The mark  *)
(* is written before the first batch.                                      *)
Install(r) ==
    /\ phase[r] = "streaming"
    /\ SessionValid(r)
    /\ LET pc == cell[sess[r]]
       IN cell' = [cell EXCEPT ![r] =
                     IF UnconditionalInstall \/ CellHlc(pc) > CellHlc(@)
                       THEN pc ELSE @]
    /\ phase' = [phase EXCEPT ![r] = "installed"]
    /\ owed'  = [owed  EXCEPT ![r] = IF DurableMarker THEN TRUE ELSE @]
    /\ epoch' = [epoch EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<claimDur, tree, cursor, claim, hlc, clock, minted,
                   gapFlag, sess, pfront, sep, faultVars>>

(* The install write fails and the cell keeps its old events. The mark   *)
(* and the session expiry come first (`begin_install/1`).                  *)
InstallWriteFail(r) ==
    /\ writeFails < MaxWriteFails
    /\ phase[r] = "streaming"
    /\ SessionValid(r)
    /\ phase' = [phase EXCEPT ![r] =
                    IF WriteFailAborts THEN "failed" ELSE "installed"]
    /\ owed'  = [owed  EXCEPT ![r] = IF DurableMarker THEN TRUE ELSE @]
    /\ epoch' = [epoch EXCEPT ![r] = @ + 1]
    /\ writeFails' = writeFails + 1
    /\ UNCHANGED <<claimDur, cell, tree, cursor, claim, hlc, clock, minted,
                   gapFlag, sess, pfront, sep, faults, trailFails, crashes>>

(* The failed-stream path with no mark to pay: the session just ends.      *)
FailedIdle(r) ==
    /\ phase[r] = "failed"
    /\ ~owed[r]
    /\ phase' = [phase EXCEPT ![r] = "idle"]
    /\ UNCHANGED <<claimDur, cell, tree, cursor, claim, hlc, clock, minted,
                   gapFlag, sess, owed, pfront, epoch, sep, faultVars>>

(* The source refused or expired the session (`cursor_expired`): it ends  *)
(* before installing anything and the scheduler flags a retry.            *)
Abort(r) ==
    /\ phase[r] = "streaming"
    /\ ~SessionValid(r)
    /\ phase'   = [phase   EXCEPT ![r] = "idle"]
    /\ gapFlag' = [gapFlag EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<claimDur, cell, tree, cursor, claim, hlc, clock, minted,
                   sess, owed, pfront, epoch, sep, faultVars>>

(* `rederive_projection`: the cursor is reset, so the whole MST is folded   *)
(* onto the cells as they are now. A full re-fold that completes while the *)
(* mark is set pays it with a checkpoint of the frontier it rebuilt, as    *)
(* `Replay` does after a restart. On the failed-stream path it runs only   *)
(* while the mark is set, and the session then ends.                       *)
Rederive(r) ==
    /\ \/ RederiveEarly /\ phase[r] = "installed"
       \/ phase[r] = "failed" /\ owed[r]
    /\ LET Old == IF ReplaceFrontier THEN [o \in Origins |-> 0] ELSE claim[r]
           C   == [o \in Origins |-> Max2(Old[o], MaxSeqOf(tree[r], o))]
       IN /\ claim'    = [claim    EXCEPT ![r] = C]
          /\ claimDur' = [claimDur EXCEPT ![r] = IF owed[r] THEN C ELSE @]
    /\ owed'   = [owed   EXCEPT ![r] = FALSE]
    /\ cell'   = [cell   EXCEPT ![r] = @ \cup tree[r]]
    /\ cursor' = [cursor EXCEPT ![r] = tree[r]]
    /\ phase'  = [phase  EXCEPT ![r] =
                    IF @ = "failed" THEN "idle" ELSE "rederived"]
    /\ UNCHANGED <<tree, hlc, clock, minted, gapFlag, sess, pfront, epoch,
                   sep, faultVars>>

(* `finalize_catalogue_bootstrap/5`: max-merge the peer frontier read at   *)
(* Begin and persist the checkpoint, which clears the mark in the same     *)
(* write on the shipped order.                                             *)
Finalize(r) ==
    /\ phase[r] = IF RederiveEarly THEN "rederived" ELSE "installed"
    /\ LET C == [o \in Origins |-> Max2(claim[r][o], pfront[r][o])]
       IN /\ claim'    = [claim    EXCEPT ![r] = C]
          /\ claimDur' = [claimDur EXCEPT ![r] = C]
    /\ phase' = [phase EXCEPT ![r] = "finalized"]
    /\ owed'  = [owed  EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<cell, tree, cursor, hlc, clock, minted, gapFlag, sess,
                   pfront, epoch, sep, faultVars>>

(* The trailing round succeeds: pull, replay, and (shipped order) re-fold. *)
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
    /\ UNCHANGED <<claimDur, hlc, clock, minted, gapFlag, sess, owed, pfront,
                   epoch, sep, faultVars>>

(* The trailing round fails (`{partisan_call_failed, timeout}`, ...).      *)
TrailFail(r) ==
    /\ trailFails < MaxTrailFails
    /\ phase[r] = "finalized"
    /\ phase'      = [phase EXCEPT ![r] = "idle"]
    /\ trailFails' = trailFails + 1
    /\ UNCHANGED <<claimDur, cell, tree, cursor, claim, hlc, clock, minted,
                   gapFlag, sess, owed, pfront, epoch, sep, faults, crashes,
                   writeFails>>

(* A crash keeps the cell, the MST, the checkpoint and the mark; the       *)
(* session and the flag are lost. A node crash loses the in-memory         *)
(* frontier; a one_for_all subtree restart keeps it, because the registry  *)
(* row survives (`bondy_oplog_instance_dyn_sup` drops it only on           *)
(* `stop_instance`), and `boot_frontier/2` max-merges the checkpoint       *)
(* into it. Without the mark the cursor is re-anchored as                  *)
(* `compute_replay_anchor/1` does. With it the frontier is reset and the   *)
(* cursor undefined, so the full re-fold rebuilds both from the MST.       *)
Crash(r) ==
    /\ crashes < MaxCrashes
    /\ \E keep \in BOOLEAN :
        LET Restored == IF keep
                          THEN [o \in Origins |-> Max2(claim[r][o], claimDur[r][o])]
                          ELSE claimDur[r]
            C        == IF owed[r] THEN [o \in Origins |-> 0] ELSE Restored
        IN /\ claim'  = [claim  EXCEPT ![r] = C]
           /\ cursor' = [cursor EXCEPT ![r] =
                           IF ~owed[r] /\ tree[r] \subseteq Claimed(C)
                             THEN tree[r] ELSE {}]
    /\ phase'   = [phase   EXCEPT ![r] = "idle"]
    /\ gapFlag' = [gapFlag EXCEPT ![r] = FALSE]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<claimDur, cell, tree, hlc, clock, minted, sess, owed,
                   pfront, epoch, sep, faults, trailFails, writeFails>>

Next ==
    \/ \E r \in Replicas : Mint(r) \/ Replay(r) \/ Checkpoint(r) \/ Fault(r)
                          \/ Install(r) \/ InstallWriteFail(r)
                          \/ FailedIdle(r) \/ Abort(r) \/ Rederive(r)
                          \/ Finalize(r) \/ TrailOk(r) \/ TrailFail(r)
                          \/ Crash(r)
    \/ \E r, p \in Replicas : Pull(r, p) \/ Begin(r, p)

Spec == Init /\ [][Next]_vars

Fairness ==
    /\ \A r, p \in Replicas : WF_vars(Pull(r, p)) /\ WF_vars(Begin(r, p))
    /\ \A r \in Replicas :
          /\ WF_vars(Replay(r)) /\ WF_vars(Install(r)) /\ WF_vars(Abort(r))
          /\ WF_vars(Rederive(r)) /\ WF_vars(FailedIdle(r))
          /\ WF_vars(Finalize(r))
          /\ WF_vars(TrailOk(r))

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

\* An undefined cursor over a non-empty MST: the next replay re-presents
\* every MST event.
RefoldPending(r) == cursor[r] = {} /\ tree[r] # {}

\* Outside a bootstrap session, the frontier claims only events the cell
\* reflects, or that a pending full re-fold will fold: the restart re-anchor
\* and the convergence oracle both read a claimed event as folded.
ClaimSound ==
    \A r \in Replicas :
        phase[r] = "idle" =>
            Claimed(claim[r]) \cap AllMinted
                \subseteq cell[r] \cup (IF RefoldPending(r) THEN tree[r] ELSE {})

=============================================================================
