%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% `bondy_db:delete/3` and the cell sweeper.
%%
%% Until now a removal left a tombstone that nothing ever reclaimed, so cell
%% count grew with every key ever written — the plum_db outcome the oplog
%% rewrite set out to escape. Reclaiming the op log does not reclaim the
%% projection.
%%
%% `delete/3` issues the removal operation the table's CRDT declares; the cell
%% becomes invisible to readers at once but is retained while a concurrent
%% lower-HLC write could still arrive. `sweep_stable_cells/2` reclaims it once
%% that is impossible. The sweep runs inside the applier — the only writer to
%% the projection — so it cannot interleave a delete with a concurrent write.
%% =============================================================================

-module(bondy_db_cell_sweep_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_lww_register).
-define(REALM, <<"r1">>).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    {ok, Db} = bondy_db:open(sweep_db, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        crdt_module => ?CRDT
    }),
    {ok, T} = bondy_db:open_table(Db, swept, #{}),
    {Db, T}.

cleanup({Db, T}) ->
    catch bondy_db:close_table(T),
    catch bondy_db:close(Db),
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

cell_sweep_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun({_Db, T}) ->
        [
            {"delete hides the value but retains the cell", fun() ->
                delete_hides_but_retains(T)
            end},
            {"sweep reclaims a stable tombstone", fun() ->
                sweep_reclaims_stable_tombstone(T)
            end},
            {"sweep below the tombstone HLC reclaims nothing", fun() ->
                sweep_below_hlc_reclaims_nothing(T)
            end},
            {"live values survive the sweep", fun() ->
                live_value_survives(T)
            end},
            {"bounded sweep: batches reclaim what one pass does", fun() ->
                bounded_sweep_equivalence(T)
            end}
        ]
    end}.

%% -----------------------------------------------------------------------------

delete_hides_but_retains(T) ->
    K = <<"doomed">>,
    ok = bondy_db:apply(T, ?REALM, K, {set, bondy_db:tick(T), <<"v">>}),
    ?assertMatch({ok, {<<"v">>, _}}, bondy_db:read(T, ?REALM, K)),

    ok = bondy_db:delete(T, ?REALM, K),

    %% Invisible to readers straight away...
    ?assertEqual({error, not_found}, bondy_db:read(T, ?REALM, K)),
    %% ...but still occupying a row. That retention is deliberate: the
    %% tombstone is what rejects a concurrent lower-HLC write.
    ?assert(cell_count(T) >= 1).

sweep_reclaims_stable_tombstone(T) ->
    K = <<"reclaim_me">>,
    ok = bondy_db:apply(T, ?REALM, K, {set, bondy_db:tick(T), <<"v">>}),
    ok = bondy_db:delete(T, ?REALM, K),
    ?assert(cell_count(T) >= 1),

    {ok, Stats} = sweep(T, far_future(T)),
    %% The tombstone was physically removed from the projection.
    ?assert(maps:get(discarded, Stats) >= 1),

    %% Reclamation does not change what a reader sees: absent and tombstoned
    %% are the same answer. That equivalence is what makes the sweep safe.
    ?assertEqual({error, not_found}, bondy_db:read(T, ?REALM, K)).

sweep_below_hlc_reclaims_nothing(T) ->
    K = <<"not_yet">>,
    ok = bondy_db:apply(T, ?REALM, K, {set, bondy_db:tick(T), <<"v">>}),
    ok = bondy_db:delete(T, ?REALM, K),
    %% A stability point below the tombstone's HLC licenses nothing: an older
    %% concurrent write could still arrive and must still lose to the removal.
    %% Reclaiming here would resurrect it.
    {ok, Stats} = sweep(T, 1),
    ?assertEqual(0, maps:get(discarded, Stats)),
    ?assert(maps:get(scanned, Stats) >= 1),
    %% Still hidden from readers, still retained.
    ?assertEqual({error, not_found}, bondy_db:read(T, ?REALM, K)).

%% Step 4 — the bound and the cursor. Eight tombstones swept in batches of
%% three reclaim exactly what one unbounded call would, no single call scans
%% more than the bound (the bound IS the latency mechanism: the sweep runs
%% inside the applier, the sole projection writer, so cells-per-call is what
%% caps the stall of a concurrent write), and the final call reports `done`.
bounded_sweep_equivalence(T) ->
    Keys = [
        <<"batch_", (integer_to_binary(N))/binary>>
     || N <- lists:seq(1, 8)
    ],
    [
        begin
            ok = bondy_db:apply(T, ?REALM, K, {set, bondy_db:tick(T), <<"v">>}),
            ok = bondy_db:delete(T, ?REALM, K)
        end
     || K <- Keys
    ],

    {Stats, Calls} = sweep_batched(T, far_future(T), 3),
    ?assert(maps:get(discarded, Stats) >= 8),
    ?assert(Calls >= 3),
    [
        ?assertEqual({error, not_found}, bondy_db:read(T, ?REALM, K))
     || K <- Keys
    ].

