# How to migrate your configuration from 1.0.0-rc.65

This release replaces Bondy's storage engine (PlumDB/RocksDB) with a new one
(`bondy_db`/`bondy_oplog`/`bondy_mst`, over `leveled`), and every
storage-related `bondy.conf` key changed as part of that work. If you are
running 1.0.0-rc.65 or earlier, your `bondy.conf` and any `advanced.config`
will not boot this release unchanged. This guide gets them there.

**Prerequisites:** a working 1.0.0-rc.65 `bondy.conf` (and `advanced.config`,
if you have one); read the ["Changes" section of the changelog](../../../CHANGELOG.md)
for the full list of behavioural changes this release makes beyond
configuration.

## Steps

### 1. Accept that this is not an in-place upgrade

On-disk data written by 1.0.0-rc.65 (or any earlier release) is in PlumDB's
RocksDB format, which this release cannot read. There is no tool that
converts it: `bondy_export`, this release's data mover, reads and writes only
the new storage engine, so it has nothing to read on a PlumDB data
directory.

Concretely, this means:

- **Wipe the data directory** (`platform_data_dir`) before starting the new
  release on a node. Starting it against an old data directory does not
  corrupt anything — the new code simply doesn't recognise the layout — but
  it also doesn't give you your data back.
- **Recreate realms, users, groups, grants, sources, tickets, tokens and
  API Gateway specs** on the new cluster. If you provisioned these
  originally through a script, Terraform/Ansible run, or a stored set of
  WAMP `bondy.realm.create` / `bondy.security.*` / `bondy.http_gateway.*`
  calls, replay it. If you provisioned by hand, there is no shortcut —
  budget time to redo it.
- This is a **new cluster**, not a rolling upgrade. Don't mix a 1.0.0-rc.65
  node and a node running this release in the same Partisan cluster.

### 2. Rename the AAE and storage keys

The `oplog.*` prefix is now `db.*`, unconditionally. If you didn't customise
any of these, you have nothing to do — the defaults are unchanged. If you
did, rename the key on the left to the key on the right; the value and its
meaning are identical.

| Old key (≤ 1.0.0-rc.65) | New key |
|---|---|
| `oplog.aae` | `db.aae` |
| `oplog.aae.interval` | `db.aae.interval` |
| `oplog.aae.live_sync` | `db.aae.live_sync` |
| `oplog.aae.live_sync.max` | `db.aae.live_sync.max` |
| `oplog.aae.max_concurrency` | `db.aae.max_concurrency` |
| `oplog.aae.max_pages_in_flight` | `db.aae.max_pages_in_flight` |
| `oplog.aae.load_adaptive` | `db.aae.load_adaptive` |
| `oplog.aae.load_run_queue_threshold` | `db.aae.load_run_queue_threshold` |
| `oplog.aae.fanout` | `db.aae.fanout` |
| `oplog.aae.fence.max_lag` | `db.aae.fence.max_lag` |
| `oplog.aae.fence.on_isolation` | `db.aae.fence.on_isolation` |

Four more keys move from `oplog.core.*` to a bare `db.*` — the `core.`
segment drops because these settings were never specific to one database;
they govern every replicated table node-wide:

| Old key | New key |
|---|---|
| `oplog.core.gc_interval` | `db.gc_interval` |
| `oplog.core.gc_heap_delta` | `db.gc_heap_delta` |
| `oplog.core.pack_auto_seal_bytes` | `db.pack_auto_seal_bytes` |
| `oplog.core.pack_seal_mode` | `db.pack_seal_mode` |

### 3. Rename the durable-database keys (`core` is now `main`)

Bondy provisions two databases: a durable one and an ephemeral, in-memory
one for the registry (registrations and subscriptions). In 1.0.0-rc.65 the
durable one was internally named `core`; this release renames it `main`, to
stop it being confused with the unrelated `bondy_oplog_core` substrate
module. If your `bondy.conf` sets any of the durable database's topology,
rename these:

| Old key | New key |
|---|---|
| `oplog.core.shard_count` | `db.main.shard_count` |
| `oplog.core.partition_strategy` | `db.main.partition_strategy` |
| `oplog.core.realm_prefix_depth` | `db.main.realm_prefix_depth` |
| `oplog.core.on_topology_mismatch` | `db.main.on_topology_mismatch` |

The on-disk directory for this database is also renamed, from
`<platform_data_dir>/bondy_db/core` to `<platform_data_dir>/bondy_db/main` —
irrelevant if you're wiping the data directory per step 1, but worth knowing
if you scripted anything against the old path.

