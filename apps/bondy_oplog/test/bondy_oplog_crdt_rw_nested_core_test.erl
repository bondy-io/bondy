%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Unit tests for `bondy_oplog_crdt_rw_nested_core` — the two-level
%% remove-wins-with-nesting engine `bondy_oplog_crdt_rw_map` builds on,
%% mirroring `bondy_oplog_crdt_nested_core_test`. Convergence under causal
%% delivery is proven by `bondy_oplog_crdt_rw_map_proper_test`; these pin
%% the mechanical pieces, plus the one place remove-wins genuinely
%% differs from add-wins: `rmv/3` needs only a dot, not a context (see
%% `bondy_oplog_crdt_rw_core`'s moduledoc).

-module(bondy_oplog_crdt_rw_nested_core_test).

-include_lib("eunit/include/eunit.hrl").

-define(M, bondy_oplog_crdt_rw_nested_core).
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

%% =============================================================================
%% nested_value/2 and remove-wins pruning
%% =============================================================================

nested_value_replays_surviving_sub_ops_test() ->
    Entries0 = ?M:put_nested(#{}, <<"k">>, {<<"a">>, 1}, [], ?COUNTER, 1, {
        inc, 5
    }),
    Entries1 = ?M:put_nested(
        Entries0, <<"k">>, {<<"b">>, 1}, [], ?COUNTER, 2, {
            inc, 3
        }
    ),
    Cell = maps:get(<<"k">>, Entries1),
    ?assertEqual(8, ?M:nested_value(?COUNTER, Cell)).

%% Remove-wins: an apply concurrent with a remove is discarded even though
%% the remove never observed it -- the causal dual of aw's "concurrent
%% survives". The cell itself persists in Entries (it carries the remove
%% frontier for future comparisons, exactly like `bondy_oplog_crdt_rw_set`
%% keeps a phantom per-element cell) even though it has no surviving add.
concurrent_apply_beaten_by_remove_test() ->
    Entries0 = ?M:put_nested(#{}, <<"k">>, {<<"a">>, 1}, [], ?COUNTER, 1, {
        inc, 5
    }),
    %% b's remove does not observe a's apply (concurrent, empty context) --
    %% remove-wins still beats it because a's apply does not dominate the
    %% new remove frontier.
    Entries1 = ?M:rmv(Entries0, <<"k">>, {<<"b">>, 1}),
    ?assert(maps:is_key(<<"k">>, Entries1)),
    Cell = maps:get(<<"k">>, Entries1),
    ?assertNot(bondy_oplog_crdt_rw_core:present(Cell)),
    ?assertEqual(0, ?M:nested_value(?COUNTER, Cell)).

%% An apply whose context observed the remove (re-add after remove)
%% survives.
apply_observing_the_remove_survives_test() ->
    Entries0 = ?M:put_nested(#{}, <<"k">>, {<<"a">>, 1}, [], ?COUNTER, 1, {
        inc, 5
    }),
    Entries1 = ?M:rmv(Entries0, <<"k">>, {<<"b">>, 1}),
    %% c's apply observed b's remove dot.
    Entries2 = ?M:put_nested(
        Entries1, <<"k">>, {<<"c">>, 1}, [{<<"b">>, 1}], ?COUNTER, 3, {
            inc, 7
        }
    ),
    Cell = maps:get(<<"k">>, Entries2),
    ?assertEqual(7, ?M:nested_value(?COUNTER, Cell)).

%% A remove on a key that was never added still leaves a phantom cell
%% behind (empty adds, non-empty remove frontier) -- needed to correctly
%% beat a later-arriving but causally-stale add.
rmv_on_absent_key_leaves_a_phantom_cell_test() ->
    Entries = ?M:rmv(#{}, <<"k">>, {<<"a">>, 1}),
    ?assert(maps:is_key(<<"k">>, Entries)),
    Cell = maps:get(<<"k">>, Entries),
    ?assertNot(bondy_oplog_crdt_rw_core:present(Cell)).

sub_mod_of_absent_cell_is_undefined_test() ->
    ?assertEqual(undefined, ?M:sub_mod(bondy_oplog_crdt_rw_core:new())).
