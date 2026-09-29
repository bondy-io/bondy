%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% A table's primary-shard provisioning over `bondy_db_topology_shared_shards`.
%%
%% `instance_starts_overlap` holds every shard instance's `init/1` at a gate
%% (through the default validator's `init/2`) and requires all shards to be
%% inside it at once. Starts made one after another reach the gate one at a
%% time, the second only after the first's hold expires, past the gate
%% timeout. The rollback cases fail one shard's start (by an error, by a
%% crash) or its core-registry registration, and require that no shard keeps
%% an instance, a core-registry row or a cache table.
%% =============================================================================

-module(bondy_db_provision_test).

-include_lib("eunit/include/eunit.hrl").

-define(FOLD, bondy_oplog_crdt_lww_register).
-define(SHARDS, 4).
-define(FAILING_SHARD, 2).
-define(GATE_TIMEOUT, 1500).
%% Longer than `GATE_TIMEOUT`, so the starts the case waits for can only all
%% arrive while every one of them is still held; finite, so serial starts fail
%% the case instead of hanging its cleanup.
-define(HOLD, 4000).

provision_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        gen(
            "every shard instance starts at once", fun instance_starts_overlap/1
        ),
        gen(
            "a failed instance start rolls back every shard", fun failed_start/1
        ),
        gen(
            "a crashed instance start rolls back every shard",
            fun crashed_start/1
        ),
        gen(
            "a failed registration rolls back every shard",
            fun failed_register/1
        )
    ]}.

gen(Title, Fn) ->
    fun(Ctx) -> {Title, {timeout, 60, fun() -> Fn(Ctx) end}} end.

%% =============================================================================
%% Setup / teardown
%% =============================================================================

setup() ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = make_tempdir(),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(provision_db, #{
        topology => bondy_db_topology_shared_shards,
        topology_opts => #{sup => Sup, dir => Dir},
        shard_count => ?SHARDS,
        fold_module => ?FOLD
    }),
    {Db, Sup, Dir}.

cleanup({Db, Sup, Dir}) ->
    _ = meck:unload(),
    _ =
        try
            bondy_db:close(Db)
        catch
            _:_ -> ok
        end,
    _ = [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    rmrf(Dir),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

instance_starts_overlap({Db, _Sup, _Dir}) ->
    Test = self(),
    ok = meck:new(bondy_oplog_validator_trust, [passthrough, no_link]),
    ok = meck:expect(bondy_oplog_validator_trust, init, fun(Id, Opts) ->
        Test ! {starting, self()},
        receive
            release -> ok
        after ?HOLD -> ok
        end,
        meck:passthrough([Id, Opts])
    end),
    _ = spawn_link(fun() ->
        Test ! {opened, bondy_db:open_table(Db, items, table_opts())}
    end),
    Starting = [
        receive
            {starting, Pid} -> Pid
        after ?GATE_TIMEOUT -> error({starts_serialised, N - 1})
        end
     || N <- lists:seq(1, ?SHARDS)
    ],
    _ = [P ! release || P <- Starting],
    {ok, T} =
        receive
            {opened, Result} -> Result
        after ?HOLD -> error(open_table_never_returned)
        end,
    ?assertEqual(
        lists:seq(0, ?SHARDS - 1), lists:sort(maps:keys(instance_ids(T)))
    ).

failed_start(Ctx) ->
    rolls_back(Ctx, fun() -> {error, refused} end).

crashed_start(Ctx) ->
    rolls_back(Ctx, fun() -> error(refused) end).

failed_register({Db, _Sup, _Dir}) ->
    Test = self(),
    ok = meck:new(bondy_oplog_core_registry, [passthrough, no_link]),
    ok = meck:expect(bondy_oplog_core_registry, register, fun(NS, Index, S, C) ->
        Test ! {target, NS, Index},
        case S of
            ?FAILING_SHARD -> {error, refused};
            _ -> meck:passthrough([NS, Index, S, C])
        end
    end),
    Caches = owned_caches(),
    ?assertEqual(
        {error, refused}, bondy_db:open_table(Db, items, table_opts())
    ),
    assert_nothing_left(Caches).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Fails `?FAILING_SHARD`'s instance start with `Fail` and checks that the
%% table left nothing behind: every other shard started and was rolled back.
rolls_back({Db, _Sup, _Dir}, Fail) ->
    Test = self(),
    ok = meck:new(bondy_oplog, [passthrough, no_link]),
    ok = meck:expect(bondy_oplog, start_instance, fun(Id, Opts) ->
        [{NS, Index, Shard}] = maps:get(ae_targets, Opts),
        Test ! {target, NS, Index},
        case Shard of
            ?FAILING_SHARD -> Fail();
            _ -> meck:passthrough([Id, Opts])
        end
    end),
    Caches = owned_caches(),
    ?assertMatch({error, _}, bondy_db:open_table(Db, items, table_opts())),
    assert_nothing_left(Caches).

assert_nothing_left(Caches) ->
    {NS, Index} =
        receive
            {target, N, I} -> {N, I}
        after 0 -> error(no_instance_start)
        end,
    ?assertEqual([], bondy_oplog:list_instances()),
    ?assertEqual(
        [not_found || _ <- lists:seq(1, ?SHARDS)],
        [
            bondy_oplog_core_registry:lookup(NS, Index, S)
         || S <- lists:seq(0, ?SHARDS - 1)
        ]
    ),
    ?assertEqual(Caches, owned_caches()).

table_opts() ->
    #{fold_module => ?FOLD, crdt_module => ?FOLD}.

instance_ids(T) ->
    maps:get(instance_ids, T).

owned_caches() ->
    Self = self(),
    lists:sort([
        Tab
     || Tab <- ets:all(),
        ets:info(Tab, name) =:= bondy_oplog_cache_ets,
        ets:info(Tab, owner) =:= Self
    ]).

make_tempdir() ->
    Dir = filename:join(
        [
            "/tmp/" ++ os:getpid(),
            "bondy_db_provision_test",
            integer_to_list(erlang:unique_integer([positive]))
        ]
    ),
    ok = filelib:ensure_path(Dir),
    Dir.

rmrf(Path) ->
    case filelib:is_dir(Path) of
        true ->
            {ok, Names} = file:list_dir(Path),
            _ = [rmrf(filename:join(Path, N)) || N <- Names],
            _ = file:del_dir(Path),
            ok;
        false ->
            _ = file:delete(Path),
            ok
    end.
