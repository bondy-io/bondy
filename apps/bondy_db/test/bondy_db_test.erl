%% =============================================================================
%% Integration tests for the `bondy_db` facade.
%%
%% The facade is fold-agnostic; the tests drive it with explicit
%% fold-shaped events so the verification covers the actual contract
%% (read-modify-write, HLC monotonicity, range over decoded states).
%% The same scenarios run twice — once against per_entity (T2) and once
%% against single_bookie — confirming the facade is topology-agnostic.
%% =============================================================================

-module(bondy_db_test).

-include_lib("eunit/include/eunit.hrl").

-define(FOLD, bondy_oplog_crdt_lww_register).

%% =============================================================================
%% Test generators
%% =============================================================================

per_entity_test_() ->
    topology_suite(bondy_db_topology_per_entity).

single_bookie_test_() ->
    topology_suite(bondy_db_topology_single_bookie).

%% The same scenarios against the in-memory (ETS) topology — proves the
%% facade is backend-agnostic and the ephemeral projection backing serves
%% reads/writes/range identically. `sup`/`dir` in the shared setup are
%% ignored by `bondy_db_topology_memory:init/2`.
memory_test_() ->
    topology_suite(bondy_db_topology_memory).

%% The memory topology anchors every per-shard resource — the projection
%% table, the read cache, and the `bondy_oplog_core_registry` row — in a
%% dedicated DB-scoped process (`bondy_db_topology_memory_owner`),
%% decoupled from the transient process that calls `open_table/3`. This
%% proves full ephemeral survival end-to-end: kill the facade caller and
%% a fresh process can still drive a write + read through the surviving
%% substrate. Against the pre-fix code — caller-owned projection + cache,
%% registry monitor on the caller — killing it wiped the tables (applier
%% crashes on a dead tid) and dropped the registry row (reads fail).
ets_owner_survives_caller_death_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_db),
            ok
        end,
        fun(_) -> ok end, fun ets_owner_survives_caller_death/0}.

topology_suite(Topology) ->
    Tag = atom_to_list(Topology),
    {foreach, fun() -> setup(Topology) end, fun cleanup/1, [
        test("apply_then_read/" ++ Tag, fun apply_then_read/1),
        test("read_missing/" ++ Tag, fun read_missing/1),
        test("later_hlc_wins/" ++ Tag, fun later_hlc_wins/1),
        test(
            "earlier_hlc_is_rejected/" ++ Tag,
            fun earlier_hlc_is_rejected/1
        ),
        test("clear_then_read/" ++ Tag, fun clear_then_read/1),
        test("clear_then_resurrect/" ++ Tag, fun clear_then_resurrect/1),
        test("realm_isolation/" ++ Tag, fun realm_isolation/1),
        test("range_returns_states/" ++ Tag, fun range_returns_states/1),
        test("tick_is_monotonic/" ++ Tag, fun tick_is_monotonic/1),
        test(
            "open_table_requires_fold/" ++ Tag,
            fun open_table_requires_fold_module/1
        ),
        test("info/" ++ Tag, fun info_db_and_table/1)
    ]}.

test(Title, Fn) ->
    fun(Ctx) -> {Title, fun() -> Fn(Ctx) end} end.

%% =============================================================================
%% Setup / teardown
%% =============================================================================

setup(Topology) ->
    process_flag(trap_exit, true),
    %% The substrate's per-shard `bondy_oplog_core_registry` lives inside the
    %% `bondy_mst` application; without this the facade's `open_table/3`
    %% cannot register a shard.
    {ok, _} = application:ensure_all_started(bondy_db),
    Dir = make_tempdir(),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(my_db, #{
        topology => Topology,
        topology_opts => #{sup => Sup, dir => Dir},
        shard_count => 4,
        fold_module => ?FOLD
    }),
    {Db, Sup, Dir}.

cleanup({Db, Sup, Dir}) ->
    _ =
        try
            bondy_db:close(Db)
        catch
            _:_ -> ok
        end,
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    rmrf(Dir),
    ok.

