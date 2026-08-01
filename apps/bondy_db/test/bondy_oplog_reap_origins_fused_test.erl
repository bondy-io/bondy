%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Dead-origin VV reaping (`bondy_oplog_instance:reap_origins/2`) on a
%% **fused** local instance — the fused mirror of
%% `bondy_oplog_reap_origins_e2e_test.erl`. A fused instance has no
%% separate applier process, so `reap_origins/2` previously always
%% returned `{error, applier_unavailable}` for it, permanently:
%% `bondy_oplog_origin_retirement.erl` calls it generically on every
%% membership event and only logs a warning + retries forever, silently.
%% `bondy_oplog_cell_utils:reap/4` (shared with the applier) now runs
%% in-process on the fused instance, guarded by the same
%% `bondy_oplog_ctx_guard` the applier uses.
%%
%% The scenario: a fused local instance and a plain (non-fused) peer
%% instance converge on a cell, then the local side dominates — the peer
%% origin is now causal-history-only and reapable.
-module(bondy_oplog_reap_origins_fused_test).

-include_lib("eunit/include/eunit.hrl").

-define(MV, bondy_oplog_crdt_mv_register).

reap_fused_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"reap a dominated peer origin on a fused instance",
                {timeout, 30, fun reap_dominated_peer/0}},
            {"ctx_guard co-eviction lets the next write through",
                {timeout, 30, fun coevict_allows_next_write/0}}
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

reap_dominated_peer() ->
    {Ta, Ia, _Oa, Ob} = converged_then_dominated(reap_fused_dominated),
    ?assertEqual([<<"va2">>], read_mv(Ta)),

    {ok, Report} = bondy_oplog_instance:reap_origins(Ia, [Ob]),
    ?assertEqual(true, maps:get(supported, Report)),
    ?assertEqual(1, maps:get(cells_reaped, Report)),
    ?assertEqual([Ob], maps:get(origins_reaped, Report)),
    ?assert(maps:get(cells_scanned, Report) >= 1),

    %% Value-preserving: the read is unchanged after the reap.
    ?assertEqual([<<"va2">>], read_mv(Ta)).

coevict_allows_next_write() ->
    {Ta, Ia, _Oa, Ob} = converged_then_dominated(reap_fused_coevict),
    {ok, _} = bondy_oplog_instance:reap_origins(Ia, [Ob]),
    %% Without co-eviction this would return
    %% `{error, {context_regression, _, _}}` — the reaped origin lingering
    %% in the stamp-site high-water.
    ?assertEqual(ok, bondy_db:apply(Ta, <<"r">>, <<"k">>, {set, <<"va3">>})),
    ?assertEqual([<<"va3">>], read_mv(Ta)).

%% =============================================================================
%% Helpers
%% =============================================================================

%% `Ta`/`Ia` (local, FUSED) converge with a plain (non-fused) peer, then the
%% local side observes both siblings and dominates them — the peer origin
%% is now causal-history-only in the local cell.
converged_then_dominated(NameBase) ->
    {DbA, Oa} = open_fused_db(name(NameBase, a)),
    {DbB, Ob} = open_db(name(NameBase, b)),
    {ok, Ta} = bondy_db:open_table(DbA, items, #{}),
    {ok, Tb} = bondy_db:open_table(DbB, items, #{}),
    Ia = instance_of(Ta),
    Ib = instance_of(Tb),
    ok = bondy_db:apply(Ta, <<"r">>, <<"k">>, {set, <<"va">>}),
    ok = bondy_db:apply(Tb, <<"r">>, <<"k">>, {set, <<"vb">>}),
    ok = sync_both(Ia, Ib),
    ok = bondy_db:apply(Ta, <<"r">>, <<"k">>, {set, <<"va2">>}),
    {Ta, Ia, Oa, Ob}.

sync_both(Ia, Ib) ->
    {ok, _} = bondy_oplog:sync(Ia, Ib),
    {ok, _} = bondy_oplog:sync(Ib, Ia),
    ok = bondy_oplog:await_apply(Ia),
    ok = bondy_oplog:await_apply(Ib),
    ok.

open_fused_db(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        crdt_module => ?MV,
        fused => true,
        oplog_instance_opts => #{origin => Origin}
    }),
    {Db, Origin}.

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

read_mv(Table) ->
    {ok, {V, _Hlc}} = bondy_db:read(Table, <<"r">>, <<"k">>),
    V.

name(Base, Suffix) ->
    binary_to_atom(
        iolist_to_binary([atom_to_binary(Base), "_", atom_to_binary(Suffix)]),
        utf8
    ).
