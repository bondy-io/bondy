# bondy_oplog: the write side

> Audience: anyone who needs to know what happens between
> `bondy_oplog:append/2` and "this event will survive a power cut".
> Time to read: ~15 min.

In the previous chapter we said `bondy_oplog` is "the write side". Let's
unpack that. The oplog has four jobs:

1. **Frame events** into a known shape (`{HLC, Origin, Seq}` keys,
   signature, payload).
2. **Persist** them durably to a Write-Ahead Log per instance.
3. **Replicate** them to peers without a leader — via the MST.
4. **Recover** them from the WAL after a crash.

This chapter is a slow walk through each.

## The unit of work: an instance

A `bondy_oplog_instance` is the smallest replicated unit. One instance
holds one MST, one WAL, one applier (durable mode), one compaction
checkpoint. Multiple instances can run side-by-side on the same node —
they are isolated from each other.

```mermaid
flowchart LR
    subgraph INSTANCE[One bondy_oplog_instance]
        WAL["WAL writer<br/>disk dir · or in-memory (fused)"]
        MST[("MST handle")]
        OV["Overlay · ETS"]
        APP["Applier<br/>(omitted in fused mode)"]
        VAL["Validator<br/>signs / verifies"]
        CKPT[Compaction checkpoint]
    end

    User(["Application"]) -- "append(Event)" --> INSTANCE
    Peers(["Peers"]) -- "sync session" --> INSTANCE
```

The instance is a gen_server, but the lock-free fast paths
(`append_fast`, lock-free `get`) bypass it when the validator is
stateless. The gen_server serialises:

- stateful-validator appends (`append`, `append_many`);
- peer event installs (`install_remote`);
- MST page exchanges (`get_pages`, `merge_pages`, `missing_set`);
- compaction operations (`compact`, `truncate_prefix`,
  `load_snapshot`);
- applier sync barriers (`drain_install_queue`,
  `await_overlay_drained`) — in fused mode these are serviced by the
  instance itself between drain slices (see below).

## An event has shape

Every event carries an **event key**:

```
{HLC, Origin, Seq}
```

- **HLC** is a Hybrid Logical Clock — monotonic across a node, and
  bounded by wall-clock skew across the cluster.
- **Origin** is the 16-byte identifier of the node that authored the
  event. Two replicas can't collide because their origins differ.
- **Seq** is a per-(HLC, Origin) tiebreaker for the rare case where
  two events at the same node share an HLC tick.

The event key is the **sort key** in the MST. That is why peers can
agree on order without any consensus: order is in the data.

The event also carries an **operation** — an opaque term the
substrate never interprets or serialises itself; meaning lives in the
table's CRDT module ([chapter 05](05_crdt_model.md)) — plus optional
`meta` (the tier_2 causal context travels here) and a signature from
the validator.

## The append path

```mermaid
sequenceDiagram
    autonumber
    participant C as Caller
    participant I as oplog_instance
    participant V as validator
    participant OV as overlay (ETS)
    participant W as wal (gen_server)

    C->>I: append(Event)
    Note over C,I: For stateless validators<br/>the caller process does this directly<br/>via append_fast.
    I->>V: build_key + sign_event
    V-->>I: signed Event'
    I->>OV: stage_to_overlay(Event')
    I->>W: append_batch(frame)
    W->>W: encode + CRC + write
    alt fsync_mode = per_write
        W->>W: fsync
    else fsync_mode = batched
        W->>W: enqueue for next barrier
    end
    alt WAL succeeds
        W-->>I: {Hlc, Segment, Offset}
        I-->>C: {ok, Hlc}
    else WAL fails
        W-->>I: {error, _}
        I->>OV: unstage_overlay(Event')
        I-->>C: {error, _}
    end
```

A couple of details to keep in mind:

- **The overlay is staged *before* the WAL append.** The invariant
  is "the applier can never observe a durable event without its
  overlay row". A failed WAL append rolls the overlay back via the
  instance's `unstage_overlay/2`.
- **The caller unblocks before the applier runs.** The applier is
  the process that materialises the event into the projection
  ([chapter 04](04_applier.md)). The caller's `ok` means "durable + visible in the
  overlay", not "materialised in the projection".

## The WAL on disk

