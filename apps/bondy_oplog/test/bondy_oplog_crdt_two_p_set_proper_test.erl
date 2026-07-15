%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PropEr properties for the Two-Phase Set (2P-Set), a tier_0
%% operation-based CRDT.
%%
%% A command sequence over a few origins (`{add,O,E}`, `{rmv,O,E}`) is
%% turned into an HLC-increasing, per-origin-sequenced event log. Because
%% 2P-Set is tier_0 (commutative, no causal context), the convergence
%% properties reduce to: `interpret_cog` is a deterministic set function
%% of the event set, the eager `apply_op` fold agrees with it under any
%% order, redelivery is idempotent, and the value matches the 2P-Set
%% oracle `AllAdded \ AllRemoved` (so a removed element can never reappear).

-module(bondy_oplog_crdt_two_p_set_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_two_p_set).
-define(ORIGINS, [<<"a">>, <<"b">>, <<"c">>]).
-define(ELEMS, [<<"x">>, <<"y">>, <<"z">>]).
-define(DEFAULT_NUMTESTS, 300).

-export([prop_eager_equals_group/0]).
-export([prop_permutation_invariant/0]).
-export([prop_idempotent_redelivery/0]).
-export([prop_encode_state_roundtrip/0]).
-export([prop_two_p_set_oracle/0]).

%% =============================================================================
%% Generators
%% =============================================================================

cmd_gen() ->
    oneof([
        {add, oneof(?ORIGINS), oneof(?ELEMS)},
        {rmv, oneof(?ORIGINS), oneof(?ELEMS)}
    ]).

cmds_gen() ->
    list(cmd_gen()).

%% =============================================================================
%% Properties
%% =============================================================================

%% The eager left-fold of `apply_op/3` over the log (arrival order) equals
%% the canonical key-sorted `interpret_cog/2`. tier_0 commutativity.
prop_eager_equals_group() ->
    ?FORALL(Cmds, cmds_gen(), begin
        Log = build_log(Cmds),
        Eager = lists:foldl(fun apply_event/2, ?MOD:init(), Log),
        Eager =:= ?MOD:interpret_cog(Log, ?MOD:init())
    end).

%% interpret_cog is invariant under any arrival permutation of the log.
prop_permutation_invariant() ->
    ?FORALL(Cmds, cmds_gen(), begin
        Log = build_log(Cmds),
        Ref = ?MOD:interpret_cog(Log, ?MOD:init()),
        ?FORALL(Perm, shuffle_gen(Log), begin
            ?MOD:interpret_cog(Perm, ?MOD:init()) =:= Ref
        end)
    end).

%% Re-delivering every event a second time changes nothing.
prop_idempotent_redelivery() ->
    ?FORALL(Cmds, cmds_gen(), begin
        Log = build_log(Cmds),
        Once = ?MOD:interpret_cog(Log, ?MOD:init()),
        Twice = ?MOD:interpret_cog(Log ++ Log, ?MOD:init()),
        Once =:= Twice
    end).

prop_encode_state_roundtrip() ->
    ?FORALL(Cmds, cmds_gen(), begin
        Log = build_log(Cmds),
        State = ?MOD:interpret_cog(Log, ?MOD:init()),
        ?MOD:decode_state(?MOD:encode_state(State)) =:= State
    end).

%% The 2P-Set semantic oracle: the value is exactly the set of elements
%% added at least once minus the set of elements removed at least once —
%% so any element that was ever removed is absent for good.
prop_two_p_set_oracle() ->
    ?FORALL(Cmds, cmds_gen(), begin
        Log = build_log(Cmds),
        State = ?MOD:interpret_cog(Log, ?MOD:init()),
        AllAdded = ordsets:from_list([E || {add, _O, E} <- Cmds]),
        AllRemoved = ordsets:from_list([E || {rmv, _O, E} <- Cmds]),
        Expected = ordsets:subtract(AllAdded, AllRemoved),
        ?MOD:to_value(State) =:= Expected
    end).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Build an HLC-increasing, per-origin-sequenced event log from the
%% commands. tier_0: events carry no causal context (`undefined` meta).
build_log(Cmds) ->
    {Log, _H, _Seqs} = lists:foldl(
        fun({Tag, O, E}, {Acc, H, Seqs}) ->
            Seq = maps:get(O, Seqs, 0) + 1,
            Ev = mk_event(H, O, Seq, {Tag, E}),
            {[Ev | Acc], H + 1, Seqs#{O => Seq}}
        end,
        {[], 1, #{}},
        Cmds
    ),
    lists:reverse(Log).

mk_event(Hlc, Origin, Seq, Op) ->
    Key = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(Key, Op, undefined).

apply_event(Event, State) ->
    ?MOD:apply_op(
        State,
        bondy_oplog_crdt_commutative:op_of(Event),
        bondy_oplog_event:key(Event)
    ).

%% A length-stable shuffle generator: permute the given list.
shuffle_gen(L) ->
    ?LET(Keys, vector(length(L), integer()), begin
        [E || {_, E} <- lists:sort(lists:zip(Keys, L))]
    end).

%% =============================================================================
%% EUnit wrapper
%% =============================================================================

properties_test_() ->
    {timeout, 240, fun() ->
        Opts = [{to_file, user}, {numtests, ?DEFAULT_NUMTESTS}],
        Props = [
            prop_eager_equals_group(),
            prop_permutation_invariant(),
            prop_idempotent_redelivery(),
            prop_encode_state_roundtrip(),
            prop_two_p_set_oracle()
        ],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, Opts)) end,
            Props
        )
    end}.
