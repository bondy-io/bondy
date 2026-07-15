%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_oplog_cell_apply).
-moduledoc """
The per-shard projection-write engine, factored out of
`bondy_oplog_applier` so both the applier gen_server and the (ephemeral)
fused writer can drive cell projection writes through identical code.

Side-effect-only over a `cell_apply_ctx()` + instance id: it reads the
old cell value (in-batch shadow → A3 frame-cache → projection `get/3`),
applies the cell kernel, writes the new frames in one `put_batch`,
invalidates the read cache, advances the per-shard high-water HLC, and
dispatches secondary-index ops. It never touches the MST or any
gen_server state. Pure relocation of the applier's prior internals —
behaviour is byte-identical.
""".

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_MAX_INFLIGHT, 100000).

-type shard_key() :: {atom(), atom(), non_neg_integer()}.
-type cell_apply_ctx() :: #{
    shard_key := shard_key(),
    adapter := module(),
    handle := term(),
    fold_module := atom() | undefined,
    %% Namespace under which the replay path publishes remote-merge events
    %% (`bondy_oplog_core:publish_merge/4`) so node-local reactors can react to
    %% peer-originated changes. `undefined` (the default) disables emission —
    %% set only for tables opened with `publish => true`. Only the replay
    %% (`apply_cell_pairs/4`) path emits; local writes use the applier's
    %% `publish_batch`.
    publish_ns => atom() | undefined,
    %% Cache adapter pair captured at init time so the applier can
    %% keep the per-shard read cache coherent after every projection
    %% write. Without this, `bondy_db:apply/4` followed by `read/3` on
    %% a different process returns stale state — the cache is
    %% populate-on-miss and never invalidated by writers otherwise.
    cache_adapter => module() | undefined,
    cache_handle => term(),
    %% Per-shard high-water HLC mark. Advanced via
    %% `bondy_oplog_high_water:advance/2` after every successful
    %% projection write in `apply_one_cell/11`. `undefined` when the
    %% shard's registry entry has no ref (defensive only; new registrations
    %% always allocate).
    high_water_ref => bondy_oplog_high_water:ref() | undefined,
    %% Secondary indexes declared on this primary table. Static descriptors
    %% resolved once at init from the applier opts; `[]` (the default) makes
    %% the index
    %% dispatch a strict no-op for non-indexed tables. For each cell the
    %% applier materialises, it term-diffs the cell's old vs new value
    %% per descriptor and dispatches `index_entry` ops to the
    %% `bondy_oplog_secondary_writer` owning each touched secondary
    %% shard (resolved live via `bondy_oplog_core_registry`), so the writer
    %% need not exist when the applier starts.
    secondary_indexes => [index_descriptor()]
}.
-type index_descriptor() :: #{
    index_name := atom(),
    spec := bondy_oplog_index_spec:spec(),
    sec_shard_count := pos_integer(),
    %% Per-shard in-flight back-pressure cap; read by `dispatch_index_ops/4`.
    %% Defaults to `?DEFAULT_MAX_INFLIGHT` when absent.
    max_inflight => non_neg_integer()
}.
%% The cell-apply context multiplexer — a `bondy_oplog_mux:t()` whose key is the
%% event's `Bucket` (entity type) and whose value is that table's
%% `cell_apply_ctx()`. `{single, Ctx}` is the one-table-per-instance case (every
%% bucket resolves to the same ctx, byte-identical to the pre-mux path);
%% `{dir, Map}` is the per-shard multiplexer keyed by bucket. Consumed by both
%% the applier (durable + non-fused ephemeral) and the fused instance, which each
%% hold a `ctx_source()` and dispatch through `apply_cell_batch_mux/3` /
%% `apply_cell_pairs_mux/4`.
-type ctx_source() :: bondy_oplog_mux:t().

-export_type([cell_apply_ctx/0]).
-export_type([index_descriptor/0]).
-export_type([ctx_source/0]).

-export([apply_cell_batch/3]).
-export([apply_cell_batch_mux/3]).
-export([apply_cell_pairs/4]).
-export([apply_cell_pairs_mux/4]).
-export([build_source/2]).
-export([compute_one_cell/12]).
-export([oldstate_cache_new/2]).
-export([oldstate_cache_put_entries/2]).
-export([oldstate_cache_clear/1]).
-export([max_hlc/2]).
-export([sec_idx/1]).
-export([index_op/7]).
-export([merge_idx_ops/2]).
-export([dispatch_index_ops/4]).
-export([invalidate_cache/4]).
-export([advance_high_water/2]).

-ifdef(TEST).
%% A3 — exported for the bounded-eviction / hit-miss unit test.
-export([oldstate_cache_get/3]).
-endif.

%% =============================================================================
%% API
%% =============================================================================

%% @private
%% Apply a batch of `cell_apply` events to the projection. For each event,
%% read the cell's current frame from the projection (or the in-batch
%% shadow), decode to state via the fold's `decode_state/1`, fold the event in
%% via `apply_event/3`, encode back, and write the new frame via
%% `put_batch/2`. Bucket is a first-class call-time parameter on the
%% projection adapter; the applier passes it through verbatim.
apply_cell_batch(undefined, _Id, _Events) ->
    ok;
apply_cell_batch(_Ctx, _Id, []) ->
    ok;