live_value_survives(T) ->
    K = <<"keeper">>,
    ok = bondy_db:apply(T, ?REALM, K, {set, bondy_db:tick(T), <<"alive">>}),

    {ok, Stats} = sweep(T, far_future(T)),
    ?assert(maps:get(scanned, Stats) >= 1),

    %% Stability says nothing older can arrive; it does not say the value is
    %% unwanted. Discarding here would be data loss, not reclamation.
    ?assertMatch({ok, {<<"alive">>, _}}, bondy_db:read(T, ?REALM, K)).

%% -----------------------------------------------------------------------------
%% Causal-stabilization folding ({keep, Reduced} → value-preserving rewrite)
%% -----------------------------------------------------------------------------
%%
%% A struct cell's fields are nested PO-Logs — one dot-store entry per
%% sub-op, forever — until the sweep folds each origin's causally-stable
%% run into a synthetic op (`bondy_oplog_crdt_struct:stabilize/2` →
%% `{keep, Reduced}`) and persists it as a value-preserving frame rewrite,
%% counted as `rewritten`. This drives the whole path end-to-end through
%% `bondy_db`: real stamped tier_2 events, the applier's sweep handler
%% (behind the I1 remote-generation fence), the overlay fence, and the
%% adapter write-back — on the registration-RIB schema, the production
%% shape this bounds.

