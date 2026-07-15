%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Coverage for the AAE advertise integrity guard
%% (`bondy_oplog_instance:aae_root/1`).
%%
%% A node must never advertise an MST root it cannot fully serve: a peer
%% that pulls against such a root requests pages the responder returns
%% empty for (`peer_returned_empty_pages`), wedging the sync. `aae_root/1`
%% (used by `bondy_oplog_responder` for `get_root`) returns the current
%% root only when every page reachable from it is present; otherwise it
%% advertises `undefined` so the peer pulls nothing unservable and this
%% node heals via its own pull / WAL replay. `root_hash/1` keeps reporting
%% the real root for local use.
-module(bondy_oplog_aae_root_guard_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).

aae_root_guard_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Dir) ->
        [
            {timeout, 60, fun() -> healthy_advertises_real_root(Dir) end},
            {timeout, 60, fun() -> dangling_root_not_advertised(Dir) end}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = filename:join(
        "/tmp",
        "aaeroot_" ++
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

%% A healthy instance advertises its real root (and an empty instance
%% advertises `undefined`); the per-root cache stays correct across the
%% root changing.
healthy_advertises_real_root(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    StartOpts = start_opts(NS, Dir),
    {ok, _} = bondy_oplog:start_instance(InstId, StartOpts),
    try
        %% Empty: nothing to serve, advertise undefined.
        ?assertEqual(undefined, bondy_oplog_instance:root_hash(InstId)),
        ?assertEqual(undefined, bondy_oplog_instance:aae_root(InstId)),

        append_batch(InstId, 1, 50),
        _ = bondy_oplog_instance:await_apply(InstId),
        Root1 = bondy_oplog_instance:root_hash(InstId),
        ?assert(is_binary(Root1)),
        %% Healthy: advertise the real root (twice → exercises the cache).
        ?assertEqual(Root1, bondy_oplog_instance:aae_root(InstId)),
        ?assertEqual(Root1, bondy_oplog_instance:aae_root(InstId)),

        %% Root advances → cache invalidates, still advertises the real root.
        append_batch(InstId, 2, 50),
        _ = bondy_oplog_instance:await_apply(InstId),
        Root2 = bondy_oplog_instance:root_hash(InstId),
        ?assertNotEqual(Root1, Root2),
        ?assertEqual(Root2, bondy_oplog_instance:aae_root(InstId))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% A genuinely-dangling root (the persisted root references a page whose
%% bytes are physically absent) must NOT be advertised. We synthesise one by
%% injecting, via the raw pack store, a root page that references a child
%% that was never written, then restart with the applier GATED so WAL replay
%% cannot heal it — isolating the advertise guard.
%%
%% Note: a *tombstoned-but-present* page is NOT dangling — the store serves
%% physically-present pages (the tombstone is a GC/enumeration hint, not a
%% read mask), so danglehood now requires genuine absence.
dangling_root_not_advertised(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    StartOpts = start_opts(NS, Dir),
    {ok, _} = bondy_oplog:start_instance(InstId, StartOpts),
    append_batch(InstId, 1, 50),
    _ = bondy_oplog_instance:await_apply(InstId),
    Root = bondy_oplog_instance:root_hash(InstId),
    ?assert(is_binary(Root)),
    ?assertEqual(Root, bondy_oplog_instance:aae_root(InstId)),
    %% A real event key — the instance's init reads the MST's last key via
    %% bondy_oplog_event:key_hlc/1, so the synthetic page below must carry a
    %% valid event key, not a bare binary.
    {ok, EventKey} = bondy_oplog_instance:latest_key(InstId),
    ok = bondy_oplog:stop_instance(InstId),

    %% Inject a genuinely-dangling root: a page whose `low` points at a child
    %% hash that was never written (bytes physically absent).
    PackDir = bondy_oplog_path:instance_dir(
        InstId, unicode:characters_to_binary(Dir), StartOpts
    ),
    S0 = bondy_mst_pack_store:open(sha256, #{
        dir => PackDir, instance_id => InstId
    }),
    Ghost = crypto:hash(sha256, <<"never-written-child">>),
    Top = bondy_mst_page:new(1, Ghost, [{EventKey, <<"v">>, undefined}]),
    {TopHash, S1} = bondy_mst_pack_store:put(S0, Top),
    S2 = bondy_mst_pack_store:set_root(S1, TopHash),
    ok = bondy_mst_pack_store:close(S2),

    %% Restart with the applier gated: no WAL replay, so the dangling root
    %% persists for the duration of the assertion.
    Applier0 = maps:get(applier, StartOpts),
    GatedOpts = StartOpts#{applier => Applier0#{drain_gated => true}},
    {ok, _} = bondy_oplog:start_instance(InstId, GatedOpts),
    try
        %% Local view still reports the real (dangling) root...
        ?assertEqual(TopHash, bondy_oplog_instance:root_hash(InstId)),
        %% ...but AAE refuses to advertise it.
        ?assertEqual(undefined, bondy_oplog_instance:aae_root(InstId)),
        %% diagnose_root classifies the missing child as genuinely absent
        %% (never written), not present_but_masked.
        D = bondy_oplog_instance:diagnose_root(InstId),
        ?assertEqual(false, maps:get(servable, D)),
        ?assert(maps:get(absent, D) >= 1),
        ?assertEqual(0, maps:get(present_but_masked, D))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

start_opts(NS, Dir) ->
    #{
        origin => bondy_oplog_origin:new(),
        fold_module => lww_register,
        backend => bondy_mst_pack_store,
        storage_path => unicode:characters_to_binary(Dir),
        seed => true,
        applier => #{cell_apply_target => {NS, primary, 0}}
    }.

mk_id() ->
    list_to_binary(
        "aaer_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
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
