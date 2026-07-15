%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Tests for the native operation-based LWW register
%% (`bondy_oplog_crdt_lww_register`): correct LWW semantics, and the
%% commutativity claim (`order_independent() -> true`) validated
%% empirically — every permutation of an event set yields the same state.

-module(bondy_oplog_crdt_lww_register_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_lww_register).

%% =============================================================================
%% Helpers
%% =============================================================================

ek(H, O, S) ->
    bondy_oplog_event:key(H, O, S).

ev(H, O, S, Op) ->
    bondy_oplog_event:new(ek(H, O, S), Op, #{}).

perms([]) ->
    [[]];
perms(L) ->
    [[X | P] || X <- L, P <- perms(L -- [X])].

%% =============================================================================
%% Semantics
%% =============================================================================

init_is_undefined_test() ->
    ?assertEqual(undefined, ?CRDT:init()),
    ?assertEqual(undefined, ?CRDT:to_value(?CRDT:init())).

highest_hlc_wins_test() ->
    Es = [
        ev(10, <<"n1">>, 1, {set, 10, <<"a">>}),
        ev(30, <<"n2">>, 1, {set, 30, <<"c">>}),
        ev(20, <<"n1">>, 2, {set, 20, <<"b">>})
    ],
    S = ?CRDT:interpret_cog(Es, ?CRDT:init()),
    ?assertEqual(<<"c">>, ?CRDT:to_value(S)),
    ?assertEqual(30, ?CRDT:hlc(S)).

clear_then_higher_set_resurrects_test() ->
    Es = [
        ev(10, <<"n1">>, 1, {set, 10, <<"v1">>}),
        ev(20, <<"n1">>, 2, {clear, 20}),
        ev(30, <<"n2">>, 1, {set, 30, <<"v2">>})
    ],
    S = ?CRDT:interpret_cog(Es, ?CRDT:init()),
    ?assertEqual(<<"v2">>, ?CRDT:to_value(S)).

clear_wins_at_tie_test() ->
    Es = [
        ev(10, <<"n1">>, 1, {set, 50, <<"v">>}),
        ev(20, <<"n2">>, 1, {clear, 50})
    ],
    S = ?CRDT:interpret_cog(Es, ?CRDT:init()),
    ?assertEqual(undefined, ?CRDT:to_value(S)).

%% =============================================================================
%% Commutativity (the order_independent claim, validated empirically)
%% =============================================================================

order_independent_over_all_permutations_test() ->
    ?assert(?CRDT:order_independent()),
    Es = [
        ev(30, <<"n2">>, 1, {set, 30, <<"c">>}),
        ev(10, <<"n1">>, 1, {set, 10, <<"a">>}),
        ev(20, <<"n1">>, 2, {clear, 20}),
        ev(40, <<"n3">>, 1, {set, 40, <<"d">>})
    ],
    Init = ?CRDT:init(),
    [First | Rest] = [?CRDT:interpret_cog(P, Init) || P <- perms(Es)],
    ?assert(lists:all(fun(R) -> R =:= First end, Rest)),
    ?assertEqual(<<"d">>, ?CRDT:to_value(First)).

tie_payload_resolution_is_deterministic_test() ->
    %% Two concurrent set at the same HLC: the lexicographically larger
    %% payload wins, regardless of order.
    A = ev(10, <<"n1">>, 1, {set, 99, <<"aaa">>}),
    B = ev(20, <<"n2">>, 1, {set, 99, <<"bbb">>}),
    S1 = ?CRDT:interpret_cog([A, B], ?CRDT:init()),
    S2 = ?CRDT:interpret_cog([B, A], ?CRDT:init()),
    ?assertEqual(S1, S2),
    ?assertEqual(<<"bbb">>, ?CRDT:to_value(S1)).

%% =============================================================================
%% Markers + round trips
%% =============================================================================

markers_test() ->
    ?assertEqual(tier_0, ?CRDT:causal_tier()),
    ?assert(?CRDT:order_independent()),
    ?assertNot(?CRDT:value_equals_state()).

gc_threshold_tracks_hlc_test() ->
    S = ?CRDT:interpret_cog(
        [ev(77, <<"n1">>, 1, {set, 77, <<"v">>})], ?CRDT:init()
    ),
    ?assertEqual(77, ?CRDT:gc_threshold(S)),
    ?assertEqual(undefined, ?CRDT:gc_threshold(?CRDT:init())).

encode_decode_roundtrip_test() ->
    States = [
        ?CRDT:init(),
        {set, <<"hello">>, 42},
        {cleared, 99}
    ],
    lists:foreach(
        fun(S) ->
            ?assertEqual(S, ?CRDT:decode_state(?CRDT:encode_state(S)))
        end,
        States
    ).
