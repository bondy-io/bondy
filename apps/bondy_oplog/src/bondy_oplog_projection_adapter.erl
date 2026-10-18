%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_projection_adapter).

-moduledoc #{format => "text/markdown"}.
-moduledoc """
Behaviour for **projection backings** — the persistent KV layer that
materialises folded cell values.

A projection adapter owns the persistent state of one
`(namespace, index, shard)` triple's keyspace. Each cell is stored as a
binary frame:

```
<<HlcLen:16, Hlc:HlcLen/binary, FoldedValueBytes/binary>>
```

## Bucket is a first-class call-time parameter

Every data callback takes a `Bucket :: term()` as its primary argument
alongside `Key`. The adapter maps `(Bucket, Key)` onto its native
keyspace exactly as leveled / Riak do — Bucket is the storage-layer
partition, not a sub-shard inside the handle.

This keeps a single `handle()` reusable across every Bucket inside the
shard. New Buckets do not require new handles, new registry entries, or
adapter `open/4` calls; they just appear on the wire when the caller
passes a new Bucket value to `get/3`, `put_batch/2`, `range/5`, or
`delete/3`.

## Required callbacks

- `open/4` — open the keyspace for an `(NS, Index, Shard)` triple.
  Returns a Bucket-agnostic handle threaded through all subsequent
  calls.
- `close/1` — release the handle.
- `get/3` — single-key read; returns the on-disk frame.
- `put_batch/2` — batched write. Each entry carries its own `Bucket`
  so a single batch can mix buckets when the caller wants to.
- `range/5` — single-shot range scan within one `Bucket`. Cross-bucket
  scans are the caller's responsibility (scatter and merge).
- `delete/3` — single-key delete inside a Bucket.
- `info/1` — implementation-specific introspection.

## Optional callbacks

- `head/4` — fast-path read that returns the substrate's HEAD wire
  format (`<<HlcLen:16, Hlc/binary, ValueBytes/binary>>`) without
  decoding the full V2 frame. `value_column` says whether the cell's
  kernel writes a value column (`bondy_oplog_cell_kernel:value_equals_state/1`
  is false); the adapter reads exactly the column that kernel writes, in
  one substrate call, so a cell being created under the read is either
  absent or whole (`bondy_db_projection_leveled_SUITE`). Adapters with a
  native HEAD mechanism implement it; adapters that don't omit the export
  and the substrate falls back to `get/3 +
  bondy_oplog_cell_frame:extract_head/1`.
- `clear/2` — bucket-scoped wipe of one index's cells, used by the
  secondary-index rebuild before a re-fold. Takes a `clear_scope()`
  descriptor (see the type) so the wipe stays scoped to the right index —
  and, on a backend that co-locates several tables in one keyspace
  (`shared_shards`, `single_bookie`), to the right **entity type** as well.
  Adapters that cannot wipe degrade gracefully (the rebuild re-puts every
  live term regardless; only orphaned terms would survive).
- `cell_keys/2` — enumerate every `{Bucket, Key}` primary cell in a
  `cell_keys_scope()` (`{entity, ET}` on a backend whose bucket carries the
  entity type, `all_primary` on a dedicated-Bookie backend). This is the
  **complete cell directory** the secondary-index rebuild, the origin reap and
  the stability sweep fold over: the projection holds every cell, whereas the
  MST is truncated by compaction and lists only the cells of the events it
  still holds. Every shipped adapter exports it; the MST walk remains only
  for an instance with no `cell_keys_scope()`, which `bondy_db` never opens.
  Probe it via `cell_keys_exported/1`.
- `sync/1` — make every write `put_batch/2` or `write_batch/3` has
  acknowledged durable. A
  durable adapter whose acknowledged writes can still be lost to a power
  failure exports it; call it through `sync/2`, which is `ok` for an adapter
  that does not. Exporting it is what makes an adapter durable
  (`is_durable/1`).
- `write_batch/3` — put several cells and delete several `{Bucket, Key}`
  cells in one atomic write. Call it through `write_batch/4`, which falls back
  to `put_batch/2` then one `delete/3` per cell for an adapter that does not
  export it.

Adapters MUST be safe under concurrent readers; `put_batch/2` may be
single-writer (the substrate guarantees one applier per shard).

## Lifecycle and owner-death

`close/1` is called on instance shutdown and on explicit shard
unregister. It is **not** called by the substrate when the registering
process dies — see `bondy_oplog_core_registry`'s "Owner DOWN cleanup"
section. Adapters that own external resources (file handles, durable
KV connections, sub-processes) MUST monitor their owning process
internally and release resources on owner death. The substrate does
not do it for them.

See `bondy_oplog_cache_adapter` for the orthogonal read-cache surface.
""".

