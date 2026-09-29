%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% The keyed-Bookie pool of `bondy_db_leveled_sup`, driven through
%% `bondy_db_topology_shared_shards` where the property is the topology's.
%%
%% `shard_opens_overlap` holds every `leveled_bookie:book_start/1` at a gate
%% and requires all shards to be inside it at once before any is released.
%% Opens serialised by one supervisor (or by a serial caller) reach the gate
%% one at a time, the second only after the first's hold expires, which is
%% past the case's gate timeout. It does not measure how much two real journal replays overlap.
%% =============================================================================

-module(bondy_db_leveled_sup_test).

-include_lib("eunit/include/eunit.hrl").

-define(SHARDS, 4).
-define(GATE_TIMEOUT, 1500).
%% Longer than `GATE_TIMEOUT`, so the openings the case waits for can only
%% all arrive while every one of them is still held; finite, so a serialised
%% pool fails the case instead of hanging its cleanup.
-define(HOLD, 4000).

leveled_sup_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        gen("every shard opens at once", fun shard_opens_overlap/1),
        gen("a crash-looping keyed Bookie fells the pool", fun crash_loop/1),
        gen("stop_bookie leaves the pool running", fun stop_bookie/1),
        gen("a failed shard open leaves the pool empty", fun failed_open/1),
        gen("bookies/1 lists keyed and anonymous", fun bookies/1)
    ]}.

gen(Title, Fn) ->
    fun(Ctx) -> {Title, {timeout, 60, fun() -> Fn(Ctx) end}} end.

%% =============================================================================
%% Setup / teardown
%% =============================================================================

setup() ->
    process_flag(trap_exit, true),
    Dir = make_tempdir(),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {Sup, Dir}.

cleanup({Sup, Dir}) ->
    _ = meck:unload(),
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    rmrf(Dir),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

shard_opens_overlap({Sup, Dir}) ->
    Test = self(),
    ok = meck:new(leveled_bookie, [passthrough, no_link]),
    ok = meck:expect(leveled_bookie, book_start, fun(Opts) ->
        Test ! {opening, self()},
        receive
            release -> ok
        after ?HOLD -> ok
        end,
        meck:passthrough([Opts])
    end),
    {ok, State} = bondy_db_topology_shared_shards:init(
        overlap_db, #{sup => Sup, dir => Dir}
    ),
    _ = spawn_link(fun() ->
        Test !
            {opened,
                bondy_db_topology_shared_shards:open_table(
                    items, ?SHARDS, #{}, State
                )}
    end),
    Openers = [
        receive
            {opening, Pid} -> Pid
        after ?GATE_TIMEOUT -> error({opens_serialised, N - 1})
        end
     || N <- lists:seq(1, ?SHARDS)
    ],
    _ = [P ! release || P <- Openers],
    {ok, #{shards := Shards}, _} =
        receive
            {opened, Result} -> Result
        after ?HOLD -> error(open_table_never_returned)
        end,
    ?assertEqual(lists:seq(0, ?SHARDS - 1), lists:sort(maps:keys(Shards))),
    ?assertEqual(?SHARDS, bondy_db_leveled_sup:bookie_count(Sup)).

crash_loop({Sup, Dir}) ->
    {ok, _} = start_keyed(Sup, Dir, {shard, 0}),
    {pt, PTKey} = bondy_db_leveled_sup:bookie_ref(Sup, {shard, 0}),
    Mon = erlang:monitor(process, Sup),
    ?assertEqual(shutdown, kill_until_pool_exits(Mon, PTKey, 10)).

stop_bookie({Sup, Dir}) ->
    {ok, _} = start_keyed(Sup, Dir, {shard, 0}),
    {ok, Kept} = start_keyed(Sup, Dir, {shard, 1}),
    ok = bondy_db_leveled_sup:stop_bookie(Sup, {shard, 0}),
    ?assert(is_process_alive(Sup)),
    ?assertEqual([Kept], bondy_db_leveled_sup:bookies(Sup)).

failed_open({Sup, Dir}) ->
    ok = meck:new(leveled_bookie, [passthrough, no_link]),
    ok = meck:expect(leveled_bookie, book_start, fun(Opts) ->
        case filename:basename(proplists:get_value(root_path, Opts)) of
            "2" -> {error, refused};
            _ -> meck:passthrough([Opts])
        end
    end),
    {ok, State} = bondy_db_topology_shared_shards:init(
        failed_db, #{sup => Sup, dir => Dir}
    ),
    ?assertMatch(
        {error, _},
        bondy_db_topology_shared_shards:open_table(items, ?SHARDS, #{}, State)
    ),
    ?assertEqual(
        [journal_trimmer],
        [Id || {Id, _, _, _} <- supervisor:which_children(Sup)]
    ).

bookies({Sup, Dir}) ->
    {ok, K0} = start_keyed(Sup, Dir, {shard, 0}),
    {ok, K1} = start_keyed(Sup, Dir, {shard, 1}),
    {ok, Anon} = bondy_db_leveled_sup:start_bookie(
        Sup, book_opts(Dir, "anon")
    ),
    ?assertEqual(
        lists:sort([K0, K1, Anon]),
        lists:sort(bondy_db_leveled_sup:bookies(Sup))
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

start_keyed(Sup, Dir, {shard, I} = Key) ->
    bondy_db_leveled_sup:get_or_start_bookie(
        Sup, Key, book_opts(Dir, integer_to_list(I))
    ).

book_opts(Dir, Name) ->
    Path = filename:join(Dir, Name),
    ok = filelib:ensure_path(Path),
    bondy_db_topology_leveled_common:default_book_opts(Path).

%% Kills the Bookie behind `PTKey` each time the per-key supervisor has
%% restarted it, until the pool itself exits. Bounded so that a pool that
%% never escalates fails the case instead of hanging it.
%% Returns the pool's exit reason.
kill_until_pool_exits(Mon, _PTKey, 0) ->
    error({pool_survived_crash_loop, Mon});
kill_until_pool_exits(Mon, PTKey, N) ->
    Pid = persistent_term:get(PTKey),
    exit(Pid, kill),
    case await_restart_or_exit(Mon, PTKey, Pid, 100) of
        {pool_exited, Reason} -> Reason;
        restarted -> kill_until_pool_exits(Mon, PTKey, N - 1)
    end.

await_restart_or_exit(_Mon, _PTKey, OldPid, 0) ->
    error({not_restarted, OldPid});
await_restart_or_exit(Mon, PTKey, OldPid, N) ->
    receive
        {'DOWN', Mon, process, _, Reason} -> {pool_exited, Reason}
    after 50 ->
        case persistent_term:get(PTKey, undefined) of
            Pid when is_pid(Pid), Pid =/= OldPid -> restarted;
            _ -> await_restart_or_exit(Mon, PTKey, OldPid, N - 1)
        end
    end.

make_tempdir() ->
    Dir = filename:join(
        [
            "/tmp/" ++ os:getpid(),
            "bondy_db_leveled_sup_test",
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
