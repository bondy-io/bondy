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
`index_entry` CRDT, and bumps each touched shard's freshness so
`{max_lag, Ms}` reads stop refusing.

## Dispatch contract

The primary applier computes the term-diff of every cell it materialises (old
terms vs new terms of the cell's value) and `enqueue/4`s the resulting index
ops to the writer owning each touched secondary shard, tagged with the
`(NS, IndexName)` stream they belong to and the primary shard they come from,
**after** its own projection `put_batch` returns ok. The writer therefore only
ever indexes applied primary state. Ops are `index_entry`-shaped against an
explicit `(SecBucket, SecKey)` cell:

```
{put,    SecBucket, SecKey, Columns :: binary(), Version} |
{remove, SecBucket, SecKey, Version}
```

`SecKey` is the `(Term, PrimaryKey)` composite from
`bondy_oplog_index_key:encode/2`. `Version` is the primary shard's index
version of the event that produced the op
(`bondy_oplog_cell_apply:next_index_version/1`), so the index cell keeps the
op of the latest event in the shard's apply order, whatever order the ops
arrive in.

## Version records

Each flush also writes, in the same `put_batch` and per primary shard the
batch holds ops from, the highest version that shard has reached in this index
shard (`bondy_oplog_core_registry:index_version_cell/3`). A primary shard's
counter restarts above it on open
(`bondy_oplog_core_registry:index_version_recorded/3`), so a new op orders above
every cell already in the index
(`bondy_db_index_coldstart_test:clean_reopen_orders_new_ops_above_old/1`).

## Coalescing

Ops buffer and flush on a short timer (`coalesce_ms`, default 5 ms) so a burst
of primary writes collapses into one `put_batch` per touched stream. A writer
takes the smallest `coalesce_ms` among the index specs of the streams registered
when it starts, a spec without one counting as the default. A writer re-created
by a `bondy_oplog_secondary_sup` restart keeps its single stream's value
(`bondy_db_index_lag_test:restarted_writer_keeps_coalesce_ms/1`); the
several-stream case has no test.
`flush_sync/1` forces an immediate flush of **every** stream and is the
deterministic barrier tests (and the read-side `await_index`) use to observe a
write without polling. `reset/1` discards one stream's buffered ops (the rebuild
orchestrator uses it before a re-fold) without disturbing the others.

## Handles are re-resolved per flush

