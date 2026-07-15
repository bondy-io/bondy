%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_core).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Read-side substrate primitive.

Composes a projection adapter (any persistent KV implementing
`bondy_oplog_projection_adapter`), a cache adapter (any read cache
implementing `bondy_oplog_cache_adapter`), and an optional overlay
(`bondy_oplog_db_overlay`) into a single read API parameterised by
the namespace's fold strategy.

## Address dimensions

Cells are addressed by **four** dimensions:

- **NS** — a config-group identifier; the registry maps `(NS, Index, Shard)`
  to `{fold_module, shard_count, projection_adapter, cache_adapter, ...}`.
  NS does not appear in the data itself; it is purely routing/config.
- **Index** — `primary` for the cell store, or one of the secondary
  indexes (different projections of the same events).
- **Bucket** — the storage-layer partition (leveled/Riak-native). Bucket
  is a call-time parameter; many buckets share one `(NS, Index, Shard)`
  registry entry. Adding or removing a bucket is data-plane work, not
  registry work.
- **Key** — the cell identifier inside `(Bucket)`.

Shard is derived as `phash2({Bucket, Key}, shard_count(NS, Index))`
(Riak-style composite hashing) so a single bucket spreads evenly across
the NS's shards.

## Read path

1. **Cache hit** — `Cache:get(Handle, Bucket, Key)` returns immediately.
2. **Cache miss** — read the projection cell, decode the frame,
   merge overlay events whose HLC is newer than the cell's HLC,
   apply the fold, populate the cache, return.

This module is read-only; writes flow through `bondy_oplog_instance`
and reach the projection via the applier. Writers can call
`write_through/5` after appending an event to keep the hot cache
coherent.

See `bondy_oplog_core_registry` for how shard handles are published. The
substrate does not own shard lifecycles — owners (writers, applier,
test setups) register the four-tuple `{cache_handle, projection_handle,
overlay, fold_module}` for each `(NS, Index, Shard)` they manage.
""").

-export([read/3]).
-export([read/4]).
-export([read/5]).
-export([read_batch/2]).
-export([read_state/3]).
-export([read_state/4]).
-export([range/4]).
-export([range/5]).
-export([range_all/4]).
-export([range_all/5]).
-export([read_at_hlc/3]).
-export([read_at_hlc/4]).
-export([write_through/4]).
-export([write_through/5]).
-export([shard_for/3]).
-export([shard_for/4]).
-export([ensure_fresh/2]).
-export([ensure_fresh_for_keys/2]).
-export([freshness/1]).
-export([subscribe/2]).
-export([unsubscribe/1]).
-export([publish/4]).
-export([publish_merge/4]).

-export_type([bucket/0]).
-export_type([read_opts/0]).
-export_type([read_result/0]).
-export_type([read_batch_opts/0]).
-export_type([read_batch_result/0]).
-export_type([batch_key/0]).
-export_type([consistency/0]).
-export_type([range_opts/0]).
-export_type([range_result/0]).
-export_type([range_spec/0]).

-type bucket() :: term().
-type read_opts() :: #{
    shard => non_neg_integer()
}.
-type read_result() ::
    {Value :: term(), Hlc :: bondy_oplog_hlc:hlc()}
    | undefined.

-type consistency() :: eventual | causal | snapshot.
-type batch_key() :: {atom(), atom(), bucket(), term()}.
-type read_batch_opts() :: #{
    fence => bondy_oplog_hlc:hlc(),
    max_lag => non_neg_integer() | infinity,
    require_skew_below => non_neg_integer(),
    consistency => consistency()
}.
-type read_batch_result() :: #{batch_key() := read_result()}.

-type range_spec() :: {Low :: term(), High :: term() | infinity}.
%% `High' may be the atom `infinity' for an open-ended scan (every key
%% greater than or equal to `Low' in the bucket). Used by the
%% secondary-index primary-scan fallback; supported by the ETS and
%% leveled projection adapters.
-type range_opts() :: #{
    limit => pos_integer(),
    direction => asc | desc,
    include_overlay => boolean(),
    fence => bondy_oplog_hlc:hlc() | infinity,
    shard => non_neg_integer()
}.
-type range_row() :: {
    Key :: term(), Value :: term(), Hlc :: bondy_oplog_hlc:hlc()
}.
-type range_result() :: [range_row()].

%% =============================================================================
%% API
%% =============================================================================

-doc """
Backward-compatible point read in the default `(NS, primary, '', Key)`
slot — `Bucket = <<>>` is the canonical empty bucket for single-tenant
consumers.

Prefer `read/4` (with explicit Bucket) for any multi-tenant or
multi-bucket setup.
""".
-spec read(
    Namespace :: atom(),
    Index :: atom(),
    Key :: term()
) -> read_result() | {error, term()}.

read(NS, Index, Key) ->
    read(NS, Index, <<>>, Key, #{}).

-spec read(
    Namespace :: atom(),
    Index :: atom(),
    Bucket :: bucket(),
    Key :: term()
) -> read_result() | {error, term()}.

read(NS, Index, Bucket, Key) ->
    read(NS, Index, Bucket, Key, #{}).

-doc """
Bucket-aware point read of a single cell.

The shard is selected by `phash2({Bucket, Key}, ShardCount)` unless the
caller passes `Opts#{shard => N}`. The override exists for `shard_by =>
realm` tables: their write hashes by `phash2(Realm, ShardCount)`, so the
point read MUST be forced onto the same realm-derived shard or it would
hash `{Bucket, Key}` to a different shard and silently miss. Symmetric
with `range/5`'s `shard` override.

## Opts

