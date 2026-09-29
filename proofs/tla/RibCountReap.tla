---------------------------- MODULE RibCountReap ------------------------------
(***************************************************************************)
(* Does a registry RIB cell's `count` end up equal to its owner's live     *)
(* registrations once everything has settled, when the owner reboots under *)
(* a new origin and BOTH `self_heal` and the retirement reap act on the    *)
(* previous origin's contribution?                                         *)
(*                                                                         *)
(* The cell is `{Realm, Policy, Uri, OwnerNode}`, single-writer. `count`   *)
(* is a `bondy_oplog_crdt_pn_counter` field of a `bondy_oplog_crdt_struct` *)
(* declared `force_reap => true` (`bondy_namespace_catalog`'s              *)
(* `?RIB_REGISTRATION_SCHEMA`), so its value is the SUM of one net entry   *)
(* per origin, and `reap_origins/2` DELETES a retired origin's entry. That *)
(* makes this reap value-changing, which is why `CellContextReap.tla`      *)
(* (value-preserving context reap) does not cover it.                      *)
(*                                                                         *)
(* Modelled, from the code:                                                *)
(*  - owner writes: `apply_added/1` `{inc,1}`, `apply_removed/1`           *)
(*    `{inc,-1}`, under the owner's CURRENT origin;                        *)
(*  - reboot: the `registry` DB is in memory with no `storage_path`, so it *)
(*    takes `bondy_oplog_origin:default/0`, fresh per VM boot              *)
(*    (`bondy_oplog_instance_sup:resolve_origin_opt/2`); the owner's cell   *)
(*    copy, frontier and live registrations are all gone;                 *)
(*  - anti-entropy: pull-only delivery, per-origin FIFO, filtered by the   *)
(*    receiver's applied set;                                              *)
(*  - `self_heal/4` runs ONLY as the owner's reaction to a merge of its    *)
(*    own cell (`on_remote_set/3`, `on_remote_clear/2`), writes           *)
(*    `LocalCount - CellCount` under the current origin, and skips when   *)
(*    the cell does not exist;                                             *)
(*  - reap: an origin is dead when no member advertises it                 *)
(*    (`reap_complement/4`: frontier origins minus live origins); it is    *)
(*    reaped from a replica only once it is in that replica's frontier,   *)
(*    and with `SweepOnce` a swept origin is never scanned again           *)
(*    (`Swept` in `reap_complement/4`).                                    *)
(*                                                                         *)
(* Not modelled: `stabilize/2` discard at zero, the periodic `check/1`     *)
(* (it only logs), subscriptions (same shape, owned counter), and the      *)
(* per-peer stubs routing actually reads (refreshed only by a merge event, *)
(* `on_remote_set/3`); `Count` here is the replicated cell.                *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    NumOrigins,      \* owner boots: origin i is the owner's i-th incarnation
    MaxOps,          \* registrations + unregistrations the owner performs
    SelfHealEnabled,
    ReapEnabled,
    SweepOnce

Replicas == {"owner", "peer"}
Origins == 1..NumOrigins
Other(r) == IF r = "owner" THEN "peer" ELSE "owner"

VARIABLES
    gen,         \* the owner's current origin
    live,        \* the owner's live registrations: the truth `count` must match
    ops,         \* owner registrations/unregistrations performed
    minted,      \* [Origins -> Nat] last seq minted per origin
    applied,     \* [Replicas -> SUBSET Event]
    cell,        \* [Replicas -> [Origins -> Int]] per-origin net entry
    swept,       \* [Replicas -> SUBSET Origins]
    healPending  \* a merge of the owner's cell reached the owner

vars == <<gen, live, ops, minted, applied, cell, swept, healPending>>

Event == [org : Origins, seq : Nat, d : Int]

RECURSIVE SumOver(_, _)
SumOver(f, S) ==
    IF S = {} THEN 0
    ELSE LET o == CHOOSE x \in S : TRUE IN f[o] + SumOver(f, S \ {o})

Count(r) == SumOver(cell[r], Origins)

Init ==
    /\ gen = 1
    /\ live = 0
    /\ ops = 0
    /\ minted = [o \in Origins |-> 0]
    /\ applied = [r \in Replicas |-> {}]
    /\ cell = [r \in Replicas |-> [o \in Origins |-> 0]]
    /\ swept = [r \in Replicas |-> {}]
    /\ healPending = FALSE

\* A local write by the owner under its current origin.
OwnerWrite(d) ==
    LET e == [org |-> gen, seq |-> minted[gen] + 1, d |-> d] IN
    /\ minted' = [minted EXCEPT ![gen] = @ + 1]
    /\ applied' = [applied EXCEPT !["owner"] = @ \cup {e}]
    /\ cell' = [cell EXCEPT !["owner"][gen] = @ + d]

Register ==
    /\ ops < MaxOps
    /\ ops' = ops + 1
    /\ live' = live + 1
    /\ OwnerWrite(1)
    /\ UNCHANGED <<gen, swept, healPending>>

Unregister ==
    /\ ops < MaxOps
    /\ live > 0
    /\ ops' = ops + 1
    /\ live' = live - 1
    /\ OwnerWrite(-1)
    /\ UNCHANGED <<gen, swept, healPending>>

\* A reboot: new VM origin; the in-memory registry and its sessions are gone.
Reboot ==
    /\ gen < NumOrigins
    /\ gen' = gen + 1
    /\ live' = 0
    /\ applied' = [applied EXCEPT !["owner"] = {}]
    /\ cell' = [cell EXCEPT !["owner"] = [o \in Origins |-> 0]]
    /\ swept' = [swept EXCEPT !["owner"] = {}]
    /\ healPending' = FALSE
    /\ UNCHANGED <<ops, minted>>

\* Anti-entropy delivery of an event the other replica holds.
Deliver(r, e) ==
    /\ e \in applied[Other(r)]
    /\ e \notin applied[r]
    /\ \A f \in applied[Other(r)] :
         (f.org = e.org /\ f.seq < e.seq) => f \in applied[r]
    /\ applied' = [applied EXCEPT ![r] = @ \cup {e}]
    /\ cell' = [cell EXCEPT ![r][e.org] = @ + e.d]
    /\ healPending' = IF r = "owner" THEN TRUE ELSE healPending
    /\ UNCHANGED <<gen, live, ops, minted, swept>>

\* `self_heal/4` on the owner, reacting to a merge of its own cell.
SelfHeal ==
    /\ SelfHealEnabled
    /\ healPending
    /\ healPending' = FALSE
    /\ IF applied["owner"] # {} /\ live - Count("owner") # 0
         THEN OwnerWrite(live - Count("owner"))
         ELSE UNCHANGED <<minted, applied, cell>>
    /\ UNCHANGED <<gen, live, ops, swept>>

\* The retirement pass on replica `r` reaping origin `o`: claimed by no
\* member (only the owner's current origin is), present in `r`'s frontier.
Reap(r, o) ==
    /\ ReapEnabled
    /\ o # gen
    /\ \E e \in applied[r] : e.org = o
    /\ ~(SweepOnce /\ o \in swept[r])
    /\ cell[r][o] # 0 \/ o \notin swept[r]
    /\ cell' = [cell EXCEPT ![r][o] = 0]
    /\ swept' = [swept EXCEPT ![r] = @ \cup {o}]
    /\ UNCHANGED <<gen, live, ops, minted, applied, healPending>>

Next ==
    \/ Register
    \/ Unregister
    \/ Reboot
    \/ \E r \in Replicas : \E e \in applied[Other(r)] : Deliver(r, e)
    \/ SelfHeal
    \/ \E r \in Replicas, o \in Origins : Reap(r, o)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

Settled == ~ENABLED Next

\* Once nothing more can happen, every replica's `count` for the owner's
\* cell equals the owner's live registrations.
SettledCountIsTruth ==
    Settled => \A r \in Replicas : Count(r) = live

\* Weaker: a settled count is never below the truth (a count below the
\* truth hides live registrations from routing).
SettledNeverUnderCounts ==
    Settled => \A r \in Replicas : Count(r) >= live

\* The harm users see: the owner has live registrations, yet every replica
\* settles on a count that routing treats as absent (`count =< 0`).
SettledLiveIsRoutable ==
    Settled => (live > 0 => \A r \in Replicas : Count(r) > 0)

=============================================================================
