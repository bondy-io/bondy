%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Dedicated unit coverage for the five commutative tier_0 CRDT twins —
%% `g_counter`, `pn_counter`, `g_set`, `max_register`, `min_register`. Before
%% PR-Z these were covered only by the `tier0_equivalence` test (a byte-for-
%% byte comparison against the now-deleted fold twins). With the folds gone,
%% these tests pin each CRDT's behaviour directly: the `apply_op/3` fold
%% produces the right value, `interpret_cog/2` is permutation-invariant (the
%% Strong Eventual Consistency property), duplicate redelivery is absorbed
%% (counters), the encoding round-trips, and the contract markers hold.

-module(bondy_oplog_crdt_tier0_test).

-include_lib("eunit/include/eunit.hrl").

-define(GC, bondy_oplog_crdt_g_counter).
-define(PN, bondy_oplog_crdt_pn_counter).
-define(GS, bondy_oplog_crdt_g_set).
-define(MAX, bondy_oplog_crdt_max_register).
-define(MIN, bondy_oplog_crdt_min_register).

k(H, O, S) ->
    bondy_oplog_event:key(H, O, S).

ev(H, O, S, Op) ->
    bondy_oplog_event:new(k(H, O, S), Op, #{}).

%% Fold `apply_op/3` over `{Op, Key}` pairs (the eager write path).
fold(Mod, Pairs) ->
    lists:foldl(
        fun({Op, Key}, S) -> Mod:apply_op(S, Op, Key) end, Mod:init(), Pairs
    ).

%% Assert `interpret_cog/2` is invariant under a few input permutations.
assert_cog_perm_invariant(Mod, Events) ->
    Base = Mod:interpret_cog(Events, Mod:init()),
    Want = Mod:to_value(Base),
    [
        ?assertEqual(Want, Mod:to_value(Mod:interpret_cog(P, Mod:init())))
     || P <- [lists:reverse(Events), rotate(Events, 1), rotate(Events, 2)]
    ].

rotate([], _) ->
    [];
rotate(L, N) ->
    {A, B} = lists:split(N rem length(L), L),
    B ++ A.

markers(Mod, OrderIndependent) ->
    ?assertEqual(tier_0, Mod:causal_tier()),
    ?assertEqual(OrderIndependent, Mod:order_independent()).

%% =============================================================================
%% g_counter
%% =============================================================================

g_counter_value_test() ->
    %% oA: inc 5 (seq1) + inc 2 (seq2) = 7; oB: inc 3 = 3; total 10.
    Pairs = [
        {{inc, 5}, k(1, <<"oA">>, 1)},
        {{inc, 3}, k(2, <<"oB">>, 1)},
        {{inc, 2}, k(3, <<"oA">>, 2)}
    ],
    ?assertEqual(10, ?GC:to_value(fold(?GC, Pairs))).

g_counter_dedups_redelivery_test() ->
    %% Same {origin, seq} delivered twice counts once (per-origin MaxSeq).
    Pairs = [
        {{inc, 5}, k(1, <<"oA">>, 1)},
        {{inc, 5}, k(1, <<"oA">>, 1)}
    ],
    ?assertEqual(5, ?GC:to_value(fold(?GC, Pairs))).

g_counter_cog_invariant_test() ->
    Events = [
        ev(1, <<"oA">>, 1, {inc, 5}),
        ev(2, <<"oB">>, 1, {inc, 3}),
        ev(3, <<"oA">>, 2, {inc, 2})
    ],
    ?assertEqual(10, ?GC:to_value(?GC:interpret_cog(Events, ?GC:init()))),
    assert_cog_perm_invariant(?GC, Events).

g_counter_roundtrip_and_markers_test() ->
    S = fold(?GC, [{{inc, 7}, k(1, <<"oA">>, 1)}]),
    ?assertEqual(S, ?GC:decode_state(?GC:encode_state(S))),
    markers(?GC, true).

%% =============================================================================
%% pn_counter
%% =============================================================================

pn_counter_value_test() ->
    Pairs = [
        {{inc, 5}, k(1, <<"oA">>, 1)},
        {{inc, -2}, k(2, <<"oB">>, 1)},
        {{inc, 4}, k(3, <<"oA">>, 2)}
    ],
    ?assertEqual(7, ?PN:to_value(fold(?PN, Pairs))).

pn_counter_cog_invariant_and_markers_test() ->
    Events = [
        ev(1, <<"oA">>, 1, {inc, 5}),
        ev(2, <<"oB">>, 1, {inc, -2}),
        ev(3, <<"oA">>, 2, {inc, 4})
    ],
    ?assertEqual(7, ?PN:to_value(?PN:interpret_cog(Events, ?PN:init()))),
    assert_cog_perm_invariant(?PN, Events),
    S = ?PN:interpret_cog(Events, ?PN:init()),
    ?assertEqual(S, ?PN:decode_state(?PN:encode_state(S))),
    markers(?PN, true).

%% =============================================================================
%% g_set
%% =============================================================================

g_set_value_test() ->
    Pairs = [
        {{add, <<"b">>}, k(1, <<"oA">>, 1)},
        {{add, <<"a">>}, k(2, <<"oB">>, 1)},
        {{add, <<"b">>}, k(3, <<"oA">>, 2)}
    ],
    ?assertEqual([<<"a">>, <<"b">>], ?GS:to_value(fold(?GS, Pairs))).

g_set_cog_invariant_and_markers_test() ->
    Events = [
        ev(1, <<"oA">>, 1, {add, <<"b">>}),
        ev(2, <<"oB">>, 1, {add, <<"a">>}),
        ev(3, <<"oA">>, 2, {add, <<"c">>})
    ],
    ?assertEqual(
        [<<"a">>, <<"b">>, <<"c">>],
        ?GS:to_value(?GS:interpret_cog(Events, ?GS:init()))
    ),
    assert_cog_perm_invariant(?GS, Events),
    S = ?GS:interpret_cog(Events, ?GS:init()),
    ?assertEqual(S, ?GS:decode_state(?GS:encode_state(S))),
    markers(?GS, true).

%% =============================================================================
%% max_register / min_register
%% =============================================================================

max_register_value_test() ->
    Pairs = [
        {{set, 5}, k(1, <<"oA">>, 1)},
        {{set, 9}, k(2, <<"oB">>, 1)},
        {{set, 3}, k(3, <<"oA">>, 2)}
    ],
    ?assertEqual(9, ?MAX:to_value(fold(?MAX, Pairs))).

min_register_value_test() ->
    Pairs = [
        {{set, 5}, k(1, <<"oA">>, 1)},
        {{set, 9}, k(2, <<"oB">>, 1)},
        {{set, 3}, k(3, <<"oA">>, 2)}
    ],
    ?assertEqual(3, ?MIN:to_value(fold(?MIN, Pairs))).

max_min_cog_invariant_and_markers_test() ->
    Events = [
        ev(1, <<"oA">>, 1, {set, 5}),
        ev(2, <<"oB">>, 1, {set, 9}),
        ev(3, <<"oA">>, 2, {set, 3})
    ],
    ?assertEqual(9, ?MAX:to_value(?MAX:interpret_cog(Events, ?MAX:init()))),
    ?assertEqual(3, ?MIN:to_value(?MIN:interpret_cog(Events, ?MIN:init()))),
    assert_cog_perm_invariant(?MAX, Events),
    assert_cog_perm_invariant(?MIN, Events),
    SMax = ?MAX:interpret_cog(Events, ?MAX:init()),
    SMin = ?MIN:interpret_cog(Events, ?MIN:init()),
    ?assertEqual(SMax, ?MAX:decode_state(?MAX:encode_state(SMax))),
    ?assertEqual(SMin, ?MIN:decode_state(?MIN:encode_state(SMin))),
    markers(?MAX, true),
    markers(?MIN, true).
