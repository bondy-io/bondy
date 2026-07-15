%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Proves the per-shard multiplexer: ONE oplog instance (one WAL + MST + applier)
%% serving TWO tables, distinguished by the `Bucket` carried in each
%% `{cell_apply, Bucket, Key, FoldEvent}` event. The founding table seeds the
%% applier's cell-apply directory (via `cell_apply_bucket`, putting the applier
%% in `{dir, _}` mode); a second table joins the SAME instance at runtime with
%% `bondy_oplog_applier:register_table/4`. Each table's cells must land in its
%% OWN projection (registered under its own namespace), with no cross-bucket
%% contamination even for an identical key — the core premise of the
%% one-log-per-shard collapse.
%% =============================================================================
-module(bondy_oplog_applier_multiplex_test).

-include_lib("eunit/include/eunit.hrl").

-define(BUCKET_A, <<"table_a">>).
-define(BUCKET_B, <<"table_b">>).

multiplex_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun two_tables_one_instance_project_independently/0,
        fun unregister_table_stops_routing/0,
        fun siblings_self_heal_from_registry/0,
        fun gated_drain_defers_until_siblings_register/0,
        fun install_catalogue_batch_routes_by_bucket/0
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

two_tables_one_instance_project_independently() ->
    {Id, NsA, NsB, HA, HB} = setup_two_tables(),

    %% Append cells for BOTH tables through the SAME instance.
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_A, <<"k">>, {set, 1, <<"va">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_B, <<"k">>, {set, 1, <<"vb">>}}
    ),
    %% A key shared by the two tables must NOT collide — distinct buckets.
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_A, <<"shared">>, {set, 2, <<"a2">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_B, <<"shared">>, {set, 2, <<"b2">>}}
    ),
    _ = bondy_oplog:projection(Id),

    %% Each table's cells materialise in its OWN projection.
    ?assertEqual(
        {<<"va">>, 1}, bondy_oplog_core:read(NsA, primary, ?BUCKET_A, <<"k">>)
    ),
    ?assertEqual(
        {<<"vb">>, 1}, bondy_oplog_core:read(NsB, primary, ?BUCKET_B, <<"k">>)
    ),
    ?assertEqual(
        {<<"a2">>, 2},
        bondy_oplog_core:read(NsA, primary, ?BUCKET_A, <<"shared">>)
    ),
    ?assertEqual(
        {<<"b2">>, 2},
        bondy_oplog_core:read(NsB, primary, ?BUCKET_B, <<"shared">>)
    ),

    %% No cross-contamination: a namespace never sees the other's bucket.
    ?assertEqual(
        undefined, bondy_oplog_core:read(NsA, primary, ?BUCKET_B, <<"k">>)
    ),
    ?assertEqual(
        undefined, bondy_oplog_core:read(NsB, primary, ?BUCKET_A, <<"k">>)
    ),

    teardown_two_tables(Id, NsA, NsB, HA, HB).

unregister_table_stops_routing() ->
    {Id, NsA, NsB, HA, HB} = setup_two_tables(),
    ApplierPid = bondy_oplog_registry:applier_pid(Id),

    %% Drop table B: its events now resolve to no ctx and are skipped
    %% (logged), while table A keeps projecting.
    ok = bondy_oplog_applier:unregister_table(ApplierPid, ?BUCKET_B),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_A, <<"x">>, {set, 1, <<"a">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_B, <<"x">>, {set, 1, <<"b">>}}
    ),
    _ = bondy_oplog:projection(Id),

    ?assertEqual(
        {<<"a">>, 1}, bondy_oplog_core:read(NsA, primary, ?BUCKET_A, <<"x">>)
    ),
    ?assertEqual(
        undefined, bondy_oplog_core:read(NsB, primary, ?BUCKET_B, <<"x">>)
    ),

    teardown_two_tables(Id, NsA, NsB, HA, HB).

