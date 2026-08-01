%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PropEr properties for the add-wins observed-remove map — the tier_2
%% ship gate.
%%
%% A command sequence over a few origins (`{put,O,K,V}`, `{rmv,O,K}`,
%% `{sync,From,To}`) is simulated with realistic **causal-delivery**
%% semantics: each origin keeps its own materialised state and the ordered
%% list of events it has delivered; a mint stamps the origin's currently
%% observed context (`context_of/1`) and delivers to itself; a sync
%% delivers, in key order, exactly the events the source has seen that the
%% target has not (a causal-order anti-entropy round). The generated
%% contexts are therefore well-formed partial causal observations, not
%% arbitrary noise.
%%
%% The headline property `prop_per_replica_eager_equals_group` asserts
%% the eager-equals-group invariant in its realistic form: each
%% replica's incremental eager state — built by applying `apply_op/4` in
%% (causal) delivery order — equals the canonical key-sorted
%% `interpret_cog/2` over exactly the events that replica delivered. The
%% delivery order is a causal linearization that generally differs from
%% the key-sorted order (a sync can interleave a peer's lower-HLC event
%% after the replica's own higher-HLC event), so this genuinely exercises
%% eager-vs-group rather than re-sorting an already-sorted log.
%%
%% The generator also mints `{apply, O, K, N}` — a nested `pn_counter`
%% sub-op on a key drawn from a set disjoint from the flat-put keys, so a
%% type-consistency `{badarg, _}` (mixing a flat put and a nested apply
%% on the same key is a caller error, see `bondy_oplog_crdt_nested_core`)
%% is never generated. This exercises the same
%% `bondy_oplog_crdt_nested_core` engine `bondy_oplog_crdt_aw_set` uses,
%% so the properties below prove convergence for nested keys too.
%%
%% `prop_nested_counter_oracle` is a **separate**, focused property (its
%% own apply-only generator, no put/rmv) that checks *semantic*
%% correctness against an independent oracle, not just internal
%% consistency: the other properties above only prove replicas agree
%% with each other, which is satisfied even if every replica agrees on a
%% *wrong* value. This distinction is not academic — it is exactly how a
%% real bug (`bondy_oplog_crdt_nested_core:put_nested/7` incorrectly
%% pruning a writer's own prior nested sub-op, silently dropping
%% sequential same-origin `pn_counter` increments) shipped past every
%% property above and was only caught by manual reproduction.

-module(bondy_oplog_crdt_aw_map_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_aw_map).
-define(ORIGINS, [<<"a">>, <<"b">>, <<"c">>]).
-define(KEYS, [<<"k1">>, <<"k2">>]).
-define(NESTED_KEYS, [<<"nk1">>, <<"nk2">>]).
-define(VALUES, [<<"x">>, <<"y">>, <<"z">>]).
-define(DELTAS, [-2, -1, 1, 2]).
-define(SUB_MOD, bondy_oplog_crdt_pn_counter).
-define(DEFAULT_NUMTESTS, 300).

-export([prop_per_replica_eager_equals_group/0]).
-export([prop_full_sync_converges/0]).
-export([prop_permutation_invariant/0]).
-export([prop_idempotent_redelivery/0]).
-export([prop_encode_state_roundtrip/0]).
-export([prop_nested_counter_oracle/0]).

%% =============================================================================
%% Generators
%% =============================================================================

cmd_gen() ->
    oneof([
        {put, oneof(?ORIGINS), oneof(?KEYS), oneof(?VALUES)},
        {apply, oneof(?ORIGINS), oneof(?NESTED_KEYS), oneof(?DELTAS)},
        {rmv, oneof(?ORIGINS), oneof(?KEYS ++ ?NESTED_KEYS)},
        {sync, oneof(?ORIGINS), oneof(?ORIGINS)}
    ]).

cmds_gen() ->
    list(cmd_gen()).

%% Focused generator for prop_nested_counter_oracle: apply/sync only, no
%% put/rmv, so the independent sum oracle never needs to reason about
%% key removal.
counter_cmd_gen() ->
    oneof([
        {apply, oneof(?ORIGINS), oneof(?NESTED_KEYS), oneof(?DELTAS)},
        {sync, oneof(?ORIGINS), oneof(?ORIGINS)}
    ]).

counter_cmds_gen() ->
    list(counter_cmd_gen()).

%% =============================================================================
%% Properties
%% =============================================================================

%% §4.3 ship gate (realistic): per replica, eager delivery-order fold ==
%% key-sorted interpret_cog of exactly what it delivered.
prop_per_replica_eager_equals_group() ->
    ?FORALL(Cmds, cmds_gen(), begin
        {PerOrigin, _Log} = simulate(Cmds),
        lists:all(
            fun({_O, State, Delivered}) ->
                State =:= ?MOD:interpret_cog(Delivered, ?MOD:init())
            end,
            PerOrigin
        )
    end).

%% Strong eventual consistency: every replica, once it has delivered the
%% whole log (in causal order), reaches the same state — the canonical
%% interpretation of the full event set.
prop_full_sync_converges() ->
    ?FORALL(Cmds, cmds_gen(), begin
        {PerOrigin, Log} = simulate(Cmds),
        Target = ?MOD:interpret_cog(Log, ?MOD:init()),
        lists:all(
            fun({_O, State, Delivered}) ->
                Remaining = [E || E <- Log, not lists:member(E, Delivered)],
                Saturated = lists:foldl(
                    fun(E, S) -> apply_event(S, E) end,
                    State,
                    sort_by_key(Remaining)
                ),
                Saturated =:= Target
            end,
            PerOrigin
        )
    end).

%% interpret_cog is invariant under any arrival permutation of the log.
prop_permutation_invariant() ->
    ?FORALL(Cmds, cmds_gen(), begin
        {_PerOrigin, Log} = simulate(Cmds),
        Ref = ?MOD:interpret_cog(Log, ?MOD:init()),
        ?FORALL(Perm, shuffle_gen(Log), begin
            ?MOD:interpret_cog(Perm, ?MOD:init()) =:= Ref
        end)
    end).

%% Re-delivering every event a second time changes nothing (idempotent).
prop_idempotent_redelivery() ->
    ?FORALL(Cmds, cmds_gen(), begin
        {_PerOrigin, Log} = simulate(Cmds),
        Once = ?MOD:interpret_cog(Log, ?MOD:init()),
        Twice = ?MOD:interpret_cog(Log ++ Log, ?MOD:init()),
        Once =:= Twice
    end).

prop_encode_state_roundtrip() ->
    ?FORALL(Cmds, cmds_gen(), begin
        {_PerOrigin, Log} = simulate(Cmds),
        State = ?MOD:interpret_cog(Log, ?MOD:init()),
        ?MOD:decode_state(?MOD:encode_state(State)) =:= State
    end).

%% A nested `pn_counter` field's converged value must equal the sum of
%% every {inc,N} delta ever applied to it, independent of how many
%% origins contributed or how much sequential same-origin churn there
%% was. Deliberately its own generator (apply/sync only, no put/rmv) so
%% key-removal interaction never complicates this independent-oracle
%% check — that interaction is already covered by the properties above.
prop_nested_counter_oracle() ->
    ?FORALL(Cmds, counter_cmds_gen(), begin
        {_PerOrigin, Log} = simulate(Cmds),
        State = ?MOD:interpret_cog(Log, ?MOD:init()),
        Value = ?MOD:to_value(State),
        lists:all(
            fun(NestedKey) ->
                Deltas = [
                    N
                 || Ev <- Log,
                    {apply, K, _SubMod, {inc, N}} <-
                        [bondy_oplog_crdt_commutative:op_of(Ev)],
                    K =:= NestedKey
                ],
                case Deltas of
                    [] ->
                        not maps:is_key(NestedKey, Value);
                    _ ->
                        maps:get(NestedKey, Value, undefined) =:=
                            lists:sum(Deltas)
                end
            end,
            ?NESTED_KEYS
        )
    end).

%% =============================================================================
%% Simulation (realistic causal delivery)
%% =============================================================================

%% Returns `{PerOrigin, Log}` where PerOrigin is `[{Origin, State,
%% DeliveredEvents}]` (DeliveredEvents in delivery order) and Log is the
%% full mint log in generation (HLC-increasing) order.
simulate(Cmds) ->
    Origins0 = maps:from_list([{O, {?MOD:init(), []}} || O <- ?ORIGINS]),
    World0 = #{origins => Origins0, hlc => 1, seqs => #{}, log => []},
    World = lists:foldl(fun step/2, World0, Cmds),
    #{origins := Origins, log := RevLog} = World,
    PerOrigin = [{O, S, D} || {O, {S, D}} <- maps:to_list(Origins)],
    {PerOrigin, lists:reverse(RevLog)}.

step({put, O, K, V}, World) ->
    mint(O, {put, K, V}, World);
step({apply, O, K, N}, World) ->
    mint(O, {apply, K, ?SUB_MOD, {inc, N}}, World);
step({rmv, O, K}, World) ->
    mint(O, {rmv, K}, World);
step({sync, From, To}, World) ->
    sync(From, To, World).

mint(O, Op, #{origins := Os, hlc := H, seqs := Seqs, log := Log} = W) ->
    {S, D} = maps:get(O, Os),
    Seq = maps:get(O, Seqs, 0) + 1,
    Ctx = ?MOD:context_of(S),
    E = mk_event(H, O, Seq, Op, Ctx),
    S1 = apply_event(S, E),
    W#{
        origins := Os#{O => {S1, D ++ [E]}},
        hlc := H + 1,
        seqs := Seqs#{O => Seq},
        log := [E | Log]
    }.

sync(From, To, #{origins := Os} = W) ->
    {_SFrom, DFrom} = maps:get(From, Os),
    {STo, DTo} = maps:get(To, Os),
    %% Events the source delivered that the target has not, applied in key
    %% (causal) order — a causal anti-entropy round.
    Missing = sort_by_key([E || E <- DFrom, not lists:member(E, DTo)]),
    {STo1, DTo1} = lists:foldl(
        fun(E, {SAcc, DAcc}) -> {apply_event(SAcc, E), DAcc ++ [E]} end,
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

apply_event(State, Event) ->
    ?MOD:apply_op(
        State,
        bondy_oplog_crdt_commutative:op_of(Event),
        bondy_oplog_event:key(Event),
        bondy_oplog_event:meta(Event)
    ).

sort_by_key(Events) ->
    lists:sort(
        fun(A, B) ->
            bondy_oplog_event:compare_keys(
                bondy_oplog_event:key(A), bondy_oplog_event:key(B)
            ) =/= gt
        end,
        Events
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
            prop_per_replica_eager_equals_group(),
            prop_full_sync_converges(),
            prop_permutation_invariant(),
            prop_idempotent_redelivery(),
            prop_encode_state_roundtrip(),
            prop_nested_counter_oracle()
        ],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, Opts)) end,
            Props
        )
    end}.
