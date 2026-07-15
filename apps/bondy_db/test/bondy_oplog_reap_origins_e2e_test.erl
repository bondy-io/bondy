%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PR-H (#24) dead-origin VV reaping — end-to-end through the real tier_2
%% substrate (`bondy_db:apply/4` stamp → applier projection →
%% `bondy_oplog_instance:reap_origins/2`).
%%
%% The scenario each test builds: two replicas (distinct origins) write the
%% same cell concurrently, sync, then the LOCAL origin writes again and
%% dominates the peer's value. The peer origin is now causal-history-only
%% in the local cell's version vector (its node is "decommissioned"), so it
%% is reapable. The tests pin:
%%
%%   - value-preserving: the read is unchanged across the reap,
%%   - the reap report counts (cells scanned/reaped, origins reaped),
%%   - ctx_guard co-eviction (#27 NOTE): a same-origin write AFTER the reap
%%     is NOT mistaken for a context regression — without co-eviction the
%%     reaped origin lingers in the stamp-site high-water and refuses it,
%%   - idempotence, and
%%   - no-op (`supported => false`) for a tier_0 table.

-module(bondy_oplog_reap_origins_e2e_test).

-include_lib("eunit/include/eunit.hrl").

-define(MV, bondy_oplog_crdt_mv_register).
-define(AW, bondy_oplog_crdt_aw_map).

%% =============================================================================
%% Fixture
%% =============================================================================

reap_e2e_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"mv_register: reap a dominated peer origin",
                {timeout, 30, fun mv_reap_dominated_peer/0}},
            {"mv_register: ctx_guard co-eviction lets the next write through",
                {timeout, 30, fun mv_coevict_allows_next_write/0}},
            {"mv_register: reap is idempotent",
                {timeout, 30, fun mv_reap_idempotent/0}},
            {"aw_map: reap a dominated peer origin",
                {timeout, 30, fun aw_reap_dominated_peer/0}},
            {"tier_0 table: reap is a no-op", fun tier0_reap_noop/0}
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
%% mv_register
%% =============================================================================

mv_reap_dominated_peer() ->
    {Ta, Ia, _Oa, Ob} = converged_then_dominated(mvreg_reap, ?MV),
    %% Local has dominated the peer's sibling — a single live value.
    ?assertEqual([<<"va2">>], read_mv(Ta)),

    {ok, Report} = bondy_oplog_instance:reap_origins(Ia, [Ob]),
    ?assertEqual(true, maps:get(supported, Report)),
    ?assertEqual(1, maps:get(cells_reaped, Report)),
    ?assertEqual([Ob], maps:get(origins_reaped, Report)),
    ?assert(maps:get(cells_scanned, Report) >= 1),

    %% Value-preserving: the read is unchanged after the reap.
    ?assertEqual([<<"va2">>], read_mv(Ta)).

mv_coevict_allows_next_write() ->
    {Ta, Ia, _Oa, Ob} = converged_then_dominated(mvreg_coevict, ?MV),
    {ok, _} = bondy_oplog_instance:reap_origins(Ia, [Ob]),
    %% The cell's context legitimately shrank (Ob gone). A same-origin
    %% write reads the shrunk context; the co-eviction of Ob from the
    %% stamp-site guard is what keeps `vv_regressed/2` from refusing it.
    %% Without co-eviction this returns `{error, {context_regression, …}}`.
    ?assertEqual(ok, bondy_db:apply(Ta, <<"r">>, <<"k">>, {set, <<"va3">>})),
    ?assertEqual([<<"va3">>], read_mv(Ta)).

mv_reap_idempotent() ->
    {_Ta, Ia, _Oa, Ob} = converged_then_dominated(mvreg_idem, ?MV),
    {ok, R1} = bondy_oplog_instance:reap_origins(Ia, [Ob]),
    ?assertEqual(1, maps:get(cells_reaped, R1)),
    {ok, R2} = bondy_oplog_instance:reap_origins(Ia, [Ob]),
    ?assertEqual(0, maps:get(cells_reaped, R2)),
    ?assertEqual([], maps:get(origins_reaped, R2)).

%% =============================================================================
%% aw_map
%% =============================================================================

aw_reap_dominated_peer() ->
    {DbA, _Oa} = open_db(awmap_reap_a, ?AW),
    {DbB, Ob} = open_db(awmap_reap_b, ?AW),
    {ok, Ta} = bondy_db:open_table(DbA, items, #{}),
    {ok, Tb} = bondy_db:open_table(DbB, items, #{}),
    Ia = instance_of(Ta),
    Ib = instance_of(Tb),
    %% Concurrent puts to the same key, then sync.
    ok = bondy_db:apply(Ta, <<"r">>, <<"k">>, {put, <<"k">>, <<"va">>}),
    ok = bondy_db:apply(Tb, <<"r">>, <<"k">>, {put, <<"k">>, <<"vb">>}),
    ok = sync_both(Ia, Ib),
    %% Local writes again, observing both → dominates the peer's dot, so
    %% the peer origin holds no live dot (reapable from the context VV).
    ok = bondy_db:apply(Ta, <<"r">>, <<"k">>, {put, <<"k">>, <<"va2">>}),
    ?assertEqual(#{<<"k">> => [<<"va2">>]}, read_aw(Ta)),

    {ok, Report} = bondy_oplog_instance:reap_origins(Ia, [Ob]),
    ?assertEqual(true, maps:get(supported, Report)),
    ?assertEqual([Ob], maps:get(origins_reaped, Report)),
    %% Value-preserving.
    ?assertEqual(#{<<"k">> => [<<"va2">>]}, read_aw(Ta)),
    %% Co-eviction: a same-origin write after the reap still goes through.
    ?assertEqual(
        ok, bondy_db:apply(Ta, <<"r">>, <<"k">>, {put, <<"k">>, <<"va3">>})
    ),
    ?assertEqual(#{<<"k">> => [<<"va3">>]}, read_aw(Ta)),
    ok = bondy_db:close(DbA),
    ok = bondy_db:close(DbB).

%% =============================================================================
%% tier_0 no-op
%% =============================================================================

tier0_reap_noop() ->
    {ok, Db} = bondy_db:open(reap_tier0, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => pn_counter,
        oplog_instance_opts => #{origin => bondy_oplog_origin:new()}
    }),
    {ok, T} = bondy_db:open_table(Db, counters, #{}),
    ok = bondy_db:counter_inc(T, <<"r">>, <<"c">>, 5),
    I = instance_of(T),
    {ok, Report} = bondy_oplog_instance:reap_origins(I, [<<"anything">>]),
    ?assertEqual(false, maps:get(supported, Report)),
    ?assertEqual(0, maps:get(cells_reaped, Report)),
    ok = bondy_db:close(Db).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Build the "converged then locally dominated" state for an mv_register
%% pair and return `{LocalTable, LocalInstance, LocalOrigin, PeerOrigin}`.
%% The peer origin `Ob` is now causal-history-only in the local cell.
converged_then_dominated(NameBase, Crdt) ->
    {DbA, Oa} = open_db(name(NameBase, a), Crdt),
    {DbB, Ob} = open_db(name(NameBase, b), Crdt),
    {ok, Ta} = bondy_db:open_table(DbA, items, #{}),
    {ok, Tb} = bondy_db:open_table(DbB, items, #{}),
    Ia = instance_of(Ta),
    Ib = instance_of(Tb),
    ok = bondy_db:apply(Ta, <<"r">>, <<"k">>, {set, <<"va">>}),
    ok = bondy_db:apply(Tb, <<"r">>, <<"k">>, {set, <<"vb">>}),
    ok = sync_both(Ia, Ib),
    %% Local observes both siblings and dominates them.
    ok = bondy_db:apply(Ta, <<"r">>, <<"k">>, {set, <<"va2">>}),
    {Ta, Ia, Oa, Ob}.

%% Bidirectional sync + the synchronous peer-replay barrier on both sides.
sync_both(Ia, Ib) ->
    {ok, _} = bondy_oplog:sync(Ia, Ib),
    {ok, _} = bondy_oplog:sync(Ib, Ia),
    ok = bondy_oplog:await_apply(Ia),
    ok = bondy_oplog:await_apply(Ib),
    ok = replay(Ia),
    ok = replay(Ib),
    ok.

open_db(Name, Crdt) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        crdt_module => Crdt,
        oplog_instance_opts => #{origin => Origin}
    }),
    {Db, Origin}.

instance_of(Table) ->
    #{0 := InstanceId} = maps:get(instance_ids, Table),
    InstanceId.

replay(InstanceId) ->
    Pid = bondy_oplog_registry:applier_pid(InstanceId),
    bondy_oplog_applier:replay_cell_events_sync(Pid).

read_mv(Table) ->
    {ok, {V, _Hlc}} = bondy_db:read(Table, <<"r">>, <<"k">>),
    V.

read_aw(Table) ->
    {ok, {V, _Hlc}} = bondy_db:read(Table, <<"r">>, <<"k">>),
    V.

name(Base, Suffix) ->
    binary_to_atom(
        iolist_to_binary([atom_to_binary(Base), "_", atom_to_binary(Suffix)]),
        utf8
    ).
