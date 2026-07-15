%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PropEr properties for PACKED-BATCH operations over the add-wins map.
%% This is the batch-op companion to `bondy_oplog_crdt_aw_map_proper_test`:
%% the same realistic causal-delivery simulation, but the command stream may
%% mint a single `{batch, Ops}` event carrying several field commands. The
%% batch is expanded at the one seam both paths share
%% (`bondy_oplog_crdt_commutative:apply_op/5`), so every property the plain
%% map satisfies must still hold with packing:
%%
%%   - `prop_per_replica_eager_equals_group` — the §4.3 ship gate: each
%%     replica's eager delivery-order fold equals the key-sorted
%%     `interpret_cog/2` over exactly what it delivered, batch events and all.
%%   - convergence, permutation-invariance, idempotent redelivery, encode
%%     roundtrip — unchanged in statement, now exercised through batches.
%%
%% All inner ops of a batch share the packed event's one dot and one stamped
%% context (atomic, mutually-concurrent semantics); the simulation mints
%% exactly one event per batch command, mirroring `bondy_db:apply_batch/4`.

-module(bondy_oplog_crdt_aw_map_batch_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_aw_map).
-define(C, bondy_oplog_crdt_commutative).
-define(ORIGINS, [<<"a">>, <<"b">>, <<"c">>]).
-define(KEYS, [<<"k1">>, <<"k2">>]).
-define(VALUES, [<<"x">>, <<"y">>, <<"z">>]).
-define(DEFAULT_NUMTESTS, 300).

-export([prop_per_replica_eager_equals_group/0]).
-export([prop_full_sync_converges/0]).
-export([prop_permutation_invariant/0]).
-export([prop_idempotent_redelivery/0]).
-export([prop_encode_state_roundtrip/0]).

%% =============================================================================
%% Generators
%% =============================================================================

sub_op_gen() ->
    oneof([
        {put, oneof(?KEYS), oneof(?VALUES)},
        {rmv, oneof(?KEYS)}
    ]).

cmd_gen() ->
    oneof([
        {put, oneof(?ORIGINS), oneof(?KEYS), oneof(?VALUES)},
        {rmv, oneof(?ORIGINS), oneof(?KEYS)},
        %% A packed batch: one event carrying several field commands.
        {batch, oneof(?ORIGINS), non_empty(list(sub_op_gen()))},
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
%% Simulation (realistic causal delivery)
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
step({rmv, O, K}, World) ->
    mint(O, {rmv, K}, World);
step({batch, O, Ops}, World) ->
    mint(O, {batch, Ops}, World);
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

%% Eager single-event apply routed through the commutative helper — the same
%% seam the cell kernel uses — so a `{batch, Ops}` op is expanded here too.
apply_event(State, Event) ->
    ?C:apply_op(
        ?MOD,
        State,
        ?C:op_of(Event),
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