The writer caches nothing across flushes: each flush re-`lookup/3`s the touched
stream's registry row for the projection adapter/handle, cache pair, freshness
atomics, and high-water ref. This keeps it correct across a registry
re-registration for free — and it never owns the ETS tables it
writes (the topology's DB-scoped owner does), so a writer crash/restart loses
only buffered, not-yet-flushed ops (see below for how they are recovered).

## Registry stamp and recovery

A writer's streams are not held in its process state — they live in the
registry, every entry that shares the writer's `writer_key`
(`index_entries_for_writer/1`). At init the writer stamps its pid onto each
row with `set_writer_pid/4`, so the primary appliers dispatch to it, and then
recovers what a previous writer may have lost:

- A durable stream: the writer resets its in-flight counter before the stamp,
  then buffers the ops it is owed from the leftover intents of every durable
  primary shard of its namespace
  (`bondy_oplog_core_registry:index_intents_leftover/4`), each counted in
  flight. Both run in `init/1`, so a `flush_sync/1` waits for the replay, and
  an op dispatched to the old pid before the stamp has an intent the replay
  reads (`proofs/tla/IndexIntents_Dispatched_Writer.cfg` holds;
  `IndexIntents_ReplayBeforeStamp.cfg` shows replaying before the stamp
  fails). A primary whose intents cannot be read marks the streams for
  rebuild.
- A stream in RAM has no intents: the writer marks it for rebuild when it is
  marked already, has in-flight ops left by the dead writer, or was ever
  freshened. A first-ever start is left to the rebuild its table's open runs.

A stream provisioned **after** the writer started (a sibling index joining an
already-running writer) is stamped by the facade with the writer's known pid.
The stamp does **not** transfer the registry monitor — the projection-handle
owner keeps it.
""").

-export([start_link/1]).
-export([enqueue/4]).
-export([flush_sync/1]).
-export([flush_entry/2]).
-export([reset/1]).
-export([op_version/1]).

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
        Version :: non_neg_integer()}
    | {remove, SecBucket :: binary(), SecKey :: binary(),
        Version :: non_neg_integer()}.

-export_type([op/0]).
-export_type([stream/0]).

-record(state, {
    %% The shard every stream of this writer lives on (uniform — folded
    %% into `writer_key`).
    shard :: non_neg_integer(),
    %% The `bondy_oplog_secondary_writer` grouping key: the set of index
    %% shards this writer drives is `index_entries_for_writer(writer_key)`.
    writer_key :: binary(),
    %% Buffered ops since the last flush, each tagged with its stream and its
    %% primary shard, in reverse arrival order.
    buffer = [] :: [{stream(), non_neg_integer(), op()}],
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
writer's shard, from primary shard `Source`. Fire-and-forget; ops buffer and
flush on the coalescing timer.
""".
-spec enqueue(pid(), stream(), non_neg_integer(), [op()]) -> ok.

enqueue(Pid, {_NS, _IName} = Stream, Source, Ops) when
    is_pid(Pid) andalso is_integer(Source) andalso is_list(Ops)
->
    gen_server:cast(Pid, {idx_update, Stream, Source, Ops}).

-doc """
Force an immediate flush of every stream's buffered ops and return once the
projection writes (and freshness bumps) have completed. It observes every
`enqueue/4` sent before it, from any process, provided that send happened
before the call: the writer's on-heap mailbox keeps one arrival order. A
failed write marks the shard for rebuild (`bondy_oplog_index_rebuild:mark/1`)
rather than failing the call.
""".
-spec flush_sync(pid()) -> ok.

flush_sync(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, flush_sync, infinity).

-doc """
`flush_sync/1` on the writer of index shard `Entry`, waiting at most
`Timeout` milliseconds (or `infinity`). `{error, no_writer}` when the shard has
no writer, and `{error, Reason}` when the call exits: the writer died, and its
buffer with it, or did not answer in time. A writer still in `init/1` answers
once its replay is buffered.
""".
-spec flush_entry(bondy_oplog_core_registry:shard_entry(), timeout()) ->
    ok | {error, term()}.

flush_entry(Entry, Timeout) ->
    case bondy_oplog_core_registry:entry_writer_pid(Entry) of
        Pid when is_pid(Pid) ->
            try
                gen_server:call(Pid, flush_sync, Timeout)
            catch
                exit:Reason -> {error, Reason}
            end;
        undefined ->
            {error, no_writer}
    end.

-doc """
Discard the buffered ops of the index shard's stream on its writer without
writing them, and cancel the flush timer if the buffer is now empty. Other
streams sharing the writer are untouched. A shard without a live writer has no
buffer, so this returns `ok`.

The rebuild orchestrator calls it before a re-fold: the buffer may hold stale
ops (a `put` for a term the primary value no longer yields, whose retracting
`remove` was dropped on saturation), and applying them would resurrect orphaned
index entries. It resets the in-flight counter separately and re-derives the
ops from the primary.

`bondy_db:close_table/1` calls it before it unregisters the shard. A writer
shared with other tables keeps running, and a table reopened before its flush
would otherwise receive the closed table's ops. The next open replays them
from the primary's index intents (`IndexIntents_Dispatched_Clean.cfg`, where a
close empties the buffer).
""".
-spec reset(bondy_oplog_core_registry:shard_entry()) -> ok.

reset(Entry) ->
    case bondy_oplog_core_registry:entry_writer_pid(Entry) of
        Pid when is_pid(Pid) ->
            {NS, IName, _Shard} = bondy_oplog_core_registry:entry_key(Entry),
            try
                gen_server:call(Pid, {reset, {NS, IName}}, infinity)
            catch
                exit:_ -> ok
            end;
        undefined ->
            ok
    end.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init(#{writer_key := WriterKey, shard := Shard}) ->
    %% On-heap, so the mailbox is one queue in arrival order. An off-heap
    %% queue may take per-sender buffers, which ERTS appends in buffer order
    %% (`proc_sig_queue_flush_buffers/2` in `erl_proc_sig_queue.c`), and a
    %% `flush_sync` could then overtake an `enqueue` another process sent
    %% before it. The dispatch back-pressure cap bounds the backlog.
    process_flag(message_queue_data, on_heap),
    Entries = bondy_oplog_core_registry:index_entries_for_writer(WriterKey),
    {Durable, InRam} = lists:partition(fun is_durable/1, Entries),
    ok = lists:foreach(
        fun bondy_oplog_core_registry:index_inflight_reset/1, Durable
    ),
    ok = adopt_streams(Entries),
    ok = lists:foreach(fun maybe_request_rebuild/1, InRam),
    State = #state{
        shard = Shard,
        writer_key = WriterKey,
        buffer = replay_intents(Durable),
        coalesce_ms = coalesce_ms(Entries)
    },
    {ok,
        case State#state.buffer of
            [] -> State;
            _ -> arm_timer(State)
        end}.

handle_call(flush_sync, _From, State0) ->
    State1 = cancel_timer(State0),
    State2 = do_flush(State1),
    {reply, ok, State2};
handle_call({reset, Stream}, _From, #state{buffer = Buf} = State0) ->
    Buf1 = [E || {S, _Source, _Op} = E <- Buf, S =/= Stream],
    State1 =
        case Buf1 of
            [] -> cancel_timer(State0);
            _ -> State0
        end,
    {reply, ok, State1#state{buffer = Buf1}};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(
    {idx_update, Stream, Source, Ops}, #state{buffer = Buf} = State0
) ->
    State1 = State0#state{buffer = prepend(Stream, Source, Ops, Buf)},
    {noreply, arm_timer(State1)};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(flush, State0) ->
    State1 = State0#state{flush_timer = undefined},
    {noreply, do_flush(State1)};
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
%% Stamp our pid onto every index shard registered under our `writer_key`, so
%% the primary appliers dispatch to us.
adopt_streams(Entries) ->
    lists:foreach(
        fun(Entry) ->
            {NS, IName, Shard} = bondy_oplog_core_registry:entry_key(Entry),
            bondy_oplog_core_registry:set_writer_pid(NS, IName, Shard, self())
        end,
        Entries
    ).

%% @private
is_durable(Entry) ->
    bondy_oplog_projection_adapter:is_durable(
        bondy_oplog_core_registry:entry_projection_adapter(Entry)
    ).

%% @private
%% The buffer of the ops that the leftover intents of each durable primary
%% shard of the streams' namespaces hold for `Entries`, each counted in flight.
replay_intents(Entries) ->
    maps:fold(
        fun(NS, NSEntries, Buf0) ->
            Own = maps:from_list([
                {{IName, SecShard}, E}
             || E <- NSEntries,
                {_, IName, SecShard} <- [
                    bondy_oplog_core_registry:entry_key(E)
                ]
            ]),
            lists:foldl(
                fun(Primary, Buf) -> replay_primary(Primary, Own, Buf) end,
                Buf0,
                [
                    P
                 || P <- bondy_oplog_core_registry:primary_entries(NS),
                    is_durable(P)
                ]
            )
        end,
        [],
        maps:groups_from_list(
            fun(E) -> element(1, bondy_oplog_core_registry:entry_key(E)) end,
            Entries
        )
    ).

%% @private
%% A primary whose intents cannot be read marks the streams for rebuild.
replay_primary(Primary, Own, Buf0) ->
    {NS, _, Source} = bondy_oplog_core_registry:entry_key(Primary),
    case
        bondy_oplog_core_registry:index_intents_leftover(
            bondy_oplog_core_registry:entry_projection_adapter(Primary),
            bondy_oplog_core_registry:entry_projection_handle(Primary),
            NS,
            Source
        )
    of
        {ok, _Cleared, Intents} ->
            lists:foldl(
                fun({_Version, IdxAcc}, Buf1) ->
                    maps:fold(
                        fun({IName, _} = Key, Ops, Buf) ->
                            case Own of
                                #{Key := Entry} ->
                                    _ = bondy_oplog_core_registry:index_inflight_add(
                                        Entry, length(Ops)
                                    ),
                                    prepend({NS, IName}, Source, Ops, Buf);
                                #{} ->
                                    Buf
                            end
                        end,
                        Buf1,
                        IdxAcc
                    )
                end,
                Buf0,
                Intents
            );
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "bondy_oplog_secondary_writer could not read a primary "
                    "shard's index intents; its index shards are marked for "
                    "rebuild.",
                namespace => NS,
                primary_shard => Source,
                reason => Reason
            }),
            ok = lists:foreach(
                fun bondy_oplog_index_rebuild:mark/1, maps:values(Own)
            ),
            Buf0
    end.

