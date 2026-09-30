%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Examples for `bondy_oplog_crdt_owned_reading` that the properties in
%% `bondy_oplog_crdt_owned_reading_proper_test` do not state: the tier, the
%% stabilization boundary, and the carrier as a `bondy_oplog_crdt_struct`
%% field under `force_reap`.

-module(bondy_oplog_crdt_owned_reading_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_owned_reading).
-define(OLD, <<"old-origin">>).
-define(NEW, <<"new-origin">>).
-define(STABLE, (1 bsl 62)).

causal_tier_is_tier_0_test() ->
    %% A dot-based tier makes every write add state until it stabilizes;
    %% see `bondy_oplog_crdt_struct`'s moduledoc.
    ?assertEqual(tier_0, ?MOD:causal_tier()).

bottom_reads_zero_and_has_no_op_test() ->
    ?assertEqual(0, ?MOD:to_value(?MOD:init())),
    ?assertEqual(undefined, ?MOD:state_to_op(?MOD:init())).

a_later_reading_from_a_new_origin_replaces_the_old_one_test() ->
    State = set([{?OLD, 5, 3}, {?NEW, 9, 1}]),
    ?assertEqual(1, ?MOD:to_value(State)).

an_older_reading_arriving_late_is_ignored_test() ->
    State = set([{?NEW, 9, 1}, {?OLD, 5, 3}]),
    ?assertEqual(1, ?MOD:to_value(State)).

stabilize_discards_only_a_stable_zero_test() ->
    Zero = set([{?OLD, 5, 3}, {?NEW, 9, 0}]),
    One = set([{?NEW, 9, 1}]),
    ?assertEqual(discard, ?MOD:stabilize(?STABLE, Zero)),
    ?assertEqual(keep, ?MOD:stabilize(?STABLE, One)),
    ?assertEqual(keep, ?MOD:stabilize(?MOD:hlc(Zero), Zero)).

reaping_the_old_origin_keeps_the_new_reading_test() ->
    State = set([{?OLD, 5, 3}, {?NEW, 9, 1}]),
    {Reaped, Ids} = ?MOD:reap_origins(State, [?OLD]),
    ?assertEqual([?OLD], Ids),
    ?assertEqual(1, ?MOD:to_value(Reaped)).

reaping_every_writer_discards_test() ->
    {Reaped, _} = ?MOD:reap_origins(set([{?OLD, 5, 3}]), [?OLD]),
    ?assertEqual(0, ?MOD:to_value(Reaped)),
    ?assertEqual(discard, ?MOD:stabilize(?STABLE, Reaped)).

struct_field_force_reap_keeps_the_survivor_test() ->
    %% The registration RIB cell's shape: `count` is this carrier, declared
    %% `force_reap`, beside a register field.
    Schema = #{
        count => {?MOD, #{stabilize_zero => 0, force_reap => true}},
        latest => {bondy_oplog_crdt_max_register, #{force_reap => true}}
    },
    S0 = bondy_oplog_crdt_struct:init(Schema),
    Ops = [
        {?OLD, 1, {apply, count, {set, {5, 3}}}},
        {?NEW, 1, {apply, count, {set, {9, 1}}}},
        {?NEW, 2, {apply, latest, {set, 7}}}
    ],
    {S1, _} = lists:foldl(
        fun({O, Seq, Op}, {S, Hlc}) ->
            Key = bondy_oplog_event:key(Hlc, O, Seq),
            {bondy_oplog_crdt_struct:apply_op(S, Op, Key, []), Hlc + 1}
        end,
        {S0, 1},
        Ops
    ),
    ?assertMatch(#{count := 1}, bondy_oplog_crdt_struct:to_value(S1)),
    {S2, [?OLD]} = bondy_oplog_crdt_struct:reap_origins(S1, [?OLD]),
    ?assertMatch(#{count := 1}, bondy_oplog_crdt_struct:to_value(S2)),
    {S3, [?NEW]} = bondy_oplog_crdt_struct:reap_origins(S2, [?NEW]),
    ?assertMatch(#{count := 0}, bondy_oplog_crdt_struct:to_value(S3)),
    ?assertEqual(discard, bondy_oplog_crdt_struct:stabilize(?STABLE, S3)).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% `[{Origin, Stamp, Count}]`, applied in list order with rising HLCs and
%% per-origin seqs.
set(Readings) ->
    {State, _, _} = lists:foldl(
        fun({O, Stamp, Count}, {S, Hlc, Seqs}) ->
            Seq = maps:get(O, Seqs, 0) + 1,
            Key = bondy_oplog_event:key(Hlc, O, Seq),
            {?MOD:apply_op(S, {set, {Stamp, Count}}, Key), Hlc + 1, Seqs#{
                O => Seq
            }}
        end,
        {?MOD:init(), 1, #{}},
        Readings
    ),
    State.
