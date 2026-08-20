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

### 1. Move your data before you wipe anything

On-disk data written by 1.0.0-rc.65 (or any earlier release) is in PlumDB's
RocksDB format, which this release cannot read. `bondy_export` reads and
writes only the new storage engine, so pointing it at a PlumDB data
directory gives it nothing to read.

The migration path runs through a backup **file**, not the data directory.
Take one on the old node with `bondy.backup.create` while it is still
running; this release's `bondy.export.import` recognises that file's format
and translates each record as it reads. Users, groups, grants, sources, API
Gateway specs and OAuth refresh tokens come across. Realm records do not —
recreate realms from configuration, and their per-realm data still imports,
because it is banded by the realm URI.

The full procedure — backing up on the old deployment, confirming it
finished, copying the file, and importing it — is
[Upgrading to 1.0.0](https://developer.bondy.io/guides/deployment/upgrading_to_1_0_0).
Follow that guide for the data; this one covers only the configuration.

Two things hold either way:

- **Wipe the data directory** (`platform_data_dir`) before starting the new
  release on a node — but only once the backup above is confirmed finished,
  since the data directory is the only thing the backup can be taken from.
  Starting the new release against an old data directory does not corrupt
  anything; the new code simply doesn't recognise the layout.
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

These keys are gone with no replacement. **Leaving one in place is silent.**
A key that matches no schema is dropped without a word: the node boots, and
the setting you thought you were applying simply isn't — that part of Bondy
runs on its default. The same is true of every rename in the two tables
above, so a key you miss here will not announce itself.

The reason is structural rather than a choice. The release generates its
application config by running `cuttlefish` once per schema set — the VM
arguments, then the application schemas — and each run reads your *whole*
`bondy.conf` while knowing only its own subset of keys. Every key belonging
to another set therefore looks unrecognised to it, so the runs are told to
tolerate keys they don't know. That tolerance cannot distinguish "belongs to
the other schema set" from "belongs to no schema at all".

So check the file rather than trusting the boot:

```bash
./scripts/migrate_conf.escript check etc/bondy.conf
```

This reports every key no schema maps, and attributes each one to a rename, a
removal, or neither — "neither" being the interesting answer. It also covers
every rename in the two tables above, so you do not have to apply them by hand
and hope you caught them all. See
[How to check your configuration](checking_your_configuration.md) for the full
output, and for `migrate`, which applies the renames for you.

Run it against the schemas of the release you are moving **to**, which is the
release that has to read your file.

If you have neither a checkout nor the script to hand, the same question can be
answered with the release's own `cuttlefish`, one schema directory at a time.
A key is genuinely dead only if *every* schema set rejects it, so take only the
complaints common to all the runs:

```bash
bin/cuttlefish --etc_dir etc --conf_file etc/bondy.conf \
    --dest_dir /tmp/check --dest_file out.config \
    --schema_dir releases/<version>
bin/cuttlefish --etc_dir etc --conf_file etc/bondy.conf \
    --dest_dir /tmp/check --dest_file out.config \
    --schema_dir releases/<version>/schema/
```

Omitting the tolerance flag is what makes the complaints visible; each run
names the keys it does not recognise and suggests the closest key it does.
Treat a key as dead only when it appears in the output of both.

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

Everything in `bondy_bridge_relay.schema`, `bondy_broker_bridge.schema`
and `oauth2.schema` — bridge relay, broker bridge, and OAuth2/OIDC
configuration — is unchanged. The RPC Gateway configuration moved; see
step 7 below.

### 7. Rename the RPC Gateway prefix (now HTTP Connector)

The experimental WAMP→HTTP RPC Gateway application was renamed
`bondy_rpc_gateway` → `bondy_http_connector`, to stop it being confused
with the (unrelated, inbound) HTTP API Gateway. Every `rpc_gateway.*`
`bondy.conf` key is now `http_connector.*` — only the prefix changes, every
sub-key, value and its meaning are identical, e.g.:

| Old key (≤ 1.0.0-rc.65) | New key |
|---|---|
| `rpc_gateway.services.$service.base_url` | `http_connector.services.$service.base_url` |
| `rpc_gateway.services.$service.pool.*` | `http_connector.services.$service.pool.*` |
| `rpc_gateway.services.$service.auth.*` | `http_connector.services.$service.auth.*` |
| `rpc_gateway.services.$service.procedures.$proc.*` | `http_connector.services.$service.procedures.$proc.*` |

If you don't have an `rpc_gateway.*` section in your `bondy.conf`, there is
nothing to do.

This release also adds a per-service liveness probe,
`http_connector.services.$service.liveness.*` (enabled by default): a
periodic health check of the upstream that raises an alarm
(`{http_connector_service_down, ServiceName}`, visible via the existing
active-alarms metric/dashboard panel) after `liveness.failure_threshold`
consecutive failures and clears it on recovery. This is new, not a rename —
the defaults are safe to run with unchanged.

### 8. Declare your listeners

This is the largest single change in the file, and the one most likely to leave
a node running but not serving.

The per-scheme keys that configured Bondy's fixed listeners are **gone**:
`admin_api.{http,https}.*`, `api_gateway.{http,https}.*`, `wamp.{tcp,tls}.*` and
`bridge.listener.{tcp,tls}.*`. A listener is now something you declare, by name,
with its own transport, protocol and bind target:

```
listeners.api_gateway_http.transport = tcp
listeners.api_gateway_http.protocol  = http
listeners.api_gateway_http.port      = 18080
listeners.api_gateway_http.services  = api_gateway, wamp_ws, wamp_sse, wamp_longpoll
```

Two failures to know about, because a file can hit the second while looking as
though it survived the first:

- **A listener you do not declare does not exist.** A file with no `listeners.*`
  key at all starts three built-in defaults — `admin`, `api_gateway_http` and
  `wamp_tcp` — and nothing else. Every TLS listener and every bridge-relay
  listener is gone, and the only symptom is a refused connection.
- **Renaming the keys is not enough.** A `listeners.<name>.*` block with options
  but no identity is refused at boot with
  `{invalid_listener, <name>, {missing, transport}}`, which aborts the whole node.

`scripts/migrate_conf.escript` reports both and applies the renames. The name
each removed block maps to, where the tails move (TLS material under `tls.*`,
Cowboy options on an HTTP listener under `http.*`), and the one narrowed
capability — `ip` no longer accepts a hostname — are all in
[Listeners](listeners.md#migrating-from-the-pre-10-keys).

One thing to check before you deploy: every **enabled** `transport = tls`
listener must state `tls.certfile` and `tls.keyfile`. The removed keys supplied a
default certificate path and nothing does now, so a TLS listener that relied on
that default is refused at boot — and because the inventory is resolved as a unit,
that refusal stops every other listener too. A listener with `enabled = off` is
not checked, so declaring one and provisioning its certificate later is fine.

## Result

You have a `bondy.conf` (and, if applicable, `advanced.config`) that this
release accepts. Your data moves separately, through the backup and import
described in step 1.

Confirming the file is complete takes more than starting a node, because a
booting node is not evidence that your keys are live — see step 4 for why a
stale or mistyped key is dropped silently, and for the `cuttlefish` check that
does surface it. Run that check before deploying. If you're building from
source, `config/bondy.conf.defaults` (regenerate it with `just conf`) lists
every current key and its default, and diffing your file's key names against it
catches the same class of mistake.

## See also

- [How to check your configuration](checking_your_configuration.md) — the tool
  that reports which of your settings this release no longer reads, and applies
  the renames in this guide for you.
- [Upgrading to 1.0.0](https://developer.bondy.io/guides/deployment/upgrading_to_1_0_0)
  — the data half of the migration: back up on the old deployment, copy the
  file, import it on the new cluster.
- [Reclamation configuration reference](reclamation_options.md) — the full
  set of reclamation/retirement options and their telemetry.
- [Understanding deletion and reclamation](../database/deletion_and_reclamation.md)
  — the model the reclamation options control.
- The [changelog](../../../CHANGELOG.md) — the full list of behavioural
  changes in this release, not just configuration.
