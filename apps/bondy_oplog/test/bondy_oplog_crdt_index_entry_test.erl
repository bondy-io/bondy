%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% `bondy_oplog_crdt_index_entry` is the op-based CRDT backing every
%% secondary-index cell. These tests pin its LWW-over-presence semantics: the
%% highest version wins, the merge converges under any operation order, and
%% the encoding round-trips.

-module(bondy_oplog_crdt_index_entry_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_index_entry).

ops() ->
    [
        {put, <<"colsA">>, 5},
        {remove, 3},
        {put, <<"colsB">>, 8},
        {put, <<"colsB2">>, 8},
        {remove, 8},
        {put, <<"colsC">>, 12}
    ].

%% The final state of the op sequence: `{put, colsC, 12}` is the highest
%% version, so it wins (live, colsC).
final_state_is_highest_version_test() ->
    ?assertEqual({live, <<"colsC">>, 12}, fold_crdt(ops())),
    ?assertEqual(<<"colsC">>, ?CRDT:to_value(fold_crdt(ops()))).

%% LWW commutes: every permutation of the ops yields the same final state.
order_independent_test() ->
    Ops = ops(),
    Final = fold_crdt(Ops),
    [
        ?assertEqual(Final, fold_crdt(P))
     || P <- perms_sample(Ops)
    ].

contract_markers_test() ->
    ?assertEqual(tier_0, ?CRDT:causal_tier()),
    ?assertEqual(true, ?CRDT:value_equals_state()),
    ?assertEqual(true, ?CRDT:order_independent()),
    ?assertEqual({dead, <<>>, 0}, ?CRDT:init()),
    ?assertEqual(undefined, ?CRDT:to_value(?CRDT:init())).

%% Golden wire-format bytes, `<<Rank:8, Version:64/big, ColsSize:32/big,
%% Cols/binary>>` with `rank(live)=1, rank(dead)=0`. A change to them is a
%% new index cell format, which needs a new `?INDEX_FORMAT` in
%% `bondy_oplog_core_registry` so durable indexes rebuild on open.
golden_bytes_test() ->
    ?assertEqual(
        <<1, 7:64/big-unsigned, 2:32/big-unsigned, "xy">>,
        ?CRDT:encode_state({live, <<"xy">>, 7})
    ),
    ?assertEqual(
        <<0, 0:64/big-unsigned, 0:32/big-unsigned>>,
        ?CRDT:encode_state({dead, <<>>, 0})
    ),
    %% And the decode is the exact inverse of those golden bytes.
    ?assertEqual(
        {live, <<"xy">>, 7},
        ?CRDT:decode_state(<<1, 7:64/big-unsigned, 2:32/big-unsigned, "xy">>)
    ).

encode_roundtrips_test() ->
    States = [
        {dead, <<>>, 0},
        {live, <<"x">>, 7},
        {dead, <<>>, 9},
        {live, <<>>, 100}
    ],
    [?assertEqual(S, ?CRDT:decode_state(?CRDT:encode_state(S))) || S <- States].

version_is_max_absorbed_test() ->
    S = fold_crdt([{put, <<"a">>, 4}, {remove, 9}, {put, <<"b">>, 6}]),
    ?assertEqual(9, ?CRDT:hlc(S)),
    %% remove at 9 dominates the put at 6 → tombstone, value undefined.
    ?assertEqual(undefined, ?CRDT:to_value(S)).

%% =============================================================================
%% Helpers
%% =============================================================================

fold_crdt(Ops) ->
    lists:foldl(
        fun(Op, S) -> ?CRDT:apply_op(S, Op, undefined) end, ?CRDT:init(), Ops
    ).

%% A handful of permutations (full permutations of 6 ops is 720 — enough to
%% exercise the commutativity without exhausting).
perms_sample(Ops) ->
    [
        lists:reverse(Ops),
        rotate(Ops, 1),
        rotate(Ops, 3),
        lists:sort(Ops),
        lists:reverse(lists:sort(Ops))
    ].

rotate(L, N) ->
    {A, B} = lists:split(N rem length(L), L),
    B ++ A.
