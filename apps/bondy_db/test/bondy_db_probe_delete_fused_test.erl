%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% `bondy_db:probe_write/1` and `bondy_db:delete/3` on a **fused** instance
%% — both go through `bondy_db:probe_module/1`, which previously resolved
%% the instance's `cell_apply_target` via the applier only: for a fused
%% instance (which has none by design) it always returned `undefined`, so
%% `probe_write/1` always reported `{skip, no_crdt_module}` (breaking the
%% opt-in idle-latency heartbeat) and `delete/3` always returned
%% `{error, {no_crdt_module, _}}` (breaking whole-cell removal), regardless
%% of whether the table's CRDT actually supported either. `bondy_oplog_
%% instance:cell_apply_target/1` (new, mirroring the applier's) fixes the
%% resolution; both call sites needed no changes beyond that.
-module(bondy_db_probe_delete_fused_test).

-include_lib("eunit/include/eunit.hrl").

-define(EW, bondy_oplog_crdt_ew_flag).

probe_delete_fused_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"probe_write succeeds on a fused instance",
                {timeout, 30, fun probe_write_on_fused/0}},
            {"delete/3 removes a cell on a fused instance",
                {timeout, 30, fun delete_on_fused/0}}
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

probe_write_on_fused() ->
    {Db, _O} = open_fused_ew_db(probe_fused),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    Id = instance_of(T),
    ?assertEqual(undefined, bondy_oplog_registry:applier_pid(Id)),
    ?assertEqual(true, bondy_oplog_registry:fused(Id)),
    ?assertEqual(ok, bondy_db:probe_write(Id)),
    ?assertEqual(ok, bondy_db:probe_write(Id)),
    %% The reserved probe cell is invisible to a normal read.
    ?assertEqual({error, not_found}, bondy_db:read(T, <<"r">>, <<"k">>)),
    ok = bondy_db:close(Db).

delete_on_fused() ->
    {Db, _O} = open_fused_ew_db(delete_fused),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ok = bondy_db:apply(T, <<"r1">>, <<"f">>, enable),
    ?assertEqual(
        {ok, {true, hlc}}, strip_hlc(bondy_db:read(T, <<"r1">>, <<"f">>))
    ),

    %% delete/3 previously failed with {error, {no_crdt_module, _}} for
    %% any fused table, regardless of whether its CRDT supported removal.
    ok = bondy_db:delete(T, <<"r1">>, <<"f">>),
    ?assertEqual(
        {ok, {false, hlc}}, strip_hlc(bondy_db:read(T, <<"r1">>, <<"f">>))
    ),
    ok = bondy_db:close(Db).

%% =============================================================================
%% Helpers
%% =============================================================================

open_fused_ew_db(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        crdt_module => ?EW,
        fused => true,
        oplog_instance_opts => #{origin => Origin}
    }),
    {Db, Origin}.

instance_of(Table) ->
    #{0 := InstanceId} = maps:get(instance_ids, Table),
    InstanceId.

strip_hlc({ok, {V, _Hlc}}) -> {ok, {V, hlc}};
strip_hlc(Other) -> Other.
