%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PR-B: the kernel/contract extension threads the write's causal context
%% (the event `meta`) to a tier_2 CRDT's `apply_op/4`, while tier_0 CRDTs
%% (which export only `apply_op/3`) stay byte-identical.

-module(bondy_oplog_crdt_context_test).

-include_lib("eunit/include/eunit.hrl").

-define(CM, bondy_oplog_crdt_commutative).
-define(K, bondy_oplog_cell_kernel).
-define(PROBE, bondy_oplog_crdt_ctx_probe).
-define(LWW, bondy_oplog_crdt_lww_register).

ek(H, O, S) -> bondy_oplog_event:key(H, O, S).
ev(H, O, S, Op, Meta) -> bondy_oplog_event:new(ek(H, O, S), Op, Meta).

%% =============================================================================
%% Commutative dispatcher routing
%% =============================================================================

%% A module exporting apply_op/4 receives the context; the 5-arg
%% dispatcher routes to it.
dispatcher_routes_to_apply_op_4_test() ->
    S = ?CM:apply_op(?PROBE, ?PROBE:init(), op1, ek(1, <<"n">>, 1), ctx1),
    ?assertEqual([{op1, ctx1}], S).

%% A tier_0 module exporting only apply_op/3 ignores the context (its
%% /3 clause is called); the 4-arg back-compat dispatcher equals the
%% 5-arg with undefined.
dispatcher_tier0_ignores_context_test() ->
    Key = ek(10, <<"n">>, 1),
    Op = {set, 10, <<"v">>},
    Via4 = ?CM:apply_op(?LWW, ?LWW:init(), Op, Key),
    Via5 = ?CM:apply_op(?LWW, ?LWW:init(), Op, Key, some_ctx),
    ?assertEqual(Via4, Via5),
    ?assertEqual({set, <<"v">>, 10}, Via5).

%% =============================================================================
%% interpret_cog threads the event meta as context
%% =============================================================================

interpret_cog_threads_event_meta_test() ->
    Events = [
        ev(10, <<"n1">>, 1, opA, ctxA),
        ev(20, <<"n2">>, 1, opB, ctxB)
    ],
    S = ?PROBE:interpret_cog(Events, ?PROBE:init()),
    %% Recorded in key order with each event's own meta as context.
    ?assertEqual([{opA, ctxA}, {opB, ctxB}], ?PROBE:to_value(S)).

%% =============================================================================
%% Kernel apply/6 threads context to the crdt branch
%% =============================================================================

kernel_apply6_threads_context_test() ->
    Kernel = {crdt, ?PROBE},
    {NewState, _Hlc, _SB, _VB, _VES} =
        ?K:apply(
            Kernel, ?PROBE:init(), undefined, op1, ek(1, <<"n">>, 1), ctx1
        ),
    ?assertEqual([{op1, ctx1}], NewState).

%% apply/5 (context-free) == apply/6 with undefined context.
kernel_apply5_is_apply6_undefined_test() ->
    Kernel = {crdt, ?PROBE},
    R5 = ?K:apply(Kernel, ?PROBE:init(), undefined, op1, ek(1, <<"n">>, 1)),
    R6 = ?K:apply(
        Kernel, ?PROBE:init(), undefined, op1, ek(1, <<"n">>, 1), undefined
    ),
    ?assertEqual(R5, R6),
    {NewState, _, _, _, _} = R5,
    ?assertEqual([{op1, undefined}], NewState).

%% tier_0 (lww) is byte-identical under apply/6 regardless of context.
kernel_tier0_byte_identical_test() ->
    Kernel = {crdt, ?LWW},
    Old = ?K:init(Kernel),
    Op = {set, 10, <<"v1">>},
    Key = ek(10, <<"n">>, 1),
    R_noctx = ?K:apply(Kernel, Old, undefined, Op, Key),
    R_ctx = ?K:apply(Kernel, Old, undefined, Op, Key, some_ctx),
    ?assertEqual(R_noctx, R_ctx).
