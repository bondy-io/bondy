%% =============================================================================
%%  bondy_oplog_wal_mem_reader.erl -
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

-module(bondy_oplog_wal_mem_reader).

-include("bondy_doc.hrl").

?MODULEDOC("""
Read side of the in-memory ephemeral WAL (`bondy_oplog_wal_mem`).

Mirrors the surface of `bondy_oplog_wal_reader` that the fused drain uses —
`open/3`, `next/1`, `position/1`, `close/1` — but reads events out of the mem
WAL's `ordered_set` ETS table instead of segment files. Because an inserted
event is visible to a reader immediately (no durable-position gate), this is
where the ephemeral path stops paying the WAL-durability latency.

`next/1` returns the same shape as `bondy_oplog_wal_reader:next/1`
(`{ok, Batch, Hlcs, {Seg, Off}, NewIter}`), with `Off` being the dense `Seq`
and `Seg` the mem WAL's single logical segment id — so the fused drain's
consumer-offset bookkeeping, idle-waiter and `collect_frames`-style aggregation
work unchanged on `{Seg, Seq}` positions.

The drain dispatches to this module (vs `bondy_oplog_wal_reader`) on the
instance's `wal_backend` flag; `bondy_oplog_wal_reader` itself is untouched.
""").

%% Default events read per `next/1` when the caller does not pass `{chunk, _}`.
%% Set at `open/3` from the fused drain's `apply_batch_max` so a mem batch
%% matches the disk path's batch size (the disk reader's `collect_frames`
%% aggregates frames up to `apply_batch_max`). A too-large chunk inflates the
%% install-batch latency that bounds the bounded-writer→await pipeline.
-define(DEFAULT_CHUNK, 256).

-record(mem_iter, {
    wal_pid :: pid(),
    tab :: ets:tid(),
    atomics :: atomics:atomics_ref(),
    seg :: non_neg_integer(),
    cursor = 0 :: non_neg_integer(),
    %% For an `{hlc, T}` start: drop events with `key_hlc < min_hlc` from each
    %% batch (Seq order need not equal HLC order under concurrency, so we
    %% filter rather than seek). `undefined` for `beginning` / `tail` /
    %% `{offset, _, _}`. Re-applying an already-installed event is idempotent
    %% by the CRDT contract, so this only avoids redundant work.
    min_hlc :: undefined | term(),
    chunk = ?DEFAULT_CHUNK :: pos_integer()
}).

-opaque t() :: #mem_iter{}.
-export_type([t/0]).

-export([open/2]).
-export([open/3]).
-export([next/1]).
-export([position/1]).
-export([reserved/1]).
-export([close/1]).

-ifdef(TEST).
%% Exposed so property tests can open a reader over a hand-built view (table +
%% atomics) with no running WAL gen_server. See `open_over/4`.
-export([open_over/4]).
-endif.

%% =============================================================================
%% API
%% =============================================================================

-spec open(pid(), bondy_oplog_wal_reader:start_position()) ->
    {ok, t()} | {error, term()}.

open(WalPid, Start) ->
    open(WalPid, Start, []).

?DOC("""
Opens a reader over the mem WAL's table at `Start`. `Opts` are accepted for
parity with `bondy_oplog_wal_reader:open/3` (e.g. `{follow, _}`) and ignored —
the mem reader never blocks; `next/1` simply returns `end_of_log` when the
cursor has caught up to the head.
""").
-spec open(pid(), bondy_oplog_wal_reader:start_position(), list()) ->
    {ok, t()} | {error, term()}.

open(WalPid, Start, Opts) when is_pid(WalPid) ->
    try bondy_oplog_wal_mem:reader_view(WalPid) of
        #{} = View ->
            {ok, open_over(WalPid, View, Start, Opts)}
    catch
        exit:{noproc, _} -> {error, wal_unavailable};
        exit:noproc -> {error, wal_unavailable};
        exit:{normal, _} -> {error, wal_unavailable};
        exit:{shutdown, _} -> {error, wal_unavailable}
    end.

%% @private
%% Build an iterator over an explicit reader view (the map `reader_view/1`
%% returns). Factored out of `open/3` so property tests can drive the reader
%% over a hand-built table + atomics without a running WAL gen_server. `WalPid`
%% is consulted only for the `tail` start (it needs `info/1`); the `beginning` /
%% `{offset,_}` / `{hlc,_}` starts tests use do not touch it.
open_over(WalPid, #{tab := Tab, mem_seg := Seg, atomics := ARef}, Start, Opts) ->
    Chunk = proplists:get_value(chunk, Opts, ?DEFAULT_CHUNK),
    Iter0 = #mem_iter{
        wal_pid = WalPid,
        tab = Tab,
        atomics = ARef,
        seg = Seg,
        chunk = Chunk
    },
    apply_start(Iter0, Start).

