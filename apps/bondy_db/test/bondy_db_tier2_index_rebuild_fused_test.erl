%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Secondary-index rebuild (`bondy_db:rebuild_index/2`) on a **fused** table
%% — the fused mirror of `bondy_db_tier2_index_rebuild_test.erl`.
%% `bondy_oplog_index_rebuild:refold_primary/1` previously dispatched only
%% to the applier: for a fused instance (which has none by design) it fell
%% into the "applier restarting, will self-resolve" branch — WRONG for
%% fused (permanent, not transient) — so the rebuild silently no-oped: the
%% rebuild orchestrator wipes the target index shard first, and the never-
%% dispatched re-derive step left it empty forever. `bondy_oplog_
%% cell_reindex:reindex/3` (new, shared with the applier) now runs the
%% actual re-derive in-process on the fused instance.
-module(bondy_db_tier2_index_rebuild_fused_test).

-include_lib("eunit/include/eunit.hrl").

-define(AW, bondy_oplog_crdt_aw_map).

tier2_index_rebuild_fused_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"rebuild on a fused table re-derives the index (was a silent no-op)",
                {timeout, 30, fun rebuild_repopulates_index/0}}
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

rebuild_repopulates_index() ->
    {Db, _O} = open_fused_db(t2idx_fused),
    {ok, T} = open_indexed(Db),
    R = <<"r1">>,
    K = <<"u1">>,
    ok = bondy_db:apply(T, R, K, {put, <<"status">>, <<"active">>}),
    ok = bondy_db:apply(T, R, K, {put, <<"name">>, <<"n1">>}),

    %% The live cell converged.
    {ok, {V, _}} = bondy_db:read(T, R, K),
    ?assertEqual(
        #{<<"status">> => [<<"active">>], <<"name">> => [<<"n1">>]}, V
    ),

    %% A rebuild must re-derive the index from the live cell — before the
    %% fix this silently did nothing on a fused table, leaving the
    %% wiped-then-never-repopulated shard empty.
    ok = bondy_db:rebuild_index(T, by_status),
    ?assertEqual([<<"n1">>], name_col(T, R)),
    ok = bondy_db:close(Db).

%% =============================================================================
%% Helpers
%% =============================================================================

open_fused_db(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        crdt_module => ?AW,
        fused => true,
        oplog_instance_opts => #{origin => Origin}
    }),
    {Db, Origin}.

open_indexed(Db) ->
    bondy_db:open_table(Db, items, #{
        fold_module => lww_register,
        crdt_module => ?AW,
        indexes => [
            #{
                name => by_status,
                extract => [<<"status">>],
                projects => [[<<"name">>]]
            }
        ]
    }).

name_col(Table, Realm) ->
    {ok, [{<<"u1">>, Cols}]} =
        bondy_db:index_get(Table, Realm, by_status, <<"active">>, #{
            max_lag => 60000
        }),
    maps:get([<<"name">>], Cols).
