------------------------------ MODULE JoinInstall ------------------------------
(***************************************************************************)
(* THIS WAS BUILT BY CLAUDE OPUS and it is not verified.                   *)
(*                                                                         *)
(* Can a catalogue install that JOINS the peer's cell state into the local *)
(* one, instead of replacing it, produce a state other than the fold of    *)
(* the events the two sides had applied, once the cells have been reduced  *)
(* by stabilization or by an origin reap?                                  *)
(*                                                                         *)
(* What the code does, established by reading it:                          *)
(*                                                                         *)
(*   - An add-wins cell is `{Dots, Context, Hlc}`: the surviving dots and  *)
(*     a version vector (`bondy_oplog_crdt_aw_core`). An op drops the dots *)
(*     its stamped context observed, adds its own dot when it is an add,   *)
(*     and max-merges its context and dot into the cell's                  *)
(*     (`cc_absorb/3`). The kernel skips an event whose dot the context    *)
(*     already covers (`bondy_oplog_cell_kernel:apply/6`). Remote events   *)
(*     fold in per-origin seq order (the contiguity hold); there is no     *)
(*     cross-origin causal broadcast.                                      *)
(*   - A remote event enters the MST on receipt and reaches the cell on a  *)
(*     later replay (`deliver_remote/1` casts `replay_cell_events`).       *)
(*   - The stabilization sweep deletes an empty flag cell whose HLC is     *)
(*     below the stability point (`bondy_oplog_crdt_ew_flag:stabilize/2`,  *)
(*     `bondy_oplog_cell_utils:apply_stabilize/10`). The stability point   *)
(*     is the HLC of the largest local key every member CONFIRMS, and a    *)
(*     member confirms a key it received (in its recorded root) or         *)
(*     applied (at or below its frontier)                                  *)
(*     (`bondy_oplog_instance:compute_frontier_for/2`).                    *)
(*   - `reap_origins/2` drops a retired origin's context entry when no     *)
(*     surviving dot is that origin's (`bondy_oplog_crdt_aw_set`).         *)
(*                                                                         *)
(* Session = TRUE makes an install the code's session                     *)
(* (`do_bootstrap_snapshot/6`): it reads the peer's frontier, then installs *)
(* the peer's cell as it is at that later moment (a live range scan of its *)
(* projection), and at finalize adopts the frontier it read                *)
(* (`finalize_catalogue_bootstrap/5`). A crash, which here is a node's,    *)
(* ends a stream (the cursor table lives in node memory). Every batch is   *)
(* served under the serve guards, unless SplitServe, which is the code's   *)
(* order: the source checks them when the session opens                     *)
(* (`bondy_oplog_catalogue_snapshot:init/1`), serves each batch while the  *)
(* cursor is open, and expires the cursor when it marks itself; a session  *)
(* whose cursor expired fails. Invariant SomeoneServes asks that some      *)
(* replica can still serve or clear its mark, which no bound on installs   *)
(* can supply once every replica owes one. FALSE makes it one step.        *)
(* InstallMode = "join" is the candidate: a dot survives when both sides hold it, or one holds it and  *)
(* the other's context does not cover it; the contexts max-merge; the      *)
(* replay cursor does not move. "replace" installs the peer's cell and, at *)
(* finalize, re-folds the whole local MST onto it (the rederive). A        *)
(* deleted cell joins as the empty state.                                  *)
(*                                                                         *)
(* Stability = "receipt" is the shipped confirmation; "applied" counts     *)
(* only a member that folded the event. HeldSweep makes the sweep wait     *)
(* until the MST holds every event whose effect the cell holds, which an   *)
(* install can break. RetiredCovered makes the join count a retired        *)
(* origin's dots as covered by both sides. ClaimSkip makes the replay skip *)
(* an event the applied frontier claims (`app` here) instead of re-folding *)
(* it onto a context a discard may have deleted; it assumes the frontier   *)
(* claims only what the cell reflects (`LiveRebootstrapRefold.ClaimSound`).*)
(* A cell's events stand in for the key-order prefix the code confirms,    *)
(* which over-approximates when a sweep may run. Retirement is granted     *)
(* only once every replica has applied every event of the origin, the      *)
(* operator's obligation.                                                  *)
(*                                                                         *)
(* MaxCrashes > 0 adds crashes. A checkpoint reads the claims, then syncs   *)
(* the projection (`write_frontier_checkpoint/2`); a crash keeps the MST    *)
(* and the minted counter, restores the claims the last checkpoint read     *)
(* (`boot_frontier/2`), and leaves the cell in any state it held since that *)
(* sync: the sweep's delete and every fold are acknowledged before they are *)
(* durable. The replay then re-presents every unclaimed received event.     *)
(* A peer confirms anything it ever claimed: a recorded report is replaced  *)
(* only by the next round's (`bondy_oplog_peer_state`), so a stale one      *)
(* outlives the peer's crash.                                               *)
(*                                                                         *)
(* CompactBy # "none" adds compaction (`do_finalize_catalogue_compaction/3`):*)
(* it syncs the projection, truncates a key-order prefix of the MST that    *)
(* every other member confirms and the replica's prefix claims             *)
(* (`capped_truncation_point/2`), then checkpoints. The watermark door     *)
(* truncates the same way with no checkpoint after (`watermark_door/2`), so *)
(* any step, a crash included, may follow a truncation. A peer confirms by  *)
(* "receipt" (root, or a reported claim); "durable" has every member, the  *)
(* replica included, confirm by its checkpointed claims. A truncated event  *)
(* is never served nor re-presented, and the bound's walk over the MST     *)
(* does not see it.                                                        *)
(*                                                                         *)
(* NOT modelled: several cells, other kernels and `{keep, Reduced}`        *)
(* rewrites, the door's fold of an unapplied event, the frontier and its   *)
(* adoption, unroutable buckets, pending claims, nested sub-CRDTs, a crash  *)
(* that loses MST receipts.                                                 *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS
    Replicas,     \* replica ids, also used as origin ids
    MaxSeq,       \* events per origin
    MaxEvents,    \* events in all
    Stability,    \* "receipt" | "applied"
    Reap,         \* TRUE: retired origins are reaped from cell contexts
    MaxInstalls,  \* installs a behaviour may make
    InstallMode,  \* "join" | "replace" (the peer's cell, then a full
                  \* re-fold of the local MST onto it)
    HeldSweep,    \* TRUE: the sweep waits until the MST holds every event
                  \* whose effect the cell holds
    RetiredCovered, \* TRUE: the join counts a retired origin's dots as
                    \* covered by both contexts
    ClaimSkip,     \* TRUE: the replay skips an event the applied frontier
                   \* already claims, instead of re-folding it
    MaxCrashes,    \* crashes a behaviour may make
    CrashKeepsCell, \* TRUE: a crash keeps the cell as it was (the VM died,
                    \* the OS kept its buffers); FALSE: any state since the
                    \* last sync (the OS lost unsynced writes)
    DurableStability, \* TRUE: a discard needs every event the cell's
                      \* context covers claimed by every member's last
                      \* checkpoint, its own included
    RefoldFirst,   \* TRUE: after a crash, no local write folds before the
                   \* replay has re-folded every unclaimed own event
    HlcStability,  \* TRUE: the code's form of DurableStability, below
    HlcGuards,     \* the guards kept: "mark", "serve", "replayed", "target",
                   \* "busy", "early"
    CompactBy,     \* "none" | "receipt" | "durable": how compaction confirms
    RetiredExempt, \* TRUE: a retired origin's events count as confirmed by
                   \* every member, for truncation and for the bound
    Session,       \* TRUE: an install is the code's session; FALSE: one step
    SplitServe     \* TRUE: a session's source checks its serve guards only
                   \* when the session opens, and serves a batch before the
                   \* initiator marks itself

ASSUME /\ Stability \in {"receipt", "applied"}
       /\ MaxCrashes \in Nat
       /\ CrashKeepsCell \in BOOLEAN /\ DurableStability \in BOOLEAN
       /\ RefoldFirst \in BOOLEAN /\ HlcStability \in BOOLEAN
       /\ HlcGuards \subseteq {"mark", "serve", "replayed", "target", "busy",
                               "early"}
       /\ Session \in BOOLEAN
       /\ SplitServe \in BOOLEAN /\ SplitServe => Session
       /\ CompactBy \in {"none", "receipt", "durable"}
       /\ CompactBy # "none" => HlcStability
       /\ RetiredExempt \in BOOLEAN
       /\ Reap \in BOOLEAN /\ HeldSweep \in BOOLEAN
       /\ RetiredCovered \in BOOLEAN
       /\ ClaimSkip \in BOOLEAN
       /\ InstallMode \in {"join", "replace"}

VV == [Replicas -> 0..MaxSeq]
Zero == [o \in Replicas |-> 0]
Dot == [org : Replicas, seq : 1..MaxSeq]
Event == [org : Replicas, seq : 1..MaxSeq, add : BOOLEAN, ctx : VV]
Bottom == [dots |-> {}, cc |-> Zero]

Max2(a, b) == IF a > b THEN a ELSE b
VMax(a, b) == [o \in Replicas |-> Max2(a[o], b[o])]
Observed(d, v) == v[d.org] >= d.seq
DotOf(e) == [org |-> e.org, seq |-> e.seq]

\* The kernel step for one event (`apply_op/4`, guarded).
Step(c, e) ==
    IF Observed(DotOf(e), c.cc) THEN c
    ELSE [dots |-> {d \in c.dots : ~Observed(d, e.ctx)}
                     \cup (IF e.add THEN {DotOf(e)} ELSE {}),
          cc   |-> [VMax(c.cc, e.ctx) EXCEPT ![e.org] = Max2(@, e.seq)]]

\* The value a set of events folds to, independent of order: an add
\* survives when no event of the set observed it.
Present(c) == c.dots # {}
PresentFold(S) ==
    \E e \in S : e.add /\ ~\E f \in S : Observed(DotOf(e), f.ctx)

Join(a, b, gone) ==
    LET Cov(d, v) == Observed(d, v) \/ (RetiredCovered /\ d.org \in gone)
    IN [dots |-> (a.dots \cap b.dots)
                   \cup {d \in a.dots : ~Cov(d, b.cc)}
                   \cup {d \in b.dots : ~Cov(d, a.cc)},
        cc   |-> VMax(a.cc, b.cc)]

\* Folds a causally closed event set onto a state in some causal order; the
\* guarded kernel makes every such order agree.
RECURSIVE FoldAll(_, _)
FoldAll(c, S) ==
    IF S = {} THEN c
    ELSE LET e == CHOOSE x \in S :
                    \A y \in S : ~(y.org = x.org /\ y.seq < x.seq)
                                /\ ~(y.seq =< x.ctx[y.org])
         IN FoldAll(Step(c, e), S \ {e})

VARIABLES
    cell,     \* [Replica -> cell state]
    recv,     \* [Replica -> SUBSET Event]  events in the MST
    app,      \* [Replica -> SUBSET Event]  events whose effect the cell holds
    fold,     \* [Replica -> SUBSET Event]  events the replay has folded
    minted,   \* [Replica -> 0..MaxSeq]
    retired,  \* SUBSET Replicas
    installs,
    ckpt,     \* [Replica -> SUBSET Event]  claims the last checkpoint holds
    read,     \* [Replica -> SUBSET Event]  claims a checkpoint has read,
              \* awaiting its sync
    hist,     \* [Replica -> SUBSET cell state]  cells held since the sync
    ever,     \* [Replica -> SUBSET Event]  every claim the replica made
    crashes,
    order,    \* Seq(Dot): every dot in mint order, so its index is its HLC
    mark,     \* [Replica -> BOOLEAN]  the durable install mark
    fresh,    \* [Replica -> BOOLEAN]  a checkpoint read the install's claims
    live,     \* [Replica -> BOOLEAN]  the install's claims survive in memory
    cmp,      \* [Replica -> SUBSET Event]  events truncated from the MST
    step,     \* [Replica -> {"idle", "read", "begun", "installed", "adopted"}]
    speer,    \* [Replica -> Replicas \cup {"none"}]  the session's peer
    pend,     \* [Replica -> SUBSET Event]  the frontier the session read,
              \* then the one its claims must reach
    replayed, \* [Replica -> BOOLEAN]  the boot replay has run
    cur,      \* [Replica -> BOOLEAN]  the session's cursor at its source is open
    has,      \* [Replica -> BOOLEAN]  the session holds a batch not installed
    got       \* [Replica -> cell state]  that batch

svars == <<step, speer, pend, replayed, cur, has, got>>

hvars == <<order, mark, fresh, live, cmp, svars>>

vars == <<cell, recv, app, fold, minted, retired, installs,
          ckpt, read, hist, ever, crashes, hvars>>

AllEvents == UNION {recv[r] : r \in Replicas}

Init ==
    /\ cell = [r \in Replicas |-> Bottom]
    /\ recv = [r \in Replicas |-> {}]
    /\ app = [r \in Replicas |-> {}]
    /\ fold = [r \in Replicas |-> {}]
    /\ minted = [r \in Replicas |-> 0]
    /\ retired = {}
    /\ installs = 0
    /\ ckpt = [r \in Replicas |-> {}]
    /\ read = [r \in Replicas |-> {}]
    /\ hist = [r \in Replicas |-> {Bottom}]
    /\ ever = [r \in Replicas |-> {}]
    /\ crashes = 0
    /\ order = <<>>
    /\ mark = [r \in Replicas |-> FALSE]
    /\ fresh = [r \in Replicas |-> FALSE]
    /\ live = [r \in Replicas |-> FALSE]
    /\ cmp = [r \in Replicas |-> {}]
    /\ step = [r \in Replicas |-> "idle"]
    /\ speer = [r \in Replicas |-> "none"]
    /\ pend = [r \in Replicas |-> {}]
    /\ replayed = [r \in Replicas |-> TRUE]
    /\ cur = [r \in Replicas |-> FALSE]
    /\ has = [r \in Replicas |-> FALSE]
    /\ got = [r \in Replicas |-> Bottom]

(* A local write, folded on the WAL drain. Its context is the cell's.      *)
Mint(r, isAdd) ==
    /\ r \notin retired
    /\ minted[r] < MaxSeq
    /\ Cardinality(AllEvents) < MaxEvents
    /\ RefoldFirst => \A e \in recv[r] : e.org = r => e \in app[r]
    /\ isAdd \/ Present(cell[r])
    /\ LET e == [org |-> r, seq |-> minted[r] + 1, add |-> isAdd,
                 ctx |-> cell[r].cc]
       IN /\ cell' = [cell EXCEPT ![r] = Step(@, e)]
          /\ recv' = [recv EXCEPT ![r] = @ \cup {e}]
          /\ app' = [app EXCEPT ![r] = @ \cup {e}]
          /\ fold' = [fold EXCEPT ![r] = @ \cup {e}]
    /\ minted' = [minted EXCEPT ![r] = @ + 1]
    /\ order' = IF HlcStability
                  THEN Append(order, [org |-> r, seq |-> minted[r] + 1])
                  ELSE order
    /\ UNCHANGED <<retired, installs, mark, fresh, live, cmp, svars>>

(* An anti-entropy round merges the peer's whole MST, so what a replica   *)
(* has received is causally closed; a retired origin's events are refused. *)
Pull(r, p) ==
    /\ r # p
    /\ LET new == {e \in recv[p] \ (recv[r] \cup cmp[p]) :
                     e.org \notin retired}
       IN /\ new # {}
          /\ recv' = [recv EXCEPT ![r] = @ \cup new]
    /\ UNCHANGED <<cell, app, fold, minted, retired, installs, hvars>>

(* The replay folds each received event once, and causally: in per-origin *)
(* seq order, and only once every dot its context observed is applied      *)
(* (`bondy_oplog_cell_apply:partition_contiguous/4`, `causal_tops/4`); a  *)
(* retired origin's events never fold (`drop_retired/2`). An              *)
(* install does not move the replay cursor, so an event whose effect came *)
(* with the peer's cell is still folded, and the kernel skips it when the  *)
(* context covers its dot.                                                 *)
Foldable(r, e) ==
    /\ e \in recv[r] \ (fold[r] \cup cmp[r])
    /\ e.org \notin retired
    /\ \A s \in 1..(e.seq - 1) : \E f \in app[r] : f.org = e.org /\ f.seq = s
    /\ \A o \in Replicas \ retired :
         \A s \in 1..e.ctx[o] : \E f \in app[r] : f.org = o /\ f.seq = s

Apply(r, e) ==
    /\ Foldable(r, e)
    /\ cell' = [cell EXCEPT ![r] =
                   IF ClaimSkip /\ e \in app[r] THEN @ ELSE Step(@, e)]
    /\ app' = [app EXCEPT ![r] = @ \cup {e}]
    /\ fold' = [fold EXCEPT ![r] = @ \cup {e}]
    /\ UNCHANGED <<recv, minted, retired, installs, hvars>>

Claims(q) ==
    CASE DurableStability -> ckpt[q]
      [] MaxCrashes = 0   -> app[q]
      [] OTHER            -> ever[q]

Confirms(q, e) ==
    IF Stability = "receipt" THEN e \in recv[q] \/ e \in Claims(q)
    ELSE e \in Claims(q)

(* HlcStability is what the sweep can compute. The stable vector is the    *)
(* pointwise least of every member's checkpointed claims, its own included; *)
(* the bound is the HLC of the earliest event the replica claims above it.  *)
(* A cell below the bound reflects only events every member holds durably,  *)
(* because HLCs rise per origin. A cell's HLC is its highest covered dot's, *)
(* which lowers it after a reap. A durable mark, set when an install starts *)
(* and cleared only by a checkpoint that read the install's claims before   *)
(* any crash lost them, holds the sweep while the cell may hold effects no  *)
(* durable claim covers. A source serves only a cell whose every covered    *)
(* event it claims ("serve"), in the session's form below.                  *)
HlcOf(d) == CHOOSE i \in 1..Len(order) : order[i] = d
Top(S, o) == LET n == {e.seq : e \in {f \in S : f.org = o}}
             IN IF n = {} THEN 0 ELSE CHOOSE m \in n : \A k \in n : k =< m
StableVV == [o \in Replicas |->
               CHOOSE m \in {Top(ckpt[q], o) : q \in Replicas} :
                 \A q \in Replicas : m =< Top(ckpt[q], o)]
CellHlc(c) ==
    LET hs == {HlcOf([org |-> o, seq |-> c.cc[o]]) :
                 o \in {x \in Replicas : c.cc[x] > 0}}
    IN IF hs = {} THEN 0 ELSE CHOOSE m \in hs : \A k \in hs : k =< m
Bound(r) ==
    LET hs == {HlcOf(DotOf(e)) :
                 e \in {f \in app[r] \ cmp[r] :
                         /\ f.seq = StableVV[f.org] + 1
                         /\ ~(RetiredExempt /\ f.org \in retired)}}
    IN IF hs = {} THEN MaxEvents + 1
       ELSE CHOOSE m \in hs : \A k \in hs : m =< k

(* The sweep deletes an empty cell all of whose events every other member *)
(* confirms, after catching the replay up (I1, `ensure_remote_caught_up/1`*)
(* in the applier's sweep handler): only held events may remain unfolded.  *)
(* Between an install and its adoption the cell holds effects nothing      *)
(* claims, so the sweep waits: the mark, or the session's own step.        *)
Discard(r) ==
    /\ cell[r] # Bottom
    /\ ~\E e \in recv[r] : Foldable(r, e)
    /\ HeldSweep => app[r] \subseteq recv[r]
    /\ ~Present(cell[r])
    /\ CASE HlcStability ->
              /\ "mark" \in HlcGuards => ~mark[r]
              /\ CellHlc(cell[r]) < Bound(r)
         [] DurableStability ->
              /\ step[r] \in {"idle", "read"}
              /\ \A e \in AllEvents :
                   Observed(DotOf(e), cell[r].cc) =>
                       \A q \in Replicas : Confirms(q, e)
         [] OTHER ->
              /\ step[r] \in {"idle", "read"}
              /\ \A e \in app[r] : \A q \in Replicas \ {r} : Confirms(q, e)
    /\ cell' = [cell EXCEPT ![r] = Bottom]
    /\ UNCHANGED <<recv, app, fold, minted, retired, installs, hvars>>

(* The operator retires an origin that every replica has fully applied;   *)
(* with crashes, that every replica's checkpoint holds every event of it.  *)
Retire(o) ==
    /\ Reap
    /\ o \notin retired
    /\ \A q \in Replicas \ {o} :
         \A e \in AllEvents :
           e.org = o => e \in (IF MaxCrashes > 0 THEN ckpt[q] ELSE app[q])
    /\ retired' = retired \cup {o}
    /\ UNCHANGED <<cell, recv, app, fold, minted, installs, hvars>>

ReapCell(r, o) ==
    /\ o \in retired
    /\ r # o
    /\ cell[r].cc[o] # 0
    /\ HeldSweep => app[r] \subseteq recv[r]
    /\ ~\E d \in cell[r].dots : d.org = o
    /\ cell' = [cell EXCEPT ![r].cc[o] = 0]
    /\ UNCHANGED <<recv, app, fold, minted, retired, installs, hvars>>

(* An install in one step, of the peer's cell as it is now: joined, or     *)
(* replaced and then re-folded from the whole local MST (the rederive).    *)
(* Its serve guard is the property the session's guards are meant to give: *)
(* the source's cell covers only events it claims.                         *)
Install(r, p) ==
    /\ ~Session
    /\ installs < MaxInstalls
    /\ r # p
    /\ r \notin retired /\ p \notin retired
    /\ HlcStability /\ "serve" \in HlcGuards =>
         \A e \in AllEvents : Observed(DotOf(e), cell[p].cc) => e \in app[p]
    /\ IF InstallMode = "join"
         THEN /\ cell' = [cell EXCEPT ![r] = Join(@, cell[p], retired)]
              /\ app' = [app EXCEPT ![r] = @ \cup app[p]]
              /\ UNCHANGED fold
         ELSE /\ cell' = [cell EXCEPT ![r] = FoldAll(cell[p], recv[r])]
              /\ app' = [app EXCEPT ![r] = app[p] \cup recv[r]]
              /\ fold' = [fold EXCEPT ![r] = recv[r]]
    /\ installs' = installs + 1
    /\ mark' = [mark EXCEPT ![r] = HlcStability]
    /\ fresh' = [fresh EXCEPT ![r] = FALSE]
    /\ live' = [live EXCEPT ![r] = HlcStability]
    /\ UNCHANGED <<recv, minted, retired, order, cmp, svars>>

(* A session's source answers neither its frontier nor its cells while     *)
(* marked ("serve") or before its boot replay has run ("replayed").        *)
Serves(p) ==
    /\ p \notin retired
    /\ HlcStability /\ "serve" \in HlcGuards => ~mark[p]
    /\ HlcStability /\ "replayed" \in HlcGuards => replayed[p]

(* The session reads the peer's frontier (`request_peer_frontier/4`).      *)
ReadFrontier(r, p) ==
    /\ Session
    /\ installs < MaxInstalls
    /\ r # p
    /\ r \notin retired
    /\ Serves(p)
    /\ step' = [step EXCEPT ![r] = "read"]
    /\ speer' = [speer EXCEPT ![r] = p]
    /\ pend' = [pend EXCEPT ![r] = app[p]]
    /\ installs' = installs + 1
    /\ cur' = [cur EXCEPT ![r] = SplitServe]
    /\ has' = [has EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired,
                   order, mark, fresh, live, cmp, replayed, got>>

(* The source serves its cell as it is now, while the session's cursor is *)
(* open (`bondy_oplog_catalogue_snapshot:next/2`).                         *)
Fetch(r) ==
    /\ SplitServe
    /\ step[r] \in {"begun", "installed"}
    /\ cur[r] /\ ~has[r]
    /\ has' = [has EXCEPT ![r] = TRUE]
    /\ got' = [got EXCEPT ![r] = cell[speer[r]]]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   order, mark, fresh, live, cmp, step, speer, pend, replayed,
                   cur>>

(* Its sessions' cursors at r expire once r marks itself                   *)
(* (`bondy_oplog_catalogue_cursor:discard_instance/1`).                    *)
Expire(r) ==
    [q \in Replicas |-> IF speer[q] = r THEN FALSE ELSE cur[q]]

(* A replica serving an open cursor ("busy").                              *)
Busy(r) == \E q \in Replicas : speer[q] = r /\ cur[q]

(* Marks(r): the step that writes the mark, and expires r's sessions.      *)
Marks(r) ==
    /\ "busy" \in HlcGuards => ~Busy(r)
    /\ mark' = [mark EXCEPT ![r] = HlcStability]
    /\ fresh' = [fresh EXCEPT ![r] = FALSE]
    /\ live' = [live EXCEPT ![r] = FALSE]
    /\ cur' = IF SplitServe /\ HlcStability THEN Expire(r) ELSE cur

(* With SplitServe the session begins installing once it has opened, and   *)
(* before it asks for a batch; "early" writes the mark here, "busy" refuses *)
(* while the replica serves an open session of its own.                     *)
Begin(r) ==
    /\ SplitServe
    /\ step[r] = "read"
    /\ step' = [step EXCEPT ![r] = "begun"]
    /\ IF "early" \in HlcGuards THEN Marks(r)
       ELSE UNCHANGED <<mark, fresh, live, cur>>
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   order, cmp, speer, pend, replayed, has, got>>

(* With "busy", a session whose replica serves an open session ends before *)
(* writing the mark, and releases its own cursor at its source, so the two *)
(* sides of a mutual re-bootstrap do not hold each other busy.             *)
Refuse(r) ==
    /\ SplitServe
    /\ "busy" \in HlcGuards
    /\ step[r] = "read"
    /\ Busy(r)
    /\ step' = [step EXCEPT ![r] = "idle"]
    /\ speer' = [speer EXCEPT ![r] = "none"]
    /\ pend' = [pend EXCEPT ![r] = {}]
    /\ cur' = [cur EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   order, mark, fresh, live, cmp, replayed, has, got>>

(* It installs the peer's cell, after writing the mark: one the source     *)
(* serves now, or with SplitServe the batch it fetched.                    *)
InstallCell(r) ==
    /\ step[r] \in IF SplitServe THEN {"begun", "installed"}
                   ELSE {"read", "installed"}
    /\ IF SplitServe THEN has[r] ELSE Serves(speer[r])
    /\ LET src == IF SplitServe THEN got[r] ELSE cell[speer[r]]
       IN cell' = [cell EXCEPT ![r] =
                     IF InstallMode = "join" THEN Join(@, src, retired)
                     ELSE src]
    /\ step' = [step EXCEPT ![r] = "installed"]
    /\ IF SplitServe /\ "early" \in HlcGuards
         THEN UNCHANGED <<mark, fresh, live, cur>>
         ELSE Marks(r)
    /\ has' = [has EXCEPT ![r] = FALSE]
    /\ got' = [got EXCEPT ![r] = Bottom]
    /\ UNCHANGED <<recv, app, fold, minted, retired, installs,
                   order, cmp, speer, pend, replayed>>

(* At finalize it adopts the frontier it read, a lower bound for what the *)
(* cells reflect; "replace" re-folds first. It then reads the peer's      *)
(* frontier again, an upper bound, as the target its own claims must reach *)
(* (`bondy_oplog_instance:install_target/2`).                              *)
Adopt(r) ==
    /\ step[r] = "installed"
    /\ SplitServe => cur[r] /\ ~has[r]
    /\ Serves(speer[r])
    /\ IF InstallMode = "join"
         THEN /\ app' = [app EXCEPT ![r] = @ \cup pend[r]]
              /\ UNCHANGED <<cell, fold>>
         ELSE /\ cell' = [cell EXCEPT ![r] = FoldAll(@, recv[r])]
              /\ app' = [app EXCEPT ![r] = pend[r] \cup recv[r]]
              /\ fold' = [fold EXCEPT ![r] = recv[r]]
    /\ step' = [step EXCEPT ![r] = "adopted"]
    /\ pend' = [pend EXCEPT ![r] = app[speer[r]]]
    /\ cur' = [cur EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<recv, minted, retired, installs,
                   order, mark, fresh, live, cmp, speer, replayed, has, got>>

(* The install ends once the replica claims the target: every effect the   *)
(* cells took from the peer is then claimed here.                          *)
Settle(r) ==
    /\ step[r] = "adopted"
    /\ "target" \in HlcGuards => pend[r] \subseteq app[r]
    /\ live' = [live EXCEPT ![r] = HlcStability]
    /\ step' = [step EXCEPT ![r] = "idle"]
    /\ speer' = [speer EXCEPT ![r] = "none"]
    /\ pend' = [pend EXCEPT ![r] = {}]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   order, mark, fresh, cmp, replayed, cur, has, got>>

(* A session whose cursor expired fails, leaving the mark it wrote.        *)
Abort(r) ==
    /\ SplitServe
    /\ step[r] \in {"read", "begun", "installed"}
    /\ ~cur[r] /\ ~has[r]
    /\ step' = [step EXCEPT ![r] = "idle"]
    /\ speer' = [speer EXCEPT ![r] = "none"]
    /\ pend' = [pend EXCEPT ![r] = {}]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   order, mark, fresh, live, cmp, replayed, cur, has, got>>

(* The boot replay has run once nothing it could fold remains.             *)
Replayed(r) ==
    /\ ~replayed[r]
    /\ ~\E e \in recv[r] : Foldable(r, e)
    /\ replayed' = [replayed EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   order, mark, fresh, live, cmp, step, speer, pend,
                   cur, has, got>>

(* Truncates the MST up to an HLC every other member confirms, capped at   *)
(* the replica's own claims, after syncing the projection                  *)
(* (`truncate_below_or_equal/3`).                                          *)
Truncate(r) ==
    /\ CompactBy # "none"
    /\ \E k \in 1..Len(order) :
         LET T == {e \in recv[r] \ cmp[r] : HlcOf(DotOf(e)) =< k}
         IN /\ T # {}
            /\ T \subseteq app[r]
            /\ \A e \in T :
                 IF CompactBy = "durable"
                   THEN \/ RetiredExempt /\ e.org \in retired
                        \/ \A q \in Replicas : e \in ckpt[q]
                 ELSE \A q \in Replicas \ {r} :
                        e \in recv[q] \/ e \in Claims(q)
            /\ cmp' = [cmp EXCEPT ![r] = @ \cup T]

(* The compaction commit: the truncation, then a checkpoint of the claims  *)
(* (`finalize_catalogue_compaction_commit/6`).                              *)
Compact(r) ==
    /\ Truncate(r)
    /\ ckpt' = [ckpt EXCEPT ![r] = app[r]]
    /\ read' = [read EXCEPT ![r] = app[r]]
    /\ hist' = [hist EXCEPT ![r] = {cell[r]}]
    /\ fresh' = [fresh EXCEPT ![r] = live[r]]
    /\ mark' = [mark EXCEPT ![r] = @ /\ ~live[r]]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   ever, crashes, order, live, svars>>

(* The watermark door's truncation, with no checkpoint after it.          *)
Door(r) ==
    /\ Truncate(r)
    /\ hist' = [hist EXCEPT ![r] = {cell[r]}]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   ckpt, read, ever, crashes, order, mark, fresh, live,
                   svars>>

(* A checkpoint reads the claims; its sync later makes them durable along  *)
(* with the cell as it is at the sync.                                     *)
ReadClaims(r) ==
    /\ MaxCrashes > 0 \/ HlcStability
    /\ read' = [read EXCEPT ![r] = app[r]]
    /\ fresh' = [fresh EXCEPT ![r] = live[r]]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   ckpt, hist, ever, crashes, order, mark, live, cmp,
                   svars>>

Sync(r) ==
    /\ MaxCrashes > 0 \/ HlcStability
    /\ ckpt' = [ckpt EXCEPT ![r] = read[r]]
    /\ hist' = [hist EXCEPT ![r] = {cell[r]}]
    /\ mark' = [mark EXCEPT ![r] = @ /\ ~fresh[r]]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   read, ever, crashes, order, fresh, live, cmp, svars>>

Crash(r) ==
    /\ crashes < MaxCrashes
    /\ IF CrashKeepsCell THEN UNCHANGED cell
       ELSE \E c \in hist[r] : cell' = [cell EXCEPT ![r] = c]
    /\ app' = [app EXCEPT ![r] = ckpt[r]]
    /\ fold' = [fold EXCEPT ![r] = @ \cap ckpt[r]]
    /\ read' = [read EXCEPT ![r] = ckpt[r]]
    /\ crashes' = crashes + 1
    /\ fresh' = [fresh EXCEPT ![r] = FALSE]
    /\ live' = [live EXCEPT ![r] = FALSE]
    /\ LET ends(q) == \/ q = r
                      \/ speer[q] = r /\ step[q] \in {"read", "begun", "installed"}
       IN /\ step' = [q \in Replicas |-> IF ends(q) THEN "idle" ELSE step[q]]
          /\ speer' = [q \in Replicas |-> IF ends(q) THEN "none" ELSE speer[q]]
          /\ pend' = [q \in Replicas |-> IF ends(q) THEN {} ELSE pend[q]]
          /\ cur' = [q \in Replicas |-> IF ends(q) THEN FALSE ELSE cur[q]]
          /\ has' = [q \in Replicas |-> IF ends(q) THEN FALSE ELSE has[q]]
          /\ got' = [q \in Replicas |-> IF ends(q) THEN Bottom ELSE got[q]]
    /\ replayed' = [replayed EXCEPT ![r] =
                     ~(HlcStability /\ "replayed" \in HlcGuards)]
    /\ UNCHANGED <<recv, minted, retired, installs, ckpt, hist, ever,
                   order, mark, cmp>>

\* Every other step records the cell it leaves and the claims it makes.
Tracked(A) ==
    /\ A
    /\ IF MaxCrashes = 0
         THEN UNCHANGED <<ckpt, read, hist, ever, crashes>>
         ELSE /\ hist' = [r \in Replicas |-> hist[r] \cup {cell'[r]}]
              /\ ever' = [r \in Replicas |-> ever[r] \cup app'[r]]
              /\ UNCHANGED <<ckpt, read, crashes>>

Next ==
    \/ Tracked(\E r \in Replicas, b \in BOOLEAN : Mint(r, b))
    \/ Tracked(\E r, p \in Replicas : Pull(r, p))
    \/ Tracked(\E r \in Replicas, e \in AllEvents : Apply(r, e))
    \/ Tracked(\E r \in Replicas : Discard(r))
    \/ Tracked(\E o \in Replicas : Retire(o))
    \/ Tracked(\E r, o \in Replicas : ReapCell(r, o))
    \/ Tracked(\E r, p \in Replicas : Install(r, p) \/ ReadFrontier(r, p))
    \/ Tracked(\E r \in Replicas : InstallCell(r) \/ Adopt(r)
                                         \/ Settle(r) \/ Replayed(r)
                                         \/ Fetch(r) \/ Abort(r) \/ Begin(r)
                                         \/ Refuse(r))
    \/ \E r \in Replicas : ReadClaims(r) \/ Sync(r) \/ Crash(r)
                            \/ Compact(r) \/ Door(r)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* Once a replica has received every event and folded each one, its value is
\* the fold of them all.
Settled(r) ==
    /\ \A e \in AllEvents : e.org \notin retired => e \in recv[r]
    /\ recv[r] \ cmp[r] \subseteq fold[r]
SettledSound ==
    \A r \in Replicas \ retired :
        Settled(r) => Present(cell[r]) = PresentFold(AllEvents)

\* Some replica can still serve a session or clear its mark: one is
\* unmarked, its install's claims survive in memory, or it has adopted.
Owes(r) == mark[r] /\ ~live[r] /\ step[r] # "adopted"
SomeoneServes == ~\A r \in Replicas \ retired : Owes(r)

\* A truncated event stays claimed: nothing re-presents it, and its origin's
\* later events fold only after it (the contiguity hold).
CompactedClaimed == \A r \in Replicas : cmp[r] \subseteq app[r]

=============================================================================
