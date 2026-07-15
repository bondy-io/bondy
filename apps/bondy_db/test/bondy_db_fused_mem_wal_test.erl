%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Ephemeral ETS WAL (task #50). A fused ephemeral instance can opt into an
%% in-memory WAL backend (`wal_backend => mem`, `bondy_oplog_wal_mem`) that
%% drops the fsync from the ack path: events live in an ETS `ordered_set`, the
%% fused drain reads them via `bondy_oplog_wal_mem_reader` the instant they are
%% inserted (no durable-position gate). These tests prove the mem WAL is
%% actually wired (not silently falling back to disk), that single + bulk writes
%% round-trip through the producer → mem reader → fused drain → projection, and
%% that two mem-backed replicas still converge under `sync` exactly like the
%% disk-backed fused path — i.e. the reader swap changed throughput mechanics,
%% not semantics.

-module(bondy_db_fused_mem_wal_test).

-include_lib("eunit/include/eunit.hrl").

fused_mem_wal_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"mem backend is actually wired (not a disk fallback)",
            {timeout, 30, fun mem_backend_is_wired/0}},
        {"single + bulk writes round-trip through the mem WAL",
            {timeout, 30, fun bulk_writes_round_trip/0}},
        {"two mem-backed replicas converge via sync",
            {timeout, 30, fun mem_replicas_converge/0}},
        {"single-node fused self-peer compaction bounds the MST",
            {timeout, 30, fun compaction_bounds_mst/0}},
        {"fused compaction truncates UNDER concurrent writes",
            {timeout, 60, fun compaction_under_concurrent_writes/0}}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

%% The WAL child must be the in-memory writer. Assert via its diagnostic
%% `info/1` so a silent disk fallback (e.g. a broken gate) fails loudly here
%% rather than passing the functional tests on the disk path.
mem_backend_is_wired() ->
    {Db, T, Id} = open_fused_mem(fmw_wired),
    WalPid = bondy_oplog_registry:wal_pid(Id),
    ?assert(is_pid(WalPid)),
    Info = bondy_oplog_wal_mem:info(WalPid),
    ?assertEqual(mem, maps:get(backend, Info)),
    %% A single write advances the head Seq and is readable.
    H = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r">>, <<"k">>, {set, H, <<"v">>}),
    ?assertEqual(<<"v">>, val(bondy_db:read(T, <<"r">>, <<"k">>))),
    ?assert(maps:get(head_seq, bondy_oplog_wal_mem:info(WalPid)) >= 1),
    ok = bondy_db:close(Db).

