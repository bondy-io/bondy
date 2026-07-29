# Bondy storage — Architecture

This folder is the architecture reference for **Bondy's storage stack** —
the three cooperating packages `bondy_db`, `bondy_oplog`, and `bondy_mst`.
Each chapter explains one idea, with a mermaid diagram to anchor it. Where a
chapter's narrative ends, it points at the source modules — module docs carry
the implementation-level detail (wire formats, option tables, invariants).

If you have read this far before reading any code, you are in the right
place. Read the chapters in order — each one assumes you have read the
previous one.

## Reading order

| # | Doc | What you'll learn |
|---|---|---|
| 00 | [Overview](00_overview.md) | The three packages — `bondy_db`, `bondy_mst`, `bondy_oplog` — and how a single `write` becomes a `read`. |
| 01 | [bondy_oplog](01_bondy_oplog.md) | The write side: instances, WAL (disk and in-memory), fused mode, the leaderless sync sessions (over Partisan), the live-sync throttle, the applied-frontier convergence oracle, the per-round freshness heartbeat, and the per-instance heap monitor. |
| 02 | bondy_mst (in the bondy_mst library docs) | The Merkle Search Tree itself: pages, hashes, the pack-store backend (including off-path sealing and the root-flush commit barrier), and how anti-entropy gets to "we agree" quickly. |
| 03 | [bondy_db](03_bondy_db.md) | The read side: cache + overlay + projection, the freshness fence, change notification, secondary indexes, topology and realm folding, projection backends. |
| 04 | [Applier](04_applier.md) | The reconciler loop that ties writes, the MST, and the projection together — and its fused inline twin. |
| 05 | [The CRDT model](05_crdt_model.md) | The pure operation-based CRDT contract: `interpret_cog`, the eager `apply_op` path, causal tiers, and the native catalogue. |
| 06 | [Compaction & bootstrap](06_compaction_and_bootstrap.md) | Why the oplog is bounded: causal stability, the compaction watermark, physical MST truncation, the applied frontier that verifies convergence once the MST is empty, how new replicas join via snapshot transfer, and how anti-entropy is kept subordinate to routing (concurrency cap, bounded memory, fairness, load-reactive yield). |
| 07 | [An app developer's tour](07_app_developers_tour.md) | Worked example over the Bondy Router tables: picking a CRDT, choosing a DB and topology, and reacting to a peer's change. Patterns and anti-patterns. |
| 08 | Backup & restore (in the bondy_mst library docs) | Operator runbook for `bondy_mst_admin:backup/2`, `verify/1`, `restore/2`. What's covered, what's not, when to use it. |

## Style notes

These are a guided tour, in the spirit of the CMU SEI **Views and
Beyond** method (a documented software architecture is a set of views,
each suited to one audience). The register is explanatory prose, not a
specification: where you want the exact contract, the chapter ends with a
pointer to the relevant source modules, whose module docs are the record.

## Conventions

- **Diagrams** are mermaid. Render in any modern markdown viewer.
- **Storage stack** means the three packages together — `bondy_db`,
  `bondy_oplog`, and `bondy_mst`.
- **`bondy_mst`** (lowercase) is the Merkle Search Tree library — one
  package in the stack. **MST** (uppercase) is the Merkle Search Tree
  data structure inside it.
- **"Substrate"** is a relative term: from a package's point of view it
  means the layer or layers directly beneath it. From `bondy_db` the
  substrate is `bondy_oplog` and `bondy_mst`; from `bondy_oplog` it is
  `bondy_mst`. This folder describes the stack itself, not the
  applications built on it.
