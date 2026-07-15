# bondy_db: the read side

> Audience: anyone who needs to know how `bondy_db:read/3` turns into a
> nanosecond.
> Time to read: ~15 min.

`bondy_db` is the consumer-facing reader. Applications never read from
the oplog directly — they go through `bondy_db`, which composes three
storage tiers (cache, overlay, projection) and a per-namespace fold
strategy into a single, predictable read API.

The substrate-level primitive is `bondy_oplog_core`; `bondy_db` is the
thin facade that adds Bondy-style tables, realms, and topology. Both
live in this package.

## The mental model: three tiers

```mermaid
flowchart TB
    subgraph HOT["Hot, in-RAM"]
        CACHE["cache_adapter<br/>bondy_oplog_cache_ets"]
        OV["overlay<br/>ETS, ordered_set"]
    end
    subgraph WARM["Warm, on-disk"]
        PROJ["projection_adapter<br/>bondy_db_projection_leveled per shard"]
    end

    CACHE -. "miss → read" .-> PROJ
    OV    -. "merge with" .-> PROJ

    subgraph FOLD[Per-namespace]
        F[fold_module]
    end
    F --- PROJ
    F --- OV
```

- **Cache** is the read-after-first-read fast path. A hit returns
  `{Value, Hlc}` without touching the LSM.
- **Overlay** is the "events not yet folded into the LSM" buffer.
  Without it, every read after a write would block on the applier.
- **Projection** is the materialised state — one cell per
  `(Bucket, Key)`, value is `<<HlcLen:16, Hlc/binary, FoldedValue>>`.

The **CRDT module** is what gives the read its semantics.
[Chapter 05](05_crdt_model.md) covers the contract in detail; here,
just note that the read path interprets the overlay's live group of
pending events *on top of* the projection state through the CRDT's
own `interpret_cog/2` (via
`bondy_oplog_cell_kernel:interpret_overlay/4`) — a group
interpretation, never a per-event state fold.

## What a cell looks like

A projection cell value, on disk:

```mermaid
flowchart LR
    subgraph CELL[Cell value frame · V2]
        V["Version<br/>8-bit (= 2)"]
        F["Flags<br/>HasValueColumn:1 · Reserved:7"]
        H["HlcLen<br/>16-bit"]
        HLC["Hlc bytes<br/>(length-prefixed)"]
        STATE["StateBytes<br/>encode_state/1 of the folded CRDT state<br/>(32-bit length-prefixed)"]
        VAL["ValueBytes<br/>(32-bit length-prefixed; only when HasValueColumn = 1)"]
    end

    V --> F --> H --> HLC --> STATE --> VAL
```

The HLC is **always present**. Reads return `{Value, Hlc}`, period.
Causality is exposed, not synthesized. This is the load-bearing
choice that lets multi-cell reads detect skew without any cluster
coordination.

## Following a read

```mermaid
sequenceDiagram
    autonumber
    participant App
    participant Core as bondy_oplog_core
    participant Reg as registry
    participant Cache
    participant Proj as projection
    participant Ov as overlay
    participant K as cell kernel / CRDT

    App->>Core: read(NS, Idx, Bucket, Key)
    Core->>Reg: lookup(NS, Idx, shard_for(Bucket,Key))
    Reg-->>Core: {cache, proj, kernel, ...}

    Core->>Cache: get(Key)
    alt cache hit
        Cache-->>Core: {Value, Hlc}
        Core-->>App: {Value, Hlc}
    else cache miss
        Core->>Proj: get(Key)
        alt no projection cell
            Proj-->>Core: not_found
            Note over Core,K: State = CrdtMod:init()<br/>ProjHlc = 0
        else cell exists
            Proj-->>Core: V2 frame (Hlc · StateBytes · [ValueBytes])
            Core->>K: decode_state(StateBytes)
            K-->>Core: State
        end
        Core->>Ov: events_for(Key, after=ProjHlc)
        Ov-->>Core: [Event1, Event2, ...]
        Core->>K: interpret_overlay(State, [Event1, ...])
        Note over K: CrdtMod:interpret_cog — the live group<br/>interpreted on top of the projection state
        K-->>Core: {Value, Hlc}
        Core->>Cache: put(Key, {Value, Hlc})
        Core-->>App: {Value, Hlc}
    end
```

