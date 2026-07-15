%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% End-to-end tests for the multi-value register through the real tier_2
%% substrate (`bondy_db:apply/4` → `apply_with_context` stamps the cell's
%% observed causal context into the event `meta` → `mv_register:apply_op/4`
%% joins it). Exercises the seams the pure unit/PropEr tests cannot:
%%
%%   - the server-side context stamp (read-your-writes through the
%%     applier's single-cell scope),
%%   - cross-replica convergence over a real MST `sync`, and
%%   - the DVV surviving a compaction checkpoint.

-module(bondy_db_mv_register_e2e_test).

-include_lib("eunit/include/eunit.hrl").

-define(MV, bondy_oplog_crdt_mv_register).

%% =============================================================================
%% Fixture
%% =============================================================================

mv_register_e2e_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"info reports tier_2", fun reports_tier_2/0},
            {"sequential writes collapse (read-your-writes)",
                fun sequential_collapse/0},
            {"distinct cells are independent", fun distinct_cells/0},
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
    {Db, _O} = open_db(mvreg_info),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ?assertEqual(tier_2, maps:get(causal_tier, bondy_db:info(T))),
    ok = bondy_db:close(Db).

%% Two sequential writes to the same cell: the second observes the first
%% (the stamp reads the committed projection), so it dominates — a single
%% value, not a sibling.
sequential_collapse() ->
    {Db, _O} = open_db(mvreg_seq),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ok = bondy_db:apply(T, <<"r">>, <<"k">>, {set, <<"v1">>}),
    ?assertEqual(
        {ok, [<<"v1">>], read_hlc},
        normalise(bondy_db:read(T, <<"r">>, <<"k">>))
    ),
    ok = bondy_db:apply(T, <<"r">>, <<"k">>, {set, <<"v2">>}),
    ?assertEqual(
        {ok, [<<"v2">>], read_hlc},
        normalise(bondy_db:read(T, <<"r">>, <<"k">>))
    ),
    ok = bondy_db:close(Db).

distinct_cells() ->
    {Db, _O} = open_db(mvreg_distinct),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ok = bondy_db:apply(T, <<"r">>, <<"k1">>, {set, <<"a">>}),
    ok = bondy_db:apply(T, <<"r">>, <<"k2">>, {set, <<"b">>}),
    ?assertEqual(
        {ok, [<<"a">>], read_hlc},
        normalise(bondy_db:read(T, <<"r">>, <<"k1">>))
    ),
    ?assertEqual(
        {ok, [<<"b">>], read_hlc},
        normalise(bondy_db:read(T, <<"r">>, <<"k2">>))
    ),
    ok = bondy_db:close(Db).

%% Two replicas (distinct origins) write the same cell without observing
%% each other, then sync both directions. Both values survive as siblings
%% and the two replicas converge to the same value and MST root.
concurrent_replicas_converge() ->
    {DbA, _Oa} = open_db(mvreg_conv_a),
    {DbB, _Ob} = open_db(mvreg_conv_b),
    {ok, Ta} = bondy_db:open_table(DbA, items, #{}),
    {ok, Tb} = bondy_db:open_table(DbB, items, #{}),
    Ia = instance_of(Ta),
    Ib = instance_of(Tb),
    %% Concurrent writes — neither observes the other yet.
    ok = bondy_db:apply(Ta, <<"r">>, <<"k">>, {set, <<"va">>}),
    ok = bondy_db:apply(Tb, <<"r">>, <<"k">>, {set, <<"vb">>}),
    %% Bidirectional sync to exchange events.
    {ok, _} = bondy_oplog:sync(Ia, Ib),
    {ok, _} = bondy_oplog:sync(Ib, Ia),
    ok = bondy_oplog:await_apply(Ia),
    ok = bondy_oplog:await_apply(Ib),
    %% Peer-received events sit in the MST until the applier replays them
    %% into the per-cell projection; force that barrier so the read below
    %% observes the merged events (production casts it async after sync).
    ok = replay(Ia),
    ok = replay(Ib),
    %% Both replicas now see both concurrent siblings.
    {ok, {Va, _}} = bondy_db:read(Ta, <<"r">>, <<"k">>),
    {ok, {Vb, _}} = bondy_db:read(Tb, <<"r">>, <<"k">>),
    ?assertEqual([<<"va">>, <<"vb">>], Va),
    ?assertEqual([<<"va">>, <<"vb">>], Vb),
    ?assertEqual(bondy_oplog:root_hash(Ia), bondy_oplog:root_hash(Ib)),
    ok = bondy_db:close(DbA),
    ok = bondy_db:close(DbB).

%% The DVV lives in the cell's StateBytes; compaction folds the stable
%% event prefix into the checkpoint (the projection). After compacting the
%% underlying instance, the read still returns the value — the DVV survived
%% the encode/decode round-trip into the checkpoint.
survives_compaction() ->
    {Db, _O} = open_db(mvreg_compact),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ok = bondy_db:apply(T, <<"r">>, <<"k">>, {set, <<"v1">>}),
    ok = bondy_db:apply(T, <<"r">>, <<"k">>, {set, <<"v2">>}),
    I = instance_of(T),
    %% Single-replica self-peer so the compaction watermark can advance.
    LocalRoot = bondy_oplog:root_hash(I),
    bondy_oplog_peer_state:record_sync_complete(
        {peer, mvreg_dummy}, I, LocalRoot
    ),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, _, _}} = bondy_oplog:compact(I),
    {ok, {V, _}} = bondy_db:read(T, <<"r">>, <<"k">>),
    ?assertEqual([<<"v2">>], V),
    bondy_oplog_peer_state:forget_peer({peer, mvreg_dummy}),
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
        crdt_module => ?MV,
        oplog_instance_opts => #{origin => Origin}
    }),
    {Db, Origin}.

instance_of(Table) ->
    #{0 := InstanceId} = maps:get(instance_ids, Table),
    InstanceId.

%% Force the synchronous peer-event replay barrier: project events the
%% sync session installed into the MST onto the per-cell projection.
replay(InstanceId) ->
    Pid = bondy_oplog_registry:applier_pid(InstanceId),
    bondy_oplog_applier:replay_cell_events_sync(Pid).

%% Collapse the read HLC (timing-dependent) to a fixed atom for assertions.
normalise({ok, {V, _Hlc}}) -> {ok, V, read_hlc};
normalise(Other) -> Other.
