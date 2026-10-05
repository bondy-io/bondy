# Storage Runtime View: The Data Lifecycle

How history is bounded. An operation log grows with every write; this view
shows the machinery that certifies what may be forgotten, forgets it, and
repairs a node that needed what everyone else forgot.

## Primary presentation

```mermaid
flowchart LR
    CONF["Confirmations<br/>peer roots held-in-full,<br/>every member (registry:<br/>recency-filtered)"] --> STAB["Stability frontier<br/>containment-certified"]
    STAB --> CMP["Compaction<br/>truncate MST history<br/>advance watermark"]
    STAB --> REC["Reclamation<br/>stabilize/2 per cell:<br/>discard tombstones,<br/>reduce metadata"]
    CMP --> GAPRISK["A lagging peer's<br/>needed pages now<br/>exist nowhere"]
    GAPRISK --> HOLD["Prefix hold +<br/>honest frontier"]
    HOLD --> GAP["Frontier-gap verdicts"]
    GAP -->|repeated| RB["Catalogue rebootstrap:<br/>install cells + re-fold + adopt frontier"]
    RB --> CONV["Converged again"]
```

## Element catalog

| Element | Responsibility |
| --- | --- |
| Stability frontier | The license to forget. An instance certifies, by containment of its local keys in every confirmed peer's tree, a point at or below which every replica holds every event. In a cluster this requires confirmation from *every* member of the reclamation set; a solo node certifies unconditionally. |
| Compaction | Truncates MST history at or below the certified point and advances the watermark. History is redundant below the frontier by definition — every replica already folded it — so compaction reclaims index and page space without touching values. |
| Reclamation | The per-cell half: each table's CRDT answers, through `stabilize/2`, what remains of a cell once nothing older can arrive — discard a tombstone, reduce ordering metadata, or keep. The license's exact boundary (clock-governed reductions only; context-governed ones need more than this frontier certifies) is stated and mechanically checked — see [deletion and reclamation](../database/deletion_and_reclamation.md) and [rationale](db_rationale.md). |
| Who confirms | On a durable database every cluster member, reachable or not, until a membership act retires it: a down or partitioned member holds compaction and reclamation back, and the writes each side of a partition accepted alone survive it. The in-memory `registry` database, whose history must not grow while a member is down, compacts on the peers heard from within `db.compaction.peer_timeout`. The deliberate consequence there: a long-silent node's needed registry history can be compacted away everywhere. |
| Repair (rebootstrap) | The recovery path for any truncation that outruns a peer: the registry's recency filter and retention, an unservable-root rebuild, or the merge dropping an event below the watermark. The returning node's holds keep its frontier honest; the persistent deficit produces gap verdicts; repeated verdicts schedule a catalogue rebootstrap, which installs the peers' *materialised cells* — values survive compaction even though events do not — re-folds the node's own logged events over them, and only then adopts their frontier. The node's own events survive throughout in its local log, and a crash mid-repair re-folds them at restart. |
| Bootstrap | The same install path, used at first join: a fresh instance takes a catalogue snapshot rather than paging through history it never had. |

## An episode, end to end

A node goes silent under registry write load. Its peers confirm among
themselves, certify, compact past registry history the silent node never
pulled, and keep writing. The node returns:

1. Its first complete round integrates the survivors' trees; the fold
   holds each truncated origin's later events (`events_held` metric
   bursts) — no state ever skips operations.
2. Its frontier, refusing to count held events, stays behind; every round
   ends in a gap verdict.
3. The second verdict schedules rebootstrap per affected shard; cells
   install, the node's own events re-fold over them, and the frontier is
   adopted; held events at or below the adopted frontier become ordinary
   re-folds.
4. Frontiers equalise; metrics go quiet. Elapsed, in the validated record:
   about three minutes from restart, under full load.

## Variability guide

Every element above runs on a timer with a budget. The options set how often
a pass runs and how much one pass may do, with the values `bondy.conf` uses
when you set nothing.

### The sweeps

`db.reclaim.interval` spaces the reclamation passes and
`db.reclaim.batch_cells` caps how many cells one pass scans, so a sweep
cannot monopolise an instance. `db.origin_retirement.interval` spaces the
retirement of departed peers, recorded under
`db.origin_retirement.path`. Each has an on/off key.

Separately, every instance inspects its own heap every `db.gc_interval` and
fullsweep-hibernates when it has grown past `db.gc_heap_delta`, reclaiming
the transient apply and anti-entropy garbage a long-lived process would
otherwise hold until its next major collection.

![Three sweep timers: reclamation, origin retirement, and the instance heap
monitor, each with its interval and its per-pass budget](img/db-sweeps.svg)

### Liveness, read two ways

`db.compaction.peer_timeout` is the recency window named above. It governs
compaction of the in-memory `registry` database only. Compaction of durable
databases and reclamation take a strict, membership-based reading with no
recency filter, so a silent member holds them down until an explicit
membership act retires it — no timeout changes that. `db.gc_max_concurrency` caps how many instances either
sweep may cycle at once — reclamation runs a second instance of the same
scheduler that drives compaction, and both read this one cap; instances over
it are skipped that tick and retried on the next. Despite the shared prefix
it has nothing to do with the `db.gc_interval` / `db.gc_heap_delta` heap
monitor, which is a separate subsystem.

```mermaid
flowchart LR
  P["Peer last seen<br/>N seconds ago"] --> C{"Registry compaction's<br/>stability read"}
  P --> R{"Durable compaction's and<br/>reclamation's membership read"}
  C -->|"N &lt; peer_timeout"| CI["counted — holds compaction back"]
  C -->|"N &gt; peer_timeout"| CX["excluded — compaction proceeds"]
  R -->|"still a member"| RI["counted — holds both down"]
  R -->|"retired by membership act"| RX["excluded"]
```

## Rationale

Forgetting is the only operation here that is irreversible, so it is the
only one gated on a cluster-wide proof; everything else — holding,
verdicts, rebootstrap — is reversible pressure toward convergence. A durable
database lets a silent member hold forgetting back, because forgetting past
it loses the writes it accepted alone once both sides of a partition have
truncated (`proofs/tla/ConfirmedCompaction_RootVV3_Fresh_Partition.cfg`), and
its history grows on disk meanwhile. The in-memory registry takes the
opposite trade: its history would grow in RAM, and its cells are meant to
be rebuilt from live sessions, so it forgets past a silent member
and treats the worst case as a first-class path with its own enforcement,
detection, repair, and validation.