apply_cell_batch(Ctx, Id, Events) ->
    #{adapter := Adapter, handle := Handle, kernel := Kernel} = Ctx,
    CacheAdapter = maps:get(cache_adapter, Ctx, undefined),
    CacheHandle = maps:get(cache_handle, Ctx, undefined),
    HighWaterRef = maps:get(high_water_ref, Ctx, undefined),
    OldStateCache = maps:get(oldstate_cache, Ctx, undefined),
    SecIdx = sec_idx(Ctx),

    %% Collect all per-event writes into a single `Adapter:put_batch/2` call.
    %%
    %% Correctness: when two events in the batch target the same
    %% `{Bucket, Key}`, the second must observe the first's write.
    %% We thread a `LocalWrites :: #{{Bucket, Key} => Frame}` shadow
    %% through the fold so the per-event read path checks the local
    %% map before falling back to `Adapter:get/3`. After the fold,
    %% we issue ONE `put_batch` with the deduped {Bucket, Key, Frame}
    %% list (last write wins per key — consistent with the previous
    %% sequential-per-key semantics).
    %%
    %% A third accumulator `IdxAcc :: #{{IndexName, SecShard} => [IndexOp]}`
    %% collects the secondary-index ops every cell yields (empty for
    %% non-indexed tables); they are dispatched to the secondary writers
    %% *after* the primary `put_batch` returns ok.
    {LocalWrites, MaxHlc, IdxAcc} = lists:foldl(
        fun(Event, {WAcc, HlcAcc, IAcc}) ->
            case bondy_oplog_event:op(Event) of
                {cell_apply, Bucket, Key, FoldEvent} ->
                    Meta = bondy_oplog_event:key(Event),
                    Context = bondy_oplog_event:meta(Event),
                    case
                        compute_one_cell(
                            Id,
                            Adapter,
                            Handle,
                            Kernel,
                            WAcc,
                            Bucket,
                            Key,
                            FoldEvent,
                            Meta,
                            Context,
                            SecIdx,
                            OldStateCache
                        )
                    of
                        {ok, NewFrame, NewHlc, IdxOps} ->
                            WAcc1 = WAcc#{{Bucket, Key} => NewFrame},
                            {
                                WAcc1,
                                max_hlc(HlcAcc, NewHlc),
                                merge_idx_ops(IAcc, IdxOps)
                            };
                        skip ->
                            {WAcc, HlcAcc, IAcc}
                    end;
                _ ->
                    {WAcc, HlcAcc, IAcc}
            end
        end,
        {#{}, undefined, #{}},
        Events
    ),

    case map_size(LocalWrites) of
        0 ->
            ok;
        _ ->
            PutT0 = erlang:monotonic_time(microsecond),
            Entries = [{B, K, F} || {{B, K}, F} <- maps:to_list(LocalWrites)],
            PutResult = Adapter:put_batch(Handle, Entries),
            telemetry:execute(
                [bondy_oplog, applier, batch_cell_put],
                #{
                    duration_us => erlang:monotonic_time(microsecond) - PutT0,
                    count => length(Entries)
                },
                #{instance_id => Id}
            ),
            case PutResult of
                ok ->
                    %% Cache invalidate per unique key (dedup via
                    %% the LocalWrites map's key set, not the Inval
                    %% list which may have duplicates).
                    maps:foreach(
                        fun({B, K}, _F) ->
                            invalidate_cache(CacheAdapter, CacheHandle, B, K)
                        end,
                        LocalWrites
                    ),
                    %% A3 — write-through the now-durable frames into the
                    %% applier's OldValue cache (no-op when disabled).
                    oldstate_cache_put_entries(OldStateCache, Entries),
                    case MaxHlc of
                        undefined -> ok;
                        _ -> advance_high_water(HighWaterRef, MaxHlc)
                    end,
                    %% Advance the applied-frontier version vector over this
                    %% batch's `{HLC, Origin, Seq}` keys (local/append path; the
                    %% replay/merge path does the same in `apply_cell_pairs/4`).
                    %% After the durable write, so the frontier never leads the
                    %% projection — the convergence oracle.
                    ok = bondy_oplog_registry:merge_frontier(
                        Id, batch_frontier_events(Events)
                    ),
                    %% Only after the primary write is durable do we let
                    %% the index see these terms. The live drain path
                    %% enforces the back-pressure cap (Bypass = false).
                    dispatch_index_ops(SecIdx, IdxAcc, MaxHlc, false);
                {error, Reason} ->
                    %% Primary write failed: do NOT dispatch index ops —
                    %% the cells (and their index entries) are re-applied
                    %% on the next replay of these events.
                    ?LOG_WARNING(#{
                        description =>
                            "bondy_oplog_applier projection batch write "
                            "failed; the cells will be re-applied on the "
                            "next replay of these events",
                        instance_id => Id,
                        count => map_size(LocalWrites),
                        reason => Reason
                    }),
                    ok
            end
    end,
    ok.

