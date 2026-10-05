%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% PROVENANCE OF A RECORDED PEER FRONTIER
%%
%% `bondy_oplog_instance:compute_frontier_for/2` is the largest local key K such
%% that every local key =< K is covered by every member's durable frontier. That
%% only holds if the frontier recorded against a peer is the PEER's, so the
%% session must record the peer's, never its own.
%%
%% The distinction is invisible while replicas agree, so these tests build a
%% divergence a pull cannot repair: B has history, A pulls it, A then writes an
%% event B never receives (sync is pull-only, so B gets nothing from A), and A
%% pulls again. A's frontier and B's now differ, and the two readings give
%% different, checkable answers. The instances are ephemeral, so each one's
%% durable frontier is its applied one.
%% =============================================================================

-module(bondy_oplog_peer_frontier_provenance_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Drive sync explicitly.
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

peer_frontier_provenance_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 60, fun records_peer_frontier_not_local_frontier/0},
        {timeout, 60, fun frontier_stops_below_events_peer_lacks/0},
        {timeout, 60, fun empty_peer_records_nothing/0},
        {timeout, 60, fun swap_records_each_sides_frontier/0}
    ]}.

%% -----------------------------------------------------------------------------
%% 0. The swap: each side records the other's frontier
%% -----------------------------------------------------------------------------
%%
%% Sync is pull-only, so a pull alone tells only the puller about the pulled
%% side. The session therefore ends by reporting the puller's own durable
%% frontier to the peer, which records it.

swap_records_each_sides_frontier() ->
    {A, B} = two_instances(),
    _ = bondy_oplog:append(A, bondy_oplog_test_projection:cell_op(1)),
    [
        bondy_oplog:append(B, bondy_oplog_test_projection:cell_op(N))
     || N <- lists:seq(2, 21)
    ],
    ok = bondy_oplog_test_projection:drain(A),
    ok = bondy_oplog_test_projection:drain(B),

    ?assertMatch({ok, _}, bondy_oplog:sync(A, B)),
    ok = bondy_oplog_peer_state:sync(),

    %% A recorded B's frontier...
    ?assertEqual(
        20, maps:get(bondy_oplog_instance:origin(B), recorded_for(A), 0)
    ),
    %% ...and B recorded A's, because A reported it.
    ?assertEqual(
        1,
        maps:get(bondy_oplog_instance:origin(A), recorded_for(B), 0),
        "peer did not record the reported frontier"
    ).

%% -----------------------------------------------------------------------------
%% 1. The recorded frontier is the peer's
%% -----------------------------------------------------------------------------

records_peer_frontier_not_local_frontier() ->
    {A, B} = diverged_pair(),
    FrontierA = bondy_oplog_registry:frontier(A),
    FrontierB = bondy_oplog_registry:frontier(B),

    %% Precondition: the divergence is real, so the two readings differ.
    ?assertNotEqual(
        FrontierA,
        FrontierB,
        "test is only discriminating when A and B have diverged"
    ),
    ?assertEqual(FrontierB, recorded_for(A), "peer_state must record B's").

%% -----------------------------------------------------------------------------
%% 2. The stability frontier therefore bounds correctly
%% -----------------------------------------------------------------------------
%%
%% The frontier must stop strictly below any event the peer has not folded,
%% while still advancing over the shared prefix — a frontier that collapsed to
%% `undefined` would stall compaction.

frontier_stops_below_events_peer_lacks() ->
    {A, _B} = diverged_pair(),
    MST = bondy_oplog_registry:mst(A),
    Frontier = bondy_oplog_instance:compute_frontier_for(MST, [recorded_for(A)]),
    {LocalMax, _} = bondy_mst:last(MST),

    ?assertNotEqual(
        undefined,
        Frontier,
        "frontier collapsed to undefined — compaction would stall"
    ),
    ?assert(Frontier < LocalMax).

%% -----------------------------------------------------------------------------
%% 3. An empty peer confirms nothing
%% -----------------------------------------------------------------------------

empty_peer_records_nothing() ->
    {A, B} = two_instances(),
    [
        bondy_oplog:append(A, bondy_oplog_test_projection:cell_op(N))
     || N <- lists:seq(1, 10)
    ],
    ok = bondy_oplog_test_projection:drain(A),

    ?assertMatch({ok, _}, bondy_oplog:sync(A, B)),
    ok = bondy_oplog_peer_state:sync(),

    ?assertEqual(
        undefined,
        recorded_for(A),
        "recorded a frontier for a peer that claims nothing"
    ).

%% -----------------------------------------------------------------------------
%% Helpers
%% -----------------------------------------------------------------------------

%% B has history that A pulls; A then writes an event B never receives.
diverged_pair() ->
    {A, B} = two_instances(),
    [
        bondy_oplog:append(B, bondy_oplog_test_projection:cell_op(N))
     || N <- lists:seq(1, 20)
    ],
    ok = bondy_oplog_test_projection:drain(B),
    ?assertMatch({ok, _}, bondy_oplog:sync(A, B)),

    _ = bondy_oplog:append(A, bondy_oplog_test_projection:cell_op(21)),
    ok = bondy_oplog_test_projection:drain(A),
    ?assertMatch({ok, _}, bondy_oplog:sync(A, B)),
    ok = bondy_oplog_peer_state:sync(),
    {A, B}.

two_instances() ->
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog_test_projection:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog_test_projection:start_instance(B, originated_opts()),
    {A, B}.

recorded_for(Instance) ->
    case bondy_oplog_peer_state:get_instance_peer_states(Instance) of
        [] -> undefined;
        [#{frontier := F} | _] -> F
    end.

mk_inst() ->
    list_to_binary(
        "provenance_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

originated_opts() ->
    #{origin => bondy_oplog_origin:new()}.
