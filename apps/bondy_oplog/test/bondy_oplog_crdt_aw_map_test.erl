%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Pure unit tests for the add-wins observed-remove map (a tier_2 native
%% CRDT). They drive `apply_op/4` and `interpret_cog/2` directly with
%% hand-built events, simulating the substrate origin-stamp: a write's
%% context is `context_of/1` of the state the origin observed. No oplog
%% instance is started — these pin the CRDT logic in isolation.

-module(bondy_oplog_crdt_aw_map_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_aw_map).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Build an event with op `Op` whose meta carries `Context` (the version
%% vector observed at the origin), dotted `{Hlc, Origin, Seq}`.
mk_event(Hlc, Origin, Seq, Op, Context) ->
    Key = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(Key, Op, Context).

%% Apply one operation at the origin: stamp the context the origin
%% currently observes (`context_of/1`), then apply. Mirrors the applier's
%% eager step exactly (read-your-writes).
write(State, Hlc, Origin, Seq, Op) ->
    Context = ?MOD:context_of(State),
    apply_event(State, mk_event(Hlc, Origin, Seq, Op, Context)).

apply_event(State, Event) ->
    ?MOD:apply_op(
        State,
        bondy_oplog_crdt_commutative:op_of(Event),
        bondy_oplog_event:key(Event),
        bondy_oplog_event:meta(Event)
    ).

%% =============================================================================
%% Tests
%% =============================================================================