%% @private
%% Per-event compute (read + apply + encode). Returns the new frame +
%% HLC to the batch caller, which collects and writes them all at once.
%%
%% Reads first consult `LocalWrites` so in-batch updates to the same
%% `{Bucket, Key}` see each other (the substrate has not been written
%% yet at this point). Then falls back to `Adapter:get/3`.
%%
%% Per-event telemetry boundaries `cell_read` + `cell_apply_event`
%% remain (each cell still pays the read + compute cost). The put
%% and side-effects now happen once per batch and are measured by
%% `batch_cell_put` in `apply_cell_batch/3`.
compute_one_cell(
    Id,
    Adapter,
    Handle,
    Kernel,
    LocalWrites,
    Bucket,
    Key,
    FoldEvent,
    Meta,
    Context,
    SecIdx,
    OldStateCache
) ->
    try
        ReadT0 = erlang:monotonic_time(microsecond),
        %% OldValue read precedence: in-batch shadow (`LocalWrites`) →
        %% A3 frame-cache → projection `get/3`. A cache hit returns
        %% byte-identical `{OldState, OldValueOpt}` to a projection read
        %% (the cache is a write-through mirror of the durable frame), so
        %% the kernel result is unchanged — A3 only removes the read I/O.
        {OldState, OldValueOpt} =
            case maps:get({Bucket, Key}, LocalWrites, undefined) of
                undefined ->
                    read_old_value(
                        OldStateCache, Adapter, Handle, Kernel, Id, Bucket, Key
                    );
                LocalFrame ->
                    decode_old_frame(Kernel, LocalFrame)
            end,
        telemetry:execute(
            [bondy_oplog, applier, cell_read],
            #{duration_us => erlang:monotonic_time(microsecond) - ReadT0},
            #{instance_id => Id}
        ),

        ApplyT0 = erlang:monotonic_time(microsecond),
        %% The cell kernel ({fold, _} legacy or {crdt, _} operation-based)
        %% applies one operation and returns every frame component. The
        %% fold-vs-CRDT branch lives in `bondy_oplog_cell_kernel`, not here.
        {NewState, Hlc, NewStateBytes, NewValueBytes, ValueEqualsState} =
            bondy_oplog_cell_kernel:apply(
                Kernel, OldState, OldValueOpt, FoldEvent, Meta, Context
            ),
        NewFrame = bondy_oplog_cell_frame:encode(
            Hlc,
            NewStateBytes,
            NewValueBytes,
            ValueEqualsState
        ),
        telemetry:execute(
            [bondy_oplog, applier, cell_apply_event],
            #{duration_us => erlang:monotonic_time(microsecond) - ApplyT0},
            #{instance_id => Id}
        ),
        %% Term-diff the cell's old vs new value into secondary index ops.
        %% Wrapped in its own try (`index_ops_for_cell/8`) so a malformed
        %% spec degrades only the index (rebuildable) and never drops the
        %% primary write.
        IdxOps = index_ops_for_cell(
            SecIdx, Id, Kernel, Bucket, Key, OldState, NewState, Hlc
        ),
        {ok, NewFrame, Hlc, IdxOps}
    catch
        C:R:S ->
            ?LOG_ERROR(#{
                description =>
                    "bondy_oplog_applier cell_apply raised; the cell "
                    "has been skipped. Batch continues with remaining cells.",
                instance_id => Id,
                bucket => Bucket,
                cell_key => Key,
                kernel => Kernel,
                class => C,
                reason => R,
                stacktrace => S
            }),
            skip
    end.

%% @private
%% A3 — resolve OldValue from the frame-cache (hit) or the projection
%% (miss). Emits a `[bondy_oplog, applier, oldstate_cache]` hit/miss
%% event only when the cache is enabled (zero overhead when off).
read_old_value(OldStateCache, Adapter, Handle, Kernel, Id, Bucket, Key) ->
    case oldstate_cache_get(OldStateCache, Bucket, Key) of
        {hit, Frame} ->
            emit_cache_result(OldStateCache, Id, hit),
            decode_old_frame(Kernel, Frame);
        miss ->
            emit_cache_result(OldStateCache, Id, miss),
            case Adapter:get(Handle, Bucket, Key) of
                not_found ->
                    {
                        bondy_oplog_cell_kernel:init(Kernel),
                        undefined
                    };
                {ok, OldFrame} ->
                    decode_old_frame(Kernel, OldFrame)
            end
    end.

%% @private
%% Decode a stored cell frame into `{OldState, OldValueOpt}` — the exact shape
%% `compute_one_cell/12` consumes. Shared by the in-batch shadow, the A3
%% cache-hit, and the projection-read paths so all three are byte-for-byte
%% equivalent.
decode_old_frame(Kernel, Frame) ->
    {_PrevHlc, StateBytes, ValueBytes} =
        bondy_oplog_cell_frame:decode_full(Frame),
    {
        bondy_oplog_cell_kernel:decode_state(Kernel, StateBytes),
        ValueBytes
    }.

%% @private
%% A3 OldValue frame-cache constructor. `{Tab, Max}` when enabled,
%% `undefined` when disabled (every cache op below is then a no-op and
%% behaviour is byte-identical to pre-A3). The table is `private` — only
%% the owning applier process reads or writes it.
oldstate_cache_new(false, _Max) ->
    undefined;
oldstate_cache_new(true, Max) ->
    {ets:new(applier_oldstate_cache, [set, private]), Max}.

%% @private
%% Look up the cached frame for `{Bucket, Key}`.
oldstate_cache_get(undefined, _Bucket, _Key) ->
    miss;
