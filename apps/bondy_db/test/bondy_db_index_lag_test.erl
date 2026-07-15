%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% IDX-4 — lag bound, back-pressure, backfill / rebuild.
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
%%     range read passes over an empty index — the IDX-3 carry-over #4).
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
            "saturation_drops_then_rebuild_converges",
            fun saturation_drops_then_rebuild_converges/1
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
    _ = catch bondy_db:close(Db),
    _ = [
        catch bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    case is_process_alive(Sup) of
        true -> _ = catch bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    rmrf(Dir),
    ok.

%% =============================================================================
%% Rebuild
%% =============================================================================

%% Wiping the index ETS and calling rebuild_index/2 re-materialises it from
%% the primary (the backfill path), not via the IDX-3 applier-replay helper.
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
%% range read over an empty index passes (resolves the IDX-3 carry-over #4
%% where empty shards stayed sentinel-stale).
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

%% =============================================================================
%% Helpers
%% =============================================================================

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
        "/tmp",
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
