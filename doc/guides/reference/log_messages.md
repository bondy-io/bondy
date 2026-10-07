# Log messages

Bondy logs structured reports. Every record on this page is a map whose
`description` field is fixed text, so an alert can match on it exactly. The
descriptions below are quoted as the code writes them. The other fields are
listed with each record.

## Connection threshold exceeded

```
description => "Connection threshold exceeded"
```

| Field | Value |
| --- | --- |
| `threshold_percent` | `75` or `90` |
| `listener` | The listener's name. |
| `alarm_name` | `num_connections_75` or `num_connections_90` |
| `connections` | The listener's connection count when the alarm fired. |

Logged at **warning** when a listener's connections reach 75 % of its
`max_connections`, and at **alert** at 90 %. Each threshold logs at most once
every 5 seconds (`cooldown` in `bondy_listener_ranch:alarms/1`). A listener
whose `max_connections` is `infinity` has no thresholds and never logs this.

## Drain: listeners suspended

```
description => "Suspending the normal-phase listeners. No new connections will be accepted from now on; the readiness and metrics endpoints stay up for the duration of the drain."
```

Logged at **notice** when a node starts to shut down. From this point the node
accepts no new client connections. Existing connections are not closed by this
step. `/ping`, `/ready` and `/metrics` keep answering until the drain ends, so
an orchestrator that watches them does not read the draining node as dead. The
next record, "Terminating all client connections.", marks the point where client
connections close.

## WebSocket closed on idle timeout

```
description => "Connection closed"
reason => idle_timeout
```

| Field | Value |
| --- | --- |
| `reason` | `idle_timeout` |
| `idle_timeout` | The timeout in force, in milliseconds. |

Logged at **error** when a WebSocket connection is closed because it was idle
for `listeners.$name.websocket.idle_timeout` (default `28800000`, eight hours).
The other "Connection closed" records from the same handler carry a different
`reason` (`normal`, `stop`) and are logged at info.

## GC stalled

```
description => "GC stalled: the trigger returned an error for this instance. For reason unconfirmed or no_frontier, a member is holding it: see member_status (highest last_sync_age_ms, or never_synced). Bring them back online, or retire them with a deliberate cluster membership removal — a stalled member never ages out. For reason no_members, clustering is enabled and no other member is listed: a member that has just restarted holds until it rejoins, and a node meant to run alone needs cluster.enabled = off."
```

| Field | Value |
| --- | --- |
| `scheduler` | `bondy_oplog_gc_scheduler` (compaction) or `bondy_oplog_reclaim_scheduler` (reclamation). |
| `instance` | The oplog instance that did not compact or reclaim. |
| `reason` | Why the run stalled, for example `unconfirmed`, `no_frontier`, `no_members`. |
| `missing_members` | For `unconfirmed`, the members with no recorded frontier. Otherwise `[]`. |
| `member_status` | One entry per cluster member: `#{member, last_sync_age_ms}`, or `#{member, status => never_synced}` for a member with no sync record for this instance. `unavailable` if it cannot be read. |

Logged at **warning**, at most once every 60 seconds per instance and
scheduler. The limit applies to the log only:
`bondy_oplog_gc_scheduler_events_total` and
`bondy_oplog_reclamation_stalled_total` count every stall (see
[Metrics](metrics.md)).

The reason `idle`, an empty local tree on a converged shard, is never logged.
It is visible in `bondy_oplog_reclamation_stalled_total`.

`no_members` on a node that runs alone means `cluster.enabled` is still `on`.
Set it to `off`: see
[Running a single node](../configuration/clustering.md#running-a-single-node).

## Causal hold

```
description => "Causal hold: this replay batch carries remote-origin events beyond a per-origin contiguity gap, or events whose context observed one; they are excluded from the fold and the applied-frontier merge, and the caller keeps its replay cursor so they re-present until the gap fills or a rebootstrap repairs it."
```

| Field | Value |
| --- | --- |
| `instance_id` | The oplog instance. |
| `held` | The held events, as origin and sequence numbers. |

Logged at **info** each time a replay holds events back. The same events are
counted by `bondy_oplog_events_held_total`. A burst while a node rejoins after
a long absence is expected. A record that repeats for the same `held` events on
a healthy cluster means a gap that is not filling.

## Bootstrap refused: peer behind truncation

```
description => "Refused to install the peer's snapshot: the peer has not seen events this node truncated. If this persists, the two nodes truncated history separately before they were joined (for example, each ran with cluster.enabled = off). Empty one of them and rejoin it."
```

| Field | Value |
| --- | --- |
| `instance` | The oplog instance. |
| `peer` | The peer whose snapshot was refused. |
| `reason` | `{source_behind_truncation, Uncovered}`, where `Uncovered` maps each origin to the sequence number this node truncated through that the peer has not seen. |

Logged at **warning** when a catalogue bootstrap from `peer` is refused because
installing the peer's snapshot would lose events this node has already
truncated. Nothing is written: the instance keeps compacting and serving.
See [Turning clustering on for a node that ran with it off](../configuration/clustering.md#turning-clustering-on-for-a-node-that-ran-with-it-off).

## Bootstrap session failed

```
description => "bootstrap_catalogue session failed"
```

| Field | Value |
| --- | --- |
| `instance` | The oplog instance. |
| `peer` | The peer the session read from. |
| `reason` | The error. |

Logged at **warning** when a catalogue bootstrap session fails for any reason
other than the refusal above.

## MST root lost pages

```
description => "The MST root has lost pages. Anti-entropy advertises it as empty, so peers pull nothing from it. Compaction rebuilds the tree once every member covers what this replica applied."
```

| Field | Value |
| --- | --- |
| `instance_id` | The oplog instance. |
| `root` | The root hash whose pages are not all in the store. |

Logged at **warning** the first time a root is found to reference a page the
store lacks. Peers recover what this replica applied from its projection by
re-bootstrap. See [MST rebuilt](#mst-rebuilt) for the repair.

## MST rebuilt

```
description => "Rebuilt an MST whose own root lost pages: every member covers what this replica applied, so the tree was truncated past every lost page and anti-entropy resumes on it."
```

| Field | Value |
| --- | --- |
| `instance_id` | The oplog instance. |
| `dropped_events` | The events the truncation removed from the tree. |

Logged at **notice** when compaction has truncated a tree whose own root lost
pages and the tree it leaves has every page. Compaction truncates such a tree
only once every member covers this replica's applied frontier, and never past
the first key this replica has not applied. A truncation that stops there and
leaves a lost page above it logs nothing; a later cycle finishes it. Each record
is also counted by `bondy_oplog_mst_rebuilt_total` with reason `unservable_root`.
Any occurrence deserves a look at why the pages went missing.

## Node removed from the cluster

```
description => "Node removed from the cluster"
```

| Field | Value |
| --- | --- |
| `node` | The removed node. |
| `survey` | The pre-removal survey: `node`, `safe`, `members` (each with `node`, `ready` and `oplog_instances`), `silent` and `not_ready`. |

Logged at **notice** by the node that served `bondy.cluster.leave`, after the
survey found every remaining member answering and ready and the node was
removed. A removal the survey judges unsafe is refused and is not logged here.

## See also

- [Metrics](metrics.md)
- [Clustering](../configuration/clustering.md)
- [Reclamation configuration reference](../configuration/reclamation_options.md)
