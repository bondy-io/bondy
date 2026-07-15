%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Convergence + de-risk tests for the first native NON-commutative
%% operation-based CRDT, `bondy_oplog_crdt_bounded_counter`.
%%
%% The headline proof: a concurrent group of {inc}/{dec} ops cannot be
%% converged by applying ops one at a time (arrival order changes the
%% clamped result), but `interpret_cog/2` over the whole group is a
%% deterministic function of the event SET — so two replicas that receive
%% the same ops in different orders agree. This is exactly the property
%% the operation-based re-grounding exists to deliver and that the
%% state-based folds could never express.
%%
%% Deterministic (no random seed) — CI-stable.

-module(bondy_oplog_crdt_bounded_counter_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_bounded_counter).

%% =============================================================================
%% Helpers
%% =============================================================================

ek(H, O, S) ->
    bondy_oplog_event:key(H, O, S).

ev(H, O, S, Op) ->
    bondy_oplog_event:new(ek(H, O, S), Op, #{}).

cell_ev(H, O, S, Bucket, Key, Op) ->
    bondy_oplog_event:new(ek(H, O, S), {cell_apply, Bucket, Key, Op}, #{}).

perms([]) ->
    [[]];
perms(L) ->
    [[X | P] || X <- L, P <- perms(L -- [X])].

%% The WRONG semantics: apply ops one at a time, clamping per op, in the
%% given arrival order. Used only to witness divergence — this is the path
%% `interpret_cog/2` replaces.
naive_apply(Events, {V0, H0}) ->
    lists:foldl(
        fun(E, {V, H}) ->
            H1 = erlang:max(
                H, bondy_oplog_event:key_hlc(bondy_oplog_event:key(E))
            ),
            V1 =
                case bondy_oplog_event:op(E) of
                    {inc, N} -> V + N;
                    {dec, N} -> erlang:max(0, V - N);
                    _ -> V
                end,
            {V1, H1}
        end,
        {V0, H0},
        Events
    ).

%% =============================================================================
%% Basics
%% =============================================================================

init_is_zero_test() ->
    ?assertEqual({0, 0}, ?CRDT:init()),
    ?assertEqual(0, ?CRDT:to_value(?CRDT:init())),
    ?assertEqual(0, ?CRDT:query(value, ?CRDT:init())).

declares_non_commutative_test() ->
    ?assertNot(?CRDT:order_independent()),
    ?assertNot(?CRDT:value_equals_state()).

simple_inc_dec_test() ->
    Es = [ev(10, <<"n1">>, 1, {inc, 5}), ev(20, <<"n1">>, 2, {dec, 2})],
    ?assertEqual({3, 20}, ?CRDT:interpret_cog(Es, ?CRDT:init())).

clamps_at_zero_test() ->
    %% Net negative group clamps to 0 at the group boundary.
    Es = [ev(10, <<"n1">>, 1, {inc, 1}), ev(20, <<"n1">>, 2, {dec, 5})],
    ?assertEqual({0, 20}, ?CRDT:interpret_cog(Es, ?CRDT:init())).

%% =============================================================================
%% Determinism in the event SET (every permutation agrees)
%% =============================================================================

interpret_cog_deterministic_in_set_test() ->
    Es = [
        ev(40, <<"n2">>, 1, {dec, 3}),
        ev(10, <<"n1">>, 1, {inc, 5}),
        ev(30, <<"n2">>, 2, {inc, 2}),
        ev(20, <<"n1">>, 2, {dec, 1})
    ],
    Init = ?CRDT:init(),
    [First | Rest] = [?CRDT:interpret_cog(P, Init) || P <- perms(Es)],
    ?assert(lists:all(fun(R) -> R =:= First end, Rest)),
    %% max(0, 0 + (5+2) - (3+1)) = 3 ; max hlc 40.
    ?assertEqual({3, 40}, First).

%% =============================================================================
%% THE de-risk witness: incremental application diverges; interpret_cog does not
%% =============================================================================

incremental_diverges_but_interpret_cog_converges_test() ->
    Dec = ev(10, <<"n2">>, 1, {dec, 1}),
    Inc = ev(20, <<"n1">>, 1, {inc, 1}),
    %% Naive per-op clamped apply: arrival order changes the answer.
    {VNaiveA, _} = naive_apply([Inc, Dec], ?CRDT:init()),
    {VNaiveB, _} = naive_apply([Dec, Inc], ?CRDT:init()),
    ?assertEqual(0, VNaiveA),
    ?assertEqual(1, VNaiveB),
    ?assertNotEqual(VNaiveA, VNaiveB),
    %% interpret_cog over the SAME set converges regardless of order.
    SA = ?CRDT:interpret_cog([Inc, Dec], ?CRDT:init()),
    SB = ?CRDT:interpret_cog([Dec, Inc], ?CRDT:init()),
    ?assertEqual(SA, SB),
    ?assertEqual(0, ?CRDT:to_value(SA)).

%% =============================================================================
%% Two replicas, divergent delivery order, same result
%% =============================================================================

two_replica_reorder_convergence_test() ->
    Es = [
        ev(10, <<"a">>, 1, {inc, 10}),
        ev(20, <<"b">>, 1, {dec, 4}),
        ev(30, <<"a">>, 2, {dec, 9}),
        ev(40, <<"b">>, 2, {inc, 1})
    ],
    ReplicaA = lists:reverse(Es),
    ReplicaB = [
        lists:nth(3, Es), lists:nth(1, Es), lists:nth(4, Es), lists:nth(2, Es)
    ],
    Init = ?CRDT:init(),
    SA = ?CRDT:interpret_cog(ReplicaA, Init),
    SB = ?CRDT:interpret_cog(ReplicaB, Init),
    ?assertEqual(SA, SB),
    %% max(0, 0 + (10+1) - (4+9)) = 0 (clamped); hlc 40.
    ?assertEqual({0, 40}, SA).

%% =============================================================================
%% Clamp-at-stability: deficit is forgotten at the group/checkpoint boundary
%% =============================================================================

forgotten_debt_at_stability_test() ->
    %% Group 1 drives to the floor, clamping away 2 units of decrement.
    G1 = [ev(10, <<"n1">>, 1, {inc, 1}), ev(20, <<"n1">>, 2, {dec, 3})],
    Ckpt = ?CRDT:interpret_cog(G1, ?CRDT:init()),
    ?assertEqual({0, 20}, Ckpt),
    %% Group 2 builds on the clamped checkpoint: the forgotten -2 deficit
    %% does NOT suppress the new increment.
    G2 = [ev(30, <<"n1">>, 3, {inc, 1})],
    ?assertEqual({1, 30}, ?CRDT:interpret_cog(G2, Ckpt)),
    %% Whereas summing ALL history would have stayed at the floor:
    AllHistory = G1 ++ G2,
    ?assertEqual({0, 30}, ?CRDT:interpret_cog(AllHistory, ?CRDT:init())).

%% =============================================================================
%% cell_apply unwrapping, HLC, encoding
%% =============================================================================

unwraps_cell_apply_test() ->
    Es = [
        cell_ev(10, <<"n1">>, 1, <<"bk">>, <<"k">>, {inc, 7}),
        cell_ev(20, <<"n1">>, 2, <<"bk">>, <<"k">>, {dec, 2})
    ],
    ?assertEqual({5, 20}, ?CRDT:interpret_cog(Es, ?CRDT:init())).

hlc_advances_to_group_max_test() ->
    %% Unknown/malformed ops still advance the HLC (the group is absorbed).
    Es = [ev(50, <<"n1">>, 1, {bogus, 1}), ev(10, <<"n1">>, 2, {inc, 2})],
    ?assertEqual({2, 50}, ?CRDT:interpret_cog(Es, ?CRDT:init())).

gc_threshold_is_state_hlc_test() ->
    S = ?CRDT:interpret_cog([ev(99, <<"n1">>, 1, {inc, 1})], ?CRDT:init()),
    ?assertEqual(?CRDT:hlc(S), ?CRDT:gc_threshold(S)).

encode_decode_roundtrip_test() ->
    S = ?CRDT:interpret_cog(
        [ev(10, <<"n1">>, 1, {inc, 123456789})], ?CRDT:init()
    ),
    ?assertEqual(S, ?CRDT:decode_state(?CRDT:encode_state(S))).
