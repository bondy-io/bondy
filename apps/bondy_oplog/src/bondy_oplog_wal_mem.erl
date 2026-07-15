%% =============================================================================
%%  bondy_oplog_wal_mem.erl -
%%
%%  Copyright (c) 2024-2026 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

-module(bondy_oplog_wal_mem).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

?MODULEDOC("""
In-memory (ETS) write-ahead log backend for **ephemeral fused** instances.

The disk WAL (`bondy_oplog_wal`) welds the drain's *visibility* of an event to
the durable position, which only advances at an fsync boundary. For an
**ephemeral** instance that constraint is redundant: the projection and MST are
themselves ETS (lost on node death) and durability is cluster-provided via
anti-entropy. This module makes the WAL ephemeral too — events live in a
`public ordered_set` keyed by a dense monotonic `Seq`, the fused drain reads
them via `bondy_oplog_wal_mem_reader` the instant they are inserted, and there
is **no fsync and no disk I/O on the ack path**.

### The append is caller-side and lock-free

Appends do **not** go through this gen_server. A single `gen_server:call` per
write serialised every writer of a shard through one mailbox — the ephemeral
throughput ceiling. Instead the producer bundle (`wal_handle/1`, published to
the registry at `init/1`) carries the ETS tid and an `atomics` ref, and
`append_local/2` runs entirely in the caller:

1. reserve a contiguous `Seq` range with `atomics:add_get/3` (monotonic, unique
   across concurrent callers),
2. `ets:insert/2` each `{Seq, Event}` directly into the `write_concurrency`
   table,
3. wake a parked drain **only if one is parked** (a single `poke` cast per
   idle→busy transition — never per write under load).

Because two callers can reserve `K` and `K+1` and insert `K+1` first, a reader
can momentarily see a **gap** at `K`. The reader (`bondy_oplog_wal_mem_reader`)
therefore reads the *contiguous prefix* and stops at the first missing `Seq`,
distinguishing an in-flight gap (`Seq =< reserved`) from the true end of the log
(`Seq > reserved`) via the `reserved` atomic. The gap fills within microseconds;
the next drain step continues. This "read to first gap" replaces the serial
gen_server insert's contiguity guarantee without a lock.

### Atomics slots

`?A_RESERVED` — the max `Seq` handed out (the head). `?A_COMMITTED` — the GC
watermark (last `Seq` the drain has installed). `?A_WAKE` — `1` while a drain is
parked on `await_durable`, so a caller knows to `poke`.

### Shared control protocol

The producer *ack* is lock-free, but the control surfaces still speak the same
`gen_server` protocol as `bondy_oplog_wal` so the shared wrappers route to
either backend with the mem pid:

- `{await_durable, {Seg, Off}, Timeout}` — reply once `reserved >= Off`
  (registers a waiter woken by a caller `poke`; a double-check on registration
  closes the lost-wakeup window).
- `durable_position` — `{?MEM_SEG, reserved}` (head is always durable here).
- `{set_committed_segment, Seg}` — retention marker (no-op; GC is by `Seq`).
- `{append_batch, Events}` — the non-fast fallback (`append/3`) still appends via
  a call; it shares the lock-free reserve+insert, then signals waiters inline.

### Durability decision (cluster-durable)

Dropping the fsync widens the acked-but-not-yet-replicated loss window to also
include a BEAM crash with surviving disk. This is accepted by design for
ephemeral instances and covered by anti-entropy in normal operation.

### Deferred

- Crash recovery: the table dies with this gen_server (node/process death →
  re-sync from peers). An `heir`-owned table is deferred.
""").

%% A mem WAL has a single logical segment; `Seq` plays the byte-offset role in
%% the `{Segment, Offset}` position shape the consumer-offset machinery expects.
-define(MEM_SEG, 0).

%% Atomics slots (unsigned).
-define(A_SLOTS, 3).
-define(A_RESERVED, 1).
-define(A_COMMITTED, 2).
-define(A_WAKE, 3).