%% =============================================================================
%% Tests — every mutating test drives apply/4 with explicit fold events
%% so the facade's fold-agnosticism is visible in the test code.
%% =============================================================================

apply_then_read({Db, _Sup, _Dir}) ->
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    H = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H, <<"v1">>}),
    ?assertEqual(
        {ok, {<<"v1">>, H}},
        bondy_db:read(T, <<"r1">>, <<"alice">>)
    ),
    ok = bondy_db:close_table(T).

read_missing({Db, _Sup, _Dir}) ->
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    ?assertEqual({error, not_found}, bondy_db:read(T, <<"r1">>, <<"nobody">>)),
    ok = bondy_db:close_table(T).

later_hlc_wins({Db, _Sup, _Dir}) ->
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    H1 = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H1, <<"first">>}),
    H2 = bondy_db:tick(T),
    ?assert(H2 > H1),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H2, <<"second">>}),
    ?assertEqual(
        {ok, {<<"second">>, H2}},
        bondy_db:read(T, <<"r1">>, <<"alice">>)
    ),
    ok = bondy_db:close_table(T).

earlier_hlc_is_rejected({Db, _Sup, _Dir}) ->
    %% LWW: an event with an HLC older than the current cell's HLC must
    %% leave the cell unchanged. Tests the read-modify-write contract
    %% routes events through fold:apply_event/3 (not blind overwrite).
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    H2 = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H2, <<"newer">>}),
    %% Replay a fabricated older event.
    H1 = H2 - 1,
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H1, <<"older">>}),
    ?assertEqual(
        {ok, {<<"newer">>, H2}},
        bondy_db:read(T, <<"r1">>, <<"alice">>)
    ),
    ok = bondy_db:close_table(T).

clear_then_read({Db, _Sup, _Dir}) ->
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    H1 = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H1, <<"v">>}),
    H2 = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {clear, H2}),
    %% lww_register's `to_value({cleared, _}) -> undefined`, so the
    %% read collapses to `not_found`.
    ?assertEqual(
        {error, not_found},
        bondy_db:read(T, <<"r1">>, <<"alice">>)
    ),
    ok = bondy_db:close_table(T).

clear_then_resurrect({Db, _Sup, _Dir}) ->
    %% LWW: a higher-HLC `set` after a `clear` re-populates the register.
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    H1 = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H1, <<"v1">>}),
    H2 = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {clear, H2}),
    H3 = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H3, <<"v2">>}),
    ?assertEqual(
        {ok, {<<"v2">>, H3}},
        bondy_db:read(T, <<"r1">>, <<"alice">>)
    ),
    ok = bondy_db:close_table(T).

realm_isolation({Db, _Sup, _Dir}) ->
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    H1 = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H1, <<"v1">>}),
    H2 = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r2">>, <<"alice">>, {set, H2, <<"v2">>}),
    ?assertEqual(
        {ok, {<<"v1">>, H1}},
        bondy_db:read(T, <<"r1">>, <<"alice">>)
    ),
    ?assertEqual(
        {ok, {<<"v2">>, H2}},
        bondy_db:read(T, <<"r2">>, <<"alice">>)
    ),
    ?assertEqual({error, not_found}, bondy_db:read(T, <<"r3">>, <<"alice">>)),
    ok = bondy_db:close_table(T).

