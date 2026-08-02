%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Causally-stable CRDT cell reclamation (`bondy_oplog_instance:reclaim_
%% stable_cells/1`) on a **fused** instance — the fused mirror of
%% `bondy_oplog_reclamation_test.erl`'s solo scenarios. A fused instance has
%% no separate applier process, so `reclaim_stable_cells/1` previously
%% always returned `reclamation_stalled(InstanceId, no_applier)` for it,
%% permanently: `bondy_oplog_gc_scheduler` drives every instance
%% unfiltered, so a fused shard's dead cells (e.g. an emptied group's
%% tombstone) accumulated forever, silently. `bondy_oplog_cell_utils:
%% sweep/5` (shared with the applier) now runs in-process on the fused
%% instance.
-module(bondy_oplog_reclamation_fused_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).

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

reclamation_fused_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun solo_fused_reclaims_the_tail_tombstone/0,
        fun pn_counter_reclaims_at_algebraic_zero/0,
        fun struct_reclaims_via_schema_stabilize_policy/0
    ]}.

%% Mirrors `bondy_oplog_reclamation_test:solo_reclaims_the_tail_tombstone/0`
%% exactly, on a fused instance.
solo_fused_reclaims_the_tail_tombstone() ->
    Id = start_fused_instance(undefined, #{}),
    K = <<"doomed">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {set, <<"v">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, clear}),
    ok = bondy_oplog_instance:await_apply(Id),

    {ok, Stats} = bondy_oplog_instance:reclaim_stable_cells(Id),
    ?assert(maps:get(discarded, Stats) >= 1),

    teardown(Id).

%% A bare `bondy_oplog_crdt_pn_counter` cell (the shape `bondy_subscription_
%% rib` registers directly, no per-use-case wrapper module) reclaims once its
%% value returns to zero and is causally stable — the config-free
%% `stabilize/2` added directly to the counter module (mirrors `dw_flag`/
%% `ew_flag`'s existing pattern). `pn_counter` exports no `removal_op/0` — no
%% explicit clear/removal event exists for this CRDT, unlike
%% `solo_fused_reclaims_the_tail_tombstone/0` above — so this is a genuinely
%% different reclamation path from every other fused-reclamation test in this
%% repo, previously exercised nowhere.
pn_counter_reclaims_at_algebraic_zero() ->
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}),
    K = <<"vehicle_42">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, 1}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, -1}}),
    ok = bondy_oplog_instance:await_apply(Id),

    {ok, Stats} = bondy_oplog_instance:reclaim_stable_cells(Id),
    ?assert(maps:get(discarded, Stats) >= 1),

    teardown(Id).

%% A `bondy_oplog_crdt_struct` cell registered directly (schema passed as
%% `crdt_opts` — the struct has no schema of its own; this exercises the
%% kernel's opts-aware `init/2` cold-start path end to end on a real fused
%% instance) reclaims once every field declaring a `stabilize_zero` policy
%% holds that value and is causally stable — mirrors
%% `bondy_namespace_catalog`'s `?RIB_REGISTRATION_SCHEMA` `count` field
%% policy exactly. Previously exercised nowhere: every other reclamation
%% test in this repo drives `lww_register`'s explicit clear/tombstone path.
struct_reclaims_via_schema_stabilize_policy() ->
    Schema = #{
        count => {bondy_oplog_crdt_pn_counter, #{stabilize_zero => 0}},
        invoke => bondy_oplog_crdt_lww_register
    },
    Id = start_fused_instance(bondy_oplog_crdt_struct, Schema),
    K = <<"group_1">>,
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, K, {apply, count, {inc, 1}}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, K, {apply, count, {inc, -1}}}
    ),
    ok = bondy_oplog_instance:await_apply(Id),

    {ok, Stats} = bondy_oplog_instance:reclaim_stable_cells(Id),
    ?assert(maps:get(discarded, Stats) >= 1),

    teardown(Id).

%% -----------------------------------------------------------------------------
%% Helpers
%% -----------------------------------------------------------------------------

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

mk_id() ->
    iolist_to_binary([
        "reclaim_fused_",
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
