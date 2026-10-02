%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% The applier's `consumer.offset` must never pass an event the instance's
%% durable MST root lacks: a durable backend resumes from that offset alone,
%% so an event committed past without its install is never re-presented.
%%
%% Four ways to commit without the barrier, each asserted not to move the
%% offset or lose an event: the root flush fails (`bondy_mst:flush/1`
%% mocked), the instance is already dead at the commit boundary, the
%% applier terminates while paused on its install cap with a commit owed,
%% and the projection read under a cell apply raises
%% (`bondy_oplog_projection_ets:get/3` mocked).
%% Not covered: an instance that dies during the barrier call; that exit
%% propagates.
-module(bondy_oplog_commit_barrier_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).

commit_barrier_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun(Dir) ->
            {timeout, 60, fun() ->
                failed_flush_stops_and_commits_nothing(Dir)
            end}
        end,
        fun(Dir) ->
            {timeout, 60, fun() -> dead_instance_withholds_offset(Dir) end}
        end,
        fun(Dir) ->
            {timeout, 60, fun() ->
                terminate_owing_commit_loses_nothing(Dir)
            end}
        end,
        fun(Dir) ->
            {timeout, 60, fun() -> failed_read_reapplies_the_event(Dir) end}
        end
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = filename:join(
        "/tmp/" ++ os:getpid(),
        "commitbarrier_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

cleanup(Dir) ->
    _ = meck:unload(),
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    _ =
        try
            del_tree(Dir)
        catch
            _:_ -> ok
        end,
    ok.

%% =============================================================================
%% TEST BODIES
%% =============================================================================

failed_flush_stops_and_commits_nothing(Dir) ->
    {InstId, NS, _Opts, Shard} = boot(Dir),
    append_batch(InstId, 1, 2),
    WalDir = wal_dir(InstId),
    CO0 = consumer_offset(WalDir),

    SupPid = bondy_oplog_registry:sup_pid(InstId),
    Instance = bondy_oplog_registry:instance_pid(InstId),
    Applier = bondy_oplog_registry:applier_pid(InstId),
    IMRef = monitor(process, Instance),
    AMRef = monitor(process, Applier),
    ok = sys:suspend(SupPid),
    try
        fail_flush(),
        append(InstId, 2, 1),
        ?assertMatch(
            {{mst_flush_failed, injected}, _}, await_down(IMRef, Instance)
        ),
        _ = await_down(AMRef, Applier),
        ?assertEqual(
            CO0,
            consumer_offset(WalDir),
            "consumer.offset advanced past a root that failed to flush"
        )
    after
        _ = meck:unload(),
        ok = sys:resume(SupPid)
    end,

    ok = await_restart(InstId, Instance),
    ok = bondy_oplog_test_projection:drain(InstId),
    ?assertEqual(3, bondy_oplog:size(InstId)),
    ?assertEqual(0, frames_after(InstId, consumer_offset(WalDir))),
    teardown(InstId, NS, Shard).

dead_instance_withholds_offset(Dir) ->
    {InstId, NS, _Opts, Shard} = boot(Dir),
    append_batch(InstId, 1, 2),
    WalDir = wal_dir(InstId),
    CO0 = consumer_offset(WalDir),

    SupPid = bondy_oplog_registry:sup_pid(InstId),
    Applier = bondy_oplog_registry:applier_pid(InstId),
    Instance = bondy_oplog_registry:instance_pid(InstId),
    ok = sys:suspend(Applier),
    append(InstId, 2, 1),
    %% Hold the one_for_all restart back so the applier meets a dead
    %% instance at its commit boundary rather than a shutdown.
    ok = sys:suspend(SupPid),
    try
        MRef = monitor(process, Instance),
        exit(Instance, kill),
        receive
            {'DOWN', MRef, process, Instance, _} -> ok
        end,
        AMRef = monitor(process, Applier),
        ok = sys:resume(Applier),
        ?assertMatch({noproc, _}, await_down(AMRef, Applier)),
        ?assertEqual(
            CO0,
            consumer_offset(WalDir),
            "consumer.offset advanced past installs cast to a dead instance"
        )
    after
        ok = sys:resume(SupPid)
    end,
    teardown(InstId, NS, Shard).

terminate_owing_commit_loses_nothing(Dir) ->
    {InstId, NS, _Opts, Shard} = boot(Dir, #{
        max_install_in_flight => 1,
        applier => #{commit_every => 1000, apply_batch_max_events => 1}
    }),
    append_batch(InstId, 1, 2),
    Instance = bondy_oplog_registry:instance_pid(InstId),
    Applier = bondy_oplog_registry:applier_pid(InstId),
    ok = sys:suspend(Applier),
    append(InstId, 2, 1),
    append(InstId, 2, 2),
    %% The applier casts one install, which the suspended instance never
    %% acknowledges, so the cap pauses it with that event uncommitted.
    ok = sys:suspend(Instance),
    ok = sys:resume(Applier),
    ok = await_paused(InstId, Applier),
    exit(Instance, kill),

    ok = await_restart(InstId, Instance),
    ok = bondy_oplog_test_projection:drain(InstId),
    ?assertEqual(4, bondy_oplog:size(InstId)),
    teardown(InstId, NS, Shard).

