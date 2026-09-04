------------------------------- MODULE SeqSeed -------------------------------
(***************************************************************************)
(* Does a bondy_oplog instance's per-origin sequence counter survive a     *)
(* restart?  Which durable sources must seed it, and in what order must    *)
(* compaction write them?                                                  *)
(*                                                                         *)
(* Why it matters.  Oplog_Model.thy takes H1 `origin_unique` -- no two     *)
(* distinct events share a dot (origin, seq) -- as a hypothesis, and       *)
(* everything downstream (the stability theorem, Dot_Exactness's compact   *)
(* test, the applied-frontier convergence oracle) consumes it.  The        *)
(* AaeCausalClosure module mints from a global `minted[o]` that never      *)
(* regresses, so it cannot exhibit a seq regression: this bug sits         *)
(* OUTSIDE that model's state space.  This module puts the minter's        *)
(* persistence protocol inside a model, with a crash action.               *)
(*                                                                         *)
(* What the code does, established by reading bondy_oplog_instance.erl     *)
(* and bondy_oplog_applier.erl (2026-09-03):                               *)
(*                                                                         *)
(*   - Mint: `do_build_events/6` reserves a seq range with one             *)
(*     `atomics:add_get` on the VOLATILE `SeqRef`, then appends the batch  *)
(*     to the WAL; the ack follows the append (`fsync_mode = per_write`,   *)
(*     the default, makes the ack imply durability).                       *)
(*   - Apply: the applier drains the WAL in append order, writes the       *)
(*     projection and advances the VOLATILE registry frontier              *)
(*     (`apply_cell_batch_mux`), then casts `install_local_batch`; the     *)
(*     install bumps `SeqRef` to the batch max (`maybe_bump_seq_atomic`).  *)
(*   - Commit (`commit_now/1`): `drain_install_queue` flushes the MST      *)
(*     root durably, THEN the consumer offset is written and the WAL's     *)
(*     committed segment advances.                                         *)
(*   - Retention (`compute_deletable/1`): a segment is dropped only when   *)
(*     it is below the committed segment AND below the snapshot watermark  *)
(*     -- the durable compaction checkpoint's watermark, fed by            *)
(*     `advance_snapshot_watermark/2`.  (As of 2026-09-03 nothing in       *)
(*     production calls that function, so the sweep drops nothing; the     *)
(*     rule modelled is the one the code states, which is also the         *)
(*     stronger of the two.)                                               *)
(*   - Compact (`finalize_catalogue_compaction/3`): truncate the MST at    *)
(*     or below a frontier key, flush the truncated root durably, THEN     *)
(*     write the checkpoint `{projection_managed, frontier, VV}` carrying  *)
(*     the registry frontier -- in that order, so the durable checkpoint   *)
(*     never outruns the durable root (`resume_position/2` is their max).  *)
(*   - Stop (`terminate/2`) and a catalogue bootstrap also write the       *)
(*     frontier checkpoint (`maybe_persist_frontier/5`).  A crash writes   *)
(*     nothing.                                                            *)
(*   - Restart: `init/1` seeds `SeqRef` from `max_local_seq(MST, Origin)`  *)
(*     -- the LIVE tree only -- then `restore_frontier/2` max-merges the   *)
(*     checkpoint VV and `frontier_from_mst/1` the tree keys into the      *)
(*     registry frontier, and the applier replays the WAL from             *)
(*     `max(last MST key, checkpoint watermark)`, bumping `SeqRef` as it   *)
(*     installs.  Nobody passes `seq_seed`.                                *)
(*                                                                         *)
(* One replica, one origin: dot uniqueness is a property of the minter's   *)
(* own persistence protocol, not of replication.  What a duplicated dot    *)
(* then does across replicas is AaeCausalClosure's territory (a duplicate  *)
(* sits at or below every peer's frontier, so no frontier gap is ever      *)
(* raised for it).                                                         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxSeq,                 \* how many seqs the origin may mint
    SeedRule,               \* what `init/1` seeds SeqRef from, directly:
                            \*   "live"     -- the live tree (what ships; the
                            \*                 WAL tail tops up through Apply)
                            \*   "ckpt"     -- live tree + checkpoint frontier
                            \*   "ckpt_wal" -- live tree + checkpoint frontier
                            \*                 + the retained WAL, scanned at
                            \*                 init rather than awaited
    FrontierBeforeTruncate, \* TRUE: compaction persists the frontier VV
                            \*       (under the OLD watermark) BEFORE the
                            \*       truncated root is flushed
                            \* FALSE: what ships -- checkpoint after the flush
    RetentionKeyedOnCkpt,   \* TRUE: the WAL drops a segment only below the
                            \*       DURABLE CHECKPOINT WATERMARK (and below
                            \*       the committed offset) -- the shipped
                            \*       rule, `compute_deletable/1`
                            \* FALSE: the differential -- drop anything the
                            \*       durable root holds
    MintAfterReplay         \* TRUE: no mint until the applier has replayed
                            \*       the WAL tail -- an ASSUMPTION the code
                            \*       does not enforce (the fast path is
                            \*       published in `init/1`; nothing awaits
                            \*       the boot drain), used to separate the
                            \*       two restart windows
                            \* FALSE: what ships

ASSUME SeedRule \in {"live", "ckpt", "ckpt_wal"}

Seq == 1..MaxSeq

Max(S) == IF S = {} THEN 0 ELSE CHOOSE m \in S : \A x \in S : x <= m
Max2(a, b) == IF a > b THEN a ELSE b
Min(S) == CHOOSE m \in S : \A x \in S : m <= x

VARIABLES
    up,        \* the instance process is running
    seqRef,    \* the volatile atomics counter (meaningless while ~up)
    inflight,  \* reserved seqs whose WAL append has not completed
    wal,       \* seqs durably in the WAL
    cursor,    \* the applier's WAL read position (last applied seq)
    fr,        \* the volatile registry applied frontier for this origin
    mem,       \* seqs installed in the in-memory MST but not yet in the
               \* durable root
    tree,      \* seqs in the durable MST root
    ckpt,      \* the checkpoint's frontier VV entry for this origin
    wm,        \* the checkpoint's watermark (the truncation frontier key)
    pend,      \* > 0 while a truncation is flushed but not yet checkpointed
    acked      \* history: every seq whose append was acknowledged

vars == <<up, seqRef, inflight, wal, cursor, fr, mem, tree, ckpt, wm, pend,
          acked>>

\* The in-memory MST is the durable root plus the staged installs.
Mst == tree \cup mem

Init ==
    /\ up = TRUE
    /\ seqRef = 0
    /\ inflight = {}
    /\ wal = {}
    /\ cursor = 0
    /\ fr = 0
    /\ mem = {}
    /\ tree = {}
    /\ ckpt = 0
    /\ wm = 0
    /\ pend = 0
    /\ acked = {}

\* `atomics:add_get(SeqRef, 1, N)` -- one seq at a time here.
\* Where a mint may happen.  Under MintAfterReplay the counter is allowed
\* to be stale while the applier is still replaying the tail.
CanMint == up /\ (MintAfterReplay => cursor = Max(wal))

Reserve ==
    /\ CanMint
    /\ seqRef < MaxSeq
    /\ seqRef' = seqRef + 1
    /\ inflight' = inflight \cup {seqRef + 1}
    /\ UNCHANGED <<up, wal, cursor, fr, mem, tree, ckpt, wm, pend, acked>>

\* The WAL append + fsync + ack.  Appends are serialised through the WAL
\* gen_server; taking the lowest reserved seq keeps the WAL in seq order,
\* which is what lets `cursor` stand for the reader's position.
Append ==
    /\ up
    /\ inflight # {}
    /\ LET s == Min(inflight) IN
        /\ wal' = wal \cup {s}
        /\ acked' = acked \cup {s}
        /\ inflight' = inflight \ {s}
    /\ UNCHANGED <<up, seqRef, cursor, fr, mem, tree, ckpt, wm, pend>>

\* The applier reads the next WAL frame past its cursor, applies it to the
\* projection (frontier bump), and the instance installs it into the MST
\* (SeqRef bump).  Two processes in the code, one step here: both effects
\* are volatile and nothing in this module can observe the gap between them.
Apply ==
    /\ up
    /\ {s \in wal : s > cursor} # {}
    /\ LET s == Min({x \in wal : x > cursor}) IN
        /\ cursor' = s
        /\ fr' = Max2(fr, s)
        /\ mem' = mem \cup {s}
        /\ seqRef' = Max2(seqRef, s)
    /\ UNCHANGED <<up, inflight, wal, tree, ckpt, wm, pend, acked>>

\* `drain_install_queue`: the staged root becomes the durable root.
FlushRoot ==
    /\ up
    /\ mem # {}
    /\ tree' = tree \cup mem
    /\ mem' = {}
    /\ UNCHANGED <<up, seqRef, inflight, wal, cursor, fr, ckpt, wm, pend,
                   acked>>

\* The retention sweep.  What ships (`bondy_oplog_wal:compute_deletable/1`)
\* drops a segment only when it is below the committed offset AND below
\* the snapshot watermark -- the durable compaction checkpoint's watermark.
\* Everything above the last durable checkpoint therefore stays in the WAL
\* and replays after a restart, which is what closes the crash window
\* between a truncated root's flush and its checkpoint write.  The
\* differential drops anything the durable root holds.
DropWal ==
    /\ up
    /\ LET Gone == IF RetentionKeyedOnCkpt
                     THEN {s \in wal : s <= wm}
                     ELSE wal \cap tree
       IN /\ Gone # {}
          /\ wal' = wal \ Gone
    /\ UNCHANGED <<up, seqRef, inflight, cursor, fr, mem, tree, ckpt, wm,
                   pend, acked>>

\* Compaction step 1: truncate the MST at or below W and flush the truncated
\* root durably.  `finalize_catalogue_compaction/3` reaches this only once
\* the projection is current up to W, which for this origin's own events is
\* always so (apply precedes install).  Under FrontierBeforeTruncate the
\* frontier VV is checkpointed first, under the watermark still in force.
TruncateFlush ==
    /\ up
    /\ pend = 0
    /\ \E w \in Mst :
        /\ pend' = w
        /\ tree' = {s \in Mst : s > w}
        /\ mem' = {}
        /\ ckpt' = IF FrontierBeforeTruncate THEN fr ELSE ckpt
    /\ UNCHANGED <<up, seqRef, inflight, wal, cursor, fr, wm, acked>>

\* Compaction step 2: `put_checkpoint(State, Frontier, {.., frontier, VV})`.
TruncateCheckpoint ==
    /\ up
    /\ pend # 0
    /\ ckpt' = fr
    /\ wm' = pend
    /\ pend' = 0
    /\ UNCHANGED <<up, seqRef, inflight, wal, cursor, fr, mem, tree, acked>>

\* `terminate/2`: persist the frontier, then go down.  Everything volatile
\* is lost exactly as in a crash; the checkpoint write is the difference.
Stop ==
    /\ up
    /\ pend = 0
    /\ up' = FALSE
    /\ ckpt' = fr
    /\ inflight' = {}
    /\ mem' = {}
    /\ UNCHANGED <<seqRef, wal, cursor, fr, tree, wm, pend, acked>>

\* kill -9.  A truncation whose root was flushed but whose checkpoint was
\* not written stays that way on disk: `pend` is dropped, `tree` is kept.
Crash ==
    /\ up
    /\ up' = FALSE
    /\ inflight' = {}
    /\ mem' = {}
    /\ pend' = 0
    /\ UNCHANGED <<seqRef, wal, cursor, fr, tree, ckpt, wm, acked>>

\* `init/1` + `restore_frontier/2` + `frontier_from_mst/1` + the applier's
\* `resume_position/2`.  The WAL tail past the resume position replays
\* through `Apply`, which bumps `seqRef` as it goes -- exactly the shipped
\* top-up.  What `Restart` seeds directly is the whole question.
Restart ==
    /\ ~up
    /\ up' = TRUE
    /\ seqRef' = CASE SeedRule = "live"     -> Max(tree)
                   [] SeedRule = "ckpt"     -> Max2(ckpt, Max(tree))
                   [] SeedRule = "ckpt_wal" -> Max({ckpt} \cup tree \cup wal)
    /\ fr' = Max2(ckpt, Max(tree))
    /\ cursor' = Max2(Max(tree), wm)
    /\ UNCHANGED <<inflight, wal, mem, tree, ckpt, wm, pend, acked>>

Next ==
    \/ Reserve
    \/ Append
    \/ Apply
    \/ FlushRoot
    \/ DropWal
    \/ TruncateFlush
    \/ TruncateCheckpoint
    \/ Stop
    \/ Crash
    \/ Restart

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ up \in BOOLEAN
    /\ seqRef \in 0..MaxSeq
    /\ inflight \subseteq Seq
    /\ wal \subseteq Seq
    /\ cursor \in 0..MaxSeq
    /\ fr \in 0..MaxSeq
    /\ mem \subseteq Seq
    /\ tree \subseteq Seq
    /\ ckpt \in 0..MaxSeq
    /\ wm \in 0..MaxSeq
    /\ pend \in 0..MaxSeq
    /\ acked \subseteq Seq

(***************************************************************************)
(* The properties.                                                         *)
(*                                                                         *)
(* DotUnique is H1 restricted to one origin: a seq the minter is about to  *)
(* hand out must never already carry an acknowledged event.  It is what    *)
(* the consumers of `origin_unique` need.                                  *)
(*                                                                         *)
(* SeedExact is the stronger, operational statement -- the counter equals  *)
(* the largest acknowledged seq plus its reservations, so the sequence     *)
(* stays gap-free (`release_seq_range/3` exists to keep it so: a hole no   *)
(* replica can fill parks every peer on it).  It fails one step earlier    *)
(* than DotUnique -- as soon as a mint is possible -- which keeps the      *)
(* traces short.                                                           *)
(***************************************************************************)
DotUnique == inflight \cap acked = {}

SeedExact == CanMint => (acked \cup inflight = 1..seqRef)

\* Sanity: the durable sources never claim a seq that was not acknowledged.
DurableSound ==
    /\ wal \subseteq acked
    /\ tree \subseteq acked
    /\ mem \subseteq acked
    /\ ckpt <= Max(acked)

=============================================================================