struct_fold_setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Deterministic timing — no AE/GC scheduler racing the sweep.
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    {ok, Db} = bondy_db:open(sweep_fold_db, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        crdt_module => bondy_oplog_crdt_struct,
        crdt_opts => #{
            count => {bondy_oplog_crdt_pn_counter, #{stabilize_zero => 0}},
            invoke => bondy_oplog_crdt_lww_register,
            earliest => bondy_oplog_crdt_min_register,
            latest => bondy_oplog_crdt_max_register
        }
    }),
    {ok, T} = bondy_db:open_table(Db, ribs, #{}),
    {Db, T}.

struct_fold_cleanup({Db, T}) ->
    catch bondy_db:close_table(T),
    catch bondy_db:close(Db),
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

struct_fold_test_() ->
    {setup, fun struct_fold_setup/0, fun struct_fold_cleanup/1, fun({_Db, T}) ->
        [
            {"sweep folds a struct cell's stable sub-op runs, "
             "value-preserving and idempotent",
                {timeout, 60, fun() -> struct_fold_reduces_stable_runs(T) end}}
        ]
    end}.

struct_fold_reduces_stable_runs(T) ->
    K = <<"proc.echo">>,
    %% Registration-RIB-shaped churn: adds each writing all four fields,
    %% then some removals — every op is one more PO-Log entry until folded.
    [
        ok = bondy_db:apply_batch(T, ?REALM, K, [
            {apply, count, {inc, 1}},
            {apply, invoke, {set, <<"single">>}},
            {apply, earliest, {set, N}},
            {apply, latest, {set, N}}
        ])
     || N <- lists:seq(1, 8)
    ],
    [
        ok = bondy_db:apply(T, ?REALM, K, {apply, count, {inc, -1}})
     || _ <- lists:seq(1, 3)
    ],
    {ok, {Value0, _}} = bondy_db:read(T, ?REALM, K),
    ?assertMatch(
        #{
            count := 5,
            invoke := <<"single">>,
            earliest := 1,
            latest := 8
        },
        Value0
    ),

    %% First sweep: the stable runs fold and the reduced frame is written.
    {ok, Stats1} = sweep(T, far_future(T)),
    ?assert(maps:get(rewritten, Stats1) >= 1),
    ?assertEqual(0, maps:get(discarded, Stats1)),
    {ok, {Value1, _}} = bondy_db:read(T, ?REALM, K),
    ?assertEqual(Value0, Value1),

    %% Second sweep at the same point: every run is already a single
    %% synthetic op — nothing left to rewrite.
    {ok, Stats2} = sweep(T, far_future(T)),
    ?assertEqual(0, maps:get(rewritten, Stats2)),

    %% The folded cell keeps absorbing writes — the next apply folds onto
    %% the REDUCED state (the write-through of the rewritten frame), and a
    %% later sweep folds the new tail in turn.
    ok = bondy_db:apply_batch(T, ?REALM, K, [
        {apply, count, {inc, 1}},
        {apply, latest, {set, 9}}
    ]),
    {ok, {Value2, _}} = bondy_db:read(T, ?REALM, K),
    ?assertMatch(#{count := 6, latest := 9}, Value2),
    {ok, Stats3} = sweep(T, far_future(T)),
    ?assert(maps:get(rewritten, Stats3) >= 1),
    {ok, {Value3, _}} = bondy_db:read(T, ?REALM, K),
    ?assertEqual(Value2, Value3).

%% -----------------------------------------------------------------------------
%% Kernel fidelity on a multiplexed applier (A6)
%% -----------------------------------------------------------------------------
%%
%% `shared_shards` + `shard_count => 1` puts BOTH tables on one applier AND one
%% shared Bookie, with different CRDT kernels — the shape of every main shard
%% in production. The topology matters: on `memory` each table has its own ETS
%% projection handle, so a founding-ctx sweep merely misses foreign cells
%% (`not_found`); on `shared_shards` the handle is shared, the foreign frame IS
%% read, and decoding a g_set state with the founding lww kernel raises. Before
%% the per-bucket fix that raise escaped `sweep_one_cell`'s `try ... of`
%% (exceptions in the `of` body are not caught) and CRASHED the applier — the
%% sole projection writer for every table on the shard.

mux_setup() ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Deterministic timing — no AE/GC scheduler racing the sweep.
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = mux_tempdir(),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(sweep_mux_db, #{
        topology => bondy_db_topology_shared_shards,
        topology_opts => #{sup => Sup, dir => Dir},
        shard_count => 1,
        fold_module => lww_register
    }),
    {ok, T1} = bondy_db:open_table(Db, mux_lww, #{}),
    {ok, T2} = bondy_db:open_table(Db, mux_set, #{fold_module => g_set}),
    {ok, T3} = bondy_db:open_table(Db, mux_lww2, #{}),
    {Db, T1, T2, T3, Sup, Dir}.

mux_cleanup({Db, _T1, _T2, _T3, Sup, Dir}) ->
    _ = catch bondy_db:close(Db),
    _ = [
        catch bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    mux_rmrf(Dir),
    ok.

mux_tempdir() ->
    Base = filename:join([
        "/tmp",
        "bondy_db_cell_sweep_mux",
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

mux_rmrf(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, _} -> ok
    end.

mux_cell_sweep_test_() ->
    {setup, fun mux_setup/0, fun mux_cleanup/1, fun({_Db, T1, T2, T3, _, _}) ->
        [
            {"sweep covers every table and foreign-kernel cells survive",
                {timeout, 60, fun() ->
                    foreign_kernel_cells_survive(T1, T2, T3)
                end}},
            {"reclamation reaches non-founding tables, per bucket",
                {timeout, 60, fun() ->
                    reclamation_is_per_bucket(T1, T2, T3)
                end}},
            {"bounded sweep resumes across members",
                {timeout, 60, fun() ->
                    bounded_sweep_across_members(T1, T2, T3)
                end}}
        ]
    end}.

%% Step 4 on the multiplexed shape: with `max_cells => 1` the cursor must
%% cross MEMBER (table) boundaries — tombstones in two different tables are
%% both reclaimed, one cell per call, while the foreign-kernel table's live
%% cell survives. Members already swept are skipped without re-enumeration.
bounded_sweep_across_members(T1, T2, T3) ->
    K1 = <<"bm_doomed1">>,
    K3 = <<"bm_doomed3">>,
    ok = bondy_db:apply(T1, ?REALM, K1, {set, bondy_db:tick(T1), <<"v">>}),
    ok = bondy_db:delete(T1, ?REALM, K1),
    ok = bondy_db:apply(T3, ?REALM, K3, {set, bondy_db:tick(T3), <<"w">>}),
    ok = bondy_db:delete(T3, ?REALM, K3),

    {Stats, Calls} = sweep_batched(T1, far_future(T1), 1),
    ?assert(maps:get(discarded, Stats) >= 2),
    ?assert(Calls >= 2),
    ?assertEqual({error, not_found}, bondy_db:read(T1, ?REALM, K1)),
    ?assertEqual({error, not_found}, bondy_db:read(T3, ?REALM, K3)),
    ?assertMatch({ok, _}, bondy_db:read(T2, ?REALM, <<"set_live">>)).

foreign_kernel_cells_survive(T1, T2, T3) ->
    ok = bondy_db:apply(
        T1, ?REALM, <<"lww_live">>, {set, bondy_db:tick(T1), <<"v">>}
    ),
    ok = bondy_db:apply(T2, ?REALM, <<"set_live">>, {add, <<"e1">>}),
    ok = bondy_db:apply(
        T3, ?REALM, <<"lww2_live">>, {set, bondy_db:tick(T3), <<"w">>}
    ),

    {ok, Stats} = sweep(T1, far_future(T1)),
    %% The sweep covers EVERY registered table's cells — before the
    %% per-member fix the founding ctx's `{entity, ET}` scope enumerated only
    %% the founding table and this asserted 1...
    ?assert(maps:get(scanned, Stats) >= 3),
    %% ...and nothing was discarded: the lww cells are live, and the g_set
    %% cell was decoded by ITS OWN kernel (no `stabilize/2` → keep), not
    %% misread by the founding lww kernel.
    ?assertEqual(0, maps:get(discarded, Stats)),
    ?assertMatch({ok, {<<"v">>, _}}, bondy_db:read(T1, ?REALM, <<"lww_live">>)),
    ?assertMatch({ok, _}, bondy_db:read(T2, ?REALM, <<"set_live">>)),
    ?assertMatch(
        {ok, {<<"w">>, _}}, bondy_db:read(T3, ?REALM, <<"lww2_live">>)
    ).

reclamation_is_per_bucket(T1, T2, T3) ->
    K1 = <<"lww_doomed">>,
    K3 = <<"lww2_doomed">>,
    ok = bondy_db:apply(T1, ?REALM, K1, {set, bondy_db:tick(T1), <<"v">>}),
    ok = bondy_db:delete(T1, ?REALM, K1),
    ok = bondy_db:apply(T3, ?REALM, K3, {set, bondy_db:tick(T3), <<"w">>}),
    ok = bondy_db:delete(T3, ?REALM, K3),

    {ok, Stats} = sweep(T1, far_future(T1)),
    %% BOTH tombstones are reclaimed — the founding table's AND the
    %% non-founding table's, each through its own ctx. Before the fix the
    %% non-founding tombstone was never even enumerated: reclamation
    %% silently did nothing for every table but the founding one.
    ?assert(maps:get(discarded, Stats) >= 2),
    ?assertEqual({error, not_found}, bondy_db:read(T1, ?REALM, K1)),
    ?assertEqual({error, not_found}, bondy_db:read(T3, ?REALM, K3)),
    %% The foreign-kernel table's cell is untouched.
    ?assertMatch({ok, _}, bondy_db:read(T2, ?REALM, <<"set_live">>)).

%% -----------------------------------------------------------------------------
%% Helpers
%% -----------------------------------------------------------------------------

sweep(T, StableHlc) ->
    InstanceId = instance_of(T),
    ok = bondy_oplog_instance:await_apply(InstanceId),
    Pid = bondy_oplog_registry:applier_pid(InstanceId),
    ?assert(is_pid(Pid)),
    bondy_oplog_applier:sweep_stable_cells(Pid, StableHlc).

%% Drive the bounded sweep to completion in batches of `Max`, asserting the
%% bound on every call. Returns the summed stats and the call count.
sweep_batched(T, StableHlc, Max) ->
    InstanceId = instance_of(T),
    ok = bondy_oplog_instance:await_apply(InstanceId),
    Pid = bondy_oplog_registry:applier_pid(InstanceId),
    ?assert(is_pid(Pid)),
    Zero = #{
        scanned => 0, discarded => 0, rewritten => 0, skipped => 0
    },
    sweep_batched_loop(Pid, StableHlc, Max, undefined, Zero, 0).

sweep_batched_loop(Pid, StableHlc, Max, Cursor, AccStats, Calls) ->
    {ok, Stats, Next} = bondy_oplog_applier:sweep_stable_cells(
        Pid, StableHlc, #{max_cells => Max, cursor => Cursor}
    ),
    %% THE BOUND: no single call scans more than `Max`.
    ?assert(maps:get(scanned, Stats) =< Max),
    Merged = maps:merge_with(fun(_, A, B) -> A + B end, AccStats, Stats),
    case Next of
        done ->
            {Merged, Calls + 1};
        {resume, C} ->
            sweep_batched_loop(Pid, StableHlc, Max, C, Merged, Calls + 1)
    end.

%% Cells the sweeper visits. NOTE this is not a projection-row count: the ETS
%% projection used by the memory topology does not export `cell_keys/2`, so
%% `primary_cell_directory/4` falls back to walking the MST. The count is
%% therefore stable across a projection delete, which is why the reclamation
%% assertions read `discarded` from the sweep rather than differencing this.
cell_count(T) ->
    {ok, Stats} = sweep(T, 1),
    ?assertEqual(0, maps:get(discarded, Stats)),
    maps:get(scanned, Stats).

%% Single-shard table, so there is exactly one instance.
instance_of(_T) ->
    [InstanceId | _] = bondy_oplog:list_instances(),
    InstanceId.

far_future(T) ->
    bondy_db:tick(T) + 1_000_000.
