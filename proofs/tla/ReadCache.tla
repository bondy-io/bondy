---------------------------- MODULE ReadCache ----------------------------
(* One key of a per-shard read cache in front of a projection.            *)
(* Writers: write the projection, then invalidate the cache entry.       *)
(* Readers: on a miss, read the projection and fill the cache.           *)
(* An invalidation bumps a per-shard generation before it       *)
(* deletes; a reader takes the generation before its projection read and *)
(* after its fill re-reads it, removing its own row if it changed.       *)
EXTENDS Naturals

CONSTANTS Readers, Writers, MaxW,
          UseTicket,        \* ticket + re-check after fill
          BumpFirst,        \* invalidation bumps before it deletes
          DeleteOwnObject   \* re-check removes only the row it wrote

None == 0 - 1  \* not a projection value (values are 0..MaxW)

VARIABLES src, cache, gen, rpc, t, v, wpc, written
vars == <<src, cache, gen, rpc, t, v, wpc, written>>

Init ==
  /\ src = 0 /\ cache = None /\ gen = 0 /\ written = 0
  /\ rpc = [r \in Readers |-> "idle"]
  /\ t = [r \in Readers |-> 0]
  /\ v = [r \in Readers |-> None]
  /\ wpc = [w \in Writers |-> "idle"]

(* Writer: projection write, then invalidate (bump and delete, in either order). *)
WWrite(w) ==
  /\ wpc[w] = "idle" /\ written < MaxW
  /\ written' = written + 1 /\ src' = written + 1
  /\ wpc' = [wpc EXCEPT ![w] = "inv1"]
  /\ UNCHANGED <<cache, gen, rpc, t, v>>

Bump == gen' = gen + 1
Del  == cache' = None

WInv1(w) ==
  /\ wpc[w] = "inv1"
  /\ IF BumpFirst THEN Bump /\ UNCHANGED cache ELSE Del /\ UNCHANGED gen
  /\ wpc' = [wpc EXCEPT ![w] = "inv2"]
  /\ UNCHANGED <<src, rpc, t, v, written>>

WInv2(w) ==
  /\ wpc[w] = "inv2"
  /\ IF BumpFirst THEN Del /\ UNCHANGED gen ELSE Bump /\ UNCHANGED cache
  /\ wpc' = [wpc EXCEPT ![w] = "idle"]
  /\ UNCHANGED <<src, rpc, t, v, written>>

(* Reader on a miss. *)
RTicket(r) ==
  /\ rpc[r] = "idle" /\ cache = None
  /\ t' = [t EXCEPT ![r] = gen]
  /\ rpc' = [rpc EXCEPT ![r] = "read"]
  /\ UNCHANGED <<src, cache, gen, v, wpc, written>>

RRead(r) ==
  /\ rpc[r] = "read"
  /\ v' = [v EXCEPT ![r] = src]
  /\ rpc' = [rpc EXCEPT ![r] = "fill"]
  /\ UNCHANGED <<src, cache, gen, t, wpc, written>>

RFill(r) ==
  /\ rpc[r] = "fill"
  /\ cache' = v[r]
  /\ rpc' = [rpc EXCEPT ![r] = IF UseTicket THEN "check" ELSE "idle"]
  /\ UNCHANGED <<src, gen, t, v, wpc, written>>

RCheck(r) ==
  /\ rpc[r] = "check"
  /\ IF gen # t[r] /\ (~DeleteOwnObject \/ cache = v[r])
       THEN cache' = None ELSE UNCHANGED cache
  /\ rpc' = [rpc EXCEPT ![r] = "idle"]
  /\ UNCHANGED <<src, gen, t, v, wpc, written>>

Evict == cache # None /\ cache' = None
         /\ UNCHANGED <<src, gen, rpc, t, v, wpc, written>>

Next ==
  \/ \E w \in Writers : WWrite(w) \/ WInv1(w) \/ WInv2(w)
  \/ \E r \in Readers : RTicket(r) \/ RRead(r) \/ RFill(r) \/ RCheck(r)
  \/ Evict

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ src \in 0..MaxW /\ cache \in {None} \cup 0..MaxW /\ gen \in Nat

(* Once every process is idle, the cache holds nothing or the projection value. *)
SettledCoherent ==
  ((\A r \in Readers : rpc[r] = "idle") /\ (\A w \in Writers : wpc[w] = "idle"))
    => cache \in {None, src}

(* Stronger, read-after-write: once writers are idle, a hit never returns an *)
(* older value, whatever readers are doing. Checked to measure the window.  *)
WritersIdleCoherent ==
  (\A w \in Writers : wpc[w] = "idle") => cache \in {None, src}
=============================================================================