%% @private
coalesce_ms([]) ->
    ?DEFAULT_COALESCE_MS;
coalesce_ms(Entries) ->
    lists:min([
        case bondy_oplog_core_registry:entry_coalesce_ms(E) of
            undefined -> ?DEFAULT_COALESCE_MS;
            Ms -> Ms
        end
     || E <- Entries
    ]).

%% @private
maybe_request_rebuild(Entry) ->
    Trigger =
        bondy_oplog_core_registry:index_needs_rebuild(Entry) orelse
            bondy_oplog_core_registry:index_inflight(Entry) > 0 orelse
            bondy_oplog_core_registry:entry_ever_freshened(Entry),
    case Trigger of
        true -> bondy_oplog_index_rebuild:mark(Entry);
        false -> ok
    end.

%% =============================================================================
%% INTERNAL — buffering
%% =============================================================================

prepend(_Stream, _Source, [], Buf) ->
    Buf;
prepend(Stream, Source, [Op | Rest], Buf) ->
    prepend(Stream, Source, Rest, [{Stream, Source, Op} | Buf]).

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
        fun({Stream, _Source, _Op}) -> {ok, Stream} end
    ),
    lists:foreach(
        fun({{NS, IName}, Tagged}) ->
            Ops = [{Source, Op} || {_Stream, Source, Op} <- Tagged],
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
    T0 = erlang:monotonic_time(microsecond),
    Writes = build_writes(Adapter, Handle, [Op || {_Source, Op} <- Ops]),
    case Writes of
        [] ->
            ok;
        _ ->
            case
                Adapter:put_batch(Handle, Writes ++ version_cells(Entry, Ops))
            of
                ok ->
                    lists:foreach(
                        fun({B, K, _F}) ->
                            invalidate_cache(CacheAdapter, CacheHandle, B, K)
                        end,
                        Writes
                    ),
                    bump_ae(AeRef),
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
                            "failed; the index shard is marked for rebuild "
                            "from the primary.",
                        namespace => NS,
                        index_name => IName,
                        shard => Shard,
                        cells => length(Writes),
                        reason => Reason
                    }),
                    bondy_oplog_index_rebuild:mark(Entry)
            end
    end.

