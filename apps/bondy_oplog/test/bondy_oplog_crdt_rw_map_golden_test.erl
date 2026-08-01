%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Concrete scenarios for `bondy_oplog_crdt_rw_map` — the remove-wins
%% dual of `bondy_oplog_crdt_aw_map_nested_golden_test`. Same structure,
%% opposite outcome on the concurrent case: here the remove wins.

-module(bondy_oplog_crdt_rw_map_golden_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_rw_map).
-define(COUNTER, bondy_oplog_crdt_pn_counter).

%% A remove concurrent with an apply on the same nested key beats it --
%% remove-wins, the opposite outcome from aw_map's add-wins golden test.
concurrent_apply_beaten_by_remove_test() ->
    Log = [
        ev(1, <<"a">>, 1, {apply, <<"count">>, ?COUNTER, {inc, 5}}, []),
        ev(2, <<"b">>, 1, {rmv, <<"count">>}, [])
    ],
    State = ?MOD:interpret_cog(Log, ?MOD:init()),
    ?assertEqual(#{}, ?MOD:to_value(State)),
    ?assertEqual(State, ?MOD:decode_state(?MOD:encode_state(State))).

%% An apply that causally observed the remove (a re-add after remove)
%% survives.
apply_observing_the_remove_survives_test() ->
    Log = [
        ev(1, <<"a">>, 1, {apply, <<"count">>, ?COUNTER, {inc, 5}}, []),
        ev(2, <<"b">>, 1, {rmv, <<"count">>}, []),
        ev(3, <<"c">>, 1, {apply, <<"count">>, ?COUNTER, {inc, 7}}, [
            {<<"b">>, 1}
        ])
    ],
    State = ?MOD:interpret_cog(Log, ?MOD:init()),
    ?assertEqual(#{<<"count">> => 7}, ?MOD:to_value(State)).

%% A flat key and a nested key coexist in the same cell without
%% interfering with one another.
mixed_flat_and_nested_keys_test() ->
    Log = [
        ev(1, <<"a">>, 1, {put, <<"label">>, <<"fleet-1">>}, []),
        ev(2, <<"a">>, 2, {apply, <<"count">>, ?COUNTER, {inc, 2}}, [
            {<<"a">>, 1}
        ])
    ],
    State = ?MOD:interpret_cog(Log, ?MOD:init()),
    ?assertEqual(
        #{<<"label">> => [<<"fleet-1">>], <<"count">> => 2},
        ?MOD:to_value(State)
    ),
    ?assertEqual(State, ?MOD:decode_state(?MOD:encode_state(State))).

ev(Hlc, Origin, Seq, Op, Ctx) ->
    Key = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(Key, Op, Ctx).