%% Many writes must all round-trip: producer → ETS → chunked mem reader →
%% collect aggregation → fused install → projection. Exercises the
%% multi-chunk reader path (N > one ets:select chunk) and the byte accounting.
bulk_writes_round_trip() ->
    {Db, T, Id} = open_fused_mem(fmw_bulk),
    N = 1500,
    [
        begin
            H = bondy_db:tick(T),
            ok = bondy_db:apply(
                T, <<"r">>, key(I), {set, H, val_for(I)}
            )
        end
     || I <- lists:seq(1, N)
    ],
    %% Every key reads back its value.
    [
        ?assertEqual(val_for(I), val(bondy_db:read(T, <<"r">>, key(I))))
     || I <- lists:seq(1, N)
    ],
    Info = bondy_oplog_wal_mem:info(bondy_oplog_registry:wal_pid(Id)),
    ?assert(maps:get(head_seq, Info) >= N),
    ?assert(maps:get(append_count, Info) >= N),
    %% GC must have fired: the live (un-GC'd) set is bounded by the commit
    %% cadence, NOT the whole run. Without GC `live_events` would be ~N (the
    %% O(n²)-decay / unbounded-memory regression). All N writes are installed +
    %% committed by now, so the live set is a small tail.
    LiveEvents = maps:get(live_events, Info),
    ?assert(LiveEvents < N div 2),
    ok = bondy_db:close(Db).

%% A writes k1, B writes k2; after a bidirectional sync both replicas answer
%% reads for both keys with identical MST roots — the mem reader feeds the same
%% inline replay the disk reader does, so convergence is unchanged.
mem_replicas_converge() ->
    {DbA, Ta, Ia} = open_fused_mem(fmw_conv_a),
    {DbB, Tb, Ib} = open_fused_mem(fmw_conv_b),
    Ha = bondy_db:tick(Ta),
    ok = bondy_db:apply(Ta, <<"r">>, <<"k1">>, {set, Ha, <<"va">>}),
    Hb = bondy_db:tick(Tb),
    ok = bondy_db:apply(Tb, <<"r">>, <<"k2">>, {set, Hb, <<"vb">>}),
    ok = wait_live(Ia, 1),
    ok = wait_live(Ib, 1),
    {ok, _} = bondy_oplog:sync(Ia, Ib),
    {ok, _} = bondy_oplog:sync(Ib, Ia),
    ?assertEqual(<<"va">>, val(bondy_db:read(Ta, <<"r">>, <<"k1">>))),
    ?assertEqual(<<"vb">>, val(bondy_db:read(Ta, <<"r">>, <<"k2">>))),
    ?assertEqual(<<"va">>, val(bondy_db:read(Tb, <<"r">>, <<"k1">>))),
    ?assertEqual(<<"vb">>, val(bondy_db:read(Tb, <<"r">>, <<"k2">>))),
    ?assertEqual(bondy_oplog:root_hash(Ia), bondy_oplog:root_hash(Ib)),
    ok = bondy_db:close(DbA),
    ok = bondy_db:close(DbB).

%% Reproduces the bench's self-peer compaction (record live root as synced →
%% sync → compact) WITHOUT the bench's error-swallowing catch, and asserts the
%% MST actually shrinks. The bench shows `comp n=0` for single-node fused — this
%% pins whether fused single-node compaction truncates at all (the bounded-MST
%% lever for the install tail) or silently no-ops.
compaction_bounds_mst() ->
    {Db, T, Id} = open_fused_mem(fmw_compact),
    N = 2000,
    [
        begin
            H = bondy_db:tick(T),
            ok = bondy_db:apply(T, <<"r">>, key(I), {set, H, val_for(I)})
        end
     || I <- lists:seq(1, N)
    ],
    ok = wait_live(Id, N),
    Before = live_size(Id),
    %% The bench's compact_trigger steps, verbatim but un-caught.
    Root = bondy_oplog:root_hash(Id),
    ?assert(is_binary(Root)),
    ok = bondy_oplog_peer_state:record_sync_complete(
        {peer, fmw_compact_dummy}, Id, Root
    ),
    bondy_oplog_peer_state:sync(),
    Result = bondy_oplog:compact(Id),
    bondy_oplog_peer_state:forget_peer({peer, fmw_compact_dummy}),
    After = live_size(Id),
    %% Diagnostics surface in the eunit output if the assertion fails.
    ?debugFmt("compact result=~p live_size before=~p after=~p", [
        Result, Before, After
    ]),
    ?assertMatch({ok, {compacted, _, _}}, Result),
    ?assert(After < Before),
    ok = bondy_db:close(Db).

