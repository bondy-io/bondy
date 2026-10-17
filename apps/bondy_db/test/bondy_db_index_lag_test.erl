%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Lag bound, back-pressure, backfill / rebuild.
%%
%% Covers:
%%   - rebuild from the primary repopulates a wiped index;
%%   - rebuild's clear-before-refold removes orphaned index terms;
%%   - back-pressure: a saturating dispatch is dropped (telemetry), the
%%     shard flagged, and a rebuild converges the index;
%%   - the `{stale_secondary, IndexName, Lag}` refusal carries the lag;
%%   - the `fallback => primary` primary-scan path returns correct rows
%%     while the index is stale;
%%   - `index_lag/2` diagnostics;
%%   - the startup backfill freshens every shard (so a finite `max_lag`
%%     range read passes over an empty index);
%%   - a rebuild whose writer lost the re-fold, or whose index was marked
%%     again while it ran, keeps the index marked and runs again;
%%   - a restarted writer replays the live ops its predecessor lost.
%% =============================================================================

-module(bondy_db_index_lag_test).

-include_lib("eunit/include/eunit.hrl").

-define(TOPOLOGY, bondy_db_topology_per_entity).

%% =============================================================================
%% Generators
%% =============================================================================

lag_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        test(
            "rebuild_after_clear_repopulates",
            fun rebuild_after_clear_repopulates/1
        ),
        test("rebuild_removes_orphans", fun rebuild_removes_orphans/1),
        test(
            "backfill_freshens_all_shards", fun backfill_freshens_all_shards/1
        ),
        test("stale_refusal_carries_lag", fun stale_refusal_carries_lag/1),
        test("primary_scan_fallback", fun primary_scan_fallback/1),
        test("index_lag_reports_fresh", fun index_lag_reports_fresh/1),
        test(
            "rebuild_keeps_mark_when_writer_lost_the_refold",
            fun rebuild_keeps_mark_when_writer_lost_the_refold/1
        ),
        test(
            "rebuild_keeps_mark_when_marked_during_run",
            fun rebuild_keeps_mark_when_marked_during_run/1
        ),
        test(
            "rebuild_keeps_mark_when_writer_wedged",
            fun rebuild_keeps_mark_when_writer_wedged/1
        ),
        test(
            "restarted_writer_replays_lost_ops",
            fun restarted_writer_replays_lost_ops/1
        ),
        test(
            "saturation_drops_then_rebuild_converges",
            fun saturation_drops_then_rebuild_converges/1
        ),
        test(
            "restarted_writer_keeps_coalesce_ms",
            fun restarted_writer_keeps_coalesce_ms/1
        ),
        test(
            "close_after_writer_restart_keeps_buffered_ops",
            fun close_after_writer_restart_keeps_buffered_ops/1
        ),
        test(
            "close_before_rebuild_keeps_lost_ops",
            fun close_before_rebuild_keeps_lost_ops/1
        ),
        test(
            "close_while_writer_sup_down",
            fun close_while_writer_sup_down/1
        ),
        test(
            "close_keeps_ops_applied_after_the_index_flush",
            fun close_keeps_ops_applied_after_the_index_flush/1
        )
    ]}.

test(Title, Fn) ->
    fun(Ctx) -> {Title, {timeout, 30, fun() -> Fn(Ctx) end}} end.

%% =============================================================================
%% Fixtures
%% =============================================================================

setup() ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(bondy_db),
    Dir = make_tempdir(),
    DbName = list_to_atom(
        "idx_lag_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(DbName, #{
        topology => ?TOPOLOGY,
        topology_opts => #{sup => Sup, dir => Dir},
        shard_count => 4,
        fold_module => lww_register
    }),
    {Db, Sup, Dir}.

cleanup({Db, Sup, Dir}) ->
    _ =
        try
            bondy_db:close(Db)
        catch
            _:_ -> ok
        end,
    _ = [
        try
            bondy_oplog:stop_instance(I)
        catch
            _:_ -> ok
        end
     || I <- bondy_oplog:list_instances()
    ],
    case is_process_alive(Sup) of
        true ->
            _ =
                try
                    bondy_db_leveled_sup:stop(Sup)
                catch
                    _:_ -> ok
                end;
        false ->
            ok
    end,
    rmrf(Dir),
    ok.

