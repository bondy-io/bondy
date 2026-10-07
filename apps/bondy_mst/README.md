# bondy_mst

An Erlang/OTP library for **Merkle Search Trees (MSTs)**, their page stores,
and the anti-entropy exchange that keeps replicas of a tree in step.

A *Merkle Search Tree* is a search tree whose shape depends on the *content*
of its items, not on the order of insertion. Two replicas that hold the same
set of items build the same tree, with the same root hash. Peers therefore
reconcile by exchanging only the pages that one of them lacks. The pages
that cross the network follow the size of the difference, not the size of
the set.

The construction is from Alex Auvolat and François Taïani,
[*Merkle Search Trees: Efficient State-Based CRDTs in Open
Networks*](https://inria.hal.science/hal-02303490/document) (SRDS 2019, Inria
HAL-02303490). This Erlang implementation is ported from the authors'
[reference Elixir prototype](https://gitlab.inria.fr/aauvolat/mst_exp). It
adds several storage backends, reachability-based garbage collection,
structural deletion, truncation, and a durable packfile store.

## What this library gives you

| Layer | Module | What it is |
|---|---|---|
| **The tree** | `bondy_mst` | The Merkle Search Tree: insert, read, merge, diff, truncate, garbage collection. |
| **Replication** | `bondy_mst_crdt`, `bondy_mst_exchange` | A replicated tree with gossip and background anti-entropy over a transport that you supply. |
| **Storage** | `bondy_mst_store` | The page-store behaviour. Three backends ship: the in-memory `bondy_mst_map_store` and `bondy_mst_ets_store`, and the durable `bondy_mst_pack_store`. |
| **Operations** | `bondy_mst_admin` | Cold backup and restore of a storage directory, with a SHA-256 manifest and verification. |

This library is the primitive. The operation-log datastore of the
[Bondy umbrella](https://github.com/bondy-io/bondy) is built on it:
`bondy_oplog` is the write and replication framework, and `bondy_db` is the
database facade. Use them when you want typed tables, a write-ahead log,
compaction and replication schedulers.

---

## Table of contents

- [When to use this library](#when-to-use-this-library)
- [How an MST converges](#how-an-mst-converges)
- [Quick start: the tree](#quick-start-the-tree)
- [Quick start: replication](#quick-start-replication)
- [API surface](#api-surface)
- [Storage backends](#storage-backends)
- [Backup and restore](#backup-and-restore)
- [Architecture documentation](#architecture-documentation)
- [Installation](#installation)
- [Credits](#credits)
- [License](#license)

---

## When to use this library

Use `bondy_mst` directly when you need one of these:

- **A content-addressed, history-independent set or map.** Its root hash
  summarises its contents, for integrity checks or as the basis of a
  replicated value.
- **Anti-entropy that transfers what differs.** A replica requests only the
  pages that it does not hold, starting from the root hash of a peer.
- **Replication that you drive yourself.** `bondy_mst_crdt` holds the
  replication logic and leaves the process model and the transport to you: a
  `gen_server`, a `gen_statem`, or a Partisan process.

Do not use it when you need linearisable writes or read-your-writes across
replicas. Those need consensus, and this library does not provide it.

---

## How an MST converges

Three properties do the work.

1. **The hash of the key decides the layer of an item.** The layer is the
   number of leading zero 4-bit nibbles in the hash of the key. Two replicas
   that insert the same items, in any order, assign the same layers and draw
   the same page boundaries. `truncate_matches_delete_and_fresh_test_` in
   `bondy_mst_truncate_test` checks this for its inputs: a tree built from
   shuffled insertions has the same root as a tree built in order from the
   same keys.

2. **Every page is content-addressed.** The address of a page is the hash of
   its level, its left child hash and its entries. Each entry carries a key, a
   value and the hash of its right child. Two pages with the same hash
   therefore hold the same entries and reference the same subtrees.

3. **Reconciliation requests only absent pages.** Peer A compares its root
   hash with the root hash of peer B. When they are equal, A stops. When they
   differ, A requests the pages under B's root that its store does not hold.

`bondy_mst:merge/2` adds every entry of the second tree to the first. When
both trees hold the same key, the `merger` function of the receiving tree
decides the resulting value.

> The page anatomy, the on-disk pack format, the anti-entropy exchange,
> truncation and garbage collection are in
> [`doc_extras/architecture/02_bondy_mst.md`](doc_extras/architecture/02_bondy_mst.md).

---

## Quick start: the tree

```erlang
%% A tree over an ETS store. The `merger` decides the value when a key
%% is already present.
T0 = bondy_mst:new(#{
    store          => bondy_mst_ets_store,
    store_opts     => #{name => <<"users">>},
    hash_algorithm => sha256,
    merger         => fun(_Key, _Old, New) -> New end
}),

T1 = bondy_mst:put(T0, <<"alice">>, <<"Alice">>),
T2 = bondy_mst:put(T1, <<"bob">>,   <<"Bob">>),

<<"Alice">> = bondy_mst:get(T2, <<"alice">>),
RootHash    = bondy_mst:root(T2).
```

`bondy_mst_ets_store` requires the `name` option, a binary.

Without options, `bondy_mst:new/0` uses `bondy_mst_map_store`, `sha256`, the
standard term order as comparator, and a merger that accepts only the value
`true`. That configuration is a set: `bondy_mst:put/2` inserts a key with the
value `true`.

For bulk inserts, use `put_batch/2`. It builds the canonical pages of the
batch directly, then merges them into the tree in one traversal.
`prop_bulk_equals_sequential` in `bondy_mst_put_batch_bulk_test` checks that
the result has the same root as a sequence of `put/3` calls.

```erlang
T = bondy_mst:put_batch(T0, [
    {<<"k1">>, <<"v1">>},
    {<<"k2">>, <<"v2">>},
    {<<"k3">>, <<"v3">>}
]).
```

### Converging two trees

```erlang
A1 = bondy_mst:put(A0, <<"x">>, <<"1">>),
B1 = bondy_mst:put(B0, <<"y">>, <<"2">>),

%% With both trees in the same process, merge directly.
Merged = bondy_mst:merge(A1, B1),

%% Across a network, find the pages of B's tree that A does not hold.
Missing = bondy_mst:missing_set(A1, bondy_mst:root(B1)).
%% Fetch those pages from B and store each one with put_page/2. When every
%% page is local, merge B's root from A's own store:
%%   A2 = bondy_mst:merge(A1, A1, BRoot).
```

`missing_set/2` takes the root hash of a peer. It walks the pages under that
root that the local store holds, and returns the hashes that the store cannot
find. It cannot descend below an absent page, because the children of that
page are unknown until the page arrives. A caller therefore repeats the
fetch-and-check cycle until the missing set is empty.

---

## Quick start: replication

`bondy_mst_crdt` wraps a tree and adds gossip and background anti-entropy. It
holds an incoming peer root, requests the missing pages, and merges only when
every page is local. Local writes continue while pages are in flight. The page
exchange itself is in `bondy_mst_exchange`.

The value type and the `merger` decide the reconciliation rule:

- a **boolean** value gives a grow-only set;
- a **last-writer-wins register** (a value and a version) gives a
  last-writer-wins key-value store;
- a value with its own merge function gives a map of those values.

You own the process and the transport. The module calls back into a module
that you supply (`send/2`, `broadcast/1`, and the optional `on_merge/1`) to
move messages. You give inbound messages to `handle/2`. The
`consistency_model` option selects one of two modes:

- `causal` (the default): every gossip from a peer starts a full sync with
  that peer.
- `eventual`: peers gossip single operations and apply them on receipt. Full
  syncs run only when you call `trigger/2`.

```erlang
%% `NodeId` is the identity of this replica. `Opts` holds the tree options
%% and `callback_mod`.
C0 = bondy_mst_crdt:new(NodeId, Opts),

%% A local write. When the root changes, the module broadcasts a gossip.
C1 = bondy_mst_crdt:put(C0, <<"alice">>, true),

%% Inbound gossip and page-exchange messages.
C2 = bondy_mst_crdt:handle(C1, Message),

bondy_mst_crdt:root(C2).
```

The module page of `bondy_mst_crdt` documents the message protocol, the
messages that you can handle concurrently, and the callback contract.

---

## API surface

The generated module documentation (`rebar3 ex_doc`) is the reference. The
public functions of `bondy_mst`, grouped by task:

**Build and update**
`new/0,1` · `put/2,3` · `put_batch/2` · `put_page/2` · `delete/2` ·
`truncate/2`

**Read and iterate**
`get/2,3` · `first/1` · `last/1` · `last_n/3` · `keys/1` · `to_list/1,2` ·
`fold/3,4` · `fold_pages/4` · `foreach/2,3` · `root/1`

**Anti-entropy and merge**
`missing_set/2` · `merge/2,3` · `diff_to_list/2`

**Maintenance and storage**
`gc/1,2` · `store/1` · `set_store/2` · `capabilities/1` · `dump/1` ·
`close/1` · `destroy/1`

**Durability and sealing**
`flush/1` · `maybe_roll_for_seal/1` · `run_seal_job/1` ·
`seal_job_pack_id/1` · `complete_seal/2` · `seal_in_flight/1`

**Diagnostics**
`gc_aborts/0` · `forget_gc_aborts/0` · `recent_swept/0` · `forget_swept/0` ·
`verify_default/0`

`fold/4` reads two options:

- `{root, Hash}` folds the tree under `Hash` instead of the current root.
- `{missing, skip | throw}` sets what the fold does at a page that the store
  does not hold. `skip`, the default, folds past the page. `throw` throws
  `{missing_page, Hash}`.

The `fold_opt()` type also lists `first`, `stop`, `match_spec`, `keys_only`
and `limit`. `fold/4` ignores them. `fold_pages/4` reads `root` only and
always skips a missing page.

`flush/1` makes the staged root durable. On the pack store it makes the pages
durable before it writes the root. On the in-memory backends it does nothing.
The `maybe_roll_for_seal/1`, `run_seal_job/1` and `complete_seal/2` sequence
moves the pack-seal rewrite off the calling process. It does nothing on the
in-memory backends; the `async_seal` key of `capabilities/1` tells you which
case applies.

`diff_to_list/2` is a read-only structural diff. It descends both roots, skips
the subtrees they share, and returns the entries that differ. It changes
neither tree.

`truncate/2` removes every key that is less than or equal to a watermark. It
removes the entries from the tree; it does not write tombstones. The pages
that only the removed keys used stay in the store until garbage collection
reclaims them.

`gc/2` keeps every page reachable from the current root and from the roots
that you pass, and lets the backend drop the rest. When a page under the
current root is missing, `gc/2` sweeps nothing and records a report that
`gc_aborts/0` returns (`gc_aborts_on_unservable_root_test` in
`bondy_mst_gc_guard_test`). The caller has to serialise `gc/2` with every
writer of the tree, or pass every root that a writer can publish.

---

## Storage backends

`bondy_mst_store` is the behaviour that every backend implements. It is a
page-level key-value contract:

- required callbacks: `open`, `close`, `get_root`, `set_root`, `get`, `has`,
  `put`, `delete`, `copy`, `free`, `gc`, `list`, `missing_set`, `page_refs`,
  `destroy`;
- optional callbacks: `flush`, `transaction`, `capabilities`, `name`,
  `page_state`, `maybe_roll_for_seal`, `complete_seal`, `seal_in_flight`.

| Backend | Module | Durable | `free/3` | Use it for |
|---|---|---|---|---|
| In-memory map | `bondy_mst_map_store` | No | Removes the page. | Small trees owned by one process. The default. |
| ETS | `bondy_mst_ets_store` | No | Marks the page; `gc/2` reclaims it. | Tests and ephemeral trees. Concurrent reads and writes. |
| Pack store | `bondy_mst_pack_store` | Yes | Records a tombstone; `gc/2` reclaims by reachability. | Durable trees. |

Select a backend with the `store` option of `bondy_mst:new/1`, and put its
settings under `store_opts`. `new/1` opens the store.

### The durable pack store

`bondy_mst_pack_store` keeps pages in append-only, content-addressed
packfiles, in the manner of the git object database. Each store owns a
directory that holds:

- `manifest`, replaced atomically, which names the sealed packs and the
  current root;
- `incoming.pack`, the mutable file that new pages append to;
- sealed, immutable `pack-NNNN.pack` files, each with a `pack-NNNN.idx` that
  holds a bloom filter, a 256-entry fanout table and the sorted hashes;
- `tombstones`, the set of hashes that `free/3` marked.

A read of a sealed page probes the in-memory index of each sealed pack, then
reads the record with two `pread` calls. When `incoming.pack` reaches
`auto_seal_records` records (default `10_000`) or `auto_seal_bytes` bytes
(default `16_000_000`), the store seals it into a new sealed pack.

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

`dir` and `instance_id` are required. The pack store supports `sha256` only.

The pack store has a single writer. It reads sealed packs through raw file
descriptors that belong to the process that opened the store, and its
`capabilities/1` reports `process_bound_reads => true`. Send every operation
through the owning process, typically a `gen_server`. When a disk operation
fails, the pack store raises `error({Op, Reason})`. The owning process then
restarts and reopens the store from its manifest.

> The on-disk format, the seal pipeline and recovery are in
> [`doc_extras/architecture/02_bondy_mst.md`](doc_extras/architecture/02_bondy_mst.md)
> and in the module pages of `bondy_mst_pack_*`.

---

## Backup and restore

`bondy_mst_admin` is a cold-backup tool. No writer may be active on the source
directory while it runs:

```erlang
{ok, Manifest} = bondy_mst_admin:backup(StoragePath, BackupDir),
{ok, Manifest} = bondy_mst_admin:verify(BackupDir),
{ok, _}        = bondy_mst_admin:restore(BackupDir, StoragePath).
```

- `backup/2,3` copies every regular file under the source directory and
  writes `manifest.etf`, which records the size and SHA-256 of each file.
- `verify/1` hashes every file again and compares it with the manifest.
- `restore/2,3` calls `verify/1` and copies nothing when verification fails.

All three emit `[bondy_mst, admin, ...]` telemetry events. For a backup
without downtime, take a filesystem snapshot (LVM, ZFS, btrfs, EBS) of the
storage path and give the snapshot to `backup/2,3`.

> Operator runbook:
> [`doc_extras/architecture/08_backup_and_restore.md`](doc_extras/architecture/08_backup_and_restore.md).

---

## Architecture documentation

| Doc | Topic |
|---|---|
| [bondy_mst: the Merkle Search Tree](doc_extras/architecture/02_bondy_mst.md) | The tree, the pack-store format, sealing, truncation, garbage collection and anti-entropy. |
| [Backup and restore](doc_extras/architecture/08_backup_and_restore.md) | Operator runbook for `bondy_mst_admin`. |

The layers built on this library are described in the
[Bondy umbrella](https://github.com/bondy-io/bondy), under
`apps/bondy_db/doc_extras/architecture/`. The MST and Canteen papers are under
[`reference/`](reference/).

These chapters render with the module reference in the ex_doc output
(`rebar3 ex_doc`). The module docs hold the contract of each function.

---

## Installation

### Requirements

- **Erlang/OTP 27 or later.** The source uses triple-quoted strings and the
  `-doc` and `-moduledoc` attributes.

### As a dependency

`bondy_mst` lives in the Bondy umbrella as `apps/bondy_mst`. Add it with a
rebar3 `git_subdir` dependency:

```erlang
{deps, [
    {bondy_mst,
        {git_subdir, "https://github.com/bondy-io/bondy.git",
            {branch, "develop"}, "apps/bondy_mst"}}
]}.
```

### Application start

`application:ensure_all_started(bondy_mst)` starts a supervisor with no
children and initialises the library configuration. The tree API
(`bondy_mst:new/1` and the rest) does not need the application to run.

---

## Credits

This library implements:

- **Alex Auvolat** and **François Taïani** (Univ. Rennes, Inria, IRISA, CNRS),
  *"Merkle Search Trees: Efficient State-Based CRDTs in Open Networks"*,
  **SRDS 2019**:
  [Inria HAL-02303490](https://inria.hal.science/hal-02303490/document) ·
  [reference Elixir prototype](https://gitlab.inria.fr/aauvolat/mst_exp). The
  MST construction in `bondy_mst` and the replication scheme in
  `bondy_mst_crdt` come from this work.

The `bondy_oplog` layer built on this library draws on Preston McCrary's
*Canteen* (UC Berkeley, 2022) for its Concurrent Operation Group abstraction.
The Bondy umbrella credits that work with `bondy_oplog`.

Any errors in this library's interpretation or adaptation of the above work are
ours, not theirs.

---

## License

Apache License 2.0. See [LICENSE](LICENSE).