failed_read_reapplies_the_event(Dir) ->
    {InstId, NS, _Opts, Shard} = boot(Dir),
    append_batch(InstId, 1, 2),
    Instance = bondy_oplog_registry:instance_pid(InstId),
    ok = fail_first_read(),
    append(InstId, 2, 1),

    ok = await_restart(InstId, Instance),
    ok = bondy_oplog_test_projection:drain(InstId),
    ?assertMatch(
        {<<"k_2_1">>, _}, bondy_oplog_core:read(NS, primary, <<"k_2_1">>)
    ),
    teardown(InstId, NS, Shard).

%% =============================================================================
%% HELPERS
%% =============================================================================

boot(Dir) ->
    boot(Dir, #{applier => #{commit_every => 1}}).

boot(Dir, Extra) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Shard = register_shard(NS),
    ApplierOpts = maps:get(applier, Extra),
    Opts = (maps:remove(applier, Extra))#{
        origin => bondy_oplog_origin:new(),
        backend => bondy_mst_pack_store,
        storage_path => unicode:characters_to_binary(Dir),
        seed => true,
        applier => ApplierOpts#{cell_apply_target => {NS, primary, 0}}
    },
    {ok, _} = bondy_oplog:start_instance(InstId, Opts),
    {InstId, NS, Opts, Shard}.

teardown(InstId, NS, {Cache, Proj}) ->
    _ = bondy_oplog:stop_instance(InstId),
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache).

await_down(MRef, Pid) ->
    receive
        {'DOWN', MRef, process, Pid, Reason} -> Reason
    after 10000 ->
        error({still_alive, Pid})
    end.

await_paused(InstId, Applier) ->
    await_paused(InstId, Applier, 200).

await_paused(_InstId, _Applier, 0) ->
    error(install_never_dispatched);
await_paused(InstId, Applier, N) ->
    Ref = bondy_oplog_registry:install_in_flight(InstId),
    case atomics:get(Ref, 1) >= 1 of
        true ->
            %% Handled only once the dispatching drain pass has returned.
            _ = sys:get_state(Applier),
            ok;
        false ->
            receive
            after 50 -> await_paused(InstId, Applier, N - 1)
            end
    end.

await_restart(InstId, OldPid) ->
    await_restart(InstId, OldPid, 200).

await_restart(InstId, _OldPid, 0) ->
    error({no_restart, InstId});
await_restart(InstId, OldPid, N) ->
    case bondy_oplog_registry:instance_pid(InstId) of
        Pid when is_pid(Pid), Pid =/= OldPid ->
            Applier = bondy_oplog_registry:applier_pid(InstId),
            case is_pid(Applier) andalso is_process_alive(Applier) of
                true -> ok;
                false -> retry_restart(InstId, OldPid, N)
            end;
        _ ->
            retry_restart(InstId, OldPid, N)
    end.

retry_restart(InstId, OldPid, N) ->
    receive
    after 50 -> await_restart(InstId, OldPid, N - 1)
    end.

fail_flush() ->
    ok = meck:new(bondy_mst, [passthrough, no_link]),
    ok = meck:expect(bondy_mst, flush, fun(_) -> {error, injected} end).

fail_first_read() ->
    Calls = counters:new(1, []),
    ok = meck:new(bondy_oplog_projection_ets, [passthrough, no_link]),
    ok = meck:expect(bondy_oplog_projection_ets, get, fun(H, B, K) ->
        ok = counters:add(Calls, 1, 1),
        case counters:get(Calls, 1) of
            1 -> error(injected_read_failure);
            _ -> meck:passthrough([H, B, K])
        end
    end).

wal_dir(InstId) ->
    View = bondy_oplog_wal:reader_view(bondy_oplog_registry:wal_pid(InstId)),
    maps:get(dir, View).

consumer_offset(WalDir) ->
    case bondy_log_state:read_consumer_offset(WalDir) of
        {ok, CO} -> CO;
        {error, _} -> none
    end.

frames_after(InstId, CO) ->
    Start =
        {offset, bondy_log_state:committed_segment(CO),
            bondy_log_state:committed_frame_offset(CO)},
    {ok, It} = bondy_log_reader:open(
        bondy_oplog_registry:wal_pid(InstId), Start, [{follow, false}]
    ),
    count_frames(It, 0).

count_frames(It0, N) ->
    case bondy_log_reader:next(It0) of
        {ok, _Batch, _Keys, _Pos, It} ->
            count_frames(It, N + 1);
        _ ->
            _ = bondy_log_reader:close(It0),
            N
    end.

append_batch(InstId, I, N) ->
    lists:foreach(
        fun(J) ->
            append(InstId, I, J),
            ok = bondy_oplog_test_projection:drain(InstId)
        end,
        lists:seq(1, N)
    ).

append(InstId, I, J) ->
    Key =
        <<"k_", (integer_to_binary(I))/binary, "_",
            (integer_to_binary(J))/binary>>,
    _ = bondy_oplog:append(
        InstId, {cell_apply, ?B, Key, {set, I * 1000 + J, Key}}
    ),
    ok.

mk_id() ->
    list_to_binary(
        "cb_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

ns_of(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

register_shard(NS) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => lww_register,
        overlay => disabled
    }),
    {Cache, Proj}.

del_tree(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            {ok, Names} = file:list_dir(Dir),
            [del_tree(filename:join(Dir, N)) || N <- Names],
            file:del_dir(Dir);
        false ->
            file:delete(Dir)
    end.
