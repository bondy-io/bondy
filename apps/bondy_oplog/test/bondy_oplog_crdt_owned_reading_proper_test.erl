%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PropEr properties for `bondy_oplog_crdt_owned_reading`.
%%
%% The value oracle is stated independently of the module: the count of the
%% highest `{Stamp, Count}` written, or 0. Every other law is checked against a
%% state built from a write list, so a law that holds only for writes in stamp
%% order, or only for one origin, fails here.

-module(bondy_oplog_crdt_owned_reading_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_owned_reading).
-define(ORIGINS, [<<"a">>, <<"b">>, <<"c">>]).
-define(STABLE, (1 bsl 62)).
-define(DEFAULT_NUMTESTS, 500).

-export([prop_value_is_the_count_of_the_highest_reading/0]).
-export([prop_interpret_is_order_and_duplicate_independent/0]).
-export([prop_state_size_is_independent_of_writes/0]).
-export([prop_encode_state_roundtrip/0]).
-export([prop_reap_equals_building_from_the_survivors/0]).
-export([prop_reap_origins_idempotent/0]).
-export([prop_stabilize_fold_preserves_the_value/0]).

%% =============================================================================
%% Value and convergence
%% =============================================================================

-doc false.
prop_value_is_the_count_of_the_highest_reading() ->
    ?FORALL(
        Writes,
        list(write_gen()),
        ?MOD:to_value(build(Writes)) =:= oracle(Writes)
    ).

-doc false.
prop_interpret_is_order_and_duplicate_independent() ->
    %% The same events, reordered and with some delivered twice, give the
    %% same state through `interpret_cog/2`.
    ?FORALL(
        {Writes, Seed},
        {list(write_gen()), integer()},
        begin
            Events = events(Writes),
            rand:seed(exsss, {Seed, Seed, Seed}),
            Dups = [E || E <- Events, rand:uniform(2) =:= 1],
            Shuffled = shuffle(Events ++ Dups),
            ?MOD:interpret_cog(Events, ?MOD:init()) =:=
                ?MOD:interpret_cog(Shuffled, ?MOD:init())
        end
    ).

-doc false.
prop_state_size_is_independent_of_writes() ->
    %% 8-byte HLC, 4-byte entry count, and per origin a 2-byte length, the
    %% origin bytes and two 8-byte integers.
    ?FORALL(
        Writes,
        list(write_gen()),
        begin
            Origins = lists:usort([O || {O, _, _} <- Writes]),
            Bound = 8 + 4 + lists:sum([2 + byte_size(O) + 16 || O <- Origins]),
            byte_size(?MOD:encode_state(build(Writes))) =:= Bound
        end
    ).

-doc false.
prop_encode_state_roundtrip() ->
    ?FORALL(
        Writes,
        list(write_gen()),
        begin
            State = build(Writes),
            ?MOD:decode_state(?MOD:encode_state(State)) =:= State
        end
    ).

%% =============================================================================
%% Reap
%% =============================================================================

-doc false.
prop_reap_equals_building_from_the_survivors() ->
    %% Reaping leaves exactly what the survivors' writes alone would have
    %% built, and names exactly the retired origins that had written.
    ?FORALL(
        {Writes, Retired},
        {list(write_gen()), list(oneof(?ORIGINS))},
        begin
            {Reaped, Ids} = ?MOD:reap_origins(build(Writes), Retired),
            Survivors = [
                W
             || {O, _, _} = W <- Writes, not lists:member(O, Retired)
            ],
            Wrote = lists:usort([O || {O, _, _} <- Writes]),
            Expected = [O || O <- lists:usort(Retired), lists:member(O, Wrote)],
            Ids =:= Expected andalso
                maps:get(readings, Reaped) =:=
                    maps:get(readings, build(Survivors)) andalso
                ?MOD:to_value(Reaped) =:= oracle(Survivors)
        end
    ).

-doc false.
prop_reap_origins_idempotent() ->
    ?FORALL(
        {Writes, Retired},
        {list(write_gen()), list(oneof(?ORIGINS))},
        begin
            {Once, _} = ?MOD:reap_origins(build(Writes), Retired),
            ?MOD:reap_origins(Once, Retired) =:= {Once, []}
        end
    ).

%% =============================================================================
%% Nested use
%% =============================================================================

-doc false.
prop_stabilize_fold_preserves_the_value() ->
    %% As a `bondy_oplog_crdt_struct` field the carrier's sub-ops sit in a
    %% nested dot store that causal stabilization folds per origin through
    %% `state_to_op/1`. The fold must not change the value, and a later reap
    %% of any origin must see the same value folded or not.
    ?FORALL(
        {Writes, Stable, Retired},
        {list(write_gen()), range(1, 40), list(oneof(?ORIGINS))},
        begin
            DS = dot_store(Writes),
            Folded =
                case bondy_oplog_crdt_nested_core:stabilize_fold(DS, Stable) of
                    {folded, DS1} -> DS1;
                    unchanged -> DS
                end,
            Value = fun(D) ->
                bondy_oplog_crdt_nested_core:nested_value(?MOD, D)
            end,
            Reap = fun(D) ->
                bondy_oplog_crdt_nested_core:force_reap(D, Retired)
            end,
            Value(Folded) =:= Value(DS) andalso
                Value(Reap(Folded)) =:= Value(Reap(DS))
        end
    ).

%% =============================================================================
%% Generators / helpers
%% =============================================================================

write_gen() ->
    {oneof(?ORIGINS), range(0, 20), range(0, 5)}.

oracle([]) ->
    0;
oracle(Writes) ->
    {_Stamp, Count} = lists:max([{S, C} || {_O, S, C} <- Writes]),
    Count.

%% One event per write, with per-origin seqs and an HLC rising in list order.
events(Writes) ->
    {Events, _, _} = lists:foldl(
        fun({Origin, Stamp, Count}, {Acc, Hlc, Seqs}) ->
            Seq = maps:get(Origin, Seqs, 0) + 1,
            Key = bondy_oplog_event:key(Hlc, Origin, Seq),
            Event = bondy_oplog_event:new(
                Key, {set, {Stamp, Count}}, undefined
            ),
            {[Event | Acc], Hlc + 1, Seqs#{Origin => Seq}}
        end,
        {[], 1, #{}},
        Writes
    ),
    lists:reverse(Events).

build(Writes) ->
    lists:foldl(
        fun(E, S) ->
            ?MOD:apply_op(S, bondy_oplog_event:op(E), bondy_oplog_event:key(E))
        end,
        ?MOD:init(),
        events(Writes)
    ).

dot_store(Writes) ->
    maps:from_list([
        {
            {bondy_oplog_event:key_origin(K), bondy_oplog_event:key_seq(K)},
            {sub, ?MOD, bondy_oplog_event:key_hlc(K), bondy_oplog_event:op(E)}
        }
     || E <- events(Writes), K <- [bondy_oplog_event:key(E)]
    ]).

shuffle(L) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), X} || X <- L])].

%% =============================================================================
%% EUnit wrapper
%% =============================================================================

properties_test_() ->
    {timeout, 240, fun() ->
        Opts = [{to_file, user}, {numtests, ?DEFAULT_NUMTESTS}],
        Props = [
            prop_value_is_the_count_of_the_highest_reading(),
            prop_interpret_is_order_and_duplicate_independent(),
            prop_state_size_is_independent_of_writes(),
            prop_encode_state_roundtrip(),
            prop_reap_equals_building_from_the_survivors(),
            prop_reap_origins_idempotent(),
            prop_stabilize_fold_preserves_the_value()
        ],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, Opts)) end,
            Props
        )
    end}.