The slow path is "one LSM get + one group interpretation" — typically
a couple of microseconds. The cache hit is sub-microsecond.

## The overlay, in pictures

> Note: the **`bondy_db` facade** provisions every shard with `overlay =>
> disabled`, so facade reads do **not** merge an overlay — read-your-writes
> comes from `apply/4`'s `await_apply` step (see
> [Read-your-writes and the write barrier](#read-your-writes-and-the-write-barrier)
> for why, and what it guarantees). The overlay-merge read path described here
> is a `bondy_oplog_core` capability used by non-facade consumers (and configs
> that enable it).

The overlay key shape is the trick:

```
{{Bucket, Key}, EventHlc, EventKey}
       ^             ^         ^
       |             |         full event key (Hlc, Origin, Seq)
       |             orders within a (Bucket, Key) by HLC
       composite cell key — Bucket + Key, not a single token
```

This means `ets:select` can answer "give me all events for
`(Bucket, Key)` with HLC > T, in HLC order" in one match-spec — no
per-key linear scans, no sorting in Erlang
(`bondy_oplog_db_overlay.erl:111`, match-specs at lines 124-129,
146-155, 173-183).

```mermaid
flowchart LR
    subgraph OVERLAY[ETS ordered_set]
        E1["{ {B,K1}, H1, ekA }"]
        E2["{ {B,K1}, H2, ekB }"]
        E3["{ {B,K1}, H3, ekC }"]
        E4["{ {B,K2}, H1, ekD }"]
        E5["{ {B,K2}, H2, ekE }"]
    end

    READK1["read (B,K1)<br/>after H1.5"] -.->|ets:select| E2
    READK1 -.-> E3
    READK2["read (B,K2)<br/>after 0"] -.-> E4
    READK2 -.-> E5
```

The instance (not the applier) evicts overlay rows per-event after
the install batch completes — the overlay stays bounded
(`bondy_oplog_instance.erl:evict_overlay_batch/2`).

## Cache invalidation

The cache is kept coherent via **invalidate-on-commit**: after the
applier writes a projection cell, it explicitly evicts the cache
entry for that `(Bucket, Key)` so the next read repopulates from the
projection.

```mermaid
sequenceDiagram
    autonumber
    participant App as applier
    participant Adapter as projection_adapter
    participant Cache as cache_adapter

    App->>Adapter: put_batch([{Bucket, Key, NewFrame}])
    Adapter-->>App: ok
    App->>Cache: delete(Handle, Bucket, Key)
    Note over App,Cache: invalidate_cache/4<br/>(bondy_oplog_cell_apply.erl)
```

There is also an optional **write-through warmth** path,
`bondy_oplog_core:write_through/5`, that an application can call to
populate the cache directly for known hot keys. It only touches the
cache; the projection itself is still written by the applier.
Today's `bondy_db` facade does not use it.

## Read-your-writes and the write barrier

A caller of the facade gets **read-your-writes**: once `apply/4` returns,
that caller's next `read/3` observes the write. The facade delivers this
guarantee not by merging an overlay on the read, but with a **synchronous
write barrier** on the write.

`apply/4` appends the event and then blocks in `bondy_oplog:await_apply/1`
until the applier has installed it — written the new cell frame to the
projection and, by invalidate-on-commit (above), evicted the stale cache
entry. So by the time `apply/4` returns, the projection holds the new value
and the next read repopulates the cache from it. The barrier — not an
overlay — is the read-your-writes mechanism.

### Why the overlay is disabled here

