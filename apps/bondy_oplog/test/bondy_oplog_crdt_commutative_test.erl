%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Property tests for `bondy_oplog_crdt_commutative`: the sanctioned,
%% dependency-free replacement for the deprecated `bondy_oplog_crdt_fold`
%% bridge.
%%
%% The headline property the whole operation-based design rests on:
%% `interpret_cog/3` is a deterministic function of the event SET — any
%% permutation of the same events yields the same state. For a commutative
%% CRDT the eager single-op write path (`apply_op/4`) additionally agrees
%% with the key-ordered batch result, which is what makes the O(1)
%% projection-maintenance path (Option B) correct.
%%
%% Deterministic (exhaustive small permutations, no random seed) — CI-stable.

-module(bondy_oplog_crdt_commutative_test).

-include_lib("eunit/include/eunit.hrl").

-define(HELPER, bondy_oplog_crdt_commutative).
-define(CRDT, bondy_oplog_crdt_gset_example).

%% =============================================================================
%% Helpers
%% =============================================================================

ek(H, O, S) ->
    bondy_oplog_event:key(H, O, S).

%% Event with a raw op (monolithic shape): op_of returns the op directly.
ev(H, O, S, Op) ->
    bondy_oplog_event:new(ek(H, O, S), Op, #{}).

%% Event with a catalogue cell_apply wrapper: op_of unwraps to the inner op.
cell_ev(H, O, S, Bucket, Key, Op) ->
    bondy_oplog_event:new(
        ek(H, O, S), {cell_apply, Bucket, Key, Op}, #{}
    ).

perms([]) ->
    [[]];
perms(L) ->
    [[X | P] || X <- L, P <- perms(L -- [X])].

sample_events() ->
    [
        ev(30, <<"n2">>, 1, {add, <<"b">>}),
        ev(10, <<"n1">>, 1, {add, <<"a">>}),
        ev(20, <<"n1">>, 2, {add, <<"c">>})
    ].

%% =============================================================================
%% interpret_cog is a deterministic function of the event SET
%% =============================================================================

interpret_cog_is_set_function_test() ->
    Es = sample_events(),
    Init = ?CRDT:init(),
    [First | Rest] =
        [?HELPER:interpret_cog(?CRDT, P, Init) || P <- perms(Es)],
    ?assert(lists:all(fun(R) -> R =:= First end, Rest)),
    %% And the value is the canonical key-ordered result.
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], ?CRDT:to_value(First)).

%% =============================================================================
%% Eager single-op path == key-ordered batch (the Option B guarantee)
%% =============================================================================

incremental_equals_interpret_cog_test() ->
    Es = sample_events(),
    Init = ?CRDT:init(),
    Authoritative = ?HELPER:interpret_cog(?CRDT, Es, Init),
    lists:foreach(
        fun(P) ->
            Incremental = lists:foldl(
                fun(E, S) ->
                    ?HELPER:apply_op(
                        ?CRDT, S, ?HELPER:op_of(E), bondy_oplog_event:key(E)
                    )
                end,
                Init,
                P
            ),
            ?assertEqual(Authoritative, Incremental)
        end,
        perms(Es)
    ).

%% =============================================================================
%% cell_apply unwrapping
%% =============================================================================

op_of_unwraps_cell_apply_test() ->
    E = cell_ev(10, <<"n1">>, 1, <<"bucket">>, <<"k">>, {add, <<"x">>}),
    ?assertEqual({add, <<"x">>}, ?HELPER:op_of(E)).

op_of_passes_raw_op_through_test() ->
    E = ev(10, <<"n1">>, 1, {add, <<"x">>}),
    ?assertEqual({add, <<"x">>}, ?HELPER:op_of(E)).

interpret_cog_unwraps_cell_apply_test() ->
    Es = [
        cell_ev(30, <<"n2">>, 1, <<"b">>, <<"k">>, {add, <<"b">>}),
        cell_ev(10, <<"n1">>, 1, <<"b">>, <<"k">>, {add, <<"a">>})
    ],
    S = ?HELPER:interpret_cog(?CRDT, Es, ?CRDT:init()),
    ?assertEqual([<<"a">>, <<"b">>], ?CRDT:to_value(S)).

%% =============================================================================
%% projection-seam round trips
%% =============================================================================

encode_decode_state_roundtrip_test() ->
    S = ?HELPER:interpret_cog(?CRDT, sample_events(), ?CRDT:init()),
    ?assertEqual(S, ?CRDT:decode_state(?CRDT:encode_state(S))).

example_declares_commutative_test() ->
    ?assert(?CRDT:order_independent()).

%% =============================================================================
%% empty group is the identity
%% =============================================================================

empty_cog_is_identity_test() ->
    Init = ?CRDT:init(),
    ?assertEqual(Init, ?HELPER:interpret_cog(?CRDT, [], Init)).
