%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Crash recovery for the shared (keyed) leveled Bookies — the plum_db
%% partition-store model adopted for bondy_db:
%%
%%   1. A keyed Bookie is a `transient` child of its key's supervisor under
%%      `bondy_db_leveled_sup`: a kill is followed by an in-place restart
%%      (leveled replays its journal, so every acked write survives).
%%   2. Handles route by `{pt, PTKey}` REFERENCE, resolved per call through
%%      `persistent_term` — so every handle captured before the crash
%%      (readers AND the applier ctx) transparently follows the new pid.
%%
%% The test kills one shard's Bookie mid-session and proves reads AND writes
%% through the pre-crash `bondy_db` table handle keep working, with the
%% pre-crash data intact. A second case pins that `stop/1` erases the
%% persistent_term registrations (no leak across pool lifecycles). A third
%% kills one shard's oplog instance subtree: `bondy_oplog_instance_keeper`
%% starts it again, every write through the same handle succeeds, and
%% `bondy_db:close_table/1` then stops the new subtree rather than leaving
%% it running.
%%
%% The drain-gate cases open the table as the catalogue opens `main`, with
%% each shard's WAL drain gated until `bondy_db:start_draining/1`. A shard
%% released that way must stay released when its applier restarts, whether
%% its own supervisor or the keeper restarts it, or its writes are never
%% applied; and a shard closed and opened again must be gated again.
%%
%% The anti-entropy cases open two tables that share each shard's instance
%% and restart shard 0's applier, alone or with its whole subtree, or, for
%% two fused ephemeral tables, the instance that is their writer. Every
%% table must stay among the instance's AE targets, so a write to either
%% table keeps the other's shard fresh; a table left out reads as stale, and
%% `bondy_auth:security_fence/0` refuses authentication on a stale security
%% table.
%%
%% The registry cases kill `bondy_oplog_registry` or
%% `bondy_oplog_core_registry` under a running table. Reads and writes through
%% the same handle must keep working, and a `start_instance/2` of a running
%% shard must return its subtree rather than start a second one on its WAL.
%% A row whose owner dies while the core registry is down (its supervisor is
%% suspended across both kills) must be deleted once the registry is back.
%% =============================================================================

-module(bondy_db_bookie_restart_test).

-include_lib("eunit/include/eunit.hrl").

-define(FOLD, bondy_oplog_crdt_lww_register).
-define(SHARDS, 4).
-define(DB, mst_bookie_restart_db).
-define(R, <<"r1">>).

bookie_restart_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        gen(
            "bookie kill → restart is transparent to handles",
            fun restart_transparent/1
        ),
        gen(
            "pool stop erases pt registrations", fun stop_erases_registrations/1
        ),
        gen(
            "a killed shard instance is started again",
            fun killed_instance_restarts/1
        ),
        gen(
            "a released shard stays released when its applier restarts",
            fun released_gate_survives_applier_restart/1
        ),
        gen(
            "a released shard stays released when it is started again",
            fun released_gate_survives_subtree_restart/1
        ),
        gen(
            "a shard opened again is gated again",
            fun reopened_shard_is_gated/1
        ),
        gen(
            "an applier restart keeps every table's AE target",
            fun applier_restart_keeps_ae_targets/1
        ),
        gen(
            "a subtree restart keeps every table's AE target",
            fun subtree_restart_keeps_ae_targets/1
        ),
        gen(
            "a fused writer restart keeps every table's AE target",
            fun fused_restart_keeps_ae_targets/1
        ),
        gen(
            "an oplog registry restart keeps every running instance",
            fun oplog_registry_restart_keeps_instances/1
        ),
        gen(
            "a core registry restart keeps every shard",
            fun core_registry_restart_keeps_shards/1
        ),
        gen(
            "a core registry restart forgets an owner that died meanwhile",
            fun core_registry_restart_forgets_dead_owner/1
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
    {ok, Db} = bondy_db:open(?DB, #{
        topology => bondy_db_topology_shared_shards,
        topology_opts => #{sup => Sup, dir => Dir},
        shard_count => ?SHARDS,
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
    _ = [
        try
            bondy_oplog:stop_instance(I)
        catch
            _:_ -> ok
        end
     || I <- bondy_oplog:list_instances()
    ],
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    rmrf(Dir),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

restart_transparent({Db, Sup, _Dir}) ->
    {ok, T} = bondy_db:open_table(Db, items, #{
        fold_module => ?FOLD,
        crdt_module => ?FOLD
    }),
    %% Enough keys to land on every shard, so the killed shard certainly
    %% holds some of them.
    Keys = [<<"k-", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 60)],
    lists:foreach(
        fun(K) ->
            ok = bondy_db:apply(
                T, ?R, K, {set, bondy_db:tick(T), <<K/binary, "-v">>}
            )
        end,
        Keys
    ),

    %% Kill shard 0's Bookie through its routing registration.
    {pt, PTKey} = bondy_db_leveled_sup:bookie_ref(Sup, {shard, 0}),
    OldPid = persistent_term:get(PTKey),
    ?assert(is_process_alive(OldPid)),
    exit(OldPid, kill),

    %% A kill is a crash, so the supervisor restarts it; the restart re-registers
    %% the NEW pid under the SAME persistent_term key.
    NewPid = await_new_registration(PTKey, OldPid, 200),
    ?assert(is_process_alive(NewPid)),
    ?assertNotEqual(OldPid, NewPid),

    %% Every pre-crash value must read back through the SAME table handle —
    %% leveled acks a put only after the journal write, so the reopen
    %% replayed everything the applier had acked.
    lists:foreach(
        fun(K) ->
            ?assertEqual(
                {ok, <<K/binary, "-v">>}, read_value(T, K)
            )
        end,
        Keys
    ),

    %% And post-crash WRITES route to the restarted Bookie transparently.
    ok = bondy_db:apply(
        T, ?R, <<"post-crash">>, {set, bondy_db:tick(T), <<"pv">>}
    ),
    ?assertEqual({ok, <<"pv">>}, read_value(T, <<"post-crash">>)).