oldstate_cache_get({Tab, _Max}, Bucket, Key) ->
    case ets:lookup(Tab, {Bucket, Key}) of
        [{_, Frame}] -> {hit, Frame};
        [] -> miss
    end.

%% @private
%% Write-through the just-written `{Bucket, Key, Frame}` entries. Called
%% only after the projection `put_batch` returns ok, so the cache mirrors
%% exactly what is durable. Bounded: if the table is at the cap, it is
%% cleared before inserting (coarse evict — the cache is rebuildable, so a
%% clear only costs re-warm misses on the next cycle).
oldstate_cache_put_entries(undefined, _Entries) ->
    ok;
oldstate_cache_put_entries({Tab, Max}, Entries) ->
    case ets:info(Tab, size) >= Max of
        true -> ets:delete_all_objects(Tab);
        false -> ok
    end,
    lists:foreach(
        fun({Bucket, Key, Frame}) ->
            ets:insert(Tab, {{Bucket, Key}, Frame})
        end,
        Entries
    ),
    ok.

%% @private
%% Drop every cached frame. Used when the projection is written outside
%% the write-through paths (catalogue install) so the cache cannot serve
%% a pre-install frame on the next read. No-op when disabled.
oldstate_cache_clear(undefined) ->
    ok;
oldstate_cache_clear({Tab, _Max}) ->
    true = ets:delete_all_objects(Tab),
    ok.

%% @private
emit_cache_result(undefined, _Id, _Result) ->
    ok;
emit_cache_result(_Cache, Id, Result) ->
    telemetry:execute(
        [bondy_oplog, applier, oldstate_cache],
        #{count => 1},
        #{instance_id => Id, result => Result}
    ).

%% @private
%% Tracks the maximum HLC seen across a batch so the per-shard
%% high-water mark can be advanced once at the end instead of once
%% per cell event.
max_hlc(undefined, Hlc) -> Hlc;
max_hlc(A, B) when A >= B -> A;
max_hlc(_, B) -> B.

%% @private
%% Bundle the namespace + resolved secondary-index descriptors out of the
%% cell-apply ctx into the compact `{NS, [Descriptor]}` pair threaded
%% through the cell compute/dispatch path. `[]` (no indexes) makes every
%% downstream step a strict no-op.
sec_idx(Ctx) ->
    {NS, _Index, _Shard} = maps:get(shard_key, Ctx),
    {NS, maps:get(secondary_indexes, Ctx, [])}.

%% @private
%% Term-diff one cell's old vs new value into a flat list of
%% `{IndexName, SecShard, IndexOp}` across every declared secondary index.
%% Own try/catch: a malformed spec (e.g. a term type the codec rejects)
%% degrades only the index — the caller's primary write proceeds.
index_ops_for_cell(
    {_NS, []}, _Id, _Kernel, _Bucket, _Key, _OldState, _NewState, _Hlc
) ->
    [];
index_ops_for_cell(
    {_NS, SecIndexes}, Id, Kernel, Bucket, Key, OldState, NewState, Hlc
) ->
    try
        OldValue = bondy_oplog_cell_kernel:to_value(Kernel, OldState),
        NewValue = bondy_oplog_cell_kernel:to_value(Kernel, NewState),
        lists:flatmap(
            fun(Desc) ->
                index_ops_for_one(Desc, Bucket, Key, OldValue, NewValue, Hlc)
            end,
            SecIndexes
        )
    catch
        C:R:S ->
            ?LOG_ERROR(#{
                description =>
                    "bondy_oplog_applier secondary-index op computation "
                    "raised; the index is degraded for this cell "
                    "(rebuildable from the primary). The primary write "
                    "is unaffected.",
                instance_id => Id,
                bucket => Bucket,
                cell_key => Key,
                class => C,
                reason => R,
                stacktrace => S
            }),
            []
    end.

%% @private
%% A `put` for every current term (an idempotent re-put also refreshes the
%% denormalised columns when sibling fields changed) and a `remove` for
%% every term the value no longer yields. The op HLC is the *primary*
%% cell's new HLC, so the index cell's LWW-over-presence fold converges
%% regardless of arrival order.
index_ops_for_one(
    #{index_name := IName, spec := Spec, sec_shard_count := SCount} = Desc,
    Bucket,
    Key,
    OldValue,
    NewValue,
    Hlc
) ->
    RealmFolded = maps:get(realm_folded, Desc, false),
    OldTerms = lists:usort(bondy_oplog_index_spec:terms(Spec, OldValue)),
    NewTerms = lists:usort(bondy_oplog_index_spec:terms(Spec, NewValue)),
    SecBucket = bondy_oplog_index_key:bucket(Bucket, IName),
    Cols = bondy_oplog_index_spec:project(Spec, NewValue),
    Removed = OldTerms -- NewTerms,
    [
        index_op(
            IName, SecBucket, SCount, T, Key, {put, Cols, Hlc}, RealmFolded
        )
     || T <- NewTerms
    ] ++
        [
            index_op(
                IName, SecBucket, SCount, T, Key, {remove, Hlc}, RealmFolded
            )
         || T <- Removed
        ].