The overlay-merge read path (above) *could* make a staged write visible
before it installs — read-your-writes without blocking. The facade opts
out: every facade shard is provisioned `overlay = disabled`
(`bondy_db.erl`, `bondy_oplog_core_registry`'s `overlay` field). The reason
is the cache. Facade reads are **cache-first**, and a cache hit never
consults the overlay (`bondy_oplog_core:do_read_traced/3`). Keeping an
overlay coherent with the cache would mean invalidating the cache on every
*staged* write — which holds a write-hot key's cache permanently cold,
defeating the point of the cache on a read-dominated workload.

So `overlay = disabled | tid()` is a **per-shard read-versus-write policy**,
not an oversight: `bondy_oplog_core` offers the overlay-merge path for
consumers whose balance favours it; the read-heavy `bondy_db` facade keeps
its cache hot and pays for read-your-writes on the rarer write.

### What the barrier guarantees

Blocking until install buys three properties a non-blocking write would not:

- **Read-your-writes** — the writer's own next read sees the write.
- **Session causality** — because write A installs before the caller issues
  write B, an observer never sees B without A, *even when A and B land on
  different shards with independent drains*. A caller's writes become
  visible in the order it issued them. (This is the local, same-node
  guarantee; cross-node causal reads are the [freshness fence](#the-freshness-fence)
  below.)
- **Read-modify-write correctness for context-carrying (tier_2) types** — a
  `tier_2` write first reads the cell's committed causal context (a version
  vector) via `apply_with_context/4` → `cell_context/3`, stamps it into the
  event, then appends. The barrier guarantees that context read reflects all
  of the caller's prior committed writes, so a causally-later write is
  recorded as *later* — not as a false concurrent sibling. Without the
  barrier a `tier_2` write could read a context missing an in-flight prior
  write and be merged as a spurious conflict.

### The tradeoff it encodes

Reads are cache-fast; writes carry the barrier. This is tuned for the
read-dominated, consistency-sensitive workloads the facade serves —
authentication, RBAC, registry resolution — where a write is comparatively
rare and its cost is well spent on the strong guarantees above. The
corollary is that a write's latency, and a single shard's *write*
throughput, are bound by **install latency** — the applier folding the
event into the MST and projection — not by the (lock-free) append. A shard
that is write-hot therefore feels the barrier where a read-hot one never
does.

## The freshness fence

Reads can be **causal** when they need to be. The substrate exposes a
wall-clock predicate on `bondy_oplog_core`:

```erlang
bondy_oplog_core:ensure_fresh([users, grants], milliseconds(1000)).
```

Each `(NS, primary, Shard)` registers an **`ae_atomics`** ref (a
one-element atomics array; see `bondy_oplog_core_registry.erl`) holding
the wall-clock time at which that shard last proved itself in contact
with its peers. The predicate is wait-free: read the atomic, subtract
from `now`, compare to MaxLag. The fence inspects **primary shards
only** (`primary_shards_for/1`) — auth reads primary cells; a secondary
index has its own `max_lag` path.

The subtle part is *what advances the timestamp*. Two writers stamp it,
and the second is the one that makes the fence usable:

- the **applier**, after it commits a batch for the shard (data flowed,
  so the shard is current);
- the **sync session**, at the end of every completed anti-entropy round
  — *including an empty round* where the peer had nothing new
  (`bump_ae_on_sync/2`, [chapter 01](01_bondy_oplog.md)).

Without the second writer a low-churn shard — exactly the security
tables — would decay to "stale" the moment writes stopped, even on a
perfectly healthy cluster, and the fence would refuse all auth. The
per-round heartbeat is what lets an idle shard keep proving liveness. The
targets a round freshens are fixed at instance birth (`ae_targets`), so
there is no window in which a shard is live but unstamped.

A node that cannot reach a peer must not stamp itself fresh — otherwise a
partitioned replica would happily authenticate against stale data. An
**isolation policy** decides whether a round may certify freshness:

| Policy | A round certifies freshness when… |
|---|---|
| `refuse` (default) | the round actually reached a peer (`synced`). A solo node never certifies — it fences closed. |
| `proceed` | always — availability over consistency for a single-node or trusted deployment. |
| `quorum` | the node can see a strict majority of the membership. |

The policy lives on the freshness-*production* side (the sync session),
so the read path stays one atomic read with no policy logic on it.

```mermaid
flowchart LR
    NS[namespaces in scope] --> SHARDS["primary shards for each NS<br/>(primary_shards_for/1)"]
    SHARDS --> READA["read ae_atomics ref"]
    READA --> CHECK["now - last_ae < MaxLag ?"]
    CHECK -->|all true| OK[ok]
    CHECK -->|some false| STALE["{stale, [NS, ...]}"]
```

This is the load-bearing primitive for security consistency. The auth
path verifies the token locally, fences, then reads:

```mermaid
sequenceDiagram
    participant Client
    participant Auth
    participant Core as bondy_oplog_core
    participant FRESH as ensure_fresh

    Client->>Auth: present credential
    Auth->>Auth: verify signature + expiry (local)
    Auth->>FRESH: bondy_oplog_core:ensure_fresh([users, grants], 1s)
    alt stale
        FRESH-->>Auth: {stale, [...]}
        Auth-->>Client: refuse — temporarily_unavailable
    else fresh
        FRESH-->>Auth: ok
        Auth->>Core: bondy_oplog_core:read(users, primary, Subject)
        Auth->>Core: bondy_oplog_core:read(grants, primary, Subject)
        Auth-->>Client: proceed
    end
```

A stale node refuses *every* authentication method with a single generic
reason, `temporarily_unavailable` (an HTTP `503` or a WAMP abort) — the
client retries after a short delay rather than being told its credential
is wrong.

Crucially, the predicate is **independent of the projection that might be
stale**. Whether or not the projection has been updated, the `ae_atomics`
timestamp tells you when the shard last completed a full anti-entropy
round with its peers — which is the thing a security decision actually
needs to know.

## `read_batch/2` — atomic-as-of-fence reads

When the application needs multiple cells at a common point in time:

```erlang
bondy_oplog_core:read_batch(
    %% batch keys are {Namespace, Index, Bucket, Key}
    [{users, primary, Realm, U1}, {grants, primary, Realm, U1}],
    #{fence => hlc:now(),
      max_lag => milliseconds(100),
      consistency => causal,
      require_skew_below => milliseconds(50)}
).
```

Semantics (`bondy_oplog_core:read_batch/2`):

```mermaid
flowchart LR
    R["fence Hlc<sub>F</sub>"] --> E1[ensure_fresh]
    E1 -->|stale| ERR["{error, stale}"]
    E1 -->|ok| F["per-cell read<br/>overlay events with Hlc ≤ Hlc<sub>F</sub>"]
    F --> SKEW{skew within<br/>require_skew_below ?}
    SKEW -->|yes| RES["{ok, #{Key => {Value, Hlc}}, Hlc<sub>F</sub>}"]
    SKEW -->|no| ERR
```

- Every read in the batch sees the **same upper bound**.
- The caller observes per-cell HLCs and can compute skew.
- This is *consistent-as-of-now* with skew detection — not
  MVCC-as-of-historical-T.

## Change notification

A read tells you the value now; sometimes a consumer needs to *react* the
moment a value changes — and, in particular, to distinguish a change it
made itself from one a peer made. `bondy_oplog_core` exposes a
subscription seam for exactly that:

```erlang
{ok, Ref} = bondy_oplog_core:subscribe(NS, all),
%% ... your process now receives, per change to NS:
%%   {bondy_oplog_core_event,       NS, Key, Hlc, Op}  — a local write
%%   {bondy_oplog_core_merge_event, NS, Key, Hlc, Op}  — a peer's write, merged via AE
```

The two tags carry the **same** shape — `Op` is the raw table write op,
`{set, Value}` for a write or `clear` for a delete (the explicit
`{clear, Hlc}` form is also accepted); the `Hlc` travels as its own field
in the message tuple, not inside `Op` — so a reactor can match one tag or
both. The distinction is the whole point:

- A **local** write already ran its side-effects inline at the call site
  (that is where the application code is). A reactor that cares only
  about its own node ignores the local tag.
- A **merge** event is how a node learns of a change that originated on a
  *peer* and arrived through anti-entropy — the substrate's equivalent of
  an "on-merge" hook. It is emitted from the one place a remote write
  reaches the projection (the cell-apply engine, [chapter 04](04_applier.md)),
  so it covers every replay path.

Notification is **opt-in per table**: only a table opened with `publish
=> true` emits, and emission costs nothing on tables that do not. The
dispatcher (`bondy_oplog_core_dispatcher`) fans out in the publishing
process with a plain `erlang:send/2` — no extra hop, no mailbox in the
write path. For a realm-folded (`shared_shards`) table the `Key` in the
event is the folded `<<Realm, 0, Key>>`; the reactor splits it to recover
the realm.

The canonical consumer is a single node-local reactor that turns a peer's
change into a local effect — closing sessions when a peer deletes a user
or realm, re-evaluating cached authorization when a peer changes a grant.
[Chapter 07](07_app_developers_tour.md#5-reacting-to-a-peers-change)
works that example through the Bondy Router tables.

## Secondary indexes

Secondary indexes are **wired**. A table opened with `indexes =>
[Spec]` gets, per declared index, a term-sharded index keyspace that
answers "which primary keys have term `T`?" without scanning and
decoding every value.

```erlang
{ok, Users} = bondy_db:open_table(Db, users, #{
    fold_module => lww_register,
    indexes => [#{
        name      => by_status,
        extract   => [status],      %% field path into the value
        normalize => downcase,
        projects  => [name, status] %% denormalised columns (optional)
    }]
}),
%% ... apply some writes, then:
{ok, Rows} = bondy_db:index_get(Users, <<"acme">>, by_status, <<"active">>, #{}),
%% Rows :: [{PrimaryKey, ColumnsMap}]
```

**Durability follows the table; always rebuildable.** Index cells live
next to the data they index and inherit its lifecycle. A durable
(`leveled`) table gets **persisted** indices: trusted across restarts via
a cold-start marker and re-folded from the primary (`cell_keys/2`) only
when that marker is absent — not on every boot. An ephemeral (`ets`)
table gets **RAM** indices, rebuilt from the primary at startup. (ETS
indices are never used on the durable stack — volatile indices over
durable data would be silently lost on restart.) Either way the index is
a deterministic function of the primary, so the authoritative copy is
always the primary and the index is a disposable accelerator. Bondy
builds these index cells itself rather than using leveled's native 2i,
which is incompatible with the `head_only` write mode the durable
projection uses.

**Term-sharded.** Each index is its own shard-set under
`(NS, IndexName, SecShard)`, sharded by `phash2({SecBucket, Term},
SecShardCount)`. An equality read (`index_get/5`) hits exactly one
shard; a range read (`index_range/6`) scatters across all of them and
merges into one globally `(term, primary-key)`-ordered list (terms span
every shard).

**Asynchronous writer + lag fence.** The primary applier computes the
old→new term diff for free — it already decoded both values — and after
the primary write commits it casts the index ops to a per-shard
`bondy_oplog_secondary_writer`. The writer batches, coalesces, and
read-modify-writes each touched index cell through the `index_entry`
fold (LWW-over-presence keyed by the primary's HLC, so an out-of-order
local-drain-vs-peer-replay delivery still converges). Because the write
is asynchronous, an index can lag the primary; reads can fence on it:

- `index_get(.., #{max_lag => Ms})` refuses with
  `{error, {stale_secondary, IndexName, Lag}}` if the touched shard
  was not freshened within `Ms` (`Lag` is the ms lag, or `infinity`
  when never freshened or flagged for rebuild).
- `#{fallback => primary}` instead scans the primary directly and
  recomputes the matching keys (slow but always correct).

**Back-pressure + self-healing.** Each shard carries an in-flight
atomic; if a hot shard's backlog would exceed its `max_inflight` cap
the applier *drops* the batch, marks the shard `needs_rebuild`, and
asks `bondy_oplog_index_rebuild` to re-materialise it from the primary
MST. The same rebuild path runs on a writer crash and at startup
(backfill). Memory stays bounded and correctness is preserved: the
index is rebuildable, and stale reads refuse until it catches up.
`bondy_db:rebuild_index/2` exposes the rebuild for operators;
`bondy_db:index_lag/2` reports per-shard `{lag, inflight,
needs_rebuild}`.

## Range scans

```mermaid
sequenceDiagram
    participant App
    participant Core as bondy_oplog_core
    participant Proj
    participant Ov as overlay

    App->>Core: range(NS, Idx, Bucket, Lo..Hi)
    Core->>Proj: range(Lo..Hi)
    Proj-->>Core: cursor
    Core->>Ov: overlay_range(Lo..Hi, after=earliest_proj_hlc)
    Ov-->>Core: list
    loop each result
        Core->>Core: merge projection cell with overlay events
    end
    Core-->>App: results
```

Ranges respect the same fold contract as point reads, only batched.

## Topology and the registry

`bondy_db` (the consumer facade, above `bondy_oplog_core`) introduces:

- **Tables** — like SQL tables but realm-scoped.
- **Topologies** — pluggable strategies for which Bookie owns which
  shard, and how a cell key is formed. Four ship:
  `bondy_db_topology_single_bookie`, `bondy_db_topology_per_entity`,
  `bondy_db_topology_shared_shards` (the three leveled-backed durable
  topologies, sharing their Bookie/directory plumbing via
  `bondy_db_topology_leveled_common`), and `bondy_db_topology_memory`
  (an in-RAM ETS provider for ephemeral tables).

### Realm folding

How the realm enters the cell key is **topology-decided**, and it matters
because the security and routing tables are multi-tenant. Under
`shared_shards` every table multiplexes onto one shard set, so the realm
is **folded into the key** — a cell is stored at `<<Realm, 0, Key>>`
(realm URIs are NUL-free, so the separator is unambiguous). Two realms
writing the same logical key land on distinct cells, with no chance of
collision. Under `per_entity` and `memory` the realm is already the
bucket, so the key is stored verbatim. A reactor or operator reading a
raw cell key recovers the realm by splitting at the first NUL; the rest
is the table's own key.

### The topology manifest

A durable DB's keying configuration — partition strategy, shard count,
each table's `shard_by` / aggregate-root — determines *where on disk*
every cell lives. Change it after data exists and reads silently miss.
`bondy_db_manifest` defends against that: the first time a durable DB
opens it **freezes** that configuration to an on-disk manifest, and every
subsequent boot reconciles the running config against it. A mismatch is
reported per the `oplog.core.on_topology_mismatch` policy (`warn` by
default, `stop` to refuse the boot). Ephemeral DBs (the registry — wiped
on restart) keep no manifest. The `core` DB's partition strategy
(`partition_strategy`, default `aggregate`) is part of the frozen set:
it is what decides which shard a `(realm, key)` write routes to.

The frozen manifest also yields a **topology fingerprint** that a node
advertises during anti-entropy. Two peers compare their applied
frontiers — the cross-node convergence oracle (`bondy_oplog`,
[chapter 06](06_compaction_and_bootstrap.md#the-applied-frontier-the-convergence-oracle)) —
only when their fingerprints agree, so a node that keys its data
differently is never mistaken for a divergent replica of the same
data. The operator sync view reads convergence this way: it compares
applied frontiers, not MST roots.

```mermaid
flowchart LR
    APP[Application] --> FACADE[bondy_db]
    FACADE --> TOPO["topology<br/>route+bucket_for"]
    FACADE --> CORE[bondy_oplog_core]
    CORE   --> REG[db_core_registry]
    REG    --> SHARDS["one entry per<br/>(NS, Index, Shard)"]
```

The registry entry per `(NS, Index, Shard)` carries:

- `projection_adapter` + `projection_handle` — published by the
  **shard owner** (typically `bondy_db:provision_shard/9`) at
  open time, not by the applier itself.
- `cache_adapter` + `cache_handle` — same.
- `overlay` — the per-instance ETS overlay tid.
- `crdt_module` — the per-table CRDT ([chapter 05](05_crdt_model.md));
  a legacy `fold_module` label resolves to its native twin.
- `ae_atomics` — the wait-free freshness ref read by `ensure_fresh/2`,
  stamped both by the applier on commit and by the sync session at the
  end of every round (the per-round heartbeat). The `(NS, primary,
  Shard)` targets are fixed at instance birth (`ae_targets`).
- For secondary-index shards, additionally a `writer_pid` and an
  `inflight_ref` (the in-flight counter + `needs_rebuild` flag);
  primary shards carry an `instance_id` so a rebuild can find the
  applier to re-fold.

The applier reads the registry at init to resolve its
`cell_apply_target` — the (projection, cache, fold, overlay) tuple
it writes through on every event.

## Projection backend: durable vs ephemeral

The registry entry's `projection_adapter` is chosen **per table** from
`open_table`'s `projection_backend` option:

- `leveled` (default) — the durable path. The topology's `route/2`
  hands back a Bookie handle; state survives restart and is the source
  of truth on a cold start.
- `ets` — an in-RAM projection (`bondy_oplog_projection_ets`). Nothing
  is persisted; the table starts empty and reconverges from peer
  anti-entropy.

`ets` alone only makes a table **ephemeral** if the *whole* stack is
in-memory — the MST store and the WAL too. Otherwise WAL replay would
resurrect dead entries on restart. The **caller assembles** that stack
from three independent keys: `projection_backend => ets` +
`oplog_instance_opts => #{backend => ets}` (in-memory MST) + no
`storage_path` anywhere in the cascade. `durability => ephemeral` is the
explicit acknowledgement of that intent — it does not enforce the bundle;
it only silences the "no durable storage" warning the missing
`storage_path` would otherwise log. The WAL still writes to a per-PID
tmp path (`/tmp/bondy_oplog_wal/<os_pid>/…`); what makes it
restart-safe is that the path is `os:getpid()`-namespaced, so a fresh
BEAM never replays the prior run's segments — not that the WAL is
non-durable within a run.

This is what ephemeral namespaces need: WAMP registrations and
subscriptions die with the node's transport connections, so persisting
them would only resurrect dead, unroutable entries on restart. An
ephemeral table starts empty after a restart and rebuilds its live
state from peers — never from disk.

Backends can be mixed within one DB — a durable `leveled` table and an
ephemeral `ets` table coexist under the same topology
(`bondy_db_topology_memory` is itself a DB-scoped ETS provider for the
ephemeral case).

### Fused ephemeral tables

An ephemeral table can additionally opt into **fused mode** —
`open_table(Db, Name, #{fused => true, …})` — which collapses each
shard's applier into its instance gen_server, and optionally swap the
WAL for the in-memory backend
(`oplog_instance_opts => #{wal_backend => mem}`), eliminating disk
I/O from the write path entirely. This is the high-throughput
configuration for registration/subscription-style tables; durability
is cluster-provided via anti-entropy exactly as for any ephemeral
table. The mechanics live in [chapter 01](01_bondy_oplog.md); the
read/write API here is unchanged.

## Things to keep in mind

- **Reads are lock-free.** Cache hit is ETS read. Cache miss is one
  Leveled get + a tiny overlay fold.
- **HLC is always returned.** Causality is part of the API.
- **Bounded staleness is a per-shard concern.** `ensure_fresh/2`
  reads the per-shard primary `ae_atomics` ref, stamped by both the
  applier (on commit) and the sync session (every round, the heartbeat);
  auth namespaces fence on it, routing namespaces don't.
- **Changes can be subscribed to.** A `publish => true` table emits a
  local `{bondy_oplog_core_event, …}` and a remote
  `{bondy_oplog_core_merge_event, …}` per change; a node-local reactor
  turns a peer's change into a local effect.
- **The applier is the only writer to the projection.** Readers
  share that handle through the registry.
- **Cache coherence is by invalidation.** The applier deletes the
  cache entry after each projection write; the next read
  repopulates.
- **Secondary indexes are wired, and their durability follows the
  table.** A table's `indexes => [Spec]` provisions a term-sharded index
  shard-set fed by an async `bondy_oplog_secondary_writer`; reads go
  through `index_get/5` / `index_range/6` with a `max_lag` fence. A
  durable (`leveled`) table gets **durable** indices — persisted beside
  the data, trusted across restarts via a cold-start marker and re-folded
  from the primary (`cell_keys/2`) only when that marker is absent. An
  ephemeral (`ets`) table gets **ETS** indices — volatile, rebuilt from
  the primary. ETS indices are never used on the durable stack.
- **Writes can be packed.** A single write to a Map (or set) cell may
  carry many commands: `apply_batch/4` packs `[{put, F, V}, {rmv, F},
  …]` (or the `map_update/4` `#{put => …, rmv => …}` sugar) into one
  `{batch, Ops}` event — one WAL/MST entry, one projection
  read-modify-write, applied atomically. Only the dot-store / grow-set
  CRDTs are batchable; counters and registers are refused. See
  [The CRDT model](05_crdt_model.md#batched-operations-packing-many-commands).

## Pointers

Implementation:

- `bondy_db.erl` — the consumer facade (tables, realms, topology).
- `bondy_oplog_core.erl` — substrate read API: `read/3`,
  `read_batch/2`, `ensure_fresh/2`, `range/4`, `write_through/5`; the
  change-notification facade `subscribe/2`, `publish/4`,
  `publish_merge/4`.
- `bondy_oplog_core_registry.erl` — per-(NS, Index, Shard) handle
  store; `primary_shards_for/1` (the fence scope) + the `ae_atomics`
  stamping.
- `bondy_oplog_core_dispatcher.erl` — the subscription dispatcher and
  the `bondy_oplog_core_event` / `bondy_oplog_core_merge_event` tags.
- `bondy_db_topology_single_bookie.erl`,
  `bondy_db_topology_per_entity.erl`,
  `bondy_db_topology_shared_shards.erl` — the three durable topologies
  (shared leveled/Bookie plumbing in
  `bondy_db_topology_leveled_common.erl`); `bondy_db_topology_memory.erl`
  is the in-RAM provider for ephemeral tables.
- `bondy_db_manifest.erl` — the on-disk topology manifest that freezes a
  durable DB's keying configuration and reconciles it on every boot.
- `bondy_oplog_db_overlay.erl` — `{{Bucket, Key}, EventHlc, EventKey}`
  ETS overlay with match-spec range reads.
- `bondy_oplog_cache_adapter.erl` + `bondy_oplog_cache_ets.erl`
  — cache behaviour and the single ETS implementation.
- `bondy_oplog_projection_adapter.erl` +
  `bondy_db_projection_leveled.erl` /
  `bondy_oplog_projection_ets.erl` — durable (Leveled) and ephemeral
  (in-RAM) projections.
- `bondy_db_topology_memory.erl` — DB-scoped ETS projection provider
  for ephemeral tables.
- `bondy_oplog_cell_frame.erl` — V2 cell encoding:
  `<<2:8 (version), HasValueColumn:1, _Reserved:7, HlcLen:16, HlcBin, StateLen:32, StateBin, [ValueLen:32, ValueBin]>>`
  — the value column is present only when `HasValueColumn = 1` (folds
  whose value differs from their state; a G-Set omits it). The
  user-facing HEAD wire format the leveled tag projects is the shorter
  `<<HlcLen:16, HlcBin, ValueBytes>>`.

Secondary indexes:

- `bondy_oplog_index_spec.erl` — declarative index spec (extract,
  normalize, projects, `max_lag`, `max_inflight`).
- `bondy_oplog_index_key.erl` — order-preserving `(Term, PrimaryKey)`
  composite-key codec.
- `bondy_oplog_crdt_index_entry.erl` — the `index_entry` CRDT
  (apply ≡ merge LWW keyed by the primary HLC;
  `value_equals_state`).
- `bondy_oplog_secondary_writer.erl` + `bondy_oplog_secondary_sup.erl`
  — per-(NS, Index, Shard) async writer and its supervisor.
- `bondy_oplog_index_rebuild.erl` — serialised MST-replay rebuild /
  backfill orchestrator.