%% Backpressure cap on the LIVE (un-GC'd) event count: `reserved - committed`.
-define(DEFAULT_MAX_LIVE_EVENTS, 2_000_000).

-record(waiter, {
    id :: pos_integer(),
    from :: gen_server:from(),
    target :: pos_integer(),
    timer :: undefined | reference()
}).

-record(state, {
    instance_id :: binary(),
    origin :: bondy_oplog_origin:t(),
    tab :: ets:tid(),
    atomics :: atomics:atomics_ref(),
    max_live_events :: pos_integer(),
    waiter_seq = 0 :: non_neg_integer(),
    waiters = [] :: [#waiter{}]
}).

%% API
-export([start_link/2]).
-export([append_local/2]).
-export([reader_view/1]).
-export([reserved/1]).
-export([committed/1]).
-export([set_committed_seq/2]).
-export([info/1]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Starts the per-instance in-memory WAL writer. Same start contract as
`bondy_oplog_wal:start_link/2` so `bondy_oplog_instance_sup` can swap the child
module on `wal_backend => mem`.
""").
-spec start_link(binary(), map()) -> {ok, pid()} | {error, term()}.

start_link(InstanceId, Opts) when is_binary(InstanceId), is_map(Opts) ->
    gen_server:start_link(?MODULE, {InstanceId, Opts}, []).

?DOC("""
Lock-free caller-side append. Reserves a contiguous `Seq` range via the atomics
head, inserts each `{Seq, Event}` directly into the public ETS table, and wakes
a parked drain iff one is parked. Runs entirely in the calling process — no
`gen_server:call`. Backpressure (`reserved - committed + N > max`) rejects the
whole batch, matching the disk WAL's all-or-nothing `check_backpressure`.

Returns `{ok, Entries}` with `Entries :: [{Hlc, {?MEM_SEG, Seq}}]` in input
order, or `{error, wal_full}`.
""").
-spec append_local(Handle :: map(), Events :: [bondy_oplog_event:t()]) ->
    {ok, [{term(), {non_neg_integer(), pos_integer()}}]} | {error, wal_full}.

append_local(#{backend := mem} = Handle, Events) when is_list(Events) ->
    #{
        tab := Tab,
        atomics := ARef,
        pid := Pid,
        max_live_events := Max,
        instance_id := Id
    } = Handle,
    N = length(Events),
    case admit(ARef, Max, N) of
        ok ->
            {ok, Entries} = insert_batch(Tab, ARef, Events),
            maybe_wake(ARef, Pid),
            {ok, Entries};
        {error, wal_full} = Err ->
            telemetry:execute(
                [bondy_oplog, wal_mem, wal_full],
                #{live => live_count(ARef), batch => N},
                #{instance_id => Id}
            ),
            Err
    end.

?DOC("""
Returns the read-side view the mem reader needs: the ETS tid, the logical
segment id, and the atomics ref (so the reader can tell an in-flight `Seq` gap
from the end of the log). The table is `public`, so any process may read it
lock-free.
""").
-spec reader_view(pid()) ->
    #{tab => ets:tid(), mem_seg => non_neg_integer(), atomics => atomics:atomics_ref()}.

reader_view(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, reader_view, infinity).

?DOC("The head: the max `Seq` handed out. Read lock-free from the atomics ref.").
-spec reserved(atomics:atomics_ref()) -> non_neg_integer().

reserved(ARef) ->
    atomics:get(ARef, ?A_RESERVED).

?DOC("The GC watermark: the last `Seq` the drain has installed + committed.").
-spec committed(atomics:atomics_ref()) -> non_neg_integer().

committed(ARef) ->
    atomics:get(ARef, ?A_COMMITTED).

?DOC("""
Marks every event with `Seq =< CommittedSeq` as consumed by the drain and GCs
them from the table. Cast (best-effort, non-blocking): the drain calls this at
each commit boundary with its reader cursor.
""").
-spec set_committed_seq(pid(), non_neg_integer()) -> ok.

set_committed_seq(Pid, Seq) when is_pid(Pid), is_integer(Seq), Seq >= 0 ->
    gen_server:cast(Pid, {set_committed_seq, Seq}).

?DOC("Diagnostic snapshot of the mem WAL writer state.").
-spec info(pid()) -> map().

info(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, info, infinity).

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init({InstanceId, Opts}) ->
    process_flag(trap_exit, true),
    Tab = ets:new(bondy_oplog_wal_mem, [
        ordered_set,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    ARef = atomics:new(?A_SLOTS, [{signed, false}]),
    MaxLive = maps:get(max_live_events, Opts, ?DEFAULT_MAX_LIVE_EVENTS),
    Origin = maps:get(origin, Opts, bondy_oplog_origin:default()),
    %% Publish our pid (disk-WAL parity: `ensure_wal_pid/1`, the idle-waiter's
    %% `await_durable`, and the fused reader all resolve this process) AND the
    %% caller-side append handle the fast path uses.
    ok = bondy_oplog_registry:set_wal_pid(InstanceId, self()),
    ok = bondy_oplog_registry:set_wal_handle(InstanceId, #{
        backend => mem,
        tab => Tab,
        atomics => ARef,
        pid => self(),
        max_live_events => MaxLive,
        instance_id => InstanceId
    }),
    {ok, #state{
        instance_id = InstanceId,
        origin = Origin,
        tab = Tab,
        atomics = ARef,
        max_live_events = MaxLive
    }}.

handle_call({append_batch, Events}, _From, State) ->
    do_append_batch(Events, State);
handle_call({await_durable, {_Seg, Off}, Timeout}, From, State) ->
    do_await_durable(Off, Timeout, From, State);
handle_call(durable_position, _From, #state{atomics = ARef} = State) ->
    {reply, {?MEM_SEG, atomics:get(ARef, ?A_RESERVED)}, State};
handle_call({set_committed_segment, _Seg}, _From, State) ->
    %% Retention marker. GC by committed Seq is via `set_committed_seq/2`.
    {reply, ok, State};
handle_call(reader_view, _From, #state{tab = Tab, atomics = ARef} = State) ->
    {reply, #{tab => Tab, mem_seg => ?MEM_SEG, atomics => ARef}, State};
handle_call(info, _From, State) ->
    {reply, info_map(State), State};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({set_committed_seq, Seq}, State) ->
    {noreply, gc_committed(Seq, State)};
handle_cast(poke, State) ->
    %% A caller advanced the head while a drain was parked — release any waiter
    %% the new `reserved` now covers.
    {noreply, signal_waiters(State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({await_timeout, Id}, State) ->
    {noreply, expire_waiter(Id, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    %% The `public` table is owned by this process and is deleted automatically
    %% on exit. An `heir` for process-crash recovery is deferred.
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Backpressure on the LIVE (un-GC'd) event count. Racy across concurrent
%% callers (both may pass and slightly overshoot `Max`) — acceptable, `Max` is a
%% stalled-drain safety bound, not an exact quota.
admit(ARef, Max, N) ->
    case live_count(ARef) + N > Max of
        true -> {error, wal_full};
        false -> ok
    end.

%% @private
live_count(ARef) ->
    atomics:get(ARef, ?A_RESERVED) - atomics:get(ARef, ?A_COMMITTED).

%% @private
%% Reserve a contiguous `Seq` range with one atomic add, then insert each event.
%% Lock-free; safe from any process concurrently. The reserve-then-insert can
%% leave a transient gap the reader tolerates (see the moduledoc).
insert_batch(Tab, ARef, Events) ->
    N = length(Events),
    NewReserved = atomics:add_get(ARef, ?A_RESERVED, N),
    FirstSeq = NewReserved - N + 1,
    {ok, insert_seq(Tab, FirstSeq, Events, [])}.

%% @private
insert_seq(_Tab, _Seq, [], Acc) ->
    lists:reverse(Acc);
insert_seq(Tab, Seq, [Event | Rest], Acc) ->
    true = ets:insert(Tab, {Seq, Event}),
    Hlc = bondy_oplog_event:key_hlc(bondy_oplog_event:key(Event)),
    insert_seq(Tab, Seq + 1, Rest, [{Hlc, {?MEM_SEG, Seq}} | Acc]).

%% @private
%% Wake a parked drain iff one is parked. Under load `?A_WAKE` is `0` and this is
%% a single atomic read; at low load one `poke` cast per idle→busy transition.
maybe_wake(ARef, Pid) ->
    case atomics:get(ARef, ?A_WAKE) of
        0 -> ok;
        _ -> gen_server:cast(Pid, poke)
    end.

%% @private
%% The gen_server append fallback (`append/3` via `bondy_oplog_wal:append_batch`
%% for a stateful-validator instance). Shares the lock-free reserve+insert, then
%% signals waiters inline (it is already in the owner process).
do_append_batch(Events, #state{tab = Tab, atomics = ARef} = State) ->
    N = length(Events),
    case admit(ARef, State#state.max_live_events, N) of
        {error, wal_full} = Err ->
            telemetry:execute(
                [bondy_oplog, wal_mem, wal_full],
                #{live => live_count(ARef), batch => N},
                #{instance_id => State#state.instance_id}
            ),
            {reply, Err, State};
        ok ->
            {ok, Entries} = insert_batch(Tab, ARef, Events),
            {reply, {ok, Entries}, signal_waiters(State)}
    end.

%% @private
%% Replies `ok` immediately if `reserved` already covers `Off`; otherwise
%% registers a waiter (with a timeout), flags `?A_WAKE`, then **re-checks**
%% `reserved` — closing the window where a caller reserved between the first read
%% and the flag being set (that caller would have seen `?A_WAKE = 0` and not
%% poked). `signal_waiters/1` performs the re-check and releases this waiter if
%% the head already covers it.
do_await_durable(Off, _Timeout, _From, #state{atomics = ARef} = State) when
    is_integer(Off)
->
    case atomics:get(ARef, ?A_RESERVED) >= Off of
        true ->
            {reply, ok, State};
        false ->
            do_register_waiter(Off, _Timeout, _From, State)
    end.

%% @private
do_register_waiter(Off, Timeout, From, State0) ->
    #state{atomics = ARef, waiter_seq = WS0, waiters = Ws} = State0,
    Id = WS0 + 1,
    TimerRef = arm_timeout(Timeout, Id),
    Waiter = #waiter{id = Id, from = From, target = Off, timer = TimerRef},
    atomics:put(ARef, ?A_WAKE, 1),
    State1 = State0#state{waiter_seq = Id, waiters = [Waiter | Ws]},
    %% Double-check: release now if a concurrent append already covered `Off`.
    {noreply, signal_waiters(State1)}.

%% @private
arm_timeout(infinity, _Id) ->
    undefined;
arm_timeout(Timeout, Id) when is_integer(Timeout), Timeout >= 0 ->
    erlang:send_after(Timeout, self(), {await_timeout, Id}).

%% @private
%% Release every waiter whose target `Seq` is now reserved (== visible). Clears
%% `?A_WAKE` once no waiter remains, so callers stop poking.
signal_waiters(#state{waiters = []} = State) ->
    State;
signal_waiters(#state{waiters = Ws, atomics = ARef} = State) ->
    Reserved = atomics:get(ARef, ?A_RESERVED),
    {Ready, Pending} = lists:partition(
        fun(#waiter{target = T}) -> T =< Reserved end, Ws
    ),
    _ = [reply_waiter(W, ok) || W <- Ready],
    Pending == [] andalso atomics:put(ARef, ?A_WAKE, 0),
    State#state{waiters = Pending}.

%% @private
expire_waiter(Id, #state{waiters = Ws, atomics = ARef} = State) ->
    case lists:keytake(Id, #waiter.id, Ws) of
        {value, W, Rest} ->
            _ = reply_waiter(W, {error, timeout}),
            Rest == [] andalso atomics:put(ARef, ?A_WAKE, 0),
            State#state{waiters = Rest};
        false ->
            State
    end.

%% @private
reply_waiter(#waiter{from = From, timer = Timer}, Reply) ->
    _ = cancel_timer(Timer),
    gen_server:reply(From, Reply).

%% @private
cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref).

%% @private
%% Delete every consumed row (`Seq =< Committed`) from the head of the
%% ordered_set. The matches are a contiguous prefix, so `ets:select_delete`
%% touches only the entries it removes. `committed` is monotonic; bounded by
%% `reserved` so it never runs ahead of the head.
gc_committed(Seq, #state{tab = Tab, atomics = ARef} = State) ->
    Reserved = atomics:get(ARef, ?A_RESERVED),
    Old = atomics:get(ARef, ?A_COMMITTED),
    Bounded = min(Seq, Reserved),
    case Bounded =< Old of
        true ->
            State;
        false ->
            MatchSpec = [{{'$1', '_'}, [{'=<', '$1', Bounded}], [true]}],
            _ = ets:select_delete(Tab, MatchSpec),
            atomics:put(ARef, ?A_COMMITTED, Bounded),
            State
    end.

%% @private
info_map(#state{atomics = ARef} = S) ->
    Reserved = atomics:get(ARef, ?A_RESERVED),
    Committed = atomics:get(ARef, ?A_COMMITTED),
    #{
        instance_id => S#state.instance_id,
        backend => mem,
        head_seq => Reserved,
        committed_seq => Committed,
        live_events => Reserved - Committed,
        max_live_events => S#state.max_live_events,
        %% Each event is handed exactly one Seq, so the reserved head is the
        %% count of events ever appended.
        append_count => Reserved,
        waiters => length(S#state.waiters)
    }.