init_is_empty_test() ->
    ?assertEqual(#{}, ?MOD:to_value(?MOD:init())),
    ?assertEqual([], ?MOD:context_of(?MOD:init())),
    ?assertEqual(0, ?MOD:hlc(?MOD:init())).

put_creates_key_test() ->
    S0 = ?MOD:init(),
    S1 = write(S0, 10, <<"a">>, 1, {put, <<"k">>, <<"v">>}),
    ?assertEqual(#{<<"k">> => [<<"v">>]}, ?MOD:to_value(S1)),
    ?assertEqual(10, ?MOD:hlc(S1)).

%% Sequential puts from one origin: the second observes the first
%% (read-your-writes), so the later value dominates — a single value.
sequential_put_overwrites_test() ->
    S0 = ?MOD:init(),
    S1 = write(S0, 10, <<"a">>, 1, {put, <<"k">>, <<"v1">>}),
    ?assertEqual(#{<<"k">> => [<<"v1">>]}, ?MOD:to_value(S1)),
    S2 = write(S1, 20, <<"a">>, 2, {put, <<"k">>, <<"v2">>}),
    ?assertEqual(#{<<"k">> => [<<"v2">>]}, ?MOD:to_value(S2)).

%% Two origins write the same key without observing each other (both saw
%% the empty context): both values survive as concurrent siblings.
concurrent_put_are_siblings_test() ->
    S0 = ?MOD:init(),
    Ea = mk_event(
        10, <<"a">>, 1, {put, <<"k">>, <<"va">>}, ?MOD:context_of(S0)
    ),
    Eb = mk_event(
        11, <<"b">>, 1, {put, <<"k">>, <<"vb">>}, ?MOD:context_of(S0)
    ),
    S1 = apply_event(apply_event(S0, Ea), Eb),
    ?assertEqual(#{<<"k">> => [<<"va">>, <<"vb">>]}, ?MOD:to_value(S1)).

%% Sibling merge is order-independent.
concurrent_put_order_independent_test() ->
    S0 = ?MOD:init(),
    Ea = mk_event(
        10, <<"a">>, 1, {put, <<"k">>, <<"va">>}, ?MOD:context_of(S0)
    ),
    Eb = mk_event(
        11, <<"b">>, 1, {put, <<"k">>, <<"vb">>}, ?MOD:context_of(S0)
    ),
    Sab = apply_event(apply_event(S0, Ea), Eb),
    Sba = apply_event(apply_event(S0, Eb), Ea),
    ?assertEqual(Sab, Sba).

%% A remove that observed the put removes the key.
observed_remove_removes_key_test() ->
    S0 = ?MOD:init(),
    S1 = write(S0, 10, <<"a">>, 1, {put, <<"k">>, <<"v">>}),
    S2 = write(S1, 20, <<"a">>, 2, {rmv, <<"k">>}),
    ?assertEqual(#{}, ?MOD:to_value(S2)).

%% Add-wins: a put concurrent with a remove (the remove never observed the
%% put's dot) survives.
add_wins_concurrent_put_survives_remove_test() ->
    S0 = ?MOD:init(),
    %% `a` puts k=va, dot {a,1}.
    Sa1 = write(S0, 10, <<"a">>, 1, {put, <<"k">>, <<"va">>}),
    %% `b`'s concurrent put observed only the empty S0.
    Eb = mk_event(
        11, <<"b">>, 1, {put, <<"k">>, <<"vb">>}, ?MOD:context_of(S0)
    ),
    %% `a` removes, with the context it observed at write time — only its
    %% own dot {a,1} (stamped from Sa1, NOT from a later merged state). The
    %% event's observed context is immutable thereafter.
    Erm = mk_event(20, <<"a">>, 2, {rmv, <<"k">>}, ?MOD:context_of(Sa1)),
    %% The same three events in two causal delivery orders converge, with
    %% `b`'s concurrent value surviving (add-wins).
    S_rm_last = apply_event(apply_event(Sa1, Eb), Erm),
    S_rm_mid = apply_event(apply_event(Sa1, Erm), Eb),
    ?assertEqual(#{<<"k">> => [<<"vb">>]}, ?MOD:to_value(S_rm_last)),
    ?assertEqual(#{<<"k">> => [<<"vb">>]}, ?MOD:to_value(S_rm_mid)),
    ?assertEqual(S_rm_last, S_rm_mid).

%% Remove then re-put by the same origin revives the key (the re-put's dot
%% is new / un-observed by the remove).
remove_then_reput_revives_test() ->
    S0 = ?MOD:init(),
    S1 = write(S0, 10, <<"a">>, 1, {put, <<"k">>, <<"v1">>}),
    S2 = write(S1, 20, <<"a">>, 2, {rmv, <<"k">>}),
    ?assertEqual(#{}, ?MOD:to_value(S2)),
    S3 = write(S2, 30, <<"a">>, 3, {put, <<"k">>, <<"v3">>}),
    ?assertEqual(#{<<"k">> => [<<"v3">>]}, ?MOD:to_value(S3)).

%% A remove of one key never touches another key — the per-key dot-store
%% guards against cross-key causal-context contamination (a single-VV
%% merge would wrongly drop k1's lower-counter dot).
distinct_keys_independent_test() ->
    S0 = ?MOD:init(),
    S1 = write(S0, 10, <<"a">>, 1, {put, <<"k1">>, <<"va">>}),
    S2 = write(S1, 20, <<"a">>, 2, {put, <<"k2">>, <<"vb">>}),
    S3 = write(S2, 30, <<"a">>, 3, {rmv, <<"k2">>}),
    ?assertEqual(#{<<"k1">> => [<<"va">>]}, ?MOD:to_value(S3)).

%% Duplicate / replayed delivery is idempotent.
duplicate_delivery_is_idempotent_test() ->
    S0 = ?MOD:init(),
    E = mk_event(10, <<"a">>, 1, {put, <<"k">>, <<"v">>}, ?MOD:context_of(S0)),
    S1 = apply_event(S0, E),
    S2 = apply_event(S1, E),
    ?assertEqual(S1, S2).

%% interpret_cog over the full event set == eager fold, and is invariant
%% under permutation of the event list.
interpret_cog_matches_eager_and_permutation_invariant_test() ->
    S0 = ?MOD:init(),
    %% Two concurrent puts to k, then a remove from `a` that observed only
    %% its own dot, plus an independent put to k2.
    Ea = mk_event(
        10, <<"a">>, 1, {put, <<"k">>, <<"va">>}, ?MOD:context_of(S0)
    ),
    Eb = mk_event(
        11, <<"b">>, 1, {put, <<"k">>, <<"vb">>}, ?MOD:context_of(S0)
    ),
    SaConc = apply_event(S0, Ea),
    Erm = mk_event(20, <<"a">>, 2, {rmv, <<"k">>}, ?MOD:context_of(SaConc)),
    Ek2 = mk_event(
        21, <<"a">>, 3, {put, <<"k2">>, <<"vc">>}, ?MOD:context_of(S0)
    ),
    Events = [Ea, Eb, Erm, Ek2],
    Eager = lists:foldl(fun(E, S) -> apply_event(S, E) end, S0, Events),
    Group = ?MOD:interpret_cog(Events, S0),
    ?assertEqual(Eager, Group),
    ?assertEqual(Group, ?MOD:interpret_cog([Ek2, Erm, Ea, Eb], S0)),
    ?assertEqual(Group, ?MOD:interpret_cog([Eb, Ek2, Ea, Erm], S0)),
    %% `b`'s concurrent put to k survives the remove; k2 is present.
    ?assertEqual(
        #{<<"k">> => [<<"vb">>], <<"k2">> => [<<"vc">>]},
        ?MOD:to_value(Group)
    ).

encode_decode_roundtrip_test() ->
    S0 = ?MOD:init(),
    S1 = write(S0, 10, <<"a">>, 1, {put, <<"k">>, <<"va">>}),
    Eb = mk_event(
        11, <<"b">>, 1, {put, <<"k">>, <<"vb">>}, ?MOD:context_of(S0)
    ),
    Ek2 = mk_event(
        12, <<"a">>, 2, {put, <<"k2">>, <<"vc">>}, ?MOD:context_of(S1)
    ),
    S2 = apply_event(apply_event(S1, Eb), Ek2),
    lists:foreach(
        fun(S) ->
            ?assertEqual(S, ?MOD:decode_state(?MOD:encode_state(S)))
        end,
        [S0, S1, S2]
    ).

%% Equal logical state ⇒ equal bytes, regardless of the order the two
%% concurrent writes were absorbed (the convergence/encoding gate).
encoding_is_canonical_under_order_test() ->
    S0 = ?MOD:init(),
    Ea = mk_event(
        10, <<"a">>, 1, {put, <<"k">>, <<"va">>}, ?MOD:context_of(S0)
    ),
    Eb = mk_event(
        11, <<"b">>, 1, {put, <<"k">>, <<"vb">>}, ?MOD:context_of(S0)
    ),
    Sab = apply_event(apply_event(S0, Ea), Eb),
    Sba = apply_event(apply_event(S0, Eb), Ea),
    ?assertEqual(?MOD:encode_state(Sab), ?MOD:encode_state(Sba)).

%% Recovery from the durable ENCODING reconstructs the exact context, so a
%% post-recovery write by the same origin dominates rather than regressing
%% into a spurious sibling.
recovery_via_encoding_preserves_context_test() ->
    S0 = ?MOD:init(),
    S1 = write(S0, 10, <<"a">>, 1, {put, <<"k">>, <<"v1">>}),
    S2 = write(S1, 20, <<"a">>, 2, {put, <<"k">>, <<"v2">>}),
    Recovered = ?MOD:decode_state(?MOD:encode_state(S2)),
    ?assertEqual(?MOD:context_of(S2), ?MOD:context_of(Recovered)),
    S3 = write(Recovered, 30, <<"a">>, 3, {put, <<"k">>, <<"v3">>}),
    ?assertEqual(#{<<"k">> => [<<"v3">>]}, ?MOD:to_value(S3)).