-export_type([
    handle/0,
    bucket/0,
    range_opts/0,
    clear_scope/0,
    cell_keys_scope/0,
    cell_keys_opts/0
]).

-export([cell_keys_exported/1]).
-export([cell_keys_page_exported/1]).
-export([sync/2]).
-export([is_durable/1]).
-export([write_batch/4]).

-type handle() :: any().
-type bucket() :: term().
-type range_opts() :: #{
    limit => pos_integer(),
    atom() => term()
}.

%% The scope of a `clear/2` index wipe, chosen by the owner (`bondy_db`) from
%% the backend's keyspace layout. `{suffix, IndexName}` wipes every bucket
%% ending with `bondy_oplog_index_key:bucket_suffix(IndexName)`; correct on a
%% backend whose handle holds a single logical table (`per_entity`, the ETS
%% adapter), where the only buckets present are this table's.
%% `{entity, EntityType, IndexName}` wipes only the index buckets of
%% `EntityType`; required on a backend whose handle co-locates several entity
%% types (`shared_shards`, `single_bookie`), where a suffix wipe hits siblings.
-type clear_scope() ::
    {suffix, IndexName :: atom()}
    | {entity, EntityType :: binary(), IndexName :: atom()}.

%% The scope of a `cell_keys/2` primary-cell enumeration, used by the
%% secondary-index rebuild to derive its complete cell directory from the
%% durable projection; the owner (`bondy_db`) chooses it from the backend's
%% keyspace layout. `{entity, EntityType}` enumerates only the primary buckets
%% of `EntityType`; required on a backend whose handle co-locates several
%% entity types. `all_primary` enumerates every non-index bucket in the handle;
%% correct on a dedicated single-table Bookie with realm-keyed primary buckets
%% (`per_entity`), where the only buckets present are this table's.
-type cell_keys_scope() ::
    {entity, EntityType :: binary()}
    | all_primary.

%% One page of a `cell_keys/3` enumeration: at most `limit` cells (default
%% `infinity`), strictly after `cursor` (default `undefined`, the start) in
%% the scope's `{Bucket, Key}` term order.
-type cell_keys_opts() :: #{
    cursor => undefined | {bucket(), Key :: term()},
    limit => pos_integer() | infinity
}.

%% =============================================================================
%% BEHAVIOUR CALLBACKS
%% =============================================================================

-callback open(
    Namespace :: atom(),
    Index :: atom(),
    Shard :: non_neg_integer(),
    Opts :: map()
) -> {ok, handle()} | {error, term()}.

-callback close(handle()) -> ok.

-callback get(handle(), bucket(), Key :: term()) ->
    {ok, Frame :: binary()} | not_found.

-callback put_batch(
    handle(),
    [{bucket(), Key :: term(), Frame :: binary()}]
) -> ok | {error, term()}.

-callback range(
    handle(),
    bucket(),
    Low :: term(),
    %% `infinity` is the open-ended upper bound (every key `>= Low`); no
    %% finite key exceeds it. Every adapter must handle it — it backs the
    %% `index_get`/`index_range` primary-scan fallback. Mirrors
    %% `bondy_oplog_core:range_spec()`.
    High :: term() | infinity,
    Opts :: range_opts()
) ->
    {ok, [{Key :: term(), Frame :: binary()}]}
    | {error, term()}.

-callback delete(handle(), bucket(), Key :: term()) -> ok.

-callback info(handle()) -> #{atom() => term()}.

-type head_opts() :: #{value_column := boolean()}.

-export_type([head_opts/0]).

-callback head(handle(), bucket(), Key :: term(), Opts :: head_opts()) ->
    {ok, HeadBytes :: binary()} | not_found.

%% Wipe an index's cells from the handle's keyspace, used by the secondary-index
%% rebuild before a re-fold to drop orphaned terms. `Scope` is a `clear_scope()`
%% descriptor — see that type for which backend needs which form. Optional: the
%% rebuild guards the call with `function_exported(Adapter, clear, 2)` and
%% degrades to live-term re-puts when absent.
-callback clear(handle(), Scope :: clear_scope()) -> ok.

%% Enumerate every `{Bucket, Key}` primary cell in `Scope` — the COMPLETE cell
%% directory the secondary-index rebuild, the origin reap and the stability
%% sweep fold over. `Scope` is a `cell_keys_scope()`; see that type for which
%% backend needs which form. Deriving the directory from the MST instead misses
%% every cell whose events compaction has truncated: an index half-built and
%% marked trusted, or a departed node's cells that no reap can reach
%% (`CellContextReap.tla`, `DirectoryComplete`). Probe with
%% `cell_keys_exported/1`.
-callback cell_keys(handle(), Scope :: cell_keys_scope()) ->
    [{bucket(), Key :: term()}].

