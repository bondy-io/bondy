%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Unit tests for the frontier-based, lifecycle-gated sync-status classifier in
%% `bondy_observer_cli_sync`. The classifier decides the per-row Status in the
%% observer_cli "Sync" view from the local instance's applied-frontier signature
%% (`{Frontier, Fingerprint}`) and the peer's (`{frontier, Map, Fingerprint}` or
%% `not_found`). It guards:
%%   - a freshly-wiped node still pulling its initial snapshot must read
%%     `bootstrap`, never IN SYNC (lifecycle gate);
%%   - the topology-fingerprint gate (incomparable keying ⇒ `topo`);
%%   - equal frontiers ⇒ IN SYNC, including two empty frontiers — the case the
%%     MST root could not verify across differing compaction states.
-module(bondy_observer_cli_sync_test).

-include_lib("eunit/include/eunit.hrl").

%% Applied-frontier version vectors (`#{Origin => Seq}`) and topology
%% fingerprints.
-define(F1, #{<<"o1">> => 5, <<"o2">> => 3}).
-define(F2, #{<<"o1">> => 5, <<"o2">> => 4}).
-define(FP1, <<"fp-a">>).
-define(FP2, <<"fp-b">>).

%% Local signature constructor: `{Frontier, Fingerprint}`.
-define(LOCAL(F), {F, ?FP1}).

%% A local instance still bootstrapping is never IN SYNC, regardless of frontiers.
pre_bootstrap_never_in_sync_test() ->
    ?assertEqual(
        bootstrap,
        st(pre_bootstrap, ?LOCAL(?F1), {frontier, ?F1, ?FP1})
    ),
    ?assertEqual(
        bootstrap,
        st(pre_bootstrap, ?LOCAL(#{}), not_found)
    ).

%% An instance not yet registered reports `starting`.
starting_when_lifecycle_unknown_test() ->
    ?assertEqual(
        starting,
        st(undefined, ?LOCAL(?F1), {frontier, ?F1, ?FP1})
    ).

%% An unreachable peer (no signature) reads `no data`.
live_unreachable_peer_no_data_test() ->
    ?assertEqual(no_data, st(live, ?LOCAL(?F1), not_found)),
    ?assertEqual(no_data, st(live, ?LOCAL(#{}), not_found)).

%% Equal frontiers with matching fingerprints converge; including two empty
%% frontiers — the case the MST root could not verify across compaction states.
live_equal_frontiers_in_sync_test() ->
    ?assertEqual(
        in_sync,
        st(live, ?LOCAL(?F1), {frontier, ?F1, ?FP1})
    ),
    ?assertEqual(
        in_sync,
        st(live, {#{}, ?FP1}, {frontier, #{}, ?FP1})
    ).

%% Differing frontiers (same topology) diverge.
live_unequal_frontiers_diverged_test() ->
    ?assertEqual(
        diverged,
        st(live, ?LOCAL(?F1), {frontier, ?F2, ?FP1})
    ).

%% Differing fingerprints (both present) are incomparable: `topo`, never a false
%% IN SYNC/DIVERGED on data.
live_topology_mismatch_test() ->
    ?assertEqual(
        topo,
        st(live, ?LOCAL(?F1), {frontier, ?F1, ?FP2})
    ),
    %% Even equal frontiers across different keying topologies are not "in sync".
    ?assertEqual(
        topo,
        st(live, {?F1, ?FP1}, {frontier, ?F1, ?FP2})
    ).

%% A missing fingerprint (either side) skips the topology gate and compares the
%% frontiers directly (e.g. the inline transport carries no fingerprint).
live_missing_fingerprint_compares_frontiers_test() ->
    ?assertEqual(
        in_sync,
        st(live, {?F1, undefined}, {frontier, ?F1, undefined})
    ),
    ?assertEqual(
        diverged,
        st(live, {?F1, ?FP1}, {frontier, ?F2, undefined})
    ).

%% Every status atom has a human label.
labels_cover_all_statuses_test() ->
    [
        ?assert(is_list(bondy_observer_cli_sync:status_label(S)))
     || S <- [
            in_sync,
            diverged,
            topo,
            bootstrap,
            no_data,
            starting,
            unknown
        ]
    ].

%% @private
st(Life, Local, Peer) ->
    bondy_observer_cli_sync:status(Life, Local, Peer).
