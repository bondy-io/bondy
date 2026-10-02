%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_cache_adapter).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Behaviour for **read caches** — the hot-cell layer in front of the
projection.

A cache adapter holds decoded `{Value, Hlc}` tuples keyed by the cell's
substrate key. The substrate is cache-agnostic — implementations can use
ETS, ARC, an LRU library, a rotating-segment TTL cache, or any other
scheme with bounded memory.

The substrate places only minimal demands on the implementation:

- **`get` / `ticket` / `fill` / `delete` semantics as specified.**
- **Concurrent access safety.** Many readers fill the cache; any process
  that writes the projection may invalidate it.
- **Bounded memory.** The adapter owns its eviction policy (LRU / LFU /
  TTL / ARC — the substrate does not care). A degenerate adapter that
  never evicts is permitted but will grow without bound.

## Required callbacks

- `init/4` — open the cache for one `(NS, Index, Shard)` triple. Called
  once at instance startup; returns a handle.
- `close/1` — release the handle and any resources it owns. Called on
  instance shutdown and on shard unregister.
- `get/3` — return the cached `{Value, Hlc}` or `not_found`.
- `ticket/1` — taken by a reader on a miss, before it reads the
  projection.
- `fill/5` — insert the value that read produced, under its ticket.
- `delete/3` — invalidate one key. Called after every projection write.
- `invalidate_all/1` — invalidate every key. Used after bulk projection
  changes (compaction, schema migration).
- `info/1` — implementation-specific introspection (hit/miss counts,
  size, etc.).

## Cache coherence model

The cache is filled on read and invalidated on write: every process
that writes a projection cell calls `delete/3` (or `invalidate_all/1`)
after the write. A reader's projection read can still race that
invalidation and fill the older value after it. An adapter MUST
therefore make `fill/5` leave nothing behind, once it returns, when an
invalidation began after its ticket was taken.

The reference adapter (`bondy_oplog_cache_ets`) counts invalidations in
a generation it advances before removing rows, and re-reads it after
inserting, deleting its own row if it moved. `ReadCache.tla` in
`proofs/tla/` checks this protocol (`SettledCoherent`), and
`bondy_db_read_cache_race_test` forces the race. A cache hit concurrent
with such a fill may return the older value until that `fill/5` returns.

## Lifecycle and owner-death

`close/1` is called on instance shutdown and on explicit shard
unregister. It is **not** called by the substrate when the registering
process dies — see `bondy_oplog_core_registry`'s "Owner DOWN cleanup"
section. ETS-based adapters can rely on Erlang's ETS GC for cleanup;
adapters that own external resources (file handles, sub-processes,
connection pools) MUST monitor their owning process internally and
release resources on owner death. The substrate does not do it for
them.

See `bondy_oplog_projection_adapter` for the persistent-state surface.
""").

-export_type([
    handle/0,
    bucket/0
]).

-type handle() :: any().
-type bucket() :: term().

%% =============================================================================
%% BEHAVIOUR CALLBACKS
%% =============================================================================

%% Bucket is a first-class call-time parameter on every data callback —
%% the same dimension the projection adapter exposes. Implementations
%% typically use a composite ETS key (`{Bucket, Key}`) so a single
%% per-shard cache table serves every bucket inside the shard.

-callback init(
    Namespace :: atom(),
    Index :: atom(),
    Shard :: non_neg_integer(),
    Opts :: map()
) -> {ok, handle()} | {error, term()}.

-callback close(handle()) -> ok.

-callback get(handle(), bucket(), Key :: term()) ->
    {ok, {Value :: term(), Hlc :: bondy_hlc:hlc()}} | not_found.

-callback ticket(handle()) -> Ticket :: term().

-callback fill(
    handle(),
    bucket(),
    Key :: term(),
    {Value :: term(), Hlc :: bondy_hlc:hlc()},
    Ticket :: term()
) -> ok.

-callback delete(handle(), bucket(), Key :: term()) -> ok.

-callback invalidate_all(handle()) -> ok.

-callback info(handle()) -> #{atom() => term()}.