stop_erases_registrations({Db, Sup, _Dir}) ->
    {ok, T} = bondy_db:open_table(Db, items, #{
        fold_module => ?FOLD,
        crdt_module => ?FOLD
    }),
    ok = bondy_db:apply(T, ?R, <<"k">>, {set, bondy_db:tick(T), <<"v">>}),
    PTKeys = [
        element(2, bondy_db_leveled_sup:bookie_ref(Sup, {shard, I}))
     || I <- lists:seq(0, ?SHARDS - 1)
    ],
    [?assert(is_pid(persistent_term:get(K))) || K <- PTKeys],
    %% `bondy_db:close/1` drives the topology shutdown, which stops the
    %% Bookie pool (`bondy_db_leveled_sup:stop/1`) — that must erase every
    %% registered routing handle.
    ok = bondy_db:close(Db),
    ?assertNot(is_process_alive(Sup)),
    [
        ?assertEqual(missing, persistent_term:get(K, missing))
     || K <- PTKeys
    ],
    ok.

killed_instance_restarts({Db, _Sup, _Dir}) ->
    {ok, T} = bondy_db:open_table(Db, items, #{
        fold_module => ?FOLD,
        crdt_module => ?FOLD
    }),
    Keys = [<<"k-", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 60)],
    Write = fun(V) ->
        [bondy_db:apply(T, ?R, K, {set, bondy_db:tick(T), V}) || K <- Keys]
    end,
    ?assertEqual([ok || _ <- Keys], Write(<<"v1">>)),
    Victim = maps:get(0, maps:get(instance_ids, T)),
    OldSup = bondy_oplog_registry:sup_pid(Victim),
    exit(OldSup, kill),
    ok = await_new_sup(Victim, OldSup, 200),
    ?assertEqual([ok || _ <- Keys], Write(<<"v2">>)),
    ?assertEqual({ok, <<"v2">>}, read_value(T, hd(Keys))),
    ok = bondy_db:close_table(T),
    ?assertNot(lists:member(Victim, bondy_oplog:list_instances())),
    ?assertEqual(undefined, bondy_oplog_instance:whereis(Victim)).

released_gate_survives_applier_restart({Db, _Sup, _Dir}) ->
    {T, Victim} = open_released(Db),
    Applier = bondy_oplog_registry:applier_pid(Victim),
    exit(Applier, kill),
    ok = wait_until(
        fun() ->
            P = bondy_oplog_registry:applier_pid(Victim),
            is_pid(P) andalso P =/= Applier andalso is_process_alive(P)
        end,
        200
    ),
    assert_writes_apply(T).

released_gate_survives_subtree_restart({Db, _Sup, _Dir}) ->
    {T, Victim} = open_released(Db),
    OldSup = bondy_oplog_registry:sup_pid(Victim),
    exit(OldSup, kill),
    ok = await_new_sup(Victim, OldSup, 200),
    assert_writes_apply(T).

