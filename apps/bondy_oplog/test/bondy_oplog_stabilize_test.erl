%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% `stabilize/2` — causal stabilization in the sense of Baquero, Almeida and
%% Shoker (arXiv:1710.04469 §7.2): what remains of a CRDT state once a timestamp
%% is causally stable, i.e. once no operation older than it can ever be
%% delivered again.
%%
%% For a LWW register the interesting case is the tombstone. `{cleared, H}`
%% exists for exactly one reason — to reject a concurrent `{set, _, H0}` with
%% `H0 < H` that has not yet arrived. Once `H` is stable no such operation can
%% arrive, so the tombstone is pure overhead and the cell is reclaimable. That
%% is what makes projection-cell GC possible; without it a tombstone is retained
%% forever, which is the plum_db outcome the oplog rewrite set out to escape.
%% =============================================================================

-module(bondy_oplog_stabilize_test).

-include_lib("eunit/include/eunit.hrl").

-define(M, bondy_oplog_crdt_lww_register).

%% -----------------------------------------------------------------------------
%% Tombstones become reclaimable once stable
%% -----------------------------------------------------------------------------

tombstone_discarded_once_stable_test() ->
    ?assertEqual(discard, ?M:stabilize(100, {cleared, 50})).

tombstone_kept_while_older_ops_may_still_arrive_test() ->
    %% Not yet stable: an operation at HLC 99 could still be delivered and must
    %% still lose to the clear at 100. Reclaiming here would resurrect it.
    ?assertEqual(keep, ?M:stabilize(50, {cleared, 100})).

%% The boundary is strict. A stability point of exactly `H` does not license
%% discarding a tombstone at `H`: event keys sort `{HLC, Origin, Seq}`, so
%% another key with the SAME HLC and a higher origin may be unconfirmed.
tombstone_at_the_boundary_is_kept_test() ->
    ?assertEqual(keep, ?M:stabilize(100, {cleared, 100})).

%% -----------------------------------------------------------------------------
%% Live values are never discarded
%% -----------------------------------------------------------------------------

live_value_kept_even_when_stable_test() ->
    %% Stability says nothing older can arrive; it does not say the value is
    %% unwanted. Discarding here would be data loss, not reclamation.
    ?assertEqual(keep, ?M:stabilize(100, {set, <<"v">>, 50})),
    ?assertEqual(keep, ?M:stabilize(100, {set, <<"v">>, 100})).

undefined_state_kept_test() ->
    ?assertEqual(keep, ?M:stabilize(100, undefined)).

%% -----------------------------------------------------------------------------
%% Whole-cell removal
%% -----------------------------------------------------------------------------

removal_op_is_clear_test() ->
    ?assertEqual(clear, ?M:removal_op()).

%% A removal must produce a state `stabilize/2` will eventually discard —
%% otherwise `bondy_db:delete/3` could never reclaim anything.
removal_produces_a_reclaimable_state_test() ->
    S0 = ?M:init(),
    %% NOTE the asymmetry: the long-form op is `{set, Hlc, Value}` but the
    %% resulting state is `{set, Value, Hlc}`.
    S = ?M:apply_op(S0, {set, 10, <<"v">>}, <<"k">>),
    ?assertEqual({set, <<"v">>, 10}, S),
    Cleared = ?M:apply_op(S, {clear, 20}, <<"k">>),
    ?assertEqual({cleared, 20}, Cleared),

    %% Invisible to readers immediately...
    ?assertEqual(undefined, ?M:to_value(Cleared)),
    %% ...and physically reclaimable once its HLC is stable.
    ?assertEqual(keep, ?M:stabilize(20, Cleared)),
    ?assertEqual(discard, ?M:stabilize(21, Cleared)).

%% -----------------------------------------------------------------------------
%% Flags (BONDY_DB_RECLAMATION_PROOF.md §9)
%% -----------------------------------------------------------------------------

-define(EW, bondy_oplog_crdt_ew_flag).
-define(DW, bondy_oplog_crdt_dw_flag).