### 4. Remove keys that no longer exist

These keys are gone with no replacement. Bondy refuses to boot if it finds
a key it doesn't recognise, so leaving one of these in place is not a silent
no-op — it's a startup failure. The boot log names the offending key and
suggests the closest current key by edit distance, which will point you back
to this guide's renamed keys if you miss one.

| Removed key | Why |
|---|---|
| `oplog.catalog` | Never had a consumer; setting it did nothing in any released version. |
| `oplog.core.scan_max_concurrency` | Same — never wired to any code path. |
| Any `store.*` key (RocksDB tuning) | RocksDB is gone. The new `leveled` backend has no equivalent `bondy.conf` tuning surface yet — if you relied on `store.*` for capacity planning, there is currently nothing to replace it with. |

If you have an `advanced.config` with a `{plum_db, [...]}` stanza (for
`store.*` settings that had no `bondy.conf` mapping, or for anything else),
delete it. The `plum_db` application no longer exists in this release, so
the stanza is inert — Erlang doesn't error on configuring an application
that isn't loaded — but it's dead weight and worth removing so it doesn't
look like it's doing something.

### 5. Update `advanced.config` application names

The router's OTP application was renamed `bondy` → `bondy_router`. The
release name, node name, `bondy.conf` file name, and every WAMP URI are
unchanged — this is purely the Erlang application identifier. If your
`advanced.config` has a `{bondy, [...]}` stanza, rename it to
`{bondy_router, [...]}`; like the `plum_db` case above, the old name is
silently inert rather than an error, so this one won't fail your boot — it
will just stop taking effect, which is worse to debug.

### 6. Consider the new options (optional)

None of these existed at 1.0.0-rc.65, in any form — they aren't renames, so
there's nothing to migrate. They're listed here so you know they exist; the
defaults are safe to run with unchanged.

| Key | What it controls |
|---|---|
| `db.registry.shard_count` | Shard count for the ephemeral registry database, independent of `db.main.shard_count`. |
| `db.wal.fsync_mode` | `per_write` (default) or `batched` — the durable write-ahead log's fsync strategy; see the key's schema comment for the throughput/durability trade-off. |
| `db.wal.batched_fsync_interval`, `db.wal.batched_fsync_bytes` | Batching window for `db.wal.fsync_mode = batched`. |
| `db.wal.max_segment_bytes` | WAL segment rotation threshold. |
| `db.reclaim`, `db.reclaim.interval`, `db.reclaim.batch_cells` | Projection-cell reclamation (tombstone space reclaim). See the [reclamation configuration reference](reclamation_options.md). |
| `db.origin_retirement`, `db.origin_retirement.interval` | Reaping bookkeeping for permanently departed cluster members. See the [reclamation configuration reference](reclamation_options.md). |
| `db.gc_max_concurrency`, `db.compaction.peer_timeout` | Shared compaction/reclamation scheduler tuning. See the [reclamation configuration reference](reclamation_options.md). |
| `db.drain.stall_alarm` | Alarm threshold for a wedged WAL consumer. |
| `cluster.max_message_size` | Partisan inter-node frame size cap. |
| `load_regulation.aae_reactor.pool.size` | Worker-pool size for anti-entropy merge reactions. |
| `load_regulation.router.flow_pool.capacity` | Capacity of the per-flow relay ordering pool. |
| `registry.rib.check_interval`, `registry.rib.damping` | Registry routing-summary consistency sweep and route-flap damping. |

Everything in `bondy_bridge_relay.schema`, `bondy_broker_bridge.schema`,
`bondy_rpc_gateway.schema` and `oauth2.schema` — bridge relay, broker
bridge, RPC Gateway, and OAuth2/OIDC configuration — is unchanged.

## Result

You have a `bondy.conf` (and, if applicable, `advanced.config`) that this
release accepts, and a plan for recreating your realm and security state on
a freshly provisioned cluster. To confirm your file is complete before
deploying it, start a node with it: an unrecognised or mistyped key fails
boot immediately, naming the key and suggesting the closest valid one. If
you're building from source, `config/bondy.conf.defaults` (regenerate it
with `make conf`) lists every current key and its default and is a useful
diff target.

## See also

- [Reclamation configuration reference](reclamation_options.md) — the full
  set of reclamation/retirement options and their telemetry.
- [Understanding deletion and reclamation](../database/deletion_and_reclamation.md)
  — the model the reclamation options control.
- The [changelog](../../../CHANGELOG.md) — the full list of behavioural
  changes in this release, not just configuration.
