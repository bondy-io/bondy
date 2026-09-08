------------------------------ MODULE MuxBucketSkip ------------------------------
(***************************************************************************)
(* THIS WAS BUILT BY CLAUDE OPUS and it is not verified.                   *)
(*                                                                         *)
(* Can the applied-frontier VV claim an event whose cell was never         *)
(* installed into the projection, because the cell's BUCKET had no         *)
(* cell-apply context on this replica?                                     *)
(*                                                                         *)
(* Why this module exists. `AaeCausalClosure.tla` models delivery as       *)
(* though every delivered event lands in `applied`; its only loss channel  *)
(* is a per-origin contiguity hole. That abstraction hides a second        *)
(* channel, which a 3-node CT reproduction hit: a graceful restart of one  *)
(* node under `bondy_rbac_user:add/2` write load left 58 of 2807 users     *)
(* permanently absent on the restarted node while the convergence oracle   *)
(* reported CONVERGED (`Instances DIVERGED` = 0).                          *)
(*                                                                         *)
(* What the code does, established by reading it:                          *)
(*                                                                         *)
(*   - A shard instance is FOUNDED by the first table opened on it         *)
(*     (`bondy_db:start_or_join_shard_instance`), seeded with only that    *)
(*     table's bucket; sibling tables join later via                       *)
(*     `bondy_oplog_instance:register_table/4`. So the set of buckets an   *)
(*     instance can route GROWS after the instance is already serving.     *)
(*                                                                         *)
(*   - `bondy_oplog_cell_apply:apply_cell_pairs_mux/5` groups the batch by *)
(*     bucket and resolves each group. An unresolved bucket calls          *)
(*     `log_missing_ctx/3` and SKIPS the group, returning success          *)
(*     (cell_apply.erl:1066-1077). The same skip exists on the catalogue   *)
(*     install (`bondy_oplog_applier:do_install_catalogue_batch/3`, where  *)
(*     it is counted only as `skipped`).                                   *)
(*                                                                         *)
(*   - The applied-frontier merge is PER SURVIVING GROUP:                  *)
(*     `merge_frontier(Id, batch_frontier(Pairs))` runs inside             *)
(*     `apply_cell_pairs` (cell_apply.erl:814) with `Pairs` = that group.  *)
(*     A skipped sibling group therefore does not suppress the merge of    *)
(*     the groups that did fold. THIS IS THE FIRST OVER-CLAIM CHANNEL and  *)
(*     it needs no bootstrap at all.                                       *)
(*                                                                         *)
(*   - `Held` is computed by `partition_contiguous/3` BEFORE bucket        *)
(*     resolution, from contiguity alone. A missing-ctx skip contributes   *)
(*     0 to `Held`, so the caller's `case Held of 0 -> advance cursor`     *)
(*     (applier.erl:2653, instance.erl:4392) advances the replay cursor    *)
(*     past cells that were discarded. The code's own comment -- "they     *)
(*     re-apply on the next replay" -- is false on this path.              *)
(*                                                                         *)
(*   - `bondy_oplog_sync_session:do_bootstrap_snapshot/6` calls            *)
(*     `finalize_catalogue_bootstrap/5` UNCONDITIONALLY; that function     *)
(*     max-merges the peer's frontier (`instance.erl:2338`) and persists   *)
(*     it. `Skipped` reaches telemetry only. THIS IS THE SECOND CHANNEL:   *)
(*     it launders an incomplete install into a convergent-looking VV.     *)
(*                                                                         *)
(* Like `AaeCausalClosure.tla`, this model keeps `claim` (what             *)
(* get_frontier reports) strictly separate from `applied` (ground truth),  *)
(* so over-claiming is expressible and therefore checkable.                *)
(*                                                                         *)
(* NOT modelled here: compaction (the loss needs none -- the replay cursor *)
(* alone makes a skipped cell unreachable), the MST, HLCs, and network     *)
(* failure. Origin retirement and the watermark door have their own        *)
(* modules.                                                                *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Replicas,           \* replica ids, also used as origin ids
    Buckets,            \* entity types multiplexed onto one shard instance
    MaxSeq,             \* how many events each origin may mint

    \* --- THE FOLD CHANNEL. Either mechanism alone closes it; removing both
    \* --- opens it (`Minus_SkipHole_Contig`).

    SkipIsHole,         \* An UNROUTABLE bucket counts as a per-origin
                        \* contiguity hole inside `partition_contiguous/4`,
                        \* so nothing at or above it folds, the applied set
                        \* stays prefix-closed, and the `Held` return keeps
                        \* the replay cursor so the parked cells re-present.

    ContigClaim,        \* The fold reports the per-origin CONTIGUOUS PREFIX
                        \* of what it applied instead of the per-group MAX.
                        \* Same wire type, one integer per origin. Governs
                        \* Replay and Mint only -- see AdoptIfComplete for
                        \* why it cannot govern the bootstrap.

    \* --- THE BOOTSTRAP CHANNEL. Both mechanisms are needed; neither alone
    \* --- suffices (`Minus_AdoptIfComplete`, `Minus_ServeGate`).

    AdoptIfComplete,    \* The joiner adopts the peer's frontier only when the
                        \* install skipped nothing it could SEE it skip, and
                        \* otherwise adopts nothing and completes the
                        \* bootstrap anyway. A claim DERIVED from the
                        \* installed cells is not an option: a shipped cell is
                        \* {Bucket, Key, Frame}, carrying no origin and no
                        \* seq, so "was anything unroutable" is the only
                        \* question the install can answer. Refusing the
                        \* bootstrap outright is sound and violates `Live`.

    ServeGate,          \* The RESPONDER refuses to serve a catalogue snapshot
                        \* until its own table set has registered. Without it
                        \* a peer answers the snapshot from `reg[p]` -- partial
                        \* while it is still opening tables -- while answering
                        \* the frontier in full, so AdoptIfComplete's guard
                        \* passes on cells that were never sent.

    \* --- THE INITIATOR GATE. Not load-bearing for the invariants here
    \* --- (`Minus_GateOnRegistration` is clean); kept because it avoids a
    \* --- bootstrap that installs a partial projection and can claim nothing.

    GateOnRegistration, \* The instance refuses remote work -- sync merge, fold
                        \* and catalogue install -- until every bucket it
                        \* DECLARES has registered.

    GapVerdict,         \* `maybe_frontier_gap/5` raises a deficit against the
                        \* peer's frontier, arming `gapFlag` and so
                        \* re-enabling CatalogueBootstrap. FALSE withholds the
                        \* verdict when this replica cannot route something
                        \* the peer ships -- the appealing "stop cycling
                        \* through catalogue transfers we can never complete"
                        \* optimisation. It costs `Live`
                        \* (`Minus_GapVerdict`): the catalogue install is the
                        \* ONLY action that writes `applied` without passing
                        \* through the fold, so it is the only way an event
                        \* parked above an unroutable seq of the same origin
                        \* is ever delivered. Withdraw the trigger and
                        \* `Replay` spins as a permanent no-op.

    \* --- SCENARIO.

    VersionSkew,        \* TRUE means SkewReplica can NEVER register
                        \* SkewBucket: it runs a build with no table for that
                        \* entity type, so the unroutable condition is
                        \* PERMANENT rather than a transient registration
                        \* window. This is what separates a mechanism that
                        \* parks the unroutable suffix from one that blocks.
    SkewReplica,
    SkewBucket

Origins == Replicas

Event == [org : Origins, seq : 1..MaxSeq]

Ev(o, s) == [org |-> o, seq |-> s]

Max2(a, b) == IF a > b THEN a ELSE b

\* The bucket the instance is FOUNDED with. Every replica starts able to
\* route exactly this one; the rest arrive by Register.
Founding == CHOOSE b \in Buckets : TRUE

\* The buckets this replica's build DECLARES for this shard -- the table set
\* its catalogue will open. NOT the global bucket set: a bucket this build has
\* no table for was never declared here, so it cannot hold the gate shut.
\*
\* An earlier version of this module gated on `reg[r] = Buckets` (the GLOBAL
\* set) and concluded the registration gate was safe-but-DEAD under version
\* skew. That conclusion was an artefact of the wrong predicate: it modelled a
\* gate no orchestrator would build. `bondy_db:start_draining/1` releases the
\* real gate once the catalogue has opened every table IT declares, which is
\* bounded and always reached.
Declared(r) ==
    IF VersionSkew /\ r = SkewReplica
      THEN Buckets \ {SkewBucket}
      ELSE Buckets

\* Highest seq of origin o present in S (0 if none). Deliberately NOT a
\* claim that everything below it is present: `batch_frontier/1` is exactly
\* this per-origin max over the pairs that folded.
MaxSeqOf(S, o) ==
    LET seqs == {e.seq : e \in {x \in S : x.org = o}}
    IN IF seqs = {} THEN 0
       ELSE CHOOSE m \in seqs : \A n \in seqs : n =< m

\* Per-origin CONTIGUOUS prefix bound of S: the largest n such that every
\* seq in 1..n is present. Unlike MaxSeqOf it cannot straddle a hole, so a
\* skipped bucket group stops it.
ContigOf(S, o) ==
    LET Full(n) == \A i \in 1..n : Ev(o, i) \in S
    IN CHOOSE n \in 0..MaxSeq : Full(n) /\ ~Full(n + 1)

ClaimFrom(S) == [o \in Origins |-> ContigOf(S, o)]

VARIABLES
    applied,   \* [Replica -> SUBSET Event]  cells materialised in the projection
    tree,      \* [Replica -> SUBSET Event]  items reachable from the local MST root
    cursor,    \* [Replica -> SUBSET Event]  the replay cursor, as the set of
               \* events already diffed past. A replay presents tree \ cursor;
               \* `last_replayed_root = undefined` is cursor = {}.
    claim,     \* [Replica -> [Origin -> Nat]]  what get_frontier reports
    reg,       \* [Replica -> SUBSET Buckets]  buckets with a cell-apply ctx
    evb,       \* [Origin -> [1..MaxSeq -> Buckets]]  bucket each event carries.
               \* Slots above minted[o] are unread; they stay at Founding so
               \* they cost no states.
    minted,    \* [Origin -> Nat]
    gapFlag,   \* [Replica -> BOOLEAN]  catalogue rebootstrap pending
    booted,    \* [Replica -> BOOLEAN]  has completed catalogue bootstrap
    restarted  \* [Replica -> BOOLEAN]  has already taken its one restart

vars ==
    <<applied, tree, cursor, claim, reg, evb, minted, gapFlag, booted,
      restarted>>

BktOf(e) == evb[e.org][e.seq]

TypeOK ==
    /\ applied \in [Replicas -> SUBSET Event]
    /\ tree    \in [Replicas -> SUBSET Event]
    /\ cursor  \in [Replicas -> SUBSET Event]
    /\ claim   \in [Replicas -> [Origins -> 0..MaxSeq]]
    /\ reg     \in [Replicas -> SUBSET Buckets]
    /\ evb     \in [Origins -> [1..MaxSeq -> Buckets]]
    /\ minted  \in [Origins -> 0..MaxSeq]
    /\ gapFlag \in [Replicas -> BOOLEAN]
    /\ booted  \in [Replicas -> BOOLEAN]
    /\ restarted \in [Replicas -> BOOLEAN]

Seed == CHOOSE r \in Replicas : TRUE

Init ==
    /\ applied = [r \in Replicas |-> {}]
    /\ tree    = [r \in Replicas |-> {}]
    /\ cursor  = [r \in Replicas |-> {}]
    /\ claim   = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ reg     = [r \in Replicas |-> {Founding}]
    /\ evb     = [o \in Origins |-> [s \in 1..MaxSeq |-> Founding]]
    /\ minted  = [o \in Origins |-> 0]
    /\ gapFlag = [r \in Replicas |-> FALSE]
    /\ booted  = [r \in Replicas |-> r = Seed]
    /\ restarted = [r \in Replicas |-> FALSE]

(***************************************************************************)
(* A sibling table opens on this shard instance and registers its bucket   *)
(* (`bondy_oplog_instance:register_table/4`). Monotone: a ctx is never     *)
(* withdrawn while the instance lives.                                     *)
(***************************************************************************)
Register(r, b) ==
    /\ b \notin reg[r]
    /\ ~(VersionSkew /\ r = SkewReplica /\ b = SkewBucket)
    /\ reg' = [reg EXCEPT ![r] = @ \cup {b}]
    /\ UNCHANGED <<applied, tree, cursor, claim, evb, minted, gapFlag, booted, restarted>>

(***************************************************************************)
(* A RESTART. The DURABLE state survives it -- the projection (`applied`),  *)
(* the MST (`tree`) and the applied-frontier checkpoint (`claim`, restored  *)
(* by `bondy_oplog_instance:restore_frontier/2` inside `init/1`, before any *)
(* table has registered). The ROUTING DIRECTORY does not: `reg` drops back  *)
(* to the founding bucket and refills table by table as the catalogue       *)
(* reopens them (`bondy_db` opens each table, then calls `start_draining`). *)
(*                                                                          *)
(* THIS ASYMMETRY IS THE WHOLE BUG, and no earlier version of this module   *)
(* could express it. With `reg` only ever growing, `applied[p]` was always  *)
(* within what `reg[p]` could ship, so a peer could not under-ship while    *)
(* over-claiming -- the model was structurally incapable of the defect it   *)
(* was written to look for, and answered "no error" for that reason alone.  *)
(*                                                                          *)
(* Bounded to one restart per replica by `restarted`: a rolling restart     *)
(* touches each node once, and the bound keeps the state space finite.      *)
(***************************************************************************)
Restart(r) ==
    /\ ~restarted[r]
    /\ reg[r] = Declared(r)
    /\ restarted' = [restarted EXCEPT ![r] = TRUE]
    /\ reg'       = [reg     EXCEPT ![r] = {Founding}]
    /\ gapFlag'   = [gapFlag EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<applied, tree, cursor, claim, evb, minted, booted>>

(***************************************************************************)
(* A local write. The table must be open here to be written through, so    *)
(* the bucket is registered by construction. Local events fold on the WAL  *)
(* drain and are never held.                                               *)
(***************************************************************************)
Mint(r, b) ==
    /\ minted[r] < MaxSeq
    /\ booted[r]
    /\ ~gapFlag[r]
    /\ b \in reg[r]
    /\ LET s == minted[r] + 1
           e == Ev(r, s)
       IN /\ evb'     = [evb EXCEPT ![r][s] = b]
          /\ applied' = [applied EXCEPT ![r] = @ \cup {e}]
          /\ tree'    = [tree    EXCEPT ![r] = @ \cup {e}]
          /\ claim'   = IF ContigClaim
                          THEN [claim EXCEPT ![r] = ClaimFrom(applied[r] \cup {e})]
                          ELSE [claim EXCEPT ![r][r] = s]
    /\ minted' = [minted EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<cursor, reg, gapFlag, booted, restarted>>

(***************************************************************************)
(* A COMPLETE anti-entropy round: r merges p's whole item set into its     *)
(* MST, then runs the frontier-gap check. The FOLD is a separate action    *)
(* (Replay) because it genuinely is one in the code: the sync session      *)
(* casts `replay_cell_events` to the applier and does not wait, so the gap *)
(* check can observe a frontier the replay has not yet advanced.           *)
(***************************************************************************)
SyncMerge(r, p) ==
    /\ r # p
    /\ booted[r]
    /\ booted[p]
    /\ ~gapFlag[r]
    /\ GateOnRegistration => (reg[r] = Declared(r))
    /\ tree' = [tree EXCEPT ![r] = @ \cup tree[p]]
    \* `maybe_frontier_gap/5`: the peer's applied frontier is ahead of ours
    \* after a complete round. The prescribed remedy is a catalogue
    \* re-bootstrap, which is why this arms `gapFlag`. Under ~GapVerdict the
    \* verdict is withheld when this replica cannot route something the peer
    \* would ship.
    /\ LET Unroutable ==
             \E e \in applied[p] :
                 BktOf(e) \in reg[p] /\ BktOf(e) \notin reg[r]
       IN IF /\ \E o \in Origins : claim[p][o] > claim[r][o]
             /\ (GapVerdict \/ ~Unroutable)
            THEN gapFlag' = [gapFlag EXCEPT ![r] = TRUE]
            ELSE UNCHANGED gapFlag
    /\ UNCHANGED <<applied, cursor, claim, reg, evb, minted, booted, restarted>>

(***************************************************************************)
(* The projection fold: diff the MST from the replay cursor, hold          *)
(* non-contiguous remote suffixes, group the remainder by bucket, apply    *)
(* the groups that resolve and SKIP the groups that do not, then merge the *)
(* applied frontier per surviving group.                                   *)
(***************************************************************************)
Replay(r) ==
    /\ booted[r]
    \* Both replay paths in the implementation are gated on the same bit as
    \* the sync plane: the WAL / cold replay defers while `drain_gate = gated`
    \* (`bondy_oplog_applier:handle_info(drain, ...)`), and the AAE
    \* diff-replay only runs inside a round the scheduler dispatched, which
    \* skips a non-serviceable instance
    \* (`bondy_oplog_sync_scheduler:dispatch_for/2`). Leaving this action
    \* ungated modelled a replay no scheduler will start.
    /\ GateOnRegistration => (reg[r] = Declared(r))
    /\ tree[r] \ cursor[r] # {}
    /\ LET presented == tree[r] \ cursor[r]
           VV == claim[r]
           \* partition_contiguous/3: for a REMOTE origin, foldable seqs are
           \* everything at or below the applied frontier (idempotent
           \* re-folds) plus the contiguous run rising from it. Local-origin
           \* events always fold.
           \* An event this replica can actually route to a projection.
           \* Under SkipIsHole an unroutable event is invisible to contiguity
           \* computation, exactly as an absent one is -- that is the whole
           \* content of the fix.
           routable == {e \in presented : e.org = r \/ BktOf(e) \in reg[r]}
           visible  == IF SkipIsHole THEN routable ELSE presented
           heldSet == {e \in presented :
                         /\ e.org # r
                         /\ e.seq > VV[e.org] + 1
                         /\ \E i \in (VV[e.org] + 1) .. (e.seq - 1) :
                              Ev(e.org, i) \notin visible}
           foldable == (IF SkipIsHole THEN routable ELSE presented) \ heldSet
           \* bondy_oplog_mux:resolve/2 returns undefined for a bucket with
           \* no registered table: log_missing_ctx/3, and the group is
           \* dropped with a success return.
           skipped == {e \in foldable : BktOf(e) \notin reg[r]}
           folded  == foldable \ skipped
           \* merge_frontier(Id, batch_frontier(Pairs)) -- per SURVIVING
           \* group, so a skipped sibling does not hold it back.
           newApplied == applied[r] \cup folded
           newClaim == IF ContigClaim
                         THEN ClaimFrom(newApplied)
                         ELSE [o \in Origins |->
                                 Max2(VV[o], MaxSeqOf(folded, o))]
           heldCount == IF SkipIsHole
                          THEN Cardinality(presented \ folded)
                          ELSE Cardinality(heldSet)
       IN /\ applied' = [applied EXCEPT ![r] = newApplied]
          /\ claim'   = [claim   EXCEPT ![r] = newClaim]
          \* `case Held of 0 -> State#state{last_replayed_root = CurrentRoot}`
          /\ cursor'  = IF heldCount = 0
                          THEN [cursor EXCEPT ![r] = tree[r]]
                          ELSE cursor
    /\ UNCHANGED <<tree, reg, evb, minted, gapFlag, booted, restarted>>

(***************************************************************************)
(* Catalogue bootstrap or re-bootstrap. Installs the peer's projection     *)
(* snapshot -- demultiplexed by bucket, so a bucket with no ctx here is    *)
(* SKIPPED (do_install_catalogue_batch/3) -- then finalize adopts the      *)
(* peer's frontier and finish_bootstrap re-derives, which resets the       *)
(* replay cursor (`rederive_projection` sets last_replayed_root =          *)
(* undefined). The replica's own events survive in its local WAL and are   *)
(* re-delivered by the drain, so they are retained here (same reasoning as *)
(* AaeCausalClosure.Rebootstrap).                                          *)
(***************************************************************************)
CatalogueBootstrap(r, p) ==
    /\ r # p
    /\ booted[p]
    /\ (~booted[r] \/ gapFlag[r])
    /\ GateOnRegistration => (reg[r] = Declared(r))
    \* The peer refuses to SERVE until its own directory is complete.
    /\ ServeGate => (reg[p] = Declared(p))
    /\ LET own      == {e \in applied[r] : e.org = r}
           \* What the peer can actually SHIP. `build_targets/2` enumerates the
           \* buckets to scan from the peer's OWN registry, so a peer still
           \* opening its tables ships a strict subset of what it holds --
           \* while `get_frontier` answers a vector restored in full at
           \* `init/1`. Modelling the ship as `applied[p]` (as this module
           \* originally did) assumes away exactly that asymmetry.
           shippable == {e \in applied[p] : BktOf(e) \in reg[p]}
           routableP == {e \in shippable : BktOf(e) \in reg[r]}
           \* What the JOINER can observe it failed to route: cells that
           \* ARRIVED and resolved to no ctx. It cannot see cells the peer
           \* never shipped -- nothing on the wire names them, so a skip set
           \* measured against applied[p] is not a function of anything the
           \* install can observe.
           obsSkipped == shippable \ routableP
       IN \* Additive, not a replacement: `install_one_cell` writes when
          \* there is no local cell and otherwise keeps the higher HLC, so a
          \* bootstrap install NEVER removes a cell this replica already
          \* holds. Modelling the install as a wholesale replace manufactures
          \* loss on a re-bootstrap that the real skip-if-older path cannot
          \* produce.
          /\ applied' = [applied EXCEPT ![r] = applied[r] \cup routableP \cup own]
          /\ tree'    = [tree    EXCEPT
                           ![r] = tree[p] \cup {e \in tree[r] : e.org = r}]
          \* The bootstrap claim has only two IMPLEMENTABLE options, so
          \* ContigClaim does NOT govern here -- it governs Replay and Mint,
          \* where a contiguous prefix IS derivable from what folded. A
          \* shipped cell is {Bucket, Key, Frame}: it carries no origin and
          \* no seq, so a claim derived from the INSTALLED cells is not a
          \* function of anything the install can observe. Checking one
          \* MASKED the bootstrap channel: a configuration pairing the
          \* shipped fold fix (ContigClaim) with the shipped bootstrap came
          \* out clean because the bootstrap silently used that branch.
          /\ claim'   = IF AdoptIfComplete /\ obsSkipped # {}
                          THEN claim
                          ELSE [claim EXCEPT
                                  ![r] = [o \in Origins |->
                                            Max2(claim[r][o], claim[p][o])]]
    /\ cursor'  = [cursor  EXCEPT ![r] = {}]
    /\ gapFlag' = [gapFlag EXCEPT ![r] = FALSE]
    /\ booted'  = [booted  EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<reg, evb, minted, restarted>>

Next ==
    \/ \E r \in Replicas, b \in Buckets : Register(r, b)
    \/ \E r \in Replicas : Restart(r)
    \/ \E r \in Replicas, b \in Buckets : Mint(r, b)
    \/ \E r \in Replicas, p \in Replicas : SyncMerge(r, p)
    \/ \E r \in Replicas : Replay(r)
    \/ \E r \in Replicas, p \in Replicas : CatalogueBootstrap(r, p)

Spec == Init /\ [][Next]_vars

\* Every action weakly fair, so a stall is a real stall and not a scheduler
\* artefact. Minting is bounded by MaxSeq, so it cannot starve the rest.
\* Fairness is per (r, p) PAIR, not per r. `WF_vars(\E p : SyncMerge(r, p))`
\* is satisfied by a replica that forever picks the same peer, which
\* manufactures a spurious liveness violation at three replicas: events held
\* only by the unchosen peer never arrive. The real scheduler rotates peers
\* (`db.aae.fanout = 3` over the member list), so pairwise fairness is the
\* faithful formulation.
Fairness ==
    /\ \A r \in Replicas, b \in Buckets : WF_vars(Register(r, b))
    /\ \A r \in Replicas, p \in Replicas : WF_vars(SyncMerge(r, p))
    /\ \A r \in Replicas : WF_vars(Replay(r))
    /\ \A r \in Replicas, p \in Replicas : WF_vars(CatalogueBootstrap(r, p))

FairSpec == Spec /\ Fairness

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* THE ORACLE CONTRACT. `bondy_oplog_responder:get_frontier` calls the
\* applied VV a convergence oracle; `bondy_prometheus_db:frontier_hash_rows`
\* turns it into the `Instances DIVERGED` panel. Both are sound only if the
\* VV never reports an event this replica did not materialise.
NoOverClaim ==
    \A r \in Replicas : \A o \in Origins : \A j \in 1..MaxSeq :
        (j =< claim[r][o]) => (Ev(o, j) \in applied[r])

\* The hypothesis Dot_Exactness.compact_test_exact needs.
PrefixClosed ==
    \A r \in Replicas : \A o \in Origins : \A j \in 1..MaxSeq :
        (Ev(o, j) \in applied[r]) => (\A i \in 1..j : Ev(o, i) \in applied[r])

\* An event this replica can route (its bucket is registered) and holds in
\* its MST, but has diffed past without applying, is unreachable: no future
\* replay presents it and no peer will re-offer it. This is the loss itself,
\* stated without reference to the frontier -- so a fix that only silences
\* the oracle still violates it.
\* LIVENESS. Infinitely often, every event this replica holds in its MST
\* and CAN route is in its projection. A fix that buys safety by refusing to
\* replicate at all fails this; a fix that parks only the unroutable suffix
\* passes it. Checked at SkewReplica because that is where a blocking fix
\* blocks.
\* Stated over what SOME replica applied, not over what this replica already
\* holds in its tree: a fix that stops a replica from ever receiving anything
\* must fail this, and a version of this property quantified over tree[r] does
\* not -- it passes vacuously on an empty tree. That weaker form let the
\* registration gate through on a first pass; recorded here because the
\* mistake is the easy one to make.
Live ==
    []<>( \A r \in Replicas : \A q \in Replicas : \A e \in applied[q] :
            (BktOf(e) \in reg[r]) => (e \in applied[r]) )

NoStrandedCell ==
    \A r \in Replicas :
        \A e \in (cursor[r] \ applied[r]) :
            BktOf(e) \notin reg[r]

=============================================================================