%% A live enable dot is data — kept at ANY stability point.
ew_live_flag_is_kept_test() ->
    S = ?EW:apply_op(?EW:init(), enable, key(10, <<"a">>, 1), undefined),
    ?assert(?EW:to_value(S)),
    ?assertEqual(keep, ?EW:stabilize(1_000_000, S)).

%% A disabled flag (no live dots) is reclaimable once STRICTLY below the
%% stability point; at the boundary it is kept (a dot at exactly StableHlc
%% with a higher origin may be undelivered — pre-barrier, outside A7).
ew_disabled_flag_discarded_once_stable_test() ->
    S0 = ?EW:apply_op(?EW:init(), enable, key(10, <<"a">>, 1), undefined),
    %% The disable OBSERVES the enable (context = the cell's own CC), so the
    %% dot is dropped — enable-wins only protects UN-observed enables.
    S1 = ?EW:apply_op(S0, disable, key(20, <<"a">>, 2), ?EW:context_of(S0)),
    ?assertNot(?EW:to_value(S1)),
    ?assertEqual(keep, ?EW:stabilize(20, S1)),
    ?assertEqual(discard, ?EW:stabilize(21, S1)).

%% A disabled flag whose ops are NOT yet stable is kept: a concurrent enable
%% below the stability point could still arrive and must find the context.
ew_disabled_flag_kept_while_unstable_test() ->
    S0 = ?EW:apply_op(?EW:init(), enable, key(10, <<"a">>, 1), undefined),
    S1 = ?EW:apply_op(S0, disable, key(100, <<"a">>, 2), ?EW:context_of(S0)),
    ?assertEqual(keep, ?EW:stabilize(50, S1)).

%% removal_op + reclaimability: a delete/3 on an ew table is a disable that
%% produces a state stabilize/2 eventually discards.
ew_removal_produces_a_reclaimable_state_test() ->
    ?assertEqual(disable, ?EW:removal_op()),
    S0 = ?EW:apply_op(?EW:init(), enable, key(10, <<"a">>, 1), undefined),
    S1 = ?EW:apply_op(S0, disable, key(20, <<"b">>, 1), ?EW:context_of(S0)),
    ?assertNot(?EW:to_value(S1)),
    ?assertEqual(discard, ?EW:stabilize(21, S1)).

%% dw: a surviving enable is data — kept at ANY stability point.
dw_live_flag_is_kept_test() ->
    S = ?DW:apply_op(?DW:init(), enable, key(10, <<"a">>, 1), undefined),
    ?assert(?DW:to_value(S)),
    ?assertEqual(keep, ?DW:stabilize(1_000_000, S)).

%% dw: disabled (disable-wins) → discard strictly above, keep at boundary.
dw_disabled_flag_discarded_once_stable_test() ->
    S0 = ?DW:apply_op(?DW:init(), enable, key(10, <<"a">>, 1), undefined),
    S1 = ?DW:apply_op(S0, disable, key(20, <<"a">>, 2), ?DW:context_of(S0)),
    ?assertNot(?DW:to_value(S1)),
    ?assertEqual(keep, ?DW:stabilize(20, S1)),
    ?assertEqual(discard, ?DW:stabilize(21, S1)).

%% dw: a disable CONCURRENT with an enable wins (that is the type) — and the
%% resulting false state follows the same reclamation rule.
dw_concurrent_disable_wins_and_reclaims_test() ->
    ?assertEqual(disable, ?DW:removal_op()),
    S0 = ?DW:apply_op(?DW:init(), enable, key(10, <<"a">>, 1), undefined),
    %% Empty context: the disable did NOT observe the enable — concurrent.
    S1 = ?DW:apply_op(S0, disable, key(15, <<"b">>, 1), undefined),
    ?assertNot(?DW:to_value(S1)),
    ?assertEqual(keep, ?DW:stabilize(10, S1)),
    ?assertEqual(discard, ?DW:stabilize(16, S1)).

%% @private
key(Hlc, Origin, Seq) ->
    bondy_oplog_event:key(Hlc, Origin, Seq).
