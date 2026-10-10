%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% The stability-point chain and the reclamation façade:
%%
%%   reclamation_members() → confirmed_peer_states/2 → compute_frontier_for/2
%%     → is_key guard → key_hlc → StableHlc → sweep_stable_cells/2
%%
%% Covers the chain outcomes (clustering disabled, fully confirmed, partially
%% confirmed, no other member, non-event frontier), asserts the derived
%% StableHlc against a HAND-COMPUTED frontier (not against itself), and pins
%% the "in effect" contract: with clustering enabled, an unavailable
%% membership or one listing no other member reclaims NOTHING, while
%% clustering disabled reclaims maximally.
%% =============================================================================

-module(bondy_oplog_reclamation_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Deterministic timing — no AE/GC scheduler racing the chain.
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    try
        meck:unload(bondy_cluster)
    catch
        _:_ -> ok
    end,
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

reclamation_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun disabled_stability_point_is_a_fresh_tick/0,
        fun disabled_reclaims_the_tail_tombstone/0,
        fun membership_error_reclaims_nothing/0,
        fun no_other_member_with_clustering_reclaims_nothing/0,
        fun empty_tree_is_idle_not_stalled/0,
        fun unconfirmed_member_blocks_stability/0,
        fun confirmed_frontier_is_hand_computed/0,
        fun non_event_frontier_is_a_named_error/0,
        fun stall_is_observable_within_one_interval/0
    ]}.

%% -----------------------------------------------------------------------------
%% Clustering disabled
%% -----------------------------------------------------------------------------

disabled_stability_point_is_a_fresh_tick() ->
    Id = start_instance(),
    K1 = bondy_oplog:append(Id, {cell_apply, ?B, <<"a">>, {set, <<"v">>}}),
    ok = bondy_oplog_instance:await_apply(Id),

    {ok, SP} = bondy_oplog_instance:stability_point(Id),
    %% The point strictly dominates every held event (the tick is fresh) ...
    ?assert(SP > bondy_oplog_event:key_hlc(K1)),
    %% ... and every subsequent mint strictly dominates the point.
    K2 = bondy_oplog:append(Id, {cell_apply, ?B, <<"b">>, {set, <<"w">>}}),
    ?assert(bondy_oplog_event:key_hlc(K2) > SP),

    teardown(Id).

%% The tombstone is the LAST event in the MST — the case an
%% `bondy_mst:last/1`-derived carve-out can never license (strict `<` against
%% its own HLC). The fresh-tick carve-out reclaims it.
disabled_reclaims_the_tail_tombstone() ->
    Id = start_instance(),
    K = <<"doomed">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {set, <<"v">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, clear}),
    ok = bondy_oplog_instance:await_apply(Id),

    {ok, Stats} = bondy_oplog_instance:reclaim_stable_cells(Id),
    ?assert(maps:get(discarded, Stats) >= 1),

    teardown(Id).

%% -----------------------------------------------------------------------------
%% Clustering enabled without a usable membership — the "in effect" contract
%% -----------------------------------------------------------------------------

membership_error_reclaims_nothing() ->
    Id = start_instance(),
    K = <<"survivor">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {set, <<"v">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, clear}),
    ok = bondy_oplog_instance:await_apply(Id),

    bondy_oplog_test_helpers:with_members(
        fun() -> error(badarg) end,
        fun() ->
            ?assertEqual(
                {error, membership_unavailable},
                bondy_oplog_instance:reclaim_stable_cells(Id)
            )
        end
    ),

    %% The tombstone genuinely survived the failed attempt: a pass with
    %% clustering disabled afterwards still finds and discards it.
    {ok, Stats} = bondy_oplog_instance:reclaim_stable_cells(Id),
    ?assert(maps:get(discarded, Stats) >= 1),

    teardown(Id).

%% A member that has just restarted lists only itself until it rejoins, so
%% with clustering enabled that membership licenses nothing.
no_other_member_with_clustering_reclaims_nothing() ->
    Id = start_instance(),
    K = <<"kept">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {set, <<"v">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, clear}),
    ok = bondy_oplog_instance:await_apply(Id),

    bondy_oplog_test_helpers:with_members(
        fun() -> [partisan:node()] end,
        fun() ->
            ?assertEqual(
                {error, no_members},
                bondy_oplog_instance:reclaim_stable_cells(Id)
            )
        end
    ),

    {ok, Stats} = bondy_oplog_instance:reclaim_stable_cells(Id),
    ?assert(maps:get(discarded, Stats) >= 1),

    teardown(Id).