%% @private
index_op(IName, SecBucket, SCount, Term, PrimaryKey, EventDelta, RealmFolded) ->
    SecShard = bondy_oplog_index_key:shard(SecBucket, Term, SCount),
    SecKey = index_seckey(Term, PrimaryKey, RealmFolded),
    Op =
        case EventDelta of
            {put, Cols, Hlc} -> {put, SecBucket, SecKey, Cols, Hlc};
            {remove, Hlc} -> {remove, SecBucket, SecKey, Hlc}
        end,
    {IName, SecShard, Op}.

%% @private
%% Compose the secondary key. A scalar term keeps the term-first layout
%% `«enc(Term), 0, PrimaryKey»` (a realm, if the topology folds one, stays inside
%% `PrimaryKey` and is scoped on the read side by `index_eq_bounds/4`). A composite
%% (list) term on a realm-folding topology (G-1) is recomposed realm-FIRST —
%% `«Realm, 0, enc(Tuple), 0, BareKey»` — so a prefix/range scan over the tuple
%% stays inside one realm. The realm is split out of the G-1 folded `PrimaryKey`
%% `«Realm, 0, BareKey»` (realm URIs are NUL-free, so the first `0x00` delimits it).
index_seckey(Term, PrimaryKey, true) when is_list(Term) ->
    [Realm, BareKey] = binary:split(PrimaryKey, <<0>>),
    <<Realm/binary, 0, (bondy_oplog_index_key:encode_term(Term))/binary, 0,
        BareKey/binary>>;
index_seckey(Term, PrimaryKey, _RealmFolded) ->
    bondy_oplog_index_key:encode(Term, PrimaryKey).

%% @private
%% Group the cell's `{IndexName, SecShard, Op}` triples into
%% `#{{IndexName, SecShard} => [Op]}` (ops accumulate in reverse; the
%% dispatcher restores arrival order). A no-op for an empty op list, so
%% non-indexed tables pay nothing.
merge_idx_ops(Acc, []) ->
    Acc;