One directory per instance, segments numbered with 9-digit IDs:

```
{wal_dir}/{instance_id}/
    manifest
    consumer.offset
    snapshot.watermark
    000000000.qdata
    000000000.qidx
    000000001.qdata
    000000001.qidx
    ...
```

Each segment file looks like this:

```mermaid
flowchart LR
    H["Segment header<br/>48 bytes · magic, id, origin, created"]
    F0["Frame 0<br/>magic + len + crc + body"]
    F1["Frame 1"]
    F2["..."]
    FN["Frame N"]
    T[("possibly torn<br/>trailing bytes")]

    H --> F0 --> F1 --> F2 --> FN --> T
```

Per-frame:

```
Magic | FrameLen | CRC32 | FrameVersion | Flags | Body (list of events, ETF)
```

The frame is the unit of atomicity: a multi-event batch becomes **one
frame**. If a crash leaves a partial frame at the tail of the head
segment, recovery truncates back to the last valid CRC boundary.

The companion `.qidx` is a sparse HLC index — used by operators and by
peer sync to jump into a segment at a target HLC without scanning the
whole thing.

## Two fsync modes

The namespace declares its durability policy:

| Mode | When `{ok, _}` is returned | Use it for |
|---|---|---|
| `per_write` | After fsync. Strictly durable. | Auth-critical (grants, tickets) |
| `batched` | After enqueue. `await_durable/3` is the barrier. | High-churn (registry) |

```mermaid
flowchart LR
    subgraph PERWRITE[per_write]
        AW[append] --> WW[write] --> FW[fsync] --> OK1[ok]
    end
    subgraph BATCHED[batched]
        AB[append] --> WB[write] --> OKB[ok queued]
        T[timer / barrier] --> FB[fsync] --> NEXT[durable_position advances]
    end
```

Both are written in pure Erlang and verified by PropEr crash tests.

## Fused mode: the ephemeral fast path

A table can opt its instances into **fused mode**
(`oplog_instance_opts => #{fused => true}`, ephemeral durability).
Fused mode collapses the applier into the instance gen_server: the
instance drains its own WAL and runs the full pipeline inline —

```
drain → verify → cell-apply → MST install → publish → overlay evict
```

(`fused_apply_batch/2` in `bondy_oplog_instance.erl`, reusing the
applier's state-free stages and emitting the applier's telemetry
events, so dashboards see one uniform write path). The supervisor
omits the applier and scrubber children entirely.

The one rule that makes this safe under sustained load: **the drain
yields**. After a bounded number of batches the instance re-queues the
drain message and returns to its mailbox, so `handle_call`/`handle_cast`
traffic — compaction triggers, `integrate_peer_root` (remote
convergence!), write-ack barriers — is serviced between drain slices
rather than starved behind an unbounded drain.

### The in-memory WAL

A fused instance can additionally select `wal_backend => mem`: the
disk WAL is replaced by `bondy_oplog_wal_mem`, an ETS `ordered_set`
queue keyed by a dense monotonic sequence. There is **no fsync and no
disk I/O on the ack path** — `head == durable` at all times, and the
fused drain reads the queue via an `ets:next/2` cursor
(`bondy_oplog_wal_mem_reader`). Consumed prefixes are garbage-collected
as the drain commits; a count-based cap (`max_live_events`) provides
the same `{error, wal_full}` backpressure shape as the disk WAL.

The durability deal is explicit and **cluster-provided**: an ephemeral
table's projection and MST are already memory-only — node death loses
them regardless of WAL backend, and the data re-converges from peers
via anti-entropy. Dropping the local fsync only widens the
acked-but-not-yet-replicated loss window to include
BEAM-crash-with-disk-survival; that window is covered by AE exactly
like node death. Durable tables never enter this code path — the
supervisor only honours `wal_backend => mem` for fused instances and
falls back to disk (with a warning) otherwise.

Producers are oblivious: the mem WAL speaks the same gen_server
protocol (`append_batch`, `await_durable`, committed-position
tracking) as `bondy_oplog_wal`.

## Replication: there is no leader

The novel bit of `bondy_oplog` is **how events get from one node to
another**. Two pieces conspire:

