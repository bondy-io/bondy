---------------------------- MODULE IndexIntents ----------------------------
(***************************************************************************)
(* Secondary-index maintenance across crashes: whether a node's index      *)
(* equals the index function of its primary once nothing is in flight,     *)
(* with index ops persisted as intents in the primary's own write batch    *)
(* instead of a full rebuild after an unclean shutdown.                    *)
(*                                                                         *)
(* The code this models (bondy_oplog_cell_apply, bondy_oplog_applier,      *)
(* bondy_oplog_secondary_writer, bondy_oplog_index_rebuild,                *)
(* bondy_oplog_instance, bondy_db):                                        *)
(*                                                                         *)
(*   - Each primary shard has its own applier and store. The applier folds *)
(*     a batch of events into one `put_batch` (`apply_cell_batch`); a      *)
(*     later event of the batch reads the earlier one's new value. Per     *)
(*     event it computes index ops from the cell's old and new value       *)
(*     (`index_ops_for_one`): a put for every current term, a remove for   *)
(*     every term the new value no longer yields. After the `put_batch` it *)
(*     dispatches them to the secondary writer (`dispatch_index_ops/4`),   *)
(*     or drops them, marks the index and requests a rebuild when the      *)
(*     writer's backlog is full (`secondary_saturation_drop/5`).           *)
(*   - One writer serves every primary shard. It buffers ops and writes    *)
(*     them to the index store in one batch (`do_flush`). An index cell is *)
(*     last-writer-wins over `{Order, live > dead}`                        *)
(*     (`bondy_oplog_crdt_index_entry:merge/2`). A restarted writer        *)
(*     registers itself for dispatch in `init/1`; a call to it waits until *)
(*     `init/1` returns.                                                   *)
(*   - A store write is one leveled `book_mput`, one journal entry, kept   *)
(*     or dropped whole by a crash (`leveled_cdb` CRC check at open).      *)
(*     Neither store is synced per write. A crash keeps every synced entry *)
(*     and, of the rest, a prefix ("prefix") or any subset ("subset"),     *)
(*     set per store (CrashKeeps, IndexCrashKeeps): a rolled journal file  *)
(*     is closed without an fsync                                          *)
(*     (`leveled_cdb:close_file`), so a later file can outlive an earlier  *)
(*     one. Each store loses entries independently of the others.          *)
(*   - A checkpoint syncs the stores, then records what the shard has      *)
(*     applied (`write_frontier_checkpoint`). The compaction barrier first *)
(*     flushes the writer, or, with the writer down, marks the index for   *)
(*     rebuild (`drive_secondary_indexes/1`, `flush_or_backstop`). After a *)
(*     crash every event the checkpoint does not claim is presented to the *)
(*     applier again (boot re-fold, `compute_replay_anchor`).              *)
(*   - A catalogue install writes or deletes primary cells directly,       *)
(*     outside the WAL (`install_cell/6`, `delete_cell/5`). The model lets *)
(*     the installed cell's HLC be any past value, below the local one     *)
(*     included.                                                           *)
(*   - A rebuild marks the index untrusted and clears it (RebuildWipes),   *)
(*     resets the writer's buffer, re-folds every primary of the table     *)
(*     into the writer (RebuildRefolds), flushes the writer, and marks the *)
(*     index trusted                                                       *)
(*     (`bondy_oplog_index_rebuild:do_rebuild/3`). With MarkNeedsFlush =   *)
(*     FALSE it marks even when the flush failed or the writer restarted   *)
(*     after taking part of the re-fold. A request that arrived while it   *)
(*     ran removes the mark again (`index_clear_rebuild/2`, `remarked`)    *)
(*     and runs another; with KeepRequests = FALSE the request is dropped. *)
(*                                                                         *)
(* Intents (Intents = TRUE):                                               *)
(*   - A batch that yields index ops stores them as one intent in the same *)
(*     primary `put_batch`. Each event of the batch takes the next version *)
(*     of its shard's counter (VersionPerEvent).                           *)
(*   - Every index batch records, per primary shard, the highest version   *)
(*     it writes. After flushing the writer and syncing the index, the     *)
(*     barrier clears a shard's intents up to a bound: the version the     *)
(*     index records for the shard (ClearBound = "source"), or the highest *)
(*     version the shard had dispatched or dropped when the barrier began  *)
(*     (ClearBound = "dispatched"), which needs no index record and so     *)
(*     holds for any number of index shards. "drawn" clears up to the      *)
(*     shard's counter instead, ops not yet dispatched included.           *)
(*   - A restarted writer registers for dispatch, then replays the         *)
(*     leftover intents of every shard, both in `init/1`                   *)
(*     (StampBeforeReplay). At open each primary shard registers, then     *)
(*     replays its own leftover intents before its applier starts; its     *)
(*     dispatched version starts at its intents' clear record              *)
(*     (OpenDispatched = "cleared"), since a shared instance's barrier may *)
(*     run before the replay. A full rebuild runs only for an untrusted    *)
(*     index.                                                              *)
(*   - A rebuild syncs the index before it writes the trust mark and       *)
(*     before it wipes the index, after removing the mark (SyncBeforeMark, *)
(*     SyncBeforeWipe); no other removal of the mark is synced. The        *)
(*     barrier clears no intents while a rebuild is due (ClearMarked =     *)
(*     FALSE).                                                             *)
(*   - A mark removes the trust mark only when no rebuild is due, and that *)
(*     removal may be lost (UnmarkMayFail): a Bookie that dies during the  *)
(*     delete restarts behind the same handle. The rebuild removes the     *)
(*     mark itself before the wipe, and a failure fails the run            *)
(*     (RebuildUnmarks).                                                   *)
(*     The barrier runs whenever a shard has dispatched past its clear     *)
(*     record, as the compaction cycle does (`clear_index_intents/1`).     *)
(*   - An install writes intents with its cells. A group of cells syncs    *)
(*     the primary before its first cell (SyncBeforeInstall), and at its   *)
(*     end, when it has ops, syncs the primary, then dispatches them       *)
(*     (InstallMode = "synced"; "unsynced" skips the second). The applier  *)
(*     runs the group in one call, so no other write of the shard runs     *)
(*     meanwhile (`install_catalogue_group`).                              *)
(*   - Index cells are ordered by the version (OrderByVersion). After a    *)
(*     crash a shard's counter restarts at the highest version its primary *)
(*     or the index records (VersionSource = "recorded").                  *)
(* Intents = FALSE has no intents, an install with no index ops, and a     *)
(* full rebuild after every unclean open (RebuildAtOpen) and every writer  *)
(* restart.                                                                *)
(*                                                                         *)
(* Scope. One index; each primary shard owns one key. Values are whole-   *)
(* value assignments, so the model checks that the index matches the      *)
(* primary, not what the primary should hold; a re-presented event whose   *)
(* value the primary already holds yields only puts, as in the code. Not   *)
(* modelled: a failed index computation.                                   *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Keys, Vals,          \* one key per primary shard; "none" yields no term
    MaxEvents, MaxBatch, MaxInstalls,
    MaxCrashes, MaxWriterCrashes, MaxSaturations,
    MaxCleanReopens,     \* clean closes, each followed by a trusting open
    MaxIndexEntries,     \* a bound on the index journal's length (IndexBound)
    Intents,             \* intents in the primary batch, replayed at open
    IntentInBatch,       \* the intent shares the cells' journal entry
    SyncBeforeClear,     \* the barrier syncs the index before clearing
    ClearBound,          \* "source": per shard; "writer": the writer's max;
                         \* "dispatched": what the shard has dispatched;
                         \* "drawn": the shard's counter
    OrderByVersion,      \* index cells ordered by the version, not the HLC
    VersionPerEvent,     \* each event of a batch takes its own version
    InstallMode,         \* "none" | "dispatch" | "synced" | "unsynced"
    VersionSource,       \* after a crash: "recorded" | "intents" | "reset"
    StampBeforeReplay,   \* a restarted writer registers before it replays
    MarkNeedsFlush,      \* a rebuild marks trusted only when the writer
                         \* that took its re-fold flushed it
    KeepRequests,        \* a request during a rebuild withholds its mark
                         \* and runs another
    CrashKeeps,          \* primaries: "prefix" | "subset" of the unsynced entries
    IndexCrashKeeps,     \* the index: "prefix" | "subset"
    RebuildAtOpen,       \* Intents = FALSE: full rebuild at every open
    OpenDispatched,      \* a shard's dispatched version at open: "cleared"
                         \* (its intents' clear record) | "seed" (its counter)
    SyncBeforeMark,      \* the index is synced before the trust mark is written
    SyncBeforeWipe,      \* a rebuild syncs the index after removing the trust
                         \* mark and before wiping it
    ClearMarked,         \* the barrier clears intents while a rebuild is due
    OpenFlushes,         \* a trusting open flushes the writer before it
                         \* freshens the index
    FreshenNeedsFlush,   \* an open whose flush failed does not freshen
    UnmarkMayFail,       \* a best-effort removal of the trust mark may be lost
    RebuildUnmarks,      \* a rebuild removes the trust mark itself before
                         \* the wipe, failing the run if it cannot
    SyncBeforeInstall,   \* an install group syncs the primary before its
                         \* first cell
    RebuildWipes,        \* a rebuild clears the index before its re-fold
    RebuildRefolds       \* a rebuild's re-fold of a shard dispatches its ops

None == "none"
Terms(v) == IF v = None THEN {} ELSE {v}
Max(S) == CHOOSE x \in S : \A y \in S : y <= x
Pick(seq, K) ==
    LET f[i \in 0..Len(seq)] ==
            IF i = 0 THEN <<>>
            ELSE IF i \in K THEN Append(f[i - 1], seq[i]) ELSE f[i - 1]
    IN f[Len(seq)]
Survivors(seq, synced, keeps) ==
    IF keeps = "prefix"
    THEN {SubSeq(seq, 1, n) : n \in synced..Len(seq)}
    ELSE {Pick(seq, (1..synced) \cup K) : K \in SUBSET (synced + 1..Len(seq))}

VARIABLES
    wal, ckpt, redo, \* per shard: WAL events, applied count checkpointed, to re-present
    pj, psync,       \* per shard: primary journal, synced length
    pend,            \* per shard: ops written but not yet dispatched
    ipend,           \* per shard: <<>>, or <<ops>> while an install group is open
    ver,             \* per shard: version counter
    disp,            \* per shard: highest version dispatched or dropped
    ij, isync,       \* index journal, synced length
    buf, bufMark,    \* writer buffer; a pending trust mark
    wstate,          \* "up" | "down" | "stamped" (registered, not replayed)
    wgen,            \* writer incarnation
    rgen,            \* writer incarnation the running rebuild started with
    rebuild,         \* "idle" | "req" | "run" | "remark" (trust mark
                     \* written, its removal not yet)
    folded,          \* shards the running rebuild has re-folded
    again,           \* a request arrived during the running rebuild
    rep,             \* per shard: opened, leftover intents not yet replayed
    opening,         \* an open with intents has not yet freshened the index
    owed,            \* the ops that open replayed, and the index length
                     \* at the open
    stale,           \* the open freshened an index missing an owed op
    clock,
    nev, ninst, ncrash, nwcrash, nsat, nclean

vars == <<wal, ckpt, redo, pj, psync, pend, ipend, ver, disp, ij, isync, buf, bufMark,
          wstate, wgen, rgen, rebuild, folded, again, rep, opening, owed, stale,
          clock, nev, ninst, ncrash, nwcrash, nsat, nclean>>

(* Primary entries: cells ("w"), a separate intent ("i"), or a clear    *)
(* ("clr"). Index entries: ops (and a trust mark), a clear, an unmark.  *)
PW(cells, iv, ops) == [kind |-> "w", cells |-> cells, iv |-> iv, ops |-> ops, upto |-> 0]
PI(iv, ops) == [kind |-> "i", cells |-> {}, iv |-> iv, ops |-> ops, upto |-> 0]
PClr(a) == [kind |-> "clr", cells |-> {}, iv |-> 0, ops |-> {}, upto |-> a]
IOps(ops, m) == [kind |-> "ops", ops |-> ops, mark |-> m]
IClear == [kind |-> "clear", ops |-> {}, mark |-> FALSE]
IUnmark == [kind |-> "unmark", ops |-> {}, mark |-> FALSE]
Op(t, k, live, ord, iv) == [t |-> t, k |-> k, live |-> live, ord |-> ord, iv |-> iv]

(* Primary state of shard k *)
LastCell(p, k) ==
    LET I == {n \in 1..Len(p) : \E c \in p[n].cells : c.k = k}
    IN IF I = {} THEN [k |-> k, v |-> None, h |-> 0]
       ELSE CHOOSE c \in p[Max(I)].cells : c.k = k
PVal(p, k) == LastCell(p, k).v
PHlc(p, k) == LastCell(p, k).h
ClearedUpTo(p) ==
    Max({p[n].upto : n \in {m \in 1..Len(p) : p[m].kind = "clr"}} \cup {0})
IsIntent(p, n) == p[n].kind \in {"w", "i"} /\ p[n].ops # {}
IntentOps(p) ==
    UNION {p[n].ops : n \in {m \in 1..Len(p) : IsIntent(p, m) /\ p[m].iv > ClearedUpTo(p)}}
RecordedVersion(p) ==
    Max({p[n].iv : n \in {m \in 1..Len(p) : IsIntent(p, m)}} \cup {ClearedUpTo(p)})
AllIntentOps(P) == UNION {IntentOps(P[k]) : k \in Keys}

(* Index state *)
LastClear(j) == Max({n \in 1..Len(j) : j[n].kind = "clear"} \cup {0})
OrdKeys(j, t, k) ==
    UNION {{2 * o.ord + (IF o.live THEN 1 ELSE 0) :
              o \in {x \in j[n].ops : x.t = t /\ x.k = k}} :
           n \in LastClear(j) + 1 .. Len(j)}
IdxLive(j, t, k) == LET S == OrdKeys(j, t, k) IN S # {} /\ Max(S) % 2 = 1
(* Index journal j holds op o or a later op on its term, or was cleared   *)
(* after position `at`: a trusted index cleared since then was rebuilt   *)
(* from the primary.                                                     *)
Reflected(j, o, at) ==
    LET S == OrdKeys(j, o.t, o.k)
    IN \/ S # {} /\ Max(S) >= 2 * o.ord + (IF o.live THEN 1 ELSE 0)
       \/ LastClear(j) > at
(* The per-shard high-water each index batch records; a clear keeps it. *)
IndexVersion(j, k) ==
    Max(UNION {{o.iv : o \in {x \in j[n].ops : x.k = k}} : n \in 1..Len(j)} \cup {0})
WriterVersion(j) == Max({IndexVersion(j, k) : k \in Keys})
(* A clear leaves the trust mark: the marker cell is outside the index    *)
(* keyspace (`bondy_oplog_index_key:trust_marker_loc/3`).                 *)
Trusted(j) ==
    LET M == {n \in 1..Len(j) : j[n].kind = "unmark" \/ j[n].mark}
    IN IF M = {} THEN TRUE ELSE j[Max(M)].mark

Diff(k, old, new, ord, iv) ==
    {Op(t, k, FALSE, ord, iv) : t \in Terms(old) \ Terms(new)}
        \cup {Op(t, k, TRUE, ord, iv) : t \in Terms(new)}

Request(r) == IF r = "idle" THEN "req" ELSE r

InstallOps(k) == IF ipend[k] = <<>> THEN {} ELSE ipend[k][1]

(* The outcomes of a best-effort removal of the trust mark (`remove_trust_   *)
(* marker`). Only the first mark removes it (`index_mark_rebuild/1`): while  *)
(* a rebuild is due, a mark finds it already removed or lost.                *)
Unmarked(j) == IF UnmarkMayFail THEN {Append(j, IUnmark), j}
               ELSE {Append(j, IUnmark)}
MarkUnmarked(j) == IF rebuild = "idle" THEN Unmarked(j) ELSE {j}
RequestAgain == rebuild = "run" \/ again

Init ==
    /\ wal = [k \in Keys |-> <<>>] /\ ckpt = [k \in Keys |-> 0]
    /\ redo = [k \in Keys |-> <<>>]
    /\ pj = [k \in Keys |-> <<>>] /\ psync = [k \in Keys |-> 0]
    /\ pend = [k \in Keys |-> {}] /\ ipend = [k \in Keys |-> <<>>]
    /\ ver = [k \in Keys |-> 0]
    /\ disp = [k \in Keys |-> 0]
    /\ ij = <<>> /\ isync = 0 /\ buf = {} /\ bufMark = FALSE
    /\ wstate = "up" /\ wgen = 0 /\ rgen = 0 /\ rebuild = "idle" /\ folded = {} /\ again = FALSE
    /\ rep = [k \in Keys |-> FALSE]
    /\ opening = FALSE /\ owed = [ops |-> {}, at |-> 0] /\ stale = FALSE
    /\ clock = 0
    /\ nev = 0 /\ ninst = 0 /\ ncrash = 0 /\ nwcrash = 0 /\ nsat = 0
    /\ nclean = 0

(* A cast reaches a registered writer; one to a dead pid is lost. In   *)
(* "stamped" the writer has registered (StampBeforeReplay) or only       *)
(* replayed (ablation).                                                  *)
WriterTakes == wstate = "up" \/ (wstate = "stamped" /\ StampBeforeReplay)

(* Event i of a batch takes version base + i, or base + 1 for the whole *)
(* batch (ablation).                                                     *)
EvVersion(base, i) == IF VersionPerEvent THEN base + i ELSE base + 1

(* Fold events [v, h] of shard k: the final value and the ops. *)
Fold(k, evs, base) ==
    LET f[i \in 0..Len(evs)] ==
            IF i = 0 THEN [v |-> PVal(pj[k], k), ops |-> {}]
            ELSE LET iv == EvVersion(base, i)
                 IN [v |-> evs[i].v,
                     ops |-> f[i - 1].ops \cup
                             Diff(k, f[i - 1].v, evs[i].v,
                                  IF OrderByVersion THEN iv ELSE evs[i].h, iv)]
    IN f[Len(evs)]

(* One primary write of shard k: the cell and, when ops result, the     *)
(* intent in the same entry or (ablation) the next one.                  *)
PrimaryAppend(p, cell, iv, ops) ==
    IF Intents /\ ops # {}
    THEN IF IntentInBatch THEN Append(p, PW({cell}, iv, ops))
         ELSE p \o <<PW({cell}, iv, {}), PI(iv, ops)>>
    ELSE Append(p, PW({cell}, iv, {}))

ApplyBatch(k, evs) ==
    LET r == Fold(k, evs, ver[k])
        top == EvVersion(ver[k], Len(evs))
        cell == [k |-> k, v |-> r.v, h |-> evs[Len(evs)].h]
    IN /\ pj' = [pj EXCEPT ![k] = PrimaryAppend(@, cell, top, r.ops)]
       /\ pend' = [pend EXCEPT ![k] = r.ops]
       /\ ver' = [ver EXCEPT ![k] = top]

Seqs(n) == UNION {[1..m -> Vals] : m \in 1..n}

Write(k, vs) ==
    /\ ~rep[k] /\ pend[k] = {} /\ ipend[k] = <<>> /\ redo[k] = <<>> /\ nev + Len(vs) <= MaxEvents
    /\ LET evs == [i \in 1..Len(vs) |-> [v |-> vs[i], h |-> clock + i]]
       IN /\ wal' = [wal EXCEPT ![k] = @ \o evs]
          /\ ApplyBatch(k, evs)
    /\ clock' = clock + Len(vs) /\ nev' = nev + Len(vs)
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, disp, wgen, rgen, ckpt, redo, psync, ij, isync, buf, bufMark, wstate, rebuild,
                   folded, again, ninst, ncrash, nwcrash, nsat, nclean>>

Redo(k) ==
    /\ ~rep[k] /\ pend[k] = {} /\ ipend[k] = <<>> /\ redo[k] # <<>>
    /\ ApplyBatch(k, <<Head(redo[k])>>)
    /\ redo' = [redo EXCEPT ![k] = Tail(@)]
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, disp, wgen, rgen, wal, ckpt, psync, ij, isync, buf, bufMark, wstate, rebuild,
                   folded, again, clock, nev, ninst, ncrash, nwcrash, nsat, nclean>>

Install(k, v, h0) ==
    /\ ~rep[k] /\ pend[k] = {} /\ redo[k] = <<>> /\ ninst < MaxInstalls
    /\ LET iv == ver[k] + 1
           ops == IF InstallMode = "none" THEN {}
                  ELSE Diff(k, PVal(pj[k], k), v, IF OrderByVersion THEN iv ELSE h0, iv)
           p == PrimaryAppend(pj[k], [k |-> k, v |-> v, h |-> h0], iv, ops)
       IN /\ pj' = [pj EXCEPT ![k] = p]
          /\ ver' = [ver EXCEPT ![k] = iv]
          /\ IF InstallMode \in {"synced", "unsynced"}
             THEN /\ ipend' = [ipend EXCEPT ![k] = <<InstallOps(k) \cup ops>>]
                  /\ UNCHANGED pend
             ELSE /\ pend' = [pend EXCEPT ![k] = ops]
                  /\ UNCHANGED ipend
    /\ psync' = IF SyncBeforeInstall /\ ipend[k] = <<>> /\ InstallMode \in {"synced", "unsynced"}
                THEN [psync EXCEPT ![k] = Len(pj[k])] ELSE psync
    /\ ninst' = ninst + 1
    /\ UNCHANGED <<opening, owed, stale, rep, disp, buf, wgen, rgen, wal, ckpt, redo, ij, isync, bufMark, wstate,
                   rebuild, folded, again, clock, nev, ncrash, nwcrash, nsat, nclean>>

(* The end of an install's group of cells: when it has ops, sync the     *)
(* primary (unless "unsynced"), then dispatch them.                        *)
InstallSettle(k) ==
    /\ ipend[k] # <<>>
    /\ psync' = IF InstallMode = "synced" /\ InstallOps(k) # {}
                THEN [psync EXCEPT ![k] = Len(pj[k])] ELSE psync
    /\ buf' = IF WriterTakes THEN buf \cup InstallOps(k) ELSE buf
    /\ disp' = [disp EXCEPT ![k] = ver[k]]
    /\ ipend' = [ipend EXCEPT ![k] = <<>>]
    /\ UNCHANGED <<opening, owed, stale, rep, wgen, rgen, wal, ckpt, redo, pj, pend, ver, ij, isync, bufMark, wstate,
                   rebuild, folded, again, clock, nev, ninst, ncrash, nwcrash, nsat, nclean>>

Dispatch(k) ==
    /\ pend[k] # {}
    /\ buf' = IF WriterTakes THEN buf \cup pend[k] ELSE buf
    /\ pend' = [pend EXCEPT ![k] = {}]
    /\ disp' = [disp EXCEPT ![k] = ver[k]]
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, wgen, rgen, wal, ckpt, redo, pj, psync, ver, ij, isync, bufMark, wstate,
                   rebuild, folded, again, clock, nev, ninst, ncrash, nwcrash,
                   nsat, nclean>>

SaturationDrop(k) ==
    /\ pend[k] # {} /\ nsat < MaxSaturations
    /\ pend' = [pend EXCEPT ![k] = {}]
    /\ ij' \in MarkUnmarked(ij)
    /\ rebuild' = Request(rebuild) /\ again' = RequestAgain
    /\ nsat' = nsat + 1
    /\ disp' = [disp EXCEPT ![k] = ver[k]]
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, wgen, rgen, wal, ckpt, redo, pj, psync, ver, isync, buf, bufMark,
                   wstate, folded, clock, nev, ninst, ncrash, nwcrash, nclean>>

Flush ==
    /\ wstate = "up" /\ (buf # {} \/ bufMark)
    /\ ij' = Append(ij, IOps(buf, bufMark))
    /\ buf' = {} /\ bufMark' = FALSE
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, disp, wgen, rgen, wal, ckpt, redo, pj, psync, pend, ver, isync, wstate,
                   rebuild, folded, again, clock, nev, ninst, ncrash, nwcrash,
                   nsat, nclean>>

WriterCrash ==
    /\ wstate # "down" /\ nwcrash < MaxWriterCrashes
    /\ wstate' = "down" /\ buf' = {} /\ bufMark' = FALSE
    /\ nwcrash' = nwcrash + 1
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, disp, wgen, rgen, wal, ckpt, redo, pj, psync, pend, ver, ij, isync, rebuild,
                   folded, again, clock, nev, ninst, ncrash, nsat, nclean>>

(* `init/1` in two steps; a dispatch between them reaches the writer *)
(* only when it registered first.                                     *)
WriterRegister ==
    /\ wstate = "down"
    /\ wgen' = wgen + 1
    /\ IF Intents
       THEN /\ wstate' = "stamped"
            /\ buf' = IF StampBeforeReplay THEN buf ELSE AllIntentOps(pj)
            /\ UNCHANGED <<rebuild, again>>
       ELSE /\ wstate' = "up" /\ UNCHANGED buf
            /\ rebuild' = Request(rebuild) /\ again' = RequestAgain
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, disp, rgen, wal, ckpt, redo, pj, psync, pend, ver, ij, isync, bufMark,
                   folded, clock, nev, ninst, ncrash, nwcrash, nsat, nclean>>

WriterReplay ==
    /\ wstate = "stamped"
    /\ wstate' = "up"
    /\ buf' = IF StampBeforeReplay THEN buf \cup AllIntentOps(pj) ELSE buf
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, disp, wgen, rgen, wal, ckpt, redo, pj, psync, pend, ver, ij, isync, bufMark,
                   rebuild, folded, again, clock, nev, ninst, ncrash, nwcrash,
                   nsat, nclean>>

RebuildStart ==
    /\ rebuild = "req" /\ wstate = "up"
    /\ LET u == IF RebuildUnmarks THEN <<IUnmark>> ELSE <<>>
       IN /\ ij' = ij \o u \o (IF RebuildWipes THEN <<IClear>> ELSE <<>>)
          /\ isync' = IF SyncBeforeWipe THEN Len(ij) + Len(u) ELSE isync
    /\ buf' = {} /\ bufMark' = FALSE
    /\ rebuild' = "run" /\ folded' = {} /\ again' = FALSE /\ rgen' = wgen
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, disp, wgen, wal, ckpt, redo, pj, psync, pend, ver, wstate,
                   clock, nev, ninst, ncrash, nwcrash, nsat, nclean>>

(* Runs in shard k's applier, between two of its batches. *)
RebuildFold(k) ==
    /\ rebuild = "run" /\ ~rep[k] /\ k \notin folded /\ pend[k] = {} /\ ipend[k] = <<>>
    /\ LET iv == ver[k] + 1
           ops == {Op(t, k, TRUE, IF OrderByVersion THEN iv ELSE PHlc(pj[k], k), iv) :
                     t \in Terms(PVal(pj[k], k))}
       IN /\ buf' = IF WriterTakes /\ RebuildRefolds THEN buf \cup ops ELSE buf
          /\ ver' = [ver EXCEPT ![k] = iv]
          /\ disp' = [disp EXCEPT ![k] = iv]
    /\ folded' = folded \cup {k}
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, wgen, rgen, wal, ckpt, redo, pj, psync, pend, ij, isync, bufMark,
                   wstate, rebuild, again, clock, nev, ninst, ncrash, nwcrash,
                   nsat, nclean>>

(* The orchestrator flushes the writer, then writes the trust mark. A   *)
(* request that arrived during the run removes it again (RebuildRemark). *)
RebuildMark ==
    /\ rebuild = "run" /\ folded = Keys /\ wstate # "stamped"
    /\ LET ok == wstate = "up" /\ wgen = rgen
           j == IF ok /\ (buf # {} \/ bufMark)
                THEN Append(ij, IOps(buf, bufMark)) ELSE ij
           mark == ok \/ ~MarkNeedsFlush
       IN /\ ij' = IF mark THEN Append(j, IOps({}, TRUE)) ELSE j
          /\ isync' = IF mark /\ SyncBeforeMark THEN Len(j) ELSE isync
          /\ buf' = IF ok THEN {} ELSE buf
          /\ rebuild' = CASE ~mark -> "req"
                           [] again /\ KeepRequests -> "remark"
                           [] OTHER -> "idle"
    /\ bufMark' = FALSE /\ folded' = {} /\ again' = FALSE
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, disp, wgen, rgen, wal, ckpt, redo, pj, psync, pend, ver, wstate,
                   clock, nev, ninst, ncrash, nwcrash, nsat, nclean>>

RebuildRemark ==
    /\ rebuild = "remark"
    /\ ij' \in Unmarked(ij)
    /\ rebuild' = "req"
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, disp, wgen, rgen, wal, ckpt, redo, pj, psync, pend, ver, isync, buf,
                   bufMark, wstate, folded, again, clock, nev, ninst, ncrash,
                   nwcrash, nsat, nclean>>

Applied(k) == Len(wal[k]) - Len(redo[k])

(* A checkpoint without the barrier: sync, then record what was applied. *)
Checkpoint(k) ==
    /\ psync[k] < Len(pj[k]) \/ isync < Len(ij) \/ ckpt[k] < Applied(k)
    /\ psync' = [psync EXCEPT ![k] = Len(pj[k])] /\ isync' = Len(ij)
    /\ ckpt' = [ckpt EXCEPT ![k] = Applied(k)]
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, disp, wgen, rgen, wal, redo, pj, pend, ver, ij, buf, bufMark, wstate, rebuild,
                   folded, again, clock, nev, ninst, ncrash, nwcrash, nsat, nclean>>

(* The barrier of shard k: flush (or, with the writer down, mark for    *)
(* rebuild), sync, checkpoint, then clear k's intents up to the bound    *)
(* the index records. The clear is its own primary write.                *)
Barrier(k) ==
    /\ wstate # "stamped"
    /\ \/ buf # {} \/ bufMark \/ psync[k] < Len(pj[k]) \/ isync < Len(ij)
       \/ ckpt[k] < Applied(k) \/ (Intents /\ disp[k] > ClearedUpTo(pj[k]))
    /\ IF wstate = "up"
       THEN LET j == IF buf = {} /\ ~bufMark THEN ij
                     ELSE Append(ij, IOps(buf, bufMark))
                a == CASE ClearBound = "source" -> IndexVersion(j, k)
                       [] ClearBound = "writer" -> WriterVersion(j)
                       [] ClearBound = "dispatched" -> disp[k]
                       [] ClearBound = "drawn" -> ver[k]
            IN /\ ij' = j
               /\ isync' = IF SyncBeforeClear THEN Len(j) ELSE isync
               /\ buf' = {} /\ bufMark' = FALSE
               /\ pj' = [pj EXCEPT ![k] =
                           IF Intents /\ a > ClearedUpTo(@)
                              /\ (ClearMarked \/ rebuild = "idle")
                           THEN Append(@, PClr(a)) ELSE @]
               /\ UNCHANGED <<rebuild, again>>
       ELSE /\ ij' \in MarkUnmarked(ij)
            /\ isync' = isync
            /\ rebuild' = Request(rebuild) /\ again' = RequestAgain
            /\ UNCHANGED <<buf, bufMark, pj>>
    /\ psync' = [psync EXCEPT ![k] = Len(pj[k])]
    /\ ckpt' = [ckpt EXCEPT ![k] = Applied(k)]
    /\ UNCHANGED <<ipend, opening, owed, stale, rep, disp, wgen, rgen, wal, redo, pend, ver, wstate, folded, clock, nev, ninst,
                   ncrash, nwcrash, nsat, nclean>>

(* An open after a close or a crash, with primaries P and index j. Each  *)
(* shard's counter starts at the highest version recorded. With intents,  *)
(* the writers start before the primary shards (`open_table_provision`),  *)
(* each primary shard replays its leftover intents before its applier     *)
(* starts (ReplayOpen), and an index without the trust mark is rebuilt.   *)
Open(P, j, clean) ==
    /\ ver' = [k \in Keys |->
                 CASE VersionSource = "recorded" ->
                        Max({RecordedVersion(P[k]), IndexVersion(j, k)})
                   [] VersionSource = "intents" -> RecordedVersion(P[k])
                   [] VersionSource = "reset" -> 0]
    /\ wstate' = "up" /\ buf' = {} /\ bufMark' = FALSE
    /\ owed' = [ops |-> {}, at |-> Len(j)]
    /\ folded' = {} /\ again' = FALSE /\ stale' = FALSE
    /\ IF Intents
       THEN /\ rep' = [k \in Keys |-> TRUE]
            /\ disp' = [k \in Keys |->
                          IF OpenDispatched = "cleared" THEN ClearedUpTo(P[k])
                          ELSE ver'[k]]
            /\ rebuild' = IF Trusted(j) THEN "idle" ELSE "req"
            /\ opening' = Trusted(j)
       ELSE /\ rep' = [k \in Keys |-> FALSE] /\ disp' = ver'
            /\ opening' = FALSE
            /\ rebuild' = IF (RebuildAtOpen /\ ~clean) \/ ~Trusted(j)
                          THEN "req" ELSE "idle"

CrashAndOpen ==
    /\ ncrash < MaxCrashes
    /\ \E P \in [Keys -> UNION {Survivors(pj[k], psync[k], CrashKeeps) : k \in Keys}],
          j \in Survivors(ij, isync, IndexCrashKeeps) :
        /\ \A k \in Keys : P[k] \in Survivors(pj[k], psync[k], CrashKeeps)
        /\ pj' = P /\ ij' = j
        /\ Open(P, j, FALSE)
    /\ redo' = [k \in Keys |-> SubSeq(wal[k], ckpt[k] + 1, Len(wal[k]))]
    /\ psync' = [k \in Keys |-> Len(pj'[k])] /\ isync' = Len(ij')
    /\ pend' = [k \in Keys |-> {}] /\ ipend' = [k \in Keys |-> <<>>]
    /\ ncrash' = ncrash + 1
    /\ UNCHANGED <<wgen, rgen, wal, ckpt, clock, nev, ninst, nwcrash, nsat, nclean>>

(* A clean close, then an open. The close stops the primaries with nothing  *)
(* left to apply or dispatch, syncs both stores and checkpoints. Without    *)
(* intents it first flushes the writer and, the index being trusted, stamps *)
(* the clean flag, which the open finds, so it runs no rebuild. With        *)
(* intents the close does not flush: the open replays the writer's buffer.  *)
CleanReopen ==
    /\ nclean < MaxCleanReopens
    /\ \A k \in Keys : redo[k] = <<>> /\ pend[k] = {} /\ ipend[k] = <<>>
    /\ wstate = "up" /\ rebuild = "idle" /\ ~bufMark /\ Trusted(ij)
    /\ LET j == IF Intents \/ buf = {} THEN ij ELSE Append(ij, IOps(buf, FALSE))
       IN /\ ij' = j /\ isync' = Len(j)
          /\ Open(pj, j, TRUE)
    /\ psync' = [k \in Keys |-> Len(pj[k])]
    /\ ckpt' = [k \in Keys |-> Applied(k)]
    /\ nclean' = nclean + 1
    /\ UNCHANGED <<ipend, wal, redo, pj, pend, wgen, rgen, clock, nev, ninst, ncrash,
                   nwcrash, nsat>>

(* Shard k replays its leftover intents through the dispatch path, after   *)
(* its row is registered and before its applier starts. A barrier of a     *)
(* shared instance may run meanwhile.                                       *)
ReplayOpen(k) ==
    /\ rep[k]
    /\ LET ops == IntentOps(pj[k])
       IN /\ buf' = IF WriterTakes THEN buf \cup ops ELSE buf
          /\ disp' = [disp EXCEPT ![k] = Max({@} \cup {o.iv : o \in ops})]
          /\ owed' = [owed EXCEPT !.ops = @ \cup ops]
    /\ rep' = [rep EXCEPT ![k] = FALSE]
    /\ UNCHANGED <<ipend, opening, stale, wal, ckpt, redo, pj, psync, pend, ver, ij, isync, bufMark,
                   wstate, wgen, rgen, rebuild, folded, again, clock, nev,
                   ninst, ncrash, nwcrash, nsat, nclean>>

(* A trusting open, once every primary shard has replayed, flushes the  *)
(* writer (OpenFlushes) and freshens the index, which lets a bounded-lag  *)
(* read through (`bondy_db:cold_start_indexes/3`). A call to a writer     *)
(* still in `init/1` waits for it. A call to a dead writer fails, and     *)
(* the open then leaves the index unfreshened (FreshenNeedsFlush): the    *)
(* restarted writer replays the intents. An index that lost its trust     *)
(* mark meanwhile is rebuilt, not freshened.                              *)
Freshen ==
    /\ opening /\ \A k \in Keys : ~rep[k]
    /\ ~(OpenFlushes /\ wstate = "stamped")
    /\ opening' = FALSE
    /\ LET flushed == OpenFlushes /\ wstate = "up"
           j == IF flushed /\ (buf # {} \/ bufMark)
                THEN Append(ij, IOps(buf, bufMark)) ELSE ij
       IN IF OpenFlushes /\ ~flushed /\ FreshenNeedsFlush
          THEN UNCHANGED <<ij, buf, bufMark, stale>>
          ELSE /\ ij' = j
               /\ stale' = Trusted(j) /\ \E o \in owed.ops : ~Reflected(j, o, owed.at)
               /\ buf' = IF flushed THEN {} ELSE buf
               /\ bufMark' = IF flushed THEN FALSE ELSE bufMark
    /\ UNCHANGED <<ipend, wal, ckpt, redo, pj, psync, pend, ver, disp, isync, wstate,
                   wgen, rgen, rebuild, folded, again, rep, owed, clock, nev,
                   ninst, ncrash, nwcrash, nsat, nclean>>

Next ==
    \/ \E k \in Keys, vs \in Seqs(MaxBatch) : Write(k, vs)
    \/ \E k \in Keys, v \in Vals, h0 \in 1..clock : Install(k, v, h0)
    \/ \E k \in Keys : \/ Redo(k) \/ Dispatch(k) \/ SaturationDrop(k)
                       \/ RebuildFold(k) \/ Checkpoint(k) \/ Barrier(k)
                       \/ ReplayOpen(k) \/ InstallSettle(k)
    \/ Flush \/ WriterCrash \/ WriterRegister \/ WriterReplay
    \/ RebuildStart \/ RebuildMark \/ RebuildRemark
    \/ CrashAndOpen \/ CleanReopen \/ Freshen

Spec == Init /\ [][Next]_vars

(* A state constraint, like the Max* bounds: runs whose index journal grows *)
(* past MaxIndexEntries are not explored.                                   *)
IndexBound == Len(ij) <= MaxIndexEntries

(* The shards are interchangeable: no definition picks one by name. *)
KeySym == Permutations(Keys)

TypeOK ==
    /\ wstate \in {"up", "down", "stamped"}
    /\ rebuild \in {"idle", "req", "run", "remark"}
    /\ isync \in 0..Len(ij)

Quiescent ==
    /\ \A k \in Keys : redo[k] = <<>> /\ pend[k] = {} /\ ipend[k] = <<>> /\ ~rep[k]
    /\ buf = {} /\ ~bufMark /\ wstate = "up" /\ rebuild = "idle"
    /\ Trusted(ij)

(* Once nothing is in flight and the index is trusted, it holds exactly *)
(* the terms of the primary.                                             *)
(* An index the open freshened holds every op the open replayed. *)
FreshMeansComplete == ~stale

IndexMatchesPrimary ==
    Quiescent =>
        \A k \in Keys, t \in Vals :
            IdxLive(ij, t, k) <=> t \in Terms(PVal(pj[k], k))
=============================================================================
