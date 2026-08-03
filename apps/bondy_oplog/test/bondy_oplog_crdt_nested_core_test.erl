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

%% =============================================================================
%% stabilize_fold/2 — causal-stabilization compaction of one PO-Log
%% =============================================================================
%%
%% The license boundary (only dot-stores never partially dropped by an
%% observed context; per-origin only) is the CALLER's obligation — these
%% tests pin the mechanics: per-origin grouping, the stability cut, the
%% representative dot, value preservation, and the opt-in gate.

stabilize_fold_collapses_per_origin_runs_test() ->
    DS = #{
        {<<"a">>, 1} => {sub, ?COUNTER, 10, {inc, 1}},
        {<<"a">>, 2} => {sub, ?COUNTER, 20, {inc, 2}},
        {<<"a">>, 3} => {sub, ?COUNTER, 30, {inc, 3}},
        {<<"b">>, 1} => {sub, ?COUNTER, 15, {inc, 10}},
        {<<"b">>, 2} => {sub, ?COUNTER, 25, {inc, -4}}
    },
    Before = ?M:nested_value(?COUNTER, DS),
    {folded, DS1} = ?M:stabilize_fold(DS, 100),
    %% One synthetic entry per origin, at each run's max dot and max HLC.
    ?assertEqual(
        #{
            {<<"a">>, 3} => {sub, ?COUNTER, 30, {inc, 6}},
            {<<"b">>, 2} => {sub, ?COUNTER, 25, {inc, 6}}
        },
        DS1
    ),
    ?assertEqual(Before, ?M:nested_value(?COUNTER, DS1)).

stabilize_fold_respects_the_stability_cut_test() ->
    DS = #{
        {<<"a">>, 1} => {sub, ?COUNTER, 10, {inc, 1}},
        {<<"a">>, 2} => {sub, ?COUNTER, 20, {inc, 2}},
        {<<"a">>, 3} => {sub, ?COUNTER, 30, {inc, 3}}
    },
    %% Only the entries strictly below the cut fold; the live tail stays.
    {folded, DS1} = ?M:stabilize_fold(DS, 25),
    ?assertEqual(
        #{
            {<<"a">>, 2} => {sub, ?COUNTER, 20, {inc, 3}},
            {<<"a">>, 3} => {sub, ?COUNTER, 30, {inc, 3}}
        },
        DS1
    ),
    ?assertEqual(6, ?M:nested_value(?COUNTER, DS1)).

stabilize_fold_single_entry_runs_unchanged_test() ->
    DS = #{
        {<<"a">>, 1} => {sub, ?COUNTER, 10, {inc, 1}},
        {<<"b">>, 1} => {sub, ?COUNTER, 20, {inc, 2}}
    },
    %% Nothing to compress — a run of one is already minimal.
    ?assertEqual(unchanged, ?M:stabilize_fold(DS, 100)).

stabilize_fold_flat_store_unchanged_test() ->
    Entries = ?M:put(#{}, <<"k">>, {<<"a">>, 1}, [], <<"v">>),
    DS = maps:get(<<"k">>, Entries),
    ?assertEqual(unchanged, ?M:stabilize_fold(DS, 100)).

stabilize_fold_non_opted_sub_mod_unchanged_test() ->
    %% g_counter exports no state_to_op/1 — it has not opted into folding.
    GC = bondy_oplog_crdt_g_counter,
    DS = #{
        {<<"a">>, 1} => {sub, GC, 10, {inc, 1}},
        {<<"a">>, 2} => {sub, GC, 20, {inc, 2}}
    },
    ?assertEqual(unchanged, ?M:stabilize_fold(DS, 100)).

stabilize_fold_lww_keeps_the_winners_own_hlc_test() ->
    LWW = bondy_oplog_crdt_lww_register,
    %% An explicit-HLC set that wins over a later-delivered lower-HLC one.
    DS = #{
        {<<"a">>, 1} => {sub, LWW, 10, {set, 50, <<"winner">>}},
        {<<"a">>, 2} => {sub, LWW, 20, {set, 15, <<"loser">>}}
    },
    ?assertEqual(<<"winner">>, ?M:nested_value(LWW, DS)),
    {folded, DS1} = ?M:stabilize_fold(DS, 100),
    %% The synthetic op carries the WINNER's write HLC in explicit form —
    %% re-stamping from the representative dot would flip the outcome.
    ?assertEqual(
        #{{<<"a">>, 2} => {sub, LWW, 20, {set, 50, <<"winner">>}}},
        DS1
    ),
    ?assertEqual(<<"winner">>, ?M:nested_value(LWW, DS1)).

stabilize_fold_is_idempotent_at_a_cut_test() ->
    DS0 = #{
        {<<"a">>, 1} => {sub, ?COUNTER, 10, {inc, 1}},
        {<<"a">>, 2} => {sub, ?COUNTER, 20, {inc, 2}}
    },
    {folded, DS1} = ?M:stabilize_fold(DS0, 100),
    ?assertEqual(unchanged, ?M:stabilize_fold(DS1, 100)).