%% Fold every op into a per-cell shadow state (read-modify-write against
%% the live projection, with in-batch reads seeing prior in-batch writes),
%% then encode one V2 `value_equals_state` frame per touched cell.
build_writes(Adapter, Handle, Ops) ->
    Shadow = lists:foldl(
        fun(Op, Acc) ->
            {Bucket, Key, Event, _Version} = op_parts(Op),
            State0 = current_state(Adapter, Handle, Acc, Bucket, Key),
            State1 = ?INDEX_CRDT:apply_op(State0, Event, undefined),
            Acc#{{Bucket, Key} => State1}
        end,
        #{},
        Ops
    ),
    maps:fold(
        fun({Bucket, Key}, State, Ws) ->
            Frame = bondy_oplog_cell_frame:encode(
                ?INDEX_CRDT:hlc(State),
                ?INDEX_CRDT:encode_state(State),
                undefined,
                true
            ),
            [{Bucket, Key, Frame} | Ws]
        end,
        [],
        Shadow
    ).

%% One version record per primary shard the batch holds ops from: the larger of
%% the stored record and the batch's highest version from that shard, so the
%% record is a running maximum whatever order the ops arrive in.
version_cells(Entry, Ops) ->
    Max = lists:foldl(
        fun({Source, Op}, Acc) ->
            V = op_version(Op),
            maps:update_with(Source, fun(M) -> max(M, V) end, V, Acc)
        end,
        #{},
        Ops
    ),
    [
        bondy_oplog_core_registry:index_version_cell(
            Entry,
            Source,
            max(
                V,
                bondy_oplog_core_registry:index_recorded_version(Entry, Source)
            )
        )
     || Source := V <- Max
    ].

-doc "The index version an op carries.".
-spec op_version(op()) -> non_neg_integer().

op_version(Op) ->
    {_Bucket, _Key, _Event, Version} = op_parts(Op),
    Version.

op_parts({put, Bucket, Key, Cols, Version}) ->
    {Bucket, Key, {put, Cols, Version}, Version};
op_parts({remove, Bucket, Key, Version}) ->
    {Bucket, Key, {remove, Version}, Version}.

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
    Adapter:delete(Handle, Bucket, Key).

bump_ae(undefined) ->
    ok;
bump_ae(Ref) ->
    atomics:put(Ref, 1, erlang:monotonic_time(millisecond)),
    ok.
