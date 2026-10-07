# Clustering

Whether a node clusters is decided by one setting, `cluster.enabled`. Every
part of Bondy that asks "does this node have other members to wait for?" —
compaction, reclamation, origin retirement, the authentication freshness fence
— reads that setting rather than inferring the answer from how many members
the node can currently see.

## `cluster.enabled` (`bondy_cluster.enabled`)

`on | off`, default `on`. Read at node start.

With `on`, the node starts the cluster peer service and replicates through
anti-entropy when `db.aae` is on.

With `off`, the node runs without clustering
(`bondy_cluster_standalone_SUITE`):

- the cluster peer service is never started, so the node opens no cluster
  port and peer discovery does not run;
- `bondy.cluster.members` answers this node only;
- anti-entropy replication is not wired;
- the authentication freshness fence certifies the node, so authentication
  works with `db.aae` on;
- the insecure-peer-plane refusal does not apply, because there is no peer
  plane;
- `bondy.cluster.leave` answers `bondy.error.cluster_disabled` (`K004`) and
  changes nothing;
- compaction and reclamation run on the node's own frontier (see
  [History when clustering is disabled](#history-when-clustering-is-disabled)).

An application that embeds the storage libraries and does not set
`bondy_cluster.enabled` runs with clustering disabled.

## Running a single node

Set `cluster.enabled = off`.

A node left on `on` with no other member does not behave as a single node.
Bondy does not persist the cluster membership, so a member that has just
restarted lists only itself until it rejoins. With clustering enabled, a
membership that lists no other node therefore cannot be told apart from a
restarted member, and it licenses nothing:

- compaction and reclamation hold and report `no_members` in their telemetry
  and in the ["GC stalled"](../reference/log_messages.md#gc-stalled) warning
  (`bondy_oplog_compaction_test`: `no_other_member_with_clustering_is_held`);
- origin retirement skips its pass and emits
  `[bondy_oplog, retirement, skipped]` with reason `no_members`;
- the authentication freshness fence follows `db.aae.fence.on_isolation`.
  Under the default, `refuse`, a node with no reachable peer is never
  certified fresh, so authentication is refused with
  `temporarily_unavailable`; `quorum` does not count a node alone as a
  majority
  (`bondy_auth_oauth2_SUITE`: `aae_fence_certifies_only_with_clustering_disabled`).

## History when clustering is disabled

With `off`, nothing can contradict the node, so compaction truncates its
history and reclamation discards causally stable cells on its own frontier
(`bondy_oplog_compaction_test`: `no_other_member_compacts_on_own_frontier`).
Each truncation is recorded per shard, and that record decides which nodes it
can later join.

## Turning clustering on for a node that ran with it off

Join nodes only while at most one side has truncated history. A node that
ran with `off` has truncated history, so:

1. Restart it with `cluster.enabled = on`. It is the first node of the
   cluster.
2. Join it only with nodes whose data directories are empty, started with
   `cluster.enabled = on` from their first boot. A node writes at first boot,
   and with `off` it would truncate those writes.

The joining nodes install the first node's snapshot and keep every write it
made, deletes included (`bondy_cluster_standalone_SUITE`:
`enabling_clustering_keeps_every_write`; `proofs/tla/JoinInstall.tla` with
`JoinInstall_Truncation_CompactMembers_SoloClean.cfg` holds `NoStrandedRecord`,
as recorded in `proofs/README.md`).

If two nodes that have each truncated are joined, each refuses to install the
other's snapshot with `source_behind_truncation`, and logs, on every retry:

> Refused to install the peer's snapshot: the peer has not seen events this
> node truncated. If this persists, the two nodes truncated history separately
> before they were joined (for example, each ran with cluster.enabled = off).
> Empty one of them and rejoin it.

Both keep serving their own data, but they never converge
(`bondy_cluster_standalone_SUITE`:
`nodes_that_truncated_alone_refuse_each_other`;
`JoinInstall_Truncation_CompactMembers_SoloJoinAny.cfg` violates
`NoStrandedRecord`). To recover, choose the node whose data to keep, stop the
other, empty its `platform_data_dir`, and start it with `cluster.enabled = on`
so that it joins empty. The writes the emptied node accepted on its own are
lost.

## Turning clustering off for a member

Remove the member from the cluster before restarting it with `off`: call
`bondy.cluster.leave` with the node's name, from the master realm. Pass
`dry_run` first; the call refuses unless every remaining member is reachable
and ready. A node that was started with `cluster.automatic_leave = on` also
leaves on a graceful shutdown, without that check; the setting is read at
start, so turning it on just before the shutdown does nothing.

Otherwise the remaining members keep counting it, and the node and the
cluster each truncate history the other lacks
(`JoinInstall_Truncation_CompactMembers_Leave_Kept.cfg` violates
`NoStrandedRecord`; with the leave, `JoinInstall_Truncation_CompactMembers_Leave.cfg`
holds).

To bring the node back later, follow
[the joining rule](#turning-clustering-on-for-a-node-that-ran-with-it-off):
it has truncated on its own, so it rejoins a cluster that has truncated only
after it has been emptied
(`JoinInstall_Truncation_CompactMembers_Leave_JoinAny.cfg` violates
`NoStrandedRecord`).

## See also

- [Reclamation configuration reference](reclamation_options.md) — the
  stall reasons, `no_members` among them.
- [Understanding deletion and reclamation](../database/deletion_and_reclamation.md).
