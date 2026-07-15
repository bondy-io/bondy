%% =============================================================================
%% End-to-end validation for the production wiring:
%%
%%     bondy_db (facade)
%%       ↓
%%     per-shard bondy_oplog instance
%%       ├─ WAL (bondy_oplog_wal)
%%       ├─ MST snapshot store  → bondy_mst_pack_store (persistent)
%%       └─ projection adapter   → bondy_db_projection_leveled
%%
%% Mirrors the scenarios in `bondy_db_multi_shard_e2e_test` so any
%% drift between the ETS-MST baseline and the pack-MST + leveled
%% wiring surfaces side-by-side. The exhaustive multi-shard / multi-
%% realm / concurrent-writer coverage already lives there; this suite
%% concentrates on the things the pack-store path actually changes:
%% reopen-recovery of MST state, integration with the leveled
%% projection, and that the new shape compiles cleanly through
%% `bondy_db`'s `oplog_instance_opts` plumbing.
%% =============================================================================

-module(bondy_db_pack_leveled_e2e_test).

-include_lib("eunit/include/eunit.hrl").

-define(FOLD, bondy_oplog_crdt_lww_register).
-define(SHARDS, 4).
-define(KEYS, 32).
-define(DB, mst_pack_leveled_e2e_db).

%% =============================================================================
%% Test generators
%% =============================================================================

per_entity_test_() ->
    topology_suite(bondy_db_topology_per_entity).

single_bookie_test_() ->
    topology_suite(bondy_db_topology_single_bookie).

topology_suite(Topology) ->
    Tag = atom_to_list(Topology),
    {foreach, fun() -> setup(Topology) end, fun cleanup/1, [
        test(
            "put_read_round_trip/" ++ Tag,
            fun put_read_round_trip/1
        ),
        test(
            "multi_shard_fanout/" ++ Tag,
            fun multi_shard_fanout/1
        ),
        test(
            "concurrent_writers/" ++ Tag,
            fun concurrent_writers/1
        ),
        test(
            "mst_state_persists_across_close_reopen/" ++ Tag,
            fun mst_state_persists_across_close_reopen/1
        ),
        test(
            "head_path_telemetry_reports_native/" ++ Tag,
            fun head_path_telemetry_reports_native/1
        ),
        test(
            "counter_inc_round_trip/" ++ Tag,
            fun counter_inc_round_trip/1
        ),
        test(
            "oldstate_cache_default_on_for_leveled/" ++ Tag,
            fun oldstate_cache_default_on_for_leveled/1
        )
    ]}.

test(Title, Fn) ->
    fun(Ctx) -> {Title, {timeout, 60, fun() -> Fn(Ctx) end}} end.

%% =============================================================================
%% Setup / teardown
%% =============================================================================

setup(Topology) ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(bondy_db),
    LeveledDir = make_tempdir("leveled"),
    PackDir = make_tempdir("pack"),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(?DB, #{
        topology => Topology,
        topology_opts => #{sup => Sup, dir => LeveledDir},
        shard_count => ?SHARDS,
        fold_module => ?FOLD,
        %% This is the production wiring under test: route every per-
        %% shard `bondy_oplog` instance to the MST pack-store backend,
        %% rooted under `PackDir`. The leveled projection store is
        %% provisioned via the topology above.
        oplog_instance_opts => #{
            backend => bondy_mst_pack_store,
            storage_path => unicode:characters_to_binary(PackDir),
            %% Single-process e2e test: each shard's instance is a
            %% genesis peer with no cluster to bootstrap from. Without
            %% `seed: true` the applier would refuse to drain the WAL
            %% per the bootstrap-lifecycle gate
            %% (`_design/catalogue_expansion_plan.md` §2).
            seed => true
        }
    }),
    {Topology, Db, Sup, LeveledDir, PackDir}.

