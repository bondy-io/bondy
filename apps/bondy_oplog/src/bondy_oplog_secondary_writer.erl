%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_secondary_writer).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Asynchronous writer for the secondary indexes on one shard. One lightweight
gen_server per `writer_key`, supervised by `bondy_oplog_secondary_sup`.

A single writer drives **every** index shard that shares its `writer_key`,
demultiplexing the ops it is handed back to each `(NS, IndexName, SecShard)`
stream. The owner (`bondy_db`) chooses the `writer_key`'s granularity from the
topology's instance strategy: coarse on a backend that co-locates tables in one
Bookie (one writer per `(DbName, SecShard)`, shared by every index of every
table on the shard) and fine on a single-table backend (one writer per index
shard, a degenerate directory of one stream). Either way the writer is the same:
the strategy only sets how many streams it carries — the secondary-side mirror
of how the per-shard primary instance multiplexes tables by entity-type bucket.

## Why a separate process (not a `bondy_oplog_instance`)

The index keyspace has no WAL, no MST, and no signing — it is a pure
deterministic function of the primary, rebuilt from it on cold start. A full
`bondy_oplog_instance` subtree (`one_for_all`, co-supervising WAL + MST it would
never use) is the wrong shape. The writer is a mini-applier over the indexes'
ETS projections: it batches the index ops the primary appliers dispatch, groups
them by stream, read-modify-writes each touched index cell through the
`index_entry` fold, and bumps each touched shard's freshness + high-water marks
so `{max_lag, Ms}` reads stop refusing.

## Dispatch contract

The primary applier computes the term-diff of every cell it materialises (old
terms vs new terms of the cell's value) and `enqueue/4`s the resulting index
ops to the writer owning each touched secondary shard, tagged with the
`(NS, IndexName)` stream they belong to, **after** its own projection
`put_batch` returns ok. The writer therefore only ever indexes durably-applied
primary state. Ops are `index_entry`-shaped against an explicit
`(SecBucket, SecKey)` cell:

```
{put,    SecBucket, SecKey, Columns :: binary(), Hlc} |
{remove, SecBucket, SecKey, Hlc}
```

`SecKey` is the `(Term, PrimaryKey)` composite from
`bondy_oplog_index_key:encode/2`; `Hlc` is the *primary* cell's HLC, so the
index cell's LWW-over-presence fold converges identically regardless of whether
the op arrived from a local WAL drain or a peer replay.

## Coalescing

Ops buffer and flush on a short timer (`coalesce_ms`, default 5 ms) so a burst
of primary writes collapses into one `put_batch` per touched stream.
`flush_sync/1` forces an immediate flush of **every** stream and is the
deterministic barrier tests (and the read-side `await_index`) use to observe a
write without polling. `reset/2` discards one stream's buffered ops (the rebuild
orchestrator uses it before a re-fold) without disturbing the others.

## Handles are re-resolved per flush

