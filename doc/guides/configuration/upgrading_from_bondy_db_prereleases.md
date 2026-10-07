# How to upgrade from a `bondy_db` pre-release

This guide is for a cluster that runs a pre-release that already carries
`bondy_db`, such as 1.0.0-rc.olive or 1.0.0-rc.pear. If you run 1.0.0-rc.65 or
earlier, follow
[How to migrate your configuration from 1.0.0-rc.65](migrating_from_1.0.0-rc.65.md)
instead.

## Steps

### 1. Stop every node, then start them all on the new release

Stop every node in the cluster. When all of them are down, start each one on
the new release.

The registry (registrations and subscriptions) is an in-memory database, so
it starts empty on every node. Clients reconnect, and register and subscribe
again.

### 2. Remove `db.compaction.peer_timeout`

`db.compaction.peer_timeout` does not exist in this release. Compaction on the
durable database holds until every cluster member has reported its frontier,
and does not time a member out.

The release generates its configuration with `cuttlefish --allow_extra`, which
ignores a key no schema maps without reporting it. A `bondy.conf` that still
sets `db.compaction.peer_timeout` boots, and the key has no effect. Remove it.
[How to check your configuration](checking_your_configuration.md) finds keys
like this one.

### 3. Set `cluster.enabled = off` on a single node

A node that runs alone must set:

```
cluster.enabled = off
```

`cluster.enabled` defaults to `on`. With `on` and no other member listed:

- compaction, reclamation and origin retirement hold with reason
  `no_members`. The node logs
  ["GC stalled"](../reference/log_messages.md#gc-stalled) for each instance,
  at most once a minute per instance and scheduler.
- With `db.aae = on` (the default), the authentication freshness fence follows
  `db.aae.fence.on_isolation`, whose default is `refuse`. A node with no peer
  is then never certified fresh. Authentication is refused with
  `temporarily_unavailable` once the security tables have not been certified
  within `db.aae.fence.max_lag`.

See [Running a single node](clustering.md#running-a-single-node).

### 4. Update dashboards and alerts

- `bondy_oplog_peer_exclusions_total` is not exported. Remove queries and
  alerts that use it.
- `bondy_oplog_gc_scheduler_events_total` carries a `scheduler` label in
  addition to `event`. A query that selects by `event` without aggregating
  over `scheduler` returns one series per scheduler. See
  [Metrics](../reference/metrics.md#storage-compaction-reclamation-and-scheduling).

### 5. Update remote-console calls to renamed modules

If you call Bondy modules from a remote console or a script, use these names:

| Pre-release module | Module in this release |
| --- | --- |
| `bondy` | `bondy_router_peer` |
| `bondy_app` | `bondy_router_app` |
| `bondy_sup` | `bondy_router_sup` |
| `bondy_utils` | `bondy_router_utils` |
| `bondy_stdlib` | `bondy_connect_lib` |
| `bondy_consult`, `bondy_error`, `bondy_humanized`, `bondy_interval_set`, `bondy_itc`, `bondy_retry`, `bondy_secret_resolver`, `bondy_secret_resolver_aws_sm`, `bondy_table_manager`, `bondy_uuidv7` | The same name with `bondy_connect_` in place of `bondy_`, in the `bondy_connect_lib` application |
| `bondy_oplog_hlc` | `bondy_connect_hlc` |
| `bondy_oplog_wal_codec`, `_frame`, `_idx`, `_key_registry`, `_manifest`, `_reader`, `_recovery`, `_scrubber`, `_segment`, `_state` | `bondy_log_codec`, `bondy_log_frame`, and so on, in the `bondy_log` application |

`bondy_oplog_wal`, `bondy_oplog_wal_mem` and `bondy_oplog_wal_mem_reader` keep
their names.

## See also

- [Clustering](clustering.md)
- [Metrics](../reference/metrics.md)
- [Log messages](../reference/log_messages.md)
- [How to check your configuration](checking_your_configuration.md)