merge_idx_ops(Acc, [{IName, SecShard, Op} | Rest]) ->
    K = {IName, SecShard},
    merge_idx_ops(Acc#{K => [Op | maps:get(K, Acc, [])]}, Rest).

%% @private
%% Dispatch the grouped index ops to the secondary writer owning each
%% touched shard, resolved live from the registry (so the writer need not
%% have existed when the applier started). A missing writer pid or row is
%% dropped silently — the index is rebuildable from the primary.
%%
%% Back-pressure: each `(IName, SecShard)` carries an in-flight op
%% counter. On the live drain path (`Bypass = false`) a batch that would
%% push the counter past the index's `max_inflight` cap is dropped, the
%% shard is marked `needs_rebuild`, its freshness reset to stale (so reads
%% refuse), and a rebuild requested. A rebuild's own re-fold dispatches
%% with `Bypass = true` so it can reload the full working set in one pass.
dispatch_index_ops({_NS, []}, _IdxAcc, _MaxHlc, _Bypass) ->
    ok;
dispatch_index_ops({NS, SecIndexes}, IdxAcc, MaxHlc, Bypass) ->
    Hlc =
        case MaxHlc of
            undefined -> 0;
            _ -> MaxHlc
        end,
    Caps = maps:from_list([
        {
            maps:get(index_name, D),
            maps:get(max_inflight, D, ?DEFAULT_MAX_INFLIGHT)
        }
     || D <- SecIndexes
    ]),
    maps:foreach(
        fun({IName, SecShard}, RevOps) ->
            Cap = maps:get(IName, Caps, ?DEFAULT_MAX_INFLIGHT),
            dispatch_one_index(
                NS, IName, SecShard, lists:reverse(RevOps), Hlc, Cap, Bypass
            )
        end,
        IdxAcc
    ).

%% @private
dispatch_one_index(NS, IName, SecShard, Ops, MaxHlc, Cap, Bypass) ->
    case bondy_oplog_core_registry:lookup(NS, IName, SecShard) of
        {ok, Entry} ->
            case bondy_oplog_core_registry:entry_writer_pid(Entry) of
                Pid when is_pid(Pid) ->
                    NumOps = length(Ops),
                    Accept =
                        Bypass orelse
                            bondy_oplog_core_registry:index_inflight(Entry) +
                                NumOps =< Cap,
                    case Accept of
                        true ->
                            _ = bondy_oplog_core_registry:index_inflight_add(
                                Entry, NumOps
                            ),
                            %% Tag the batch with its `(NS, IndexName)` stream:
                            %% the writer is shared across every index shard on
                            %% its `writer_key` and demuxes the ops back to each
                            %% stream's projection.
                            bondy_oplog_secondary_writer:enqueue(
                                Pid, {NS, IName}, Ops, MaxHlc
                            );
                        false ->
                            secondary_saturation_drop(
                                NS, IName, SecShard, Entry, NumOps
                            )
                    end;
                undefined ->
                    ok
            end;
        not_found ->
            ok
    end.

%% @private
%% Saturation: the secondary writer's in-flight backlog would exceed the
%% cap. Drop the batch (the index is a deterministic function of the
%% primary, so it is rebuildable), mark the shard for rebuild, reset its
%% freshness so `index_get`/`index_range` refuse until the rebuild
%% completes, and request the rebuild.
secondary_saturation_drop(NS, IName, SecShard, Entry, NumOps) ->
    bondy_oplog_core_registry:index_mark_rebuild(Entry),
    bondy_oplog_core_registry:reset_stale_ae(Entry),
    telemetry:execute(
        [bondy_oplog, secondary_writer, saturated],
        #{dropped_ops => NumOps},
        #{namespace => NS, index_name => IName, shard => SecShard}
    ),
    catch bondy_oplog_index_rebuild:request(NS, IName),
    ok.

%% @private
%% Walks the `{Key, Value}` pairs from the MST (or its diff) and
%% dispatches every `cell_apply` op through the batched compute path.
%% Non-cell ops are skipped here — the per-instance fold owns them and
%% has already seen them via the WAL drain.
%%
%% Same collect-then-batch shape as `apply_cell_batch/3`. Per-key shadow
%% map preserves in-batch read-your-own-writes when two pairs target the
%% same `{Bucket, Key}`.
%%
%% Index dispatch respects the back-pressure cap (`Bypass = false`): a
%% peer-event replay that overflows a writer is dropped and self-heals via
%% a marked rebuild. The full-rebuild path no longer routes through here —
%% it re-indexes from the converged projection (`reindex_from_projection/3`).
apply_cell_pairs(Ctx, Id, Pairs, LocalOrigin) ->
    #{adapter := Adapter, handle := Handle, kernel := Kernel} = Ctx,
    CacheAdapter = maps:get(cache_adapter, Ctx, undefined),
    CacheHandle = maps:get(cache_handle, Ctx, undefined),
    HighWaterRef = maps:get(high_water_ref, Ctx, undefined),
    OldStateCache = maps:get(oldstate_cache, Ctx, undefined),
    SecIdx = sec_idx(Ctx),
    %% When set (table opened with `publish => true`), every PEER-authored cell
    %% this replay writes is published as a remote-merge event so node-local
    %% reactors can react to peer-originated changes. `undefined` ⇒ no emission,
    %% zero cost. The replay diff can also sweep up locally-authored cells (a
    %% shared per-shard instance replays one MST whenever ANY of its tables
    %% merges a peer root); those were already published locally via
    %% `publish_batch`, so they are filtered here by `LocalOrigin` — only a cell
    %% whose event-key origin differs from this node's own origin is a true merge.
    PublishNs = maps:get(publish_ns, Ctx, undefined),
    try
        {LocalWrites, MaxHlc, N, IdxAcc, PubAcc} = lists:foldl(
            fun
                (
                    {MstKey, {
                        {cell_apply, Bucket, CellKey, FoldEvent},
                        EventMeta,
                        _Prev,
                        _Sig
                    }},
                    {WAcc, HlcAcc, NAcc, IAcc, PAcc}
                ) ->
                    case
                        compute_one_cell(
                            Id,
                            Adapter,
                            Handle,
                            Kernel,
                            WAcc,
                            Bucket,
                            CellKey,
                            FoldEvent,
                            MstKey,
                            EventMeta,
                            SecIdx,
                            OldStateCache
                        )
                    of
                        {ok, NewFrame, NewHlc, IdxOps} ->
                            WAcc1 = WAcc#{{Bucket, CellKey} => NewFrame},
                            %% Only a peer-authored cell is a true merge; a
                            %% locally-authored cell swept into the diff was
                            %% already published locally.
                            CellPublishNs = merge_publish_ns(
                                PublishNs, MstKey, LocalOrigin
                            ),
                            PAcc1 = maybe_collect_merge(
                                CellPublishNs,
                                PAcc,
                                Bucket,
                                CellKey,
                                FoldEvent,
                                NewHlc
                            ),
                            {
                                WAcc1,
                                max_hlc(HlcAcc, NewHlc),
                                NAcc + 1,
                                merge_idx_ops(IAcc, IdxOps),
                                PAcc1
                            };
                        skip ->
                            {WAcc, HlcAcc, NAcc, IAcc, PAcc}
                    end;
                (_, Acc) ->
                    Acc
            end,
            {#{}, undefined, 0, #{}, #{}},
            Pairs
        ),
        case map_size(LocalWrites) of
            0 ->
                ok;
            _ ->
                Entries = [
                    {B, K, F}
                 || {{B, K}, F} <- maps:to_list(LocalWrites)
                ],
                case Adapter:put_batch(Handle, Entries) of
                    ok ->
                        maps:foreach(
                            fun({B, K}, _F) ->
                                invalidate_cache(
                                    CacheAdapter, CacheHandle, B, K
                                )
                            end,
                            LocalWrites
                        ),
                        %% A3 — write-through the peer/replay frames too,
                        %% so a subsequent local read sees the durable
                        %% value (no-op when disabled).
                        oldstate_cache_put_entries(OldStateCache, Entries),
                        case MaxHlc of
                            undefined -> ok;
                            _ -> advance_high_water(HighWaterRef, MaxHlc)
                        end,
                        %% Advance the applied-frontier version vector over every
                        %% `{HLC, Origin, Seq}` in this committed batch. The
                        %% universal materialisation path, so it captures all
                        %% sources (local fast/replay, remote append, page-sync
                        %% merge). The convergence oracle compares these frontiers
                        %% across nodes. After the durable write, so the frontier
                        %% never leads the projection.
                        ok = bondy_oplog_registry:merge_frontier(
                            Id, batch_frontier(Pairs)
                        ),
                        dispatch_index_ops(SecIdx, IdxAcc, MaxHlc, false),
                        %% Notify reactors AFTER the durable write + index
                        %% dispatch, so a reactor that reads back sees the
                        %% merged value. Best-effort, never blocks the replay.
                        publish_merges(PublishNs, PubAcc);
                    {error, Reason} ->
                        ?LOG_WARNING(#{
                            description =>
                                "bondy_oplog_applier replay batch write "
                                "failed; the cells will be re-applied on "
                                "the next sync tick",
                            instance_id => Id,
                            count => map_size(LocalWrites),
                            reason => Reason
                        })
                end
        end,
        N
    catch
        C:R:S ->
            ?LOG_WARNING(#{
                description =>
                    "bondy_oplog_applier replay_cell_events raised; "
                    "the projection may be temporarily stale on this "
                    "node — the next sync tick re-issues the replay.",
                instance_id => Id,
                class => C,
                reason => R,
                stacktrace => S
            }),
            0
    end.