range_returns_states({Db, _Sup, _Dir}) ->
    %% range/5 returns user-facing values (post-`to_value/1`).
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    Keys = [
        list_to_binary("k" ++ integer_to_list(I))
     || I <- lists:seq(1, 20)
    ],
    Written = lists:sort(Keys),
    lists:foreach(
        fun(K) ->
            H = bondy_db:tick(T),
            ok = bondy_db:apply(
                T,
                <<"r1">>,
                K,
                {set, H, <<K/binary, "v">>}
            )
        end,
        Keys
    ),
    Shard = erlang:phash2(hd(Keys), 4),
    {ok, Rows} = bondy_db:range(
        T,
        <<"r1">>,
        <<"k">>,
        <<"l">>,
        #{shard => Shard, limit => 100}
    ),
    Got = [K || {K, _Value, _Hlc} <- Rows],
    %% Sorted ascending.
    ?assertEqual(lists:sort(Got), Got),
    %% Every returned key lies in [<<"k">>, <<"l">>).
    ?assert(lists:all(fun(K) -> K >= <<"k">> andalso K < <<"l">> end, Got)),
    %% Every returned key was written.
    ?assert(lists:all(fun(K) -> lists:member(K, Written) end, Got)),
    %% Every returned value is <<K, "v">> with matching HLC.
    ?assert(
        lists:all(
            fun({K, V, Hlc}) ->
                V =:= <<K/binary, "v">> andalso
                    is_integer(Hlc)
            end,
            Rows
        )
    ),
    %% At least one row came back.
    ?assert(length(Got) >= 1),
    ok = bondy_db:close_table(T).

tick_is_monotonic({Db, _Sup, _Dir}) ->
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    Hs = [bondy_db:tick(T) || _ <- lists:seq(1, 50)],
    ?assertEqual(lists:sort(Hs), Hs),
    %% No duplicates.
    ?assertEqual(length(Hs), sets:size(sets:from_list(Hs))),
    ok = bondy_db:close_table(T).

open_table_requires_fold_module({_Db, Sup, Dir}) ->
    {ok, Db2} = bondy_db:open(my_db2, #{
        topology => bondy_db_topology_single_bookie,
        topology_opts => #{
            sup => Sup,
            dir => filename:join(Dir, "no_fold")
        },
        shard_count => 2
    }),
    ?assertMatch(
        {error, {missing_required_opt, fold_module}},
        bondy_db:open_table(Db2, users, #{})
    ),
    ok = bondy_db:close(Db2).

info_db_and_table({Db, _Sup, _Dir}) ->
    DbInfo = bondy_db:info(Db),
    ?assertMatch(#{kind := db, name := my_db}, DbInfo),
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    TInfo = bondy_db:info(T),
    ?assertMatch(
        #{
            kind := table,
            db_name := my_db,
            entity_type := users,
            shard_count := 4,
            fold_module := ?FOLD
        },
        TInfo
    ),
    ok = bondy_db:close_table(T).

ets_owner_survives_caller_death() ->
    Parent = self(),
    %% `open_table/3` from a transient process — the facade caller. Under
    %% the pre-fix code it owned the projection table AND the cache, and
    %% the registry monitor was on it, so its death wiped all three. With
    %% the fix every per-shard resource is anchored in the DB-scoped
    %% `bondy_db_topology_memory_owner`. Capture the full `Table` handle
    %% so the parent can keep driving the facade after the caller dies.
    {Caller, MRef} = spawn_monitor(fun() ->
        {ok, Db} = bondy_db:open(ets_owner_db, #{
            topology => bondy_db_topology_memory,
            shard_count => 2,
            fold_module => ?FOLD
        }),
        {ok, T} = bondy_db:open_table(Db, users, #{}),
        H = bondy_db:tick(T),
        ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H, <<"v1">>}),
        Parent ! {captured, T},
        receive
            stop -> ok
        end
    end),
    Table =
        receive
            {captured, T} -> T
        after 5000 -> error(captured_timeout)
        end,
    TS = maps:get(table_state, Table),
    Owner = maps:get(owner, TS),
    Shards = maps:get(shards, TS),
    NS = maps:get(namespace, Table),
    Shard = erlang:phash2({<<"r1">>, <<"alice">>}, 2),
    Tid = maps:get(Shard, Shards),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, Shard),
    CacheTid = bondy_oplog_core_registry:entry_cache_handle(Entry),
    %% Pre-condition: projection table AND cache are owned by the
    %% dedicated owner, NOT the transient caller — so by ETS semantics
    %% the caller's death cannot delete either.
    ?assert(is_pid(Owner)),
    ?assertNotEqual(Caller, Owner),
    ?assertEqual(Owner, ets:info(Tid, owner)),
    ?assertEqual(Owner, ets:info(CacheTid, owner)),
    %% Kill the caller.
    exit(Caller, kill),
    receive
        {'DOWN', MRef, process, Caller, _} -> ok
    after 5000 -> error(down_timeout)
    end,
    %% Every per-shard resource the appliers and reads depend on outlives
    %% the caller: projection table, read cache, and the registry row
    %% (its monitor now tracks the owner, not the caller).
    ?assert(is_process_alive(Owner)),
    ?assertEqual(Owner, ets:info(Tid, owner)),
    ?assertEqual(Owner, ets:info(CacheTid, owner)),
    ?assertMatch({ok, _}, bondy_oplog_core_registry:lookup(NS, primary, Shard)),
    %% The decisive end-to-end check: a fresh process (the test process,
    %% not the dead caller) drives a read of the pre-kill write, then a
    %% NEW write + read, all through the surviving substrate. Pre-fix this
    %% raised (dead projection/cache tid) or returned a read error (the
    %% registry row was gone).
    ?assertMatch(
        {ok, {<<"v1">>, _}}, bondy_db:read(Table, <<"r1">>, <<"alice">>)
    ),
    H2 = bondy_db:tick(Table),
    ok = bondy_db:apply(Table, <<"r1">>, <<"alice">>, {set, H2, <<"v2">>}),
    ?assertEqual(
        {ok, {<<"v2">>, H2}}, bondy_db:read(Table, <<"r1">>, <<"alice">>)
    ),
    %% Teardown through the normal facade path — every delete is routed
    %% through the owner (cache + registry + projection). The owner is
    %% orphaned (no surviving Db handle), so stop it explicitly.
    ok = bondy_db:close_table(Table),
    ?assertEqual(undefined, ets:info(Tid, owner)),
    ?assertEqual(undefined, ets:info(CacheTid, owner)),
    ok = bondy_db_topology_memory_owner:stop(Owner).

