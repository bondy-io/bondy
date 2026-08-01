%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Unit tests for `bondy_oplog_crdt_nested_core` — the two-level
%% add-wins-with-nesting engine shared by `bondy_oplog_crdt_aw_map` and
%% `bondy_oplog_crdt_aw_set`. Exercised directly at the `entries()` level
%% (no cell-wide context/HLC bookkeeping, which is each consumer's own
%% job); convergence under causal delivery is proven end-to-end via the
%% consumers' own PropEr suites (`bondy_oplog_crdt_aw_map_proper_test`,
%% `bondy_oplog_crdt_aw_set_proper_test`), since this module has no
%% independent behaviour beyond what `put/5`, `put_nested/7`, and `rmv/3`
%% do. These tests pin the mechanical pieces: the type-consistency
%% guards, the dot-store pruning, and the sub-CRDT replay.

-module(bondy_oplog_crdt_nested_core_test).

-include_lib("eunit/include/eunit.hrl").

-define(M, bondy_oplog_crdt_nested_core).
-define(COUNTER, bondy_oplog_crdt_pn_counter).

%% =============================================================================
%% Type consistency
%% =============================================================================

put_nested_onto_flat_key_raises_test() ->
    Entries0 = ?M:put(#{}, <<"k">>, {<<"a">>, 1}, [], <<"v">>),
    ?assertError(
        {badarg, {flat_key, <<"k">>}},
        ?M:put_nested(
            Entries0, <<"k">>, {<<"a">>, 2}, [], ?COUNTER, 2, {inc, 1}
        )
    ).

put_flat_onto_nested_key_raises_test() ->
    Entries0 = ?M:put_nested(#{}, <<"k">>, {<<"a">>, 1}, [], ?COUNTER, 1, {
        inc, 1
    }),
    ?assertError(
        {badarg, {nested_key, <<"k">>}},
        ?M:put(Entries0, <<"k">>, {<<"a">>, 2}, [], <<"v">>)
    ).

put_nested_sub_mod_mismatch_raises_test() ->
    Entries0 = ?M:put_nested(#{}, <<"k">>, {<<"a">>, 1}, [], ?COUNTER, 1, {
        inc, 1
    }),
    ?assertError(
        {badarg, {sub_mod_mismatch, <<"k">>, ?COUNTER, other_sub_mod}},
        ?M:put_nested(
            Entries0, <<"k">>, {<<"b">>, 1}, [], other_sub_mod, 2, some_op
        )
    ).

put_nested_same_sub_mod_twice_is_fine_test() ->
    Entries0 = ?M:put_nested(#{}, <<"k">>, {<<"a">>, 1}, [], ?COUNTER, 1, {
        inc, 1
    }),
    Entries1 = ?M:put_nested(
        Entries0, <<"k">>, {<<"b">>, 1}, [], ?COUNTER, 2, {
            inc, 2
        }
    ),
    ?assertEqual(?COUNTER, ?M:sub_mod(maps:get(<<"k">>, Entries1))).

%% =============================================================================
%% sub_mod/1
%% =============================================================================

sub_mod_of_empty_dot_store_is_undefined_test() ->
    ?assertEqual(undefined, ?M:sub_mod(#{})).

sub_mod_of_flat_dot_store_is_undefined_test() ->
    Entries = ?M:put(#{}, <<"k">>, {<<"a">>, 1}, [], <<"v">>),
    ?assertEqual(undefined, ?M:sub_mod(maps:get(<<"k">>, Entries))).

%% =============================================================================
%% nested_value/2
%% =============================================================================

nested_value_on_empty_dot_store_is_sub_mod_bottom_test() ->
    ?assertEqual(0, ?M:nested_value(?COUNTER, #{})).

nested_value_replays_surviving_sub_ops_test() ->
    Entries0 = ?M:put_nested(#{}, <<"k">>, {<<"a">>, 1}, [], ?COUNTER, 1, {
        inc, 5
    }),
    Entries1 = ?M:put_nested(
        Entries0, <<"k">>, {<<"b">>, 1}, [], ?COUNTER, 2, {
            inc, 3
        }
    ),
    DS = maps:get(<<"k">>, Entries1),
    ?assertEqual(8, ?M:nested_value(?COUNTER, DS)).

%% =============================================================================
%% rmv/3
%% =============================================================================

rmv_prunes_only_observed_dots_test() ->
    Entries0 = ?M:put_nested(#{}, <<"k">>, {<<"a">>, 1}, [], ?COUNTER, 1, {
        inc, 5
    }),
    Entries1 = ?M:put_nested(
        Entries0, <<"k">>, {<<"b">>, 1}, [], ?COUNTER, 2, {
            inc, 3
        }
    ),
    %% Remove observing only a's dot -- b's concurrent apply survives.
    Entries2 = ?M:rmv(Entries1, <<"k">>, [{<<"a">>, 1}]),
    DS = maps:get(<<"k">>, Entries2),
    ?assertEqual(3, ?M:nested_value(?COUNTER, DS)).

rmv_drops_key_when_dot_store_empties_test() ->
    Entries0 = ?M:put(#{}, <<"k">>, {<<"a">>, 1}, [], <<"v">>),
    Entries1 = ?M:rmv(Entries0, <<"k">>, [{<<"a">>, 1}]),
    ?assertNot(maps:is_key(<<"k">>, Entries1)).

rmv_on_absent_key_is_a_noop_test() ->
    ?assertEqual(#{}, ?M:rmv(#{}, <<"k">>, [])).

%% =============================================================================
%% put/5 flat pruning (bounds growth from repeated sequential writes)
%% =============================================================================

put_prunes_writers_own_observed_dot_test() ->
    Entries0 = ?M:put(#{}, <<"k">>, {<<"a">>, 1}, [], <<"v1">>),
    %% A second write from the same origin, observing its own prior dot.
    Entries1 = ?M:put(
        Entries0, <<"k">>, {<<"a">>, 2}, [{<<"a">>, 1}], <<"v2">>
    ),
    ?assertEqual(#{{<<"a">>, 2} => <<"v2">>}, maps:get(<<"k">>, Entries1)).
