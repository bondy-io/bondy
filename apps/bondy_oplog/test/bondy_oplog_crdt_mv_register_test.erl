%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Pure unit tests for the multi-value register (the first tier_2 native
%% CRDT). They drive `apply_op/4` and `interpret_cog/2` directly with
%% hand-built events, simulating the substrate origin-stamp: a write's
%% context is `context_of/1` of the state the origin observed. No oplog
%% instance is started — these pin the CRDT logic in isolation.

-module(bondy_oplog_crdt_mv_register_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_mv_register).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Build an event with op `{set, V}` whose meta carries `Context` (the
%% version vector observed at the origin), dotted `{Hlc, Origin, Seq}`.
mk_event(Hlc, Origin, Seq, V, Context) ->
    Key = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(Key, {set, V}, Context).

%% Apply one write at the origin: stamp the context the origin currently
%% observes (`context_of/1`), then apply. Mirrors the applier's eager
%% step exactly.
write(State, Hlc, Origin, Seq, V) ->
    Context = ?MOD:context_of(State),
    Event = mk_event(Hlc, Origin, Seq, V, Context),
    apply_event(State, Event).

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
    ?assertEqual([], ?MOD:to_value(?MOD:init())),
    ?assertEqual([], ?MOD:context_of(?MOD:init())),
    ?assertEqual(0, ?MOD:hlc(?MOD:init())).

%% Sequential writes from one origin: each observes the prior (read-your-
%% writes), so the later value dominates — a single value, not a sibling.
sequential_writes_dominate_test() ->
    S0 = ?MOD:init(),
    S1 = write(S0, 10, <<"a">>, 1, <<"v1">>),
    ?assertEqual([<<"v1">>], ?MOD:to_value(S1)),
    S2 = write(S1, 20, <<"a">>, 2, <<"v2">>),
    ?assertEqual([<<"v2">>], ?MOD:to_value(S2)),
    ?assertEqual(20, ?MOD:hlc(S2)).

%% Two origins write without observing each other (both saw the empty
%% context): both values survive as concurrent siblings.
concurrent_writes_are_siblings_test() ->
    S0 = ?MOD:init(),
    %% Both stamp the SAME (empty) context — they are concurrent.
    Ea = mk_event(10, <<"a">>, 1, <<"va">>, ?MOD:context_of(S0)),
    Eb = mk_event(11, <<"b">>, 1, <<"vb">>, ?MOD:context_of(S0)),
    S1 = apply_event(apply_event(S0, Ea), Eb),
    ?assertEqual([<<"va">>, <<"vb">>], ?MOD:to_value(S1)).

%% Sibling merge is order-independent: applying the two concurrent writes
%% in either order yields the same state (eager step commutes).
concurrent_order_independent_test() ->
    S0 = ?MOD:init(),
    Ea = mk_event(10, <<"a">>, 1, <<"va">>, ?MOD:context_of(S0)),
    Eb = mk_event(11, <<"b">>, 1, <<"vb">>, ?MOD:context_of(S0)),
    Sab = apply_event(apply_event(S0, Ea), Eb),
    Sba = apply_event(apply_event(S0, Eb), Ea),
    ?assertEqual(Sab, Sba).

%% A write that observes BOTH siblings (its context dominates both dots)
%% collapses them to its single value — concurrency resolution.
resolving_write_collapses_siblings_test() ->
    S0 = ?MOD:init(),
    Ea = mk_event(10, <<"a">>, 1, <<"va">>, ?MOD:context_of(S0)),
    Eb = mk_event(11, <<"b">>, 1, <<"vb">>, ?MOD:context_of(S0)),
    S1 = apply_event(apply_event(S0, Ea), Eb),
    ?assertEqual([<<"va">>, <<"vb">>], ?MOD:to_value(S1)),
    %% `a` now observes the full context and writes vc.
    S2 = write(S1, 20, <<"a">>, 2, <<"vc">>),
    ?assertEqual([<<"vc">>], ?MOD:to_value(S2)).

%% Duplicate / replayed delivery is idempotent (set-union under sync).
duplicate_delivery_is_idempotent_test() ->
    S0 = ?MOD:init(),
    E = mk_event(10, <<"a">>, 1, <<"va">>, ?MOD:context_of(S0)),
    S1 = apply_event(S0, E),
    S2 = apply_event(S1, E),
    ?assertEqual(S1, S2).

