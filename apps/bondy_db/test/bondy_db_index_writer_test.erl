%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% IDX-3 — secondary writer + dispatch (end-to-end).
%%
%% Drives the real path: `bondy_db:apply/4` → primary applier
%% `compute_one_cell` term-diff → `bondy_oplog_secondary_writer` →
%% `index_get`/`index_range`. Covers a pointer-only `lww_register` value
%% index and an `aw_map` field-extract index (with denormalised columns),
%% term-change retraction, multi-key/same-term ordering, the `{max_lag}`
%% gate clearing once the writer flushes, the writer's registry pid stamp,
%% and a rebuild of a cleared index by replaying the primary MST (the
%% `apply_cell_pairs` dispatch path).
%%
%% `flush_index/2` is a deterministic barrier: it `flush_sync`s every
%% secondary shard's writer, and because casts are processed in arrival
%% order, all index ops dispatched by the (already-awaited) `apply/4`s are
%% materialised before it returns — no polling, no sleeps.
%% =============================================================================

-module(bondy_db_index_writer_test).

-include_lib("eunit/include/eunit.hrl").

-define(TOPOLOGY, bondy_db_topology_per_entity).

%% =============================================================================
%% Generators
%% =============================================================================

writer_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        test("lww_value_index_populates", fun lww_value_index_populates/1),
        test("lww_value_change_retracts", fun lww_value_change_retracts/1),
        test("lww_multi_key_same_term", fun lww_multi_key_same_term/1),
        test(
            "lww_index_range_after_writes", fun lww_index_range_after_writes/1
        ),
        test(
            "backfill_freshens_empty_index", fun backfill_freshens_empty_index/1
        ),
        test("writer_pid_registered", fun writer_pid_registered/1),
        test("aw_map_field_extract_index", fun aw_map_field_extract_index/1),
        test(
            "aw_map_status_change_retracts", fun aw_map_status_change_retracts/1
        ),
        test(
            "replay_rebuilds_cleared_index", fun replay_rebuilds_cleared_index/1
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
        "idx_writer_" ++ integer_to_list(erlang:unique_integer([positive]))
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
%% lww_register — index on the whole (binary) value
%% =============================================================================

lww_value_index_populates({Db, _Sup, _Dir}) ->
    {ok, T} = open_lww(Db),
    R = <<"r1">>,
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = flush_index(T, by_value),
    ?assertEqual(
        {ok, [{<<"u1">>, #{}}]},
        bondy_db:index_get(T, R, by_value, <<"active">>, #{})
    ),
    ?assertEqual(
        {ok, []}, bondy_db:index_get(T, R, by_value, <<"idle">>, #{})
    ),
    ok = bondy_db:close_table(T).

lww_value_change_retracts({Db, _Sup, _Dir}) ->
    {ok, T} = open_lww(Db),
    R = <<"r1">>,
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = flush_index(T, by_value),
    ?assertMatch(
        {ok, [{<<"u1">>, _}]},
        bondy_db:index_get(T, R, by_value, <<"active">>, #{})
    ),
    %% Change the value: the old term retracts, the new term appears.
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"idle">>}),
    ok = flush_index(T, by_value),
    ?assertEqual(
        {ok, []}, bondy_db:index_get(T, R, by_value, <<"active">>, #{})
    ),
    ?assertEqual(
        {ok, [{<<"u1">>, #{}}]},
        bondy_db:index_get(T, R, by_value, <<"idle">>, #{})
    ),
    ok = bondy_db:close_table(T).

lww_multi_key_same_term({Db, _Sup, _Dir}) ->
    {ok, T} = open_lww(Db),
    R = <<"r1">>,
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = bondy_db:apply(T, R, <<"u2">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = bondy_db:apply(T, R, <<"u3">>, {set, bondy_db:tick(T), <<"idle">>}),
    ok = flush_index(T, by_value),
    %% Both active keys land in the same (term-sharded) secondary shard and
    %% come back in primary-key order.
    ?assertEqual(
        {ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}]},
        bondy_db:index_get(T, R, by_value, <<"active">>, #{})
    ),
    ?assertEqual(
        {ok, [{<<"u3">>, #{}}]},
        bondy_db:index_get(T, R, by_value, <<"idle">>, #{})
    ),
    ok = bondy_db:close_table(T).

lww_index_range_after_writes({Db, _Sup, _Dir}) ->
    {ok, T} = open_lww(Db),
    R = <<"r1">>,
    ok = bondy_db:apply(T, R, <<"u_a">>, {set, bondy_db:tick(T), <<"a">>}),
    ok = bondy_db:apply(T, R, <<"u_b">>, {set, bondy_db:tick(T), <<"b">>}),
    ok = bondy_db:apply(T, R, <<"u_c">>, {set, bondy_db:tick(T), <<"c">>}),
    ok = flush_index(T, by_value),
    %% Half-open [a, c): a and b, not c. Globally ordered by (term, pk).
    ?assertEqual(
        {ok, [{<<"u_a">>, #{}}, {<<"u_b">>, #{}}]},
        bondy_db:index_range(T, R, by_value, <<"a">>, <<"c">>, #{})
    ),
    ok = bondy_db:close_table(T).

%% Since IDX-4 the mandatory startup backfill freshens every secondary
%% shard at open, so a finite max_lag read of the (empty) index passes
%% immediately — it is fresh, not "stale until first write". A subsequent
%% write+flush surfaces the row, still fresh.
backfill_freshens_empty_index({Db, _Sup, _Dir}) ->
    {ok, T} = open_lww(Db),
    R = <<"r1">>,
    ?assertEqual(
        {ok, []},
        bondy_db:index_get(T, R, by_value, <<"active">>, #{max_lag => 60000})
    ),
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = flush_index(T, by_value),
    ?assertMatch(
        {ok, [{<<"u1">>, #{}}]},
        bondy_db:index_get(T, R, by_value, <<"active">>, #{max_lag => 60000})
    ),
    ok = bondy_db:close_table(T).

writer_pid_registered({Db, _Sup, _Dir}) ->
    {ok, T} = open_lww(Db),
    NS = maps:get(namespace, bondy_db:info(T)),
    #{by_value := #{sec_shard_count := N}} = maps:get(
        indexes, bondy_db:info(T)
    ),
    lists:foreach(
        fun(Shard) ->
            {ok, Entry} = bondy_oplog_core_registry:lookup(NS, by_value, Shard),
            Pid = bondy_oplog_core_registry:entry_writer_pid(Entry),
            ?assert(is_pid(Pid)),
            ?assert(is_process_alive(Pid))
        end,
        lists:seq(0, N - 1)
    ),
    ok = bondy_db:close_table(T).

%% =============================================================================
%% aw_map — field-extract index with denormalised columns
%% =============================================================================

aw_map_field_extract_index({Db, _Sup, _Dir}) ->
    {ok, T} = open_aw_map(Db),
    R = <<"r1">>,
    K = <<"u1">>,
    %% Set a projected (non-indexed) field first, then the indexed one, so
    %% the single `put` of term "active" already carries the columns.
    ok = bondy_db:apply(T, R, K, {put, <<"name">>, <<"alice">>}),
    ok = bondy_db:apply(T, R, K, {put, <<"status">>, <<"active">>}),
    ok = flush_index(T, by_status),
    %% Projected column is the MV-leaf sibling list (`[<<"alice">>]`), not
    %% the bare value — the native map's projection shape.
    ?assertEqual(
        {ok, [{<<"u1">>, #{[<<"name">>] => [<<"alice">>]}}]},
        bondy_db:index_get(T, R, by_status, <<"active">>, #{})
    ),
    ok = bondy_db:close_table(T).

aw_map_status_change_retracts({Db, _Sup, _Dir}) ->
    {ok, T} = open_aw_map(Db),
    R = <<"r1">>,
    K = <<"u1">>,
    ok = bondy_db:apply(T, R, K, {put, <<"name">>, <<"alice">>}),
    ok = bondy_db:apply(T, R, K, {put, <<"status">>, <<"active">>}),
    ok = flush_index(T, by_status),
    ?assertMatch(
        {ok, [{<<"u1">>, _}]},
        bondy_db:index_get(T, R, by_status, <<"active">>, #{})
    ),
    %% Re-put the status field. The new put observes the prior one
    %% (read-your-writes) and dominates, so the old "active" dot is
    %% dropped — the indexed term changes to "inactive".
    ok = bondy_db:apply(T, R, K, {put, <<"status">>, <<"inactive">>}),
    ok = flush_index(T, by_status),
    ?assertEqual(
        {ok, []}, bondy_db:index_get(T, R, by_status, <<"active">>, #{})
    ),
    ?assertEqual(
        {ok, [{<<"u1">>, #{[<<"name">>] => [<<"alice">>]}}]},
        bondy_db:index_get(T, R, by_status, <<"inactive">>, #{})
    ),
    ok = bondy_db:close_table(T).

%% =============================================================================
%% Replay path (apply_cell_pairs dispatch): clearing the ETS index and
%% replaying the primary MST rebuilds identical entries.
%% =============================================================================

replay_rebuilds_cleared_index({Db, _Sup, _Dir}) ->
    {ok, T} = open_lww(Db),
    R = <<"r1">>,
    ok = bondy_db:apply(T, R, <<"u1">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = bondy_db:apply(T, R, <<"u2">>, {set, bondy_db:tick(T), <<"active">>}),
    ok = flush_index(T, by_value),
    Before = bondy_db:index_get(T, R, by_value, <<"active">>, #{}),
    ?assertEqual({ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}]}, Before),

    %% Wipe the secondary projection tables out from under the index.
    clear_index(T, by_value),
    ?assertEqual(
        {ok, []}, bondy_db:index_get(T, R, by_value, <<"active">>, #{})
    ),

    %% Replay every primary shard's MST: `last_replayed_root` is still
    %% `undefined` (no peer sync happened), so this is a full re-fold
    %% through `apply_cell_pairs`, which re-dispatches every index op.
    replay_all(T),
    ok = flush_index(T, by_value),
    ?assertEqual(
        Before, bondy_db:index_get(T, R, by_value, <<"active">>, #{})
    ),
    ok = bondy_db:close_table(T).

%% =============================================================================
%% Helpers
%% =============================================================================

open_lww(Db) ->
    bondy_db:open_table(Db, users, #{
        fold_module => lww_register,
        indexes => [#{name => by_value, extract => []}]
    }).

%% Native tier_2 add-wins map. `fold_module` is mandatory at open but
%% vestigial when a `crdt_module` is set (the kernel selects the CRDT).
%% Its projection is `#{MapKey => [SiblingValue, ...]}`, so an extracted
%% field is a (usually singleton) list — the index spec turns a list leaf
%% into one term per element, and a projected column is the list itself.
open_aw_map(Db) ->
    bondy_db:open_table(Db, profiles, #{
        fold_module => lww_register,
        crdt_module => bondy_oplog_crdt_aw_map,
        indexes => [
            #{
                name => by_status,
                extract => [<<"status">>],
                projects => [[<<"name">>]]
            }
        ]
    }).

%% Deterministic barrier: synchronously flush every secondary-shard writer.
flush_index(Table, IndexName) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{IndexName := #{sec_shard_count := N}} = maps:get(indexes, Info),
    lists:foreach(
        fun(Shard) ->
            {ok, Entry} = bondy_oplog_core_registry:lookup(
                NS, IndexName, Shard
            ),
            Pid = bondy_oplog_core_registry:entry_writer_pid(Entry),
            true = is_pid(Pid),
            ok = bondy_oplog_secondary_writer:flush_sync(Pid)
        end,
        lists:seq(0, N - 1)
    ).

%% Wipe every secondary shard's projection directly (test-only).
clear_index(Table, IndexName) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{IndexName := #{sec_shard_count := N}} = maps:get(indexes, Info),
    lists:foreach(
        fun(Shard) ->
            {ok, Entry} = bondy_oplog_core_registry:lookup(
                NS, IndexName, Shard
            ),
            %% Backend-agnostic: the durable table backs its indices with
            %% leveled, so use the projection adapter's clear/2 (exported by
            %% both the ets and leveled adapters) rather than assuming ETS.
            %% Use the entry's own `clear_scope()` — exactly what the rebuild
            %% passes — so the wipe is correctly entity-scoped on a shared
            %% Bookie.
            Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
            Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
            Scope =
                case bondy_oplog_core_registry:entry_index_clear_scope(Entry) of
                    undefined -> {suffix, IndexName};
                    S -> S
                end,
            ok = Adapter:clear(Handle, Scope)
        end,
        lists:seq(0, N - 1)
    ).

%% Force a full cell-replay on every primary shard's applier.
replay_all(Table) ->
    Ids = maps:values(maps:get(instance_ids, Table)),
    lists:foreach(
        fun(InstanceId) ->
            ApplierPid = bondy_oplog_registry:applier_pid(InstanceId),
            true = is_pid(ApplierPid),
            ok = bondy_oplog_applier:replay_cell_events_sync(ApplierPid)
        end,
        Ids
    ).

make_tempdir() ->
    Base = filename:join([
        "/tmp/" ++ os:getpid(),
        "bondy_db_index_writer_test",
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