%% @private
%% As `batch_frontier/1`, for the local/append path (`apply_cell_batch/3`), whose
%% input is a list of `bondy_oplog_event:t()` rather than `{MstKey, _}` pairs.
batch_frontier_events(Events) ->
    lists:foldl(
        fun(Event, Acc) ->
            case bondy_oplog_event:op(Event) of
                {cell_apply, _B, _K, _F} ->
                    Key = bondy_oplog_event:key(Event),
                    Origin = bondy_oplog_event:key_origin(Key),
                    Seq = bondy_oplog_event:key_seq(Key),
                    case Acc of
                        #{Origin := Cur} when Cur >= Seq -> Acc;
                        _ -> Acc#{Origin => Seq}
                    end;
                _ ->
                    Acc
            end
        end,
        #{},
        Events
    ).

%% @private
%% Per-origin max-Seq over the cell_apply events in a replay batch — the
%% applied-frontier delta committed via `bondy_oplog_registry:merge_frontier/2`.
%% Iterates ALL cell_apply pairs (materialised or skipped): a skipped event is
%% older than the cell's current state, so that origin's frontier is already at a
%% higher seq, making the unconditional `max` correct.
batch_frontier(Pairs) ->
    lists:foldl(
        fun
            ({MstKey, {{cell_apply, _B, _K, _F}, _Meta, _Prev, _Sig}}, Acc) ->
                Origin = bondy_oplog_event:key_origin(MstKey),
                Seq = bondy_oplog_event:key_seq(MstKey),
                case Acc of
                    #{Origin := Cur} when Cur >= Seq -> Acc;
                    _ -> Acc#{Origin => Seq}
                end;
            (_, Acc) ->
                Acc
        end,
        #{},
        Pairs
    ).

%% @private
%% Per-bucket multiplexing front-ends for `apply_cell_batch/3` and
%% `apply_cell_pairs/4`. A shard instance shared by several tables receives
%% events for more than one `Bucket` (entity type); these group the batch by
%% bucket and apply each group under that bucket's `cell_apply_ctx`, resolved
%% from a `ctx_source()`:
%%
%%   `{single, Ctx}` — one table per instance (today): every bucket resolves to
%%       the same ctx. With a single bucket this is byte-identical to calling
%%       `apply_cell_batch/3` / `apply_cell_pairs/4` directly.
%%   `{dir, Map}`    — a `#{Bucket => Ctx}` directory: each bucket resolves to
%%       its own table's ctx (the per-shard-instance multiplexer).
%%
%% A bucket with no ctx under a `{dir, _}` source is logged and skipped (its
%% cells re-apply on the next replay); `{single, undefined}` is the
%% no-cell-apply instance and is a silent no-op.
apply_cell_batch_mux({single, undefined}, _Id, _Events) ->
    ok;
apply_cell_batch_mux(Source, Id, Events) ->
    lists:foreach(
        fun({Bucket, Group}) ->
            case bondy_oplog_mux:resolve(Source, Bucket) of
                undefined ->
                    log_missing_ctx(Id, Bucket, length(Group));
                Ctx ->
                    ok = apply_cell_batch(Ctx, Id, Group)
            end
        end,
        bondy_oplog_mux:group_by(Events, fun event_bucket/1)
    ),
    ok.

%% @private
%% As `apply_cell_batch_mux/3`, for the replay/merge path; returns the total
%% number of cells applied across all bucket groups.
apply_cell_pairs_mux({single, undefined}, _Id, _Pairs, _LocalOrigin) ->
    0;
apply_cell_pairs_mux(Source, Id, Pairs, LocalOrigin) ->
    lists:foldl(
        fun({Bucket, Group}, Acc) ->
            case bondy_oplog_mux:resolve(Source, Bucket) of
                undefined ->
                    log_missing_ctx(Id, Bucket, length(Group)),
                    Acc;
                Ctx ->
                    Acc + apply_cell_pairs(Ctx, Id, Group, LocalOrigin)
            end
        end,
        0,
        bondy_oplog_mux:group_by(Pairs, fun pair_bucket/1)
    ).