%% =============================================================================
%% Rebuild
%% =============================================================================

%% Wiping the index ETS and calling rebuild_index/2 re-materialises it from
%% the primary (the backfill path), not via the applier-replay helper.
rebuild_after_clear_repopulates({Db, _Sup, _Dir}) ->
    {ok, T} = open_lww(Db),
    R = <<"r1">>,
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = bondy_db:apply(T, R, <<"u2">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = flush_index(T, by_value),
    Before = bondy_db:index_get(T, R, by_value, <<"active">>, #{}),
    ?assertEqual({ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}]}, Before),

    clear_index(T, by_value),
    ?assertEqual(
        {ok, []}, bondy_db:index_get(T, R, by_value, <<"active">>, #{})
    ),

    ok = bondy_db:rebuild_index(T, by_value),
    ?assertEqual(
        Before, bondy_db:index_get(T, R, by_value, <<"active">>, #{})
    ),
    %% A finite max_lag read passes after the rebuild freshened the shard.
    ?assertEqual(
        Before,
        bondy_db:index_get(T, R, by_value, <<"active">>, #{max_lag => 60000})
    ),
    ok = bondy_db:close_table(T).

%% Rebuild clears each target shard before re-folding, so a term the
%% primary value no longer yields (injected directly here) does not survive.
rebuild_removes_orphans({Db, _Sup, _Dir}) ->
    {ok, T} = open_lww(Db),
    R = <<"r1">>,
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = flush_index(T, by_value),

    %% Inject an orphan: an index entry for a term the primary never had.
    inject_orphan(T, by_value, <<"ghost">>, <<"u9">>),
    ?assertMatch(
        {ok, [{<<"u9">>, _}]},
        bondy_db:index_get(T, R, by_value, <<"ghost">>, #{})
    ),

    ok = bondy_db:rebuild_index(T, by_value),
    %% The real term survives, the orphan is gone.
    ?assertEqual(
        {ok, [{<<"u1">>, #{}}]},
        bondy_db:index_get(T, R, by_value, <<"active">>, #{})
    ),
    ?assertEqual(
        {ok, []}, bondy_db:index_get(T, R, by_value, <<"ghost">>, #{})
    ),
    ok = bondy_db:close_table(T).

%% The startup backfill freshens every secondary shard, so a finite max_lag
%% range read over an empty index passes; empty shards are not sentinel-stale.
backfill_freshens_all_shards({Db, _Sup, _Dir}) ->
    {ok, T} = open_lww(Db),
    R = <<"r1">>,
    ?assertEqual(
        {ok, []},
        bondy_db:index_range(T, R, by_value, <<"a">>, <<"z">>, #{
            max_lag => 60000
        })
    ),
    {ok, Lags} = bondy_db:index_lag(T, by_value),
    maps:foreach(
        fun(_Shard, #{lag := Lag, needs_rebuild := NR}) ->
            ?assert(is_integer(Lag)),
            ?assertNot(NR)
        end,
        Lags
    ),
    ok = bondy_db:close_table(T).

%% =============================================================================
%% Stale refusal + lag diagnostics + primary-scan fallback
%% =============================================================================

stale_refusal_carries_lag({Db, _Sup, _Dir}) ->
    {ok, T} = open_lww(Db),
    R = <<"r1">>,
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = flush_index(T, by_value),
    mark_all_rebuild(T, by_value),
    ?assertMatch(
        {error, {stale_secondary, by_value, infinity}},
        bondy_db:index_get(T, R, by_value, <<"active">>, #{max_lag => 0})
    ),
    {ok, Lags} = bondy_db:index_lag(T, by_value),
    ?assert(
        lists:any(
            fun(#{needs_rebuild := NR}) -> NR end, maps:values(Lags)
        )
    ),
    ok = bondy_db:close_table(T).

primary_scan_fallback({Db, _Sup, _Dir}) ->
    {ok, T} = open_lww(Db),
    R = <<"r1">>,
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = bondy_db:apply(T, R, <<"u2">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = bondy_db:apply(T, R, <<"u3">>, {set, bondy_db:tick(T), <<"idle">>}),
    ok = flush_index(T, by_value),
    %% Force the index stale, then the secondary read refuses but the
    %% primary-scan fallback still returns the correct rows.
    mark_all_rebuild(T, by_value),
    ?assertMatch(
        {error, {stale_secondary, by_value, infinity}},
        bondy_db:index_get(T, R, by_value, <<"active">>, #{max_lag => 0})
    ),
    ?assertEqual(
        {ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}]},
        bondy_db:index_get(T, R, by_value, <<"active">>, #{
            max_lag => 0, fallback => primary
        })
    ),
    ?assertEqual(
        {ok, [{<<"u3">>, #{}}]},
        bondy_db:index_get(T, R, by_value, <<"idle">>, #{
            max_lag => 0, fallback => primary
        })
    ),
    %% Range fallback, half-open [active, idle): only "active".
    ?assertEqual(
        {ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}]},
        bondy_db:index_range(T, R, by_value, <<"active">>, <<"idle">>, #{
            max_lag => 0, fallback => primary
        })
    ),
    ok = bondy_db:close_table(T).

index_lag_reports_fresh({Db, _Sup, _Dir}) ->
    {ok, T} = open_lww(Db),
    R = <<"r1">>,
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = flush_index(T, by_value),
    {ok, Lags} = bondy_db:index_lag(T, by_value),
    maps:foreach(
        fun(_Shard, Info) ->
            ?assertMatch(#{lag := _, inflight := _, needs_rebuild := _}, Info),
            ?assertEqual(0, maps:get(inflight, Info)),
            ?assertNot(maps:get(needs_rebuild, Info)),
            ?assert(is_integer(maps:get(lag, Info)))
        end,
        Lags
    ),
    ok = bondy_db:close_table(T).

%% =============================================================================
%% Back-pressure
%% =============================================================================

%% A tiny in-flight cap with auto-flush disabled: repeated updates to one
%% indexed term overflow the writer backlog, the dispatch is dropped (a
%% `saturated` telemetry event fires), and a rebuild converges the index.
saturation_drops_then_rebuild_converges({Db, _Sup, _Dir}) ->
    {ok, T} = open_saturating(Db),
    R = <<"r1">>,
    K = <<"u1">>,
    Self = self(),
    HandlerId = {?MODULE, saturated, erlang:unique_integer()},
    ok = telemetry:attach(
        HandlerId,
        [bondy_oplog, secondary_writer, saturated],
        fun(_E, _M, Meta, _C) -> Self ! {saturated, Meta} end,
        undefined
    ),
    try
        %% First set the indexed field, then push several updates to a
        %% NON-indexed field — each re-dispatches a put for the same term
        %% "active", growing the (never-flushed) backlog past the cap.
        ok = bondy_db:apply(T, R, K, {put, <<"status">>, <<"active">>}),
        lists:foreach(
            fun(N) ->
                Name = <<"n", (integer_to_binary(N))/binary>>,
                ok = bondy_db:apply(T, R, K, {put, <<"name">>, Name})
            end,
            lists:seq(1, 8)
        ),
        receive
            {saturated, _Meta} -> ok
        after 5000 ->
            ?assert(false)
        end
    after
        telemetry:detach(HandlerId)
    end,

    %% Rebuild (barrier; also drains any autonomous rebuild the drop
    %% requested) converges the index to the live working set.
    ok = bondy_db:rebuild_index(T, by_status),
    ?assertMatch(
        {ok, [{<<"u1">>, _}]},
        bondy_db:index_get(T, R, by_status, <<"active">>, #{max_lag => 60000})
    ),
    {ok, [{<<"u1">>, Cols}]} =
        bondy_db:index_get(T, R, by_status, <<"active">>, #{}),
    %% The rebuild's projected column EXACTLY matches the live cell value
    %% (`[n8]`), with no spurious siblings. The rebuild re-indexes from the
    %% converged projection value rather than replaying historical events
    %% (which, on a context-carrying tier_2 CRDT, would re-introduce
    %% superseded dots as spurious MV-leaf siblings — e.g. `[n7, n8]`). See
    %% `bondy_db_tier2_index_rebuild_test` for the dedicated regression.
    ?assertEqual([<<"n8">>], maps:get([<<"name">>], Cols)),
    ok = bondy_db:close_table(T).

%% A writer that `bondy_oplog_secondary_sup` re-creates from the registry keeps
%% its index's `coalesce_ms`: under the 600 s window of `open_saturating/1` an
%% indexed write stays in flight until `flush_sync`, where the 5 ms default
%% would have flushed it within the 200 ms wait. A rebuild's reset and a
%% compaction cycle's flush would also empty the count, so the rebuild server
%% is held until the check and the compaction trigger is quiesced.
restarted_writer_keeps_coalesce_ms({Db, _Sup, _Dir}) ->
    {ok, T} = open_saturating(Db),
    ok = bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok = sys:suspend(bondy_oplog_index_rebuild),
    try
        SecSup = whereis(bondy_oplog_secondary_sup),
        Ref = monitor(process, SecSup),
        exit(SecSup, kill),
        receive
            {'DOWN', Ref, process, SecSup, _} -> ok
        end,
        ok = wait_for_new(bondy_oplog_secondary_sup, SecSup, 200),
        ok = bondy_db:apply(
            T, <<"r1">>, <<"u1">>, {put, <<"status">>, <<"on">>}
        ),
        timer:sleep(200),
        ?assert(inflight(T, by_status) > 0),
        ok = flush_index(T, by_status),
        ?assertEqual(0, inflight(T, by_status))
    after
        ok = sys:resume(bondy_oplog_index_rebuild)
    end,
    ok = bondy_db:close_table(T).

%% An op buffered in a writer re-created by a `bondy_oplog_secondary_sup`
%% restart survives a graceful close and reopen without a rebuild: the close
%% discards the buffer, and the open replays the op from the primary's intent
%% and flushes it before it freshens the trusted index.
close_after_writer_restart_keeps_buffered_ops({Db, _Sup, _Dir}) ->
    {ok, T0} = open_saturating(Db),
    NS = maps:get(namespace, bondy_db:info(T0)),
    ok = restart_writer_sup(),
    %% Barriers: the restarted supervisor's `init/1` has started its writers,
    %% and the index is trusted.
    _ = sys:get_state(bondy_oplog_secondary_sup),
    ok = wait_trusted(T0, by_status, 200),
    ok = bondy_db:apply(T0, <<"r1">>, <<"u1">>, {put, <<"status">>, <<"on">>}),
    ?assert(inflight(T0, by_status) > 0),
    ok = bondy_db:close_table(T0),
    Self = self(),
    HandlerId = {?MODULE, rebuild, erlang:unique_integer()},
    ok = telemetry:attach(
        HandlerId,
        [bondy_oplog, secondary_index, rebuild],
        fun(_E, _M, Meta, _C) -> Self ! {rebuilt, Meta} end,
        undefined
    ),
    {ok, T1} =
        try
            open_saturating(Db)
        after
            telemetry:detach(HandlerId)
        end,
    ?assertMatch(
        {ok, [{<<"u1">>, _}]},
        bondy_db:index_get(T1, <<"r1">>, by_status, <<"on">>, #{})
    ),
    ?assertEqual(
        none,
        receive
            {rebuilt, #{namespace := NS, index_name := by_status}} -> rebuilt
        after 0 -> none
        end
    ),
    ok = bondy_db:close_table(T1).

%% An op dispatched while no writer ran must survive a close made before any
%% rebuild could run: the restarted writer replays it from the primary's
%% intent. The rebuild orchestrator is held suspended until the close has
%% returned.
close_before_rebuild_keeps_lost_ops({Db, _Sup, _Dir}) ->
    {ok, T0} = open_lww(Db),
    R = <<"r1">>,
    ok = sys:suspend(bondy_oplog_index_rebuild),
    try
        ok = sys:suspend(bondy_oplog_sup),
        SecSup = whereis(bondy_oplog_secondary_sup),
        Ref = monitor(process, SecSup),
        exit(SecSup, kill),
        receive
            {'DOWN', Ref, process, SecSup, _} -> ok
        end,
        ok = bondy_db:apply(
            T0, R, <<"gap">>, {set, bondy_db:tick(T0), <<"g">>}
        ),
        ok = sys:resume(bondy_oplog_sup),
        ok = wait_for_new(bondy_oplog_secondary_sup, SecSup, 200),
        ok = bondy_db:close_table(T0)
    after
        ok = sys:resume(bondy_oplog_index_rebuild)
    end,
    {ok, T1} = open_lww(Db),
    ?assertEqual(
        {ok, [{<<"gap">>, #{}}]},
        bondy_db:index_get(T1, R, by_value, <<"g">>, #{})
    ),
    ok = bondy_db:close_table(T1).

%% A table closed while `bondy_oplog_secondary_sup` is down (between its exit
%% and `bondy_oplog_sup` restarting it) must close, and the restarted supervisor
%% must not re-create the closed table's writers.
close_while_writer_sup_down({Db, _Sup, _Dir}) ->
    {ok, T} = open_saturating(Db),
    ok = sys:suspend(bondy_oplog_sup),
    SecSup = whereis(bondy_oplog_secondary_sup),
    Ref = monitor(process, SecSup),
    exit(SecSup, kill),
    receive
        {'DOWN', Ref, process, SecSup, _} -> ok
    end,
    Closed =
        try
            bondy_db:close_table(T)
        catch
            Class:Reason -> {Class, Reason}
        after
            ok = sys:resume(bondy_oplog_sup)
        end,
    ok = wait_for_new(bondy_oplog_secondary_sup, SecSup, 200),
    ?assertEqual(ok, Closed),
    ?assertEqual([], supervisor:which_children(bondy_oplog_secondary_sup)).

%% A write still waiting in the WAL when the table closes is applied by the
%% instance's applier while the close runs, released here as the close stops
%% the instance. The reopened index is trusted, so it must hold that write: the
%% open replays it from the primary's intent and flushes it.
close_keeps_ops_applied_after_the_index_flush({Db, _Sup, _Dir}) ->
    {ok, T0} = open_lww(Db),
    R = <<"r1">>,
    InstanceIds = maps:values(maps:get(instance_ids, T0)),
    Appliers = [bondy_oplog_registry:applier_pid(I) || I <- InstanceIds],
    ok = meck:new(bondy_oplog, [passthrough]),
    try
        [ok = sys:suspend(A) || A <- Appliers],
        ok = bondy_db:apply_async(
            T0, R, <<"late">>, {set, bondy_db:tick(T0), <<"l">>}
        ),
        Resumed = atomics:new(1, []),
        ok = meck:expect(bondy_oplog, stop_instance, fun(Id) ->
            _ =
                atomics:add_get(Resumed, 1, 1) =:= 1 andalso
                    [ok = sys:resume(A) || A <- Appliers],
            _ = bondy_oplog_instance:await_apply(Id),
            meck:passthrough([Id])
        end),
        ok = bondy_db:close_table(T0)
    after
        meck:unload(bondy_oplog)
    end,
    {ok, T1} = open_lww(Db),
    ?assertEqual(
        {ok, {<<"l">>, '_'}},
        case bondy_db:read(T1, R, <<"late">>) of
            {ok, {V, _}} -> {ok, {V, '_'}};
            Other -> Other
        end
    ),
    ?assertEqual(
        {ok, [{<<"late">>, #{}}]},
        bondy_db:index_get(T1, R, by_value, <<"l">>, #{})
    ),
    ok = bondy_db:close_table(T1).

%% =============================================================================
%% Rebuild completion
%% =============================================================================

%% The writers die holding the re-folded ops, before the rebuild flushes them.
%% The rebuild must not mark the index trusted: it returns `incomplete`, and
%% the rebuild that runs again restores every row.
rebuild_keeps_mark_when_writer_lost_the_refold({Db, _Sup, _Dir}) ->
    {ok, T} = open_buffered(Db),
    R = <<"r1">>,
    Keys = [<<"u1">>, <<"u2">>, <<"u3">>],
    [
        ok = bondy_db:apply(T, R, K, {set, bondy_db:tick(T), <<"on">>})
     || K <- Keys
    ],
    ok = flush_index(T, by_value),
    Expected = {ok, [{K, #{}} || K <- Keys]},
    ?assertEqual(Expected, bondy_db:index_get(T, R, by_value, <<"on">>, #{})),
    with_flush_hook(
        fun(_) -> ok = restart_writers(T, by_value) end,
        fun() ->
            ?assertEqual(
                {error, incomplete}, bondy_db:rebuild_index(T, by_value)
            ),
            ok = wait_trusted(T, by_value, 200)
        end
    ),
    ?assertEqual(Expected, bondy_db:index_get(T, R, by_value, <<"on">>, #{})),
    ok = bondy_db:close_table(T).

%% A writer that cannot flush within the rebuild's deadline, and does not
%% restart, leaves nothing marked after the wipe; the failed flush alone must
%% keep the index untrusted until a rebuild completes.
rebuild_keeps_mark_when_writer_wedged({Db, _Sup, _Dir}) ->
    {ok, T} = open_buffered(Db),
    R = <<"r1">>,
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"on">>}),
    ok = flush_index(T, by_value),
    Self = self(),
    with_flush_hook(
        fun(Pid) ->
            ok = sys:suspend(Pid),
            Self ! {wedged, Pid}
        end,
        fun() ->
            ?assertEqual(
                {error, incomplete}, bondy_db:rebuild_index(T, by_value)
            ),
            ?assert(lists:any(fun needs_rebuild/1, entries(T, by_value))),
            receive
                {wedged, Pid} -> ok = sys:resume(Pid)
            end,
            ok = wait_trusted(T, by_value, 200)
        end
    ),
    ?assertEqual(
        {ok, [{<<"u1">>, #{}}]},
        bondy_db:index_get(T, R, by_value, <<"on">>, #{})
    ),
    ok = bondy_db:close_table(T).

%% A mark that arrives while a rebuild runs (a saturation drop, a writer
%% restart) must survive it: the rebuild returns `incomplete` with the shards
%% still marked and their trust markers absent, and the rebuild that runs
%% again restores the markers.
rebuild_keeps_mark_when_marked_during_run({Db, _Sup, _Dir}) ->
    {ok, T} = open_buffered(Db),
    R = <<"r1">>,
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"on">>}),
    ok = flush_index(T, by_value),
    with_flush_hook(
        fun(_) -> ok = mark_all_rebuild(T, by_value) end,
        fun() ->
            ?assertEqual(
                {error, incomplete}, bondy_db:rebuild_index(T, by_value)
            ),
            ?assert(lists:all(fun needs_rebuild/1, entries(T, by_value))),
            ?assertNot(lists:any(fun has_trust_marker/1, entries(T, by_value))),
            ok = wait_trusted(T, by_value, 200)
        end
    ),
    ?assert(lists:all(fun has_trust_marker/1, entries(T, by_value))),
    ?assertEqual(
        {ok, [{<<"u1">>, #{}}]},
        bondy_db:index_get(T, R, by_value, <<"on">>, #{})
    ),
    ok = bondy_db:close_table(T).

%% A writer killed while it buffers an op loses it; its restart replays the op
%% from the primary's intent, without marking the shards. The rebuild server
%% is held throughout, so no rebuild can be what delivers the op.
restarted_writer_replays_lost_ops({Db, _Sup, _Dir}) ->
    {ok, T} = open_buffered(Db),
    R = <<"r1">>,
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"on">>}),
    ok = sys:suspend(bondy_oplog_index_rebuild),
    try
        ok = restart_writers(T, by_value),
        ?assertNot(lists:any(fun needs_rebuild/1, entries(T, by_value))),
        ok = flush_index(T, by_value),
        ?assertEqual(0, inflight(T, by_value)),
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}]},
            bondy_db:index_get(T, R, by_value, <<"on">>, #{})
        )
    after
        ok = sys:resume(bondy_oplog_index_rebuild)
    end,
    ok = bondy_db:close_table(T).

%% Runs `Body` while the rebuild's first
%% `bondy_oplog_secondary_writer:flush_entry/2` call first runs `Hook(Pid)` on
%% the writer it targets. Calls from other processes, such as an instance's
%% compaction flush barrier, pass through without the hook.
with_flush_hook(Hook, Body) ->
    Once = atomics:new(1, []),
    Rebuild = whereis(bondy_oplog_index_rebuild),
    ok = meck:new(bondy_oplog_secondary_writer, [passthrough]),
    try
        ok = meck:expect(
            bondy_oplog_secondary_writer, flush_entry, fun(Entry, Timeout) ->
                Pid = bondy_oplog_core_registry:entry_writer_pid(Entry),
                %% The orchestrator runs each rebuild in a worker it spawns.
                {parent, Parent} = process_info(self(), parent),
                _ =
                    Parent =:= Rebuild andalso
                        atomics:add_get(Once, 1, 1) =:= 1 andalso Hook(Pid),
                meck:passthrough([Entry, Timeout])
            end
        ),
        Body()
    after
        meck:unload(bondy_oplog_secondary_writer)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

restart_writers(Table, IndexName) ->
    Old = [
        bondy_oplog_core_registry:entry_writer_pid(E)
     || E <- entries(Table, IndexName)
    ],
    [exit(Pid, kill) || Pid <- Old],
    wait_until(
        fun() ->
            New = [
                bondy_oplog_core_registry:entry_writer_pid(E)
             || E <- entries(Table, IndexName)
            ],
            lists:all(
                fun(P) ->
                    is_pid(P) andalso is_process_alive(P) andalso
                        not lists:member(P, Old)
                end,
                New
            )
        end,
        200
    ).

wait_trusted(Table, IndexName, Tries) ->
    wait_until(
        fun() ->
            not lists:any(fun needs_rebuild/1, entries(Table, IndexName))
        end,
        Tries
    ).

wait_until(Fun, 0) ->
    error({timeout, Fun});
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, N - 1)
    end.

needs_rebuild(Entry) ->
    bondy_oplog_core_registry:index_needs_rebuild(Entry).

has_trust_marker(Entry) ->
    {NS, IndexName, Shard} = bondy_oplog_core_registry:entry_key(Entry),
    {B, K} = bondy_oplog_index_key:trust_marker_loc(NS, IndexName, Shard),
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
    case Adapter:get(Handle, B, K) of
        {ok, _} -> true;
        not_found -> false
    end.

entries(Table, IndexName) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{IndexName := #{sec_shard_count := N}} = maps:get(indexes, Info),
    [
        Entry
     || Shard <- lists:seq(0, N - 1),
        {ok, Entry} <- [bondy_oplog_core_registry:lookup(NS, IndexName, Shard)]
    ].

open_buffered(Db) ->
    bondy_db:open_table(Db, users, #{
        fold_module => lww_register,
        indexes => [
            #{name => by_value, extract => [], coalesce_ms => 600000}
        ]
    }).

restart_writer_sup() ->
    SecSup = whereis(bondy_oplog_secondary_sup),
    Ref = monitor(process, SecSup),
    exit(SecSup, kill),
    receive
        {'DOWN', Ref, process, SecSup, _} -> ok
    end,
    wait_for_new(bondy_oplog_secondary_sup, SecSup, 200).

wait_for_new(Name, Old, 0) ->
    error({not_restarted, Name, Old});
wait_for_new(Name, Old, N) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= Old ->
            ok;
        _ ->
            timer:sleep(10),
            wait_for_new(Name, Old, N - 1)
    end.

inflight(Table, IndexName) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{IndexName := #{sec_shard_count := N}} = maps:get(indexes, Info),
    lists:sum([
        bondy_oplog_core_registry:index_inflight(Entry)
     || Shard <- lists:seq(0, N - 1),
        {ok, Entry} <- [bondy_oplog_core_registry:lookup(NS, IndexName, Shard)]
    ]).

open_lww(Db) ->
    bondy_db:open_table(Db, users, #{
        fold_module => lww_register,
        indexes => [#{name => by_value, extract => []}]
    }).

open_saturating(Db) ->
    bondy_db:open_table(Db, profiles, #{
        fold_module => lww_register,
        crdt_module => bondy_oplog_crdt_aw_map,
        indexes => [
            #{
                name => by_status,
                extract => [<<"status">>],
                projects => [[<<"name">>]],
                %% Tiny cap + auto-flush effectively off, so the backlog
                %% overflows deterministically before any flush.
                max_inflight => 2,
                coalesce_ms => 600000
            }
        ]
    }).

flush_index(Table, IndexName) ->
    foreach_shard(Table, IndexName, fun(_NS, _Sh, Pid, _Entry) ->
        ok = bondy_oplog_secondary_writer:flush_sync(Pid)
    end).

clear_index(Table, IndexName) ->
    foreach_shard(Table, IndexName, fun(_NS, _Sh, _Pid, Entry) ->
        %% Backend-agnostic: use the projection adapter's clear/2 (both the
        %% ets and leveled adapters export it) rather than assuming an ETS
        %% handle — durable tables back their indices with leveled. Use the
        %% entry's own `clear_scope()` (what the rebuild passes) so the wipe
        %% is correctly entity-scoped on a shared Bookie.
        Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
        Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
        Scope =
            case bondy_oplog_core_registry:entry_index_clear_scope(Entry) of
                undefined -> {suffix, IndexName};
                S -> S
            end,
        ok = Adapter:clear(Handle, Scope)
    end).

mark_all_rebuild(Table, IndexName) ->
    foreach_shard(Table, IndexName, fun(_NS, _Sh, _Pid, Entry) ->
        ok = bondy_oplog_core_registry:index_mark_rebuild(Entry)
    end).

%% Insert an index entry directly (bypassing the writer) so a rebuild can
%% be shown to remove it.
inject_orphan(Table, IndexName, Term, PrimaryKey) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{IndexName := #{sec_shard_count := N}} = maps:get(indexes, Info),
    SecBucket = index_sec_bucket(Table, <<"r1">>, IndexName),
    Shard = bondy_oplog_index_key:shard(SecBucket, Term, N),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, IndexName, Shard),
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
    SecKey = bondy_oplog_index_key:encode(Term, PrimaryKey),
    Hlc = 1,
    State = {live, <<>>, Hlc},
    Frame = bondy_oplog_cell_frame:encode(
        Hlc,
        bondy_oplog_crdt_index_entry:encode_state(State),
        undefined,
        true
    ),
    ok = Adapter:put_batch(Handle, [{SecBucket, SecKey, Frame}]).

index_sec_bucket(Table, Realm, IndexName) ->
    #{db_topology := Topology, table_state := TableState, entity_type := ET} =
        Table,
    PrimaryBucket = Topology:bucket_for(ET, Realm, TableState),
    bondy_oplog_index_key:bucket(PrimaryBucket, IndexName).

foreach_shard(Table, IndexName, Fun) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{IndexName := #{sec_shard_count := N}} = maps:get(indexes, Info),
    lists:foreach(
        fun(Shard) ->
            {ok, Entry} = bondy_oplog_core_registry:lookup(
                NS, IndexName, Shard
            ),
            Pid = bondy_oplog_core_registry:entry_writer_pid(Entry),
            Fun(NS, Shard, Pid, Entry)
        end,
        lists:seq(0, N - 1)
    ).

make_tempdir() ->
    Base = filename:join([
        "/tmp/" ++ os:getpid(),
        "bondy_db_index_lag_test",
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

rmrf(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.
