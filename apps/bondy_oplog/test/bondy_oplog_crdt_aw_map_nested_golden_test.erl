%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Concrete scenarios for `bondy_oplog_crdt_aw_map`'s nested sub-CRDT
%% support (`{apply, K, SubMod, SubOp}`, added on top of
%% `bondy_oplog_crdt_nested_core`). Unlike the byte-identity golden test
%% (which pins a pre-existing encoding across a refactor), there is no
%% prior encoding to regress against here — this hand-traces the
%% add-wins/observed-remove interaction with a nested key instead, plus
%% the encode/decode round-trip.

-module(bondy_oplog_crdt_aw_map_nested_golden_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_aw_map).
-define(COUNTER, bondy_oplog_crdt_pn_counter).

%% Two origins concurrently `apply` an `inc` to the same nested key
%% ("count"), then one of them removes the key having observed only its
%% own prior write. Add-wins/apply-wins: the concurrent sibling from the
%% other origin survives, so the nested pn_counter's converged value is
%% that surviving contribution alone.
concurrent_apply_then_partial_remove_test() ->
    Log = [
        ev(1, <<"a">>, 1, {apply, <<"count">>, ?COUNTER, {inc, 5}}, []),
        ev(2, <<"b">>, 1, {apply, <<"count">>, ?COUNTER, {inc, 3}}, []),
        ev(3, <<"a">>, 2, {rmv, <<"count">>}, [{<<"a">>, 1}])
    ],
    State = ?MOD:interpret_cog(Log, ?MOD:init()),
    ?assertEqual(#{<<"count">> => 3}, ?MOD:to_value(State)),
    ?assertEqual(State, ?MOD:decode_state(?MOD:encode_state(State))).

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

%% A key removed with a fully-observing context has nothing survive: the
%% nested field's replay sees no sub-ops at all, i.e. the sub-CRDT's own
%% bottom value.
full_remove_leaves_no_trace_test() ->
    Log = [
        ev(1, <<"a">>, 1, {apply, <<"count">>, ?COUNTER, {inc, 5}}, []),
        ev(2, <<"a">>, 2, {rmv, <<"count">>}, [{<<"a">>, 1}])
    ],
    State = ?MOD:interpret_cog(Log, ?MOD:init()),
    ?assertEqual(#{}, ?MOD:to_value(State)).

ev(Hlc, Origin, Seq, Op, Ctx) ->
    Key = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(Key, Op, Ctx).