%% interpret_cog over the full event set == eager fold, and is invariant
%% under permutation of the event list.
interpret_cog_matches_eager_and_permutation_invariant_test() ->
    S0 = ?MOD:init(),
    %% Two concurrent writes then a resolving write from `a`.
    Ea = mk_event(10, <<"a">>, 1, <<"va">>, ?MOD:context_of(S0)),
    Eb = mk_event(11, <<"b">>, 1, <<"vb">>, ?MOD:context_of(S0)),
    SConc = apply_event(apply_event(S0, Ea), Eb),
    Ec = mk_event(20, <<"a">>, 2, <<"vc">>, ?MOD:context_of(SConc)),
    Eager = apply_event(SConc, Ec),
    Events = [Ea, Eb, Ec],
    Group = ?MOD:interpret_cog(Events, S0),
    ?assertEqual(Eager, Group),
    %% Permutation invariance of interpret_cog.
    ?assertEqual(Group, ?MOD:interpret_cog([Ec, Ea, Eb], S0)),
    ?assertEqual(Group, ?MOD:interpret_cog([Eb, Ec, Ea], S0)),
    ?assertEqual([<<"vc">>], ?MOD:to_value(Group)).

encode_decode_roundtrip_test() ->
    S0 = ?MOD:init(),
    S1 = write(S0, 10, <<"a">>, 1, <<"va">>),
    Ea = mk_event(11, <<"a">>, 2, <<"va2">>, ?MOD:context_of(S0)),
    Eb = mk_event(12, <<"b">>, 1, <<"vb">>, ?MOD:context_of(S0)),
    S2 = apply_event(apply_event(S1, Ea), Eb),
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
    Ea = mk_event(10, <<"a">>, 1, <<"va">>, ?MOD:context_of(S0)),
    Eb = mk_event(11, <<"b">>, 1, <<"vb">>, ?MOD:context_of(S0)),
    Sab = apply_event(apply_event(S0, Ea), Eb),
    Sba = apply_event(apply_event(S0, Eb), Ea),
    ?assertEqual(?MOD:encode_state(Sab), ?MOD:encode_state(Sba)).

%% Recovery from the durable ENCODING (the compaction checkpoint /
%% projection HEAD `StateBytes`) reconstructs the exact DVV, so the
%% recovered context equals the original — a post-recovery write by the
%% same origin observes it and DOMINATES, never regressing the context
%% into a spurious sibling. This is the algorithmic half of the
%% origin-context-monotonicity precondition; the substrate guarantees the
%% other half (finish recovery before accepting writes — see PR-J4).
recovery_via_encoding_preserves_context_test() ->
    S0 = ?MOD:init(),
    S1 = write(S0, 10, <<"a">>, 1, <<"v1">>),
    S2 = write(S1, 20, <<"a">>, 2, <<"v2">>),
    Recovered = ?MOD:decode_state(?MOD:encode_state(S2)),
    ?assertEqual(?MOD:context_of(S2), ?MOD:context_of(Recovered)),
    S3 = write(Recovered, 30, <<"a">>, 3, <<"v3">>),
    ?assertEqual([<<"v3">>], ?MOD:to_value(S3)).

%% Recovery by REPLAYING the event history (each event with its stamped
%% context, as the WAL holds it) through `interpret_cog/2` reconstructs the
%% exact same state and context as the eager path — and a subsequent write
%% still dominates (no regression / no spurious sibling).
recovery_via_replay_preserves_context_test() ->
    S0 = ?MOD:init(),
    E1 = mk_event(10, <<"a">>, 1, <<"v1">>, ?MOD:context_of(S0)),
    S1 = apply_event(S0, E1),
    E2 = mk_event(20, <<"a">>, 2, <<"v2">>, ?MOD:context_of(S1)),
    S2 = apply_event(S1, E2),
    Replayed = ?MOD:interpret_cog([E1, E2], ?MOD:init()),
    ?assertEqual(S2, Replayed),
    ?assertEqual(?MOD:context_of(S2), ?MOD:context_of(Replayed)),
    E3 = mk_event(30, <<"a">>, 3, <<"v3">>, ?MOD:context_of(Replayed)),
    ?assertEqual([<<"v3">>], ?MOD:to_value(apply_event(Replayed, E3))).