%% =============================================================================
%% PB-2 — per-table projection backend (durable leveled vs ephemeral ets)
%% =============================================================================

%% An `ets`-backed (ephemeral) table provisioned *inside a leveled DB*.
%% The facade routes the table's projection through a DB-scoped
%% `bondy_db_topology_memory` provider; the leveled topology is left
%% untouched. The full read/write/range contract is identical to leveled.
ets_backend_in_leveled_db_test_() ->
    {setup, fun() -> setup(bondy_db_topology_per_entity) end, fun cleanup/1,
        fun(Ctx) -> {"ets_backend_e2e", fun() -> ets_backend_e2e(Ctx) end} end}.

ets_backend_e2e({Db, _Sup, _Dir}) ->
    {ok, T} = bondy_db:open_table(Db, registrations, #{
        projection_backend => ets,
        oplog_instance_opts => #{backend => ets, durability => ephemeral}
    }),
    Info = bondy_db:info(T),
    ?assertEqual(ets, maps:get(projection_backend, Info)),
    %% Effective projection topology is the in-memory one even though the
    %% DB's own topology is leveled.
    ?assertEqual(bondy_db_topology_memory, maps:get(db_topology, T)),
    H1 = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H1, <<"v1">>}),
    ?assertEqual({ok, {<<"v1">>, H1}}, bondy_db:read(T, <<"r1">>, <<"alice">>)),
    H2 = bondy_db:tick(T),
    ?assert(H2 > H1),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H2, <<"v2">>}),
    ?assertEqual({ok, {<<"v2">>, H2}}, bondy_db:read(T, <<"r1">>, <<"alice">>)),
    %% Single-shard range over the shard `alice` lives in (the facade
    %% does not scatter-merge; mirror `range_returns_states`). Resolve the
    %% shard via `shard_for/3` rather than hardcoding the placement formula —
    %% memory now buckets by entity type and folds the realm into the key, so
    %% the legacy `phash2({Realm, Key})` no longer matches.
    Shard = bondy_db:shard_for(T, <<"r1">>, <<"alice">>),
    {ok, Rows} = bondy_db:range(
        T, <<"r1">>, <<"a">>, <<"z">>, #{shard => Shard, limit => 100}
    ),
    ?assert(lists:member({<<"alice">>, <<"v2">>, H2}, Rows)),
    ok = bondy_db:close_table(T).

