%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% MST/WAL compaction on a **solo, ephemeral, fused** instance — the shape
%% the `registry` DB uses (`bondy_namespace_catalog:registry_db_spec/0`:
%% `fused => true`, `projection_backend => ets`, `durability => ephemeral`;
%% `bondy_db:assert_fused_requires_ephemeral/2` makes `fused` an
%% ephemeral-only property by construction).
%%
%% `bondy_oplog_compaction:compact/1` derives `PeerRoots` from THIS
%% instance's own sync history (`bondy_oplog_peer_state:
%% get_instance_peer_states/1`), not live cluster membership. On a node
%% with no cluster peer at all that history can never be populated, so
%% `compute_frontier_for(_MST, []) -> undefined.` never advances — unlike
%% CRDT-cell reclamation, which short-circuits via `reclamation_members/0`'s
%% solo carve-out (see `stability_point/1`), compaction has none. A
%% sustained write burst against a peerless ephemeral+fused instance (e.g. a
%% single-node `bondy` under subscribe-heavy load) therefore grows its MST
%% page store unbounded — the RAM leak reproduced against a live node on
%% Fly and locally with a k6 run.
-module(bondy_oplog_compaction_fused_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
-define(BUCKET_SUB, <<"sub_rib">>).
-define(BUCKET_REG, <<"reg_rib">>).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

compaction_fused_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun solo_ephemeral_fused_never_compacts_today/0},
        {timeout, 30, fun self_root_confirms_ephemeral_fused_compacts/0},
        {timeout, 30, fun mux_shard_both_tables_compact_together/0},
        {timeout, 30, fun solo_fused_without_projection_never_shortcuts/0},
        {timeout, 30, fun solo_carve_out_compaction_is_idempotent/0}
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

%% P1 — the RED test. A fused instance with NO peers at all (the exact
%% shape `bondy_oplog_compaction:compact/1` drives every 1s via
%% `bondy_oplog_gc_scheduler`): writes bring a pn_counter cell to algebraic
%% zero, are applied, and compaction is invoked with the real-world empty
%% peer-root list. Today `compute_frontier_for(_MST, []) -> undefined.` has
%% no solo carve-out, so the MST never bounds — this asserts the property
%% the eventual fix must satisfy (size converges to 0), not today's
%% `{ok, no_change}` return shape.
solo_ephemeral_fused_never_compacts_today() ->
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}),
    K = <<"vehicle_1">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, 1}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, -1}}),
    ok = bondy_oplog_instance:await_apply(Id),
    ?assert(bondy_oplog:size(Id) >= 1),

    %% The exact shape `bondy_oplog_compaction:compact/1` uses for a
    %% peerless node: no confirmed peer roots at all.
    _ = bondy_oplog_instance:compact(Id, []),

    ?assertEqual(0, bondy_oplog:size(Id)),

    teardown(Id).

%% P3 — baseline sanity. Same fused, single-table construction as the RED
%% test, but with a confirmed peer root (the "self-root-as-fake-confirmed-
%% peer" trick from `bondy_oplog_catalogue_compaction_test.erl`, mirroring
%% `truncates_and_preserves_reads/0` but on a fused instance). Expected to
%% pass today: the peer-confirmed path already works on fused, this test
%% protects the "the eventual fix doesn't break the working path"
%% direction.
self_root_confirms_ephemeral_fused_compacts() ->
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}),
    K = <<"vehicle_2">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, 1}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, -1}}),
    ok = bondy_oplog_instance:await_apply(Id),
    ?assert(bondy_oplog:size(Id) >= 1),

    Root = bondy_oplog_instance:root_hash(Id),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(Id, [Root])
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),

    teardown(Id).

%% P4 — regression-lock for the real registry mux shape: one fused instance
%% multiplexing TWO tables with heterogeneous CRDT kernels, distinguished by
%% `Bucket` (`bondy_oplog_crdt_pn_counter` founding the instance —
%% `?BUCKET_SUB`, mirroring `bondy_subscription_rib` — with
%% `bondy_oplog_crdt_struct` joining at runtime via `register_table/4` as
%% `?BUCKET_REG`, mirroring `bondy_registration_rib`'s
%% `?RIB_REGISTRATION_SCHEMA` shape). The core compaction mechanism
%% (`run_compaction/9`, `compute_frontier_for/2`) operates purely on the MST
%% as a flat key/value tree — it never decodes cells with any per-table
%% kernel — so this is mux-agnostic by construction; self-root-confirms and
%% asserts combined size returns to 0 across both tables. Expected to pass
%% today.
mux_shard_both_tables_compact_together() ->
    Id = mk_id(),
    NsSub = ns_of(Id),
    NsReg = binary_to_atom(<<"reg_", Id/binary>>, utf8),

    {SubCache, SubProj} = register_shard_with_bucket(
        NsSub, Id, ?BUCKET_SUB, bondy_oplog_crdt_pn_counter, #{}
    ),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        origin => bondy_oplog_origin:new(),
        fused => true,
        applier => #{
            cell_apply_target => {NsSub, primary, 0},
            cell_apply_bucket => ?BUCKET_SUB
        }
    }),

    StructSchema = #{
        count => {bondy_oplog_crdt_pn_counter, #{stabilize_zero => 0}},
        invoke => bondy_oplog_crdt_lww_register
    },
    {RegCache, RegProj} = register_shard_with_bucket(
        NsReg, Id, ?BUCKET_REG, bondy_oplog_crdt_struct, StructSchema
    ),
    ok = bondy_oplog_instance:register_table(
        Id, ?BUCKET_REG, {NsReg, primary, 0}, #{}
    ),

    K1 = <<"sub_1">>,
    K2 = <<"reg_1">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?BUCKET_SUB, K1, {inc, 1}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?BUCKET_SUB, K1, {inc, -1}}),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_REG, K2, {apply, count, {inc, 1}}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_REG, K2, {apply, count, {inc, -1}}}
    ),
    ok = bondy_oplog_instance:await_apply(Id),
    ?assert(bondy_oplog:size(Id) >= 2),

    Root = bondy_oplog_instance:root_hash(Id),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(Id, [Root])
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),

    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NsSub, primary, 0),
    ok = bondy_oplog_core_registry:unregister(NsReg, primary, 0),
    close_shard(SubCache, SubProj),
    close_shard(RegCache, RegProj).

%% Proves the narrowed guard on `effective_frontier/3`: it is gated on
%% `Fused ANDALSO HasProjection`, not `Fused` alone. A fused instance with NO
%% projection wiring at all (a bare CRDT checkpoint, `bondy_oplog_compaction_
%% test.erl`'s `counter_opts()` shape + `fused => true` — constructible below
%% `bondy_db`, since `bondy_db:assert_fused_requires_ephemeral/2` only guards
%% the `bondy_db:open_table/3` entry point, not raw `bondy_oplog:
%% start_instance/2`) must NOT get the solo shortcut: the safety argument for
%% it (a rootless peer falls back to a catalogue bootstrap) was made for the
%% projection-backed path, never extended to the bare-CRDT checkpoint path.
%% Even solo, compaction must stay `{ok, no_change}` here.
solo_fused_without_projection_never_shortcuts() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        crdt_module => bondy_oplog_test_counter,
        origin => bondy_oplog_origin:new(),
        fused => true
    }),
    try
        [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 5)],
        ok = bondy_oplog_instance:await_apply(Id),
        SizeBefore = bondy_oplog:size(Id),
        ?assert(SizeBefore >= 5),

        ?assertEqual({ok, no_change}, bondy_oplog_instance:compact(Id, [])),
        ?assertEqual(SizeBefore, bondy_oplog:size(Id)),
        ?assertEqual(undefined, bondy_oplog:current_watermark(Id))
    after
        ok = bondy_oplog:stop_instance(Id)
    end.

%% A second solo-carve-out compaction with nothing new to fold must degrade
%% to `{ok, no_change}` — the same idempotence
%% `bondy_oplog_catalogue_compaction_test:idempotent_after_truncation/0`
%% pins for the peer-confirmed path, now pinned for the solo path too.
solo_carve_out_compaction_is_idempotent() ->
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}),
    K = <<"vehicle_3">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, 1}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, -1}}),
    ok = bondy_oplog_instance:await_apply(Id),
    ?assert(bondy_oplog:size(Id) >= 1),

    ?assertMatch(
        {ok, {compacted, _, _}}, bondy_oplog_instance:compact(Id, [])
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),
    Watermark1 = bondy_oplog:current_watermark(Id),
    ?assertNotEqual(undefined, Watermark1),

    %% Nothing new since the first compaction — the second cycle finds an
    %% empty MST and must not re-derive a "new" frontier from it.
    ?assertEqual({ok, no_change}, bondy_oplog_instance:compact(Id, [])),
    ?assertEqual(Watermark1, bondy_oplog:current_watermark(Id)),
    ?assertEqual(0, bondy_oplog:size(Id)),

    teardown(Id).

%% =============================================================================
%% Helpers
%% =============================================================================

start_fused_instance(CrdtModule, CrdtOpts) ->
    Id = mk_id(),
    NS = ns_of(Id),
    _ = register_shard(NS, primary, 0, CrdtModule, CrdtOpts),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        origin => bondy_oplog_origin:new(),
        fused => true,
        applier => #{
            cell_apply_target => {NS, primary, 0}
        }
    }),
    Id.

register_shard(NS, Index, Shard, CrdtModule, CrdtOpts) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        overlay => disabled,
        fold_module => lww_register,
        crdt_module => CrdtModule,
        crdt_opts => CrdtOpts
    }),
    {Cache, Proj}.

close_shard(Cache, Proj) ->
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

%% Like `register_shard/5` but also stamps `instance_id`/`cell_apply_bucket`
%% on the registry entry — the multi-table mux shape
%% (`bondy_oplog_applier_multiplex_test.erl`'s `register_shard/3`) — so the
%% shared instance can route events for this table by `Bucket`.
register_shard_with_bucket(NS, InstanceId, Bucket, CrdtModule, CrdtOpts) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        overlay => disabled,
        fold_module => lww_register,
        crdt_module => CrdtModule,
        crdt_opts => CrdtOpts,
        instance_id => InstanceId,
        cell_apply_bucket => Bucket
    }),
    {Cache, Proj}.

mk_id() ->
    iolist_to_binary([
        "compact_fused_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

teardown(Id) ->
    bondy_oplog:stop_instance(Id),
    NS = ns_of(Id),
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)],
        N =:= NS
    ],
    ok.
