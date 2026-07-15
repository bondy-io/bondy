%% =============================================================================
%% Multi-shard end-to-end test for the `bondy_db` facade.
%%
%% `bondy_db_test.erl` already covers the single-key contract at
%% `shard_count => 4`. This suite *exercises* the fan-out: keys are
%% generated to hit every shard, multiple tables and realms are
%% interleaved, the per-shard scan is unioned to recover the full
%% input set, and concurrent writers prove the WAL+applier+await
%% pipeline serialises correctly under load.
%%
%% Both topologies are driven through the same scenarios so any
%% latent shard- or bucket-routing bug surfaces uniformly.
%% =============================================================================

-module(bondy_db_multi_shard_e2e_test).

-include_lib("eunit/include/eunit.hrl").

-define(FOLD, bondy_oplog_crdt_lww_register).
-define(SHARDS, 4).
-define(KEYS, 60).
-define(DB, mst_multi_shard_e2e_db).
%% With phash2({Bucket, Key}, 4), the probability that ?KEYS=60 keys
%% miss any one of the 4 shards is bounded above by 4·(3/4)^60 ≈ 10⁻⁷.

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
            "fan_out_routing_exercises_all_shards/" ++ Tag,
            fun fan_out_routing_exercises_all_shards/1
        ),
        test(
            "multi_table_isolation_under_fanout/" ++ Tag,
            fun multi_table_isolation_under_fanout/1
        ),
        test(
            "multi_realm_isolation_under_fanout/" ++ Tag,
            fun multi_realm_isolation_under_fanout/1
        ),
        test(
            "per_shard_scan_recovers_all_keys/" ++ Tag,
            fun per_shard_scan_recovers_all_keys/1
        ),
        test(
            "concurrent_apply_visible_after_completion/" ++ Tag,
            fun concurrent_apply_visible_after_completion/1
        ),
        test(
            "later_hlc_wins_across_fanout/" ++ Tag,
            fun later_hlc_wins_across_fanout/1
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
    Dir = make_tempdir(),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(?DB, #{
        topology => Topology,
        topology_opts => #{sup => Sup, dir => Dir},
        shard_count => ?SHARDS,
        fold_module => ?FOLD
    }),
    {Topology, Db, Sup, Dir}.