reopened_shard_is_gated({Db, _Sup, _Dir}) ->
    {T, Victim} = open_released(Db),
    ok = bondy_db:close_table(T),
    {ok, _} = bondy_db:open_table(Db, items, gated_opts()),
    ?assertNot(bondy_oplog_registry:tables_registered(Victim)),
    ok = bondy_db:start_draining(Db),
    ?assert(bondy_oplog_registry:tables_registered(Victim)).

applier_restart_keeps_ae_targets({Db, _Sup, _Dir}) ->
    {T1, T2, Id} = open_siblings(Db),
    Applier = bondy_oplog_registry:applier_pid(Id),
    exit(Applier, kill),
    ok = wait_until(
        fun() ->
            P = bondy_oplog_registry:applier_pid(Id),
            is_pid(P) andalso P =/= Applier andalso is_process_alive(P)
        end,
        200
    ),
    assert_ae_targets_kept(T1, T2, Id).

subtree_restart_keeps_ae_targets({Db, _Sup, _Dir}) ->
    {T1, T2, Id} = open_siblings(Db),
    OldSup = bondy_oplog_registry:sup_pid(Id),
    exit(OldSup, kill),
    ok = await_new_sup(Id, OldSup, 200),
    assert_ae_targets_kept(T1, T2, Id).

fused_restart_keeps_ae_targets({Db, _Sup, _Dir}) ->
    Opts = #{
        fold_module => ?FOLD,
        crdt_module => ?FOLD,
        projection_backend => ets,
        fused => true
    },
    {ok, T1} = bondy_db:open_table(Db, items, Opts),
    {ok, T2} = bondy_db:open_table(Db, grants, Opts),
    Id = maps:get(0, maps:get(instance_ids, T1)),
    ?assertEqual(Id, maps:get(0, maps:get(instance_ids, T2))),
    ?assert(bondy_oplog_registry:fused(Id)),
    Writer = bondy_oplog_instance:whereis(Id),
    OldWal = bondy_oplog_registry:wal_pid(Id),
    exit(Writer, kill),
    %% The instance restarts before its WAL writer, and a write while the WAL
    %% is mid-restart is refused with `wal_unavailable`.
    ok = wait_until(
        fun() ->
            P = bondy_oplog_instance:whereis(Id),
            W = bondy_oplog_registry:wal_pid(Id),
            is_pid(P) andalso P =/= Writer andalso is_process_alive(P) andalso
                is_pid(W) andalso W =/= OldWal andalso is_process_alive(W)
        end,
        200
    ),
    _ = sys:get_state(bondy_oplog_registry:wal_pid(Id)),
    assert_ae_targets_kept(T1, T2, Id).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Two tables sharing each shard's instance, opened and released as the
%% catalogue opens `main`; and shard 0's instance id.
open_siblings(Db) ->
    {ok, T1} = bondy_db:open_table(Db, items, gated_opts()),
    {ok, T2} = bondy_db:open_table(Db, grants, gated_opts()),
    ok = bondy_db:start_draining(Db),
    Id = maps:get(0, maps:get(instance_ids, T1)),
    ?assertEqual(Id, maps:get(0, maps:get(instance_ids, T2))),
    {T1, T2, Id}.

%% Both tables are still the instance's AE targets, and each stays fresh
%% when only the other is written: every commit bumps every target.
assert_ae_targets_kept(T1, T2, Id) ->
    ?assertEqual(
        lists:sort([
            {maps:get(namespace, T1), primary, 0},
            {maps:get(namespace, T2), primary, 0}
        ]),
        lists:sort(bondy_oplog_registry:ae_targets(Id))
    ),
    assert_writes_apply(T1),
    ?assertEqual(ok, bondy_db:ensure_fresh([T2], 1000)),
    assert_writes_apply(T2),
    ?assertEqual(ok, bondy_db:ensure_fresh([T1], 1000)).

gated_opts() ->
    #{
        fold_module => ?FOLD,
        crdt_module => ?FOLD,
        oplog_instance_opts => #{applier => #{drain_gated => true}}
    }.

