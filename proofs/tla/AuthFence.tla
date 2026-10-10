------------------------------ MODULE AuthFence ------------------------------
(***************************************************************************)
(* The authentication freshness fence (`bondy_auth:security_fence/0` over  *)
(* `bondy_db:ensure_fresh/2`): a node authenticates only while its view of *)
(* the security tables was confirmed within MaxLag.                         *)
(*                                                                         *)
(* A confirmation stamps the node's freshness clock:                        *)
(*   - Sync: a successful pull from a peer (`bondy_oplog_sync_session`),    *)
(*     which merges the peer's view into ours.                              *)
(*   - Isolated: a scheduler round with no peer                             *)
(*     (`maybe_bump_ae_isolated/1`). A node with clustering off always      *)
(*     confirms; a clustered one follows `db.aae.fence.on_isolation`:       *)
(*     "refuse" never confirms, "proceed" always does.                      *)
(*   - LocalCommit: an applier commit of local writes (`bump_ae_targets/1` *)
(*     in `bondy_oplog_applier:commit_now/1`), when CommitBumps = TRUE.    *)
(*                                                                         *)
(* FenceSafe: once a revocation made at r1 is older than MaxLag, a node    *)
(* whose fence passes has seen it.                                         *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Nodes,
    r1,           \* the node that makes the revocation
    MaxLag,
    MaxTime,
    Clustered,    \* clustering on
    Policy,       \* "refuse" | "proceed"
    CommitBumps   \* a local commit confirms freshness

ASSUME r1 \in Nodes /\ Policy \in {"refuse", "proceed"}

VARIABLES now, conf, rev, revokedAt, link

vars == <<now, conf, rev, revokedAt, link>>

Init ==
    /\ now = 0
    /\ conf = [n \in Nodes |-> 0]
    /\ rev = [n \in Nodes |-> FALSE]
    /\ revokedAt = 0
    /\ link = TRUE

Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ UNCHANGED <<conf, rev, revokedAt, link>>

Revoke ==
    /\ revokedAt = 0 /\ now > 0
    /\ rev' = [rev EXCEPT ![r1] = TRUE]
    /\ revokedAt' = now
    /\ UNCHANGED <<now, conf, link>>

Sync(n, m) ==
    /\ n # m /\ link
    /\ rev' = [rev EXCEPT ![n] = rev[n] \/ rev[m]]
    /\ conf' = [conf EXCEPT ![n] = now]
    /\ UNCHANGED <<now, revokedAt, link>>

Peers(n) == IF link THEN Nodes \ {n} ELSE {}

Isolated(n) ==
    /\ Peers(n) = {}
    /\ ~Clustered \/ Policy = "proceed"
    /\ conf' = [conf EXCEPT ![n] = now]
    /\ UNCHANGED <<now, rev, revokedAt, link>>

LocalCommit(n) ==
    /\ CommitBumps
    /\ conf' = [conf EXCEPT ![n] = now]
    /\ UNCHANGED <<now, rev, revokedAt, link>>

Partition ==
    /\ link /\ Clustered
    /\ link' = FALSE
    /\ UNCHANGED <<now, conf, rev, revokedAt>>

Heal ==
    /\ ~link
    /\ link' = TRUE
    /\ UNCHANGED <<now, conf, rev, revokedAt>>

Next ==
    \/ Tick \/ Revoke \/ Partition \/ Heal
    \/ \E n, m \in Nodes : Sync(n, m)
    \/ \E n \in Nodes : Isolated(n) \/ LocalCommit(n)

Spec == Init /\ [][Next]_vars

Passes(n) == now - conf[n] <= MaxLag

FenceSafe ==
    \A n \in Nodes :
        (revokedAt > 0 /\ now - revokedAt > MaxLag /\ Passes(n)) => rev[n]

TypeOK ==
    /\ now \in 0..MaxTime
    /\ conf \in [Nodes -> 0..MaxTime]
    /\ rev \in [Nodes -> BOOLEAN]
=============================================================================
