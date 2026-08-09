%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Regression for the tier_2 secondary-index REBUILD divergence.
%%
%% A secondary index is rebuilt from the primary on the mandatory startup
%% backfill, after a back-pressure saturation drop, after a writer crash,
%% and on the operator `rebuild_index/2` call. The rebuild must re-derive
%% the index from each live cell's CURRENT (converged) projection value.
%%
%% What this pins: the rebuild must read each cell's current value, not
%% re-fold the primary's MST by re-applying every historical `cell_apply`
%% event onto the already-advanced projection cell. For a context-carrying
%% (tier_2) CRDT that re-application is NOT idempotent — a historical event
%% re-mints its dot and, because the advanced cell holds newer dots the
%% historical event never observed, the per-event intermediate states
%% re-introduce superseded dots as spurious MV-leaf siblings. The primary
%% reconverges (the complete causal suffix re-collapses them) but the index,
%% which captures a per-event term-diff, would latch a divergent intermediate
%% (e.g. `[n7, n8]` where the live cell is `[n8]`).
%%
%% Two directions are pinned:
%%   1. Sequential dominance: the rebuilt projected column EXACTLY equals
%%      the live column — no resurrected superseded siblings.
%%   2. Genuine concurrency: the rebuilt column PRESERVES legitimate
%%      concurrent siblings (the fix reads the value, it does not collapse
%%      it).

-module(bondy_db_tier2_index_rebuild_test).

-include_lib("eunit/include/eunit.hrl").

-define(AW, bondy_oplog_crdt_aw_map).

%% =============================================================================
%% Fixture
%% =============================================================================

tier2_index_rebuild_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"rebuild does not resurrect superseded siblings",
                {timeout, 30, fun no_spurious_siblings/0}},
            {"rebuild preserves genuine concurrent siblings",
                {timeout, 30, fun preserves_concurrent_siblings/0}}
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

%% Eight sequential dominating writes to one field of one cell collapse to
%% a single live value. A rebuild must reproduce exactly that value in the
%% projected index column — re-folding the eight events would resurrect the
%% superseded `n7` as a spurious sibling.
no_spurious_siblings() ->
    {Db, _O} = open_db(t2idx_seq),
    {ok, T} = open_indexed(Db),
    R = <<"r1">>,
    K = <<"u1">>,
    ok = bondy_db:apply(T, R, K, {put, <<"status">>, <<"active">>}),
    lists:foreach(
        fun(N) ->
            Name = <<"n", (integer_to_binary(N))/binary>>,
            ok = bondy_db:apply(T, R, K, {put, <<"name">>, Name})
        end,
        lists:seq(1, 8)
    ),

    %% The live cell collapsed to the last write.
    {ok, {V, _}} = bondy_db:read(T, R, K),
    ?assertEqual(
        #{<<"status">> => [<<"active">>], <<"name">> => [<<"n8">>]}, V
    ),

    %% The live index column (after a flush) is the converged column.
    ok = flush(T, by_status),
    LiveCol = name_col(T, R),
    ?assertEqual([<<"n8">>], LiveCol),

    %% A rebuild reproduces it EXACTLY — no resurrected `n7`.
    ok = bondy_db:rebuild_index(T, by_status),
    RebuiltCol = name_col(T, R),
    ?assertEqual(LiveCol, RebuiltCol),
    ?assertEqual([<<"n8">>], RebuiltCol),
    ok = bondy_db:close(Db).

%% Two replicas write the same map-key concurrently (neither observes the
%% other), then sync. The converged cell holds both siblings. A rebuild on
%% one replica must keep both — reading the value preserves concurrency.
preserves_concurrent_siblings() ->
    {DbA, _Oa} = open_db(t2idx_conv_a),
    {DbB, _Ob} = open_db(t2idx_conv_b),
    {ok, Ta} = open_indexed(DbA),
    {ok, Tb} = open_indexed(DbB),
    Ia = instance_of(Ta),
    Ib = instance_of(Tb),
    R = <<"r1">>,
    K = <<"u1">>,

    %% A stamps the indexed term + one concurrent value; B the other.
    ok = bondy_db:apply(Ta, R, K, {put, <<"status">>, <<"active">>}),
    ok = bondy_db:apply(Ta, R, K, {put, <<"color">>, <<"red">>}),
    ok = bondy_db:apply(Tb, R, K, {put, <<"color">>, <<"blue">>}),

    %% Exchange events both ways and force the per-cell projection replay.
    {ok, _} = bondy_oplog:sync(Ia, Ib),
    {ok, _} = bondy_oplog:sync(Ib, Ia),
    ok = bondy_oplog:await_apply(Ia),
    ok = bondy_oplog:await_apply(Ib),
    ok = replay(Ia),
    ok = replay(Ib),

    %% The converged cell on A holds both color siblings.
    {ok, {Va, _}} = bondy_db:read(Ta, R, K),
    ?assertEqual(
        #{
            <<"status">> => [<<"active">>],
            <<"color">> => [<<"blue">>, <<"red">>]
        },
        Va
    ),

    %% Rebuild A's index and confirm the projected column keeps both.
    ok = bondy_db:rebuild_index(Ta, by_status),
    ?assertEqual([<<"blue">>, <<"red">>], color_col(Ta, R)),
    ok = bondy_db:close(DbA),
    ok = bondy_db:close(DbB).

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

%% An aw_map table indexed by `status`, projecting the `name` and `color`
%% fields, so a rebuild's projected column can be checked against the live
%% cell value.
open_indexed(Db) ->
    bondy_db:open_table(Db, items, #{
        fold_module => lww_register,
        crdt_module => ?AW,
        indexes => [
            #{
                name => by_status,
                extract => [<<"status">>],
                projects => [[<<"name">>], [<<"color">>]]
            }
        ]
    }).

instance_of(Table) ->
    #{0 := InstanceId} = maps:get(instance_ids, Table),
    InstanceId.

replay(InstanceId) ->
    Pid = bondy_oplog_registry:applier_pid(InstanceId),
    bondy_oplog_applier:replay_cell_events_sync(Pid).

name_col(Table, Realm) ->
    col(Table, Realm, [<<"name">>]).

color_col(Table, Realm) ->
    col(Table, Realm, [<<"color">>]).

col(Table, Realm, Path) ->
    {ok, [{<<"u1">>, Cols}]} =
        bondy_db:index_get(Table, Realm, by_status, <<"active">>, #{
            max_lag => 60000
        }),
    maps:get(Path, Cols).

flush(Table, IndexName) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{IndexName := #{sec_shard_count := N}} = maps:get(indexes, Info),
    lists:foreach(
        fun(Shard) ->
            {ok, Entry} = bondy_oplog_core_registry:lookup(
                NS, IndexName, Shard
            ),
            Pid = bondy_oplog_core_registry:entry_writer_pid(Entry),
            ok = bondy_oplog_secondary_writer:flush_sync(Pid)
        end,
        lists:seq(0, N - 1)
    ).