- `shard` — explicit shard override (default: hash of `{Bucket, Key}`).
""".
-spec read(
    Namespace :: atom(),
    Index :: atom(),
    Bucket :: bucket(),
    Key :: term(),
    Opts :: read_opts()
) -> read_result() | {error, term()}.

read(NS, Index, Bucket, Key, Opts) ->
    case resolve_shard(NS, Index, Bucket, Key, Opts) of
        {ok, Entry} ->
            {_NS, _Idx, Shard} = bondy_oplog_core_registry:entry_key(Entry),
            T0 = erlang:monotonic_time(microsecond),
            {Result, Source} = do_read_traced(Entry, Bucket, Key),
            DurUs = erlang:monotonic_time(microsecond) - T0,
            emit_read_event(
                NS, Index, Shard, Bucket, Entry, Source, DurUs, Result
            ),
            Result;
        {error, _} = Err ->
            Err
    end.

-doc """
Bootstrap-snapshot read. Returns the **raw fold state** (not the
user-facing value) for the cell, post-overlay-merge. Used by the
bootstrap-snapshot send path which forwards encoded state to a peer for
state-sync. Not part of the public `bondy_db`
API — consumers of substrate values must call `read/3..5`.

`undefined` when the cell does not exist and the overlay is empty.
""".
-spec read_state(atom(), atom(), term()) ->
    {State :: term(), bondy_oplog_hlc:hlc()} | undefined | {error, term()}.

read_state(NS, Index, Key) ->
    read_state(NS, Index, <<>>, Key).

-spec read_state(atom(), atom(), bucket(), term()) ->
    {State :: term(), bondy_oplog_hlc:hlc()} | undefined | {error, term()}.

read_state(NS, Index, Bucket, Key) ->
    case resolve_shard(NS, Index, Bucket, Key) of
        {ok, Entry} ->
            Kernel = kernel_for(Entry),
            {ProjState, ProjHlc, ProjHadFrame} =
                read_projection_state_with_hlc(Entry, Bucket, Key, Kernel),
            Overlay = read_overlay(Entry, Bucket, Key, ProjHlc),
            case {ProjHadFrame, Overlay} of
                {false, []} ->
                    undefined;
                _ ->
                    {NewState, NewHlc} =
                        bondy_oplog_cell_kernel:interpret_overlay(
                            Kernel, ProjState, ProjHlc, Overlay
                        ),
                    {NewState, NewHlc}
            end;
        {error, _} = Err ->
            Err
    end.

-doc """
Coalesced multi-cell read with optional fence and skew constraints.

`Reads` is a list of `{Namespace, Index, Bucket, Key}` four-tuples. The
result is a map keyed by the same four-tuple, mapping to the per-cell
`read_result()`.

See module doc for `Opts` semantics.
""".
-spec read_batch([batch_key()], read_batch_opts()) ->
    {ok, read_batch_result(), bondy_oplog_hlc:hlc()} | {error, term()}.

read_batch(Reads, Opts) when is_list(Reads), is_map(Opts) ->
    Consistency = maps:get(consistency, Opts, eventual),
    Fence = maps:get(fence, Opts, infinity),
    {EffectiveMaxLag, EffectiveSkew} = apply_consistency(Consistency, Opts),
    T0 = erlang:monotonic_time(microsecond),
    Result =
        case check_consistency_class(Reads, Consistency) of
            {error, _} = ClassErr ->
                ClassErr;
            ok ->
                case ensure_fresh_predicate_for_keys(Reads, EffectiveMaxLag) of
                    {error, _} = Err ->
                        Err;
                    ok ->
                        Results = compute_batch(Reads, Fence),
                        case check_skew(Results, EffectiveSkew) of
                            ok ->
                                {ok, Results, Fence};
                            {error, _} = SkewErr ->
                                SkewErr
                        end
                end
        end,
    DurUs = erlang:monotonic_time(microsecond) - T0,
    emit_read_batch_event(Reads, Fence, Result, DurUs),
    Result.

-doc """
Backward-compatible write-through in the default `<<>>` bucket slot.
Prefer `write_through/5` for any Bucket-aware setup.
""".
-spec write_through(
    Namespace :: atom(),
    Index :: atom(),
    Key :: term(),
    Event :: bondy_oplog_event:t()
) -> ok | {error, term()}.

write_through(NS, Index, Key, Event) ->
    write_through(NS, Index, <<>>, Key, Event).

-spec write_through(
    Namespace :: atom(),
    Index :: atom(),
    Bucket :: bucket(),
    Key :: term(),
    Event :: bondy_oplog_event:t()
) -> ok | {error, term()}.

write_through(NS, Index, Bucket, Key, Event) ->
    case resolve_shard(NS, Index, Bucket, Key) of
        {ok, Entry} ->
            do_write_through(Entry, Bucket, Key, Event);
        {error, _} = Err ->
            Err
    end.

-doc """
Shard selector. Hashes `{Bucket, Key}` (Riak-style) over the substrate's
shard count for `(NS, Index)`. Returns `{error, no_shards}` if no shards
are registered for the namespace.
""".
-spec shard_for(atom(), atom(), bucket(), term()) ->
    {ok, non_neg_integer()} | {error, no_shards}.

shard_for(NS, Index, Bucket, Key) ->
    case bondy_oplog_core_registry:shard_count(NS, Index) of
        {ok, Count} -> {ok, erlang:phash2({Bucket, Key}, Count)};
        not_found -> {error, no_shards}
    end.

-doc """
Backward-compatible shard selector for the default `<<>>` bucket.
Hashes `{<<>>, Key}` which is identical to the historical Key-only
behaviour modulo the constant prefix — kept so legacy callers that
never used Bucket still address the same shards.
""".
-spec shard_for(atom(), atom(), term()) ->
    {ok, non_neg_integer()} | {error, no_shards}.

shard_for(NS, Index, Key) ->
    shard_for(NS, Index, <<>>, Key).

-doc """
Backward-compatible range scan in the default `<<>>` bucket slot. See
`range/5` for the Bucket-aware version.
""".
-spec range(atom(), atom(), range_spec(), range_opts()) ->
    {ok, range_result()} | {error, term()}.

range(NS, Index, Spec, Opts) ->
    range(NS, Index, <<>>, Spec, Opts).

-doc """
Single-shard range scan over `[Low, High)` inside `Bucket`.

The shard is selected by `phash2({Bucket, Low}, ShardCount)` unless the
caller passes `Opts#{shard => N}`. Callers whose `[Low, High)` spans
more than one shard MUST scatter across shards themselves and merge
the results.

## Opts

