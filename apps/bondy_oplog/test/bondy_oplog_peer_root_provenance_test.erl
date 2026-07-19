%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% PROVENANCE OF THE "PEER CONFIRMED ROOT"
%%
%% `bondy_oplog_instance:compute_frontier_for/2` is documented as "the largest
%% local key K such that every local key =< K is present in EVERY peer's
%% confirmed root". That contract only holds if the roots it is fed are roots
%% the PEERS hold. The session must therefore checkpoint the peer's root, not
%% its own.
%%
%% The distinction is invisible while replicas agree, so these tests build a
%% divergence a pull cannot repair: B has history, A pulls it, A then writes an
%% event B never receives (sync is pull-only, so B gets nothing from A), and A
%% pulls again. A's root and B's root now differ, and the two readings give
%% different, checkable answers.
%%
%% Recording the local root here would make the frontier a measure of A's own
%% sync recency rather than of peer knowledge, and it would cover events no
%% peer holds — unsound for anything that reclaims on stability
%% (BONDY_DB_DELETE_DESIGN.md §4.6).
%% =============================================================================

-module(bondy_oplog_peer_root_provenance_test).

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

peer_root_provenance_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 60, fun records_peer_root_not_local_root/0},
        {timeout, 60, fun frontier_stops_below_events_peer_lacks/0},
        {timeout, 60, fun empty_peer_checkpoints_nothing/0},
        {timeout, 60, fun swap_checkpoints_the_same_root_on_both_sides/0}
    ]}.

%% -----------------------------------------------------------------------------
%% 0. The swap: both sides checkpoint the SAME root
%% -----------------------------------------------------------------------------
%%
%% Canteen's stability is the intersection of *common sub-graphs* — objects both
%% replicas agree on (§3.3). A bare pull gives no such object: each side would
%% hold only what it unilaterally observed of the other, captured at its own
%% times, so stability advances at different rates and compaction diverges
%% (measured: `bondy_frontier_cluster_SUITE:asymmetric_compaction_keeps_oracle_in_sync`
%% fails on root inequality).
%%
%% The session therefore ends by confirming to the peer that it now holds the
%% advertised root. Both then checkpoint that same root against each other.

swap_checkpoints_the_same_root_on_both_sides() ->
    {A, B} = two_instances(),
    [bondy_oplog:append(B, {shared, N}) || N <- lists:seq(1, 20)],

    RootBefore = bondy_oplog:root_hash(B),
    ?assertMatch({ok, _}, bondy_oplog:sync(A, B)),
    ok = bondy_oplog_peer_state:sync(),

    %% A checkpointed B's root...
    ?assertEqual(RootBefore, recorded_root_for(A)),

    %% ...and B checkpointed the same root against A, because A confirmed it
    %% holds it. One shared object, not two observations.
    ?assertEqual(
        RootBefore,
        recorded_root_for(B),
        "peer did not checkpoint the confirmed root — the frontier would be "
        "two unilateral observations rather than a common sub-graph"
    ),

    ?assertEqual(recorded_root_for(A), recorded_root_for(B)).

%% -----------------------------------------------------------------------------
%% 1. The checkpointed root is the peer's
%% -----------------------------------------------------------------------------

records_peer_root_not_local_root() ->
    {A, B} = diverged_pair(),

    RootA = bondy_oplog:root_hash(A),
    RootB = bondy_oplog:root_hash(B),

    %% Precondition: the divergence is real, so the two readings differ.
    ?assertNotEqual(
        RootA,
        RootB,
        "test is only discriminating when A and B have diverged"
    ),

    Recorded = recorded_root_for(A),
    ?assertNotEqual(
        undefined,
        Recorded,
        "sync completed but no root was checkpointed"
    ),

    ?assertEqual(
        RootB,
        Recorded,
        "peer_state must checkpoint the peer's root"
    ),

    %% Stated negatively too: recording A's own root is the specific defect
    %% this guards against, and it would satisfy no other assertion here.
    ?assertNotEqual(
        RootA,
        Recorded,
        "peer_state checkpointed A's own root — the frontier would then "
        "measure A's sync recency, not what B holds"
    ).

%% -----------------------------------------------------------------------------
%% 2. The frontier therefore bounds correctly
%% -----------------------------------------------------------------------------
%%
%% The consequence that matters. The frontier must stop strictly below any
%% event the peer has not received, while still advancing over the shared
%% prefix — a frontier that collapsed to `undefined` would stall compaction.

frontier_stops_below_events_peer_lacks() ->
    {A, _B} = diverged_pair(),

    PeerRoots = [
        maps:get(root_hash, P)
     || P <- bondy_oplog_peer_state:get_instance_peer_states(A)
    ],
    ?assertNotEqual([], PeerRoots, "no peer roots checkpointed for A"),

    MST = bondy_oplog_registry:mst(A),
    Frontier = bondy_oplog_instance:compute_frontier_for(MST, PeerRoots),

    LocalMax =
        case bondy_mst:last(MST) of
            {K, _} -> K;
            undefined -> undefined
        end,
    ?assertNotEqual(undefined, LocalMax),

    ?assertNotEqual(
        LocalMax,
        Frontier,
        "frontier covers the event B never received"
    ),
    ?assertNotEqual(
        undefined,
        Frontier,
        "frontier collapsed to undefined — compaction would stall"
    ),
    ?assert(Frontier < LocalMax).

%% -----------------------------------------------------------------------------
%% 3. An empty peer confirms nothing
%% -----------------------------------------------------------------------------
%%
%% A peer with no root has told us nothing about what it holds, so there is
%% nothing to checkpoint. Previously the local root was recorded here, which
%% asserted peer knowledge that does not exist.

empty_peer_checkpoints_nothing() ->
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog:start_instance(B, originated_opts()),

    %% A has data; B is empty.
    [bondy_oplog:append(A, {a, N}) || N <- lists:seq(1, 10)],
    _ = bondy_oplog_instance:await_apply(A),

    ?assertMatch({ok, _}, bondy_oplog:sync(A, B)),

    ?assertEqual(
        undefined,
        recorded_root_for(A),
        "checkpointed a root for a peer that advertised none"
    ).

%% -----------------------------------------------------------------------------
%% Helpers
%% -----------------------------------------------------------------------------

%% B has history that A pulls; A then writes an event B never receives.
diverged_pair() ->
    {A, B} = two_instances(),
    [bondy_oplog:append(B, {shared, N}) || N <- lists:seq(1, 20)],
    ?assertMatch({ok, _}, bondy_oplog:sync(A, B)),

    _ = bondy_oplog:append(A, {a_only, 1}),
    _ = bondy_oplog_instance:await_apply(A),
    ?assertMatch({ok, _}, bondy_oplog:sync(A, B)),
    {A, B}.

two_instances() ->
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog:start_instance(B, originated_opts()),
    {A, B}.

recorded_root_for(Instance) ->
    case bondy_oplog_peer_state:get_instance_peer_states(Instance) of
        [] -> undefined;
        [P | _] -> maps:get(root_hash, P, undefined)
    end.

mk_inst() ->
    list_to_binary(
        "provenance_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

originated_opts() ->
    #{origin => bondy_oplog_origin:new()}.