%% The bug PR-5 hit: under CONTINUOUS writes the overlay never drains to 0, so
%% `bondy_oplog:compact`'s old `await_apply` barrier timed out every cycle and
%% compaction never ran (the MST grew unbounded → install latency climbed). This
%% drives a writer that never pauses, runs several compaction cycles concurrently,
%% and asserts the MST is actually bounded (live_size stays far below the total
%% written) — i.e. compaction truncates WHILE writes are in flight.
compaction_under_concurrent_writes() ->
    {Db, T, Id} = open_fused_mem(fmw_concurrent),
    Parent = self(),
    %% Fire-and-forget writers (NO per-write await) keep the overlay non-empty,
    %% reproducing the "overlay never drains to 0" condition under which the old
    %% `await_apply` barrier made compaction time out every cycle. Two writers
    %% over a UNIQUE growing keyspace — without effective compaction the MST
    %% grows toward the full install count (tens of thousands in a few seconds).
    W1 = spawn_link(fun() -> ff_writer(T, Id, 0, Parent) end),
    W2 = spawn_link(fun() -> ff_writer(T, Id, 1, Parent) end),
    %% Run compaction cycles concurrently (the bench's self-peer frontier).
    [
        begin
            timer:sleep(250),
            Root = bondy_oplog_instance:root_hash(Id),
            is_binary(Root) andalso
                begin
                    bondy_oplog_peer_state:record_sync_complete(
                        {peer, fmw_cc_dummy}, Id, Root
                    ),
                    bondy_oplog_peer_state:sync(),
                    _ = bondy_oplog:compact(Id)
                end
        end
     || _ <- lists:seq(1, 10)
    ],
    W1 ! stop,
    W2 ! stop,
    ok = recv_done(),
    ok = recv_done(),
    %% Drain the tail, then one final compaction, and assert the MST is BOUNDED
    %% — far below the ~thousands of unique keys written. Broken compaction
    %% leaves live_size in the tens of thousands; working compaction keeps it
    %% to a small recent tail.
    _ = bondy_oplog_instance:await_apply(Id, 5000),
    Root2 = bondy_oplog_instance:root_hash(Id),
    ok = bondy_oplog_peer_state:record_sync_complete(
        {peer, fmw_cc_dummy}, Id, Root2
    ),
    bondy_oplog_peer_state:sync(),
    _ = bondy_oplog:compact(Id),
    Live = live_size(Id),
    ?debugFmt("concurrent compaction: final live_size=~p", [Live]),
    bondy_oplog_peer_state:forget_peer({peer, fmw_cc_dummy}),
    ?assert(Live < 5000),
    ok = bondy_db:close(Db).

%% Self-paced writer (one in-flight write at a time via `bondy_db:apply`, which
%% awaits its own install), striped by start offset so two writers don't collide
%% on keys. Self-pacing keeps the instance mailbox bounded (mirrors the bench's
%% append+await loop) while still applying continuous concurrent load — unlike a
%% pure fire-and-forget loop, which floods the mailbox and starves everything.
ff_writer(T, Id, N, Parent) ->
    receive
        stop -> Parent ! {writer_done, self()}
    after 0 ->
        K = list_to_binary("ck" ++ integer_to_list(N)),
        H = bondy_db:tick(T),
        _ = catch bondy_db:apply(T, <<"r">>, K, {set, H, <<"v">>}),
        ff_writer(T, Id, N + 2, Parent)
    end.

recv_done() ->
    receive
        {writer_done, _} -> ok
    after 5000 -> ok
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

open_fused_mem(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        %% `wal_backend => mem` rides `oplog_instance_opts` through to both the
        %% supervisor (which swaps the WAL child) and the instance (which
        %% dispatches the drain reader). Gated on `fused` by the supervisor.
        oplog_instance_opts => #{origin => Origin, wal_backend => mem}
    }),
    {ok, T} = bondy_db:open_table(Db, items, #{fused => true}),
    {Db, T, instance_of(T)}.

instance_of(Table) ->
    #{0 := InstanceId} = maps:get(instance_ids, Table),
    InstanceId.

key(I) ->
    list_to_binary("k" ++ integer_to_list(I)).

val_for(I) ->
    list_to_binary("v" ++ integer_to_list(I)).

val({ok, {V, _Hlc}}) -> V.

wait_live(Id, N) ->
    wait_until(fun() -> live_size(Id) >= N end, 5000).

live_size(Id) ->
    case bondy_oplog_registry:live_size(Id) of
        undefined -> 0;
        N -> N
    end.

wait_until(_Pred, Remaining) when Remaining =< 0 ->
    error(timeout);
wait_until(Pred, Remaining) ->
    case Pred() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_until(Pred, Remaining - 20)
    end.
