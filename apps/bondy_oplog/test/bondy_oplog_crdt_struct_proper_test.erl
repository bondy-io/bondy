%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PropEr properties for `bondy_oplog_crdt_struct` — the fixed-schema
%% record CRDT ("ImmutableCRDT"), the ship gate mirroring
%% `bondy_oplog_crdt_aw_map_proper_test`/`bondy_oplog_crdt_aw_set_proper_test`.
%%
%% `bondy_oplog_crdt_struct` is a toolkit, not a `bondy_oplog_crdt`
%% implementation in its own right (its `init/1` takes the schema, unlike
%% the behaviour's arity-0 `init/0` — see its moduledoc), so there is no
%% concrete module to drive through `bondy_oplog_crdt_commutative`
%% directly. This suite plays that role itself: a fixed two-field test
%% schema (`count` => `pn_counter`, `tag` => `lww_register`), and a local
%% `group_interpret/2` that sorts by key and folds `apply_op/4` exactly as
%% `bondy_oplog_crdt_commutative:interpret_cog/3` would for a concrete
%% consumer module.

-module(bondy_oplog_crdt_struct_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_struct).
-define(ORIGINS, [<<"a">>, <<"b">>, <<"c">>]).
-define(DELTAS, [-2, -1, 1, 2]).
-define(TAGS, [<<"x">>, <<"y">>, <<"z">>]).
-define(SCHEMA, #{
    count => bondy_oplog_crdt_pn_counter,
    tag => bondy_oplog_crdt_lww_register
}).
-define(DEFAULT_NUMTESTS, 300).

-export([prop_per_replica_eager_equals_group/0]).
-export([prop_full_sync_converges/0]).
-export([prop_permutation_invariant/0]).
-export([prop_idempotent_redelivery/0]).
-export([prop_encode_state_roundtrip/0]).
-export([prop_counter_field_oracle/0]).
-export([prop_stabilize_fold_transparent/0]).

%% =============================================================================
%% Generators
%% =============================================================================

cmd_gen() ->
    oneof([
        {apply, oneof(?ORIGINS), count, {inc, oneof(?DELTAS)}},
        {apply, oneof(?ORIGINS), tag, {set, oneof(?TAGS)}},
        {sync, oneof(?ORIGINS), oneof(?ORIGINS)}
    ]).

cmds_gen() ->
    list(cmd_gen()).

%% =============================================================================
%% Properties
%% =============================================================================

prop_per_replica_eager_equals_group() ->
    ?FORALL(Cmds, cmds_gen(), begin
        {PerOrigin, _Log} = simulate(Cmds),
        lists:all(
            fun({_O, State, Delivered}) ->
                State =:= group_interpret(Delivered, init())
            end,
            PerOrigin
        )
    end).

prop_full_sync_converges() ->
    ?FORALL(Cmds, cmds_gen(), begin
        {PerOrigin, Log} = simulate(Cmds),
        Target = group_interpret(Log, init()),
        lists:all(
            fun({_O, State, Delivered}) ->
                Remaining = [E || E <- Log, not lists:member(E, Delivered)],
                Saturated = lists:foldl(
                    fun(E, S) -> apply_event(E, S) end,
                    State,
                    sort_by_key(Remaining)
                ),
                Saturated =:= Target
            end,
            PerOrigin
        )
    end).

prop_permutation_invariant() ->
    ?FORALL(Cmds, cmds_gen(), begin
        {_PerOrigin, Log} = simulate(Cmds),
        Ref = group_interpret(Log, init()),
        ?FORALL(Perm, shuffle_gen(Log), begin
            group_interpret(Perm, init()) =:= Ref
        end)
    end).

prop_idempotent_redelivery() ->
    ?FORALL(Cmds, cmds_gen(), begin
        {_PerOrigin, Log} = simulate(Cmds),
        Once = group_interpret(Log, init()),
        Twice = group_interpret(Log ++ Log, init()),
        Once =:= Twice
    end).

prop_encode_state_roundtrip() ->
    ?FORALL(Cmds, cmds_gen(), begin
        {_PerOrigin, Log} = simulate(Cmds),
        State = group_interpret(Log, init()),
        ?MOD:decode_state(?MOD:encode_state(State)) =:= State
    end).

%% The `count` field's converged value must equal the sum of every
%% {inc,N} delta ever applied to it, independent of how many origins
%% contributed or how much sequential same-origin churn there was — a
%% semantic-correctness check, not just internal consistency. This is
%% what would have caught a real bug
%% (`bondy_oplog_crdt_nested_core:put_nested/7` incorrectly pruning a
%% writer's own prior nested sub-op, silently dropping sequential
%% same-origin increments) that shipped past every property above.
prop_counter_field_oracle() ->
    ?FORALL(Cmds, cmds_gen(), begin
        {_PerOrigin, Log} = simulate(Cmds),
        State = group_interpret(Log, init()),
        #{count := Count} = ?MOD:to_value(State),
        Deltas = [
            N
         || Ev <- Log,
            {apply, count, {inc, N}} <- [bondy_oplog_event:op(Ev)]
        ],
        Count =:= lists:sum(Deltas)
    end).

