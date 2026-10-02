%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Tests for `bondy_oplog_cell_kernel` — the per-cell projection kernel.
%% Since PR-Z the kernel is CRDT-only: `from_modules/2` resolves a former
%% `fold_module` label to its native CRDT twin (or errors for an unknown
%% label), and the eager step / read seam run the op-based CRDT. Verifies
%% the selector + resolution, that the CRDT branch maintains the
%% materialised value via the commutative O(1) step, the COG read seam, and
%% that a non-commutative CRDT is refused on the eager path.

-module(bondy_oplog_cell_kernel_test).

-include_lib("eunit/include/eunit.hrl").

-define(K, bondy_oplog_cell_kernel).
-define(LWW, bondy_oplog_crdt_lww_register).
-define(BC, bondy_oplog_crdt_bounded_counter).

ek(H, O, S) ->
    bondy_oplog_event:key(H, O, S).

ev(H, O, S, Op) ->
    bondy_oplog_event:new(ek(H, O, S), Op, #{}).

%% =============================================================================
%% Selector + fold-label resolution
%% =============================================================================

from_modules_prefers_crdt_test() ->
    ?assertEqual({crdt, ?LWW}, ?K:from_modules(lww_register, ?LWW)).

from_modules_resolves_fold_label_test() ->
    %% A former `fold_module` label resolves to its native CRDT twin.
    ?assertEqual({crdt, ?LWW}, ?K:from_modules(lww_register, undefined)),
    ?assertEqual(
        {crdt, ?LWW}, ?K:from_modules(bondy_oplog_fold_lww_register, undefined)
    ).

from_modules_unknown_label_errors_test() ->
    ?assertError(
        {unknown_cell_module, no_such_fold},
        ?K:from_modules(no_such_fold, undefined)
    ).

default_crdt_for_fold_test() ->
    ?assertEqual(?LWW, ?K:default_crdt_for_fold(lww_register)),
    ?assertEqual(
        bondy_oplog_crdt_index_entry, ?K:default_crdt_for_fold(index_entry)
    ),
    ?assertEqual(undefined, ?K:default_crdt_for_fold(no_such_fold)).

%% =============================================================================
%% Dispatch of init / decode_state / encode_state / to_value
%% =============================================================================

init_dispatch_test() ->
    ?assertEqual(undefined, ?K:init({crdt, ?LWW})).

decode_state_dispatch_test() ->
    Bytes = ?LWW:encode_state({set, <<"v">>, 5}),
    ?assertEqual({set, <<"v">>, 5}, ?K:decode_state({crdt, ?LWW}, Bytes)).

%% State bytes reaching decode_state are this node's own projection frames —
%% peer state arrives as terms via the sync transport, never as bytes here
%% (measured: `bondy_aae_cluster_SUITE` runtime-atom cases). So the decode is
%% PLAIN per the C-2 own-bytes rule: an atom present only as ETF bytes — the
%% post-restart state, when no loaded module names it and its event was
%% compacted out of the log — must decode (re-interning it), not be refused.
own_bytes_decode_state_interns_own_atom_test() ->
    %% Hand-built ETF for a small UTF-8 atom (tag 119 = SMALL_ATOM_UTF8_EXT).
    %% The name appears here only as binary bytes, so loading this test never
    %% interns it — proven by the existing_atom probe below.
    Name = <<"bondy_f4_uninterned_atom_qwertyz">>,
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
    ValueBytes = <<131, 119, (byte_size(Name)):8, Name/binary>>,
    %% Wrap it in an LWW `set` state envelope (<<1, Hlc:64, ValueBytes>>).
    Crafted = <<1, 5:64/big-unsigned, ValueBytes/binary>>,
    ?assertMatch(
        {set, V, 5} when is_atom(V), ?K:decode_state({crdt, ?LWW}, Crafted)
    ),
    {set, Atom, 5} = ?K:decode_state({crdt, ?LWW}, Crafted),
    ?assertEqual(Name, atom_to_binary(Atom, utf8)),

    Legit = ?LWW:encode_state({set, <<"v">>, 5}),
    ?assertEqual({set, <<"v">>, 5}, ?K:decode_state({crdt, ?LWW}, Legit)).

encode_state_dispatch_test() ->
    State = {set, <<"v">>, 5},
    ?assertEqual(
        ?LWW:encode_state(State), ?K:encode_state({crdt, ?LWW}, State)
    ).

to_value_dispatch_test() ->
    ?assertEqual(<<"v">>, ?K:to_value({crdt, ?LWW}, {set, <<"v">>, 5})).

%% =============================================================================
%% CRDT branch — apply maintains the materialised value
%% =============================================================================

crdt_apply_sets_value_test() ->
    Kernel = {crdt, ?LWW},
    Old = ?K:init(Kernel),
    {NewState, Hlc, StateBytes, ValueBytes, VES} =
        ?K:apply(
            Kernel, Old, undefined, {set, 10, <<"v1">>}, ek(10, <<"n1">>, 1)
        ),
    ?assertEqual({set, <<"v1">>, 10}, NewState),
    ?assertEqual(10, Hlc),
    ?assertEqual(?LWW:encode_state(NewState), StateBytes),
    ?assertEqual(false, VES),
    %% The value column is term_to_binary(to_value(NewState)).
    ?assertEqual(term_to_binary(<<"v1">>), ValueBytes).

crdt_apply_threads_old_state_test() ->
    Kernel = {crdt, ?LWW},
    {S1, _, _, _, _} =
        ?K:apply(
            Kernel,
            undefined,
            undefined,
            {set, 10, <<"v1">>},
            ek(10, <<"n1">>, 1)
        ),
    %% A lower-HLC set must be rejected (LWW); the state is unchanged.
    {S2, _, _, V2, _} =
        ?K:apply(
            Kernel,
            S1,
            term_to_binary(<<"v1">>),
            {set, 5, <<"old">>},
            ek(5, <<"n2">>, 1)
        ),
    ?assertEqual(S1, S2),
    ?assertEqual(term_to_binary(<<"v1">>), V2).

%% =============================================================================
%% Non-commutative CRDT is refused on the eager path (deferred)
%% =============================================================================

non_commutative_crdt_is_refused_test() ->
    Kernel = {crdt, ?BC},
    ?assertError(
        {non_commutative_crdt_eager_unsupported, ?BC},
        ?K:apply(Kernel, ?BC:init(), undefined, {inc, 1}, ek(10, <<"n1">>, 1))
    ).

%% =============================================================================
%% Read seam — interpret_overlay/4 (the operation-based overlay merge)
%% =============================================================================

%% The CRDT branch interprets the overlay group via `interpret_cog`, NOT a
%% per-event arrival-order fold. Highest-HLC wins, and — the proof it is a
%% COG interpretation — reversing the event list yields the SAME state.
interpret_overlay_crdt_interprets_cog_test() ->
    Kernel = {crdt, ?LWW},
    Init = ?K:init(Kernel),
    Events = [
        ev(10, <<"n1">>, 1, {set, 10, <<"a">>}),
        ev(30, <<"n2">>, 1, {set, 30, <<"c">>}),
        ev(20, <<"n1">>, 2, {set, 20, <<"b">>})
    ],
    {S1, H1} = ?K:interpret_overlay(Kernel, Init, 0, Events),
    ?assertEqual(<<"c">>, ?LWW:to_value(S1)),
    ?assertEqual(30, H1),
    {S2, H2} = ?K:interpret_overlay(Kernel, Init, 0, lists:reverse(Events)),
    ?assertEqual(S1, S2),
    ?assertEqual(H1, H2).

%% Overlay events carry `{cell_apply, Bucket, Key, Op}` ops in production;
%% the CRDT branch unwraps them (via `interpret_cog` -> `op_of/1`).
interpret_overlay_crdt_unwraps_cell_apply_test() ->
    Kernel = {crdt, ?LWW},
    Init = ?K:init(Kernel),
    Events = [
        ev(10, <<"n1">>, 1, {cell_apply, <<>>, <<"k">>, {set, 10, <<"a">>}}),
        ev(20, <<"n2">>, 1, {cell_apply, <<>>, <<"k">>, {set, 20, <<"b">>}})
    ],
    {S, H} = ?K:interpret_overlay(Kernel, Init, 0, Events),
    ?assertEqual(<<"b">>, ?LWW:to_value(S)),
    ?assertEqual(20, H).

%% An empty overlay group returns the base state unchanged with the
%% passed-in HLC.
interpret_overlay_empty_passes_through_test() ->
    ?assertEqual(
        {undefined, 7}, ?K:interpret_overlay({crdt, ?LWW}, undefined, 7, [])
    ).

%% =============================================================================
%% Read seam — decode_value_bytes/2
%% =============================================================================

%% LWW has `value_equals_state -> false`, so the value column is
%% `term_to_binary(Value)`; the crdt branch reproduces it.
decode_value_bytes_roundtrips_test() ->
    Bytes = term_to_binary(<<"v">>),
    ?assertEqual(<<"v">>, ?K:decode_value_bytes({crdt, ?LWW}, Bytes)).
