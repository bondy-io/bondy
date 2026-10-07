------------------------------ MODULE JoinInstall ------------------------------
(***************************************************************************)
(* THIS WAS BUILT BY CLAUDE OPUS and it is not verified.                   *)
(*                                                                         *)
(* Can the catalogue install, a session that stages the source's cells and *)
(* swaps them in at its re-fold, leave a cell other than the fold of every *)
(* event, once cells are deleted by the stabilization sweep, truncated by  *)
(* compaction, or reaped of a retired origin? And can a replica's          *)
(* truncation record strand another member once clustering is turned off  *)
(* and on, or a member leaves and returns?                                 *)
(*                                                                         *)
(* What the code does, established by reading it:                          *)
(*                                                                         *)
(*   - An add-wins cell is `{Dots, Context, Hlc}`: the surviving dots and  *)
(*     a version vector (`bondy_oplog_crdt_aw_core`). An op drops the dots *)
(*     its stamped context observed, adds its own dot when it is an add,   *)
(*     and max-merges its context and dot into the cell's                  *)
(*     (`cc_absorb/3`). The kernel skips an event whose dot the context    *)
(*     already covers (`bondy_oplog_cell_kernel:apply/6`). Remote events   *)
(*     fold in per-origin seq order (the contiguity hold).                 *)
(*   - A remote event enters the MST on receipt and reaches the cell on a  *)
(*     later replay (`deliver_remote/1` casts `replay_cell_events`). The   *)
(*     replay skips an event the applied frontier already claims           *)
(*     (`bondy_oplog_cell_apply:drop_claimed/2`); it assumes the frontier  *)
(*     claims only what the cell reflects                                  *)
(*     (`LiveRebootstrapRefold.ClaimSound`).                               *)
(*   - The stabilization sweep deletes an empty flag cell whose HLC is     *)
(*     below the stability point (`bondy_oplog_crdt_ew_flag:stabilize/2`,  *)
(*     `bondy_oplog_cell_utils:apply_stabilize/10`): the HLC of the last   *)
(*     key of the replica's tree before the first key that some member's   *)
(*     durable frontier, its own included, does not cover                  *)
(*     (`bondy_oplog_instance:compute_frontier_for/2`, `member_vvs/2`).    *)
(*     Bound below stands in for it: the HLC of the earliest event the     *)
(*     replica claims above the pointwise least of the durable claims.     *)
(*   - `reap_origins/2` drops a retired origin's context entry when no     *)
(*     surviving dot is that origin's (`bondy_oplog_crdt_aw_set`).         *)
(*                                                                         *)
(* An install is the code's session (`do_bootstrap_snapshot/6`): it reads  *)
(* the peer's frontier, then streams the peer's cells as they are at that  *)
(* later moment (a live range scan of its projection), and adopts the      *)
(* frontier it read at its rederive, which re-folds only the MST events    *)
(* that frontier does not claim. With "coverbegin" the session begins only *)
(* when that frontier claims every event whose truncation the replica      *)
(* recorded, before it writes its mark, so a refused session ends unmarked.*)
(* A crash, which here is a node's, ends a stream (the cursor table lives  *)
(* in node memory). The source checks its serve guards when the session    *)
(* opens (`bondy_oplog_catalogue_snapshot:init/1`), serves each batch      *)
(* while the cursor is open, and expires the cursor when it marks itself;  *)
(* a session whose cursor expired fails. Invariant SomeoneServes asks that *)
(* some replica can still serve or clear its mark, which no bound on       *)
(* installs can supply once every replica owes one.                        *)
(* A session is a process apart from its replica (`bondy_oplog_sync_session`*)
(* spawns it): a crash may leave one that has re-derived running, and a     *)
(* session may begin while an earlier one is past its rederive. That one    *)
(* goes on detached (`det`) and its finalize and target reach the replica,  *)
(* unless "token": the replica refuses a session whose install token it no  *)
(* longer holds.                                                            *)
(* InstallMode = "stage" is the code's: the session writes the peer's      *)
(* cells aside and the rederive swaps them in, in the same step as its     *)
(* re-fold, so no fold lands on an installed cell. "replace" writes them   *)
(* over the local cells and re-folds later, the ablation of staging.       *)
(* Retirement is granted only once every replica has applied every event   *)
(* of the origin, the operator's obligation.                               *)
(*                                                                         *)
(* MaxCrashes > 0 adds crashes. A checkpoint reads the claims, then syncs   *)
(* the projection (`write_frontier_checkpoint/2`); a crash keeps the MST    *)
(* and the minted counter, restores the claims the last checkpoint read     *)
(* (`boot_frontier/2`), and leaves the cell in any state it held since that *)
(* sync: the sweep's delete and every fold are acknowledged before they are *)
(* durable. The replay then re-presents every unclaimed received event.     *)
(*                                                                         *)
(* CompactBy # "none" adds compaction (`do_finalize_catalogue_compaction/4`):*)
(* it syncs the projection, truncates a key-order prefix of the MST that    *)
(* every other member confirms and the replica's prefix claims             *)
(* (`capped_truncation_point/2`), then checkpoints. The watermark door     *)
(* truncates the same way with no checkpoint after (`watermark_door/2`), so *)
(* any step, a crash included, may follow a truncation. "members" is the   *)
(* code's: every other member confirms by its claims                       *)
(* (`compaction_witnesses/1`). The ablations: "receipt" (a root, or a      *)
(* reported claim); "durable", every member, the replica included, by its  *)
(* checkpointed claims; "recorded", some set of the other members, as a    *)
(* recency filter on the members would; "own", none, as a retention policy *)
(* would. Guard "trunc" holds every truncation while the replica holds the *)
(* mark. A truncated event is never served nor re-presented, and the       *)
(* bound's walk over the MST does not see it. A truncation records its     *)
(* events before it cuts them (Reserve, Cut); "floor" makes every restore  *)
(* of the claims keep the recorded events, which the replica's cells       *)
(* reflect since the record followed a projection sync.                    *)
(*                                                                         *)
(* NOT modelled: several cells, other kernels and `{keep, Reduced}`        *)
(* rewrites, the door's fold of an unapplied event, unroutable buckets,    *)
(* pending claims, nested sub-CRDTs, a crash that loses MST receipts.      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Replicas,     \* replica ids, also used as origin ids
    MaxSeq,       \* events per origin
    MaxEvents,    \* events in all
    Reap,         \* TRUE: retired origins are reaped from cell contexts
    MaxInstalls,  \* installs a behaviour may make
    InstallMode,  \* "stage" | "replace"
    MaxCrashes,    \* crashes a behaviour may make
    RefoldFirst,   \* TRUE: after a crash, no local write folds before the
                   \* replay has re-folded every unclaimed own event
    HlcGuards,     \* the guards kept: "mark", "serve", "replayed", "target",
                   \* "busy", "early", "token", "trunc", "coverbegin",
                   \* "floor", "solo", "soloclean", "leave", "kept"
    CompactBy,     \* "none" | "receipt" | "durable" | "recorded" | "own" |
                   \* "members":
                   \* how compaction confirms
    RetiredExempt  \* TRUE: a retired origin's events count as confirmed by
                   \* every member, for truncation and for the bound

ASSUME /\ MaxCrashes \in Nat
       /\ RefoldFirst \in BOOLEAN
       /\ HlcGuards \subseteq {"mark", "serve", "replayed", "target", "busy",
                               "early", "token", "trunc", "coverbegin",
                               "floor", "solo", "soloclean", "leave", "kept"}
       /\ CompactBy \in {"none", "receipt", "durable", "recorded", "own",
                         "members"}
       /\ RetiredExempt \in BOOLEAN
       /\ Reap \in BOOLEAN
       /\ InstallMode \in {"replace", "stage"}

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
    rsv,      \* [Replica -> SUBSET Event]  events a truncation will cut
    tv,       \* [Replica -> SUBSET Event]  the truncation record: every
              \* event a truncation may have cut, or will
    joined,   \* [Replica -> {"solo", "in", "alone", "back"}]  alone
              \* before any Merge, a member, alone after being one, or a
              \* member again
    step,     \* [Replica -> {"idle", "read", "begun", "installed",
              \*               "rederived", "targeted", "adopted"}]
    speer,    \* [Replica -> Replicas \cup {"none"}]  the session's peer
    pend,     \* [Replica -> SUBSET Event]  the frontier the session read,
              \* then the one its claims must reach
    replayed, \* [Replica -> BOOLEAN]  the boot replay has run
    cur,      \* [Replica -> BOOLEAN]  the session's cursor at its source is open
    has,      \* [Replica -> BOOLEAN]  the session holds a batch not installed
    got,      \* [Replica -> cell state]  that batch
    tgt,      \* [Replica -> SUBSET Event]  the target a session read
    dirty,    \* [Replica -> BOOLEAN]  a replace wrote a cell no rederive has
              \* re-folded since
    stg,      \* [Replica -> cell state]  the cell a "stage" session staged,
              \* Bottom when none
    det       \* [Replica -> session]  a detached session past its rederive

svars == <<step, speer, pend, replayed, cur, has, got, tgt, dirty, stg, det>>

\* Guards "solo" and "soloclean" start every replica alone, its own cluster
\* (`cluster.enabled = off`), until a Merge: at any time, or only while at
\* most one replica has truncated (`CleanJoin`, which with "leave" also
\* holds a Rejoin).
Solo == HlcGuards \cap {"solo", "soloclean"}

\* A member, which shares state with the other members. With "kept" the
\* members still count one that went alone without a Partisan leave.
In(r) == joined[r] \in {"in", "back"}
Counted(q) == In(q) \/ ("kept" \in HlcGuards /\ joined[q] = "alone")
Linked(r, p) == In(r) /\ In(p)

hvars == <<order, mark, fresh, live, cmp, rsv, tv, joined, svars>>

vars == <<cell, recv, app, fold, minted, retired, installs,
          ckpt, read, hist, ever, crashes, hvars>>

AllEvents == UNION {recv[r] : r \in Replicas}

\* A replica's session: its own (z = FALSE) or the detached one (z = TRUE).
Idle == [st |-> "idle", peer |-> "none", pend |-> {}, tgt |-> {}]
Sess(r, z) ==
    IF z THEN det[r]
    ELSE [st |-> step[r], peer |-> speer[r], pend |-> pend[r], tgt |-> tgt[r]]
SetSess(r, z, s) ==
    IF z THEN /\ det' = [det EXCEPT ![r] = s]
              /\ UNCHANGED <<step, speer, pend, tgt>>
    ELSE /\ step' = [step EXCEPT ![r] = s.st]
         /\ speer' = [speer EXCEPT ![r] = s.peer]
         /\ pend' = [pend EXCEPT ![r] = s.pend]
         /\ tgt' = [tgt EXCEPT ![r] = s.tgt]
         /\ UNCHANGED det
Rederived(st) == st \in {"rederived", "targeted", "adopted"}
\* The replica takes a finalize or a target from a detached session only
\* without "token".
Holds(z) == z => "token" \notin HlcGuards

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
    /\ rsv = [r \in Replicas |-> {}]
    /\ tv = [r \in Replicas |-> {}]
    /\ joined = [r \in Replicas |-> IF Solo = {} THEN "in" ELSE "solo"]
    /\ step = [r \in Replicas |-> "idle"]
    /\ speer = [r \in Replicas |-> "none"]
    /\ pend = [r \in Replicas |-> {}]
    /\ replayed = [r \in Replicas |-> TRUE]
    /\ cur = [r \in Replicas |-> FALSE]
    /\ has = [r \in Replicas |-> FALSE]
    /\ got = [r \in Replicas |-> Bottom]
    /\ tgt = [r \in Replicas |-> {}]
    /\ dirty = [r \in Replicas |-> FALSE]
    /\ stg = [r \in Replicas |-> Bottom]
    /\ det = [r \in Replicas |-> Idle]

(* A local write, folded on the WAL drain. Its context is the cell's as   *)
(* the writer reads it. The write is accepted either way; it folds at once *)
(* only when the drain may fold (FoldsNow), and otherwise later, on the    *)
(* replay that re-presents it.                                             *)
(* RefoldFirst: the drain folds nothing before the boot replay has folded  *)
(* the replica's own events (`bondy_oplog_applier` `start_folding`).       *)
FoldsNow(r) ==
    RefoldFirst => \A e \in recv[r] : e.org = r => e \in app[r]

Mint(r, isAdd) ==
    /\ r \notin retired
    /\ minted[r] < MaxSeq
    /\ Cardinality(AllEvents) < MaxEvents
    /\ isAdd \/ Present(cell[r])
    /\ LET e == [org |-> r, seq |-> minted[r] + 1, add |-> isAdd,
                 ctx |-> cell[r].cc]
       IN IF FoldsNow(r)
            THEN /\ cell' = [cell EXCEPT ![r] = Step(@, e)]
                 /\ recv' = [recv EXCEPT ![r] = @ \cup {e}]
                 /\ app' = [app EXCEPT ![r] = @ \cup {e}]
                 /\ fold' = [fold EXCEPT ![r] = @ \cup {e}]
            ELSE /\ recv' = [recv EXCEPT ![r] = @ \cup {e}]
                 /\ UNCHANGED <<cell, app, fold>>
    /\ minted' = [minted EXCEPT ![r] = @ + 1]
    /\ order' = Append(order, [org |-> r, seq |-> minted[r] + 1])
    /\ UNCHANGED <<retired, installs, mark, fresh, live, cmp, rsv, tv, joined, svars>>

(* An anti-entropy round merges the peer's whole MST, so what a replica   *)
(* has received is causally closed; a retired origin's events are refused. *)
Pull(r, p) ==
    /\ r # p
    /\ Linked(r, p)
    /\ LET new == {e \in recv[p] \ (recv[r] \cup cmp[p]) :
                     e.org \notin retired}
       IN /\ new # {}
          /\ recv' = [recv EXCEPT ![r] = @ \cup new]
    /\ UNCHANGED <<cell, app, fold, minted, retired, installs, hvars>>

(* The replay folds each received event once, and causally: in per-origin *)
(* seq order, and only once every dot its context observed is applied      *)
(* (the replica's own events are never held, for contiguity or context,  *)
(* and fold in seq order: `partition_contiguous/4` and                     *)
(* `unapplied_contexts/3` drop the local origin)                           *)
(* (`bondy_oplog_cell_apply:partition_contiguous/4`, `causal_tops/4`); a  *)
(* retired origin's events never fold (`drop_retired/2`). An              *)
(* install does not move the replay cursor, so an event whose effect came *)
(* with the peer's cell is still folded, and the kernel skips it when the  *)
(* context covers its dot.                                                 *)
Foldable(r, e) ==
    /\ e \in recv[r] \ (fold[r] \cup cmp[r])
    /\ e.org \notin retired
    /\ IF e.org = r
         THEN \A f \in recv[r] \ cmp[r] : f.org = r /\ f.seq < e.seq => f \in app[r]
         ELSE /\ \A s \in 1..(e.seq - 1) :
                   \E f \in app[r] : f.org = e.org /\ f.seq = s
              /\ \A o \in Replicas \ retired :
                   \A s \in 1..e.ctx[o] : \E f \in app[r] : f.org = o /\ f.seq = s

Apply(r, e) ==
    /\ Foldable(r, e)
    /\ cell' = [cell EXCEPT ![r] = IF e \in app[r] THEN @ ELSE Step(@, e)]
    /\ app' = [app EXCEPT ![r] = @ \cup {e}]
    /\ fold' = [fold EXCEPT ![r] = @ \cup {e}]
    /\ UNCHANGED <<recv, minted, retired, installs, hvars>>

(* What a replica's last checkpoint claims durably: nothing while it holds *)
(* the install mark, since a checkpoint written under the mark restores an  *)
(* empty frontier (`bondy_oplog_instance:restored_frontier/1`). With        *)
(* "floor" it also claims every event whose truncation it recorded, which a *)
(* record written before the cut makes durable.                           *)
Recorded(q) == tv[q]

Members(r) == IF In(r) THEN {q \in Replicas \ {r} : Counted(q)} ELSE {}
Floor(q) == IF "floor" \in HlcGuards THEN Recorded(q) ELSE {}
DurClaims(q) == (IF mark[q] THEN {} ELSE ckpt[q]) \cup Floor(q)

\* A peer confirms anything it ever claimed: a recorded report is replaced
\* only by the next round's (`bondy_oplog_peer_state`), so a stale one
\* outlives the peer's crash.
Claims(q) == IF MaxCrashes = 0 THEN app[q] ELSE ever[q]

(* The sweep's stability point. The stable vector is the pointwise least   *)
(* of every member's checkpointed claims, its own included; the bound is   *)
(* the HLC of the earliest event the replica claims above it. A cell below *)
(* the bound reflects only events every member holds durably, because HLCs *)
(* rise per origin. A cell's HLC is its highest covered dot's, which lowers *)
(* it after a reap. A durable mark, set when an install starts and cleared *)
(* only by a checkpoint that read the install's claims before any crash    *)
(* lost them, holds the sweep while the cell may hold effects no durable   *)
(* claim covers.                                                           *)
HlcOf(d) == CHOOSE i \in 1..Len(order) : order[i] = d
Top(S, o) == LET n == {e.seq : e \in {f \in S : f.org = o}}
             IN IF n = {} THEN 0 ELSE CHOOSE m \in n : \A k \in n : k =< m
StableVV == [o \in Replicas |->
               CHOOSE m \in {Top(DurClaims(q), o) : q \in Replicas} :
                 \A q \in Replicas : m =< Top(DurClaims(q), o)]
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

(* The sweep deletes an empty cell below the bound, after catching the     *)
(* replay up (I1, `ensure_remote_caught_up/1` in the applier's sweep       *)
(* handler): only held events may remain unfolded. It waits while the      *)
(* replica holds the mark ("mark").                                        *)
Discard(r) ==
    /\ cell[r] # Bottom
    /\ ~\E e \in recv[r] : Foldable(r, e)
    /\ ~Present(cell[r])
    /\ "mark" \in HlcGuards => ~mark[r]
    /\ CellHlc(cell[r]) < Bound(r)
    /\ cell' = [cell EXCEPT ![r] = Bottom]
    /\ UNCHANGED <<recv, app, fold, minted, retired, installs, hvars>>

(* The operator retires an origin that every replica has fully applied;   *)
(* with crashes, that every replica's checkpoint holds every event of it.  *)
Retire(o) ==
    /\ Reap
    /\ o \notin retired
    /\ \A q \in Replicas \ {o} :
         \A e \in AllEvents :
           e.org = o => e \in (IF MaxCrashes > 0 THEN DurClaims(q) ELSE app[q])
    /\ retired' = retired \cup {o}
    /\ UNCHANGED <<cell, recv, app, fold, minted, installs, hvars>>

ReapCell(r, o) ==
    /\ o \in retired
    /\ r # o
    /\ cell[r].cc[o] # 0
    /\ ~\E d \in cell[r].dots : d.org = o
    /\ cell' = [cell EXCEPT ![r].cc[o] = 0]
    /\ UNCHANGED <<recv, app, fold, minted, retired, installs, hvars>>

(* A session's source answers neither its frontier nor its cells while     *)
(* marked ("serve") or before its boot replay has run ("replayed").        *)
Serves(p) ==
    /\ p \notin retired
    /\ "serve" \in HlcGuards => ~mark[p]
    /\ "replayed" \in HlcGuards => replayed[p]

(* The session reads the peer's frontier (`request_peer_frontier/4`).      *)
ReadFrontier(r, p) ==
    /\ Linked(r, p)
    /\ installs < MaxInstalls
    /\ r # p
    /\ r \notin retired
    /\ Serves(p)
    /\ step' = [step EXCEPT ![r] = "read"]
    /\ speer' = [speer EXCEPT ![r] = p]
    /\ pend' = [pend EXCEPT ![r] = app[p]]
    /\ installs' = installs + 1
    /\ cur' = [cur EXCEPT ![r] = TRUE]
    /\ has' = [has EXCEPT ![r] = FALSE]
    /\ det' = [det EXCEPT ![r] = IF Rederived(step[r]) THEN Sess(r, FALSE) ELSE @]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired,
                   order, mark, fresh, live, cmp, rsv, tv, joined, replayed, got, tgt, dirty, stg>>

(* The source serves its cell as it is now, while the session's cursor is *)
(* open (`bondy_oplog_catalogue_snapshot:next/2`).                         *)
Fetch(r) ==
    /\ step[r] \in {"begun", "installed"}
    /\ cur[r] /\ ~has[r]
    /\ has' = [has EXCEPT ![r] = TRUE]
    /\ got' = [got EXCEPT ![r] = cell[speer[r]]]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   order, mark, fresh, live, cmp, rsv, tv, joined, step, speer, pend, replayed,
                   cur, tgt, dirty, stg, det>>

(* Its sessions' cursors at r expire once r marks itself                   *)
(* (`bondy_oplog_catalogue_cursor:discard_instance/1`).                    *)
Expire(r) ==
    [q \in Replicas |-> IF speer[q] = r THEN FALSE ELSE cur[q]]

(* A replica serving an open cursor ("busy").                              *)
Busy(r) == \E q \in Replicas : speer[q] = r /\ cur[q]

(* Marks(r): the step that writes the mark, and expires r's sessions.      *)
Marks(r) ==
    /\ "busy" \in HlcGuards => ~Busy(r)
    /\ mark' = [mark EXCEPT ![r] = TRUE]
    /\ fresh' = [fresh EXCEPT ![r] = FALSE]
    /\ live' = [live EXCEPT ![r] = FALSE]
    /\ cur' = Expire(r)

(* The session begins installing once it has opened, and before it asks   *)
(* for a batch; "early" writes the mark here, "busy" refuses while the     *)
(* replica serves an open session of its own.                              *)
Begin(r) ==
    /\ step[r] = "read"
    /\ "coverbegin" \in HlcGuards => Recorded(r) \subseteq pend[r]
    /\ step' = [step EXCEPT ![r] = "begun"]
    /\ IF "early" \in HlcGuards THEN Marks(r)
       ELSE UNCHANGED <<mark, fresh, live, cur>>
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   order, cmp, rsv, tv, joined, speer, pend, replayed, has, got, tgt, dirty, det>>
    /\ stg' = [stg EXCEPT ![r] = Bottom]

(* With "busy", a session whose replica serves an open session ends before *)
(* writing the mark, and releases its own cursor at its source, so the two *)
(* sides of a mutual re-bootstrap do not hold each other busy.             *)
Refuse(r) ==
    /\ "busy" \in HlcGuards
    /\ step[r] = "read"
    /\ Busy(r)
    /\ step' = [step EXCEPT ![r] = "idle"]
    /\ speer' = [speer EXCEPT ![r] = "none"]
    /\ pend' = [pend EXCEPT ![r] = {}]
    /\ cur' = [cur EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   order, mark, fresh, live, cmp, rsv, tv, joined, replayed, has, got, tgt, dirty, stg,
                   det>>

(* A replace writes only a cell the source holds: a discarded cell is a    *)
(* deleted row, which the range scan does not return                       *)
(* (`bondy_oplog_projection_ets:range/5`, `bondy_oplog_applier:install_cell/5`).*)
(* A stage is meant to install the snapshot whole, a row it lacks as an    *)
(* absent cell, since the frontier it adopts claims that cell's events.    *)
(* It installs the batch it fetched, after writing the mark.               *)
InstallCell(r) ==
    /\ step[r] \in {"begun", "installed"}
    /\ has[r]
    /\ LET src == got[r]
       IN /\ cell' = [cell EXCEPT ![r] =
                        IF InstallMode = "stage" \/ src = Bottom THEN @
                        ELSE src]
          /\ stg' = [stg EXCEPT ![r] =
                        IF InstallMode = "stage" THEN src ELSE @]
    /\ step' = [step EXCEPT ![r] = "installed"]
    /\ IF "early" \in HlcGuards
         THEN UNCHANGED <<mark, fresh, live, cur>>
         ELSE Marks(r)
    /\ has' = [has EXCEPT ![r] = FALSE]
    /\ got' = [got EXCEPT ![r] = Bottom]
    /\ UNCHANGED <<recv, app, fold, minted, retired, installs,
                   order, cmp, rsv, tv, joined, speer, pend, replayed, tgt, det>>
    /\ dirty' = [dirty EXCEPT ![r] = @ \/ InstallMode = "replace"]

(* The session adopted the frontier it read at its rederive; finalize      *)
(* records the target it read after.                                       *)
Adopt(r, z) ==
    LET s == Sess(r, z)
    IN /\ Holds(z)
       /\ s.st = "targeted"
       /\ UNCHANGED app
       /\ SetSess(r, z, [s EXCEPT !.st = "adopted", !.pend = s.tgt])
       /\ cur' = IF z THEN cur ELSE [cur EXCEPT ![r] = FALSE]
       /\ UNCHANGED <<cell, fold, recv, minted, retired, installs,
                      order, mark, fresh, live, cmp, rsv, tv, joined, replayed, has, got,
                      dirty, stg>>

(* The session re-derives once the stream has ended: the claims become F, *)
(* the frontier the session read, and the MST events F does not claim are *)
(* folded onto the installed cells; a truncated event is no longer there  *)
(* to fold, nor is a recorded one the re-fold reads after its cut (X): the *)
(* truncation runs in another process. An abort's re-fold has F the        *)
(* floor. The call folds the replica's own events before it returns, since *)
(* the hold never holds them. It holds a remote event until every          *)
(* dependency is claimed or folded; the own events the batch folds count   *)
(* for nothing (`bondy_oplog_cell_apply:partition_contiguous/4`). Apply    *)
(* folds a held event on a later replay.                                   *)
OwnLeft(r) == {e \in recv[r] \ cmp[r] : e.org = r}
Closed(R, B) ==
    \A e \in R :
        /\ \A s \in 1..(e.seq - 1) : \E f \in R \cup B : f.org = e.org /\ f.seq = s
        /\ \A o \in Replicas \ retired : \A s \in 1..e.ctx[o] :
             \E f \in R \cup B : f.org = o /\ f.seq = s
ReadyRemote(r, F) ==
    UNION {R \in SUBSET {e \in recv[r] \ (cmp[r] \cup F) :
                           e.org # r /\ e.org \notin retired} :
             Closed(R, F)}
Refold(r, base, F, X) ==
    LET S == ((OwnLeft(r) \ F) \cup ReadyRemote(r, F)) \ X
    IN /\ cell' = [cell EXCEPT ![r] = FoldAll(base, S)]
       /\ stg' = [stg EXCEPT ![r] = Bottom]
       /\ app' = [app EXCEPT ![r] = F \cup S]
       /\ fold' = [fold EXCEPT ![r] = S]
Rederive(r) ==
    /\ step[r] = "installed"
    /\ cur[r] /\ ~has[r]
    /\ step' = [step EXCEPT ![r] = "rederived"]
    /\ \E X \in SUBSET rsv[r] :
         Refold(r, IF InstallMode = "stage" THEN stg[r] ELSE cell[r],
                pend[r], X)
    /\ cur' = [cur EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<recv, minted, retired, installs,
                   order, mark, fresh, live, cmp, rsv, tv, joined, speer, pend, replayed, has,
                   got, tgt, det>>
    /\ dirty' = [dirty EXCEPT ![r] = FALSE]

(* It then reads the source's frontier, the target, which the source       *)
(* answers only while it serves (`fetch_peer_frontiers/4`).                *)
ReadTarget(r, z) ==
    LET s == Sess(r, z)
    IN /\ s.st = "rederived"
       /\ Serves(s.peer)
       /\ SetSess(r, z, [s EXCEPT !.st = "targeted", !.tgt = app[s.peer]])
       /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                      order, mark, fresh, live, cmp, rsv, tv, joined, replayed, cur,
                      has, got, dirty, stg>>

(* A session can fail after its rederive, on any transport error, keeping  *)
(* the mark.                                                               *)
FailRederived(r, z) ==
    /\ Sess(r, z).st \in {"rederived", "targeted"}
    /\ SetSess(r, z, Idle)
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   order, mark, fresh, live, cmp, rsv, tv, joined, replayed, cur, has, got, dirty, stg>>

(* The install ends once the replica claims the target: every effect the   *)
(* cells took from the peer is then claimed here.                          *)
Settle(r, z) ==
    LET s == Sess(r, z)
    IN /\ Holds(z)
       /\ s.st = "adopted"
       /\ "target" \in HlcGuards => s.pend \subseteq app[r]
       /\ live' = [live EXCEPT ![r] = TRUE]
       /\ SetSess(r, z, Idle)
       /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                      order, mark, fresh, cmp, rsv, tv, joined, replayed, cur, has, got, dirty, stg>>

(* A session whose cursor expired fails, leaving the mark it wrote; a      *)
(* marked replace re-derives; a stage only drops what it staged, as its   *)
(* cell and claims are untouched (`bondy_oplog_instance:abort_install/2`). *)
(* A stage session can also fail at any point, on any transport error,    *)
(* releasing its cursor and the batch it holds.                           *)
Abort(r) ==
    /\ step[r] \in {"read", "begun", "installed"}
    /\ InstallMode = "stage" \/ (~cur[r] /\ ~has[r])
    /\ step' = [step EXCEPT ![r] = "idle"]
    /\ speer' = [speer EXCEPT ![r] = "none"]
    /\ pend' = [pend EXCEPT ![r] = {}]
    /\ cur' = [cur EXCEPT ![r] = FALSE]
    /\ has' = [has EXCEPT ![r] = FALSE]
    /\ got' = [got EXCEPT ![r] = Bottom]
    /\ CASE InstallMode = "replace" /\ mark[r] ->
              /\ Refold(r, cell[r], Floor(r), {})
              /\ dirty' = [dirty EXCEPT ![r] = FALSE]
         [] InstallMode = "stage" ->
              /\ stg' = [stg EXCEPT ![r] = Bottom]
              /\ UNCHANGED <<cell, app, fold, dirty>>
         [] OTHER -> UNCHANGED <<cell, app, fold, dirty, stg>>
    /\ UNCHANGED <<recv, minted, retired, installs,
                   order, mark, fresh, live, cmp, rsv, tv, joined, replayed, tgt, det>>

(* The boot replay has run once nothing it could fold remains.             *)
Replayed(r) ==
    /\ ~replayed[r]
    /\ ~\E e \in recv[r] : Foldable(r, e)
    /\ replayed' = [replayed EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   order, mark, fresh, live, cmp, rsv, tv, joined, step, speer, pend,
                   cur, has, got, tgt, dirty, stg, det>>

(* A truncation is two steps, so a re-derive can run between them: it     *)
(* syncs the projection and records every event that its own claims and    *)
(* every confirming member's do, the meet of their frontiers; later it     *)
(* cuts the events up to an HLC that the record covers. The code runs both *)
(* steps in one instance call (`truncate_below_or_equal/4`), one of the    *)
(* interleavings checked here.                                             *)
Reserve(r) ==
    /\ CompactBy # "none"
    /\ "trunc" \in HlcGuards => ~mark[r]
    /\ \E k \in 1..Len(order), W \in SUBSET (Replicas \ {r}) :
         LET Ok(e) ==
               CASE CompactBy = "durable" ->
                      \/ RetiredExempt /\ e.org \in retired
                      \/ \A q \in Replicas : e \in DurClaims(q)
                 [] CompactBy = "recorded" -> \A q \in W : e \in Claims(q)
                 [] CompactBy = "members" -> \A q \in Members(r) : e \in Claims(q)
                 [] CompactBy = "own" -> TRUE
                 [] OTHER -> \A q \in Replicas \ {r} :
                               e \in recv[q] \/ e \in Claims(q)
             M == {e \in app[r] : Ok(e)}
             T == {e \in recv[r] \ (cmp[r] \cup rsv[r]) : HlcOf(DotOf(e)) =< k}
         IN /\ T # {}
            /\ T \subseteq M
            /\ CompactBy = "recorded" => W # {}
            /\ rsv' = [rsv EXCEPT ![r] = @ \cup T]
            /\ tv' = [tv EXCEPT ![r] = @ \cup M]
    /\ hist' = [hist EXCEPT ![r] = {cell[r]}]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   ckpt, read, ever, crashes, order, mark, fresh, live, cmp,
                   joined, svars>>

\* With "soloclean", sides join only while at most one of them, each a set
\* of replicas, holds a truncation record.
CleanJoin(Sides) ==
    "soloclean" \in HlcGuards =>
        Cardinality({S \in Sides : \E q \in S : Recorded(q) # {}}) =< 1

Merge ==
    /\ \A r \in Replicas : joined[r] = "solo"
    /\ CleanJoin({{r} : r \in Replicas})
    /\ joined' = [r \in Replicas |-> "in"]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   ckpt, read, hist, ever, crashes, order, mark, fresh, live,
                   cmp, rsv, tv, svars>>

(* With "leave", a member leaves and restarts alone (`cluster.enabled =  *)
(* off`) once, truncating on its own frontier, and may restart a member   *)
(* again later. Leave is the change of membership alone, taken with no    *)
(* session in flight; the restart's loss of memory is Crash's.            *)
Leave(r) ==
    /\ "leave" \in HlcGuards
    /\ joined[r] = "in"
    /\ step[r] = "idle" /\ det[r] = Idle
    /\ \A q \in Replicas : speer[q] # r /\ det[q].peer # r
    /\ joined' = [joined EXCEPT ![r] = "alone"]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   ckpt, read, hist, ever, crashes, order, mark, fresh, live,
                   cmp, rsv, tv, svars>>

Rejoin(r) ==
    /\ joined[r] = "alone"
    /\ CleanJoin({{r}, {q \in Replicas : In(q)}})
    /\ joined' = [joined EXCEPT ![r] = "back"]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   ckpt, read, hist, ever, crashes, order, mark, fresh, live,
                   cmp, rsv, tv, svars>>

Cut(r) ==
    /\ rsv[r] # {}
    /\ UNCHANGED <<tv, joined>>
    /\ cmp' = [cmp EXCEPT ![r] = @ \cup rsv[r]]
    /\ rsv' = [rsv EXCEPT ![r] = {}]

(* The compaction commit: the cut, then a checkpoint of the claims         *)
(* (`finalize_catalogue_compaction_commit/6`).                              *)
Compact(r) ==
    /\ Cut(r)
    /\ ckpt' = [ckpt EXCEPT ![r] = app[r]]
    /\ read' = [read EXCEPT ![r] = app[r]]
    /\ hist' = [hist EXCEPT ![r] = {cell[r]}]
    /\ fresh' = [fresh EXCEPT ![r] = live[r]]
    /\ mark' = [mark EXCEPT ![r] = @ /\ ~live[r]]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   ever, crashes, order, live, svars>>

(* The watermark door's cut, with no checkpoint after it.                 *)
Door(r) ==
    /\ Cut(r)
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   ckpt, read, hist, ever, crashes, order, mark, fresh, live,
                   svars>>

(* A checkpoint reads the claims; its sync later makes them durable along  *)
(* with the cell as it is at the sync.                                     *)
ReadClaims(r) ==
    /\ read' = [read EXCEPT ![r] = app[r]]
    /\ fresh' = [fresh EXCEPT ![r] = live[r]]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   ckpt, hist, ever, crashes, order, mark, live, cmp, rsv, tv, joined,
                   svars>>

Sync(r) ==
    /\ ckpt' = [ckpt EXCEPT ![r] = read[r]]
    /\ hist' = [hist EXCEPT ![r] = {cell[r]}]
    /\ mark' = [mark EXCEPT ![r] = @ /\ ~fresh[r]]
    /\ UNCHANGED <<cell, recv, app, fold, minted, retired, installs,
                   read, ever, crashes, order, fresh, live, cmp, rsv, tv, joined, svars>>

(* A crash ends the sessions served by the replica. Its own session ends,   *)
(* or, past its rederive, may go on detached: the restarted replica holds  *)
(* no install token, so it refuses the session's stage before the rederive *)
(* (`bondy_oplog_applier:open_stage/3`).                                   *)
Crash(r) ==
    /\ crashes < MaxCrashes
    /\ \E c \in hist[r] : cell' = [cell EXCEPT ![r] = c]
    /\ app' = [app EXCEPT ![r] = DurClaims(r)]
    /\ fold' = [fold EXCEPT ![r] = @ \cap DurClaims(r)]
    /\ read' = [read EXCEPT ![r] = DurClaims(r)]
    /\ crashes' = crashes + 1
    /\ fresh' = [fresh EXCEPT ![r] = FALSE]
    /\ live' = [live EXCEPT ![r] = FALSE]
    /\ LET ends(q) == \/ q = r
                      \/ speer[q] = r /\ step[q] \in {"read", "begun", "installed",
                                                         "rederived", "targeted"}
       IN /\ step' = [q \in Replicas |-> IF ends(q) THEN "idle" ELSE step[q]]
          /\ speer' = [q \in Replicas |-> IF ends(q) THEN "none" ELSE speer[q]]
          /\ pend' = [q \in Replicas |-> IF ends(q) THEN {} ELSE pend[q]]
          /\ cur' = [q \in Replicas |-> IF ends(q) THEN FALSE ELSE cur[q]]
          /\ has' = [q \in Replicas |-> IF ends(q) THEN FALSE ELSE has[q]]
          /\ got' = [q \in Replicas |-> IF ends(q) THEN Bottom ELSE got[q]]
          /\ tgt' = [q \in Replicas |-> IF ends(q) THEN {} ELSE tgt[q]]
    /\ \E detach \in BOOLEAN :
         det' = [det EXCEPT ![r] =
                   IF detach /\ Rederived(step[r]) THEN Sess(r, FALSE) ELSE @]
    /\ dirty' = [dirty EXCEPT ![r] = @ /\ ~mark[r]]
    /\ stg' = [stg EXCEPT ![r] = Bottom]
    /\ replayed' = [replayed EXCEPT ![r] = "replayed" \notin HlcGuards]
    /\ UNCHANGED <<recv, minted, retired, installs, ckpt, hist, ever,
                   order, mark, cmp, rsv, tv, joined>>

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
    \/ Merge
    \/ \E r \in Replicas : Leave(r) \/ Rejoin(r)
    \/ Tracked(\E r \in Replicas, e \in AllEvents : Apply(r, e))
    \/ Tracked(\E r \in Replicas : Discard(r))
    \/ Tracked(\E o \in Replicas : Retire(o))
    \/ Tracked(\E r, o \in Replicas : ReapCell(r, o))
    \/ Tracked(\E r, p \in Replicas : ReadFrontier(r, p))
    \/ Tracked(\E r \in Replicas : InstallCell(r) \/ Replayed(r)
                                         \/ Fetch(r) \/ Abort(r) \/ Begin(r)
                                         \/ Refuse(r) \/ Rederive(r))
    \/ Tracked(\E r \in Replicas, z \in BOOLEAN :
                 Adopt(r, z) \/ Settle(r, z) \/ ReadTarget(r, z)
                 \/ FailRederived(r, z))
    \/ \E r \in Replicas : ReadClaims(r) \/ Sync(r) \/ Crash(r)
                            \/ Reserve(r) \/ Compact(r) \/ Door(r)

Spec == Init /\ [][Next]_vars

\* Replicas are interchangeable: no definition names one.
Sym == Permutations(Replicas)

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* Once a replica has received every event and folded each one, its value is
\* the fold of them all.
Settled(r) ==
    /\ \A e \in AllEvents : e.org \notin retired => e \in recv[r]
    /\ recv[r] \ cmp[r] \subseteq fold[r]
\* A replace session's cells are the source's until its rederive re-folds
\* the MST; readers see them in that window, and the mark keeps them from
\* being served.
InstallWindow(r) == dirty[r]
SettledSound ==
    \A r \in Replicas \ retired :
        Settled(r) /\ ~InstallWindow(r) =>
            Present(cell[r]) = PresentFold(AllEvents)

\* While two replicas or more are live, some replica can still serve a
\* session or clear its mark: one is unmarked, its install's claims survive
\* in memory, or it has adopted. A lone survivor owing an install waits for
\* a new member.
Owes(r) == mark[r] /\ ~live[r] /\ step[r] # "adopted"
SomeoneServes ==
    Cardinality(Replicas \ retired) >= 2 =>
        ~\A r \in Replicas \ retired : Owes(r)

\* A truncated event stays claimed from the moment its truncation is
\* recorded: nothing re-presents it once cut, and its origin's later events
\* fold only after it (the contiguity hold).
CompactedClaimed == \A r \in Replicas : Recorded(r) \subseteq app[r]

\* Every event a replica's truncation record holds is, at every other member
\* of its cluster, claimed, or still in its tree, from which its fold claims
\* it, or reachable by an install from that replica, which the "coverbegin"
\* check admits while its claims cover the member's own record. A member with
\* none of the three never comes to cover the record, and the two refuse each
\* other as sources for good.
NoStrandedRecord ==
    \A r \in Replicas \ retired : \A q \in Members(r) \ retired :
        \A e \in Recorded(r) :
            \/ e \in Claims(q)
            \/ e \in recv[q] \ cmp[q]
            \/ Recorded(q) \subseteq Claims(r)

=============================================================================
