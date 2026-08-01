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
        ?MOD:apply_op(State, {apply, bogus, {inc, 1}}, ev_key(1, <<"a">>, 1), [])
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

ev_key(Hlc, Origin, Seq) ->
    bondy_oplog_event:key(Hlc, Origin, Seq).
