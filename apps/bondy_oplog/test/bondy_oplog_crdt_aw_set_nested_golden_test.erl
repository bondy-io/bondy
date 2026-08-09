%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Concrete scenarios for `bondy_oplog_crdt_aw_set`'s CRDT-valued-element
%% support (`{apply, E, SubMod, SubOp}`), mirroring
%% `bondy_oplog_crdt_aw_map_nested_golden_test.erl`.

-module(bondy_oplog_crdt_aw_set_nested_golden_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_aw_set).
-define(COUNTER, bondy_oplog_crdt_pn_counter).

%% A plain element and a nested element coexist; to_value/1 switches to
%% the map shape once any element is nested.
plain_and_nested_elements_coexist_test() ->
    Log = [
        ev(1, <<"a">>, 1, {add, <<"x">>}, []),
        ev(2, <<"a">>, 2, {apply, <<"count">>, ?COUNTER, {inc, 4}}, [
            {<<"a">>, 1}
        ])
    ],
    State = ?MOD:interpret_cog(Log, ?MOD:init()),
    ?assertEqual(
        #{<<"x">> => true, <<"count">> => 4}, ?MOD:to_value(State)
    ),
    ?assertEqual(State, ?MOD:decode_state(?MOD:encode_state(State))).

%% With no nested element, to_value/1 answers a plain sorted list.
no_nested_elements_keeps_list_shape_test() ->
    Log = [
        ev(1, <<"a">>, 1, {add, <<"x">>}, []),
        ev(2, <<"b">>, 1, {add, <<"y">>}, [])
    ],
    State = ?MOD:interpret_cog(Log, ?MOD:init()),
    ?assertEqual([<<"x">>, <<"y">>], ?MOD:to_value(State)).

%% Concurrent applies to the same nested element both survive as
%% siblings; the sub-CRDT replay combines them (apply-wins, like
%% aw_map's put-wins).
concurrent_applies_survive_test() ->
    Log = [
        ev(1, <<"a">>, 1, {apply, <<"count">>, ?COUNTER, {inc, 5}}, []),
        ev(2, <<"b">>, 1, {apply, <<"count">>, ?COUNTER, {inc, 3}}, [])
    ],
    State = ?MOD:interpret_cog(Log, ?MOD:init()),
    ?assertEqual(#{<<"count">> => 8}, ?MOD:to_value(State)).

ev(Hlc, Origin, Seq, Op, Ctx) ->
    Key = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(Key, Op, Ctx).
