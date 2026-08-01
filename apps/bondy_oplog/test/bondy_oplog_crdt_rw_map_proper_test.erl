%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PropEr properties for the remove-wins observed-remove map — the tier_2
%% ship gate, mirroring `bondy_oplog_crdt_aw_map_proper_test`. A command
%% sequence over a few origins (`{put,O,K,V}`, `{apply,O,K,N}`,
%% `{rmv,O,K}`, `{sync,From,To}`) is simulated with realistic
%% causal-delivery semantics identical to the add-wins suite; only the
%% CRDT module (and thus the pruning rule it applies) differs.
%%
%% The generator also mints `{apply, O, K, N}` — a nested `pn_counter`
%% sub-op on a key drawn from a set disjoint from the flat-put keys, so a
%% type-consistency `{badarg, _}` is never generated. This exercises
%% `bondy_oplog_crdt_rw_nested_core`, the remove-wins analogue of the
%% engine `bondy_oplog_crdt_aw_map`/`bondy_oplog_crdt_aw_set` share.
%%
%% Unlike `bondy_oplog_crdt_rw_set_proper_test`, there is no independent
%% value oracle here — a map's multi-value-sibling projection has no
%% simple oracle the way a set's membership does (`aw_map`'s own suite
%% has the same scope for the same reason).

-module(bondy_oplog_crdt_rw_map_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_rw_map).
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
            prop_encode_state_roundtrip()
        ],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, Opts)) end,
            Props
        )
    end}.