- `limit` — max rows in the result (default `1000`).
- `direction` — `asc` (default) or `desc`.
- `include_overlay` — set `false` to exclude pending events (default `true`).
- `fence` — HLC ceiling for overlay events (default `infinity`).
- `shard` — explicit shard override.
""".
-spec range(atom(), atom(), bucket(), range_spec(), range_opts()) ->
    {ok, range_result()} | {error, term()}.

range(NS, Index, Bucket, {Low, High}, Opts) when is_map(Opts) ->
    case resolve_shard_for_range(NS, Index, Bucket, Low, Opts) of
        {ok, Entry} ->
            {_NS, _Idx, Shard} = bondy_oplog_core_registry:entry_key(Entry),
            T0 = erlang:monotonic_time(microsecond),
            Result = do_range(Entry, Bucket, Low, High, Opts),
            DurUs = erlang:monotonic_time(microsecond) - T0,
            emit_range_event(NS, Index, Shard, Bucket, Result, DurUs),
            Result;
        {error, _} = Err ->
            Err
    end.

-doc """
Backward-compatible cross-shard range over the default `<<>>` bucket
slot. See `range_all/5` for the Bucket-aware version.
""".
-spec range_all(atom(), atom(), range_spec(), range_opts()) ->
    {ok, range_result()} | {error, term()}.

range_all(NS, Index, Spec, Opts) ->
    range_all(NS, Index, <<>>, Spec, Opts).

-doc """
Cross-shard range scan over `[Low, High)` inside `Bucket`.

Scatters the range to every shard registered under `(NS, Index)`, runs
the single-shard `range/5` per shard with `Opts#{shard => Shard}`, then
merges the per-shard results into a single globally-sorted list.

## Opts

- `limit` — global cap on rows in the result (default `1000`). Applied
  after merge.
- `direction` — `asc` (default) or `desc`.
- `include_overlay` — set `false` to exclude pending events (default
  `true`). Propagated to every per-shard scan.
- `fence` — HLC ceiling for overlay events (default `infinity`).
  Propagated to every per-shard scan.

## Correctness of per-shard limit propagation

Per-shard calls pass the caller's `limit` verbatim. Because each shard's
result is already globally sorted on the shard, and the merged result
is bounded above by the union of the per-shard top-`Limit`s, every key
that would appear in the global top-`Limit` is present in at least one
per-shard top-`Limit`. Truncating the merged list to `Limit` is
therefore correct.

## Error semantics

If any shard returns `{error, _}` the call surfaces that error and
discards results from other shards. No partial results are returned.

If `(NS, Index)` has no registered shards the call returns `{ok, []}`.
""".
-spec range_all(atom(), atom(), bucket(), range_spec(), range_opts()) ->
    {ok, range_result()} | {error, term()}.

range_all(NS, Index, Bucket, {Low, High}, Opts) when
    is_atom(NS), is_atom(Index), is_map(Opts)
->
    Direction = maps:get(direction, Opts, asc),
    Limit = maps:get(limit, Opts, 1000),
    Shards = shards_in(NS, Index),
    T0 = erlang:monotonic_time(microsecond),
    Result = scatter_range(Shards, NS, Index, Bucket, Low, High, Opts),
    DurUs = erlang:monotonic_time(microsecond) - T0,
    case Result of
        {ok, Rows} ->
            Merged = merge_sorted_ranges(Rows, Direction),
            Truncated = lists:sublist(Merged, Limit),
            emit_range_all_event(
                NS,
                Index,
                Bucket,
                length(Shards),
                length(Truncated),
                DurUs
            ),
            {ok, Truncated};
        {error, _} = Err ->
            emit_range_all_error_event(
                NS, Index, Bucket, length(Shards), Err, DurUs
            ),
            Err
    end.

-doc """
Backward-compatible point-in-time read in the default `<<>>` bucket
slot. See `read_at_hlc/4` for the Bucket-aware version.
""".
-spec read_at_hlc(
    Namespace :: atom(),
    Key :: term(),
    T :: bondy_oplog_hlc:hlc()
) ->
    {ok, Value :: term(), Hlc :: bondy_oplog_hlc:hlc()}
    | {error, term()}.

read_at_hlc(NS, Key, T) ->
    read_at_hlc(NS, <<>>, Key, T).

-doc """
Point-in-time read against the primary index.

Returns the cell value as of HLC `T`. See module doc for the historical-
read semantics; the substrate refuses with
`{error, {historical_read_unavailable, ProjHlc, T}}` if the projection
has already advanced past `T`.
""".
-spec read_at_hlc(
    Namespace :: atom(),
    Bucket :: bucket(),
    Key :: term(),
    T :: bondy_oplog_hlc:hlc()
) ->
    {ok, Value :: term(), Hlc :: bondy_oplog_hlc:hlc()}
    | {error, term()}.

read_at_hlc(NS, Bucket, Key, T) when is_integer(T), T >= 0 ->
    T0 = erlang:monotonic_time(microsecond),
    Result =
        case resolve_shard(NS, primary, Bucket, Key) of
            {ok, Entry} ->
                do_read_at_hlc(Entry, Bucket, Key, T);
            {error, _} = Err ->
                Err
        end,
    DurUs = erlang:monotonic_time(microsecond) - T0,
    emit_read_at_hlc_event(NS, Result, DurUs),
    Result.

-doc """
Freshness predicate. Returns `ok` iff every PRIMARY shard of every
supplied namespace has had a `bump_ae/3` within `MaxLag` milliseconds of
"now" (a local commit or a successful AE round, per
`bondy_oplog_core_registry`). Secondary-index shards are excluded —
the auth fence reads primary-projection cells; index staleness is
governed by the `index_get` `max_lag` path.

