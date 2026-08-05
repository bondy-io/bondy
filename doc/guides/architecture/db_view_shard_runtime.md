# Storage Runtime View: The Shard

One shard instance at runtime: the write path from `bondy_db:apply/4` to a
durable, readable, replicable event, and the read path back. Cross-node
behaviour is [replication](db_view_replication.md).

## Primary presentation

```mermaid
flowchart TD
    W["write: apply/4"] --> MINT["mint event key<br/>HLC tick · seq range"]
    MINT --> OV["stage overlay row"]
    OV --> WA{"WAL append"}
    WA -->|ok| ACK["acknowledge caller"]
    WA -->|rejected| RB["roll back: unstage overlay,<br/>return seq range"]
    WA --> DR["applier drain"]
    DR --> FOLD["fold via CRDT module<br/>(cell_apply)"]
    FOLD --> PROJ[("projection<br/>ETS or leveled")]
    FOLD --> FRONT["advance applied frontier<br/>contiguous seqs only"]
    DR --> INSTALL["install into MST"]
    RD["read: read/3"] --> OV2{"in overlay?"}
    OV2 -->|yes| V["value"]
    OV2 -->|no| PROJ
    PROJ --> V
```

## The write path, step by step

1. **Mint.** The event key is created caller-side on the fast path: one
   hybrid-logical-clock tick (strictly monotone per instance, dominated by
   every timestamp ever received) and a sequence number from an atomically
   reserved contiguous range. Both fast (lock-free, stateless-validator)
   and gen-server paths share one minting core.
2. **Stage, then append.** The overlay row is staged *before* the WAL
   append, so the moment the event is durable a reader can see it — there
   is no window where a durable write is invisible. If the WAL rejects the
   append, the overlay row is unstaged and the reserved sequence range is
   returned to the counter when still topmost; a range overtaken by a
   concurrent reservation cannot be returned, so it is counted
   (`bondy_oplog_seqs_burned_total`) and backfilled with signed no-op
   `seq_fill` events (`bondy_oplog_seqs_filled_total`) that occupy the
   seqs — replicating and advancing frontiers like any event, folding to
   nothing — so the gap never becomes sync-unfillable.
3. **Acknowledge.** The caller's write is complete at durable append —
   before the fold. Durability policy (`db.fsync`) governs what "durable"
   costs.
4. **Drain and fold.** The applier consumes the log in order and folds
   each event through the table's CRDT module into the projection. The
   fold is the only interpreter of operations; every event source passes
   through it, so a locally minted event and the same event arriving from
   a peer produce identical state.
5. **Frontier and install.** The applied frontier advances at the fold's
   commit point, per origin, across contiguous sequences only. The event
   is installed into the MST, becoming visible to
   [replication](db_view_replication.md). The overlay row is evicted once
   the projection covers it.

## The read path

`read/3` consults the overlay first (writes not yet drained), then the
projection — a lookup, never a fold, never the MST. Folds and relational
queries run over the projection and its secondary indexes, which
`cell_apply` maintains in the same commit as the values. Reads on the
writing node therefore observe writes immediately; reads elsewhere observe
them after replication.

## Ordering and concurrency contract

Within one instance: events fold in per-origin sequence order (holes are
held, not skipped — the prefix-closure enforcement lives at this fold);
concurrent writers to one instance interleave freely at mint time, and the
HLC gives every event a total order consistent with causality for
order-independent CRDTs. Across instances there is no ordering — a batch is
atomic only within one shard, which is why the facade co-shards entities
that must commit together (the aggregate-root declaration).

## Rationale

Acknowledging at the log rather than the fold makes write latency the price
of durability, not of interpretation, and lets the fold batch. Staging the
overlay before the append trades a rollback obligation on the failure path
for read-your-write with no coordination on the success path — the common
case pays nothing. One minting core and one fold path exist because both
were once two, and each pair drifted; the invariants each must uphold
(gap-free sequences; identical interpretation everywhere) are now stated in
one place each. See [rationale](db_rationale.md) for which of these are
machine-checked.