%% A multiplexed instance rebuilds its FULL per-bucket directory from the durable
%% registry at init — the exact path a `one_for_all` subtree restart re-runs. We
%% register BOTH tables' entries (each stamped with the shared `instance_id` and
%% its `cell_apply_bucket`) and start ONE instance, but DO NOT call
%% `register_table/4` for table B. Table B's cells must still project, because
%% the applier's init reconstructs its ctx from table B's registry entry — proof
%% that a restart self-heals routing for non-founding tables.
siblings_self_heal_from_registry() ->
    Id = mk_id(),
    NsA = binary_to_atom(<<"sh_a_", Id/binary>>, utf8),
    NsB = binary_to_atom(<<"sh_b_", Id/binary>>, utf8),
    HA = register_shard(NsA, Id, ?BUCKET_A),
    HB = register_shard(NsB, Id, ?BUCKET_B),
    %% Founding table A seeds via `cell_apply_bucket`; table B is NOT registered
    %% at runtime — it is recovered from its registry entry by the init rebuild.
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            cell_apply_target => {NsA, primary, 0},
            cell_apply_bucket => ?BUCKET_A
        }
    }),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_A, <<"k">>, {set, 1, <<"va">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_B, <<"k">>, {set, 1, <<"vb">>}}
    ),
    _ = bondy_oplog:projection(Id),
    ?assertEqual(
        {<<"va">>, 1}, bondy_oplog_core:read(NsA, primary, ?BUCKET_A, <<"k">>)
    ),
    %% Table B projected with NO register_table call — recovered from the registry.
    ?assertEqual(
        {<<"vb">>, 1}, bondy_oplog_core:read(NsB, primary, ?BUCKET_B, <<"k">>)
    ),
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NsA, primary, 0),
    ok = bondy_oplog_core_registry:unregister(NsB, primary, 0),
    teardown_handles(HA),
    teardown_handles(HB).

%% Reproduces the cold-boot ordering bug (#104). A collapsed per-shard instance
%% is founded by the FIRST table opened on the shard, but its single WAL holds
%% cells for EVERY table sharing the shard. If the founding applier replayed the
%% WAL at init — before the sibling tables registered their cell-apply buckets —
%% the siblings' cells would resolve to no ctx and be SKIPPED, and (because the
%% MST install is unconditional) the resume frontier would advance past them:
%% permanent loss of every non-founding table's WAL-tail on the durable backend.
%%
%% Here only table A is registered when the instance starts (so even the init
%% self-heal rebuild cannot recover B's ctx), and the instance is founded with
%% the drain GATED. A table B cell is written to the shared WAL; while gated it
%% is HELD, not skipped. After B registers and the gate is released, the deferred
%% drain replays the whole WAL with a complete routing directory and B's cell
%% projects. Without the gate this would assert `undefined` for table B.
gated_drain_defers_until_siblings_register() ->
    Id = mk_id(),
    NsA = binary_to_atom(<<"gate_a_", Id/binary>>, utf8),
    NsB = binary_to_atom(<<"gate_b_", Id/binary>>, utf8),
    %% Only table A is registered at founding time — exactly the cold-boot
    %% window where the sibling has not provisioned yet.
    HA = register_shard(NsA, Id, ?BUCKET_A),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            cell_apply_target => {NsA, primary, 0},
            cell_apply_bucket => ?BUCKET_A,
            drain_gated => true
        }
    }),

    %% Write cells for BOTH the founding table and the not-yet-registered
    %% sibling B into the shared WAL.
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_A, <<"k">>, {set, 1, <<"va">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_B, <<"k">>, {set, 1, <<"vb">>}}
    ),

    %% Gate holds: nothing has been replayed into the projection yet. A direct
    %% projection read does NOT await the drain, so this observes the gate.
    ?assertEqual(
        undefined, bondy_oplog_core:read(NsA, primary, ?BUCKET_A, <<"k">>)
    ),

    %% Sibling B provisions: durable registry entry + runtime bucket
    %% registration — the state the orchestrator reaches before releasing.
    HB = register_shard(NsB, Id, ?BUCKET_B),
    ApplierPid = bondy_oplog_registry:applier_pid(Id),
    ok = bondy_oplog_applier:register_table(
        ApplierPid, ?BUCKET_B, {NsB, primary, 0}, #{}
    ),

    %% Release the gate; the deferred drain replays the whole WAL now that the
    %% routing directory is complete.
    ok = bondy_oplog:open_drain_gate(Id),
    _ = bondy_oplog:projection(Id),

    %% Both cells projected — B's cell was held across the gate, not skipped.
    ?assertEqual(
        {<<"va">>, 1}, bondy_oplog_core:read(NsA, primary, ?BUCKET_A, <<"k">>)
    ),
    ?assertEqual(
        {<<"vb">>, 1}, bondy_oplog_core:read(NsB, primary, ?BUCKET_B, <<"k">>)
    ),

    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NsA, primary, 0),
    ok = bondy_oplog_core_registry:unregister(NsB, primary, 0),
    teardown_handles(HA),
    teardown_handles(HB).

