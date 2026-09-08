%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Unit tests for `bondy_oplog_crdt_struct` — the fixed-schema record CRDT
%% ("ImmutableCRDT"). Convergence under causal delivery is proven by
%% `bondy_oplog_crdt_struct_proper_test`; these pin the mechanical
%% pieces: schema validation, field isolation, and a never-written
%% field's bottom value.

-module(bondy_oplog_crdt_struct_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_struct).
-define(SCHEMA, #{
    count => bondy_oplog_crdt_pn_counter,
    tag => bondy_oplog_crdt_lww_register
}).

apply_op_on_unknown_field_raises_test() ->
    State = ?MOD:init(?SCHEMA),
    ?assertError(
        {badarg, {unknown_field, bogus}},
        ?MOD:apply_op(
            State, {apply, bogus, {inc, 1}}, ev_key(1, <<"a">>, 1), []
        )
    ).

never_written_field_projects_sub_mod_bottom_test() ->
    State = ?MOD:init(?SCHEMA),
    ?assertEqual(#{count => 0, tag => undefined}, ?MOD:to_value(State)).

writes_to_one_field_do_not_affect_another_test() ->
    State0 = ?MOD:init(?SCHEMA),
    State1 = ?MOD:apply_op(
        State0, {apply, count, {inc, 5}}, ev_key(1, <<"a">>, 1), []
    ),
    ?assertEqual(#{count => 5, tag => undefined}, ?MOD:to_value(State1)),
    State2 = ?MOD:apply_op(
        State1, {apply, tag, {set, <<"x">>}}, ev_key(2, <<"a">>, 2), [
            {<<"a">>, 1}
        ]
    ),
    ?assertEqual(#{count => 5, tag => <<"x">>}, ?MOD:to_value(State2)).

encode_decode_roundtrip_test() ->
    State0 = ?MOD:init(?SCHEMA),
    State1 = ?MOD:apply_op(
        State0, {apply, count, {inc, 3}}, ev_key(1, <<"a">>, 1), []
    ),
    ?assertEqual(State1, ?MOD:decode_state(?MOD:encode_state(State1))).

reap_origins_is_value_preserving_test() ->
    State0 = ?MOD:init(?SCHEMA),
    State1 = ?MOD:apply_op(
        State0, {apply, count, {inc, 5}}, ev_key(1, <<"a">>, 1), []
    ),
    Value0 = ?MOD:to_value(State1),
    {State2, Reaped} = ?MOD:reap_origins(State1, [<<"b">>]),
    %% "b" never wrote anything -- nothing to reap, value unchanged.
    ?assertEqual([], Reaped),
    ?assertEqual(Value0, ?MOD:to_value(State2)).

%% =============================================================================
%% stabilize/2 — causal-stabilization folding ({keep, Reduced})
%% =============================================================================

stabilize_folds_stable_field_runs_test() ->
    %% Two origins churning both fields — the registration-RIB shape.
    Ops = [
        {1, <<"a">>, 1, count, {inc, 1}},
        {2, <<"a">>, 2, tag, {set, <<"x">>}},
        {3, <<"b">>, 1, count, {inc, 1}},
        {4, <<"a">>, 3, count, {inc, 1}},
        {5, <<"b">>, 2, count, {inc, -1}},
        {6, <<"a">>, 4, tag, {set, <<"y">>}},
        {7, <<"a">>, 5, count, {inc, -1}}
    ],
    State = lists:foldl(
        fun({H, O, S, F, Op}, Acc) ->
            ?MOD:apply_op(Acc, {apply, F, Op}, ev_key(H, O, S), [])
        end,
        ?MOD:init(?SCHEMA),
        Ops
    ),
    Value = ?MOD:to_value(State),
    ?assertMatch(#{count := 1, tag := <<"y">>}, Value),

    {keep, Reduced} = ?MOD:stabilize(100, State),
    %% Value-preserving, context-preserving, and each field collapsed to
    %% at most one entry per origin.
    ?assertEqual(Value, ?MOD:to_value(Reduced)),
    ?assertEqual(?MOD:context_of(State), ?MOD:context_of(Reduced)),
    {_Schema, Fields, _CC, _Hlc} = Reduced,
    ?assertEqual(2, map_size(maps:get(count, Fields))),
    ?assertEqual(1, map_size(maps:get(tag, Fields))),
    %% The reduced state round-trips through the frame encoding.
    ?assertEqual(Reduced, ?MOD:decode_state(?MOD:encode_state(Reduced))),
    %% And a second pass at the same cut has nothing left to fold.
    ?assertEqual(keep, ?MOD:stabilize(100, Reduced)).

stabilize_fold_then_suffix_equals_full_replay_test() ->
    Prefix = [
        {1, <<"a">>, 1, count, {inc, 2}},
        {2, <<"a">>, 2, count, {inc, 3}},
        {3, <<"b">>, 1, tag, {set, <<"x">>}},
        {4, <<"b">>, 2, tag, {set, <<"y">>}}
    ],
    Suffix = [
        {10, <<"a">>, 3, count, {inc, -1}},
        {11, <<"b">>, 3, tag, {set, <<"z">>}},
        {12, <<"c">>, 1, count, {inc, 7}}
    ],
    Apply = fun(OpList, State0) ->
        lists:foldl(
            fun({H, O, S, F, Op}, Acc) ->
                ?MOD:apply_op(Acc, {apply, F, Op}, ev_key(H, O, S), [])
            end,
            State0,
            OpList
        )
    end,
    Full = Apply(Suffix, Apply(Prefix, ?MOD:init(?SCHEMA))),
    {keep, Folded} = ?MOD:stabilize(5, Apply(Prefix, ?MOD:init(?SCHEMA))),
    Saturated = Apply(Suffix, Folded),
    %% Folding a stable prefix is invisible to everything applied after.
    ?assertEqual(?MOD:to_value(Full), ?MOD:to_value(Saturated)).

stabilize_zero_discard_takes_precedence_over_folding_test() ->
    Schema = #{count => {bondy_oplog_crdt_pn_counter, #{stabilize_zero => 0}}},
    State = lists:foldl(
        fun({H, S, Op}, Acc) ->
            ?MOD:apply_op(Acc, {apply, count, Op}, ev_key(H, <<"a">>, S), [])
        end,
        ?MOD:init(Schema),
        [{1, 1, {inc, 1}}, {2, 2, {inc, 2}}, {3, 3, {inc, -3}}]
    ),
    %% Balanced and stable: the whole cell discards — folding would have
    %% applied, but reclaiming the cell outright is the stronger reduction.
    ?assertEqual(discard, ?MOD:stabilize(100, State)).

stabilize_below_every_op_keeps_test() ->
    State = ?MOD:apply_op(
        ?MOD:init(?SCHEMA), {apply, count, {inc, 1}}, ev_key(10, <<"a">>, 1), []
    ),
    ?assertEqual(keep, ?MOD:stabilize(1, State)).

%% `force_reap => true` is what makes a single-writer cell reclaimable once
%% its writer is permanently gone: the retired origin's contributions are
%% dropped, `count` reaches its `stabilize_zero`, and the cell discards
%% outright. That matters because `bondy_oplog_cell_utils:reap_one_cell/6`
%% re-encodes a VALUE-PRESERVING frame (old value column, shrunk state), so
%% reclamation rests entirely on `stabilize/2` reading the SHRUNK state —
%% this is the test that pins that chain. The whole cell is minted by ONE
%% origin here, which is the single-writer shape of a registry RIB cell.
force_reap_zeroes_the_field_and_discards_the_cell_test() ->
    Schema = #{
        count =>
            {bondy_oplog_crdt_pn_counter, #{
                stabilize_zero => 0, force_reap => true
            }}
    },
    State = counted(Schema, <<"dead">>, 3),
    ?assertEqual(#{count => 3}, ?MOD:to_value(State)),

    {Reaped, Ids} = ?MOD:reap_origins(State, [<<"dead">>]),
    ?assertEqual([<<"dead">>], Ids),
    ?assertEqual(#{count => 0}, ?MOD:to_value(Reaped)),
    ?assertEqual(discard, ?MOD:stabilize(100, Reaped)).

%% The control that makes the above attributable to the policy rather than to
%% reaping in general: the documented conservative default leaves the value of
%% every field WITHOUT `force_reap` untouched, so the cell stays live.
reap_without_force_reap_preserves_the_value_test() ->
    Schema = #{count => {bondy_oplog_crdt_pn_counter, #{stabilize_zero => 0}}},
    State = counted(Schema, <<"dead">>, 3),

    {Reaped, _Ids} = ?MOD:reap_origins(State, [<<"dead">>]),
    ?assertEqual(#{count => 3}, ?MOD:to_value(Reaped)),
    ?assertNotEqual(discard, ?MOD:stabilize(100, Reaped)).

%% @private
%% `N` single-increment ops on `count`, all minted by `Origin`.
counted(Schema, Origin, N) ->
    lists:foldl(
        fun(S, Acc) ->
            ?MOD:apply_op(
                Acc, {apply, count, {inc, 1}}, ev_key(S, Origin, S), []
            )
        end,
        ?MOD:init(Schema),
        lists:seq(1, N)
    ).

ev_key(Hlc, Origin, Seq) ->
    bondy_oplog_event:key(Hlc, Origin, Seq).