oplog_registry_restart_keeps_instances({Db, _Sup, _Dir}) ->
    {T, Victim} = open_released(Db),
    Sup = bondy_oplog_registry:sup_pid(Victim),
    Subtrees = subtrees(),
    ok = kill_restart(bondy_oplog_registry),
    ?assertEqual(Sup, bondy_oplog_registry:sup_pid(Victim)),
    assert_writes_apply(T),
    ?assertEqual({ok, Sup}, bondy_oplog:start_instance(Victim, #{})),
    ?assertEqual(Subtrees, subtrees()).

core_registry_restart_keeps_shards({Db, _Sup, _Dir}) ->
    {T, _Victim} = open_released(Db),
    ok = kill_restart(bondy_oplog_core_registry),
    assert_writes_apply(T).

core_registry_restart_forgets_dead_owner(_Ctx) ->
    NS = binary_to_atom(
        <<"dead_owner_",
            (integer_to_binary(erlang:unique_integer([positive])))/binary>>
    ),
    Owner = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => ?FOLD,
        overlay => disabled,
        owner => Owner
    }),
    ok = sys:suspend(bondy_oplog_sup),
    try
        ok = kill(whereis(bondy_oplog_core_registry)),
        ok = kill(Owner),
        ?assertMatch({ok, _}, bondy_oplog_core_registry:lookup(NS, primary, 0))
    after
        ok = sys:resume(bondy_oplog_sup)
    end,
    ok = wait_until(
        fun() ->
            bondy_oplog_core_registry:lookup(NS, primary, 0) =:= not_found
        end,
        100
    ).

%% A table opened with every shard's drain gated, then released, as the
%% catalogue opens `main`; and shard 0's instance id.
open_released(Db) ->
    {ok, T} = bondy_db:open_table(Db, items, gated_opts()),
    ok = bondy_db:start_draining(Db),
    assert_writes_apply(T),
    {T, maps:get(0, maps:get(instance_ids, T))}.

%% Every write lands on its shard's projection: a gated shard's writes are
%% never applied, so its keys never read back.
assert_writes_apply(T) ->
    V = integer_to_binary(erlang:unique_integer([positive])),
    Keys = [<<"g-", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 60)],
    Self = self(),
    Writer = spawn_link(fun() ->
        Self !
            {written, [
                bondy_db:apply(T, ?R, K, {set, bondy_db:tick(T), V})
             || K <- Keys
            ]}
    end),
    Written =
        receive
            {written, W} -> W
        after 10000 ->
            unlink(Writer),
            exit(Writer, kill),
            writes_never_applied
        end,
    ?assertEqual([ok || _ <- Keys], Written),
    ?assertEqual([{ok, V} || _ <- Keys], [read_value(T, K) || K <- Keys]).

%% Kills the registered `Name` and waits for its supervisor to start it again.
kill_restart(Name) ->
    Old = whereis(Name),
    ok = kill(Old),
    wait_until(
        fun() ->
            P = whereis(Name),
            is_pid(P) andalso P =/= Old
        end,
        100
    ).

kill(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    end.

subtrees() ->
    length(supervisor:which_children(bondy_oplog_instance_dyn_sup)).

wait_until(_Fun, 0) ->
    error(timeout);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, N - 1)
    end.

await_new_sup(_Id, _OldSup, 0) ->
    error(instance_not_restarted);
await_new_sup(Id, OldSup, N) ->
    case bondy_oplog_registry:sup_pid(Id) of
        P when is_pid(P), P =/= OldSup ->
            case is_process_alive(P) of
                true -> ok;
                false -> retry_sup(Id, OldSup, N)
            end;
        _ ->
            retry_sup(Id, OldSup, N)
    end.

retry_sup(Id, OldSup, N) ->
    timer:sleep(50),
    await_new_sup(Id, OldSup, N - 1).

%% Poll until the persistent_term registration points at a NEW live pid.
await_new_registration(_PTKey, _OldPid, 0) ->
    error(bookie_not_restarted);
await_new_registration(PTKey, OldPid, N) ->
    case persistent_term:get(PTKey, undefined) of
        Pid when is_pid(Pid), Pid =/= OldPid ->
            case is_process_alive(Pid) of
                true -> Pid;
                false -> retry(PTKey, OldPid, N)
            end;
        _ ->
            retry(PTKey, OldPid, N)
    end.

retry(PTKey, OldPid, N) ->
    timer:sleep(50),
    await_new_registration(PTKey, OldPid, N - 1).

read_value(T, K) ->
    case bondy_db:read(T, ?R, K) of
        {ok, {V, _Hlc}} -> {ok, V};
        Other -> Other
    end.

make_tempdir() ->
    Dir = filename:join(
        [
            "/tmp/" ++ os:getpid(),
            "bondy_db_bookie_restart_test",
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
