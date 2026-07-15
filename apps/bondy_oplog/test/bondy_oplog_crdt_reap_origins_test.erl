%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PR-H (#24) dead-origin VV reaping — the deterministic CRDT-level gate.
%%
%% Reaping drops the causal-context entries of permanently-retired origins
%% but ONLY when they carry no live value, so it is VALUE-PRESERVING:
%% `to_value/1` never changes, only `context_of/1` (the per-cell version
%% vector) shrinks. An origin still holding a live sibling is retained.
%% These tests pin both halves on `mv_register` and `aw_map`, the kernel
%% dispatch (tier_0 / fold ⇒ `not_supported`), and the encode round-trip.

-module(bondy_oplog_crdt_reap_origins_test).

-include_lib("eunit/include/eunit.hrl").

-define(ALIVE, <<"alive">>).
-define(DEAD, <<"dead">>).
-define(OTHER, <<"other">>).

%% =============================================================================
%% mv_register
%% =============================================================================

mv_reap_dominated_origin_test() ->
    M = bondy_oplog_crdt_mv_register,
    %% `alive` holds a live sibling; `dead` advanced its counter but every
    %% value it wrote has been dominated (empty Values) — pure causal
    %% history, the reapable case.
    State = {{[{?ALIVE, 1, [v_alive]}, {?DEAD, 2, []}], []}, 5},
    {State1, Reaped} = M:reap_origins(State, [?DEAD]),
    ?assertEqual([?DEAD], Reaped),
    %% value-preserving: the sibling set is unchanged.
    ?assertEqual(M:to_value(State), M:to_value(State1)),
    %% the context shrank — `dead` is gone.
    ?assertEqual([{?ALIVE, 1}], M:context_of(State1)),
    ?assertEqual([{?ALIVE, 1}, {?DEAD, 2}], M:context_of(State)).

mv_retain_live_origin_test() ->
    M = bondy_oplog_crdt_mv_register,
    %% `dead` is declared retired but still holds a live value — retaining
    %% it is mandatory (that value is real register state).
    State = {{[{?ALIVE, 1, [v_alive]}, {?DEAD, 2, [v_dead]}], []}, 5},
    {State1, Reaped} = M:reap_origins(State, [?DEAD]),
    ?assertEqual([], Reaped),
    ?assertEqual(State, State1),
    ?assertEqual([{?ALIVE, 1}, {?DEAD, 2}], M:context_of(State1)).

mv_reap_absent_origin_is_noop_test() ->
    M = bondy_oplog_crdt_mv_register,
    State = {{[{?ALIVE, 1, [v_alive]}], []}, 5},
    ?assertEqual({State, []}, M:reap_origins(State, [?OTHER])).

mv_reap_only_dominated_subset_test() ->
    M = bondy_oplog_crdt_mv_register,
    %% A mix: `dead` dominated (reapable), `alive` live (retained) — both
    %% named retired; only `dead` is dropped.
    State = {{[{?ALIVE, 1, [v_alive]}, {?DEAD, 2, []}], []}, 5},
    {State1, Reaped} = M:reap_origins(State, [?DEAD, ?ALIVE]),
    ?assertEqual([?DEAD], Reaped),
    ?assertEqual([{?ALIVE, 1}], M:context_of(State1)),
    ?assertEqual(M:to_value(State), M:to_value(State1)).

mv_reap_empty_clock_is_noop_test() ->
    M = bondy_oplog_crdt_mv_register,
    Init = M:init(),
    ?assertEqual({Init, []}, M:reap_origins(Init, [?DEAD])).

mv_reap_encode_roundtrips_test() ->
    M = bondy_oplog_crdt_mv_register,
    State = {{[{?ALIVE, 1, [v_alive]}, {?DEAD, 2, []}], []}, 5},
    {State1, _} = M:reap_origins(State, [?DEAD]),
    ?assertEqual(State1, M:decode_state(M:encode_state(State1))).

%% =============================================================================
%% aw_map
%% =============================================================================

aw_reap_context_only_origin_test() ->
    M = bondy_oplog_crdt_aw_map,
    %% `alive` holds a live dot under k1; `dead` is in the context VV only
    %% (no surviving dot anywhere) — reapable.
    Entries = #{<<"k1">> => #{{?ALIVE, 3} => v1}},
    CC = [{?ALIVE, 3}, {?DEAD, 7}],
    State = {Entries, CC, 9},
    {State1, Reaped} = M:reap_origins(State, [?DEAD]),
    ?assertEqual([?DEAD], Reaped),
    %% value-preserving + the entries (the value carrier) untouched.
    ?assertEqual(M:to_value(State), M:to_value(State1)),
    ?assertEqual([{?ALIVE, 3}], M:context_of(State1)),
    {Entries1, _, _} = State1,
    ?assertEqual(Entries, Entries1).

aw_retain_origin_with_live_dot_test() ->
    M = bondy_oplog_crdt_aw_map,
    %% `dead` is declared retired but still has a live dot under k1 — its
    %% context entry must stay (the dot is a surviving sibling).
    Entries = #{<<"k1">> => #{{?DEAD, 4} => v_dead}},
    CC = [{?DEAD, 4}],
    State = {Entries, CC, 9},
    {State1, Reaped} = M:reap_origins(State, [?DEAD]),
    ?assertEqual([], Reaped),
    ?assertEqual(State, State1).

aw_reap_absent_origin_is_noop_test() ->
    M = bondy_oplog_crdt_aw_map,
    State = {#{<<"k1">> => #{{?ALIVE, 3} => v1}}, [{?ALIVE, 3}], 9},
    ?assertEqual({State, []}, M:reap_origins(State, [?OTHER])).

aw_reap_only_dead_when_alive_has_dot_test() ->
    M = bondy_oplog_crdt_aw_map,
    Entries = #{<<"k1">> => #{{?ALIVE, 3} => v1}},
    CC = [{?ALIVE, 3}, {?DEAD, 7}],
    State = {Entries, CC, 9},
    {State1, Reaped} = M:reap_origins(State, [?DEAD, ?ALIVE]),
    ?assertEqual([?DEAD], Reaped),
    ?assertEqual([{?ALIVE, 3}], M:context_of(State1)).

aw_reap_encode_roundtrips_test() ->
    M = bondy_oplog_crdt_aw_map,
    State = {#{<<"k1">> => #{{?ALIVE, 3} => v1}}, [{?ALIVE, 3}, {?DEAD, 7}], 9},
    {State1, _} = M:reap_origins(State, [?DEAD]),
    ?assertEqual(State1, M:decode_state(M:encode_state(State1))).

%% =============================================================================
%% kernel dispatch
%% =============================================================================

kernel_dispatches_to_tier2_crdt_test() ->
    M = bondy_oplog_crdt_mv_register,
    Kernel = {crdt, M},
    State = {{[{?DEAD, 2, []}], []}, 5},
    ?assertEqual(
        M:reap_origins(State, [?DEAD]),
        bondy_oplog_cell_kernel:reap_origins(Kernel, State, [?DEAD])
    ).

kernel_tier0_crdt_is_not_supported_test() ->
    %% A tier_0 CRDT does not export `reap_origins/2` (its per-origin
    %% entries are value, not disposable bookkeeping).
    ?assertEqual(
        not_supported,
        bondy_oplog_cell_kernel:reap_origins(
            {crdt, bondy_oplog_crdt_g_counter}, ignored_state, [?DEAD]
        )
    ).
