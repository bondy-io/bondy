# Bondy storage — Architecture

This folder is the architecture reference for **Bondy's storage stack**: the
packages `bondy_db`, `bondy_oplog` and `bondy_mst`, and the log core
`bondy_log` under the `bondy_oplog` WAL. Each chapter explains one idea and
uses a mermaid diagram to anchor it. Where a chapter's narrative ends, it
points at the source modules. The module docs carry the implementation-level
detail: wire formats, option tables and invariants.

Read the chapters in order. Each one assumes the previous ones.

## Reading order

| # | Doc | What you'll learn |
|---|---|---|
| 00 | [Overview](00_overview.md) | The packages, how they layer, and how a write becomes a read. |
| 01 | [bondy_oplog](01_bondy_oplog.md) | The write side: instances, the WAL (disk and in-memory), fused mode, the leaderless sync sessions, the live-sync throttle, the applied-frontier convergence oracle, the per-round freshness heartbeat, and the per-instance heap monitor. |
| 02 | bondy_mst (in the bondy_mst library docs) | The Merkle Search Tree itself: pages, hashes, the pack-store backend (including off-path sealing and the root-flush commit barrier), and how anti-entropy finds the pages two peers disagree on. |
| 03 | [bondy_db](03_bondy_db.md) | The read side: cache and projection, the write barrier, the freshness fence, change notification, secondary indexes, topologies and realm folding, projection backends. |
| 04 | [Applier](04_applier.md) | The reconciler loop that ties the WAL, the MST and the projection together, and its fused inline twin. |
| 05 | [The CRDT model](05_crdt_model.md) | The pure operation-based CRDT contract: `interpret_cog`, the eager `apply_op` path, causal tiers, and the native catalogue. |
| 06 | [Compaction & bootstrap](06_compaction_and_bootstrap.md) | Why the oplog is bounded: causal stability, the compaction watermark, physical MST truncation, the applied frontier that verifies convergence once the MST is empty, how new replicas join by snapshot transfer, and how anti-entropy stays subordinate to routing (concurrency cap, bounded memory, fairness, load-reactive yield). |
| 07 | [An app developer's tour](07_app_developers_tour.md) | A worked example over the Bondy Router tables: picking a CRDT, choosing a database and topology, and reacting to a peer's change. Patterns and anti-patterns. |
| 08 | Backup & restore (in the bondy_mst library docs) | Operator runbook for `bondy_mst_admin:backup/2`, `verify/1` and `restore/2`: what they cover, what they do not, and when to use them. |

## Style notes

These chapters are a guided tour in the spirit of the CMU SEI **Views and
Beyond** method, where a documented software architecture is a set of views,
each suited to one audience. The register is explanatory prose, not a
specification. For the exact contract, each chapter ends with a pointer to the
relevant source modules, whose module docs are the record.

## Conventions

- **Diagrams** are mermaid.
- **Storage stack** means `bondy_db`, `bondy_oplog`, `bondy_log` and
  `bondy_mst` together.
- **`bondy_mst`** (lowercase) is the Merkle Search Tree library, one package
  in the stack. **MST** (uppercase) is the Merkle Search Tree data structure
  inside it.
- **Substrate** is a relative term. From a package's point of view it means
  the layers directly beneath it. From `bondy_db` the substrate is
  `bondy_oplog` and what it builds on. From `bondy_oplog` it is `bondy_log`
  and `bondy_mst`. This folder describes the stack itself, not the
  applications built on it.
