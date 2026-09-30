----------------------------- MODULE RibAbs -------------------------------
(***************************************************************************)
(* A RIB cell's count (`bondy_oplog_crdt_owned_reading`): the owner      *)
(* replicates its latest READING of the live count, `<<Stamp, Count>>`,    *)
(* and a replica's value is the count of the highest-stamped reading it    *)
(* holds. Nothing is ever corrected by arithmetic.                         *)
(*                                                                         *)
(* A local writer (a registration or unregistration, a self-heal, or a     *)
(* restore) does three steps, each atomic and interleavable with other     *)
(* writers: take a stamp from the owner's clock (strictly increasing       *)
(* within an incarnation), read the live count, write the reading under    *)
(* the DB's current origin. The row op that changes `live` happens before *)
(* the stamp.                                                              *)
(*                                                                         *)
(* Owner events:                                                           *)
(*  - Reboot: sessions die (`live` = 0, in-flight writers lost). With      *)
(*    `Durable` the DB keeps its origin, seqs and local state, and the     *)
(*    owner replays its own cells through self-heal at boot. Without it   *)
(*    the DB is empty and takes a fresh origin. The clock restarts from   *)
(*    wall time: above everything before, or, with `ClockRegress`, at 0.  *)
(*  - Reopen (ephemeral only): the DB's storage is lost in a running VM;   *)
(*    sessions survive, the DB takes a fresh origin, and a restore writer *)
(*    restates the cell.                                                   *)
(*  - Restart (ephemeral only): one oplog instance of the DB restarts in   *)
(*    a running VM. Its log, seq counter and in-flight async writes die   *)
(*    with it and it takes a fresh origin; the projection (the cell) and  *)
(*    the frontier live elsewhere and survive. The owner can no longer    *)
(*    ship the events it held. With `RestartRestore` a restore writer     *)
(*    restates the cell; with `RestartReopens` the restart instead makes  *)
(*    a Reopen due, which happens even past `MaxResets`.                  *)
(*                                                                         *)
(* Self-heal runs on the owner after a merge of its own cell (and at a     *)
(* durable boot): if the cell's value differs from `live`, it advances    *)
(* the clock past the highest stamp in the cell and writes a reading.      *)
(*                                                                         *)
(* Reap: an origin no member advertises (every origin but the owner's      *)
(* current one) has its readings dropped from a replica's cell once it is *)
(* in that replica's frontier; with `SweepOnce` a swept origin is never    *)
(* rescanned.                                                              *)
(*                                                                         *)
(* Stubs: a peer's routing view of the cell, refreshed only by a merge     *)
(* event on that peer. With `StubFollowsCell`, a sweep also zeroes a stub *)
(* whose cell is gone.                                                     *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    Peers,          \* the other replicas
    MaxOps,         \* registrations + unregistrations the owner performs
    MaxResets,      \* reboots + reopens
    MaxStamp,       \* bound on the owner's clock
    Durable,
    ReopenEnabled,
    RestartEnabled,
    RestartRestore,
    RestartReopens,
    ClockRegress,
    SelfHealEnabled,
    HealOnAbsent,
    HealOnForeignTop,
    HealAlways,
    ReapEnabled,
    SweepOnce,
    StubFollowsCell

Owner == "owner"
Replicas == {Owner} \cup Peers
NoWriter == [ph |-> "idle", s |-> 0]
Writers == 1..2

VARIABLES
    org,        \* the owner DB's current origin
    live,       \* the owner's live registrations: the truth
    ops,
    resets,
    clock,      \* the owner's stamp clock
    minted,     \* [origin -> last seq]
    writer,     \* [Writers -> in-flight writer]
    applied,    \* [Replicas -> SUBSET Event]  (the frontier)
    cell,       \* [Replicas -> SUBSET Event]  (readings held, after reaps)
    swept,      \* [Replicas -> SUBSET origins]
    stub,       \* [Peers -> Int]
    healPending,
    lost,       \* events the owner holds applied but can no longer ship
    due         \* a Reopen the owner's catalogue owes

vars == <<org, live, ops, resets, clock, minted, writer, applied, cell,
          swept, stub, healPending, lost, due>>

Origins == 1..(MaxResets + 2)
Event == [o : Origins, q : Nat, s : Nat, c : Nat]

Top(S) == CHOOSE e \in S : \A f \in S : f.s < e.s \/ (f.s = e.s /\ f.c =< e.c)
Value(r) == IF cell[r] = {} THEN 0 ELSE Top(cell[r]).c

Init ==
    /\ org = 1
    /\ live = 0
    /\ ops = 0
    /\ resets = 0
    /\ clock = 0
    /\ minted = [o \in Origins |-> 0]
    /\ writer = [w \in Writers |-> NoWriter]
    /\ applied = [r \in Replicas |-> {}]
    /\ cell = [r \in Replicas |-> {}]
    /\ swept = [r \in Replicas |-> {}]
    /\ stub = [p \in Peers |-> 0]
    /\ healPending = FALSE
    /\ lost = {}
    /\ due = FALSE

Idle(w) == writer[w].ph = "idle"

Spawn(w) == writer' = [writer EXCEPT ![w] = [ph |-> "stamp", s |-> 0]]

\* A registration or unregistration: the row op, then a writer.
RowOp(d) ==
    /\ ops < MaxOps
    /\ live + d >= 0
    /\ \E w \in Writers : Idle(w) /\ Spawn(w)
    /\ ops' = ops + 1
    /\ live' = live + d
    /\ UNCHANGED <<org, resets, clock, minted, applied, cell, swept, stub,
                   healPending, lost, due>>

Stamp(w) ==
    /\ writer[w].ph = "stamp"
    /\ clock < MaxStamp
    /\ clock' = clock + 1
    /\ writer' = [writer EXCEPT ![w] = [ph |-> "read", s |-> clock + 1]]
    /\ UNCHANGED <<org, live, ops, resets, minted, applied, cell, swept, stub,
                   healPending, lost, due>>

ReadAndWrite(w) ==
    LET e == [o |-> org, q |-> minted[org] + 1, s |-> writer[w].s, c |-> live]
    IN
    /\ writer[w].ph = "read"
    /\ minted' = [minted EXCEPT ![org] = @ + 1]
    /\ applied' = [applied EXCEPT ![Owner] = @ \cup {e}]
    /\ cell' = [cell EXCEPT ![Owner] = @ \cup {e}]
    /\ writer' = [writer EXCEPT ![w] = NoWriter]
    /\ UNCHANGED <<org, live, ops, resets, clock, swept, stub, healPending, lost, due>>

Reboot ==
    /\ resets < MaxResets
    /\ resets' = resets + 1
    /\ live' = 0
    /\ writer' = [w \in Writers |-> NoWriter]
    /\ \/ clock' = clock + 1
       \/ ClockRegress /\ clock' = 0
    /\ IF Durable
         THEN /\ healPending' = TRUE
              /\ UNCHANGED <<org, applied, cell, swept>>
         ELSE /\ org' = org + 1
              /\ applied' = [applied EXCEPT ![Owner] = {}]
              /\ cell' = [cell EXCEPT ![Owner] = {}]
              /\ swept' = [swept EXCEPT ![Owner] = {}]
              /\ healPending' = FALSE
    /\ lost' = {}
    /\ due' = FALSE
    /\ UNCHANGED <<ops, minted, stub>>

\* The DB's storage is lost in a running VM; sessions and in-flight
\* writers survive, and a restore writer restates the cell.
Reopen ==
    /\ \/ ReopenEnabled /\ resets < MaxResets
       \/ due
    /\ ~Durable
    /\ resets' = resets + 1
    /\ due' = FALSE
    /\ org' = org + 1
    /\ applied' = [applied EXCEPT ![Owner] = {}]
    /\ cell' = [cell EXCEPT ![Owner] = {}]
    /\ \E w \in Writers : Idle(w) /\ Spawn(w)
    /\ healPending' = FALSE
    /\ lost' = {}
    /\ UNCHANGED <<live, ops, clock, minted, swept, stub>>

\* The owner's DB loses one instance's process state in a running VM.
Restart ==
    /\ RestartEnabled
    /\ ~Durable
    /\ resets < MaxResets
    /\ resets' = resets + 1
    /\ org' = org + 1
    /\ lost' = applied[Owner]
    /\ due' = RestartReopens
    /\ \E keep \in SUBSET Writers :
         LET w1 == [w \in Writers |->
                      IF w \in keep \/ writer[w].ph # "read"
                        THEN writer[w] ELSE NoWriter]
         IN IF RestartRestore
              THEN \E w \in Writers :
                     /\ w1[w].ph = "idle"
                     /\ writer' = [w1 EXCEPT ![w] = [ph |-> "stamp", s |-> 0]]
              ELSE writer' = w1
    /\ UNCHANGED <<live, ops, clock, minted, applied, cell, swept, stub,
                   healPending>>

Deliver(r, src, e) ==
    /\ src = Owner => e \notin lost
    /\ \A f \in applied[src] : (f.o = e.o /\ f.q < e.q) => f \in applied[r]
    /\ e \notin applied[r]
    /\ applied' = [applied EXCEPT ![r] = @ \cup {e}]
    /\ cell' = [cell EXCEPT ![r] = @ \cup {e}]
    /\ IF r = Owner
         THEN /\ healPending' = TRUE
              /\ UNCHANGED stub
         ELSE /\ stub' = [stub EXCEPT ![r] =
                  LET S == cell[r] \cup {e} IN Top(S).c]
              /\ UNCHANGED healPending
    /\ UNCHANGED <<org, live, ops, resets, clock, minted, writer, swept, lost, due>>

TopStamp(r) == IF cell[r] = {} THEN 0 ELSE Top(cell[r]).s
Max2(a, b) == IF a > b THEN a ELSE b

\* The owner's reaction to a merge of its own cell. Its clock absorbs the
\* cell's top stamp (as an HLC absorbs a received timestamp); it writes a
\* reading when the cell disagrees with `live`, and, with `HealOnAbsent`,
\* also when the cell is gone.
SelfHeal ==
    /\ SelfHealEnabled
    /\ healPending
    /\ healPending' = FALSE
    /\ IF \/ HealAlways
          \/ cell[Owner] = {} /\ HealOnAbsent
          \/ cell[Owner] # {} /\ Value(Owner) # live
          \/ cell[Owner] # {} /\ HealOnForeignTop /\ Top(cell[Owner]).o # org
         THEN \E w \in Writers :
                /\ Idle(w)
                /\ Spawn(w)
                /\ clock' = Max2(clock, TopStamp(Owner))
         ELSE /\ clock' = Max2(clock, TopStamp(Owner))
              /\ UNCHANGED writer
    /\ UNCHANGED <<org, live, ops, resets, minted, applied, cell, swept, stub, lost, due>>

Reap(r, o) ==
    /\ ReapEnabled
    /\ o # org
    /\ \E e \in applied[r] : e.o = o
    /\ ~(SweepOnce /\ o \in swept[r])
    /\ \E e \in cell[r] : e.o = o
    /\ cell' = [cell EXCEPT ![r] = {e \in @ : e.o # o}]
    /\ swept' = [swept EXCEPT ![r] = @ \cup {o}]
    /\ UNCHANGED <<org, live, ops, resets, clock, minted, writer, applied, stub,
                   healPending, lost, due>>

StubSweep(p) ==
    /\ StubFollowsCell
    /\ cell[p] = {}
    /\ stub[p] # 0
    /\ stub' = [stub EXCEPT ![p] = 0]
    /\ UNCHANGED <<org, live, ops, resets, clock, minted, writer, applied, cell,
                   swept, healPending, lost, due>>

Next ==
    \/ RowOp(1)
    \/ RowOp(-1)
    \/ \E w \in Writers : Stamp(w) \/ ReadAndWrite(w)
    \/ Reboot
    \/ Reopen
    \/ Restart
    \/ \E r \in Replicas : \E src \in Replicas \ {r} :
         \E e \in applied[src] : Deliver(r, src, e)
    \/ SelfHeal
    \/ \E r \in Replicas, o \in Origins : Reap(r, o)
    \/ \E p \in Peers : StubSweep(p)

Spec == Init /\ [][Next]_vars

PeerSym == Permutations(Peers)

(***************************************************************************)
(* PROPERTIES, on settled states (no action enabled)                      *)
(***************************************************************************)

Settled == ~ENABLED Next

\* A writer blocked only by the stamp bound is a truncated run, not a
\* settled one.
Truncated == \E w \in Writers : writer[w].ph = "stamp" /\ clock >= MaxStamp

SettledCellIsTruth ==
    (Settled /\ ~Truncated) => \A r \in Replicas : Value(r) = live

SettledStubIsTruth ==
    (Settled /\ ~Truncated) => \A p \in Peers : stub[p] = live

TypeOK ==
    /\ live \in Nat
    /\ \A r \in Replicas : cell[r] \subseteq applied[r]

=============================================================================