1. The **MST** is a content-addressed structure. Two peers compare
   roots and, in one round-trip, find exactly which pages they differ
   on. Chapter 02 (in the bondy_mst library docs) has the details.
   (Root comparison finds the *differences* to pull; whether two
   nodes hold the *same data* is judged separately, by the applied
   frontier — see below.)
2. A **single node-global `bondy_oplog_sync_scheduler`** ticks every
   `sync_interval_ms` (default 500 ms). On each tick it iterates
   the locally-running instances and, per instance, asks the
   configured peer source for a small subset of peers, then spawns
   one `bondy_oplog_sync_session` per peer via the dispatch
   callback (default: `bondy_oplog_sync_session:start/3`).

```mermaid
sequenceDiagram
    autonumber
    participant SCHED as sync_scheduler (singleton)
    participant INSTS as list_instances
    participant PS as peer_source
    participant SESS as sync_session
    participant PEER as peer (remote node)

    loop every sync_interval_ms (500 ms default)
        SCHED->>INSTS: bondy_oplog:list_instances/0
        INSTS-->>SCHED: [I1, I2, ...]
        par per instance
            SCHED->>PS: peers_for(InstanceId, Opts)
            PS-->>SCHED: [Peer1, Peer2, ...]
            par per peer
                SCHED->>SESS: start(InstanceId, PeerN)
                SESS->>PEER: get_root
                PEER-->>SESS: PeerRoot
                SESS->>SESS: missing_set + pull pages
                SESS->>PEER: integrate
            end
        end
    end
```

The session is short-lived and asynchronous. It does not block
writes, and a failing session is just retried on the next tick.

A converged instance has nothing to pull, yet a naive scheduler would
still spawn a session against every peer on every tick. The
**live-sync throttle** (on by default) makes the cadence adaptive: an
instance dispatches every tick while its MST root is moving, then
backs the poll window off — doubling up to `live_sync_max_ms` (default
5 s) — once the root goes quiescent, and snaps back to the base
interval the moment a poll pulls something. Because `bondy_db` is
pull-only, that capped window is also the steady-state convergence
latency for an idle shard. One exception: an instance that backs the
read-side freshness fence is **never** throttled, because its sync
round is what re-stamps the fence heartbeat (below) — backing it off
would trip the fence on inactivity.

A successful round does one more thing: it **advances the shard's
freshness signal**. Each `(NS, primary, Shard)` carries a wait-free
`ae_atomics` timestamp that `bump_ae_on_sync/2` stamps with the current
wall-clock time at the end of every completed round — including an
*empty* round, where the peer had nothing new. That heartbeat is what
lets a low-churn shard prove it is still in contact with its peers even
when no event has changed; the read side reads it as the freshness fence
([chapter 03](03_bondy_db.md)). Whether a round is allowed to certify
freshness is governed by an **isolation policy** (`refuse` / `proceed` /
`quorum`): a node that cannot reach a peer does not get to declare its
own data fresh under the default `refuse`. The policy lives here, on the
freshness-production side, so the read path stays a single atomic read.

The transport is pluggable (`bondy_oplog_transport` behaviour). Three
implementations ship: **`bondy_oplog_transport_partisan`** — the
production transport, which carries sync traffic over the same Partisan
overlay Bondy already uses for its cluster membership and messaging —
`bondy_oplog_transport_disterl` (Distributed Erlang), and
`bondy_oplog_transport_inline` (same-VM, used for tests). Bondy runs on
Partisan, not Distributed Erlang, so a Bondy deployment uses the
Partisan transport.

