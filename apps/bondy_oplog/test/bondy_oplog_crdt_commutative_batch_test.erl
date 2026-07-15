%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Unit tests for the packed-batch expansion in
%% `bondy_oplog_crdt_commutative:apply_op/5` — the single seam that both the
%% eager write path and `interpret_cog/3` route through. Exercised against
%% the add-wins map (`bondy_oplog_crdt_aw_map`) at the pure level (no
%% substrate): a `{batch, Ops}` op folds its inner ops onto the state in
%% list order, all sharing the one event's dot and observed context.

-module(bondy_oplog_crdt_commutative_batch_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_aw_map).
-define(C, bondy_oplog_crdt_commutative).

%% =============================================================================
%% Tests
%% =============================================================================

%% Every inner op of a packed batch shares the one event's dot {Origin, Seq}
%% — the batch is one atomic causal unit. The dot lands per field in each
%% field's own dot-store, so distinct fields do not interfere.
batch_shares_one_dot_test() ->
    E = mk_event(
        1,
        <<"o">>,
        1,
        {batch, [
            {put, <<"k1">>, <<"v1">>},
            {put, <<"k2">>, <<"v2">>}
        ]},
        []
    ),
    {Entries, CC, Hlc} = eager(?MOD:init(), E),
    ?assertEqual(#{{<<"o">>, 1} => <<"v1">>}, maps:get(<<"k1">>, Entries)),
    ?assertEqual(#{{<<"o">>, 1} => <<"v2">>}, maps:get(<<"k2">>, Entries)),
    %% The shared dot is absorbed once into the cell-wide context.
    ?assertEqual([{<<"o">>, 1}], CC),
    ?assertEqual(1, Hlc).

%% The eager arrival-order fold equals the canonical key-sorted
%% interpret_cog over the same log when the log contains a batch event —
%% the §4.3 ship gate, with packing. Here the batch (dot {o,2}, context
%% observing {o,1}) removes the earlier k1 (cross-event causality) while its
%% own put of k2 and rmv of k1 share the dot/context (intra-batch).
batch_eager_equals_group_test() ->
    E1 = mk_event(1, <<"o">>, 1, {put, <<"k1">>, <<"v1">>}, []),
    E2 = mk_event(
        2,
        <<"o">>,
        2,
        {batch, [
            {put, <<"k2">>, <<"v2">>},
            {rmv, <<"k1">>}
        ]},
        [{<<"o">>, 1}]
    ),
    Log = [E1, E2],
    Eager = lists:foldl(fun(E, S) -> eager(S, E) end, ?MOD:init(), Log),
    Group = ?MOD:interpret_cog(Log, ?MOD:init()),
    ?assertEqual(Eager, Group),
    %% k1 removed (the batch observed its dot), k2 present.
    ?assertEqual(#{<<"k2">> => [<<"v2">>]}, ?MOD:to_value(Group)).

%% A put and a remove of the SAME field in one batch share the dot and the
%% pre-batch context, so the remove cannot observe the put: add-wins, the
%% put survives.
batch_atomic_put_rmv_same_field_test() ->
    E = mk_event(
        1,
        <<"o">>,
        1,
        {batch, [
            {put, <<"k">>, <<"v">>},
            {rmv, <<"k">>}
        ]},
        []
    ),
    State = eager(?MOD:init(), E),
    ?assertEqual(#{<<"k">> => [<<"v">>]}, ?MOD:to_value(State)).

%% Re-delivering a batch event a second time changes nothing.
batch_idempotent_redelivery_test() ->
    E = mk_event(
        1,
        <<"o">>,
        1,
        {batch, [
            {put, <<"k1">>, <<"v1">>},
            {put, <<"k2">>, <<"v2">>}
        ]},
        []
    ),
    Once = ?MOD:interpret_cog([E], ?MOD:init()),
    Twice = ?MOD:interpret_cog([E, E], ?MOD:init()),
    ?assertEqual(Once, Twice).

%% Later list-order op wins for repeated writes to the same field within a
%% batch (they share the dot, so the second overwrites the first).
batch_same_field_last_wins_test() ->
    E = mk_event(
        1,
        <<"o">>,
        1,
        {batch, [
            {put, <<"k">>, <<"first">>},
            {put, <<"k">>, <<"second">>}
        ]},
        []
    ),
    State = eager(?MOD:init(), E),
    ?assertEqual(#{<<"k">> => [<<"second">>]}, ?MOD:to_value(State)).

%% The capability marker: the dot-store / grow-set types are batchable; the
%% Seq/HLC-deduping counters and registers are not.
is_batchable_test() ->
    ?assert(?C:is_batchable(bondy_oplog_crdt_aw_map)),
    ?assert(?C:is_batchable(bondy_oplog_crdt_aw_set)),
    ?assert(?C:is_batchable(bondy_oplog_crdt_rw_set)),
    ?assert(?C:is_batchable(bondy_oplog_crdt_two_p_set)),
    ?assert(?C:is_batchable(bondy_oplog_crdt_g_set)),
    ?assert(?C:is_batchable(bondy_oplog_crdt_ew_flag)),
    ?assert(?C:is_batchable(bondy_oplog_crdt_dw_flag)),
    ?assertNot(?C:is_batchable(bondy_oplog_crdt_pn_counter)),
    ?assertNot(?C:is_batchable(bondy_oplog_crdt_g_counter)),
    ?assertNot(?C:is_batchable(bondy_oplog_crdt_lww_register)),
    ?assertNot(?C:is_batchable(bondy_oplog_crdt_mv_register)).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_event(Hlc, Origin, Seq, Op, Context) ->
    Key = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(Key, Op, Context).

%% The eager single-event write step, routed through the commutative helper
%% exactly as the cell kernel does — so the batch op is expanded here too.
eager(State, Event) ->
    ?C:apply_op(
        ?MOD,
        State,
        ?C:op_of(Event),
        bondy_oplog_event:key(Event),
        bondy_oplog_event:meta(Event)
    ).
