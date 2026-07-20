%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Crash recovery for the shared (keyed) leveled Bookies — the plum_db
%% partition-store model adopted for bondy_db:
%%
%%   1. A keyed Bookie is a `permanent` child of `bondy_db_leveled_sup`: a
%%      kill is followed by an in-place supervisor restart (leveled replays
%%      its journal, so every acked write survives).
%%   2. Handles route by `{pt, PTKey}` REFERENCE, resolved per call through
%%      `persistent_term` — so every handle captured before the crash
%%      (readers AND the applier ctx) transparently follows the new pid.
%%
%% The test kills one shard's Bookie mid-session and proves reads AND writes
%% through the pre-crash `bondy_db` table handle keep working, with the
%% pre-crash data intact. A second case pins that `stop/1` erases the
%% persistent_term registrations (no leak across pool lifecycles).
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

    %% The supervisor restarts it (permanent child); the restart re-registers
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

%% =============================================================================
%% Helpers
%% =============================================================================

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
            "/tmp",
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