Root comparison tells a peer which pages to pull; it does not, on its
own, establish that two nodes hold the same data — compaction empties
the MST, so a converged instance's root is `undefined` and witnesses
nothing. Convergence is judged instead by a per-instance **applied
frontier**, a `#{Origin => max Seq}` version vector over applied events
(compaction-invariant), which a peer fetches with a `get_frontier`
request alongside `get_root`. The construction and its three-source
recovery are covered in
[chapter 06](06_compaction_and_bootstrap.md#the-applied-frontier-the-convergence-oracle);
on this side, the responder serves the request and the operator sync
view is what compares the two frontiers.

## Replication is anti-entropy only

Today replication is **exclusively anti-entropy** over the MST via
`bondy_oplog_sync_session`. A local append stages the overlay and
appends to the local WAL; peers learn about the event when a sync
tick walks the MST and pulls divergent pages.

```mermaid
flowchart LR
    LW[local writer] -->|stage overlay + append WAL| LOCAL["local overlay + WAL"]
    LOCAL -->|applier installs pages| MST[local MST]
    AE["sync_session<br/>(periodic, per peer)"] -->|missing_set diff| RM[remote MST]
    RM -->|pages| AE
    AE -->|integrate_peer_root| MST
```

A few notes:

- **Peer events do not flow through the remote WAL.** They arrive
  via the responder / sync_session and are forwarded to the
  remote instance, which stages them in the overlay; the
  receiving applier installs them into the MST + projection.
- **A future eager-push fast-path is intended.** An `enqueue_remote`
  hook is in place as the receive-side seam; the `eager_pushed` overlay
  tag it would carry is reserved for that future receiver and is not
  written yet. No sending-side pusher exists today, so treat
  sync-session cadence as the floor on cross-node visibility.

## Recovery on boot

What happens when a node restarts?

```mermaid
flowchart TB
    BOOT([instance subtree boots])
    WI["WAL writer init/1<br/>(bondy_oplog_wal_recovery:recover/_)"]
    M[read manifest]
    HEAD[open head segment]
    SCAN[tail-scan to last valid CRC]
    TRUNC[truncate any torn trailing bytes]
    OFF[clamp committed segment + load consumer.offset]
    II["instance init/1<br/>(HLC + MST + snapshot setup)"]
    AI[applier init/1]
    DRAIN["wal_reader drains → applier folds → installs"]

    BOOT --> WI --> M --> HEAD --> SCAN --> TRUNC --> OFF
    BOOT --> II
    OFF --> AI --> DRAIN
    II --> AI
```

- Recovery runs in the WAL writer's `init/1`, not the instance's
  init.
- The manifest is small and atomic; read in sub-ms.
- The tail scan is bounded by `max_segment_bytes` (default 64 MiB);
  the worst case is "scan one segment" — tens of ms.
- After the tail is clean, the applier resumes from the backend's
  **durability capability**, never from MST state: a **durable**
  backend resumes at the WAL's own committed consumer offset
  (`start_pos_from_consumer_offset/1`), a **volatile** (ets/map)
  backend replays from `beginning` to rebuild its lost MST. (Resuming
  from MST state was the old behaviour; a stale or absent root regressed
  the cursor to `beginning` and re-read the whole WAL every drain — the
  resume livelock fixed in [chapter 04](04_applier.md#crash-recovery).)
  The consumer offset doubles as the durability fence for WAL retention.
- Any events past the resume position get re-applied — CRDT
  idempotency makes that safe ([chapter 05](05_crdt_model.md)).
- **Identity survives restarts.** When `storage_path` is set and no
  explicit `origin` is configured, the supervisor loads (or persists,
  on first boot) the instance's origin from disk
  (`bondy_oplog_origin:load_or_create/1`), so recovery never rejects
  the node's own WAL segments as foreign. If the WAL would fall back
  to the per-OS-pid tmp path (identity and segments abandoned on
  restart), the supervisor logs a loud warning — configure
  `storage_path`/`wal_dir`, or declare `durability => ephemeral` to
  acknowledge it.

## Backpressure

The instance gates appends via overlay-size and WAL-availability
checks. There is no soft "hint" — appends either succeed or return
one of three error tuples (`bondy_oplog_instance.erl`):

```mermaid
flowchart LR
    A["append"]
    OK["{ok, Hlc}"]
    BP1["{error, backpressure}<br/>overlay event/byte caps hit"]
    BP2["{error, working_set_full}<br/>install queue saturated"]
    BP3["{error, wal_unavailable}<br/>WAL writer down / recovering"]
    Caller(["Caller backs off"])

    A --> OK
    A --> BP1 --> Caller
    A --> BP2 --> Caller
    A --> BP3 --> Caller
```

The overlay caps (`max_overlay_events`, `max_overlay_bytes`) are
read on the hot path via atomics so the check is wait-free. Disks
fill, partitions degrade, peers fall behind — backpressure is
*signalled*, not "the system crashes".

## The instance heap monitor

A `bondy_oplog_instance` is a long-lived `gen_server`, and applying a
high-volume event stream churns a lot of short-lived terms — the
apply/drain folds, the AAE page merges, the CRDT interpretation. The
BEAM's generational collector keeps that transient garbage around until
the next *major* collection, so a busy instance's heap can climb well
above its live working set and look like a leak. It is not — the process
reclaims under memory pressure — but the lingering peak is real, and most
visible during a **solo import** (no peers): the convergence-driven
hibernate that would otherwise sweep the heap never fires, because there
is no peer round to drive it, so the heap grows unchecked until the BEAM's
own GC catches up. This was the cause of a multi-GB resident-size scare on
a freshly-importing node that turned out to be instance-heap garbage, not
anti-entropy buffers.

The heap monitor closes that gap directly. It lives in its own module,
`bondy_oplog_heap_monitor` — passive state the instance drives from
`handle_info(gc_tick, …)`. A periodic `gc_tick`
(`instance_gc_interval_ms`, default `2000`; `0` disables) fullsweep-and-
hibernates the instance once its heap has grown past
`instance_gc_heap_delta_bytes` (default 16 MiB) over a post-GC baseline.
The decision is the pure `bondy_oplog_heap_monitor:gc_decision/3`: grown
past the delta → hibernate; shrank below the baseline → rebaseline to the
lower live size; grew but under the delta → keep accumulating against the
same baseline, so slow steady growth still trips eventually.

Two properties make it safe to run always-on:

- **It keys on *growth over the live baseline*, not absolute heap size.**
  An instance holding a large live MST (an ephemeral backend keeps the
  whole tree on-heap) is never GC-thrashed — the monitor fires roughly
  once per delta of *accumulated garbage*, capping the transient peak at
  ≈ `live + delta`, then settles at the new baseline.
- **It is independent of anti-entropy and free on the hot path.** It runs
  from its own timer, so it reclaims during a solo import where the
  convergence-driven hibernate cannot; and the append/drain path never
  touches it, so it adds nothing to write latency.

## The oplog truncates itself

The defining property of `bondy_oplog` is that the event log does not
grow without bound. Once peers confirm they have an event, the
`bondy_oplog_gc_scheduler` (1 s default tick) calls
`bondy_oplog_compaction:compact/1` for each instance, which:

1. computes a **stability frontier** from per-peer root hashes
   (`bondy_oplog_peer_state` filters out peers older than
   `peer_timeout_ms`, default 30 s). Because the frontier is derived
   from peer-synced roots — which only ever reflect installed,
   published events — it is always at or below the installed
   watermark, so `compact/1` needs **no** overlay-drain barrier and
   runs safely under sustained write load (fused included).
2. **Catalogue (projection-backed) instances skip the re-fold
   entirely** — the projection, maintained eagerly on write, *is* the
   per-cell `interpret_cog` checkpoint. A bare single-CRDT instance
   folds the stable range through `interpret_cog/2` and persists the
   result via the **compaction checkpoint**
   (`bondy_oplog_compaction_checkpoint`; file-backed when
   `storage_path` is set, ETS otherwise).
3. atomically truncates the MST via `bondy_mst:truncate/2` — a
   **structural prefix-truncate** that walks only the left spine,
   rewrites O(log N) pages, and leaves a root byte-identical to the
   equivalent per-key deletes — and advances the watermark.

```mermaid
flowchart LR
    PEERS["bondy_oplog_peer_state<br/>fresh root hashes"]
    FRONT["compute_frontier_for"]
    MODE{"catalogue?"}
    FAST["projection already current<br/>(no re-fold)"]
    INTERP["CrdtMod:interpret_cog<br/>(bare single-CRDT only)"]
    CKPT[compaction_checkpoint:put]
    TRUNC["bondy_mst:truncate/2<br/>(structural O(log N) prefix drop)"]
    WM[watermark advance]

    PEERS --> FRONT --> MODE
    MODE -->|yes| FAST --> TRUNC
    MODE -->|no| INTERP --> CKPT --> TRUNC
    TRUNC --> WM
```

At full quiescence the live MST is empty; new replicas bootstrap from
the checkpoint (or, for catalogues, the catalogue snapshot protocol)
via `bondy_oplog_sync_session` instead of replaying history.
[Chapter 06](06_compaction_and_bootstrap.md) walks through the full
lifecycle.

## Things to keep in mind

- **One writer per WAL.** No locking, no contention.
- **Events are signed.** The validator is the gateway for both local
  appends and peer-received events ([chapter 04](04_applier.md)).
- **WAL ≠ replication log.** The WAL is **per-node**; the MST is the
  replication structure. Peers don't replay each other's WALs.
- **The overlay is the read-your-writes primitive.** Without it,
  every read would block on the applier.
- **The MST is bounded.** Compaction physically deletes stable
  events; the live MST is a *window*, not a log ([chapter 06](06_compaction_and_bootstrap.md)).

## Pointers

Implementation:

- `bondy_oplog.erl` — the facade.
- `bondy_oplog_instance.erl` — the gen_server; lock-free fast
  paths, stateful-validator slow paths, `integrate_peer_root`,
  overlay staging; `fused_apply_batch/2` and the yielding fused
  drain.
- `bondy_oplog_heap_monitor.erl` — the periodic instance heap
  monitor (`new/0`, `arm/1`, `handle_tick/1`, the pure
  `gc_decision/3`); passive state driven by the instance from
  `handle_info(gc_tick, …)`.
- `bondy_oplog_wal.erl` — WAL gen_server: `append_batch/2`,
  `await_durable/3`, `set_committed_segment/2`. (The consumer offset
  is persisted by `bondy_oplog_wal_state:write_consumer_offset/2`.)
- `bondy_oplog_wal_mem.erl` + `bondy_oplog_wal_mem_reader.erl` —
  the in-memory (ETS) WAL backend for fused ephemeral instances.
- `bondy_oplog_origin.erl` — origin persistence under
  `storage_path` (`load_or_create/1`).
- `bondy_oplog_path.erl` — per-instance on-disk directory layout
  (`flat` | `sharded`, selected by the `path_layout` option).
- `bondy_oplog_compaction_checkpoint.erl` (+ `_ets` / `_file`) —
  the compaction checkpoint behaviour and backends.
- `bondy_oplog_wal_recovery.erl` — boot-time tail scan + manifest
  reconciliation.
- `bondy_oplog_wal_frame.erl`, `_segment.erl`, `_idx.erl`,
  `_manifest.erl`, `_codec.erl` — on-disk format.
- `bondy_oplog_sync_scheduler.erl` — single global scheduler;
  `run_tick/1`, `dispatch_for/2`.
- `bondy_oplog_sync_session.erl` — `run/3`, `bootstrap/3`,
  `pull_until_complete`; `bump_ae_on_sync/2` and
  `maybe_bump_ae_isolated/1` (the per-round freshness heartbeat) and
  `should_certify_freshness/1` (the isolation policy).
- `bondy_oplog_transport.erl` (+ `_partisan.erl` / `_disterl.erl` /
  `_inline.erl`) — the transport behaviour and its three
  implementations; Bondy uses the Partisan transport.
- `bondy_oplog_registry.erl` holds the per-instance **applied frontier**
  (the convergence oracle) and its idempotent max-merge;
  `bondy_oplog_cell_apply.erl` advances it on the apply path and
  `bondy_oplog_responder.erl` serves the `get_frontier` request
  ([chapter 06](06_compaction_and_bootstrap.md#the-applied-frontier-the-convergence-oracle)).
- `bondy_oplog_config.erl` — the layer's public configuration surface:
  one accessor per tunable, each holding its default once and read live
  from the application environment (not a cached snapshot, so a runtime
  `set_env` takes effect on the next read). It covers the scheduler
  cadence; the anti-entropy regulators (`aae_max_concurrency`,
  `aae_max_pages_in_flight`, the live-sync throttle bounds, the
  `aae_load_adaptive` yield); the durable-seal mode and threshold
  (`pack_seal_mode`, `pack_auto_seal_bytes`); the instance heap monitor
  (`instance_gc_interval_ms`, `instance_gc_heap_delta_bytes`); the fence
  isolation policy; and GC concurrency.
- `bondy_oplog_validator.erl` (+ `_crypto.erl` / `_trust.erl`).
