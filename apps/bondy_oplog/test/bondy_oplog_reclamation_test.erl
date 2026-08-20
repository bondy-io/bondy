%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Step 3 of BONDY_DB_RECLAMATION_PLAN.md — the stability-point chain and the
%% reclamation façade:
%%
%%   reclamation_members() → confirmed_peer_states/2 → compute_frontier_for/2
%%     → is_key guard → key_hlc → StableHlc → sweep_stable_cells/2
%%
%% Covers the four chain outcomes (solo, fully confirmed, partially confirmed,
%% non-event frontier), asserts the derived StableHlc against a HAND-COMPUTED
%% frontier (not against itself), and pins the Step 2 "in effect" contract:
%% an unavailable membership service reclaims NOTHING while genuine solo
%% reclaims maximally.
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
        meck:unload(partisan_peer_service)
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
        fun solo_stability_point_is_a_fresh_tick/0,
        fun solo_reclaims_the_tail_tombstone/0,
        fun membership_error_reclaims_nothing/0,
        fun empty_tree_is_idle_not_stalled/0,
        fun unconfirmed_member_blocks_stability/0,
        fun confirmed_frontier_is_hand_computed/0,
        fun non_event_frontier_is_a_named_error/0,
        fun stall_is_observable_within_one_interval/0
    ]}.

%% -----------------------------------------------------------------------------
%% Solo
%% -----------------------------------------------------------------------------

solo_stability_point_is_a_fresh_tick() ->
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
solo_reclaims_the_tail_tombstone() ->
    Id = start_instance(),
    K = <<"doomed">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {set, <<"v">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, clear}),
    ok = bondy_oplog_instance:await_apply(Id),

    {ok, Stats} = bondy_oplog_instance:reclaim_stable_cells(Id),
    ?assert(maps:get(discarded, Stats) >= 1),

    teardown(Id).

%% -----------------------------------------------------------------------------
%% Membership unavailable ≠ solo — the Step 2 "in effect" contract
%% -----------------------------------------------------------------------------

membership_error_reclaims_nothing() ->
    Id = start_instance(),
    K = <<"survivor">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {set, <<"v">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, clear}),
    ok = bondy_oplog_instance:await_apply(Id),

    ok = meck:new(partisan_peer_service, [passthrough]),
    try
        ok = meck:expect(partisan_peer_service, members, fun() ->
            exit({noproc, {gen_server, call, [partisan_peer_service]}})
        end),
        ?assertEqual(
            {error, membership_unavailable},
            bondy_oplog_instance:reclaim_stable_cells(Id)
        )
    after
        meck:unload(partisan_peer_service)
    end,

    %% The tombstone genuinely survived the failed attempt: a solo pass
    %% afterwards still finds and discards it.
    {ok, Stats} = bondy_oplog_instance:reclaim_stable_cells(Id),
    ?assert(maps:get(discarded, Stats) >= 1),

    teardown(Id).

%% -----------------------------------------------------------------------------
%% Empty local tree in a cluster — vacuous, reported as `idle`
%% -----------------------------------------------------------------------------

%% A clustered replica whose MST holds no events (never written, or fully
%% compacted) can have no frontier by construction and holds nothing whose
%% stability needs certifying: the outcome is the distinct, non-actionable
%% `idle` — NOT `unconfirmed` (which tells the operator to revive a member
%% that is alive and converged). The first local event ends the idle state
%% and the ordinary confirmation discipline takes over.
empty_tree_is_idle_not_stalled() ->
    Id = start_instance(),
    Ghost = 'ghost@nowhere',
    ok = meck:new(partisan_peer_service, [passthrough]),
    try
        ok = meck:expect(partisan_peer_service, members, fun() ->
            {ok, [partisan:node(), Ghost]}
        end),
        ?assertEqual(
            {error, idle},
            bondy_oplog_instance:reclaim_stable_cells(Id)
        ),

        %% A local event ends idle: the same unconfirmed member now
        %% genuinely holds stability down.
        _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k">>, {set, <<"v">>}}),
        ok = bondy_oplog_instance:await_apply(Id),
        ?assertEqual(
            {error, {unconfirmed, [Ghost]}},
            bondy_oplog_instance:reclaim_stable_cells(Id)
        )
    after
        meck:unload(partisan_peer_service)
    end,
    teardown(Id).

%% -----------------------------------------------------------------------------
%% Partially confirmed — a silent member holds stability down
%% -----------------------------------------------------------------------------