%% -----------------------------------------------------------------------------
%% Nothing applied in a cluster — vacuous, reported as `idle`
%% -----------------------------------------------------------------------------

%% A clustered replica that has applied nothing holds no cell whose
%% stability needs certifying: the outcome is the distinct, non-actionable
%% `idle` — NOT `unconfirmed` (which tells the operator to revive a member
%% that is alive and converged). The first local event ends the idle state
%% and the ordinary confirmation discipline takes over. A tree emptied by
%% compaction keeps its frontier and is not idle
%% (`bondy_reclamation_cluster_SUITE:compacted_tombstone_is_reclaimed/1`).
empty_tree_is_idle_not_stalled() ->
    Id = start_instance(),
    Ghost = 'ghost@nowhere',
    bondy_oplog_test_helpers:with_members(
        fun() -> lists:usort([partisan:node(), Ghost]) end,
        fun() ->
            ?assertEqual(
                {error, idle},
                bondy_oplog_instance:reclaim_stable_cells(Id)
            ),

            %% A local event ends idle: the same unconfirmed member now
            %% genuinely holds stability down.
            _ = bondy_oplog:append(
                Id, {cell_apply, ?B, <<"k">>, {set, <<"v">>}}
            ),
            ok = bondy_oplog_instance:await_apply(Id),
            ?assertEqual(
                {error, {unconfirmed, [Ghost]}},
                bondy_oplog_instance:reclaim_stable_cells(Id)
            )
        end
    ),
    teardown(Id).

%% -----------------------------------------------------------------------------
%% Partially confirmed — a silent member holds stability down
%% -----------------------------------------------------------------------------

unconfirmed_member_blocks_stability() ->
    Id = start_instance(),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"held">>, {set, <<"v">>}}),
    ok = bondy_oplog_instance:await_apply(Id),
    Ghost = 'ghost@nowhere',
    bondy_oplog_test_helpers:with_members(
        fun() -> lists:usort([partisan:node(), Ghost]) end,
        fun() ->
            ?assertEqual(
                {error, {unconfirmed, [Ghost]}},
                bondy_oplog_instance:reclaim_stable_cells(Id)
            )
        end
    ),
    teardown(Id).

%% -----------------------------------------------------------------------------
%% Fully confirmed — the point equals the hand-computed frontier
%% -----------------------------------------------------------------------------

confirmed_frontier_is_hand_computed() ->
    Id = start_instance(),
    Ghost = 'peer@confirmed',

    %% e1 set kA, e2 CLEAR kA (the reclaimable tombstone), e3 set kB.
    _K1 = bondy_oplog:append(Id, {cell_apply, ?B, <<"kA">>, {set, <<"v">>}}),
    _K2 = bondy_oplog:append(Id, {cell_apply, ?B, <<"kA">>, clear}),
    K3 = bondy_oplog:append(Id, {cell_apply, ?B, <<"kB">>, {set, <<"w">>}}),
    ok = bondy_oplog_instance:await_apply(Id),
    %% The peer's durable frontier: everything up to and including e3.
    Witness = bondy_oplog_registry:frontier(Id),
    %% e4 lands AFTER the peer's frontier: the first key it does not cover.
    K4 = bondy_oplog:append(Id, {cell_apply, ?B, <<"kC">>, {set, <<"x">>}}),
    ok = bondy_oplog_instance:await_apply(Id),

    ok = bondy_oplog_peer_state:record_sync_complete(Ghost, Id, Witness),
    ok = bondy_oplog_peer_state:sync(),

    bondy_oplog_test_helpers:with_members(
        fun() -> lists:usort([partisan:node(), Ghost]) end,
        fun() ->
            %% Hand-computed: the first local key `Witness` does not cover is
            %% e4, so the stability point is e4's HLC — asserted against the
            %% captured event keys, not against the chain's own output.
            {ok, SP} = bondy_oplog_instance:stability_point(Id),
            ?assert(bondy_oplog_event:key_hlc(K3) < SP),
            ?assertEqual(bondy_oplog_event:key_hlc(K4), SP),

            %% In effect: the kA tombstone (HLC < SP) is reclaimed ...
            {ok, Stats} = bondy_oplog_instance:reclaim_stable_cells(Id),
            ?assert(maps:get(discarded, Stats) >= 1),

            %% ... while a tombstone minted above e4 is retained: the peer has
            %% not confirmed anything past e3, so a second pass discards
            %% nothing.
            _K5 = bondy_oplog:append(Id, {cell_apply, ?B, <<"kB">>, clear}),
            ok = bondy_oplog_instance:await_apply(Id),
            {ok, Stats2} = bondy_oplog_instance:reclaim_stable_cells(Id),
            ?assertEqual(0, maps:get(discarded, Stats2))
        end
    ),
    teardown(Id).