%% One DB, two tables, two backends. A durable (leveled) table and an
%% ephemeral (ets) table coexist and stay isolated — the headline
%% intra-DB-mixing capability.
intra_db_mixing_test_() ->
    {setup, fun() -> setup(bondy_db_topology_per_entity) end, fun cleanup/1,
        fun(Ctx) -> {"intra_db_mixing", fun() -> intra_db_mixing(Ctx) end} end}.

intra_db_mixing({Db, _Sup, _Dir}) ->
    {ok, Durable} = bondy_db:open_table(Db, accounts, #{}),
    {ok, Ephemeral} = bondy_db:open_table(Db, registrations, #{
        projection_backend => ets,
        oplog_instance_opts => #{backend => ets, durability => ephemeral}
    }),
    ?assertEqual(leveled, maps:get(projection_backend, bondy_db:info(Durable))),
    ?assertEqual(ets, maps:get(projection_backend, bondy_db:info(Ephemeral))),
    Hd = bondy_db:tick(Durable),
    ok = bondy_db:apply(
        Durable, <<"r1">>, <<"acct">>, {set, Hd, <<"balance">>}
    ),
    He = bondy_db:tick(Ephemeral),
    ok = bondy_db:apply(Ephemeral, <<"r1">>, <<"sess">>, {set, He, <<"conn">>}),
    ?assertEqual(
        {ok, {<<"balance">>, Hd}}, bondy_db:read(Durable, <<"r1">>, <<"acct">>)
    ),
    ?assertEqual(
        {ok, {<<"conn">>, He}}, bondy_db:read(Ephemeral, <<"r1">>, <<"sess">>)
    ),
    %% Distinct namespaces — neither table sees the other's cells.
    ?assertEqual(
        {error, not_found}, bondy_db:read(Durable, <<"r1">>, <<"sess">>)
    ),
    ?assertEqual(
        {error, not_found}, bondy_db:read(Ephemeral, <<"r1">>, <<"acct">>)
    ),
    ok = bondy_db:close_table(Durable),
    ok = bondy_db:close_table(Ephemeral).

%% An ets-backed table writes nothing to the leveled topology's disk
%% layout: it bypasses the leveled topology, so no `<Dir>/<entity>/...`
%% subtree is ever laid out for it.
ets_backend_no_disk_artifacts_test_() ->
    {setup, fun() -> setup(bondy_db_topology_per_entity) end, fun cleanup/1,
        fun(Ctx) ->
            {"ets_backend_no_disk_artifacts", fun() ->
                ets_backend_no_disk_artifacts(Ctx)
            end}
        end}.

ets_backend_no_disk_artifacts({Db, _Sup, Dir}) ->
    {ok, T} = bondy_db:open_table(Db, registrations, #{
        projection_backend => ets,
        oplog_instance_opts => #{backend => ets, durability => ephemeral}
    }),
    H = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H, <<"v1">>}),
    ?assertNot(filelib:is_dir(filename:join(Dir, "registrations"))),
    %% A durable table in the same DB *does* lay out its subtree.
    {ok, D} = bondy_db:open_table(Db, accounts, #{}),
    Hd = bondy_db:tick(D),
    ok = bondy_db:apply(D, <<"r1">>, <<"acct">>, {set, Hd, <<"v">>}),
    ?assert(filelib:is_dir(filename:join(Dir, "accounts"))),
    ok = bondy_db:close_table(T),
    ok = bondy_db:close_table(D).

%% A memory-topology DB has no leveled capability, so an explicit
%% `projection_backend => leveled` is rejected rather than silently
%% downgraded to ets.
memory_db_rejects_leveled_backend_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_db),
            ok
        end,
        fun(_) -> ok end, fun memory_db_rejects_leveled_backend/0}.

