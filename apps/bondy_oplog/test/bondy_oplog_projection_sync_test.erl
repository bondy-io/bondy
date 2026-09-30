%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% An applied-frontier claim is made once the projection acknowledges a write,
%% which on a durable adapter need not mean on disk. So the instance syncs the
%% projection before it truncates a claimed event and before it persists a
%% claim. Each case drives a durable (pack) instance whose projection is
%% `bondy_oplog_projection_sync_probe`:
%%
%% - `compaction_syncs_before_the_truncation_is_durable/1`: the first sync of
%%   a compaction runs while the durable MST root still holds every event,
%%   including when the truncate itself writes the root to disk.
%% - `a_failed_sync_persists_nothing/1`: `persist_frontier/1` returns the
%%   failure and writes no checkpoint.
%% - `a_claim_made_during_the_sync_is_not_persisted/1`: the frontier is read
%%   before the sync, so a claim that lands while it runs is not in the
%%   checkpoint.
%% - `every_table_on_the_instance_has_its_indexes_flushed/1`: two tables share
%%   the instance, as every table on a `per_shard` shard does; compaction
%%   flushes and syncs the durable index shards of both.
%%
%% Not covered: a truncation that drops nothing skips the sync, a cost
%% property only.
-module(bondy_oplog_projection_sync_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
-define(PROBE, bondy_oplog_projection_sync_probe).

projection_sync_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun(Dir) ->
            {timeout, 60, fun() ->
                compaction_syncs_before_the_truncation_is_durable(Dir)
            end}
        end,
        fun(Dir) ->
            {timeout, 60, fun() -> a_failed_sync_persists_nothing(Dir) end}
        end,
        fun(Dir) ->
            {timeout, 60, fun() ->
                a_claim_made_during_the_sync_is_not_persisted(Dir)
            end}
        end,
        fun(Dir) ->
            {timeout, 60, fun() ->
                every_table_on_the_instance_has_its_indexes_flushed(Dir)
            end}
        end
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = filename:join(
        "/tmp/" ++ os:getpid(),
        "projsync_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

cleanup(Dir) ->
    ok = ?PROBE:set_sync(fun(_) -> ok end),
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
%% Tests
%% =============================================================================

compaction_syncs_before_the_truncation_is_durable(Dir) ->
    {Id, Opts} = fresh(Dir),
    ok = append_batch(Id, 3),
    _ = bondy_oplog_instance:await_apply(Id),
    PackDir = bondy_oplog_path:instance_dir(
        Id, unicode:characters_to_binary(Dir), Opts
    ),
    Root = bondy_oplog_instance:root_hash(Id),
    ?assertEqual(Root, disk_root(PackDir)),
    %% Past the pack writer's default root-flush interval, so the truncate
    %% itself writes the truncated root to disk.
    timer:sleep(300),
    Test = self(),
    ok = ?PROBE:set_sync(fun(_) ->
        Test ! {synced, disk_root(PackDir)},
        ok
    end),
    ?assertMatch(
        {ok, {compacted, _, _}}, bondy_oplog_instance:compact(Id, [Root])
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),
    ?assertEqual(
        Root,
        receive
            {synced, R} -> R
        after 0 -> no_sync
        end
    ).

a_failed_sync_persists_nothing(Dir) ->
    {Id, _Opts} = fresh(Dir),
    ok = append_batch(Id, 3),
    _ = bondy_oplog_instance:await_apply(Id),
    ok = ?PROBE:set_sync(fun(_) -> {error, injected} end),
    ?assertEqual(
        {error, {projection_sync_failed, injected}},
        bondy_oplog_instance:persist_frontier(Id)
    ),
    ?assertEqual([], checkpoint_files(Dir, Id)).

a_claim_made_during_the_sync_is_not_persisted(Dir) ->
    {Id, _Opts} = fresh(Dir),
    Late = bondy_oplog_origin:new(),
    ok = ?PROBE:set_sync(fun(_) ->
        bondy_oplog_registry:merge_applied(Id, #{Late => [1]})
    end),
    ok = bondy_oplog_instance:persist_frontier(Id),
    ?assertEqual(1, maps:get(Late, bondy_oplog_registry:frontier(Id), 0)),
    ?assertEqual(
        [false],
        lists:usort([maps:is_key(Late, VV) || VV <- checkpointed(Dir, Id)])
    ).

every_table_on_the_instance_has_its_indexes_flushed(Dir) ->
    {Id, _Opts, NS} = fresh_ns(Dir),
    Sibling = binary_to_atom(<<"sibling_", Id/binary>>, utf8),
    ok = register_shard(Sibling, primary, #{instance_id => Id}),
    Test = self(),
    Writer = spawn_link(fun() -> fake_writer(Test) end),
    Indexes = [
        begin
            ok = register_shard(T, idx, #{}),
            ok = bondy_oplog_core_registry:set_writer_pid(T, idx, 0, Writer),
            {ok, E} = bondy_oplog_core_registry:lookup(T, idx, 0),
            bondy_oplog_core_registry:entry_projection_handle(E)
        end
     || T <- [NS, Sibling]
    ],
    ok = append_batch(Id, 3),
    _ = bondy_oplog_instance:await_apply(Id),
    ok = ?PROBE:set_sync(fun(H) ->
        Test ! {synced, H},
        ok
    end),
    Root = bondy_oplog_instance:root_hash(Id),
    ?assertMatch(
        {ok, {compacted, _, _}}, bondy_oplog_instance:compact(Id, [Root])
    ),
    ?assertEqual(2, length(drain(flushed))),
    ?assertEqual([], Indexes -- drain(synced)).

%% =============================================================================
%% Helpers
%% =============================================================================

fresh(Dir) ->
    {Id, Opts, _NS} = fresh_ns(Dir),
    {Id, Opts}.

fresh_ns(Dir) ->
    Id = list_to_binary(
        "projsync_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    NS = binary_to_atom(<<"ns_", Id/binary>>, utf8),
    ok = register_shard(NS, primary, #{instance_id => Id}),
    Opts = #{
        origin => bondy_oplog_origin:new(),
        backend => bondy_mst_pack_store,
        storage_path => unicode:characters_to_binary(Dir),
        seed => true,
        applier => #{cell_apply_target => {NS, primary, 0}, commit_every => 1}
    },
    {ok, _} = bondy_oplog:start_instance(Id, Opts),
    {Id, Opts, NS}.

register_shard(NS, Index, Extra) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, 0, #{}),
    {ok, Proj} = ?PROBE:open(NS, Index, 0, #{}),
    bondy_oplog_core_registry:register(NS, Index, 0, Extra#{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => ?PROBE,
        projection_handle => Proj,
        fold_module => lww_register,
        overlay => disabled
    }).

%% Answers every `bondy_oplog_secondary_writer:flush_sync/2` and reports it.
fake_writer(Test) ->
    receive
        {'$gen_call', From, flush_sync} ->
            Test ! {flushed, self()},
            gen_server:reply(From, ok),
            fake_writer(Test)
    end.

drain(Tag) ->
    receive
        {Tag, X} -> [X | drain(Tag)]
    after 0 -> []
    end.

append_batch(Id, N) ->
    lists:foreach(
        fun(J) ->
            Key = <<"k_", (integer_to_binary(J))/binary>>,
            _ = bondy_oplog:append(Id, {cell_apply, ?B, Key, {set, J, Key}}),
            ok = bondy_oplog_test_projection:drain(Id)
        end,
        lists:seq(1, N)
    ).

disk_root(PackDir) ->
    case bondy_mst_pack_manifest:read(PackDir) of
        {ok, M} -> bondy_mst_pack_manifest:current_root(M);
        _ -> undefined
    end.

checkpointed(Dir, Id) ->
    [
        begin
            {ok, Bin} = file:read_file(F),
            {checkpoint_v1, _W, {projection_managed, frontier, VV, _M, _Meta}} =
                erlang:binary_to_term(Bin),
            VV
        end
     || F <- checkpoint_files(Dir, Id)
    ].

checkpoint_files(Dir, Id) ->
    [
        F
     || F <- filelib:wildcard(filename:join(Dir, "**/checkpoint.etf")),
        string:find(F, binary_to_list(Id)) =/= nomatch
    ].

del_tree(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            {ok, Names} = file:list_dir(Dir),
            [del_tree(filename:join(Dir, N)) || N <- Names],
            file:del_dir(Dir);
        false ->
            file:delete(Dir)
    end.