?DOC("""
Returns the next chunk of events in the **contiguous prefix** past `cursor` (up
to `chunk`), or `end_of_log` when the cursor has caught up. The position
returned is the `Seq` of the last delivered event.

Because appends are lock-free (`bondy_oplog_wal_mem:append_local/2`), two callers
can reserve `K` and `K+1` and insert `K+1` first — so a bare `ets:next/2` walk
(which skips absent keys) would read `K+1` and permanently miss the in-flight
`K`. Instead this walks the *contiguous* run with a point `ets:lookup/2` from
`cursor+1` and **stops at the first missing `Seq`**. A missing `Seq =< reserved`
is a transient in-flight gap (the drain retries and it fills within
microseconds); `Seq > reserved` is the genuine end of the log. A missing
`Seq =< committed` is a GC'd prefix (a reader opened behind the GC watermark) and
is skipped forward to `committed`. Point lookups keep reads O(chunk·log n)
regardless of cursor advance or GC.
""").
-spec next(t()) -> bondy_oplog_wal_reader:next_result().

next(#mem_iter{seg = Seg, cursor = Cursor} = Iter) ->
    #mem_iter{tab = Tab, atomics = ARef, chunk = Chunk, min_hlc = Min} = Iter,
    case walk(Tab, ARef, Cursor, Chunk, Min, []) of
        {[], Cursor} ->
            %% Nothing in the contiguous prefix past the cursor — caught up (or
            %% blocked on an in-flight gap; the drain distinguishes via
            %% `reserved/1` and retries).
            end_of_log;
        {[], NewCursor} ->
            %% Only skipped entries (below `min_hlc`, or a GC'd prefix jump);
            %% advance and retry.
            next(Iter#mem_iter{cursor = NewCursor});
        {AccRev, NewCursor} ->
            {ok, lists:reverse(AccRev), [], {Seg, NewCursor}, Iter#mem_iter{
                cursor = NewCursor
            }}
    end.

-spec position(t()) -> {non_neg_integer(), non_neg_integer()}.

position(#mem_iter{seg = Seg, cursor = Cursor}) ->
    {Seg, Cursor}.

?DOC("""
The mem WAL's current head (`reserved` Seq). The fused drain compares it to the
reader cursor to tell an in-flight gap (retry) from the true end of the log
(park): `cursor < reserved` with an empty read means a gap.
""").
-spec reserved(t()) -> non_neg_integer().

reserved(#mem_iter{atomics = ARef}) ->
    bondy_oplog_wal_mem:reserved(ARef).

-spec close(t()) -> ok.

close(#mem_iter{}) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
apply_start(Iter, beginning) ->
    Iter#mem_iter{cursor = 0};
apply_start(Iter, tail) ->
    %% Start at the head: skip everything already present.
    #{head_seq := H} = bondy_oplog_wal_mem:info(Iter#mem_iter.wal_pid),
    Iter#mem_iter{cursor = H};
apply_start(Iter, {offset, _Seg, Off}) ->
    Iter#mem_iter{cursor = Off};
apply_start(Iter, {hlc, Hlc}) ->
    %% No persisted Seq↔HLC map (a fresh process has an empty table), so scan
    %% from the start and drop events below the watermark per batch.
    Iter#mem_iter{cursor = 0, min_hlc = Hlc}.

%% @private
%% Walk the CONTIGUOUS run forward from `Cursor` collecting up to `K` kept events
%% (reversed). Each step is a point `ets:lookup/2` at `Cursor+1` (O(log n)). A
%% `min_hlc` skip advances the cursor WITHOUT consuming a slot. A missing
%% `Cursor+1` stops the walk (its cursor is left at the last contiguous Seq) —
%% EXCEPT a GC'd prefix (`Cursor+1 =< committed`), which is skipped forward to
%% `committed`. Returns the reversed events and the last Seq advanced to.
walk(_Tab, _ARef, Cursor, 0, _Min, Acc) ->
    {Acc, Cursor};
walk(Tab, ARef, Cursor, K, Min, Acc) ->
    Seq = Cursor + 1,
    case ets:lookup(Tab, Seq) of
        [{Seq, Event}] ->
            case keep(Event, Min) of
                true ->
                    walk(Tab, ARef, Seq, K - 1, Min, [Event | Acc]);
                false ->
                    walk(Tab, ARef, Seq, K, Min, Acc)
            end;
        [] ->
            %% `Seq` is absent: an in-flight gap, the end of the log, or a GC'd
            %% prefix. Since `Cursor >= committed` for a live drain, a GC'd
            %% prefix only arises when a reader opened behind the GC watermark —
            %% jump forward to `committed` and continue. Otherwise stop.
            Committed = bondy_oplog_wal_mem:committed(ARef),
            case Seq =< Committed of
                true -> walk(Tab, ARef, Committed, K, Min, Acc);
                false -> {Acc, Cursor}
            end
    end.

%% @private
keep(_Event, undefined) ->
    true;
keep(Event, MinHlc) ->
    bondy_oplog_event:key_hlc(bondy_oplog_event:key(Event)) >= MinHlc.
