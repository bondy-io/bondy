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

- **`get` / `put` / `delete` semantics as specified.**
- **Concurrent access safety.** Many readers, one or many writers; the
  substrate guarantees the writer for any given key is the namespace's
  writer process for that shard.
- **Bounded memory.** The adapter owns its eviction policy (LRU / LFU /
  TTL / ARC — the substrate does not care). A degenerate adapter that
  never evicts is permitted but will grow without bound.
- **Optional TTL or rotation-based safety ceiling.** Any caller may
  request `invalidate_all/1` (e.g., after a bulk projection rewrite); the
  adapter MUST honour it.

## Required callbacks

- `init/4` — open the cache for one `(NS, Index, Shard)` triple. Called
  once at instance startup; returns a handle.
- `close/1` — release the handle and any resources it owns. Called on
  instance shutdown and on shard unregister.
- `get/2` — return the cached `{Value, Hlc}` or `not_found`.
- `put/3` — insert/overwrite. The substrate writes through this on each
  accepted event whose key is already cached (cold keys are populated on
  read).
- `delete/2` — explicit invalidation for a specific key. Used by the
  applier when the projection rejects an event the writer pre-folded.
- `invalidate_all/1` — flush the cache. Used after bulk projection
  changes (compaction, schema migration).
- `info/1` — implementation-specific introspection (hit/miss counts,
  size, etc.).

## Cache coherence model

The substrate keeps the cache coherent without explicit invalidation in
the normal write path: the writer applies the event to the existing
cached value (if any) before publishing it, and the applier writes the
same folded value to the projection. Explicit `delete/2` is reserved for
the divergence case (`{conflict, _}` from the applier).

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
    {ok, {Value :: term(), Hlc :: bondy_oplog_hlc:hlc()}} | not_found.

-callback put(
    handle(),
    bucket(),
    Key :: term(),
    {Value :: term(), Hlc :: bondy_oplog_hlc:hlc()}
) -> ok.

-callback delete(handle(), bucket(), Key :: term()) -> ok.

-callback invalidate_all(handle()) -> ok.

-callback info(handle()) -> #{atom() => term()}.