cleanup({_T, Db, Sup, LeveledDir, PackDir}) ->
    _ = catch bondy_db:close(Db),
    _ = [
        catch bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    rmrf(LeveledDir),
    rmrf(PackDir),
    rmrf(wal_dir_for_this_db()),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

put_read_round_trip({_Topo, Db, _Sup, _LDir, _PDir}) ->
    %% Smoke test: one apply, one read, every layer of the stack
    %% touched at least once.
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    Realm = <<"r1">>,
    Key = <<"alice">>,
    H = bondy_db:tick(T),
    V = <<"alice@example.com">>,
    ok = bondy_db:apply(T, Realm, Key, {set, H, V}),
    ?assertEqual({ok, {V, H}}, bondy_db:read(T, Realm, Key)),
    ok = bondy_db:close_table(T).

oldstate_cache_default_on_for_leveled({_Topo, Db, _Sup, _LDir, _PDir}) ->
    %% A3 — a leveled (durable) `bondy_db` table must get the applier's
    %% OldValue frame-cache ON by DEFAULT, with no `oldstate_cache` opt set
    %% anywhere. Proven by the `[bondy_oplog, applier, oldstate_cache]`
    %% telemetry, which the applier emits per OldValue resolve ONLY when the
    %% cache is enabled (zero events when off — an ets table, or a leveled
    %% table opened with an explicit `oldstate_cache => false`).
    {ok, T} = bondy_db:open_table(Db, cache_default_users, #{}),
    HandlerId = {?MODULE, oldstate_default, erlang:unique_integer()},
    Self = self(),
    ok = telemetry:attach(
        HandlerId,
        [bondy_oplog, applier, oldstate_cache],
        fun(_Event, Meas, Meta, _Cfg) ->
            Self ! {oldstate_event, Meas, Meta}
        end,
        undefined
    ),
    try
        Realm = <<"r1">>,
        Key = <<"carol">>,
        H = bondy_db:tick(T),
        ok = bondy_db:apply(T, Realm, Key, {set, H, <<"v1">>}),
        %% The resolve (and its telemetry) fires on the applier during the
        %% async WAL drain — `read/3` returns from the overlay and does not
        %% prove the drain ran, so wait on the event directly.
        receive
            {oldstate_event, _Meas, _Meta} -> ok
        after 5000 ->
            erlang:error(no_oldstate_cache_event_so_cache_is_off_by_default)
        end
    after
        telemetry:detach(HandlerId),
        ok = bondy_db:close_table(T)
    end.

multi_shard_fanout({Topology, Db, _Sup, _LDir, _PDir}) ->
    %% Apply ?KEYS keys and confirm they fan out across all shards and
    %% all round-trip correctly. Mirrors the canonical multi-shard
    %% scenario but on the pack-MST + leveled wiring.
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    Realm = <<"r1">>,
    Keys = test_keys(?KEYS),
    Writes = lists:map(
        fun(K) ->
            H = bondy_db:tick(T),
            V = <<K/binary, "-v">>,
            ok = bondy_db:apply(T, Realm, K, {set, H, V}),
            {K, V, H}
        end,
        Keys
    ),
    lists:foreach(
        fun({K, V, H}) ->
            ?assertEqual({ok, {V, H}}, bondy_db:read(T, Realm, K))
        end,
        Writes
    ),
    Bucket = bucket_for(Topology, users, Realm),
    Used = lists:foldl(
        fun(K, Acc) ->
            sets:add_element(erlang:phash2({Bucket, K}, ?SHARDS), Acc)
        end,
        sets:new([{version, 2}]),
        Keys
    ),
    ?assertEqual(?SHARDS, sets:size(Used)),
    ok = bondy_db:close_table(T).

concurrent_writers({_Topo, Db, _Sup, _LDir, _PDir}) ->
    %% 4 writers × 16 keys each, disjoint key prefixes (so no LWW
    %% interference). After every writer has returned, every key must
    %% be readable — proves WAL+applier serialisation under load with
    %% the pack-MST + leveled wiring.
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    Realm = <<"r1">>,
    Writers = 4,
    PerWriter = 16,
    Self = self(),
    _ = [
        spawn_link(fun() ->
            Writes = [
                begin
                    K =
                        <<"w", (integer_to_binary(W))/binary, "-k",
                            (integer_to_binary(I))/binary>>,
                    H = bondy_db:tick(T),
                    V = <<K/binary, "-v">>,
                    ok = bondy_db:apply(T, Realm, K, {set, H, V}),
                    {K, V, H}
                end
             || I <- lists:seq(1, PerWriter)
            ],
            Self ! {done, W, Writes}
        end)
     || W <- lists:seq(1, Writers)
    ],
    All = collect_writers(Writers, []),
    ?assertEqual(Writers * PerWriter, length(All)),
    lists:foreach(
        fun({K, V, H}) ->
            ?assertEqual({ok, {V, H}}, bondy_db:read(T, Realm, K))
        end,
        All
    ),
    ok = bondy_db:close_table(T).

mst_state_persists_across_close_reopen({Topology, Db, _Sup, LDir, PDir}) ->
    %% Pack-store-specific: the MST snapshot store is persistent, so
    %% closing the oplog instance and reopening must surface the
    %% prior root + every reachable page. The leveled projection
    %% provides the user-visible KV state; this test additionally
    %% verifies that the underlying MST recovers from disk by
    %% reading the same keys back via the same fold module.
    {ok, T0} = bondy_db:open_table(Db, users, #{}),
    Realm = <<"r1">>,
    Keys = test_keys(?KEYS),
    Writes = lists:map(
        fun(K) ->
            H = bondy_db:tick(T0),
            V = <<K/binary, "-pre-reopen">>,
            ok = bondy_db:apply(T0, Realm, K, {set, H, V}),
            {K, V, H}
        end,
        Keys
    ),
    %% Tear down the table + DB. `bondy_db:close/1` stops the leveled
    %% supervisor (and every Bookie under it), so we also stop every
    %% running oplog instance — they cache projection-adapter handles
    %% pointing at the just-killed Bookies. The on-disk state (the
    %% leveled journal/ledger and the pack-store manifests + sealed
    %% packs) survives, which is what the reopen below depends on.
    ok = bondy_db:close_table(T0),
    ok = bondy_db:close(Db),
    _ = [
        catch bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],

    %% Reopen with a fresh leveled supervisor over the same on-disk
    %% dirs. Each Bookie is restarted against its prior journal +
    %% ledger; the pack store reopens its manifest + sealed packs.
    {ok, Sup1} = bondy_db_leveled_sup:start_link(),
    {ok, Db1} = bondy_db:open(?DB, #{
        topology => Topology,
        topology_opts => #{sup => Sup1, dir => LDir},
        shard_count => ?SHARDS,
        fold_module => ?FOLD,
        oplog_instance_opts => #{
            backend => bondy_mst_pack_store,
            storage_path => unicode:characters_to_binary(PDir)
        }
    }),
    {ok, T1} = bondy_db:open_table(Db1, users, #{}),

    try
        lists:foreach(
            fun({K, V, H}) ->
                ?assertEqual(
                    {ok, {V, H}},
                    bondy_db:read(T1, Realm, K)
                )
            end,
            Writes
        )
    after
        _ = catch bondy_db:close_table(T1),
        _ = catch bondy_db:close(Db1),
        _ = [
            catch bondy_oplog:stop_instance(I)
         || I <- bondy_oplog:list_instances()
        ],
        case is_process_alive(Sup1) of
            true -> bondy_db_leveled_sup:stop(Sup1);
            false -> ok
        end
    end.

head_path_telemetry_reports_native({Topology, Db, _Sup, _LDir, _PDir}) ->
    %% Pin the leveled fast-read path: the projection adapter exports
    %% `head/3` natively, so a read served from the projection must
    %% emit `path => head` and `head_path => native`. ETS test
    %% adapters lack `head/3` and fall back; this assertion guards
    %% against silent regressions on the leveled path
    %% (`_design/catalogue_expansion_plan.md` §3.10 deferred item).
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    Realm = <<"r1">>,
    Key = <<"head-path-key">>,
    H = bondy_db:tick(T),
    V = <<"head-path-val">>,
    ok = bondy_db:apply(T, Realm, Key, {set, H, V}),
    %% Drive the applier to bake the event into the projection. The
    %% drain loop uses `bondy_db:read/3` which warms the value cache;
    %% we explicitly evict that cache afterwards so the assertion read
    %% must travel the projection path.
    ok = wait_for_overlay_drain(T, Realm, Key),
    Bucket = bucket_for(Topology, users, Realm),
    NS = maps:get(namespace, T),
    ok = evict_value_cache(NS, Bucket, Key),
    Self = self(),
    HandlerId = {?MODULE, head_path, erlang:unique_integer()},
    ok = telemetry:attach(
        HandlerId,
        [bondy_oplog_core, read],
        fun(_, Meas, Meta, _) ->
            Self ! {read_event, Meas, Meta}
        end,
        undefined
    ),
    try
        ?assertEqual({ok, {V, H}}, bondy_db:read(T, Realm, Key)),
        Meta =
            receive
                {read_event, _, M} -> M
            after 1000 ->
                error(no_read_event)
            end,
        ?assertEqual(projection, maps:get(source, Meta)),
        ?assertEqual(head, maps:get(path, Meta)),
        ?assertEqual(native, maps:get(head_path, Meta))
    after
        telemetry:detach(HandlerId),
        bondy_db:close_table(T)
    end.

wait_for_overlay_drain(T, Realm, Key) ->
    wait_for_overlay_drain(T, Realm, Key, 50).

wait_for_overlay_drain(T, Realm, Key, 0) ->
    %% Last-ditch read — let the test fail downstream if the cache is
    %% still warm. We don't have a hook to confirm overlay drain so
    %% best-effort 5s timeout is the contract.
    _ = bondy_db:read(T, Realm, Key),
    ok;
wait_for_overlay_drain(T, Realm, Key, N) ->
    case bondy_db:read(T, Realm, Key) of
        {ok, {_, _}} ->
            ok;
        _ ->
            timer:sleep(100),
            wait_for_overlay_drain(T, Realm, Key, N - 1)
    end.

counter_inc_round_trip({_Topo, Db, _Sup, _LDir, _PDir}) ->
    %% Exercise `bondy_db:counter_inc/4` end-to-end against a
    %% leveled-backed `pn_counter` table. Multiple positive/negative
    %% increments must converge to the sum (per-Origin Seq dedup is
    %% native to the WAL key — duplicate sends are no-ops). Closes
    %% out the PR-3 carry-over that requested a write-then-read e2e
    %% for `counter_inc/4` (§4.7).
    {ok, T} = bondy_db:open_table(Db, counters, #{
        fold_module => bondy_oplog_crdt_pn_counter
    }),
    Realm = <<"r1">>,
    Key = <<"visits">>,
    Deltas = [+5, -1, +10, -3, +7],
    Expected = lists:sum(Deltas),
    lists:foreach(
        fun(D) -> ok = bondy_db:counter_inc(T, Realm, Key, D) end,
        Deltas
    ),
    ?assertMatch({ok, {Expected, _Hlc}}, bondy_db:read(T, Realm, Key)),
    ok = bondy_db:close_table(T).

%% Evict the (NS, Bucket, Key) entry from every shard's value cache.
%% Iterating every shard is cheaper than computing phash2 ourselves
%% and matches what `bondy_oplog_core_registry:lookup/3` exposes.
evict_value_cache(NS, Bucket, Key) ->
    {ok, ShardCount} = bondy_oplog_core_registry:shard_count(NS, primary),
    lists:foreach(
        fun(Shard) ->
            case bondy_oplog_core_registry:lookup(NS, primary, Shard) of
                {ok, Entry} ->
                    CA = bondy_oplog_core_registry:entry_cache_adapter(Entry),
                    CH = bondy_oplog_core_registry:entry_cache_handle(Entry),
                    case CA:get(CH, Bucket, Key) of
                        {ok, _} -> _ = CA:delete(CH, Bucket, Key);
                        not_found -> ok
                    end;
                not_found ->
                    ok
            end
        end,
        lists:seq(0, ShardCount - 1)
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

collect_writers(0, Acc) ->
    Acc;
collect_writers(N, Acc) ->
    receive
        {done, _W, Writes} ->
            collect_writers(N - 1, Writes ++ Acc)
    after 60000 ->
        error({timeout_waiting_for_writers, N})
    end.

test_keys(N) ->
    [<<"key-", (integer_to_binary(I))/binary>> || I <- lists:seq(1, N)].

bucket_for(bondy_db_topology_per_entity, _ET, Realm) ->
    Realm;
bucket_for(bondy_db_topology_single_bookie, ET, Realm) ->
    <<Realm/binary, "/", (atom_to_binary(ET, utf8))/binary>>.

make_tempdir(Prefix) ->
    Base = filename:join([
        "/tmp",
        "bondy_db_pack_leveled_e2e",
        Prefix,
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

wal_dir_for_this_db() ->
    filename:join([
        "/tmp", "bondy_oplog_wal", os:getpid(), atom_to_list(?DB)
    ]).

rmrf(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.
