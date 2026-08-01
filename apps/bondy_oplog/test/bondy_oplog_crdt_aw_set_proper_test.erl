%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PropEr properties for the Add-Wins Set (AWSet / observed-remove set),
%% the tier_2 ship gate. Modelled on the aw_map suite: a command sequence
%% over a few origins (`{add,O,E}`, `{rmv,O,E}`, `{sync,From,To}`) is
%% simulated with realistic causal-delivery semantics (each origin keeps
%% its own materialised state + delivered events; a mint stamps the
%% origin's observed `context_of/1`; a sync delivers, in key order, exactly
%% the events the source saw that the target had not).
%%
%% Beyond the standard convergence properties, `prop_add_wins_oracle`
%% pins the defining semantics: an element is present iff some add of it
%% survived every remove that observed it (concurrent add wins).
%%
%% The generator also mints `{apply, O, E, N}` — a nested `pn_counter`
%% sub-op on an element drawn from a set disjoint from the plain-add
%% elements, so a type-consistency `{badarg, _}` (mixing a plain add and
%% a nested apply on the same element is a caller error, see
%% `bondy_oplog_crdt_nested_core`) is never generated. `apply` mints a
%% dot exactly like `add` does, so `oracle/1` treats both as
%% presence-contributing.
%%
%% `prop_nested_counter_oracle` (its own apply/sync-only generator, no
%% add/rmv) independently sums every {inc,N} delta applied to a nested
%% element and checks it against the converged value — semantic
%% correctness, not just internal consistency. See the aw_map suite's
%% moduledoc for why this distinction matters: it is what would have
%% caught a real bug (`bondy_oplog_crdt_nested_core:put_nested/7`
%% incorrectly pruning a writer's own prior nested sub-op).

-module(bondy_oplog_crdt_aw_set_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_aw_set).
-define(CORE, bondy_oplog_crdt_aw_core).
-define(ORIGINS, [<<"a">>, <<"b">>, <<"c">>]).
-define(ELEMS, [<<"x">>, <<"y">>, <<"z">>]).
-define(NESTED_ELEMS, [<<"nx">>, <<"ny">>]).
-define(DELTAS, [-2, -1, 1, 2]).
-define(SUB_MOD, bondy_oplog_crdt_pn_counter).
-define(DEFAULT_NUMTESTS, 300).

-export([prop_per_replica_eager_equals_group/0]).
-export([prop_full_sync_converges/0]).
-export([prop_permutation_invariant/0]).
-export([prop_idempotent_redelivery/0]).
-export([prop_encode_state_roundtrip/0]).
-export([prop_add_wins_oracle/0]).
-export([prop_nested_counter_oracle/0]).

%% =============================================================================
%% Generators
%% =============================================================================

%% Focused generator for prop_nested_counter_oracle: apply/sync only, no
%% add/rmv, so the independent sum oracle never needs to reason about
%% element removal.
counter_cmd_gen() ->
    oneof([
        {apply, oneof(?ORIGINS), oneof(?NESTED_ELEMS), oneof(?DELTAS)},
        {sync, oneof(?ORIGINS), oneof(?ORIGINS)}
    ]).

counter_cmds_gen() ->
    list(counter_cmd_gen()).

cmd_gen() ->
    oneof([
        {add, oneof(?ORIGINS), oneof(?ELEMS)},
        {apply, oneof(?ORIGINS), oneof(?NESTED_ELEMS), oneof(?DELTAS)},
        {rmv, oneof(?ORIGINS), oneof(?ELEMS ++ ?NESTED_ELEMS)},
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
                State =:= ?MOD:interpret_cog(Delivered, ?MOD:init())
            end,
            PerOrigin
        )
    end).

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

prop_permutation_invariant() ->
    ?FORALL(Cmds, cmds_gen(), begin
        {_PerOrigin, Log} = simulate(Cmds),
        Ref = ?MOD:interpret_cog(Log, ?MOD:init()),
        ?FORALL(Perm, shuffle_gen(Log), begin
            ?MOD:interpret_cog(Perm, ?MOD:init()) =:= Ref
        end)
    end).

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

%% Add-wins semantics oracle: an element is present iff at least one of its
%% adds/applies has a dot that NO remove of that element observed.
prop_add_wins_oracle() ->
    ?FORALL(Cmds, cmds_gen(), begin
        {_PerOrigin, Log} = simulate(Cmds),
        State = ?MOD:interpret_cog(Log, ?MOD:init()),
        present_elems(?MOD:to_value(State)) =:= oracle(Log)
    end).

%% A nested `pn_counter` element's converged value must equal the sum of
%% every {inc,N} delta ever applied to it, independent of how many
%% origins contributed or how much sequential same-origin churn there
%% was. See the aw_map suite's identical property for why this checks
%% something the properties above do not.
prop_nested_counter_oracle() ->
    ?FORALL(Cmds, counter_cmds_gen(), begin
        {_PerOrigin, Log} = simulate(Cmds),
        State = ?MOD:interpret_cog(Log, ?MOD:init()),
        Value = ?MOD:to_value(State),
        lists:all(
            fun(NestedElem) ->
                Deltas = [
                    N
                 || Ev <- Log,
                    {apply, E, _SubMod, {inc, N}} <-
                        [bondy_oplog_crdt_commutative:op_of(Ev)],
                    E =:= NestedElem
                ],
                %% `to_value/1` returns a plain list (never a map) when
                %% nothing in the whole state is nested -- e.g. an empty
                %% command sequence -- so a nested element is trivially
                %% absent in that shape too.
                case Deltas of
                    [] ->
                        not (is_map(Value) andalso
                            maps:is_key(NestedElem, Value));
                    _ ->
                        is_map(Value) andalso
                            maps:get(NestedElem, Value, undefined) =:=
                                lists:sum(Deltas)
                end
            end,
            ?NESTED_ELEMS
        )
    end).

%% `to_value/1` returns a plain list when no element is nested (the
%% common case this property mostly exercises) or a map once at least one
%% `apply` produced a nested element — normalise both to a sorted list of
%% present elements for comparison against the oracle.
present_elems(L) when is_list(L) -> lists:sort(L);
present_elems(M) when is_map(M) -> lists:sort(maps:keys(M)).

%% =============================================================================
%% Add-wins oracle (independent of the CRDT implementation)
%% =============================================================================

oracle(Log) ->
    %% `apply` mints a dot for its element exactly like `add` does — both
    %% are presence-contributing writes.
    Adds = [
        {?CORE:dot_of(bondy_oplog_event:key(Ev)), elem_of(Ev)}
     || Ev <- Log, lists:member(tag_of(Ev), [add, apply])
    ],
    Rmvs = [
        {elem_of(Ev), normctx(bondy_oplog_event:meta(Ev))}
     || Ev <- Log, rmv =:= tag_of(Ev)
    ],
    Present = [
        E
     || {Dot, E} <- Adds,
        not lists:any(
            fun({E2, Ctx}) ->
                E2 =:= E andalso ?CORE:dot_observed(Dot, Ctx)
            end,
            Rmvs
        )
    ],
    lists:usort(Present).

tag_of(Ev) -> element(1, bondy_oplog_crdt_commutative:op_of(Ev)).
elem_of(Ev) -> element(2, bondy_oplog_crdt_commutative:op_of(Ev)).
normctx(undefined) -> [];
normctx(VV) -> VV.

%% =============================================================================
%% Simulation (realistic causal delivery) — mirrors the aw_map suite
%% =============================================================================

simulate(Cmds) ->
    Origins0 = maps:from_list([{O, {?MOD:init(), []}} || O <- ?ORIGINS]),
    World0 = #{origins => Origins0, hlc => 1, seqs => #{}, log => []},
    World = lists:foldl(fun step/2, World0, Cmds),
    #{origins := Origins, log := RevLog} = World,
    PerOrigin = [{O, S, D} || {O, {S, D}} <- maps:to_list(Origins)],
    {PerOrigin, lists:reverse(RevLog)}.

step({add, O, E}, World) ->
    mint(O, {add, E}, World);
step({apply, O, E, N}, World) ->
    mint(O, {apply, E, ?SUB_MOD, {inc, N}}, World);
step({rmv, O, E}, World) ->
    mint(O, {rmv, E}, World);
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
            prop_add_wins_oracle(),
            prop_nested_counter_oracle()
        ],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, Opts)) end,
            Props
        )
    end}.
