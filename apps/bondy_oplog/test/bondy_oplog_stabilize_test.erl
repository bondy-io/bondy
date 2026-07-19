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