cleanup({_T, Db, Sup, Dir}) ->
    %% A mid-test assertion failure bypasses `close_table/1`, leaving
    %% applier instances alive whose cached projection-adapter handles
    %% point at the (about-to-die) bookie. Force-stop every running
    %% instance so the next test boots from a clean substrate.
    _ = catch bondy_db:close(Db),
    _ = [
        catch bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    rmrf(Dir),
    %% WAL segments default to /tmp/bondy_oplog_wal/<os_pid>/<DbName>/...
    %% — delete them so the next test (or test suite using the same
    %% DbName atom) does not recover stale events from disk.
    rmrf(wal_dir_for_this_db()),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

fan_out_routing_exercises_all_shards({Topology, Db, _Sup, _Dir}) ->
    %% Apply every key, then read every key back. Both write- and read-
    %% paths must agree on the routing, and the key set must actually
    %% reach all 4 shards (probabilistic — see header).
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

multi_table_isolation_under_fanout({_Topo, Db, _Sup, _Dir}) ->
    %% Two tables on the same DB resolve to distinct buckets — in T1
    %% via `bucket_for/3`, in T2 via separate Bookies. Same realm and
    %% key in each table must hold independent state across all shards.
    {ok, Users} = bondy_db:open_table(Db, users, #{}),
    {ok, Sessions} = bondy_db:open_table(Db, sessions, #{}),
    Realm = <<"r1">>,
    Keys = test_keys(?KEYS),
    lists:foreach(
        fun(K) ->
            Hu = bondy_db:tick(Users),
            ok = bondy_db:apply(
                Users,
                Realm,
                K,
                {set, Hu, <<K/binary, "/u">>}
            ),
            Hs = bondy_db:tick(Sessions),
            ok = bondy_db:apply(
                Sessions,
                Realm,
                K,
                {set, Hs, <<K/binary, "/s">>}
            )
        end,
        Keys
    ),
    lists:foreach(
        fun(K) ->
            {ok, {Vu, _}} = bondy_db:read(Users, Realm, K),
            {ok, {Vs, _}} = bondy_db:read(Sessions, Realm, K),
            ?assertEqual(<<K/binary, "/u">>, Vu),
            ?assertEqual(<<K/binary, "/s">>, Vs)
        end,
        Keys
    ),
    ok = bondy_db:close_table(Users),
    ok = bondy_db:close_table(Sessions).

multi_realm_isolation_under_fanout({_Topo, Db, _Sup, _Dir}) ->
    %% Same key in three realms — bucket disambiguation must hold
    %% across every shard the key set fans out to.
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    Realms = [<<"r1">>, <<"r2">>, <<"r3">>],
    Keys = test_keys(?KEYS),
    lists:foreach(
        fun(R) ->
            lists:foreach(
                fun(K) ->
                    H = bondy_db:tick(T),
                    V = <<R/binary, "::", K/binary>>,
                    ok = bondy_db:apply(T, R, K, {set, H, V})
                end,
                Keys
            )
        end,
        Realms
    ),
    lists:foreach(
        fun(R) ->
            lists:foreach(
                fun(K) ->
                    Expect = <<R/binary, "::", K/binary>>,
                    {ok, {V, _}} = bondy_db:read(T, R, K),
                    ?assertEqual(Expect, V)
                end,
                Keys
            )
        end,
        Realms
    ),
    ok = bondy_db:close_table(T).

per_shard_scan_recovers_all_keys({_Topo, Db, _Sup, _Dir}) ->
    %% `bondy_db:range/5` is single-shard by contract; the caller
    %% scatters. Write a fanned-out key set, scatter-scan, then verify
    %% the union (deduplicated) equals the input set and each row's
    %% value+HLC matches what was written.
    %%
    %% Per-entity routes each shard to its own bookie, so each shard's
    %% scan returns a disjoint slice. Single-bookie aliases every shard
    %% onto one bookie, so each shard's scan returns the *whole* bucket
    %% — the same key surfaces once per shard. `usort` flattens both
    %% cases to the union semantics that the test actually cares about.
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    Realm = <<"r1">>,
    Keys = test_keys(?KEYS),
    Writes = lists:foldl(
        fun(K, Acc) ->
            H = bondy_db:tick(T),
            V = <<K/binary, "-v">>,
            ok = bondy_db:apply(T, Realm, K, {set, H, V}),
            Acc#{K => {V, H}}
        end,
        #{},
        Keys
    ),
    PerShard = [
        bondy_db:range(
            T,
            Realm,
            <<"a">>,
            <<"z">>,
            #{shard => S, limit => ?KEYS * 2}
        )
     || S <- lists:seq(0, ?SHARDS - 1)
    ],
    Rows = lists:flatmap(
        fun({ok, Xs}) -> [{K, V, H} || {K, V, H} <- Xs] end,
        PerShard
    ),
    GotKeys = lists:usort([K || {K, _, _} <- Rows]),
    ?assertEqual(lists:sort(Keys), GotKeys),
    lists:foreach(
        fun({K, V, H}) ->
            ?assertEqual({V, H}, maps:get(K, Writes))
        end,
        Rows
    ),
    ok = bondy_db:close_table(T).

concurrent_apply_visible_after_completion({_Topo, Db, _Sup, _Dir}) ->
    %% `apply/4` awaits the per-shard applier, so once every writer has
    %% returned, every write must be readable. Disjoint key prefixes
    %% (`w<N>-k<M>`) avoid LWW interference between writers; the test
    %% then verifies WAL+applier serialisation under concurrent load.
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    Realm = <<"r1">>,
    Writers = 8,
    PerWriter = 20,
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

later_hlc_wins_across_fanout({_Topo, Db, _Sup, _Dir}) ->
    %% Two rounds against the same keys; round 2 carries strictly
    %% higher HLCs (HLC monotonic per shard). LWW must converge to the
    %% round-2 value for every key regardless of which shard holds it.
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    Realm = <<"r1">>,
    Keys = test_keys(?KEYS),
    R1 = [
        begin
            H = bondy_db:tick(T),
            ok = bondy_db:apply(T, Realm, K, {set, H, <<K/binary, "-v1">>}),
            {K, H}
        end
     || K <- Keys
    ],
    R2 = [
        begin
            H = bondy_db:tick(T),
            ok = bondy_db:apply(T, Realm, K, {set, H, <<K/binary, "-v2">>}),
            {K, H}
        end
     || K <- Keys
    ],
    R1Map = maps:from_list(R1),
    lists:foreach(
        fun({K, H2}) -> ?assert(H2 > maps:get(K, R1Map)) end,
        R2
    ),
    lists:foreach(
        fun({K, H2}) ->
            ?assertEqual(
                {ok, {<<K/binary, "-v2">>, H2}},
                bondy_db:read(T, Realm, K)
            )
        end,
        R2
    ),
    ok = bondy_db:close_table(T).

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

make_tempdir() ->
    Base = filename:join([
        "/tmp",
        "bondy_db_multi_shard_e2e",
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