The writer caches nothing across flushes: each flush re-`lookup/3`s the touched
stream's registry row for the projection adapter/handle, cache pair, freshness
atomics, and high-water ref. This keeps it correct across a registry
re-registration (epoch change) for free — and it never owns the ETS tables it
writes (the topology's DB-scoped owner does), so a writer crash/restart loses
only buffered, not-yet-flushed ops, which the rebuild recovers.

## Registry stamp and self-healing

A writer's streams are not held in its process state — they live in the
registry, every entry that shares the writer's `writer_key`. At init (and on the
registry-restart epoch event) the writer re-derives that set via
`index_entries_for_writer/1`, stamps its pid onto each row with `set_writer_pid/4`
so the primary applier can dispatch to it, and requests a rebuild for any stream
whose shard a crash left un-recoverable. A stream provisioned **after** the
writer started (a sibling index joining an already-running writer) is stamped by
the facade with the writer's known pid; the writer picks it up on the next epoch
event. The stamp does **not** transfer the registry monitor — the
projection-handle owner keeps it.
""").

-export([start_link/1]).
-export([enqueue/4]).
-export([flush_sync/1]).
-export([flush_sync/2]).
-export([reset/2]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% The `(NS, IndexName)` a buffered op belongs to — the writer's
%% multiplexing key. The `SecShard` is uniform across a writer's streams
%% (it is folded into the `writer_key`), so it is held once in state.
-type stream() :: {NS :: atom(), IndexName :: atom()}.

-type op() ::
    {put, SecBucket :: binary(), SecKey :: binary(), Columns :: binary(),
        Hlc :: non_neg_integer()}
    | {remove, SecBucket :: binary(), SecKey :: binary(),
        Hlc :: non_neg_integer()}.

-export_type([op/0]).
-export_type([stream/0]).

-record(state, {
    %% The shard every stream of this writer lives on (uniform — folded
    %% into `writer_key`).
    shard :: non_neg_integer(),
    %% The `bondy_oplog_secondary_writer` grouping key: the set of index
    %% shards this writer drives is `index_entries_for_writer(writer_key)`.
    writer_key :: binary(),
    %% Buffered ops since the last flush, each tagged with its stream, in
    %% reverse arrival order (`group_by/2` restores per-stream order at flush).
    buffer = [] :: [{stream(), op()}],
    %% Outstanding coalescing timer, or `undefined` when the buffer is
    %% empty / just flushed.
    flush_timer = undefined :: undefined | reference(),
    coalesce_ms :: non_neg_integer()
}).

-define(DEFAULT_COALESCE_MS, 5).
%% The native op-based CRDT backing every secondary-index cell (the
%% op-based twin of the retired `bondy_oplog_fold_index_entry`).
-define(INDEX_CRDT, bondy_oplog_crdt_index_entry).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.

start_link(#{writer_key := _, shard := _} = Args) ->
    gen_server:start_link(?MODULE, Args, []).

-doc """
Enqueue a batch of index ops for the `(NS, IndexName)` stream `Stream` on this
writer's shard. Fire-and-forget; ops buffer and flush on the coalescing timer.
`Hlc` is the primary batch's max HLC, carried for telemetry only — the writer
derives the authoritative high-water mark from the ops it actually materialises.
""".
-spec enqueue(pid(), stream(), [op()], non_neg_integer()) -> ok.

enqueue(Pid, {_NS, _IName} = Stream, Ops, Hlc) when
    is_pid(Pid) andalso is_list(Ops)
->
    gen_server:cast(Pid, {idx_update, Stream, Ops, Hlc}).

-doc """
Force an immediate flush of every stream's buffered ops and return once the
projection writes (and freshness/high-water bumps) have completed. The
deterministic barrier for tests and operational tooling: because casts are
processed in arrival order, a `flush_sync/1` issued after a sequence of
`enqueue/4`s observes all of them.
""".
-spec flush_sync(pid()) -> ok.

flush_sync(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, flush_sync, infinity).

-doc """
`flush_sync/1` with a bounded wait. The compaction flush barrier
(`bondy_oplog_instance:drive_secondary_indexes/1`) uses this so a wedged or dead
writer cannot stall a truncate indefinitely: on timeout the caller catches the
exit and falls back to the rebuild backstop rather than blocking the instance.
`Timeout` is in milliseconds (or the atom `infinity`).
""".
-spec flush_sync(pid(), timeout()) -> ok.

flush_sync(Pid, Timeout) when
    is_pid(Pid) andalso (Timeout =:= infinity orelse is_integer(Timeout))
->
    gen_server:call(Pid, flush_sync, Timeout).

-doc """
Discard one stream's buffered ops without writing them and cancel the flush
timer if the buffer is now empty. Used by the rebuild orchestrator before a
re-fold of that stream: the buffer may hold stale ops (e.g. a `put` for a term
the primary value no longer yields, whose retracting `remove` was dropped on
saturation), so applying them would resurrect orphaned index entries. The
rebuild discards the stream's buffer and resets its in-flight counter together,
then re-derives the correct ops from the primary. Other streams sharing this
writer are untouched.
""".
-spec reset(pid(), stream()) -> ok.

reset(Pid, {_NS, _IName} = Stream) when is_pid(Pid) ->
    gen_server:call(Pid, {reset, Stream}, infinity).

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init(#{writer_key := WriterKey, shard := Shard} = Args) ->
    %% Per-op `{idx_update, …}` cast receiver under write load: keep the
    %% mailbox off the process heap so a transient backlog isn't re-scanned
    %% by the GC (same rationale as the instance/applier/WAL processes).
    process_flag(message_queue_data, off_heap),
    CoalesceMs = maps:get(coalesce_ms, Args, ?DEFAULT_COALESCE_MS),
    %% Stamp our pid onto every stream already registered under this
    %% writer_key so the primary appliers can dispatch to us, and request a
    %% rebuild for any stream a crash left un-recoverable. On a fresh
    %% provisioning only the founding stream exists (siblings the facade
    %% stamps as they join); on a crash restart all of the shard's streams do.
    ok = adopt_streams(WriterKey, Shard),
    %% Re-adopt if the registry restarts (epoch change drops every row,
    %% including our writer_pid stamps).
    ok = bondy_oplog_core_events:subscribe(bondy_oplog_core_registry_started),
    {ok, #state{
        shard = Shard,
        writer_key = WriterKey,
        coalesce_ms = CoalesceMs
    }}.

handle_call(flush_sync, _From, State0) ->
    State1 = cancel_timer(State0),
    State2 = do_flush(State1),
    {reply, ok, State2};
handle_call({reset, Stream}, _From, #state{buffer = Buf} = State0) ->
    %% Drop only this stream's ops unwritten; the rebuild resets that
    %% stream's in-flight counter separately, so they stay consistent.
    %% Sibling streams keep their buffered ops.
    Buf1 = [E || {S, _Op} = E <- Buf, S =/= Stream],
    State1 =
        case Buf1 of
            [] -> cancel_timer(State0);
            _ -> State0
        end,
    {reply, ok, State1#state{buffer = Buf1}};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({idx_update, Stream, Ops, _Hlc}, #state{buffer = Buf} = State0) ->
    State1 = State0#state{buffer = prepend(Stream, Ops, Buf)},
    {noreply, arm_timer(State1)};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(flush, State0) ->
    State1 = State0#state{flush_timer = undefined},
    {noreply, do_flush(State1)};
handle_info(
    {bondy_oplog_core_event, bondy_oplog_core_registry_started, _Epoch},
    #state{writer_key = WriterKey, shard = Shard} = State
) ->
    %% The registry restarted: every row (including our writer_pid stamps)
    %% was lost. Re-adopt best-effort. A stream whose projection-handle owner
    %% has not re-registered its row yet is simply absent from the scan; the
    %% index is rebuildable, so we do not block on it.
    ok = adopt_streams(WriterKey, Shard),
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% INTERNAL — stream adoption (self-healing)
%% =============================================================================

%% @private
%% Stamp our pid onto every index shard registered under `WriterKey`, and
%% request a rebuild for any one a crash left un-recoverable. Idempotent:
%% `set_writer_pid/4` is a single-field update and `request/2` is debounced,
%% so re-running it on each epoch event is cheap.
adopt_streams(WriterKey, _Shard) ->
    lists:foreach(
        fun(Entry) ->
            {NS, IName, Shard} = bondy_oplog_core_registry:entry_key(Entry),
            _ = bondy_oplog_core_registry:set_writer_pid(
                NS, IName, Shard, self()
            ),
            ok = maybe_request_rebuild(NS, IName, Entry)
        end,
        bondy_oplog_core_registry:index_entries_for_writer(WriterKey)
    ).

%% @private
maybe_request_rebuild(NS, IName, Entry) ->
    %% Rebuild when: the shard is flagged; OR a crash/kill left un-flushed
    %% in-flight reservations behind (the lost buffer the rebuild recovers —
    %% `terminate/2` does not run on a `kill`, and the leaked reservation is
    %% the only post-restart signal that the dead writer had buffered work);
    %% OR the shard was previously populated (AE past the stale sentinel). A
    %% first-ever start is sentinel-stale, unflagged, with a zero counter, so
    %% it is left to the startup backfill.
    Trigger =
        bondy_oplog_core_registry:index_needs_rebuild(Entry) orelse
            bondy_oplog_core_registry:index_inflight(Entry) > 0 orelse
            bondy_oplog_core_registry:entry_ever_freshened(Entry),
    case Trigger of
        true ->
            catch bondy_oplog_index_rebuild:request(NS, IName),
            ok;
        false ->
            ok
    end.

%% =============================================================================
%% INTERNAL — buffering
%% =============================================================================

%% Prepend a batch tagged with its stream (kept reversed; `group_by/2`
%% restores per-stream arrival order at flush).
prepend(_Stream, [], Buf) ->
    Buf;
prepend(Stream, [Op | Rest], Buf) ->
    prepend(Stream, Rest, [{Stream, Op} | Buf]).

arm_timer(#state{flush_timer = Ref} = State) when is_reference(Ref) ->
    State;
arm_timer(#state{coalesce_ms = Ms} = State) ->
    Ref = erlang:send_after(Ms, self(), flush),
    State#state{flush_timer = Ref}.

cancel_timer(#state{flush_timer = undefined} = State) ->
    State;
cancel_timer(#state{flush_timer = Ref} = State) ->
    _ = erlang:cancel_timer(Ref),
    %% Drain a possibly already-delivered `flush` so it does not fire a
    %% redundant (harmless, empty) flush after we handled it synchronously.
    receive
        flush -> ok
    after 0 -> ok
    end,
    State#state{flush_timer = undefined}.

%% =============================================================================
%% INTERNAL — flush
%% =============================================================================

do_flush(#state{buffer = []} = State) ->
    State#state{flush_timer = undefined};
do_flush(#state{shard = Shard, buffer = Buf} = State) ->
    %% Demultiplex the buffer back to its streams (the same primitive the
    %% primary applier uses to demux a batch by bucket), preserving each
    %% stream's arrival order, then flush each stream to its own projection.
    Groups = bondy_oplog_mux:group_by(
        lists:reverse(Buf),
        fun({Stream, _Op}) -> {ok, Stream} end
    ),
    lists:foreach(
        fun({{NS, IName}, Tagged}) ->
            Ops = [Op || {_Stream, Op} <- Tagged],
            flush_stream(NS, IName, Shard, Ops)
        end,
        Groups
    ),
    State#state{buffer = [], flush_timer = undefined}.

flush_stream(NS, IName, Shard, Ops) ->
    case bondy_oplog_core_registry:lookup(NS, IName, Shard) of
        not_found ->
            ?LOG_DEBUG(#{
                description =>
                    "bondy_oplog_secondary_writer flush dropped: the "
                    "index shard's registry row is gone (torn down or "
                    "registry restarted before re-registration). The "
                    "index is rebuildable from the primary.",
                namespace => NS,
                index_name => IName,
                shard => Shard,
                dropped => length(Ops)
            }),
            ok;
        {ok, Entry} ->
            do_write(NS, IName, Shard, Entry, Ops)
    end.

do_write(NS, IName, Shard, Entry, Ops) ->
    %% These ops leave the buffer now; release their in-flight reservation
    %% (added by the primary applier at dispatch) regardless of the write
    %% outcome — the back-pressure accounting tracks buffered ops, not
    %% successful writes.
    bondy_oplog_core_registry:index_inflight_sub(Entry, length(Ops)),
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
    CacheAdapter = bondy_oplog_core_registry:entry_cache_adapter(Entry),
    CacheHandle = bondy_oplog_core_registry:entry_cache_handle(Entry),
    AeRef = bondy_oplog_core_registry:entry_ae_atomics(Entry),
    HwRef = bondy_oplog_core_registry:entry_high_water_ref(Entry),
    T0 = erlang:monotonic_time(microsecond),
    {Writes, MaxHlc} = build_writes(Adapter, Handle, Ops),
    case Writes of
        [] ->
            ok;
        _ ->
            case Adapter:put_batch(Handle, Writes) of
                ok ->
                    lists:foreach(
                        fun({B, K, _F}) ->
                            invalidate_cache(CacheAdapter, CacheHandle, B, K)
                        end,
                        Writes
                    ),
                    bump_ae(AeRef),
                    advance_high_water(HwRef, MaxHlc),
                    telemetry:execute(
                        [bondy_oplog, secondary_writer, flush],
                        #{
                            duration_us =>
                                erlang:monotonic_time(microsecond) - T0,
                            cells => length(Writes),
                            ops => length(Ops),
                            inflight =>
                                bondy_oplog_core_registry:index_inflight(Entry)
                        },
                        #{namespace => NS, index_name => IName, shard => Shard}
                    );
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        description =>
                            "bondy_oplog_secondary_writer projection write "
                            "failed; the affected index cells will be "
                            "rebuilt from the primary or re-applied "
                            "on the next dispatch.",
                        namespace => NS,
                        index_name => IName,
                        shard => Shard,
                        cells => length(Writes),
                        reason => Reason
                    })
            end
    end.

%% Fold every op into a per-cell shadow state (read-modify-write against
%% the live projection, with in-batch reads seeing prior in-batch writes),
%% then encode one V2 `value_equals_state` frame per touched cell. The
%% high-water mark is the max HLC across the resulting states — the actual
%% HLC now materialised, not merely the max op HLC (an older-HLC op that
%% the fold rejects must not advance it).
build_writes(Adapter, Handle, Ops) ->
    Shadow = lists:foldl(
        fun(Op, Acc) ->
            {Bucket, Key, Event, _H} = op_parts(Op),
            State0 = current_state(Adapter, Handle, Acc, Bucket, Key),
            %% The native op-based index-entry CRDT (`apply_op/3`); `Key` (the
            %% event dot) is unused — the entry carries its own primary HLC in
            %% the operation. Byte-identical to the retired fold.
            State1 = ?INDEX_CRDT:apply_op(State0, Event, undefined),
            Acc#{{Bucket, Key} => State1}
        end,
        #{},
        Ops
    ),
    %% One pass over the shadow map builds the write list and the batch
    %% high-water HLC together (order is irrelevant — it is a put_batch).
    maps:fold(
        fun({Bucket, Key}, State, {Ws, MaxH}) ->
            Hlc = ?INDEX_CRDT:hlc(State),
            Frame = bondy_oplog_cell_frame:encode(
                Hlc,
                ?INDEX_CRDT:encode_state(State),
                undefined,
                true
            ),
            {[{Bucket, Key, Frame} | Ws], erlang:max(MaxH, Hlc)}
        end,
        {[], 0},
        Shadow
    ).

op_parts({put, Bucket, Key, Cols, Hlc}) ->
    {Bucket, Key, {put, Cols, Hlc}, Hlc};
op_parts({remove, Bucket, Key, Hlc}) ->
    {Bucket, Key, {remove, Hlc}, Hlc}.

current_state(Adapter, Handle, Shadow, Bucket, Key) ->
    case maps:get({Bucket, Key}, Shadow, undefined) of
        undefined ->
            case Adapter:get(Handle, Bucket, Key) of
                not_found ->
                    ?INDEX_CRDT:init();
                {ok, Frame} ->
                    {_Hlc, StateBytes, _Value} =
                        bondy_oplog_cell_frame:decode_full(Frame),
                    ?INDEX_CRDT:decode_state(StateBytes)
            end;
        State ->
            State
    end.

invalidate_cache(undefined, _Handle, _Bucket, _Key) ->
    ok;
invalidate_cache(_Adapter, undefined, _Bucket, _Key) ->
    ok;
invalidate_cache(Adapter, Handle, Bucket, Key) ->
    _ = catch Adapter:delete(Handle, Bucket, Key),
    ok.

bump_ae(undefined) ->
    ok;
bump_ae(Ref) ->
    atomics:put(Ref, 1, erlang:monotonic_time(millisecond)),
    ok.

advance_high_water(undefined, _Hlc) ->
    ok;
advance_high_water(Ref, Hlc) ->
    bondy_oplog_high_water:advance(Ref, Hlc).