unconfirmed_member_blocks_stability() ->
    Id = start_instance(),
    %% The instance must HOLD an event: an empty tree is the vacuous
    %% `idle` case (tested separately), not a member-blocked stall.
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"held">>, {set, <<"v">>}}),
    ok = bondy_oplog_instance:await_apply(Id),
    Ghost = 'ghost@nowhere',
    ok = meck:new(partisan_peer_service, [passthrough]),
    try
        ok = meck:expect(partisan_peer_service, members, fun() ->
            {ok, [partisan:node(), Ghost]}
        end),
        ?assertEqual(
            {error, {unconfirmed, [Ghost]}},
            bondy_oplog_instance:reclaim_stable_cells(Id)
        )
    after
        meck:unload(partisan_peer_service)
    end,
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
    %% The peer's confirmed root: everything up to and including e3.
    R3 = bondy_oplog_instance:root_hash(Id),
    ?assert(is_binary(R3)),
    %% e4 lands AFTER the confirmed root — outside the frontier.
    _K4 = bondy_oplog:append(Id, {cell_apply, ?B, <<"kC">>, {set, <<"x">>}}),
    ok = bondy_oplog_instance:await_apply(Id),

    ok = bondy_oplog_peer_state:record_sync_complete(Ghost, Id, R3),
    ok = bondy_oplog_peer_state:sync(),

    ok = meck:new(partisan_peer_service, [passthrough]),
    try
        ok = meck:expect(partisan_peer_service, members, fun() ->
            {ok, [partisan:node(), Ghost]}
        end),

        %% Hand-computed: the largest local key covered by R3 is e3, so the
        %% stability point IS e3's HLC — asserted against the captured event
        %% key, not against the chain's own output.
        {ok, SP} = bondy_oplog_instance:stability_point(Id),
        ?assertEqual(bondy_oplog_event:key_hlc(K3), SP),

        %% In effect: the kA tombstone (HLC < SP) is reclaimed ...
        {ok, Stats} = bondy_oplog_instance:reclaim_stable_cells(Id),
        ?assert(maps:get(discarded, Stats) >= 1),

        %% ... while a tombstone minted ABOVE the frontier is retained: the
        %% peer has not confirmed anything past e3, so a second pass at the
        %% same point discards nothing.
        _K5 = bondy_oplog:append(Id, {cell_apply, ?B, <<"kB">>, clear}),
        ok = bondy_oplog_instance:await_apply(Id),
        {ok, Stats2} = bondy_oplog_instance:reclaim_stable_cells(Id),
        ?assertEqual(0, maps:get(discarded, Stats2))
    after
        meck:unload(partisan_peer_service)
    end,
    teardown(Id).

%% -----------------------------------------------------------------------------
%% Non-event frontier — a named error, never a raise inside a GC worker
%% -----------------------------------------------------------------------------

non_event_frontier_is_a_named_error() ->
    ?assertEqual(
        {error, no_frontier},
        bondy_oplog_instance:frontier_stability_point(undefined)
    ),
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
%% Step 6 — observability: a stall must be visible within ONE interval
%% -----------------------------------------------------------------------------
%%
%% Reclamation fails silently in both directions, so a member that never
%% confirms (here: present in the membership, absent from peer state — the
%% "killed member" case) must surface within one scheduler interval as BOTH
%% the reclamation-level stall event (naming the missing members) and the
%% scheduler-level trigger outcome. A stall that cannot be seen is the
%% failure mode Step 6 exists for.

stall_is_observable_within_one_interval() ->
    Id = start_instance(),
    %% Hold an event so the ghost member genuinely blocks stability (an
    %% empty tree would be the non-actionable `idle`, which never warns).
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
    ok = meck:new(partisan_peer_service, [passthrough]),
    ok = meck:expect(partisan_peer_service, members, fun() ->
        {ok, [partisan:node(), Ghost]}
    end),
    {ok, SchedPid} = bondy_oplog_gc_scheduler:start_link(#{
        name => reclaim_sched_probe,
        interval_ms => 100,
        trigger => fun bondy_oplog_instance:reclaim_stable_cells/1
    }),
    try
        receive
            {telemetry, [bondy_oplog, reclamation, stalled], _, Meta} ->
                ?assertEqual(Id, maps:get(instance_id, Meta)),
                ?assertEqual(unconfirmed, maps:get(reason, Meta)),
                ?assertEqual([Ghost], maps:get(missing_members, Meta))
        after 2000 ->
            error(stall_not_observable)
        end,
        receive
            {telemetry, [bondy_oplog, scheduler, gc, trigger_outcome], _,
                OMeta} ->
                ?assertEqual(unconfirmed, maps:get(outcome, OMeta)),
                ?assertEqual(
                    reclaim_sched_probe, maps:get(scheduler, OMeta)
                )
        after 2000 ->
            error(outcome_not_observable)
        end
    after
        telemetry:detach(HandlerId),
        gen_server:stop(SchedPid),
        meck:unload(partisan_peer_service),
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
        fold_module => lww_register,
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
