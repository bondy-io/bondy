%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PropEr properties for the multi-value register — the tier_2 ship gate.
%%
%% A command sequence over a few origins (`{write, Origin, Value}` and
%% `{sync, From, To}`) is simulated to produce a list of events, each
%% carrying the causal context (`context_of/1`) its origin observed at
%% write time — exactly as the substrate stamps it. The simulator's
%% `sync` merges two origins' clocks (what an MST sync between replicas
%% achieves), so the generated contexts are well-formed partial
%% observations, not arbitrary noise.
%%
%% The headline property `prop_eager_equals_group` asserts the
%% eager-equals-group invariant: the eager incremental
%% `apply_op/4` fold in ARRIVAL order equals the canonical sorted-group
%% `interpret_cog/2`. Both are `bondy_dvvset:sync` folds of the same
%% fixed per-event contributions, so a lattice join makes them equal
%% regardless of order or duplication.

-module(bondy_oplog_crdt_mv_register_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_mv_register).
-define(ORIGINS, [<<"a">>, <<"b">>, <<"c">>]).
-define(VALUES, [<<"x">>, <<"y">>, <<"z">>, <<"w">>]).
-define(DEFAULT_NUMTESTS, 300).

-export([prop_eager_equals_group/0]).
-export([prop_permutation_invariant/0]).
-export([prop_replica_sync_converges/0]).
-export([prop_encode_state_roundtrip/0]).
-export([prop_idempotent_redelivery/0]).

%% =============================================================================
%% Generators
%% =============================================================================

cmd_gen() ->
    oneof([
        {write, oneof(?ORIGINS), oneof(?VALUES)},
        {sync, oneof(?ORIGINS), oneof(?ORIGINS)}
    ]).

cmds_gen() ->
    list(cmd_gen()).

%% =============================================================================
%% Properties
%% =============================================================================

%% §4.3 ship gate: eager arrival-order fold == sorted-group interpret_cog.
prop_eager_equals_group() ->
    ?FORALL(Cmds, cmds_gen(), begin
        Events = simulate(Cmds),
        Eager = lists:foldl(
            fun(E, S) -> apply_event(S, E) end, ?MOD:init(), Events
        ),
        Group = ?MOD:interpret_cog(Events, ?MOD:init()),
        Eager =:= Group
    end).

%% interpret_cog is invariant under any arrival permutation.
prop_permutation_invariant() ->
    ?FORALL(Cmds, cmds_gen(), begin
        Events = simulate(Cmds),
        Ref = ?MOD:interpret_cog(Events, ?MOD:init()),
        ?FORALL(Perm, shuffle_gen(Events), begin
            ?MOD:interpret_cog(Perm, ?MOD:init()) =:= Ref
        end)
    end).

%% Two replicas each absorb a disjoint partition of the events, then
%% state-sync (the DVV join MST sync achieves): they converge to the same
%% clock and value as a single replica that saw everything.
prop_replica_sync_converges() ->
    ?FORALL(Cmds, cmds_gen(), begin
        Events = simulate(Cmds),
        ?FORALL(Mask, vector(length(Events), boolean()), begin
            {EvsA, EvsB} = partition(Events, Mask),
            {Ca, Ha} = ?MOD:interpret_cog(EvsA, ?MOD:init()),
            {Cb, Hb} = ?MOD:interpret_cog(EvsB, ?MOD:init()),
            Merged = {bondy_dvvset:sync([Ca, Cb]), erlang:max(Ha, Hb)},
            Whole = ?MOD:interpret_cog(Events, ?MOD:init()),
            Merged =:= Whole andalso
                ?MOD:to_value(Merged) =:= ?MOD:to_value(Whole)
        end)
    end).

%% Re-delivering every event a second time changes nothing (idempotent).
prop_idempotent_redelivery() ->
    ?FORALL(Cmds, cmds_gen(), begin
        Events = simulate(Cmds),
        Once = ?MOD:interpret_cog(Events, ?MOD:init()),
        Twice = ?MOD:interpret_cog(Events ++ Events, ?MOD:init()),
        Once =:= Twice
    end).

prop_encode_state_roundtrip() ->
    ?FORALL(Cmds, cmds_gen(), begin
        State = ?MOD:interpret_cog(simulate(Cmds), ?MOD:init()),
        ?MOD:decode_state(?MOD:encode_state(State)) =:= State
    end).

%% =============================================================================
%% Simulation
%% =============================================================================

%% Run the command sequence, returning the ordered list of events each
%% stamped with the context its origin observed. `sync` merges clocks so
%% later writes can observe earlier ones across origins.
simulate(Cmds) ->
    Init = maps:from_list([{O, ?MOD:init()} || O <- ?ORIGINS]),
    {_States, _Seqs, _Hlc, RevEvents} =
        lists:foldl(fun step/2, {Init, #{}, 1, []}, Cmds),
    lists:reverse(RevEvents).

step({write, O, V}, {States, Seqs, Hlc, Evs}) ->
    S = maps:get(O, States),
    Ctx = ?MOD:context_of(S),
    Seq = maps:get(O, Seqs, 0) + 1,
    E = mk_event(Hlc, O, Seq, V, Ctx),
    %% The origin observes its own write (read-your-writes).
    {States#{O => apply_event(S, E)}, Seqs#{O => Seq}, Hlc + 1, [E | Evs]};
step({sync, From, To}, {States, Seqs, Hlc, Evs}) ->
    {Cf, Hf} = maps:get(From, States),
    {Ct, Ht} = maps:get(To, States),
    Merged = {bondy_dvvset:sync([Cf, Ct]), erlang:max(Hf, Ht)},
    {States#{To => Merged}, Seqs, Hlc, Evs}.

%% =============================================================================
%% Helpers
%% =============================================================================

mk_event(Hlc, Origin, Seq, V, Context) ->
    Key = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(Key, {set, V}, Context).

apply_event(State, Event) ->
    ?MOD:apply_op(
        State,
        bondy_oplog_crdt_commutative:op_of(Event),
        bondy_oplog_event:key(Event),
        bondy_oplog_event:meta(Event)
    ).

%% A length-stable shuffle generator: permute the given list.
shuffle_gen(L) ->
    ?LET(Keys, vector(length(L), integer()), begin
        [E || {_, E} <- lists:sort(lists:zip(Keys, L))]
    end).

partition(Events, Mask) ->
    Pairs = lists:zip(Events, Mask),
    {[E || {E, true} <- Pairs], [E || {E, false} <- Pairs]}.

%% =============================================================================
%% EUnit wrapper
%% =============================================================================

properties_test_() ->
    {timeout, 240, fun() ->
        Opts = [{to_file, user}, {numtests, ?DEFAULT_NUMTESTS}],
        Props = [
            prop_eager_equals_group(),
            prop_permutation_invariant(),
            prop_replica_sync_converges(),
            prop_idempotent_redelivery(),
            prop_encode_state_roundtrip()
        ],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, Opts)) end,
            Props
        )
    end}.