-doc """
Build the initial `ctx_source()` for the cell-apply mux. A `cell_apply_bucket`
in `Opts` (a `bondy_db`-provisioned table that may later share its shard
instance) starts the source in `{dir, _}` mode keyed by that bucket, so
`source_put/3` can add sibling tables. Without it — the single-table and
raw-instance callers — the source stays `{single, Ctx}` (every bucket routes to
the one ctx), byte-identical to the pre-mux behaviour. A `CellCtx` of `undefined`
is the no-cell-apply instance.
""".
-spec build_source(
    CellCtx :: cell_apply_ctx() | undefined, Opts :: map()
) -> ctx_source().

build_source(undefined, _Opts) ->
    bondy_oplog_mux:single(undefined);
build_source(CellCtx, Opts) ->
    case maps:get(cell_apply_bucket, Opts, undefined) of
        Bucket when is_binary(Bucket) ->
            bondy_oplog_mux:dir([{Bucket, CellCtx}]);
        _ ->
            bondy_oplog_mux:single(CellCtx)
    end.

%% @private
event_bucket(Event) ->
    case bondy_oplog_event:op(Event) of
        {cell_apply, Bucket, _Key, _FoldEvent} -> {ok, Bucket};
        _ -> skip
    end.

%% @private
pair_bucket(
    {_MstKey, {{cell_apply, Bucket, _CellKey, _FoldEvent}, _Meta, _Prev, _Sig}}
) ->
    {ok, Bucket};
pair_bucket(_) ->
    skip.

%% @private
log_missing_ctx(Id, Bucket, Count) ->
    ?LOG_WARNING(#{
        description =>
            "bondy_oplog_cell_apply: no cell-apply context for bucket; "
            "cells skipped (they re-apply on the next replay).",
        instance_id => Id,
        bucket => Bucket,
        count => Count
    }).

%% @private
%% The publish namespace to use for ONE replayed cell: the table's `PublishNs`
%% only when the cell was peer-authored (its event-key origin differs from this
%% node's `LocalOrigin`), else `undefined` (suppress emission). A locally
%% authored cell — which a shared per-shard instance can sweep into a replay diff
%% triggered by a sibling table's peer merge — was already published locally via
%% the applier's `publish_batch`, so re-publishing it as a "merge" would be a
%% spurious, duplicate reactor event. `LocalOrigin = undefined` (no origin known)
%% degrades to publishing all, preserving the pre-filter behaviour.
merge_publish_ns(undefined, _MstKey, _LocalOrigin) ->
    undefined;
merge_publish_ns(PublishNs, MstKey, LocalOrigin) ->
    case bondy_oplog_event:key_origin(MstKey) of
        LocalOrigin -> undefined;
        _ -> PublishNs
    end.

%% @private
%% Accumulate a cell's `(FoldEvent, Hlc)` for remote-merge publication, keyed by
%% `{Bucket, CellKey}` so a key written twice in one batch publishes once (the
%% last write). A no-op when the table did not opt in (`publish_ns = undefined`).
maybe_collect_merge(undefined, PubAcc, _Bucket, _CellKey, _FoldEvent, _Hlc) ->
    PubAcc;
maybe_collect_merge(_NS, PubAcc, Bucket, CellKey, FoldEvent, Hlc) ->
    PubAcc#{{Bucket, CellKey} => {FoldEvent, Hlc}}.

%% @private
%% Publish one remote-merge event per collected cell. The published `(Key, Op)`
%% mirrors `bondy_db:publish_event/1` (Key = CellKey, Op = FoldEvent), so a
%% reactor sees the same shape for local and remote changes.
publish_merges(undefined, _PubAcc) ->
    ok;
publish_merges(NS, PubAcc) ->
    maps:foreach(
        fun({_Bucket, CellKey}, {FoldEvent, Hlc}) ->
            bondy_oplog_core:publish_merge(NS, CellKey, Hlc, FoldEvent)
        end,
        PubAcc
    ).

%% @private
%% Invalidate the per-shard read cache entry for `{Bucket, Key}` after a
%% projection write so the next reader repopulates it. Both `(a)` the
%% applier cannot insert the correct cached value (the cache wants the
%% post-overlay-merge value but the applier has only the *decoded* fold
%% state) and `(b)` the next reader's `slow_read_traced/3` will repopulate
%% the cache anyway.
invalidate_cache(undefined, _Handle, _Bucket, _Key) ->
    ok;
invalidate_cache(_Adapter, undefined, _Bucket, _Key) ->
    ok;
invalidate_cache(Adapter, Handle, Bucket, Key) ->
    %% `delete/3` is the cache_adapter callback. Swallow any errors —
    %% a failed cache eviction must not stop the drain.
    _ = catch Adapter:delete(Handle, Bucket, Key),
    ok.

%% @private
%% Advance the per-shard high-water HLC mark
%% (`bondy_oplog_high_water:advance/2`) after a successful projection
%% write. The ref may be `undefined` defensively (older registry entries
%% without an allocated ref); new registrations always allocate, so this
%% branch is dead in practice but keeps the applier resilient.
advance_high_water(undefined, _Hlc) ->
    ok;
advance_high_water(Ref, Hlc) ->
    bondy_oplog_high_water:advance(Ref, Hlc).