%% A page of `cell_keys/2`, so a caller that walks the directory with a
%% rising cursor (`bondy_oplog_cell_utils:member_cells/5`) pays for the page,
%% not for the prefix it has already swept. The page is a slice of the sorted
%% `cell_keys/2` result cut strictly after `cursor` and to `limit`
%% (`bondy_oplog_projection_ets_proper_test`,
%% `prop_cell_keys_page_is_a_slice_of_the_directory`). Probe with
%% `cell_keys_page_exported/1`.
-callback cell_keys(
    handle(), Scope :: cell_keys_scope(), Opts :: cell_keys_opts()
) ->
    [{bucket(), Key :: term()}].

-callback sync(handle()) -> ok | {error, term()}.

-callback write_batch(
    handle(),
    Puts :: [{bucket(), Key :: term(), Frame :: binary()}],
    Deletes :: [{bucket(), Key :: term()}]
) -> ok | {error, term()}.

-optional_callbacks([
    head/4, clear/2, cell_keys/2, cell_keys/3, sync/1, write_batch/3
]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Whether `Adapter` implements the optional `cell_keys/2` callback.

This is the single decision point for the cell directory source
(`bondy_oplog_cell_utils:primary_cell_directory/4`): an adapter that exports
`cell_keys/2` enumerates the complete projection directory; one that does not
falls back to the truncatable MST walk. `bondy_db` asserts the predicate at
durable-table open so an adapter missing the callback fails loudly instead of
silently building empty indexes on the next rebuild.
""".
-spec cell_keys_exported(Adapter :: module()) -> boolean().

cell_keys_exported(Adapter) when is_atom(Adapter) ->
    _ = code:ensure_loaded(Adapter),
    erlang:function_exported(Adapter, cell_keys, 2).

-doc """
Whether `Adapter` implements the optional paged `cell_keys/3` callback, the
decision point for whether a bounded sweep seeks to its cursor or
re-enumerates the directory and drops the prefix
(`bondy_oplog_cell_utils:member_cells/5`).
""".
-spec cell_keys_page_exported(Adapter :: module()) -> boolean().

cell_keys_page_exported(Adapter) when is_atom(Adapter) ->
    _ = code:ensure_loaded(Adapter),
    erlang:function_exported(Adapter, cell_keys, 3).

-doc """
Makes every write `put_batch/2` or `write_batch/3` has acknowledged on
`Handle` durable, through
`Adapter`'s optional `sync/1`. `ok` when `Adapter` does not export it.
""".
-spec sync(Adapter :: module(), handle()) -> ok | {error, term()}.

sync(Adapter, Handle) when is_atom(Adapter) ->
    _ = code:ensure_loaded(Adapter),
    case erlang:function_exported(Adapter, sync, 1) of
        true -> Adapter:sync(Handle);
        false -> ok
    end.

-doc """
Whether `Adapter`'s writes outlive the process that made them: it exports the
optional `sync/1`. The in-RAM ETS adapter does not.
""".
-spec is_durable(Adapter :: module()) -> boolean().

is_durable(Adapter) when is_atom(Adapter) ->
    _ = code:ensure_loaded(Adapter),
    erlang:function_exported(Adapter, sync, 1).

-doc """
Writes every cell of `Puts` and deletes every `{Bucket, Key}` cell of
`Deletes` on `Handle` in one write, through `Adapter`'s optional
`write_batch/3`. When `Adapter` does not export it, the puts go in one
`put_batch/2` and the deletes follow one `delete/3` per cell, so a crash may
keep the puts without the deletes.
""".
-spec write_batch(
    Adapter :: module(),
    handle(),
    [{bucket(), term(), binary()}],
    [{bucket(), term()}]
) -> ok | {error, term()}.

write_batch(_Adapter, _Handle, [], []) ->
    ok;
write_batch(Adapter, Handle, Puts, Deletes) when is_atom(Adapter) ->
    _ = code:ensure_loaded(Adapter),
    case erlang:function_exported(Adapter, write_batch, 3) of
        true ->
            Adapter:write_batch(Handle, Puts, Deletes);
        false ->
            maybe
                ok ?= Adapter:put_batch(Handle, Puts),
                lists:foreach(
                    fun({B, K}) -> ok = Adapter:delete(Handle, B, K) end,
                    Deletes
                )
            end
    end.