memory_db_rejects_leveled_backend() ->
    {ok, Db} = bondy_db:open(mem_reject_db, #{
        topology => bondy_db_topology_memory,
        shard_count => 2,
        fold_module => ?FOLD
    }),
    ?assertMatch(
        {error,
            {unsupported_projection_backend,
                {leveled, bondy_db_topology_memory}}},
        bondy_db:open_table(Db, t, #{projection_backend => leveled})
    ),
    ?assertMatch(
        {error, {invalid_projection_backend, nonsense}},
        bondy_db:open_table(Db, t, #{projection_backend => nonsense})
    ),
    ok = bondy_db:close(Db).

%% The no-durable-storage WAL warning fires only when storage is absent
%% AND the caller has not declared the instance ephemeral.
warn_default_wal_path_test_() ->
    [
        ?_assert(bondy_oplog_instance_sup:warn_default_wal_path(#{})),
        ?_assert(
            bondy_oplog_instance_sup:warn_default_wal_path(
                #{durability => durable}
            )
        ),
        ?_assertNot(
            bondy_oplog_instance_sup:warn_default_wal_path(
                #{durability => ephemeral}
            )
        ),
        ?_assertNot(
            bondy_oplog_instance_sup:warn_default_wal_path(
                #{storage_path => <<"/x">>}
            )
        ),
        ?_assertNot(
            bondy_oplog_instance_sup:warn_default_wal_path(
                #{wal_dir => <<"/x">>}
            )
        )
    ].

%% =============================================================================
%% reconcile/4 — idempotent declarative-config write
%% =============================================================================

%% `reconcile/4` is the write used to apply declarative config on every boot.
%% The contract that fixes the cross-node convergence bug: re-asserting an
%% UNCHANGED value emits NO operation, so the cell's HLC does not advance and
%% the per-shard state stays identical across nodes/boots. A genuine
%% change still writes (fresh HLC). A durable (leveled) table is used because
%% that is where the real config tables live.
reconcile_test_() ->
    {setup, fun() -> setup(bondy_db_topology_per_entity) end, fun cleanup/1,
        fun(Ctx) ->
            {"reconcile_idempotent", fun() -> reconcile_idempotent(Ctx) end}
        end}.

reconcile_idempotent({Db, _Sup, _Dir}) ->
    {ok, T} = bondy_db:open_table(Db, things, #{}),
    %% First reconcile of an absent cell writes it.
    ok = bondy_db:reconcile(T, <<"r1">>, <<"k">>, <<"v1">>),
    {ok, {<<"v1">>, H1}} = bondy_db:read(T, <<"r1">>, <<"k">>),
    %% Re-asserting the SAME value is a no-op: no new write, so the HLC is
    %% unchanged. This is exactly what keeps the per-shard state stable when
    %% config is re-applied on a restart.
    ok = bondy_db:reconcile(T, <<"r1">>, <<"k">>, <<"v1">>),
    ?assertEqual({ok, {<<"v1">>, H1}}, bondy_db:read(T, <<"r1">>, <<"k">>)),
    %% Re-asserting it many times stays a no-op (HLC never moves).
    _ = [
        ok = bondy_db:reconcile(T, <<"r1">>, <<"k">>, <<"v1">>)
     || _ <- lists:seq(1, 5)
    ],
    ?assertEqual({ok, {<<"v1">>, H1}}, bondy_db:read(T, <<"r1">>, <<"k">>)),
    %% A genuine change DOES write: value updates and the HLC advances.
    ok = bondy_db:reconcile(T, <<"r1">>, <<"k">>, <<"v2">>),
    {ok, {<<"v2">>, H2}} = bondy_db:read(T, <<"r1">>, <<"k">>),
    ?assert(H2 > H1),
    %% ...and the new value is then idempotent in turn.
    ok = bondy_db:reconcile(T, <<"r1">>, <<"k">>, <<"v2">>),
    ?assertEqual({ok, {<<"v2">>, H2}}, bondy_db:read(T, <<"r1">>, <<"k">>)),
    ok = bondy_db:close_table(T).

%% =============================================================================
%% Helpers
%% =============================================================================

make_tempdir() ->
    Base = filename:join([
        "/tmp/" ++ os:getpid(),
        "bondy_db_test",
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
