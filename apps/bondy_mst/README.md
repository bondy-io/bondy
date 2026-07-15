# bondy_mst

An Erlang/OTP library for **Merkle Search Trees (MSTs)** and the
**coordination-free, state-based CRDTs** you build on them.

A *Merkle Search Tree* is a balanced search tree whose shape is fixed by the
*content* of its items rather than their insertion order. Two replicas that
hold the same set of items build the **same tree**, with the **same root
hash** — so peers reconcile by exchanging only the pages that differ, never
the full state. This is *anti-entropy in O(diff)*, not O(set size), and it is
the one property that makes large replicated stores converge without
consensus.

The construction is from Alex Auvolat & François Taïani's 2019 paper
[*Merkle Search Trees: Efficient State-Based CRDTs in Open
Networks*](https://inria.hal.science/hal-02303490/document) (SRDS 2019, Inria
HAL-02303490). This Erlang implementation is ported from the authors'
[reference Elixir prototype](https://gitlab.inria.fr/aauvolat/mst_exp) and
extended with multiple storage backends, configurable garbage collection,
deletion, and a durable packfile store.

## What this library gives you

| Layer | Module | What it is |
|---|---|---|
| **The tree** | `bondy_mst` | The Merkle Search Tree data structure: insert, read, merge, diff, truncate, GC. A *state-based CRDT* in itself — `merge/2` is the join. |
| **The CRDT** | `bondy_mst_crdt` | A state-based CRDT *built on* the tree — a grow-only set, an LWW key-value register store, or a nested map — with background, non-blocking anti-entropy and a pluggable transport. |
| **Storage** | `bondy_mst_store` | The page-store behaviour. Three backends ship: in-memory `map` and `ets`, and the durable, content-addressed `pack_store`. |
| **Operations** | `bondy_mst_admin` | Cold backup and restore of a durable tree, with a SHA-256 manifest and verification. |

This library is the **primitive**. If you want a ready-made replicated
*datastore* — typed tables, a CRDT catalogue, a durable write-ahead log,
compaction, and replication schedulers — use **`bondy_oplog`** (the
write/replication framework) and **`bondy_db`** (the consumer-facing database
facade), which are built on this library and live in the
[Bondy umbrella](https://github.com/bondy-io/bondy).

---

## Table of contents

- [When to use this library](#when-to-use-this-library)
- [How an MST converges](#how-an-mst-converges)
- [Quick start — the tree](#quick-start--the-tree)
- [Quick start — the CRDT](#quick-start--the-crdt)
- [API surface](#api-surface)
- [Storage backends](#storage-backends)
- [Backup and restore](#backup-and-restore)
- [Architecture documentation](#architecture-documentation)
- [Installation](#installation)
- [Credits](#credits)
- [License](#license)

---

## When to use this library

Reach for `bondy_mst` directly when you need:

- **A content-addressed, history-independent set or map** whose root hash is a
  cryptographic summary of its contents — for integrity verification, or as
  the substrate of a replicated value.
- **Bandwidth-proportional anti-entropy** — two replicas converge by
  exchanging only the differing pages, found in a logarithmic number of hash
  comparisons.
- **A state-based CRDT you drive yourself** — `bondy_mst_crdt` gives you the
  convergence logic (grow-only set, LWW register store, or map) and leaves the
  process model and transport to you (a `gen_server`, a `gen_statem`, a
  Partisan process — your choice).

Do **not** use it when you need strong consistency, linearizable writes, or
read-your-writes across replicas. Those require consensus; this library trades
them for availability and partition tolerance.

And if you want the whole datastore rather than the primitive — durable
tables, a typed CRDT catalogue, a WAL, compaction, and replication schedulers
out of the box — use `bondy_oplog` and `bondy_db` in the Bondy umbrella. They
are built on exactly this library.

---

## How an MST converges

Three properties do all the work:

1. **The tree is balanced by hash, not by insertion order.** Each item's layer
   is decided by hashing its key, so two replicas inserting the same items —
   in any order — assign the same layers and draw the same page boundaries.
   Same items ⇒ same tree ⇒ same root hash.

2. **Every page is content-addressed.** A page's address *is* the hash of its
   contents, including the hashes of its children. Two pages with the same hash
   are bit-identical and have identical subtrees beneath them.

3. **Reconciliation is a parallel tree walk that prunes matching subtrees.** To
   converge, peer A asks peer B for its root hash. Equal? Done. Different? A
   descends, fetching only the pages whose hashes it does not already hold.
   For 10⁶ items differing in 10, an MST exchange ships those 10 plus a
   logarithmic number of internal pages — not 10⁶.

The merge of two trees is the CRDT **join**: commutative, associative, and
idempotent. `merge(A, B)` and `merge(B, A)` produce the same tree and the same
root.

> For the full treatment — the page anatomy, the on-disk pack format, the
> anti-entropy protocol, truncation, and GC — read
> [`doc_extras/architecture/02_bondy_mst.md`](doc_extras/architecture/02_bondy_mst.md).

---

## Quick start — the tree

```erlang
%% A tree over an in-memory ETS store. The `merger` resolves a key
%% collision during put/merge — it IS the per-key conflict resolution.
T0 = bondy_mst:new(#{
    store          => bondy_mst_ets_store,
    store_opts     => #{name => <<"users">>},
    hash_algorithm => sha256,
    merger         => fun(_Key, _V1, V2) -> V2 end  %% last-writer-wins
}),

T1 = bondy_mst:put(T0, <<"alice">>, <<"Alice">>),
T2 = bondy_mst:put(T1, <<"bob">>,   <<"Bob">>),

<<"Alice">>  = bondy_mst:get(T2, <<"alice">>),
RootHash     = bondy_mst:root(T2).
```

For bulk inserts prefer `put_batch/2` — it builds a small volatile tree from
the batch and merges it in a single traversal, rebuilding the spine once
instead of once per item:

```erlang
T = bondy_mst:put_batch(T0, [
    {<<"k1">>, <<"v1">>},
    {<<"k2">>, <<"v2">>},
    {<<"k3">>, <<"v3">>}
]).
```

### Converging two trees

```erlang
%% A and B independently received different writes.
A1 = bondy_mst:put(A0, <<"x">>, <<"1">>),
B1 = bondy_mst:put(B0, <<"y">>, <<"2">>),

%% If you hold both trees locally, merge directly:
Merged = bondy_mst:merge(A1, B1),   %% contains x and y; same as merge(B1, A1)

%% Over a network, ship only the difference:
Missing = bondy_mst:missing_set(A1, bondy_mst:root(B1)),  %% page hashes A lacks
%% ... fetch those pages from B, then `bondy_mst:put_page/2` each into A,
%%     or `bondy_mst:merge/3` against B's root.
```

`missing_set/2` is the heart of anti-entropy: given a peer's root hash it
returns only the page hashes this tree is missing, pruning every subtree the
two already share.

---

## Quick start — the CRDT

`bondy_mst_crdt` wraps the tree as a state-based CRDT and adds the
**background anti-entropy logic** — buffering a peer's incoming root, fetching
the missing pages, and merging once they are all local, without blocking local
writes. You choose the value type to choose the CRDT:

- a **boolean** value → a **grow-only set**;
- an **LWW register** (value + version) → a **last-writer-wins key-value store**;
- another **CRDT** value → a **map CRDT** with efficient differing-item detection.

You own the process and the transport. The CRDT calls back into a module you
supply (`send/2`, `broadcast/1`, `on_merge/1`) to move messages; you feed
inbound messages to `handle/2`. It supports **causal** consistency (full state
sync per gossip — the default) and **eventual** consistency (gossip individual
operations, sync periodically).

```erlang
%% Create a replica. `NodeId` is this replica's identity; `Opts` carries the
%% tree options above plus your callback module.
C0 = bondy_mst_crdt:new(NodeId, Opts),

%% Local write — returns the updated CRDT and broadcasts a gossip if the root
%% changed.
C1 = bondy_mst_crdt:put(C0, <<"alice">>, true),

%% Inbound sync messages (gossip / get / put / missing) are handled here.
C2 = bondy_mst_crdt:handle(C1, Message),

bondy_mst_crdt:root(C2).
```

The message protocol (which messages may be handled concurrently, the gossip /
get / put / missing exchange, and the `send`/`broadcast`/`on_merge` callback
contract) is documented in full on the `bondy_mst_crdt` module page. Wire it
into a `gen_server`, a `gen_statem`, or a Partisan process — the library is
deliberately agnostic to the process infrastructure.

---

## API surface

The authoritative reference is the generated module documentation (`bondy
docs` / `rebar3 ex_doc`). The public functions of `bondy_mst`, grouped by
task:

**Build and update**
`new/0,1` · `put/2,3` · `put_batch/2` · `put_page/2` · `delete/2` ·
`truncate/2`

**Read and iterate**
`get/2,3` · `first/1` · `last/1` · `last_n/3` · `keys/1` · `to_list/1,2` ·
`fold/3,4` · `fold_pages/4` · `foreach/2,3` · `root/1` · `capabilities/1`

**Anti-entropy and merge**
`root/1` · `missing_set/2` · `merge/2,3` · `diff_to_list/2`

**Maintenance and storage**
`gc/1,2` · `store/1` · `set_store/2` · `dump/1` · `destroy/1`

**Durability and sealing**
`flush/1` · `close/1` · `maybe_roll_for_seal/1` · `run_seal_job/1` ·
`seal_job_pack_id/1` · `complete_seal/2` · `seal_in_flight/1`

`flush/1` persists the root at a commit barrier (pages before root); on a
durable pack store the `maybe_roll_for_seal/1` → `run_seal_job/1` →
`complete_seal/2` handshake moves the pack-seal rewrite off the caller's
critical path (a no-op on in-memory backends — see `capabilities/1`).

`diff_to_list/2` is a *read-only* structural diff — it descends both roots and
surfaces the differing entries without mutating either tree. `truncate/2`
physically removes every entry at or below a watermark (it is **not** a
tombstone), so truncated keys never reappear in a later `missing_set/2` result.

---

## Storage backends

`bondy_mst_store` is the behaviour every backend implements — a small,
page-level key-value contract (`open`, `close`, `get_root`/`set_root`, `get`,
`put`, `has`, `delete`, `copy`, `free`, `gc`, `missing_set`, `page_refs`,
`list`, `destroy`, plus the optional `flush`, `transaction`, `capabilities`,
and the async-seal callbacks `maybe_roll_for_seal`/`complete_seal`/`seal_in_flight`).
GC is **mark-from-root**: keep only
pages reachable from the live roots, drop the rest. Three backends ship:

| Backend | Module | Persistent? | Use it for |
|---|---|---|---|
| In-memory map | `bondy_mst_map_store` | No (process state) | Tiny embedded use; single writer; `free/3` deletes immediately. The default. |
| ETS | `bondy_mst_ets_store` | No (RAM) | Tests and ephemeral trees. Read-concurrent. |
| Pack store | `bondy_mst_pack_store` | **Yes** | Production. Durable content-addressed packfiles. |

Select a backend by passing its **module** as the `store` option to
`bondy_mst:new/1`, with any backend-specific settings under `store_opts`;
`new/1` opens the store for you. The default is `bondy_mst_map_store`.

### The durable pack store

`bondy_mst_pack_store` is the production backend: an **append-only,
content-addressed packfile format** — git's object database, scoped to MST
pages. Each instance owns a directory with an atomically-swapped `manifest`, a
mutable `incoming.pack`, and sealed immutable `pack-NNNN.pack` files each with
a companion `.idx` (sorted hashes + a 256-way fanout table + a bloom filter).
Reads are a bloom probe, a fanout lookup, and a couple of `pread`s; sealed
packs are immutable, which is what makes concurrent GC and crash recovery
safe. `incoming.pack` auto-seals once it crosses a record or byte threshold
(`auto_seal_records`, default 10 000; `auto_seal_bytes`, default 16 MB).

```erlang
T = bondy_mst:new(#{
    store          => bondy_mst_pack_store,
    store_opts     => #{
        dir         => <<"/var/lib/bondy_mst/users">>,
        instance_id => <<"users">>
    },
    hash_algorithm => sha256
}).
```

The pack store is **single-writer**: its file handles are owned by the calling
process and cannot be shared, so serialise all mutations through one owner
process (typically a `gen_server` above it). Unlike the in-memory backends,
which cannot fail at I/O, the pack store raises `error({Op, Reason})` on
unrecoverable disk failures — the owning process is expected to restart and
recover from the manifest.

> The on-disk format, the seal pipeline, and the recovery path are documented
> in [`doc_extras/architecture/02_bondy_mst.md`](doc_extras/architecture/02_bondy_mst.md)
> and in each `bondy_mst_pack_*` module's own page.

---

## Backup and restore

`bondy_mst_admin` is the **cold-backup** primitive for a durable tree. It
assumes no writer is active against the source directory; the recommended
sequence stops the writer, backs up, and restarts:

```erlang
{ok, Manifest} = bondy_mst_admin:backup(StoragePath, BackupDir),
ok             = bondy_mst_admin:verify(BackupDir),
{ok, _}        = bondy_mst_admin:restore(BackupDir, StoragePath).
```

`backup/2,3` copies the storage tree byte-for-byte and writes a `manifest.etf`
recording every file's size and SHA-256; `verify/1` re-hashes every file
against the manifest; `restore/2,3` verifies before copying. All three emit
`[bondy_mst, admin, …]` telemetry. For zero-downtime backups, take a
filesystem-level snapshot (LVM, ZFS, btrfs, EBS) of the storage path and hand
that to `backup/3` for the manifest and checksum step.

> Operator runbook:
> [`doc_extras/architecture/08_backup_and_restore.md`](doc_extras/architecture/08_backup_and_restore.md).

---

## Architecture documentation

Two chapters ship with this library:

| Doc | Topic |
|---|---|
| [02 — bondy_mst](doc_extras/architecture/02_bondy_mst.md) | The Merkle Search Tree, the pack-store on-disk format, and the anti-entropy protocol. |
| [08 — Backup & restore](doc_extras/architecture/08_backup_and_restore.md) | Operator runbook for `bondy_mst_admin`. |

The remaining chapters of the storage architecture — the layered overview, the
`bondy_oplog` write side, the `bondy_db` facade, the applier, the CRDT
catalogue, compaction, and the app developer's tour — describe the layers
*built on* this library and ship in the
[Bondy umbrella](https://github.com/bondy-io/bondy) alongside the
`bondy_oplog`/`bondy_db` apps. The original MST and Canteen papers are under
[`reference/`](reference/).

These chapters render alongside the module reference in the ex_doc output
(`rebar3 ex_doc`). They are the authoritative architecture reference; the
module docs carry the implementation-level contracts.

---

## Installation

### Requirements

- **Erlang/OTP 27+** — the source uses triple-quoted string literals and the
  `-doc`/`-moduledoc` attributes.

### As a dependency

`bondy_mst` is vendored in the Bondy umbrella as `apps/bondy_mst`. Consume it
via a rebar3 `git_subdir` dependency:

```erlang
{deps, [
    {bondy_mst,
        {git_subdir, "https://github.com/bondy-io/bondy.git",
            {branch, "main"}, "apps/bondy_mst"}}
]}.
```

### Application start

`bondy_mst` is a **pure library**: it has no long-lived processes of its own.
Its application start
(`application:ensure_all_started(bondy_mst)`) only initialises the library's
configuration defaults — it brings up no registries, schedulers, or
responders. The tree API (`bondy_mst:new/1` and friends) is usable directly;
start the application when you want the configured defaults to apply. The
replication framework that *does* run processes — `bondy_oplog` — is booted
separately in the Bondy umbrella.

---

## Credits

This library is a direct realization of:

- **Alex Auvolat** and **François Taïani** (Univ. Rennes, Inria, IRISA, CNRS),
  *"Merkle Search Trees: Efficient State-Based CRDTs in Open Networks"*,
  **SRDS 2019** —
  [Inria HAL-02303490](https://inria.hal.science/hal-02303490/document) ·
  [reference Elixir prototype](https://gitlab.inria.fr/aauvolat/mst_exp). The
  MST construction and the state-based-CRDT framing (`bondy_mst` and
  `bondy_mst_crdt`) come from this work.

The `bondy_oplog` layer that builds an operation-log datastore on top of this
primitive draws on Preston McCrary's *Canteen* (UC Berkeley, 2022) for its
Concurrent Operation Group abstraction; that lineage is credited in the Bondy
umbrella alongside `bondy_oplog`.

Any errors in this library's interpretation or adaptation of the above work are
ours, not theirs.

---

## License

Apache License 2.0. See [LICENSE](LICENSE).
