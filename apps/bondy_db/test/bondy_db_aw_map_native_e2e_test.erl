%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% End-to-end tests for the NATIVE add-wins observed-remove map
%% (`bondy_oplog_crdt_aw_map`) through the real tier_2 substrate
%% (`bondy_db:apply/4` → `apply_with_context` stamps the cell's observed
%% causal context into the event `meta` → `aw_map:apply_op/4` consumes it).
%% This is now the only aw_map: the former state-based fold and its
%% server-side `resolve_event` round-trip were removed in this rollout.
%%
%% Each (Bucket, Key) cell holds an entire aw_map; ops are
%% `{put, MapKey, V}` / `{rmv, MapKey}`. Exercises the seams the pure
%% unit/PropEr tests cannot:
%%
%%   - the server-side context stamp (read-your-writes, single-cell scope),
%%   - the pure observed-remove (no resolve_event round-trip),
%%   - cross-replica convergence over a real MST `sync`, and
%%   - the dot-store + context surviving a compaction checkpoint.

-module(bondy_db_aw_map_native_e2e_test).

-include_lib("eunit/include/eunit.hrl").

-define(AW, bondy_oplog_crdt_aw_map).

%% =============================================================================
%% Fixture
%% =============================================================================

aw_map_native_e2e_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"info reports tier_2", fun reports_tier_2/0},
            {"sequential puts collapse (read-your-writes)",
                fun sequential_collapse/0},
            {"observed remove removes the key", fun observed_remove/0},
            {"concurrent replicas converge to siblings",
                {timeout, 30, fun concurrent_replicas_converge/0}},
            {"value survives compaction checkpoint",
                {timeout, 30, fun survives_compaction/0}}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

reports_tier_2() ->
    {Db, _O} = open_db(awmapn_info),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ?assertEqual(tier_2, maps:get(causal_tier, bondy_db:info(T))),
    ok = bondy_db:close(Db).

%% Two sequential puts of the same map-key to the same cell: the second
%% observes the first (read-your-writes), so it dominates — a single value.
sequential_collapse() ->
    {Db, _O} = open_db(awmapn_seq),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ok = bondy_db:apply(T, <<"r">>, <<"c">>, {put, <<"k">>, <<"v1">>}),
    ?assertEqual(
        {ok, #{<<"k">> => [<<"v1">>]}, read_hlc},
        normalise(bondy_db:read(T, <<"r">>, <<"c">>))
    ),
    ok = bondy_db:apply(T, <<"r">>, <<"c">>, {put, <<"k">>, <<"v2">>}),
    ?assertEqual(
        {ok, #{<<"k">> => [<<"v2">>]}, read_hlc},
        normalise(bondy_db:read(T, <<"r">>, <<"c">>))
    ),
    ok = bondy_db:close(Db).

%% A remove that observed the put (read-your-writes) removes the map-key,
%% and leaves an independent key untouched (no cross-key contamination).
observed_remove() ->
    {Db, _O} = open_db(awmapn_rmv),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ok = bondy_db:apply(T, <<"r">>, <<"c">>, {put, <<"k1">>, <<"v1">>}),
    ok = bondy_db:apply(T, <<"r">>, <<"c">>, {put, <<"k2">>, <<"v2">>}),
    ok = bondy_db:apply(T, <<"r">>, <<"c">>, {rmv, <<"k1">>}),
    ?assertEqual(
        {ok, #{<<"k2">> => [<<"v2">>]}, read_hlc},
        normalise(bondy_db:read(T, <<"r">>, <<"c">>))
    ),
    ok = bondy_db:close(Db).

%% Two replicas (distinct origins) put the same map-key without observing
%% each other, then sync both directions. Both values survive as siblings
%% and the two replicas converge to the same value and MST root.
concurrent_replicas_converge() ->
    {DbA, _Oa} = open_db(awmapn_conv_a),
    {DbB, _Ob} = open_db(awmapn_conv_b),
    {ok, Ta} = bondy_db:open_table(DbA, items, #{}),
    {ok, Tb} = bondy_db:open_table(DbB, items, #{}),
    Ia = instance_of(Ta),
    Ib = instance_of(Tb),
    %% Concurrent writes to the same map-key — neither observes the other.
    ok = bondy_db:apply(Ta, <<"r">>, <<"c">>, {put, <<"k">>, <<"va">>}),
    ok = bondy_db:apply(Tb, <<"r">>, <<"c">>, {put, <<"k">>, <<"vb">>}),
    %% Bidirectional sync to exchange events.
    {ok, _} = bondy_oplog:sync(Ia, Ib),
    {ok, _} = bondy_oplog:sync(Ib, Ia),
    ok = bondy_oplog:await_apply(Ia),
    ok = bondy_oplog:await_apply(Ib),
    %% Peer-received events sit in the MST until the applier replays them
    %% into the per-cell projection; force that barrier (prod casts async).
    ok = replay(Ia),
    ok = replay(Ib),
    {ok, {Va, _}} = bondy_db:read(Ta, <<"r">>, <<"c">>),
    {ok, {Vb, _}} = bondy_db:read(Tb, <<"r">>, <<"c">>),
    ?assertEqual(#{<<"k">> => [<<"va">>, <<"vb">>]}, Va),
    ?assertEqual(#{<<"k">> => [<<"va">>, <<"vb">>]}, Vb),
    ?assertEqual(bondy_oplog:root_hash(Ia), bondy_oplog:root_hash(Ib)),
    ok = bondy_db:close(DbA),
    ok = bondy_db:close(DbB).

%% The dot-store + context live in the cell's StateBytes; compaction folds
%% the stable event prefix into the checkpoint. After compacting, the read
%% still returns the value — the state survived the encode/decode round-trip.
survives_compaction() ->
    {Db, _O} = open_db(awmapn_compact),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ok = bondy_db:apply(T, <<"r">>, <<"c">>, {put, <<"k">>, <<"v1">>}),
    ok = bondy_db:apply(T, <<"r">>, <<"c">>, {put, <<"k">>, <<"v2">>}),
    I = instance_of(T),
    LocalRoot = bondy_oplog:root_hash(I),
    bondy_oplog_peer_state:record_sync_complete(
        {peer, awmapn_dummy}, I, LocalRoot
    ),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, _, _}} = bondy_oplog:compact(I),
    {ok, {V, _}} = bondy_db:read(T, <<"r">>, <<"c">>),
    ?assertEqual(#{<<"k">> => [<<"v2">>]}, V),
    bondy_oplog_peer_state:forget_peer({peer, awmapn_dummy}),
    ok = bondy_db:close(Db).

%% =============================================================================
%% Helpers
%% =============================================================================

open_db(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        crdt_module => ?AW,
        oplog_instance_opts => #{origin => Origin}
    }),
    {Db, Origin}.

instance_of(Table) ->
    #{0 := InstanceId} = maps:get(instance_ids, Table),
    InstanceId.

replay(InstanceId) ->
    Pid = bondy_oplog_registry:applier_pid(InstanceId),
    bondy_oplog_applier:replay_cell_events_sync(Pid).

normalise({ok, {V, _Hlc}}) -> {ok, V, read_hlc};
normalise(Other) -> Other.
