# Replicated Security State

In a cluster, users, groups, group memberships, grants and sources replicate
between nodes through anti-entropy. Sessions do not replicate: each node owns
the sessions of the clients connected to it. When a security change arrives
from another node, each node applies its local consequences itself. The
reactions are implemented in `bondy_aae_reactor`.

To protect this state in transit, see
[Securing the Cluster Peer Plane](cluster_peer_plane.md).

## Users

| Change from another node | Effect on this node |
| --- | --- |
| The user is deleted. | The user's sessions are closed with reason `bondy.user.deleted`. |
| The user's password or authorized keys change. | The user's sessions are closed with reason `bondy.user.credentials_changed`. |
| Any other change to the user record. | None. |

A credential counts as changed when the replicated record carries a password
or authorized keys that differ from the value this node held before the merge
(`bondy_aae_reactor_test:remote_delete_closes_user_sessions_test`,
`bondy_aae_reactor_test:remote_credential_change_closes_user_sessions_test`,
`bondy_aae_reactor_test:remote_set_does_not_close_user_sessions_test`).

## Group membership

Group membership is stored as one replicated fact per `(user, group)` pair,
in the `security_group_members` table. Its fold is `ew`: each fact is an
enable-wins flag (`bondy_oplog_crdt_ew_flag`). Adding a user to a group
enables the fact; removing the user disables it.

- A removal disables only the additions its node had observed when it was
  made.
- When an addition and a removal are concurrent, neither having observed the
  other, the addition wins and the user remains a member
  (`bondy_oplog_crdt_ew_flag_proper_test:prop_enable_wins_oracle`).

A membership change from another node invalidates the cached authorization
context of every session in the realm on this node. The sessions stay open,
and the next authorization reads the user's current groups
(`bondy_aae_reactor_test:remote_member_invalidates_realm_rbac_test`). Changes
to grants and to group records from another node have the same effect.

## Merge conflicts

Grants and sources are last-writer-wins: when two nodes change the same cell
concurrently, one change is discarded. Bondy cannot tell a concurrent change
from a later one, so it reports every case where a merge from another node
replaces a different value this node held.

The report is the telemetry event `[bondy, aae, merge_conflict]` and a warning
log naming the table and the realm
(`bondy_aae_reactor_test:merge_conflict_alarm_test`). It fires for these
tables:

- `security_user_grants`
- `security_group_grants`
- `security_sources`

It fires when a merge from another node writes a value, this node already
held a value for that cell, and the two differ. It does not fire when the
cell did not exist on this node, when the value is identical, or when the
merge deletes the cell (a revoke).

| Event part | Content |
| --- | --- |
| Measurements | `#{count => 1}` |
| Metadata | `table`: one of the table names above, as a string. `realm_uri`: the realm. |

The Prometheus exporter counts the event as `bondy_aae_merge_conflicts_total`,
labelled by `table`.

The event does not mean that a change was lost. It also fires when a change
made on one node, with no concurrent change elsewhere, replaces the older value
on the other nodes, so an ordinary update of an existing grant or source can
fire it on every other node. When the count rises at a time you did not change
that table, check that the affected cells hold the values you intended.