%% -----------------------------------------------------------------------------
%% Non-event frontier — a named error, never a raise inside a GC worker
%% -----------------------------------------------------------------------------

non_event_frontier_is_a_named_error() ->
    ?assertEqual(
        {error, non_event_frontier},
        bondy_oplog_instance:frontier_stability_point(<<"not-an-event-key">>)
    ),
    K = bondy_oplog_event:key(1234, <<"origin">>, 1),
    ?assertEqual(
        {ok, 1234},
        bondy_oplog_instance:frontier_stability_point(K)
    ).

%% -----------------------------------------------------------------------------
%% Observability: a stall must be visible within ONE interval
%% -----------------------------------------------------------------------------
%%
%% Reclamation fails silently in both directions, so a member that never
%% confirms (here: present in the membership, absent from peer state — the
%% "killed member" case) must surface within one scheduler interval as BOTH
%% the reclamation-level stall event (naming the missing members) and the
%% scheduler-level trigger outcome. A stall that cannot be seen is the
%% failure mode this case exists for.

stall_is_observable_within_one_interval() ->
    Id = start_instance(),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"held">>, {set, <<"v">>}}),
    ok = bondy_oplog_instance:await_apply(Id),
    Ghost = 'dead-member@nowhere',
    Self = self(),
    HandlerId = {?MODULE, stall_probe},
    ok = telemetry:attach_many(
        HandlerId,
        [
            [bondy_oplog, reclamation, stalled],
            [bondy_oplog, scheduler, gc, trigger_outcome]
        ],
        fun(Event, Meas, Meta, _) ->
            Self ! {telemetry, Event, Meas, Meta}
        end,
        undefined
    ),
    try
        bondy_oplog_test_helpers:with_members(
            fun() -> lists:usort([partisan:node(), Ghost]) end,
            fun() ->
                {ok, SchedPid} = bondy_oplog_gc_scheduler:start_link(#{
                    name => reclaim_sched_probe,
                    interval_ms => 100,
                    trigger => fun bondy_oplog_instance:reclaim_stable_cells/1
                }),
                try
                    receive
                        {telemetry, [bondy_oplog, reclamation, stalled], _,
                            Meta} ->
                            ?assertEqual(Id, maps:get(instance_id, Meta)),
                            ?assertEqual(unconfirmed, maps:get(reason, Meta)),
                            ?assertEqual(
                                [Ghost], maps:get(missing_members, Meta)
                            )
                    after 2000 ->
                        error(stall_not_observable)
                    end,
                    receive
                        {telemetry,
                            [bondy_oplog, scheduler, gc, trigger_outcome], _,
                            OMeta} ->
                            ?assertEqual(unconfirmed, maps:get(outcome, OMeta)),
                            ?assertEqual(
                                reclaim_sched_probe, maps:get(scheduler, OMeta)
                            )
                    after 2000 ->
                        error(outcome_not_observable)
                    end
                after
                    gen_server:stop(SchedPid)
                end
            end
        )
    after
        telemetry:detach(HandlerId),
        teardown(Id)
    end.

%% -----------------------------------------------------------------------------
%% Helpers
%% -----------------------------------------------------------------------------

start_instance() ->
    Id = mk_id(),
    NS = ns_of(Id),
    _ = register_shard(NS, primary, 0),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        origin => bondy_oplog_origin:new(),
        applier => #{
            cell_apply_target => {NS, primary, 0}
        }
    }),
    Id.

register_shard(NS, Index, Shard) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        overlay => disabled,
        fold_module => lww_register
    }),
    {Cache, Proj}.

mk_id() ->
    iolist_to_binary([
        "reclaim_",
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
