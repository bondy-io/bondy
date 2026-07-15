# How the storage stack splits into three packages

The storage substrate is three OTP packages stacked
`bondy_db → bondy_oplog → bondy_mst`. [The overview](../doc_extras/architecture/00_overview.md)
introduces them from the consumer's side; this note explains *why the
boundaries fall where they do*, because the split deliberately does **not**
follow the module-name prefixes.

```
apps/bondy_db      depends on bondy_oplog + leveled   — consumer facade + storage topologies
apps/bondy_oplog   depends on bondy_mst               — write/replication framework + core substrate + CRDT catalogue
bondy_mst (dep)    — pure Merkle-Search-Tree library
```

`bondy_mst` is a standalone library; the `bondy` umbrella declares it as a
dependency and pulls `leveled` in directly.

## The split cuts across the prefixes

A naïve cut along the `bondy_db_*` / `bondy_oplog_*` names is impossible: the
dependency graph crosses the prefixes in two places, and an OTP app dependency
is one-way.

### The core substrate cycles with the oplog → it lives in the lower app

The `*_core_*` modules — the per-`(NS, Index, Shard)` registry, the read API,
the change-notification dispatcher, the metrics — and the `bondy_oplog_*`
framework form one strongly-connected cluster. The framework (applier, instance,
cell-apply, sync session) calls the core registry and `publish`; the core
modules call down into the framework's cell kernel, overlay, HLC, and event.
Two modules in a cycle cannot live in two OTP apps with a one-way app
dependency, so the core substrate sits in **`bondy_oplog`** and carries the
`bondy_oplog_core_*` prefix.

### Only the leveled-touching modules rise to the upper app

`leveled` is a `bondy_db` dependency only. The two modules that touch it — the
leveled projection backend and the leveled tag — live in **`bondy_db`**
(`bondy_db_projection_leveled`, `bondy_db_leveled_tag`), which leaves
`bondy_oplog` with no `leveled` reference at all.

## What each package owns

- **`bondy_oplog`** — the write/replication framework (instance, WAL, applier,
  sync scheduler/session, compaction), the core registry + read API + the
  change-notification dispatcher, and the native CRDT catalogue
  ([chapter 05](../doc_extras/architecture/05_crdt_model.md)). Depends only on `bondy_mst`.
- **`bondy_db`** — the consumer table facade, the storage topologies
  (`shared_shards`, `per_entity`, `single_bookie`, `memory`) and their leveled
  plumbing, the topology manifest, and the leveled projection. Depends on
  `bondy_oplog` + `leveled`.
- **`bondy_mst`** — the pure Merkle Search Tree: pages, hashes, the pack store,
  the state-based merge engine. A standalone library, the replication structure
  the other two build on.

## One-line summary

The clean stack is `bondy_db → bondy_oplog → bondy_mst`, but it cuts *across* the
old prefixes: the core substrate moves down into `bondy_oplog` because it cycles
with the oplog, and the leveled modules move up into `bondy_db`. See
[the overview](../doc_extras/architecture/00_overview.md) for how the three cooperate at run
time.
