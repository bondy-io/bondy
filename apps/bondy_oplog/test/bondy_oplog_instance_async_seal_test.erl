%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Instance-level integration for the asynchronous pack-store seal
%% (`seal_mode => async`). A durable instance opened in async mode must:
%%
%%  1. drive the seal off the install/commit critical path — the
%%     `[bondy_mst, page_store, seal_roll]` event (emitted ONLY by the
%%     async `maybe_roll_for_seal/1`, never by the synchronous `seal/1`)
%%     fires, and sealed packs materialise on disk;
%%  2. keep the instance gen_server alive throughout (the monitored worker
%%     lifecycle never faults the instance under a normal workload);
%%  3. lose no data — every appended event survives a stop + restart, where
%%     the reopen recovery finalises any seal the stop interrupted.
%%
%% Harness mirrors `bondy_oplog_replay_sealed_pack_test`.
%% =============================================================================

-module(bondy_oplog_instance_async_seal_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
-define(N, 200).
-define(SEAL_EVERY, 10).

async_seal_off_process_and_survives_restart_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Dir) ->
        {timeout, 60, fun() -> run(Dir) end}
    end}.

run(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Origin = bondy_oplog_origin:new(),
    {C, P} = register_shard(NS),

    %% Count the async-roll events: `seal_roll` is emitted only by the
    %% asynchronous path, so a non-zero count proves the seal ran off the
    %% put/commit critical path rather than inline.
    Counter = counters:new(1, [atomics]),
    HId = {?MODULE, seal_roll, InstId},
    ok = telemetry:attach(
        HId,
        [bondy_mst, page_store, seal_roll],
        fun
            (_E, _M, #{instance_id := I}, Ctr) when I == InstId ->
                counters:add(Ctr, 1, 1);
            (_E, _M, _Meta, _Ctr) ->
                ok
        end,
        Counter
    ),

    {ok, _} = open_async_instance(InstId, NS, Dir, Origin, ?SEAL_EVERY),
    append_batch(InstId, 1, ?N),
    _ = bondy_oplog_instance:await_apply(InstId),
    ?assertEqual(?N, bondy_oplog:size(InstId)),

    %% The seal worker runs off the instance process — wait for at least one
    %% sealed pack to appear on disk.
    ok = wait_for(fun() -> length(sealed_packs(Dir)) >= 1 end, 5000),
    ok = telemetry:detach(HId),

    %% The async roll path fired (would be 0 if put had sealed inline).
    ?assert(
        counters:get(Counter, 1) >= 1,
        "no seal_roll telemetry — the async roll path did not run"
    ),

    %% The instance gen_server is alive (the worker lifecycle never faulted it).
    InstP = bondy_oplog_registry:instance_pid(InstId),
    ?assert(is_process_alive(InstP)),

    %% Every appended pair is present in the durable MST.
    {ok, {_Root0, Pairs0}} = bondy_oplog_instance:replay_pairs(
        InstP, undefined
    ),
    ?assertEqual(?N, length(Pairs0)),

    %% Stop (kills any in-flight seal worker) + restart: the reopen recovery
    %% re-seals an interrupted roll, so no data is lost.
    ok = bondy_oplog:stop_instance(InstId),
    {ok, _} = open_async_instance(InstId, NS, Dir, Origin, ?SEAL_EVERY),
    ok = bondy_oplog:await_drain(InstId),

    ?assertEqual(?N, bondy_oplog:size(InstId)),
    InstP2 = bondy_oplog_registry:instance_pid(InstId),
    {ok, {_Root1, Pairs1}} = bondy_oplog_instance:replay_pairs(
        InstP2, undefined
    ),
    ?assertEqual(?N, length(Pairs1)),

    ok = bondy_oplog:stop_instance(InstId),
    close_shard(C, P),
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
    ok.

%% =============================================================================
%% Helpers (mirrored from bondy_oplog_replay_sealed_pack_test)
%% =============================================================================

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = filename:join(
        "/tmp/" ++ os:getpid(),
        "aseal_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

cleanup(Dir) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    _ = (catch del_tree(Dir)),
    ok.

mk_id() ->
    list_to_binary(
        "aseal_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

ns_of(Id) when is_binary(Id) ->
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

close_shard(Cache, Proj) ->
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache).

open_async_instance(InstanceId, NS, Dir, Origin, SealEvery) ->
    bondy_oplog:start_instance(InstanceId, #{
        origin => Origin,
        fold_module => lww_register,
        backend => bondy_mst_pack_store,
        storage_path => unicode:characters_to_binary(Dir),
        backend_options => #{
            auto_seal_records => SealEvery,
            seal_mode => async
        },
        seed => true,
        applier => #{cell_apply_target => {NS, primary, 0}}
    }).

append_batch(InstanceId, I, Batch) ->
    lists:foreach(
        fun(J) ->
            Key = key(I, J),
            Hlc = I * 1000 + J,
            _ = bondy_oplog:append(
                InstanceId, {cell_apply, ?B, Key, {set, Hlc, Key}}
            ),
            _ = bondy_oplog:projection(InstanceId)
        end,
        lists:seq(1, Batch)
    ).

key(I, J) ->
    <<"k_", (integer_to_binary(I))/binary, "_", (integer_to_binary(J))/binary>>.

sealed_packs(Dir) ->
    filelib:fold_files(
        Dir, "pack-.*\\.pack$", true, fun(F, Acc) -> [F | Acc] end, []
    ).

wait_for(_Pred, TimeoutMs) when TimeoutMs =< 0 ->
    {error, timeout};
wait_for(Pred, TimeoutMs) ->
    case Pred() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_for(Pred, TimeoutMs - 50)
    end.

del_tree(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            {ok, Names} = file:list_dir(Dir),
            [del_tree(filename:join(Dir, N)) || N <- Names],
            file:del_dir(Dir);
        false ->
            file:delete(Dir)
    end.
