# Storage Topology: What Is Fixed at Provision

Three of the storage stack's options, together with each table's shard key,
are written into an on-disk manifest (`bondy_db_manifest`) the first time a
node provisions its data directory, and the data is keyed under them from
that moment. This page names those options, shows what each one
routes, and states what changing one afterwards costs. Read it before the
first node starts, because that is the only cheap moment to decide.

The views describe a topology already chosen: the
[shard at runtime](db_view_shard_runtime.md) works inside one shard, and
[replication](db_view_replication.md) reconciles shards across peers.
Neither can tell you which shard a write belongs to. That is settled here.

## Where a write lands

`db.main.partition_strategy` maps a `(realm, key)` write onto one of
`db.main.shard_count` shards. It sets two things at once: the
write-atomicity grain, since entities sharing a shard are written in one
atomic batch on one causal log, and which reads stay shard-local rather than
scatter-gather.

Follow one subject's three records — its own row, its grants, its
memberships — and the trade is visible in where they land.

![One subject's three records routed under each partition strategy: braced
into a single shard under aggregate and realm, split across three shards
under entity](img/db-topology.svg)

**`aggregate`** hashes the realm with the aggregate root, so a subject's
records co-locate and commit together. Subjects spread across every shard,
so a single realm still uses the whole ring and realm-wide listings
scatter-gather. This is the default and the recommended setting.

**`realm`** hashes a realm prefix, so a realm's entire dataset is one shard.
Realm scans become single-shard, but a realm does not spread across shards.
`db.main.realm_prefix_depth` (default `1`) sets how many leading
dot-separated components of the realm URI are hashed. At `1`, `org.acme.sso`
and `org.other.app` share the prefix `org` and land together; at `2`,
`org.acme.sso` and `org.acme.app` land together and `org.other.app` may not.
A realm with no more components than the depth is hashed whole. Only `realm`
reads this option. Suits
many-small-realm fleets and nothing else.

**`entity`** hashes the entity type with the key. Write parallelism is
maximal and there is no cross-entity atomicity — the three records above
cannot be written as one batch.

## Why the choice is expensive to revisit

The manifest records the strategy, the shard count, the prefix depth and the
per-table shard keys. On-disk data is keyed under what it records, so a
changed configuration cannot be applied to existing data: the path is
export, wipe the data directory, reimport.

`db.main.on_topology_mismatch` decides what a node does when it finds that
disagreement at boot. `warn`, the default, logs the diverging keys and keeps
running on the on-disk topology, which means the configuration you edited is
not in effect. `stop` refuses to boot. Production wants `stop`, because the
failure mode of `warn` is a node that looks configured and is not.

The manifest also records a sample output of the runtime's shard-placement
hash function, so a runtime that hashes differently is reported as a mismatch
in the same way (`bondy_db_manifest_test`: `hash_probe_divergence_detected`).
Between nodes, every sync round compares a keying-topology fingerprint, and a
node refuses to pull from a peer that keys data differently.

The `registry` database is ephemeral and has no manifest, so it cannot
mismatch and has no partition-strategy option. It has its own
`db.registry.shard_count`.

## Bounding registry history

Two options bound how much registry history is retained.
`db.registry.retention.max_events` is a size bound and
`db.registry.retention.max_age_ms` an age bound. A compaction cycle applies
them only when the peer-confirmed frontier yields nothing to truncate. The
size bound is checked first and, when breached, truncates the whole tree on
that cycle, which keeps a write burst from outrunning the age window. Both
are `0` by default, disabling retention so that peer-confirmed compaction
alone bounds history — see [the data lifecycle](db_view_lifecycle.md). Compaction waits for every
cluster member, so while a member is down and has not been removed from the
cluster, compaction truncates nothing and registry history grows in memory
(`bondy_oplog_compaction_fused_test`: `fused_compaction_waits_for_every_member`).

Truncating past peer confirmation is the risk either bound introduces: a
lagging peer whose needed history is gone goes through catalogue
rebootstrap, which the lifecycle view describes as a first-class path rather
than a fault.

## Related

- [Storage architecture](db_architecture.md) — the view set and its reading order
- [The shard at runtime](db_view_shard_runtime.md) — what happens inside one shard
- [Rationale: invariants and verification](db_rationale.md) — which properties are machine-checked