%% End-to-end catalogue-snapshot bootstrap across a collapsed per-shard instance:
%% the PRODUCTION side (`init/1`) must stream EVERY table on the shard in one
%% session — walking each table's bucket in turn — and the INSTALL side must
%% route each returned cell back to its OWN table's ctx by bucket, not funnel
%% them through the founding table's ctx. We populate two tables on a source
%% multiplexed instance, pull its whole-shard snapshot, and install it on a
%% fresh multiplexed target, asserting the batch genuinely spans both buckets
%% and each lands in its own projection. The per-table separate ETS projections
%% here are a STRICTER check than the shared Bookie of `shared_shards` (where a
%% shared handle would mask a misroute).
install_catalogue_batch_routes_by_bucket() ->
    {SrcId, SrcNsA, SrcNsB, SrcHA, SrcHB} = setup_two_tables(),
    _ = bondy_oplog:append(
        SrcId, {cell_apply, ?BUCKET_A, <<"ka">>, {set, 5, <<"va">>}}
    ),
    _ = bondy_oplog:append(
        SrcId, {cell_apply, ?BUCKET_A, <<"shared">>, {set, 9, <<"a_shared">>}}
    ),
    _ = bondy_oplog:append(
        SrcId, {cell_apply, ?BUCKET_B, <<"kb">>, {set, 7, <<"vb">>}}
    ),
    _ = bondy_oplog:append(
        SrcId, {cell_apply, ?BUCKET_B, <<"shared">>, {set, 9, <<"b_shared">>}}
    ),
    _ = bondy_oplog:projection(SrcId),

    %% The whole-shard snapshot (`init/1`) genuinely spans BOTH tables' buckets.
    Cells = pull_snapshot(SrcId),
    Buckets = lists:usort([B || {B, _K, _F} <- Cells]),
    ?assertEqual([?BUCKET_A, ?BUCKET_B], Buckets),
    ?assertEqual(4, length(Cells)),

    %% Install onto a fresh target multiplexed instance.
    {TgtId, TgtNsA, TgtNsB, TgtHA, TgtHB} = setup_two_tables(),
    TgtApplier = bondy_oplog_registry:applier_pid(TgtId),
    {ok, Counts} =
        bondy_oplog_applier:install_catalogue_batch(TgtApplier, Cells),
    ?assertEqual(length(Cells), maps:get(installed, Counts)),

    %% Each bucket's cells materialised in its OWN table's projection.
    ?assertEqual(
        {<<"va">>, 5},
        bondy_oplog_core:read(TgtNsA, primary, ?BUCKET_A, <<"ka">>)
    ),
    ?assertEqual(
        {<<"vb">>, 7},
        bondy_oplog_core:read(TgtNsB, primary, ?BUCKET_B, <<"kb">>)
    ),
    ?assertEqual(
        {<<"a_shared">>, 9},
        bondy_oplog_core:read(TgtNsA, primary, ?BUCKET_A, <<"shared">>)
    ),
    ?assertEqual(
        {<<"b_shared">>, 9},
        bondy_oplog_core:read(TgtNsB, primary, ?BUCKET_B, <<"shared">>)
    ),
    %% No misrouting: the B cell never leaked into table A's projection.
    ?assertEqual(
        undefined,
        bondy_oplog_core:read(TgtNsA, primary, ?BUCKET_B, <<"kb">>)
    ),
    ?assertEqual(
        undefined,
        bondy_oplog_core:read(TgtNsB, primary, ?BUCKET_A, <<"ka">>)
    ),

    teardown_two_tables(SrcId, SrcNsA, SrcNsB, SrcHA, SrcHB),
    teardown_two_tables(TgtId, TgtNsA, TgtNsB, TgtHA, TgtHB).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Pull the complete whole-shard catalogue snapshot (every table on the shard)
