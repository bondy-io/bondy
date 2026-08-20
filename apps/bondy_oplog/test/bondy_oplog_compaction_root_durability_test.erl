%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Durability-ordering coverage for compaction on a durable (pack-store)
%% instance.
%%
%% Compaction advances the durable checkpoint watermark
%% (`put_checkpoint/3`) and truncates the MST in memory, but does NOT
%% flush the (truncated) MST root. The root is only persisted at the next
%% commit barrier (`drain_install_queue` -> `flush_mst_root`). The reboot
%% resume position is `max(durable_root_last.hlc, durable_watermark.hlc)`
%% (`bondy_oplog_applier:resume_position/2`), so if the durable watermark
%% can outrun the durable MST root, a crash between compaction and the next
%% barrier can leave the on-disk root inconsistent with the checkpoint.
%%
%% This test pins the invariant deterministically with `commit_every => 1`
%% (so the root IS durable before compaction): after `compact`, the on-disk
%% manifest root must equal the in-memory root. If compaction does not flush
%% the truncated root, the on-disk root lags and the assertion fails.
-module(bondy_oplog_compaction_root_durability_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).

compaction_root_durability_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Dir) ->
        [
            {timeout, 60, fun() -> compaction_persists_truncated_root(Dir) end}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = filename:join(
        "/tmp/" ++ os:getpid(),
        "ccrootdur_" ++
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
    _ =
        try
            del_tree(Dir)
        catch
            _:_ -> ok
        end,
    ok.

compaction_persists_truncated_root(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    StartOpts = start_opts(NS, Dir),
    {ok, _} = bondy_oplog:start_instance(InstId, StartOpts),
    try
        append_batch(InstId, 1, 10),
        _ = bondy_oplog_instance:await_apply(InstId),
        ?assertEqual(10, bondy_oplog:size(InstId)),

        PackDir = bondy_oplog_path:instance_dir(
            InstId, unicode:characters_to_binary(Dir), StartOpts
        ),
        %% With commit_every => 1 the root is durable before compaction.
        ?assertNotEqual(undefined, disk_root(PackDir)),

        Root = bondy_oplog_instance:root_hash(InstId),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(InstId, [Root])
        ),
        ?assertEqual(0, bondy_oplog:size(InstId)),

        %% INVARIANT: compaction's effect on the root must be durable in
        %% lockstep with the checkpoint it advanced — so the on-disk root
        %% equals the in-memory (post-truncate) root. If they differ, the
        %% durable checkpoint has outrun the durable MST root and a crash
        %% here corrupts the shard on reboot.
        MemRoot = bondy_oplog_instance:root_hash(InstId),
        ?assertEqual(MemRoot, disk_root(PackDir))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

disk_root(PackDir) ->
    case bondy_mst_pack_manifest:read(PackDir) of
        {ok, M} -> bondy_mst_pack_manifest:current_root(M);
        _ -> undefined
    end.

start_opts(NS, Dir) ->
    #{
        origin => bondy_oplog_origin:new(),
        fold_module => lww_register,
        backend => bondy_mst_pack_store,
        storage_path => unicode:characters_to_binary(Dir),
        seed => true,
        applier => #{cell_apply_target => {NS, primary, 0}, commit_every => 1}
    }.

mk_id() ->
    list_to_binary(
        "ccrd_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

register_shard(NS, Index, Shard, FoldModule) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => FoldModule,
        overlay => disabled
    }),
    {Cache, Proj}.

close_shard(Cache, Proj) ->
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

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

del_tree(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            {ok, Names} = file:list_dir(Dir),
            [del_tree(filename:join(Dir, N)) || N <- Names],
            file:del_dir(Dir);
        false ->
            file:delete(Dir)
    end.