`MaxLag = infinity` short-circuits to `ok` (fence disabled).
""".
-spec ensure_fresh([atom()], non_neg_integer() | infinity) ->
    ok | {stale, [atom()]}.

ensure_fresh(_NSs, infinity) ->
    ok;
ensure_fresh(NSs, MaxLag) when
    is_list(NSs), is_integer(MaxLag), MaxLag >= 0
->
    T0 = erlang:monotonic_time(microsecond),
    Now = erlang:monotonic_time(millisecond),
    Stale = lists:usort(
        [
            NS
         || NS <- NSs,
            Entry <- bondy_oplog_core_registry:primary_shards_for(NS),
            (Now -
                atomics:get(
                    bondy_oplog_core_registry:entry_ae_atomics(Entry), 1
                )) > MaxLag
        ]
    ),
    DurUs = erlang:monotonic_time(microsecond) - T0,
    emit_ensure_fresh_event(length(NSs), length(Stale), DurUs),
    case Stale of
        [] -> ok;
        _ -> {stale, Stale}
    end.

-doc """
Like `ensure_fresh/2` but only inspects the shards actually touched by
the supplied keys.
""".
-spec ensure_fresh_for_keys(
    [batch_key()],
    non_neg_integer() | infinity
) -> ok | {stale, [atom()]}.

ensure_fresh_for_keys(_Reads, infinity) ->
    ok;
ensure_fresh_for_keys(Reads, MaxLag) when
    is_list(Reads), is_integer(MaxLag), MaxLag >= 0
->
    T0 = erlang:monotonic_time(microsecond),
    Now = erlang:monotonic_time(millisecond),
    Touched = touched_shards(Reads),
    Stale = lists:usort(
        [
            NS
         || {NS, Ae} <- Touched,
            (Now - atomics:get(Ae, 1)) > MaxLag
        ]
    ),
    DurUs = erlang:monotonic_time(microsecond) - T0,
    emit_ensure_fresh_event(length(Touched), length(Stale), DurUs),
    case Stale of
        [] -> ok;
        _ -> {stale, Stale}
    end.

-doc """
Return per-shard freshness lag for the namespace as a map keyed by
`{Index, Shard}` with values in milliseconds.
""".
-spec freshness(atom()) ->
    #{{atom(), non_neg_integer()} := integer()}.

freshness(NS) when is_atom(NS) ->
    Now = erlang:monotonic_time(millisecond),
    maps:from_list(
        [
            begin
                {_NS, Index, Shard} = bondy_oplog_core_registry:entry_key(
                    Entry
                ),
                Ae = bondy_oplog_core_registry:entry_ae_atomics(Entry),
                {{Index, Shard}, Now - atomics:get(Ae, 1)}
            end
         || Entry <- bondy_oplog_core_registry:shards_for(NS)
        ]
    ).

-spec subscribe(atom(), bondy_oplog_core_dispatcher:pattern()) ->
    {ok, reference()}.

subscribe(NS, Pattern) ->
    bondy_oplog_core_dispatcher:subscribe(NS, Pattern).

-spec unsubscribe(reference()) -> ok.

unsubscribe(SubRef) ->
    bondy_oplog_core_dispatcher:unsubscribe(SubRef).

-spec publish(atom(), term(), bondy_oplog_hlc:hlc(), term()) -> ok.

publish(NS, Key, Hlc, Op) ->
    bondy_oplog_core_dispatcher:publish(NS, Key, Hlc, Op).

-doc """
Publish a remote-merge event. Fired by the replay path when anti-entropy merges
a peer's write into the local projection, so node-local reactors can react to
peer-originated changes. See `bondy_oplog_core_dispatcher:publish_merge/4`.
""".
-spec publish_merge(atom(), term(), bondy_oplog_hlc:hlc(), term()) -> ok.

publish_merge(NS, Key, Hlc, Op) ->
    bondy_oplog_core_dispatcher:publish_merge(NS, Key, Hlc, Op).

%% =============================================================================
%% Read path
%% =============================================================================

resolve_shard(NS, Index, Bucket, Key) ->
    case shard_for(NS, Index, Bucket, Key) of
        {ok, Shard} ->
            case bondy_oplog_core_registry:lookup(NS, Index, Shard) of
                {ok, Entry} -> {ok, Entry};
                not_found -> {error, shard_not_registered}
            end;
        {error, _} = Err ->
            Err
    end.

%% Point-read shard resolution honouring an explicit `shard` override
%% (symmetry with `resolve_shard_for_range/5`). A `shard_by => realm`
%% table forces the point read onto the realm-derived shard via
%% `Opts#{shard => N}` so write and read address the same shard; without
%% the override the shard is hashed from `{Bucket, Key}`.
resolve_shard(NS, Index, Bucket, Key, Opts) ->
    case maps:get(shard, Opts, undefined) of
        undefined ->
            resolve_shard(NS, Index, Bucket, Key);
        Shard when is_integer(Shard) ->
            registry_lookup(NS, Index, Shard)
    end.

%% The per-cell projection kernel for a shard: a configured `crdt_module`
%% selects the operation-based path, otherwise the `fold_module` drives
%% the legacy fold path. Every read helper projects/decodes/merges
%% through this kernel so a CRDT table's read path interprets the COG
%% (`interpret_cog`) and never folds events through `apply_event`.
kernel_for(Entry) ->
    Fold = bondy_oplog_core_registry:entry_fold_module(Entry),
    Crdt = bondy_oplog_core_registry:entry_crdt_module(Entry),
    bondy_oplog_cell_kernel:from_modules(Fold, Crdt).

do_read_traced(Entry, Bucket, Key) ->
    CA = bondy_oplog_core_registry:entry_cache_adapter(Entry),
    CH = bondy_oplog_core_registry:entry_cache_handle(Entry),
    case CA:get(CH, Bucket, Key) of
        {ok, {Value, Hlc}} ->
            {{Value, Hlc}, cache};
        not_found ->
            slow_read_traced(Entry, Bucket, Key)
    end.

slow_read_traced(Entry, Bucket, Key) ->
    Kernel = kernel_for(Entry),
    case read_projection_head(Entry, Bucket, Key) of
        not_found ->
            slow_read_no_projection(Entry, Bucket, Key, Kernel);
        {ok, ProjHlc, ValueBytes} ->
            slow_read_with_projection(
                Entry, Bucket, Key, Kernel, ProjHlc, ValueBytes
            )
    end.

slow_read_no_projection(Entry, Bucket, Key, Kernel) ->
    case read_overlay(Entry, Bucket, Key, 0) of
        [] ->
            {undefined, projection};
        Events ->
            InitState = bondy_oplog_cell_kernel:init(Kernel),
            {NewState, NewHlc} =
                bondy_oplog_cell_kernel:interpret_overlay(
                    Kernel, InitState, 0, Events
                ),
            finalise_slow_read(
                Entry,
                Bucket,
                Key,
                Kernel,
                NewState,
                NewHlc,
                overlay_only
            )
    end.

slow_read_with_projection(Entry, Bucket, Key, Kernel, ProjHlc, ValueBytes) ->
    case read_overlay(Entry, Bucket, Key, ProjHlc) of
        [] ->
            case
                bondy_oplog_cell_kernel:decode_value_bytes(Kernel, ValueBytes)
            of
                undefined ->
                    {undefined, projection};
                Value ->
                    cache_and_return(
                        Entry, Bucket, Key, Value, ProjHlc, projection
                    )
            end;
        Events ->
            %% Overlay events need the full state to apply incrementally.
            %% HEAD bytes alone don't carry enough — re-read the full frame.
            State = read_projection_state(Entry, Bucket, Key, Kernel),
            {NewState, NewHlc} =
                bondy_oplog_cell_kernel:interpret_overlay(
                    Kernel, State, ProjHlc, Events
                ),
            finalise_slow_read(
                Entry,
                Bucket,
                Key,
                Kernel,
                NewState,
                NewHlc,
                projection_with_overlay
            )
    end.

finalise_slow_read(Entry, Bucket, Key, Kernel, NewState, NewHlc, Source) ->
    case bondy_oplog_cell_kernel:to_value(Kernel, NewState) of
        undefined ->
            {undefined, Source};
        Value ->
            cache_and_return(Entry, Bucket, Key, Value, NewHlc, Source)
    end.

cache_and_return(Entry, Bucket, Key, Value, Hlc, Source) ->
    CA = bondy_oplog_core_registry:entry_cache_adapter(Entry),
    CH = bondy_oplog_core_registry:entry_cache_handle(Entry),
    ok = CA:put(CH, Bucket, Key, {Value, Hlc}),
    {{Value, Hlc}, Source}.

%% Fast-path projection read: returns `{ok, Hlc, ValueBytes}` via the
%% adapter's `head/3` callback when available, else falls back to
%% `get/3 + bondy_oplog_cell_frame:extract_head/1`.
read_projection_head(Entry, Bucket, Key) ->
    PA = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    PH = bondy_oplog_core_registry:entry_projection_handle(Entry),
    case erlang:function_exported(PA, head, 3) of
        true ->
            case PA:head(PH, Bucket, Key) of
                {ok, HeadBytes} ->
                    {Hlc, ValueBytes} =
                        bondy_oplog_cell_frame:decode_head(HeadBytes),
                    {ok, Hlc, ValueBytes};
                not_found ->
                    not_found
            end;
        false ->
            case PA:get(PH, Bucket, Key) of
                not_found ->
                    not_found;
                {ok, Frame} ->
                    HeadBytes = bondy_oplog_cell_frame:extract_head(Frame),
                    {Hlc, ValueBytes} =
                        bondy_oplog_cell_frame:decode_head(HeadBytes),
                    {ok, Hlc, ValueBytes}
            end
    end.

%% Slow-path projection read: returns the **decoded state** (not the
%% value). Used by the overlay-merge path, by `read_at_hlc/4`, and by
%% the bootstrap-snapshot send path via `read_state/3`.
read_projection_state(Entry, Bucket, Key, Kernel) ->
    PA = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    PH = bondy_oplog_core_registry:entry_projection_handle(Entry),
    case PA:get(PH, Bucket, Key) of
        not_found ->
            bondy_oplog_cell_kernel:init(Kernel);
        {ok, Frame} ->
            {_Hlc, StateBytes, _ValueBytes} =
                bondy_oplog_cell_frame:decode_full(Frame),
            bondy_oplog_cell_kernel:decode_state(Kernel, StateBytes)
    end.

%% Slow-path projection read with HLC: returns `{State, Hlc, HadFrame}`.
%% Used by paths that need both the state (for folding) and the HLC.
read_projection_state_with_hlc(Entry, Bucket, Key, Kernel) ->
    PA = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    PH = bondy_oplog_core_registry:entry_projection_handle(Entry),
    case PA:get(PH, Bucket, Key) of
        not_found ->
            {bondy_oplog_cell_kernel:init(Kernel), 0, false};
        {ok, Frame} ->
            {Hlc, StateBytes, _ValueBytes} =
                bondy_oplog_cell_frame:decode_full(Frame),
            {
                bondy_oplog_cell_kernel:decode_state(Kernel, StateBytes),
                Hlc,
                true
            }
    end.

read_overlay(Entry, Bucket, Key, AfterHlc) ->
    case bondy_oplog_core_registry:entry_overlay(Entry) of
        disabled -> [];
        Tab -> bondy_oplog_db_overlay:events_for(Tab, Bucket, Key, AfterHlc)
    end.

%% =============================================================================
%% Batch read path
%% =============================================================================

apply_consistency(eventual, Opts) ->
    {infinity, maps:get(require_skew_below, Opts, undefined)};
apply_consistency(causal, Opts) ->
    {
        maps:get(max_lag, Opts, infinity),
        maps:get(require_skew_below, Opts, undefined)
    };
apply_consistency(snapshot, Opts) ->
    MaxLag = maps:get(max_lag, Opts, infinity),
    Bound =
        case maps:get(require_skew_below, Opts, undefined) of
            undefined when is_integer(MaxLag) -> MaxLag div 2;
            undefined -> undefined;
            Explicit -> Explicit
        end,
    {MaxLag, Bound}.

ensure_fresh_predicate_for_keys(_Reads, infinity) ->
    ok;
ensure_fresh_predicate_for_keys(Reads, MaxLag) ->
    case ensure_fresh_for_keys(Reads, MaxLag) of
        ok -> ok;
        {stale, _} = Err -> {error, Err}
    end.

%% Dedup shards before per-shard registry lookups.
touched_shards(Reads) ->
    ShardSet = lists:foldl(
        fun({NS, Index, Bucket, Key}, Acc) ->
            case shard_for(NS, Index, Bucket, Key) of
                {ok, Shard} -> Acc#{{NS, Index, Shard} => []};
                {error, _} -> Acc
            end
        end,
        #{},
        Reads
    ),
    lists:foldl(
        fun({NS, Index, Shard}, Acc) ->
            case bondy_oplog_core_registry:lookup(NS, Index, Shard) of
                {ok, Entry} ->
                    Ae = bondy_oplog_core_registry:entry_ae_atomics(Entry),
                    [{NS, Ae} | Acc];
                not_found ->
                    Acc
            end
        end,
        [],
        maps:keys(ShardSet)
    ).

compute_batch(Reads, Fence) ->
    maps:from_list([
        {{NS, Idx, Bucket, Key}, read_at_fence(NS, Idx, Bucket, Key, Fence)}
     || {NS, Idx, Bucket, Key} <- Reads
    ]).

read_at_fence(NS, Index, Bucket, Key, Fence) ->
    case resolve_shard(NS, Index, Bucket, Key) of
        {ok, Entry} ->
            fenced_read(Entry, Bucket, Key, Fence);
        {error, _} = Err ->
            Err
    end.

fenced_read(Entry, Bucket, Key, Fence) ->
    Kernel = kernel_for(Entry),
    %% Batch reads always pay the full-state fetch since a fence may
    %% include overlay events; using the HEAD fast-path here would
    %% require a second trip on every overlay-present cell.
    {ProjState, ProjHlc, _ProjHadFrame} =
        read_projection_state_with_hlc(Entry, Bucket, Key, Kernel),
    OverlayEvents = fenced_overlay(Entry, Bucket, Key, ProjHlc, Fence),
    {NewState, NewHlc} =
        bondy_oplog_cell_kernel:interpret_overlay(
            Kernel, ProjState, ProjHlc, OverlayEvents
        ),
    case bondy_oplog_cell_kernel:to_value(Kernel, NewState) of
        undefined -> undefined;
        Value -> {Value, NewHlc}
    end.

fenced_overlay(Entry, Bucket, Key, AfterHlc, infinity) ->
    read_overlay(Entry, Bucket, Key, AfterHlc);
fenced_overlay(Entry, Bucket, Key, AfterHlc, Fence) ->
    case bondy_oplog_core_registry:entry_overlay(Entry) of
        disabled ->
            [];
        Tab ->
            bondy_oplog_db_overlay:events_for_window(
                Tab, Bucket, Key, AfterHlc, Fence
            )
    end.

check_skew(_Results, undefined) ->
    ok;
check_skew(_Results, infinity) ->
    ok;
check_skew(Results, Bound) when is_integer(Bound) ->
    Hlcs = collect_hlcs(maps:values(Results)),
    case Hlcs of
        [] ->
            ok;
        _ ->
            Physicals = [physical(H) || H <- Hlcs],
            Skew = lists:max(Physicals) - lists:min(Physicals),
            case Skew =< Bound of
                true -> ok;
                false -> {error, {skew_too_large, Skew, Bound}}
            end
    end.

collect_hlcs(Values) ->
    lists:foldl(
        fun
            ({_, Hlc}, Acc) when is_integer(Hlc) -> [Hlc | Acc];
            (_, Acc) -> Acc
        end,
        [],
        Values
    ).

physical(Hlc) ->
    {Phys, _Log} = bondy_oplog_hlc:decode(Hlc),
    Phys.

%% =============================================================================
%% Range
%% =============================================================================

resolve_shard_for_range(NS, Index, Bucket, Low, Opts) ->
    case maps:get(shard, Opts, undefined) of
        undefined ->
            case shard_for(NS, Index, Bucket, Low) of
                {ok, Shard} -> registry_lookup(NS, Index, Shard);
                {error, _} = Err -> Err
            end;
        Shard when is_integer(Shard) ->
            registry_lookup(NS, Index, Shard)
    end.

registry_lookup(NS, Index, Shard) ->
    case bondy_oplog_core_registry:lookup(NS, Index, Shard) of
        {ok, Entry} -> {ok, Entry};
        not_found -> {error, shard_not_registered}
    end.

do_range(Entry, Bucket, Low, High, Opts) ->
    Limit = maps:get(limit, Opts, 1000),
    Direction = maps:get(direction, Opts, asc),
    IncludeOverlay = maps:get(include_overlay, Opts, true),
    Fence = maps:get(fence, Opts, infinity),
    Kernel = kernel_for(Entry),
    PA = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    PH = bondy_oplog_core_registry:entry_projection_handle(Entry),

    case PA:range(PH, Bucket, Low, High, Opts) of
        {ok, ProjEntries} ->
            OverlayEntries = overlay_for_range(
                Entry, Bucket, Low, High, Fence, IncludeOverlay
            ),
            Merged = merge_range(Kernel, ProjEntries, OverlayEntries),
            Ordered =
                case Direction of
                    asc -> Merged;
                    desc -> lists:reverse(Merged)
                end,
            {ok, lists:sublist(Ordered, Limit)};
        {error, _} = Err ->
            Err
    end.

overlay_for_range(_Entry, _Bucket, _Low, _High, _Fence, false) ->
    [];
overlay_for_range(Entry, Bucket, Low, High, Fence, true) ->
    case bondy_oplog_core_registry:entry_overlay(Entry) of
        disabled ->
            [];
        Tab ->
            bondy_oplog_db_overlay:range_window(
                Tab, Bucket, Low, High, Fence
            )
    end.

merge_range(Kernel, ProjEntries, OverlayEntries) ->
    Init = maps:from_list([{K, {F, []}} || {K, F} <- ProjEntries]),
    Grouped = lists:foldl(
        fun({K, E}, M) ->
            case maps:get(K, M, undefined) of
                undefined -> M#{K => {undefined, [E]}};
                {Frame, Events} -> M#{K => {Frame, [E | Events]}}
            end
        end,
        Init,
        OverlayEntries
    ),
    Cells = lists:keysort(1, maps:to_list(Grouped)),
    lists:filtermap(
        fun({K, {Frame, Events}}) ->
            case emit_range_cell(Kernel, Frame, lists:reverse(Events)) of
                undefined -> false;
                {V, H} -> {true, {K, V, H}}
            end
        end,
        Cells
    ).

shards_in(NS, Index) ->
    [
        E
     || E <- bondy_oplog_core_registry:shards_for(NS),
        begin
            {_NS, Idx, _Sh} = bondy_oplog_core_registry:entry_key(E),
            Idx =:= Index
        end
    ].

scatter_range([], _NS, _Index, _Bucket, _Low, _High, _Opts) ->
    {ok, []};
scatter_range([Entry], NS, Index, Bucket, Low, High, Opts) ->
    %% Single shard — read inline, no spawn overhead.
    {_NS, _Idx, Shard} = bondy_oplog_core_registry:entry_key(Entry),
    case range(NS, Index, Bucket, {Low, High}, Opts#{shard => Shard}) of
        {ok, Rows} -> {ok, [Rows]};
        {error, _} = Err -> Err
    end;
scatter_range(Shards, NS, Index, Bucket, Low, High, Opts) ->
    %% Read every shard CONCURRENTLY. Each shard is an independent per-shard
    %% projection (its own leveled/ETS stack), so the reads do not contend with
    %% one another; a serial scatter made a realm-scoped range (e.g. a user list
    %% page) cost O(shards) sequential reads — the dominant latency once the
    %% per-user fan-out was removed. Results are key-merged afterwards, so the
    %% order in which shards complete is irrelevant.
    Tasks = [
        begin
            {_NS, _Idx, Shard} = bondy_oplog_core_registry:entry_key(Entry),
            spawn_monitor(fun() ->
                exit(
                    {scatter_result,
                        range(NS, Index, Bucket, {Low, High}, Opts#{
                            shard => Shard
                        })}
                )
            end)
        end
     || Entry <- Shards
    ],
    collect_scatter(Tasks, []).

%% @private
%% Gather one per-shard range result per spawned task. The task carries its
%% result in its exit reason, so each `DOWN` both delivers a result and frees
%% its monitor — no separate message or demonitor needed.
collect_scatter([], Acc) ->
    {ok, Acc};
collect_scatter([{_Pid, MRef} | Rest], Acc) ->
    receive
        {'DOWN', MRef, process, _, {scatter_result, {ok, Rows}}} ->
            collect_scatter(Rest, [Rows | Acc]);
        {'DOWN', MRef, process, _, {scatter_result, {error, _} = Err}} ->
            ok = drain_scatter(Rest),
            Err;
        {'DOWN', MRef, process, _, Reason} ->
            ok = drain_scatter(Rest),
            {error, {scatter_shard_crashed, Reason}}
    end.

%% @private
%% After an early error, wait out the remaining shard tasks so their `DOWN`
%% messages do not leak into the caller's mailbox.
drain_scatter([]) ->
    ok;
drain_scatter([{_Pid, MRef} | Rest]) ->
    receive
        {'DOWN', MRef, process, _, _} -> ok
    end,
    drain_scatter(Rest).

%% Multi-way merge of per-shard range results into a single globally
%% sorted list. Each input list is already sorted by Key for the
%% requested direction; shards partition the keyspace under
%% `phash2({Bucket, Key}, ShardCount)` so the union has no Key
%% collisions, and a flat sort over the concatenation is correct.
merge_sorted_ranges([], _Direction) ->
    [];
merge_sorted_ranges(PerShardRows, Direction) ->
    Flat = lists:append(PerShardRows),
    Comparator =
        case Direction of
            asc -> fun({K1, _, _}, {K2, _, _}) -> K1 =< K2 end;
            desc -> fun({K1, _, _}, {K2, _, _}) -> K1 >= K2 end
        end,
    lists:sort(Comparator, Flat).

emit_range_cell(Kernel, Frame, Events) ->
    {ProjState, ProjHlc} =
        case Frame of
            undefined ->
                {bondy_oplog_cell_kernel:init(Kernel), 0};
            Bin when is_binary(Bin) ->
                {H, StateBytes, _ValueBytes} =
                    bondy_oplog_cell_frame:decode_full(Bin),
                {bondy_oplog_cell_kernel:decode_state(Kernel, StateBytes), H}
        end,
    Applicable = [
        E
     || E <- Events,
        bondy_oplog_event:key_hlc(bondy_oplog_event:key(E)) > ProjHlc
    ],
    {NewState, NewHlc} =
        bondy_oplog_cell_kernel:interpret_overlay(
            Kernel, ProjState, ProjHlc, Applicable
        ),
    case bondy_oplog_cell_kernel:to_value(Kernel, NewState) of
        undefined -> undefined;
        Value -> {Value, NewHlc}
    end.

%% =============================================================================
%% Point-in-time read
%% =============================================================================

do_read_at_hlc(Entry, Bucket, Key, T) ->
    Kernel = kernel_for(Entry),
    {ProjState, ProjHlc, _ProjHadFrame} =
        read_projection_state_with_hlc(Entry, Bucket, Key, Kernel),
    case ProjHlc > T of
        true ->
            {error, {historical_read_unavailable, ProjHlc, T}};
        false ->
            OverlayEvents = fenced_overlay(Entry, Bucket, Key, ProjHlc, T),
            {NewState, NewHlc} =
                bondy_oplog_cell_kernel:interpret_overlay(
                    Kernel, ProjState, ProjHlc, OverlayEvents
                ),
            case bondy_oplog_cell_kernel:to_value(Kernel, NewState) of
                undefined ->
                    {ok,
                        bondy_oplog_cell_kernel:to_value(
                            Kernel, bondy_oplog_cell_kernel:init(Kernel)
                        ),
                        0};
                Value ->
                    {ok, Value, NewHlc}
            end
    end.

%% =============================================================================
%% Write-through
%% =============================================================================

check_consistency_class(_Reads, Consistency) when
    Consistency =/= eventual
->
    ok;
check_consistency_class(Reads, eventual) ->
    NSs = lists:usort([NS || {NS, _Idx, _B, _K} <- Reads]),
    case
        lists:dropwhile(
            fun(NS) ->
                bondy_oplog_core_registry:consistency_class(NS) =/= cp
            end,
            NSs
        )
    of
        [] -> ok;
        [CpNs | _] -> {error, {consistency_class_violation, CpNs, cp, eventual}}
    end.

do_write_through(Entry, Bucket, Key, _Event) ->
    %% The cache now stores the user-facing `Value` (post-`to_value/1`),
    %% not the fold state. Applying an event in-place would need the
    %% fold's `apply_value_delta/2` callback, which no current fold
    %% exports. Invalidate instead so the next read repopulates from
    %% the HEAD fast-path (which sees the writer's overlay event).
    CA = bondy_oplog_core_registry:entry_cache_adapter(Entry),
    CH = bondy_oplog_core_registry:entry_cache_handle(Entry),
    case CA:get(CH, Bucket, Key) of
        not_found -> ok;
        {ok, _} -> ok = CA:delete(CH, Bucket, Key)
    end.

%% =============================================================================
%% Telemetry
%% =============================================================================

emit_read_event(NS, Index, Shard, Bucket, Entry, Source, DurUs, Result) ->
    {Hit, ValueBytes} =
        case Result of
            {Value, _Hlc} when Value =/= undefined ->
                {Source =:= cache, erlang:external_size(Value)};
            _ ->
                {false, 0}
        end,
    Path = path_of_source(Source),
    Meta0 = #{
        namespace => NS,
        index => Index,
        shard => Shard,
        bucket => Bucket,
        source => Source,
        path => Path
    },
    Meta =
        case Path of
            head -> Meta0#{head_path => head_path_of(Entry)};
            _ -> Meta0
        end,
    telemetry:execute(
        [bondy_oplog_core, read],
        #{duration_us => DurUs, hit => Hit, value_bytes => ValueBytes},
        Meta
    ).

%% Normalise the read `Source` tag into a `path` classification used
%% by downstream telemetry handlers and tests:
%%   `none` — served from the value cache; no projection touched.
%%   `head` — HEAD-path read: HEAD bytes decoded directly (no slow
%%            `read_projection_state`).
%%   `slow` — full-state path: read `read_projection_state` because
%%            overlay events had to be folded in, or because the
%%            projection was missing and overlay had to drive the fold.
path_of_source(cache) -> none;
path_of_source(projection) -> head;
path_of_source(overlay_only) -> slow;
path_of_source(projection_with_overlay) -> slow;
path_of_source(_) -> unknown.

%% Tell whether the projection adapter served the read via its native
%% `head/3` callback (`native`) or whether the substrate fell back to
%% `get/3 + bondy_oplog_cell_frame:extract_head/1` (`fallback`). This
%% is the leveled fast-path indicator used by HEAD-path tests.
head_path_of(Entry) ->
    PA = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    case erlang:function_exported(PA, head, 3) of
        true -> native;
        false -> fallback
    end.

emit_read_batch_event(Reads, Fence, Result, DurUs) ->
    NSs = lists:usort([NS || {NS, _Idx, _B, _K} <- Reads]),
    {ReadCount, TotalBytes, SkewMs} = batch_summary(Result),
    telemetry:execute(
        [bondy_oplog_core, read_batch],
        #{
            duration_us => DurUs,
            read_count => ReadCount,
            total_bytes => TotalBytes,
            skew_ms => SkewMs
        },
        #{namespaces => NSs, fence_hlc => Fence}
    ).

batch_summary({ok, Results, _Fence}) ->
    Values = maps:values(Results),
    Bytes = lists:foldl(
        fun
            ({V, _H}, Acc) when V =/= undefined ->
                Acc + erlang:external_size(V);
            (_, Acc) ->
                Acc
        end,
        0,
        Values
    ),
    Hlcs = collect_hlcs(Values),
    Skew =
        case Hlcs of
            [] ->
                0;
            _ ->
                Phys = [physical(H) || H <- Hlcs],
                lists:max(Phys) - lists:min(Phys)
        end,
    {length(Values), Bytes, Skew};
batch_summary(_Err) ->
    {0, 0, 0}.

emit_range_event(NS, Index, Shard, Bucket, Result, DurUs) ->
    {Entries, Bytes} =
        case Result of
            {ok, Rows} ->
                B = lists:foldl(
                    fun({_K, V, _H}, Acc) -> Acc + erlang:external_size(V) end,
                    0,
                    Rows
                ),
                {length(Rows), B};
            _ ->
                {0, 0}
        end,
    telemetry:execute(
        [bondy_oplog_core, range],
        #{
            duration_us => DurUs,
            entries_returned => Entries,
            scanned_bytes => Bytes
        },
        #{
            namespace => NS,
            index => Index,
            shard => Shard,
            bucket => Bucket
        }
    ).

emit_range_all_event(NS, Index, Bucket, ShardCount, EntriesReturned, DurUs) ->
    telemetry:execute(
        [bondy_oplog_core, range_all],
        #{
            duration_us => DurUs,
            shards_scanned => ShardCount,
            entries_returned => EntriesReturned
        },
        #{namespace => NS, index => Index, bucket => Bucket}
    ).

emit_range_all_error_event(
    NS, Index, Bucket, ShardCount, {error, Reason}, DurUs
) ->
    telemetry:execute(
        [bondy_oplog_core, range_all],
        #{
            duration_us => DurUs,
            shards_scanned => ShardCount,
            entries_returned => 0
        },
        #{
            namespace => NS,
            index => Index,
            bucket => Bucket,
            refused => true,
            reason => Reason
        }
    ).

emit_read_at_hlc_event(NS, Result, DurUs) ->
    {Refused, Reason} =
        case Result of
            {ok, _, _} ->
                {false, undefined};
            {error, {historical_read_unavailable, _, _}} ->
                {true, historical_read_unavailable};
            {error, {Tag, _, _}} ->
                {true, Tag};
            {error, {Tag, _}} ->
                {true, Tag};
            {error, Tag} when is_atom(Tag) -> {true, Tag};
            {error, _} ->
                {true, unknown};
            _ ->
                {true, unknown}
        end,
    telemetry:execute(
        [bondy_oplog_core, read_at_hlc],
        #{duration_us => DurUs, refused => Refused},
        #{namespace => NS, refusal_reason => Reason}
    ).

emit_ensure_fresh_event(NSsChecked, StaleCount, DurUs) ->
    telemetry:execute(
        [bondy_oplog_core, ensure_fresh],
        #{
            duration_us => DurUs,
            namespaces_checked => NSsChecked,
            stale_count => StaleCount
        },
        #{}
    ).