%% off a collapsed instance.
pull_snapshot(Id) ->
    {ok, {_W, Cursor}} = bondy_oplog_catalogue_snapshot:init(Id),
    pull_snapshot_loop(Id, Cursor, []).

pull_snapshot_loop(Id, Cursor, Acc) ->
    case bondy_oplog_catalogue_snapshot:next(Id, Cursor) of
        {ok, {batch, {NextCursor, Cells}}} ->
            pull_snapshot_loop(Id, NextCursor, Acc ++ Cells);
        {ok, {done, Cells}} ->
            Acc ++ Cells
    end.

setup_two_tables() ->
    Id = mk_id(),
    NsA = binary_to_atom(<<"ns_a_", Id/binary>>, utf8),
    NsB = binary_to_atom(<<"ns_b_", Id/binary>>, utf8),
    %% Stamp the shared instance_id + each table's bucket on the entries, as
    %% real per-shard provisioning does — so the catalogue snapshot can derive
    %% the full set of tables on the shard from the registry alone.
    HA = register_shard(NsA, Id, ?BUCKET_A),
    HB = register_shard(NsB, Id, ?BUCKET_B),
    %% Founding table A seeds the cell-apply directory (dir-mode via
    %% `cell_apply_bucket`).
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            cell_apply_target => {NsA, primary, 0},
            cell_apply_bucket => ?BUCKET_A
        }
    }),
    %% Table B joins the SAME instance at runtime.
    ApplierPid = bondy_oplog_registry:applier_pid(Id),
    ok = bondy_oplog_applier:register_table(
        ApplierPid, ?BUCKET_B, {NsB, primary, 0}, #{}
    ),
    {Id, NsA, NsB, HA, HB}.

%% Register a primary shard entry, stamping the shared `instance_id` and the
%% table's `cell_apply_bucket`, so the applier's init rebuild
%% (`primary_entries_for_instance/1`) can recover this table's ctx — and the
%% catalogue snapshot can derive the shard's table set — from the registry alone.
register_shard(NS, Id, Bucket) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    Config0 = #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => lww_register,
        overlay => disabled
    },
    Config =
        case Id of
            undefined ->
                Config0;
            _ ->
                Config0#{instance_id => Id, cell_apply_bucket => Bucket}
        end,
    ok = bondy_oplog_core_registry:register(NS, primary, 0, Config),
    {Cache, Proj}.

teardown_handles({Cache, Proj}) ->
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache).

teardown_two_tables(Id, NsA, NsB, {CA, PA}, {CB, PB}) ->
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NsA, primary, 0),
    ok = bondy_oplog_core_registry:unregister(NsB, primary, 0),
    ok = bondy_oplog_projection_ets:close(PA),
    ok = bondy_oplog_cache_ets:close(CA),
    ok = bondy_oplog_projection_ets:close(PB),
    ok = bondy_oplog_cache_ets:close(CB),
    ok.

mk_id() ->
    list_to_binary(
        "mux_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).
