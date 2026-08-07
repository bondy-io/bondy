%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% EUnit coverage for the node-stage liveness policy in `bondy_dealer`.
%%
%% Context: a node's RIB cells outlive the node. Only the node named in the
%% key may write them, so no peer can clear a dead node's registrations, and
%% the node stage of RPC selection would happily keep choosing a corpse — the
%% CALL then times out instead of failing over to a live sibling.
%%
%% The fix filters at selection time, and the property that makes it safe is
%% that it is a PREFERENCE, not an exclusion: it may only replace a candidate
%% that cannot answer with one that might. It must never empty the candidate
%% set, because that would convert a routable call into `no_such_procedure`.
%% These tests pin that invariant, with the environment probe injected so
%% they need no cluster.
-module(bondy_dealer_reachability_test).

-include_lib("eunit/include/eunit.hrl").

-define(LIVE, fun(_) -> true end).
-define(DEAD, fun(_) -> false end).

unit(Id) ->
    {Id, #{count => 1, earliest => 1, latest => 1}}.


%% =============================================================================
%% THE NEVER-EMPTY INVARIANT
%% =============================================================================

%% The load-bearing case. Everything unreachable must yield the ORIGINAL set,
%% not `[]` — `select_node([])` answers `{error, noproc}`, which the dealer
%% reports as `no_such_procedure`. A transient probe failure must not be able
%% to tell a caller that a registered procedure does not exist.
all_unreachable_preserves_the_set_test() ->
    Units = [unit(~"a@x"), unit(~"b@x")],
    ?assertEqual(Units, bondy_dealer:prefer_reachable(Units, ?DEAD)).

empty_stays_empty_test() ->
    ?assertEqual([], bondy_dealer:prefer_reachable([], ?DEAD)).

%% A sole candidate is returned whatever the probe says — and the probe is
%% not consulted at all, which is what keeps the common CALL shape free of
%% ETS reads. The exploding fun asserts the short circuit, not just the value.
sole_candidate_skips_the_probe_test() ->
    Units = [unit(~"a@x")],
    Explode = fun(_) -> erlang:error(probe_must_not_run) end,
    ?assertEqual(Units, bondy_dealer:prefer_reachable(Units, Explode)).


%% =============================================================================
%% THE FILTER ITSELF
%% =============================================================================

drops_the_unreachable_when_a_live_one_remains_test() ->
    Live = unit(~"live@x"),
    Dead = unit(~"dead@x"),
    IsReachable = fun(N) -> N == ~"live@x" end,
    ?assertEqual(
        [Live], bondy_dealer:prefer_reachable([Dead, Live], IsReachable)
    ).

%% Survivors keep their relative order. `select_node/2` sorts before applying
%% an extremal policy, but `single`/`first` tie-break on the base order, so an
%% order-scrambling filter would make selection non-deterministic.
preserves_order_test() ->
    [A, B, C] = [unit(~"a@x"), unit(~"b@x"), unit(~"c@x")],
    IsReachable = fun(N) -> N =/= ~"b@x" end,
    ?assertEqual(
        [A, C], bondy_dealer:prefer_reachable([A, B, C], IsReachable)
    ).

all_reachable_is_identity_test() ->
    Units = [unit(self), unit(~"a@x")],
    ?assertEqual(Units, bondy_dealer:prefer_reachable(Units, ?LIVE)).


%% =============================================================================
%% `self`
%% =============================================================================

%% The local unit is the one candidate that cannot be unreachable — a local
%% win invokes directly rather than sending anything. It must survive even
%% when it is the only survivor, which is the exact shape of "one peer died
%% and this node still has the callee".
self_survives_a_dead_peer_test() ->
    Self = unit(self),
    ?assertEqual(
        [Self],
        bondy_dealer:prefer_reachable(
            [Self, unit(~"dead@x")], fun bondy_dealer:is_reachable/1
        )
    ).

self_is_always_reachable_test() ->
    ?assert(bondy_dealer:is_reachable(self)).


%% =============================================================================
%% THE PROBE
%% =============================================================================

%% A node whose name has never been an atom in this VM has never been
%% connected to, so it is unreachable.
%%
%% Both tests below build the name at runtime: the compiler constant-folds
%% `binary_to_atom/2` over a literal, which would create the atom at compile
%% time and quietly defeat them.
never_connected_node_is_unreachable_test() ->
    ?assertNot(bondy_dealer:is_reachable(fresh_nodestring(?LINE))).

%% RIB cells are replicated data. Resolving their nodestrings with
%% `binary_to_atom/2` would hand a peer a way to grow this node's atom table
%% one registration at a time, so the probe must use the `_existing_` form.
%%
%% Asserted directly rather than through the return value: whether a
%% freshly-minted atom reads reachable depends on how far Partisan gets in a
%% bare VM, so `is_reachable/1` answering `false` is not on its own evidence
%% that no atom was created.
probe_does_not_create_atoms_test() ->
    Nodestring = fresh_nodestring(?LINE),
    ?assertError(badarg, binary_to_existing_atom(Nodestring, utf8)),
    _ = bondy_dealer:is_reachable(Nodestring),
    ?assertError(badarg, binary_to_existing_atom(Nodestring, utf8)).

%% @private
fresh_nodestring(Line) ->
    Suffix = integer_to_binary(erlang:phash2({?MODULE, Line})),
    <<"bondy_never_a_node_", Suffix/binary, "@nowhere.invalid">>.