%% Causal-stabilization folding (`stabilize/2` -> `{keep, Reduced}`,
%% via `bondy_oplog_crdt_nested_core:stabilize_fold/2`) is transparent:
%% at ANY stability cut, on any replica, the folded state (a) projects
%% the same value, (b) round-trips the frame encoding, and (c) after
%% delivering every event the replica had not yet seen, converges to the
%% same value as the never-folded full fold. This is the R2 soundness
%% claim for the struct shape (no put/rmv, so no context ever partially
%% drops a field's dot-store — see the license boundary in
%% `bondy_oplog_crdt_nested_core`'s moduledoc).
prop_stabilize_fold_transparent() ->
    ?FORALL({Cmds, Cut}, {cmds_gen(), choose(0, 60)}, begin
        {PerOrigin, Log} = simulate(Cmds),
        Target = ?MOD:to_value(group_interpret(Log, init())),
        lists:all(
            fun({_O, State, Delivered}) ->
                case ?MOD:stabilize(Cut, State) of
                    keep ->
                        true;
                    {keep, Folded} ->
                        Remaining = sort_by_key([
                            E
                         || E <- Log, not lists:member(E, Delivered)
                        ]),
                        Saturated = lists:foldl(
                            fun apply_event/2, Folded, Remaining
                        ),
                        ?MOD:to_value(Folded) =:= ?MOD:to_value(State) andalso
                            ?MOD:decode_state(?MOD:encode_state(Folded)) =:=
                                Folded andalso
                            ?MOD:to_value(Saturated) =:= Target
                end
            end,
            PerOrigin
        )
    end).

%% =============================================================================
%% Simulation (realistic causal delivery) — mirrors the aw_map/aw_set suites
%% =============================================================================

init() ->
    ?MOD:init(?SCHEMA).

simulate(Cmds) ->
    Origins0 = maps:from_list([{O, {init(), []}} || O <- ?ORIGINS]),
    World0 = #{origins => Origins0, hlc => 1, seqs => #{}, log => []},
    World = lists:foldl(fun step/2, World0, Cmds),
    #{origins := Origins, log := RevLog} = World,
    PerOrigin = [{O, S, D} || {O, {S, D}} <- maps:to_list(Origins)],
    {PerOrigin, lists:reverse(RevLog)}.

step({apply, O, FieldKey, SubOp}, World) ->
    mint(O, {apply, FieldKey, SubOp}, World);
step({sync, From, To}, World) ->
    sync(From, To, World).

mint(O, Op, #{origins := Os, hlc := H, seqs := Seqs, log := Log} = W) ->
    {S, D} = maps:get(O, Os),
    Seq = maps:get(O, Seqs, 0) + 1,
    Ctx = ?MOD:context_of(S),
    E = mk_event(H, O, Seq, Op, Ctx),
    S1 = apply_event(E, S),
    W#{
        origins := Os#{O => {S1, D ++ [E]}},
        hlc := H + 1,
        seqs := Seqs#{O => Seq},
        log := [E | Log]
    }.

sync(From, To, #{origins := Os} = W) ->
    {_SFrom, DFrom} = maps:get(From, Os),
    {STo, DTo} = maps:get(To, Os),
    Missing = sort_by_key([E || E <- DFrom, not lists:member(E, DTo)]),
    {STo1, DTo1} = lists:foldl(
        fun(E, {SAcc, DAcc}) -> {apply_event(E, SAcc), DAcc ++ [E]} end,
        {STo, DTo},
        Missing
    ),
    W#{origins := Os#{To => {STo1, DTo1}}}.

%% =============================================================================
%% Helpers
%% =============================================================================

mk_event(Hlc, Origin, Seq, Op, Context) ->
    Key = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(Key, Op, Context).

apply_event(Event, State) ->
    ?MOD:apply_op(
        State,
        bondy_oplog_event:op(Event),
        bondy_oplog_event:key(Event),
        bondy_oplog_event:meta(Event)
    ).

%% The canonical batch-fold path: sort by key, fold `apply_op/4` — what
%% `bondy_oplog_crdt_commutative:interpret_cog/3` does for a concrete
%% consumer module.
group_interpret(Events, State) ->
    lists:foldl(fun apply_event/2, State, sort_by_key(Events)).

sort_by_key(Events) ->
    lists:sort(
        fun(A, B) ->
            bondy_oplog_event:compare_keys(
                bondy_oplog_event:key(A), bondy_oplog_event:key(B)
            ) =/= gt
        end,
        Events
    ).

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
            prop_per_replica_eager_equals_group(),
            prop_full_sync_converges(),
            prop_permutation_invariant(),
            prop_idempotent_redelivery(),
            prop_encode_state_roundtrip(),
            prop_counter_field_oracle(),
            prop_stabilize_fold_transparent()
        ],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, Opts)) end,
            Props
        )
    end}.
