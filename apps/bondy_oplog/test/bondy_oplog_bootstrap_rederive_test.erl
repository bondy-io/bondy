%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% A LIVE replica re-bootstrapping from a peer must lose none of its own
%% events and claim none it does not hold.
%%
%% The catalogue install replaces every cell the peer ships, which drops the
%% contributions of any origin the peer's state does not carry. The rederive
%% that follows re-folds the local MST over the installed cells before the
%% peer's frontier is adopted, and a durable re-fold mark carries that duty
%% across a crash. The order, the mark and the serve guard are checked in
%% `proofs/tla/LiveRebootstrapRefold.tla`; these tests replay its
%% counterexamples on the real code.

-module(bondy_oplog_bootstrap_rederive_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
-define(K, <<"counter">>).
-define(OTHER, <<"other">>).

rederive_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"fold path (pn_counter)",
            {timeout, 30, fun() -> converges_after_clobber(undefined) end}},
        {"native crdt path (flipped pn_counter twin)",
            {timeout, 30, fun() ->
                converges_after_clobber(bondy_oplog_crdt_pn_counter)
            end}},
        {"aw_set, trailing round fails",
            {timeout, 30, fun keeps_local_add_when_the_trailing_round_fails/0}},
        {"aw_set, replay folds an add before its remove",
            {timeout, 30, fun replay_folds_add_before_its_remove/0}},
        {"aw_set, rederive over an install keeps a peer remove",
            {timeout, 30, fun rederive_over_install_keeps_peer_remove/0}},
        {"aw_set, a completed re-bootstrap keeps a peer remove",
            {timeout, 30, fun completed_rebootstrap_keeps_peer_remove/0}},
        {"aw_set, claim A: a later round then a rederive keeps a peer remove",
            {timeout, 30, fun claim_a_later_round_then_rederive_remove/0}},
        {"aw_set, claim A: a later round then a rederive keeps a local add",
            {timeout, 30, fun claim_a_later_round_then_rederive_add/0}},
        {"aw_set, claim B: the installed context covers the removed dot",
            {timeout, 30, fun claim_b_install_covers_removed_dot/0}},
        {"aw_set, a held add folds after a later add that saw it",
            {timeout, 30, fun held_add_folds_after_a_later_add_that_saw_it/0}},
        {"aw_set, fused: a rederive holds a dependent of a held add",
            {timeout, 30, fun fused_rederive_holds_a_dependent/0}},
        {"aw_set, a held add folds after its remove",
            {timeout, 30, fun held_add_folds_after_its_remove/0}},
        {"aw_set, a member silent past the peer timeout holds compaction",
            {timeout, 30, fun silent_member_holds_compaction/0}},
        {"aw_set, both sides of a partition keep their own writes",
            {timeout, 30, fun partitioned_pairs_keep_their_writes/0}},
        {"aw_set, a node cut off alone keeps its unsynced write",
            {timeout, 30, fun cut_off_node_keeps_its_unsynced_write/0}},
        {"aw_set, a folded add that re-enters the log stays removed",
            {timeout, 30, fun folded_add_reentering_stays_removed/0}},
        {"aw_set, fused: the door keeps an event a member lacks",
            {timeout, 30, fun fused_door_keeps_what_a_member_lacks/0}},
        {"aw_set, applier: the door keeps an event a member lacks",
            {timeout, 30, fun applier_door_keeps_what_a_member_lacks/0}},
        {"aw_set, applier: a pair that both compacted stops re-shipping",
            {timeout, 30, fun compacted_pair_stops_reshipping/0}},
        {"aw_set, a local cell with the higher HLC still takes the peer's",
            {timeout, 30, fun newer_local_cell_takes_the_peers/0}},
        {"aw_set, a cell the snapshot lacks is pruned",
            {timeout, 30, fun cell_the_snapshot_lacks_is_pruned/0}},
        {"aw_set, fused: a cell the snapshot lacks is pruned",
            {timeout, 30, fun fused_cell_the_snapshot_lacks_is_pruned/0}},
        {"aw_set, an empty source table prunes every cell",
            {timeout, 30, fun empty_source_table_prunes_every_cell/0}},
        {"aw_set, a table the source lacks keeps its cells",
            {timeout, 30, fun table_the_source_lacks_keeps_its_cells/0}},
        {"aw_set, a new install supersedes an earlier one",
            {timeout, 30, fun begin_install_supersedes_an_earlier_one/0}},
        {"aw_set, fused: a new install supersedes an earlier one",
            {timeout, 30, fun fused_begin_install_supersedes_an_earlier_one/0}},
        {"aw_set, durable: a restart supersedes the install",
            {timeout, 60, fun restart_supersedes_the_install/0}},
        {"aw_set, fused: a restart supersedes the install",
            {timeout, 60, fun fused_restart_supersedes_the_install/0}},
        {"aw_set, a restart mid-stream fails the session",
            {timeout, 60, fun restart_mid_stream_fails_the_session/0}},
        {"aw_set, durable: a crash after the stream keeps the local add",
            {timeout, 60, fun crash_after_the_stream_keeps_local_add/0}},
        {"aw_set, durable: a crash before finalize keeps no stale claim",
            {timeout, 60, fun crash_before_finalize_keeps_no_stale_claim/0}},
        {"aw_set, durable: a write after a lost fold keeps the folded add",
            {timeout, 60, fun write_after_lost_fold_keeps_the_add/0}},
        {"aw_set, durable: nothing is served before the boot replay",
            {timeout, 60, fun nothing_served_before_the_boot_replay/0}},
        {"aw_set, a stream that fails once staged keeps the local add",
            {timeout, 30, fun failed_stream_keeps_the_local_add/0}},
        {"aw_set, a failed install write adopts no frontier",
            {timeout, 30, fun failed_install_write_adopts_nothing/0}},
        {"ew_flag, an installed enable stays disabled across a sweep",
            {timeout, 30, fun installed_enable_stays_disabled/0}},
        {"aw_set, a local write after the install keeps an earlier add",
            {timeout, 30, fun local_write_after_install_keeps_earlier_add/0}},
        {"aw_set, fused: a local write after the install keeps an earlier add",
            {timeout, 30,
                fun fused_local_write_after_install_keeps_earlier_add/0}},
        {"aw_set, a replay after the install keeps an earlier add",
            {timeout, 30, fun replay_after_install_keeps_earlier_add/0}},
        {"aw_set, fused: a replay after the install keeps an earlier add",
            {timeout, 30, fun fused_replay_after_install_keeps_earlier_add/0}},
        {"aw_set, a source that is installing refuses to serve",
            {timeout, 30, fun installing_source_refuses_to_serve/0}},
        {"aw_set, a replica serving a snapshot does not install one",
            {timeout, 30, fun serving_replica_does_not_install/0}},
        {"aw_set, an expired cursor does not hold the install",
            {timeout, 30, fun expired_cursor_does_not_hold_the_install/0}},
        {"aw_set, an expired cursor is not renewed after the mark",
            {timeout, 30, fun expired_cursor_is_not_renewed_after_the_mark/0}},
        {"aw_set, a cursor open before the serve check holds the install",
            {timeout, 30,
                fun cursor_open_before_the_serve_check_holds_the_install/0}},
        {"aw_set, an install holds until its claims cover the source",
            {timeout, 30, fun install_holds_until_claims_cover_source/0}},
        {"aw_set, fused: a truncation records what licensed it",
            {timeout, 30, fun truncation_records_the_meet/0}},
        {"aw_set, fused: nothing is truncated while the mark is held",
            {timeout, 30, fun no_truncation_under_the_mark/0}},
        {"aw_set: an install behind the truncation record is refused",
            {timeout, 30, fun install_behind_truncation_is_refused/0}},
        {"aw_set, fused: an install behind the truncation record is refused",
            {timeout, 30, fun fused_install_behind_truncation_is_refused/0}},
        {"aw_set, durable: a restart under the mark keeps a truncated claim",
            {timeout, 60, fun restart_under_the_mark_keeps_truncated_claim/0}}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

%% `CrdtMod = undefined` exercises the legacy fold kernel; the native
%% `bondy_oplog_crdt_pn_counter` twin exercises the op-based kernel. The
%% rederive mechanism is kernel-agnostic, so both must converge identically.
converges_after_clobber(CrdtMod) ->
    {Peer, _} = setup_counter_instance(CrdtMod),
    {Local, LocalEntry} = setup_counter_instance(CrdtMod),

    %% Each live replica increments the SAME counter cell under its own
    %% Origin, so the install replaces Local's +5 with Peer's cell and only
    %% the rederive brings it back.
    ok = inc(Local, 5),
    ok = inc(Peer, 3),
    ok = inc(Peer, 0),

    ?assertEqual(live, bondy_oplog_instance:lifecycle_state(Local)),
    ?assertEqual(5, counter_value(LocalEntry)),

    %% Local re-bootstraps from Peer (replace-install + anti-entropy +
    %% op-replay). The counter must converge to the SUM (5 + 3), proving
    %% both Origins' contributions survived.
    {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(Local, Peer, #{}),
    ?assertEqual(8, counter_value(LocalEntry)),

    teardown(Peer),
    teardown(Local).

%% Local has pulled from Peer once, so its replay cursor is past its own add;
%% Peer never pulled from Local. Peer's later add gives its cell the higher
%% HLC, so the install replaces the local cell and drops the local add. The
%% trailing round then fails as a Partisan call timeout would, and a later
%% live round succeeds: the local add must be visible after it.
keeps_local_add_when_the_trailing_round_fails() ->
    {Peer, Local, LocalEntry} = local_add_unseen_by_peer(),
    {error, _} = failing_bootstrap(Local, Peer),
    {ok, _} = bondy_oplog_sync_session:run(Local, Peer, #{}),
    ok = drain(Local),
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], aw_set_value(LocalEntry)),
    teardown(Peer),
    teardown(Local).

%% Peer adds and then removes `a`; Local pulls both in one round. A replay
%% that folded the remove before the add would resurrect `a`, since an add's
%% dot is re-inserted whatever the cell's context covers.
replay_folds_add_before_its_remove() ->
    {Peer, PeerEntry} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Local, LocalEntry} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    ok = apply_op(Peer, {add, <<"a">>}),
    ok = apply_ctx_op(Peer, {rmv, <<"a">>}),
    ?assertEqual([], aw_set_value(PeerEntry)),
    {ok, _} = bondy_oplog_sync_session:run(Local, Peer, #{}),
    ok = drain(Local),
    ?assertEqual([], aw_set_value(LocalEntry)),
    ok = rederive(Local),
    ?assertEqual([], aw_set_value(LocalEntry)),
    teardown(Peer),
    teardown(Local).

%% Peer removes Local's add and adds `c`; Local re-bootstraps and the
%% trailing round fails, so Local's MST holds the add but not its remove.
%% The installed cell already reflects the remove: a full rederive must not
%% bring `a` back.
rederive_over_install_keeps_peer_remove() ->
    {Peer, Local, LocalEntry} = peer_removes_local_add(),
    {error, _} = failing_bootstrap(Local, Peer),
    ?assertEqual([<<"c">>], aw_set_value(LocalEntry)),
    ok = rederive(Local),
    ?assertEqual([<<"c">>], aw_set_value(LocalEntry)),
    teardown(Peer),
    teardown(Local).

%% As `rederive_over_install_keeps_peer_remove/0`, with a trailing round that
%% succeeds: it pulls the remove into Local's MST before the rederive runs.
completed_rebootstrap_keeps_peer_remove() ->
    {Peer, Local, LocalEntry} = peer_removes_local_add(),
    {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(Local, Peer, #{}),
    ok = drain(Local),
    ?assertEqual([<<"c">>], aw_set_value(LocalEntry)),
    teardown(Peer),
    teardown(Local).

claim_a_later_round_then_rederive_remove() ->
    {Peer, Local, LocalEntry} = peer_removes_local_add(),
    {error, _} = failing_bootstrap(Local, Peer),
    {ok, _} = bondy_oplog_sync_session:run(Local, Peer, #{}),
    ok = drain(Local),
    ?assertEqual([<<"c">>], aw_set_value(LocalEntry)),
    ok = rederive(Local),
    ?assertEqual([<<"c">>], aw_set_value(LocalEntry)),
    teardown(Peer),
    teardown(Local).

claim_a_later_round_then_rederive_add() ->
    {Peer, Local, LocalEntry} = local_add_unseen_by_peer(),
    {error, _} = failing_bootstrap(Local, Peer),
    {ok, _} = bondy_oplog_sync_session:run(Local, Peer, #{}),
    ok = drain(Local),
    ok = rederive(Local),
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], aw_set_value(LocalEntry)),
    teardown(Peer),
    teardown(Local).

claim_b_install_covers_removed_dot() ->
    {Peer, Local, LocalEntry} = peer_removes_local_add(),
    LocalDot = local_dot(Local),
    {error, _} = failing_bootstrap(Local, Peer),
    ?assert(installed_context_covers(LocalEntry, LocalDot)),
    teardown(Peer),
    teardown(Local).

%% Local cannot route Origin's first event, so the contiguity hold parks
%% Origin's add of `a`, and Writer's add of `b`, whose context covers that add,
%% is held with it: nothing folds before what it observed. Once the table is
%% routable both fold, in key order.
held_add_folds_after_a_later_add_that_saw_it() ->
    {Local, LocalEntry, ADot} = held_add_after(add, <<"b">>),
    ?assertEqual([], aw_set_value(LocalEntry)),
    ?assertNot(installed_context_covers(LocalEntry, ADot)),
    ok = register_other_table(Local),
    ?assertEqual([<<"a">>, <<"b">>], aw_set_value(LocalEntry)).

%% On fused instances a rederive while the gap is open folds through the same
%% causal hold, so `b` stays held and `a` is not marked seen ahead of its fold.
fused_rederive_holds_a_dependent() ->
    {Local, LocalEntry, ADot} = held_add_after(add, <<"b">>, fused_opts()),
    ?assertEqual([], aw_set_value(LocalEntry)),
    ok = rederive(Local),
    ?assertEqual([], aw_set_value(LocalEntry)),
    ?assertNot(installed_context_covers(LocalEntry, ADot)),
    ok = register_other_table(Local),
    ok = rederive(Local),
    ?assertEqual([<<"a">>, <<"b">>], aw_set_value(LocalEntry)).

%% Writer's remove of `a` observed Origin's held add, so it is held with it.
held_add_folds_after_its_remove() ->
    {Local, LocalEntry, ADot} = held_add_after(rmv, <<"a">>),
    ?assertEqual([], aw_set_value(LocalEntry)),
    ?assertNot(installed_context_covers(LocalEntry, ADot)),
    ok = register_other_table(Local),
    ?assertEqual([], aw_set_value(LocalEntry)).

%% Returning stops syncing and adds `d`; Peer
%% removes `a`, adds `c` and syncs only with Witness. Returning is still a
%% member, so Peer truncates only `a`, which Returning holds, and Returning
%% catches up by ordinary rounds.
silent_member_holds_compaction() ->
    {Peer, PeerEntry} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Witness, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Returning, ReturningEntry} = setup_instance(
        aw_set, bondy_oplog_crdt_aw_set
    ),
    ok = apply_op(Returning, {add, <<"a">>}),
    ok = converge(Peer, Returning),
    ok = apply_op(Returning, {add, <<"d">>}),
    ok = apply_ctx_op(Peer, {rmv, <<"a">>}),
    ok = apply_op(Peer, {add, <<"c">>}),
    ?assertEqual([<<"c">>], aw_set_value(PeerEntry)),
    ok = converge(Peer, Witness),
    ?assertMatch(
        {ok, {compacted, _, 1}},
        bondy_oplog_test_helpers:compact_among(Peer, [Peer, Witness, Returning])
    ),
    ok = converge(Returning, Peer),
    ?assertEqual([<<"c">>, <<"d">>], aw_set_value(PeerEntry)),
    ?assertEqual([<<"c">>, <<"d">>], aw_set_value(ReturningEntry)),
    teardown(Peer),
    teardown(Witness),
    teardown(Returning).

%% Four nodes converge on `s`, then split into two pairs, so each holds a
%% confirmed but stale row for the other pair. Each pair writes and syncs within itself; compaction truncates only
%% `s`, which the other pair confirmed, and on reconnect ordinary rounds carry
%% both writes everywhere.
partitioned_pairs_keep_their_writes() ->
    Nodes = [
        {Id, Entry}
     || _ <- [a, b, c, d],
        {Id, Entry} <- [setup_instance(aw_set, bondy_oplog_crdt_aw_set)]
    ],
    [{A, _}, {B, _}, {C, _}, {D, _}] = Nodes,
    Cluster = [A, B, C, D],
    ok = apply_op(A, {add, <<"s">>}),
    [ok = converge(X, Y) || _ <- [1, 2], X <- Cluster, Y <- Cluster, X < Y],
    ok = apply_op(A, {add, <<"a">>}),
    ok = converge(A, B),
    ok = apply_op(C, {add, <<"c">>}),
    ok = converge(C, D),
    [
        ?assertMatch(
            {ok, {compacted, _, 1}},
            bondy_oplog_test_helpers:compact_among(Id, Cluster)
        )
     || Id <- Cluster
    ],
    [
        ?assertEqual(synced, repair(X, Y))
     || _ <- [1, 2], X <- Cluster, Y <- [A, C], X =/= Y
    ],
    ?assertEqual(
        [[<<"a">>, <<"c">>, <<"s">>] || _ <- Nodes],
        [aw_set_value(Entry) || {_, Entry} <- Nodes]
    ),
    [teardown(Id) || {Id, _} <- Nodes],
    ok.

%% A node cut off from its only peer truncates what that peer confirmed and
%% keeps the write it accepted alone.
cut_off_node_keeps_its_unsynced_write() ->
    {Lone, LoneEntry} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Peer, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    ok = apply_op(Lone, {add, <<"a">>}),
    ok = converge(Lone, Peer),
    ok = apply_op(Lone, {add, <<"b">>}),
    ?assertMatch(
        {ok, {compacted, _, 1}},
        bondy_oplog_test_helpers:compact_among(Lone, [Lone, Peer])
    ),
    ?assertEqual(1, bondy_oplog:size(Lone)),
    ?assertEqual([<<"a">>, <<"b">>], aw_set_value(LoneEntry)),
    teardown(Lone),
    teardown(Peer).

%% Peer folds Other's add of `a`, removes it, and truncates the add on Other's
%% confirmation. The add comes back on Peer's next pull and, with a member that
%% has not confirmed it, the door keeps it, so the applier's replay is handed an
%% event it has already folded. Folding it again would restore `a`.
folded_add_reentering_stays_removed() ->
    {Peer, PeerEntry} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Other, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    ok = apply_op(Other, {add, <<"a">>}),
    ok = converge(Peer, Other),
    ok = apply_ctx_op(Peer, {rmv, <<"a">>}),
    ?assertEqual([], aw_set_value(PeerEntry)),
    [Witness] = [
        F
     || #{peer := P, frontier := F} <-
            bondy_oplog_peer_state:get_instance_peer_states(Peer, 0),
        P =:= Other
    ],
    ?assertMatch(
        {ok, {compacted, _, 1}}, bondy_oplog_instance:compact(Peer, [Witness])
    ),
    ok = bondy_oplog_test_helpers:with_cluster(
        [Peer, Other, <<"unconfirmed_member">>], fun() -> pull(Peer, Other) end
    ),
    ?assertEqual(2, bondy_oplog:size(Peer)),
    ?assertEqual([], aw_set_value(PeerEntry)),
    teardown(Peer),
    teardown(Other).

%% Replay of the trace by which `ConfirmedCompaction_3R_DoorDrop.cfg` violates
%% `NoGap`, on fused instances, every member reachable. Middle compacts its own
%% `b` once Left and Right hold it, then pulls Left's earlier `a`, which sorts
%% below Middle's watermark. Right has not confirmed `a`, so Middle keeps it and
%% ships it to Right.
fused_door_keeps_what_a_member_lacks() ->
    {Left, _} = setup_fused_instance(),
    {Middle, _} = setup_fused_instance(),
    {Right, RightEntry} = setup_fused_instance(),
    ok = apply_op(Left, {add, <<"a">>}),
    ok = apply_op(Middle, {add, <<"b">>}),
    ok = pull(Left, Middle),
    ok = pull(Right, Middle),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_test_helpers:compact_among(Middle, [Left, Middle, Right])
    ),
    ok = pull(Middle, Left),
    LeftOrigin = bondy_oplog_registry:origin(Left),
    ?assertEqual(
        1, maps:get(LeftOrigin, bondy_oplog_instance:frontier(Middle))
    ),
    ?assert(bondy_oplog:size(Middle) > 0),
    ok = pull(Right, Middle),
    ?assertEqual([<<"a">>, <<"b">>], aw_set_value(RightEntry)),
    teardown(Left),
    teardown(Middle),
    teardown(Right).

%% The same on applier-backed instances, the main database's shape, where the
%% door holds `a` until the applier folds it and the compaction cycle is the
%% next site that may truncate it. Once Right confirms `a`, Middle drops it.
applier_door_keeps_what_a_member_lacks() ->
    {Left, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Middle, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Right, RightEntry} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    Cluster = [Left, Middle, Right],
    bondy_oplog_test_helpers:with_cluster(Cluster, fun() ->
        ok = apply_op(Left, {add, <<"a">>}),
        ok = apply_op(Middle, {add, <<"b">>}),
        ok = pull(Left, Middle),
        ok = pull(Right, Middle),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_test_helpers:compact_among(Middle, Cluster)
        ),
        ok = pull(Middle, Left),
        _ = bondy_oplog_test_helpers:compact_among(Middle, Cluster),
        ?assertEqual(2, bondy_oplog:size(Middle)),
        ok = pull(Right, Middle),
        ?assertEqual([<<"a">>, <<"b">>], aw_set_value(RightEntry)),
        ok = pull(Middle, Right),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_test_helpers:compact_among(Middle, Cluster)
        ),
        ?assertEqual(0, bondy_oplog:size(Middle))
    end),
    teardown(Left),
    teardown(Middle),
    teardown(Right).

%% `ConfirmedCompaction_2R_Async_Live.cfg`: once both members have
%% confirmed `e`, a pull that brings it back below the watermark drops it, so
%% the two trees empty instead of re-shipping `e` to each other.
compacted_pair_stops_reshipping() ->
    {A, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {B, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    Cluster = [A, B],
    bondy_oplog_test_helpers:with_cluster(Cluster, fun() ->
        ok = apply_op(A, {add, <<"e">>}),
        ok = converge(A, B),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_test_helpers:compact_among(A, Cluster)
        ),
        ok = pull(A, B),
        ?assertEqual(0, bondy_oplog:size(A)),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_test_helpers:compact_among(B, Cluster)
        ),
        ok = pull(B, A),
        ok = pull(A, B),
        ?assertEqual({0, 0}, {bondy_oplog:size(A), bondy_oplog:size(B)})
    end),
    teardown(A),
    teardown(B).

%% Local adds `a` after Peer's `b` and never pulls it, so Local's cell has the
%% higher HLC. The re-bootstrap's trailing round fails, so `b` reaches Local
%% only through the install, and Local adopts Peer's frontier, which claims it.
newer_local_cell_takes_the_peers() ->
    {Peer, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Local, LocalEntry} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    ok = apply_op(Peer, {add, <<"b">>}),
    ok = apply_op(Local, {add, <<"a">>}),
    {error, _} = failing_bootstrap(Local, Peer),
    ok = drain(Local),
    ?assertEqual([<<"a">>, <<"b">>], aw_set_value(LocalEntry)),
    teardown(Peer),
    teardown(Local).

%% Local holds cells Peer has none of and no event of Local's log writes, as a
%% cell whose events Peer's sweep reclaimed is left: below Peer's first key,
%% between its two keys, and more than a prune page above its last. The
%% re-bootstrap deletes them all and keeps Peer's two.
cell_the_snapshot_lacks_is_pruned() ->
    cell_the_snapshot_lacks_is_pruned(#{}).

fused_cell_the_snapshot_lacks_is_pruned() ->
    cell_the_snapshot_lacks_is_pruned(fused_opts()).

cell_the_snapshot_lacks_is_pruned(LocalOpts) ->
    {Peer, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Local, LocalEntry} = setup_instance(
        aw_set, bondy_oplog_crdt_aw_set, LocalOpts
    ),
    ok = add_at(Peer, <<"k10">>),
    ok = add_at(Peer, <<"k20">>),
    Above = [<<"k3", (integer_to_binary(N))/binary>> || N <- lists:seq(1, 300)],
    ok = put_stale(LocalEntry, ?B, [<<"k05">>, <<"k15">> | Above]),
    {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(Local, Peer, #{}),
    ?assertEqual([<<"k10">>, <<"k20">>], bucket_keys(LocalEntry, ?B)),
    teardown(Peer),
    teardown(Local).

%% Peer's table holds no cell, so its snapshot ships none, and Local's cell of
%% that table goes.
empty_source_table_prunes_every_cell() ->
    {Peer, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Local, LocalEntry} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    ok = put_stale(LocalEntry, ?B, [<<"k05">>]),
    {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(Local, Peer, #{}),
    ?assertEqual([], bucket_keys(LocalEntry, ?B)),
    teardown(Peer),
    teardown(Local).

%% Local has a table at `?OTHER` that Peer does not, so Peer's snapshot names
%% only `?B`, and Local's `?OTHER` cell stays.
table_the_source_lacks_keeps_its_cells() ->
    {Peer, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Local, _} = setup_two_table_instance(#{}),
    {ok, OtherEntry} = bondy_oplog_core_registry:lookup(
        binary_to_atom(<<"other_", Local/binary>>, utf8), primary, 0
    ),
    ok = put_stale(OtherEntry, ?OTHER, [<<"k05">>]),
    {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(Local, Peer, #{}),
    ?assertEqual([<<"k05">>], bucket_keys(OtherEntry, ?OTHER)),
    teardown(Peer),
    teardown(Local).

%% Local stages Peer's cells and a second install begins before the first
%% re-derives. The first one's token then stages and installs nothing, and
%% the second installs none of what the first staged
%% (`bondy_oplog_applier:open_stage/3`).
begin_install_supersedes_an_earlier_one() ->
    begin_install_supersedes_an_earlier_one(#{}).

fused_begin_install_supersedes_an_earlier_one() ->
    begin_install_supersedes_an_earlier_one(fused_opts()).

begin_install_supersedes_an_earlier_one(LocalOpts) ->
    {Peer, Local, LocalEntry} = local_add_unseen_by_peer(LocalOpts),
    Cells = snapshot_cells(Peer),
    {ok, First} = bondy_oplog_instance:begin_install(Local, [], #{}),
    ok = bondy_oplog_instance:install_catalogue_batch(Local, First, Cells),
    {ok, Second} = bondy_oplog_instance:begin_install(Local, [], #{}),
    ?assertEqual(
        {error, install_superseded},
        bondy_oplog_instance:install_catalogue_batch(Local, First, Cells)
    ),
    ?assertEqual(
        {error, install_superseded},
        bondy_oplog_instance:rederive_projection(Local, First)
    ),
    ?assertMatch(
        {ok, #{installed := 0}},
        bondy_oplog_instance:rederive_projection(Local, Second)
    ),
    ?assertEqual([<<"a">>, <<"b">>], aw_set_value(LocalEntry)),
    teardown(Peer),
    teardown(Local).

%% As above, with a crash instead of a second install: the restarted instance
%% neither installs nor drops what the old token staged.
restart_supersedes_the_install() ->
    with_dir(fun(Dir) -> restart_supersedes_the_install(durable_opts(Dir)) end).

fused_restart_supersedes_the_install() ->
    restart_supersedes_the_install(fused_opts()).

restart_supersedes_the_install(LocalOpts) ->
    {Peer, Local, LocalEntry} = local_add_unseen_by_peer(LocalOpts),
    Cells = snapshot_cells(Peer),
    {ok, Token} = bondy_oplog_instance:begin_install(Local, [], #{}),
    ok = bondy_oplog_instance:install_catalogue_batch(Local, Token, Cells),
    ok = crash(Local),
    ?assertEqual(
        {error, install_superseded},
        bondy_oplog_instance:install_catalogue_batch(Local, Token, Cells)
    ),
    ?assertEqual(
        {error, install_superseded},
        bondy_oplog_instance:rederive_projection(Local, Token)
    ),
    ?assertEqual(
        {error, install_superseded},
        bondy_oplog_instance:abort_install(Local, Token)
    ),
    ok = drain(Local),
    ?assertEqual([<<"a">>, <<"b">>], aw_set_value(LocalEntry)),
    teardown(Peer),
    teardown(Local).

%% Local restarts while its session holds Peer's batch, so the session's
%% install can no longer cover what the restart dropped: the session fails
%% instead of installing what is left and adopting Peer's frontier over it.
restart_mid_stream_fails_the_session() ->
    {Peer, Local, LocalEntry} = local_add_unseen_by_peer(),
    ?assertEqual(
        {error, install_superseded},
        bootstrap_with(Local, Peer, fun
            (Src, {get_catalogue_snapshot_next, _}, Pass) when Src =:= Peer ->
                Reply = Pass(),
                ok = crash(Local),
                Reply;
            (_, _, Pass) ->
                Pass()
        end)
    ),
    ok = drain(Local),
    ?assertEqual([<<"a">>, <<"b">>], aw_set_value(LocalEntry)),
    teardown(Peer),
    teardown(Local).

%% As `keeps_local_add_when_the_trailing_round_fails/0`, on a durable Local whose
%% checkpoint already claims its add, and which crashes once the stream has
%% ended, before the rederive installs what it staged. The restart keeps its
%% own cell, and a re-bootstrap then settles, bringing Peer's add, after which
%% the instance serves again.
crash_after_the_stream_keeps_local_add() ->
    with_dir(fun(Dir) ->
        {Peer, Local, LocalEntry} = local_add_unseen_by_peer(durable_opts(Dir)),
        ok = bondy_oplog_instance:persist_frontier(Local),
        {error, _} = bootstrap_with(Local, Peer, fun
            (Src, {get_catalogue_snapshot_next, _}, Pass) when Src =:= Peer ->
                crash_when_done(Local, Pass());
            (_, _, Pass) ->
                Pass()
        end),
        ok = drain(Local),
        ?assertEqual([<<"a">>, <<"b">>], aw_set_value(LocalEntry)),
        ok = rebootstraps(Local, Peer),
        ?assertEqual([<<"a">>, <<"b">>, <<"c">>], aw_set_value(LocalEntry)),
        teardown(Peer),
        teardown(Local)
    end).

%% Local holds Early's `b` only through an install, and its checkpoint claims
%% it. A second re-bootstrap installs Late's cell, which lacks `b`, and Local
%% crashes before finalizing it. After the restart, Local's frontier must not
%% claim `b` unless its cell has it.
crash_before_finalize_keeps_no_stale_claim() ->
    with_dir(fun(Dir) ->
        {Early, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
        {Late, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
        {Local, LocalEntry} = setup_instance(
            aw_set, bondy_oplog_crdt_aw_set, durable_opts(Dir)
        ),
        ok = apply_op(Early, {add, <<"b">>}),
        {error, _} = failing_bootstrap(Local, Early),
        EarlyOrigin = bondy_oplog_registry:origin(Early),
        ?assertEqual(1, maps:get(EarlyOrigin, frontier(Local), 0)),
        ok = apply_op(Late, {add, <<"c">>}),
        ok = meck:new(bondy_oplog_instance, [passthrough, no_link]),
        try
            ok = meck:expect(
                bondy_oplog_instance,
                finalize_catalogue_bootstrap,
                fun(_, _, _, _) ->
                    crash(Local),
                    {error, crashed}
                end
            ),
            {error, _} = bondy_oplog_sync_session:bootstrap_catalogue(
                Local, Late, #{}
            )
        after
            meck:unload(bondy_oplog_instance)
        end,
        ok = drain(Local),
        ?assert(
            maps:get(EarlyOrigin, frontier(Local), 0) =:= 0 orelse
                lists:member(<<"b">>, aw_set_value(LocalEntry))
        ),
        teardown(Early),
        teardown(Late),
        teardown(Local)
    end).

%% An OS crash loses the projection write of Local's add while its MST and
%% committed WAL offset keep the event, and its claim falls back to the empty
%% checkpoint. Local then takes a write before its boot replay has run, whose
%% dot covers the add's; the add must still be folded
%% (`proofs/tla/JoinInstall_Truncation_CompactMembers_NoRefoldFirst.cfg`).
write_after_lost_fold_keeps_the_add() ->
    with_dir(fun(Dir) ->
        {Local, Entry} = setup_instance(
            aw_set,
            bondy_oplog_crdt_aw_set,
            (durable_opts(Dir))#{
                applier => #{drain_gated => true, commit_every => 1}
            }
        ),
        ok = bondy_oplog_test_helpers:open_gate(Local),
        ok = apply_op(Local, {add, <<"a">>}),
        ok = lose_cell(Local, Entry),
        crash(Local),
        _ = bondy_oplog:append(Local, {cell_apply, ?B, ?K, {add, <<"b">>}}),
        ok = bondy_oplog_test_helpers:open_gate(Local),
        ok = drain(Local),
        ?assertEqual([<<"a">>, <<"b">>], aw_set_value(Entry)),
        teardown(Local)
    end).

%% A crash loses Local's claim on its add but keeps the cell that reflects
%% it. Until the boot replay re-folds the add, a peer installing that cell
%% would adopt a frontier without the add and lose it to a later sweep
%% (`proofs/tla/JoinInstall_Truncation_CompactMembers_NoReplayed.cfg`).
%% Neither a new session, nor one opened before the crash, nor the frontier
%% request is answered until the replay has run. With the claim kept, nothing
%% is owed and the restarted instance serves with its drain still gated.
nothing_served_before_the_boot_replay() ->
    {error, _} = serves_after_crash(fun lose_claims/1),
    ok = serves_after_crash(fun(_) -> ok end).

serves_after_crash(LoseClaim) ->
    with_dir(fun(Dir) ->
        {Local, _Entry} = setup_instance(
            aw_set,
            bondy_oplog_crdt_aw_set,
            (durable_opts(Dir))#{applier => #{drain_gated => true}}
        ),
        ok = bondy_oplog_test_helpers:open_gate(Local),
        ok = apply_op(Local, {add, <<"a">>}),
        {ok, {init, {_W, Cursor, _}}} =
            request(Local, get_catalogue_snapshot_init),
        ok = LoseClaim(Local),
        crash(Local),
        Served = bondy_oplog_instance:serving(Local),
        case Served of
            ok ->
                ?assertMatch(
                    {ok, _}, bondy_oplog_instance:durable_frontier(Local)
                );
            {error, {refold_owed, Local}} = Refused ->
                ?assertEqual(
                    Refused, bondy_oplog_instance:durable_frontier(Local)
                ),
                ?assertEqual(
                    Refused, request(Local, get_catalogue_snapshot_init)
                ),
                ?assertEqual(
                    {error, cursor_expired},
                    request(Local, {get_catalogue_snapshot_next, Cursor})
                ),
                ok = bondy_oplog_test_helpers:open_gate(Local),
                ?assertEqual(ok, bondy_oplog_instance:serving(Local))
        end,
        teardown(Local),
        Served
    end).

%% What an OS crash leaves when it loses the cell's unsynced write: neither
%% the cell, its cached copy, nor the claim on its events.
lose_cell(Id, Entry) ->
    ok = lose_claims(Id),
    ok = bondy_oplog_cell_apply:invalidate_cache(
        bondy_oplog_core_registry:entry_cache_adapter(Entry),
        bondy_oplog_core_registry:entry_cache_handle(Entry),
        ?B,
        ?K
    ),
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    Adapter:delete(
        bondy_oplog_core_registry:entry_projection_handle(Entry), ?B, ?K
    ).

%% The stream fails once every batch is staged, as a source that started its own
%% re-bootstrap would make it. The failed session drops what it staged and its
%% spool, so Local keeps its own cell, and Peer's `c` arrives with the
%% re-bootstrap after which Local serves again.
failed_stream_keeps_the_local_add() ->
    {Peer, Local, LocalEntry} = local_add_unseen_by_peer(),
    Spool = filename:join(
        bondy_oplog_instance_sup:wal_dir(Local, #{}), "catalogue_install.spool"
    ),
    {error, cursor_expired} = bootstrap_with(Local, Peer, fun
        (Src, {get_catalogue_snapshot_next, _}, Pass) when Src =:= Peer ->
            case Pass() of
                {ok, {done, _}} ->
                    ?assert(filelib:is_regular(Spool)),
                    {error, cursor_expired};
                Other ->
                    Other
            end;
        (_, _, Pass) ->
            Pass()
    end),
    ?assertNot(filelib:is_regular(Spool)),
    ok = drain(Local),
    ?assertEqual([<<"a">>, <<"b">>], aw_set_value(LocalEntry)),
    ok = rebootstraps(Local, Peer),
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], aw_set_value(LocalEntry)),
    teardown(Peer),
    teardown(Local).

%% Local's projection refuses the install's first write, and the trailing
%% round would fail too. The session must end on the write error with Local's
%% frontier not claiming Peer's `c`, which its cell lacks, and the re-bootstrap
%% that follows must deliver it.
failed_install_write_adopts_nothing() ->
    {Peer, Local, LocalEntry} = local_add_unseen_by_peer(),
    PeerOrigin = bondy_oplog_registry:origin(Peer),
    Writer = bondy_oplog_registry:applier_pid(Local),
    Writes = atomics:new(1, []),
    ok = meck:new(bondy_oplog_projection_ets, [passthrough, no_link]),
    Result =
        try
            ok = meck:expect(bondy_oplog_projection_ets, put_batch, fun(H, E) ->
                case
                    self() =:= Writer andalso
                        atomics:add_get(Writes, 1, 1) =:= 1
                of
                    true -> {error, injected};
                    false -> meck:passthrough([H, E])
                end
            end),
            failing_bootstrap(Local, Peer)
        after
            meck:unload(bondy_oplog_projection_ets)
        end,
    ok = drain(Local),
    ?assertEqual([<<"a">>, <<"b">>], aw_set_value(LocalEntry)),
    ?assertEqual(1, maps:get(PeerOrigin, frontier(Local), 0)),
    ?assertEqual({error, {projection_write_failed, injected}}, Result),
    ok = rebootstraps(Local, Peer),
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], aw_set_value(LocalEntry)),
    teardown(Peer),
    teardown(Local).

%% Local installs Peer's enabled flag while its MST lacks the enable, since the
%% trailing round fails. Local disables it, and a delivery from Other moves its
%% replay cursor past the disable. Peer pulls the disable, and Local's sweep
%% deletes the empty cell: membership is solo here, so the stability point is
%% a fresh tick, where a cluster would take Peer's receipt of the disable. When
%% the enable then arrives, Local's flag must stay disabled, as Peer's is
%% (`proofs/tla/JoinInstall_Truncation_CompactMembers.cfg` holds
%% `SettledSound`).
installed_enable_stays_disabled() ->
    {Peer, PeerEntry} = setup_instance(ew_flag, bondy_oplog_crdt_ew_flag),
    {Local, LocalEntry} = setup_instance(ew_flag, bondy_oplog_crdt_ew_flag),
    {Other, _} = setup_instance(ew_flag, bondy_oplog_crdt_ew_flag),
    ok = apply_op(Peer, enable),
    {error, _} = failing_bootstrap(Local, Peer),
    ok = drain(Local),
    ?assert(ew_flag_value(LocalEntry)),
    ok = apply_ctx_op(Local, disable),
    _ = bondy_oplog:append(Other, {cell_apply, ?B, <<"elsewhere">>, enable}),
    ok = drain(Other),
    ok = pull(Local, Other),
    ok = pull(Peer, Local),
    ?assertNot(ew_flag_value(PeerEntry)),
    ?assertMatch(
        {ok, #{discarded := 1}},
        bondy_oplog_instance:reclaim_stable_cells(Local)
    ),
    ok = pull(Local, Peer),
    ok = converge(Local, Peer),
    ?assertNot(ew_flag_value(PeerEntry)),
    ?assertNot(ew_flag_value(LocalEntry)),
    teardown(Other),
    teardown(Peer),
    teardown(Local).

%% Local adds `x`, which Source never receives, re-bootstraps from Source, and
%% gains `z` once the stream has ended, before the rederive: by its own write,
%% or by a replay of Other's add, whose context covers `x`. Source's cell, whose
%% context does not cover `x`, is only staged, so `z` folds onto Local's own
%% cell at once; the rederive installs Source's and re-folds both `x` and `z`
%% (`bondy_oplog_applier:stage_cells/3`).
local_write_after_install_keeps_earlier_add() ->
    install_window_keeps_earlier_add(#{}, fun(_) -> ok end, fun write_z/1).

fused_local_write_after_install_keeps_earlier_add() ->
    install_window_keeps_earlier_add(
        fused_opts(), fun(_) -> ok end, fun write_z/1
    ).

replay_after_install_keeps_earlier_add() ->
    replay_after_install_keeps_earlier_add(#{}).

fused_replay_after_install_keeps_earlier_add() ->
    replay_after_install_keeps_earlier_add(fused_opts()).

replay_after_install_keeps_earlier_add(InstanceOpts) ->
    {Other, OtherEntry} = setup_instance(
        aw_set, bondy_oplog_crdt_aw_set, InstanceOpts
    ),
    install_window_keeps_earlier_add(
        InstanceOpts,
        fun(Local) ->
            ok = pull(Other, Local),
            apply_ctx_op(Other, {add, <<"z">>})
        end,
        fun(Local) ->
            {ok, _} = bondy_oplog_sync_session:run(Local, Other, #{}),
            ok
        end
    ),
    ?assertEqual([<<"x">>, <<"z">>], aw_set_value(OtherEntry)),
    teardown(Other).

install_window_keeps_earlier_add(InstanceOpts, Before, InWindow) ->
    {Source, SourceEntry} = setup_instance(
        aw_set, bondy_oplog_crdt_aw_set, InstanceOpts
    ),
    {Local, LocalEntry} = setup_instance(
        aw_set, bondy_oplog_crdt_aw_set, InstanceOpts
    ),
    ok = apply_op(Source, {add, <<"s">>}),
    ok = apply_op(Local, {add, <<"x">>}),
    ok = Before(Local),
    {ok, _} = bootstrap_with(Local, Source, fun
        (Src, {get_catalogue_snapshot_next, _}, Pass) when Src =:= Source ->
            case Pass() of
                {ok, {done, _}} = Done ->
                    ok = InWindow(Local),
                    ok = await(fun() ->
                        aw_set_value(LocalEntry) =:= [<<"x">>, <<"z">>]
                    end),
                    Done;
                Other ->
                    Other
            end;
        (_, _, Pass) ->
            Pass()
    end),
    ok = drain(Local),
    ?assertEqual([<<"s">>, <<"x">>, <<"z">>], aw_set_value(LocalEntry)),
    ok = converge(Local, Source),
    ?assertEqual([<<"s">>, <<"x">>, <<"z">>], aw_set_value(LocalEntry)),
    ?assertEqual([<<"s">>, <<"x">>, <<"z">>], aw_set_value(SourceEntry)),
    teardown(Source),
    teardown(Local).

write_z(Local) ->
    _ = bondy_oplog:append(Local, {cell_apply, ?B, ?K, {add, <<"z">>}}),
    ok.

%% Middle re-bootstraps from Source. From its first batch request, before any
%% cell is installed, another replica can neither open a snapshot on it nor
%% read its frontier (`proofs/tla/JoinInstall.tla`, guard "early"). Once the
%% re-bootstrap has finished and Middle claims Source's frontier, Middle serves
%% again.
installing_source_refuses_to_serve() ->
    {Source, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Middle, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    ok = apply_op(Source, {add, <<"s">>}),
    ok = apply_op(Middle, {add, <<"m">>}),
    Self = self(),
    {ok, _} = bootstrap_with(Middle, Source, fun
        (Src, {get_catalogue_snapshot_next, _}, Pass) when Src =:= Source ->
            Self !
                {served, [
                    request(Middle, get_catalogue_snapshot_init),
                    request(Middle, get_frontier)
                ]},
            Pass();
        (_, _, Pass) ->
            Pass()
    end),
    Served =
        receive
            {served, S} -> S
        after 0 -> error(not_installing)
        end,
    ?assertMatch([{error, _}, {error, _}], Served),
    _ = bondy_oplog:compact(Middle),
    ?assertMatch({ok, {init, _}}, request(Middle, get_catalogue_snapshot_init)),
    teardown(Source),
    teardown(Middle).

%% Middle serves a snapshot it opened to another replica, so it does not start
%% installing one of its own: the open session would read a cell the install
%% has replaced (`proofs/tla/JoinInstall.tla`, guard "busy"), and releases the
%% cursor it opened on Source, which would otherwise hold Source's own install
%% (action `Refuse`). Once that session has finished, Middle re-bootstraps.
serving_replica_does_not_install() ->
    {Source, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Middle, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    ok = apply_op(Source, {add, <<"s">>}),
    ok = apply_op(Middle, {add, <<"m">>}),
    {ok, {init, {_, Opened, _}}} = request(Middle, get_catalogue_snapshot_init),
    ?assertEqual(
        {error, {serving_snapshot, Middle}},
        bondy_oplog_sync_session:bootstrap_catalogue(Middle, Source, #{})
    ),
    ?assertEqual(ok, bondy_oplog_instance:serving(Middle)),
    ?assertNot(bondy_oplog_catalogue_cursor:any_open(Source)),
    ?assertEqual(
        {ok, ok}, request(Source, {release_catalogue_snapshot, Opened})
    ),
    ?assert(bondy_oplog_catalogue_cursor:any_open(Middle)),
    ok = read_to_end(Middle, Opened),
    {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(Middle, Source, #{}),
    teardown(Source),
    teardown(Middle).

%% A session that abandoned its cursor on Middle holds Middle's install only
%% until the cursor expires (`catalogue_cursor_ttl_ms`, here 0).
expired_cursor_does_not_hold_the_install() ->
    {Source, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Middle, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    ok = apply_op(Source, {add, <<"s">>}),
    ok = apply_op(Middle, {add, <<"m">>}),
    ok = application:set_env(bondy_oplog, catalogue_cursor_ttl_ms, 0),
    try
        {ok, {init, _}} = request(Middle, get_catalogue_snapshot_init)
    after
        ok = application:unset_env(bondy_oplog, catalogue_cursor_ttl_ms)
    end,
    {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(Middle, Source, #{}),
    teardown(Source),
    teardown(Middle).

%% A batch request that looked its cursor up just before it expired renews it
%% when it advances. Middle's mark, written once the cursor has expired, must
%% delete it first, so the request ends instead of serving a replica that is
%% installing.
expired_cursor_is_not_renewed_after_the_mark() ->
    {Middle, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    ok = apply_op(Middle, {add, <<"m">>}),
    ok = application:set_env(bondy_oplog, catalogue_cursor_ttl_ms, 0),
    try
        {ok, {init, {_, Cursor, _}}} = request(
            Middle, get_catalogue_snapshot_init
        ),
        {ok, _} = bondy_oplog_instance:begin_install(Middle, [], #{}),
        ?assertEqual(
            not_found, bondy_oplog_catalogue_cursor:advance(Cursor, <<"m">>)
        )
    after
        ok = application:unset_env(bondy_oplog, catalogue_cursor_ttl_ms)
    end,
    teardown(Middle).

%% Middle is suspended while a snapshot opens on it, so the open mints its
%% cursor and waits on the serve check, and an install queued behind that check
%% must see the cursor and refuse; the open is then served.
cursor_open_before_the_serve_check_holds_the_install() ->
    {Middle, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    ok = apply_op(Middle, {add, <<"m">>}),
    Pid = bondy_oplog_instance:whereis(Middle),
    Self = self(),
    ok = sys:suspend(Pid),
    try
        _ = spawn_link(fun() ->
            Self ! {opened, request(Middle, get_catalogue_snapshot_init)}
        end),
        ok = await(fun() -> bondy_oplog_catalogue_cursor:any_open(Middle) end),
        _ = spawn_link(fun() ->
            Self ! {began, bondy_oplog_instance:begin_install(Middle, [], #{})}
        end),
        ok = await(fun() ->
            element(2, erlang:process_info(Pid, message_queue_len)) >= 2
        end)
    after
        ok = sys:resume(Pid)
    end,
    receive
        {opened, Opened} -> ?assertMatch({ok, {init, _}}, Opened)
    end,
    receive
        {began, Began} ->
            ?assertEqual({error, {serving_snapshot, Middle}}, Began)
    end,
    ?assertEqual(ok, bondy_oplog_instance:serving(Middle)),
    teardown(Middle).

%% Source adds `x` after Local has read its frontier and before the stream
%% ships its cell, so Local installs `x` with a frontier that does not claim
%% it, and the trailing round that would pull it fails. Local must refuse to
%% serve, a compaction tick notwithstanding, until it claims Source's frontier
%% as read at finalize, and serve once a pull and a compaction tick have made
%% it claim that frontier
%% (`proofs/tla/JoinInstall_Truncation_CompactMembers_NoTarget.cfg`).
install_holds_until_claims_cover_source() ->
    {Source, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Local, LocalEntry} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    ok = apply_op(Source, {add, <<"s">>}),
    {error, _} = bootstrap_with(Local, Source, fun
        (Src, {get_catalogue_snapshot_next, _}, Pass) when Src =:= Source ->
            ok = apply_op(Source, {add, <<"x">>}),
            Pass();
        (_, get_root, _Pass) ->
            {error, {partisan_call_failed, timeout}};
        (_, _, Pass) ->
            Pass()
    end),
    ok = drain(Local),
    ?assertEqual([<<"s">>, <<"x">>], aw_set_value(LocalEntry)),
    _ = bondy_oplog:compact(Local),
    ?assertEqual(
        {error, {refold_owed, Local}}, bondy_oplog_instance:serving(Local)
    ),
    ok = pull(Local, Source),
    _ = bondy_oplog:compact(Local),
    ?assertEqual(ok, bondy_oplog_instance:serving(Local)),
    teardown(Source),
    teardown(Local).

%% =============================================================================
%% Helpers
%% =============================================================================

%% One round of `Id` against `Peer`, re-bootstrapping on a frontier gap as the
%% sync scheduler does.
repair(Id, Peer) ->
    Path =
        case bondy_oplog_sync_session:run(Id, Peer, #{}) of
            {error, {frontier_gap, _}} ->
                {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(
                    Id, Peer, #{}
                ),
                rebootstrapped;
            _ ->
                synced
        end,
    ok = drain(Id),
    Path.

pull(Id, Peer) ->
    {ok, _} = bondy_oplog_sync_session:run(Id, Peer, #{}),
    ok = drain(Id),
    bondy_oplog_peer_state:sync(),
    ok.

%% Both directions, so each side records the other as a witness.
converge(A, B) ->
    {ok, _} = bondy_oplog_sync_session:run(A, B, #{}),
    ok = drain(A),
    {ok, _} = bondy_oplog_sync_session:run(B, A, #{}),
    ok = drain(B),
    bondy_oplog_peer_state:sync(),
    ok.

%% Origin writes the other table, then adds `a`; Writer pulls both and applies
%% `{Tag, E}` under its context; Local, which cannot route the other table,
%% pulls from Writer. Returns the dot of Origin's add.
held_add_after(Tag, E) ->
    held_add_after(Tag, E, #{}).

held_add_after(Tag, E, InstanceOpts) ->
    {Origin, _} = setup_two_table_instance(InstanceOpts),
    {Writer, WriterEntry} = setup_two_table_instance(InstanceOpts),
    {Local, LocalEntry} = setup_two_table_instance(InstanceOpts),
    _ = bondy_oplog:append(
        Origin, {cell_apply, ?OTHER, <<"k">>, {set, 1, <<"v">>}}
    ),
    ok = apply_op(Origin, {add, <<"a">>}),
    ADot = local_dot(Origin),
    _ = bondy_oplog_sync_session:run(Writer, Origin, #{}),
    ok = drain(Writer),
    ?assertEqual([<<"a">>], aw_set_value(WriterEntry)),
    ok = apply_ctx_op(Writer, {Tag, E}),
    ok = bondy_oplog_instance:unregister_table(Local, ?OTHER),
    _ = bondy_oplog_sync_session:run(Local, Writer, #{}),
    ok = drain(Local),
    {AOrigin, ASeq} = ADot,
    ?assert(maps:get(AOrigin, bondy_oplog_instance:frontier(Local), 0) < ASeq),
    {Local, LocalEntry, ADot}.

%% An aw_set table at bucket `?B` sharing its instance with an lww table.
setup_two_table_instance(InstanceOpts) ->
    Id = mk_id(),
    NS = ns_of(Id),
    OtherNS = binary_to_atom(<<"other_", Id/binary>>, utf8),
    ok = register_table_entry(NS, Id, ?B, #{
        fold_module => aw_set, crdt_module => bondy_oplog_crdt_aw_set
    }),
    ok = register_table_entry(OtherNS, Id, ?OTHER, #{
        fold_module => lww_register
    }),
    {ok, _} = bondy_oplog:start_instance(Id, InstanceOpts#{
        origin => bondy_oplog_origin:new(),
        applier => #{
            cell_apply_target => {NS, primary, 0}, cell_apply_bucket => ?B
        }
    }),
    ok = bondy_oplog_instance:register_table(
        Id, ?OTHER, {OtherNS, primary, 0}, #{}
    ),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    {Id, Entry}.

register_table_entry(NS, Id, Bucket, Kernel) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    bondy_oplog_core_registry:register(NS, primary, 0, Kernel#{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        overlay => disabled,
        instance_id => Id,
        cell_apply_bucket => Bucket
    }).

register_other_table(Id) ->
    OtherNS = binary_to_atom(<<"other_", Id/binary>>, utf8),
    ok = bondy_oplog_instance:register_table(
        Id, ?OTHER, {OtherNS, primary, 0}, #{}
    ),
    drain(Id).

%% Local adds `a`; Peer pulls it, removes it under its context and adds `c`.
peer_removes_local_add() ->
    {Peer, PeerEntry} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Local, LocalEntry} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    ok = apply_op(Local, {add, <<"a">>}),
    {ok, _} = bondy_oplog_sync_session:run(Peer, Local, #{}),
    ok = drain(Peer),
    ok = apply_ctx_op(Peer, {rmv, <<"a">>}),
    ok = apply_op(Peer, {add, <<"c">>}),
    ?assertEqual([<<"c">>], aw_set_value(PeerEntry)),
    {Peer, Local, LocalEntry}.

%% A re-bootstrap whose trailing round fails as a Partisan call timeout would.
failing_bootstrap(Local, Peer) ->
    bootstrap_with(Local, Peer, fun
        (_, get_root, _Pass) -> {error, {partisan_call_failed, timeout}};
        (_, _, Pass) -> Pass()
    end).

%% A re-bootstrap of `Local` from `Peer` in which every transport request is
%% answered by `Hook(Peer, Request, Pass)`, where `Pass()` serves it as usual.
bootstrap_with(Local, Peer, Hook) ->
    ok = meck:new(bondy_oplog_transport_inline, [passthrough]),
    try
        ok = meck:expect(
            bondy_oplog_transport_inline,
            request,
            fun(P, I, R, O) ->
                Hook(P, R, fun() -> meck:passthrough([P, I, R, O]) end)
            end
        ),
        bondy_oplog_sync_session:bootstrap_catalogue(Local, Peer, #{})
    after
        meck:unload(bondy_oplog_transport_inline)
    end.

%% `Id` holds the re-fold mark with no session left to clear it, so it refuses
%% to serve until the re-bootstrap the scheduler dispatches has settled.
rebootstraps(Id, Peer) ->
    ?assert(bondy_oplog_instance:owes_install(Id)),
    ?assertEqual(
        {error, {refold_owed, Id}}, request(Id, get_catalogue_snapshot_init)
    ),
    {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(Id, Peer, #{}),
    ok = drain(Id),
    _ = bondy_oplog:compact(Id),
    ?assertMatch({ok, {init, _}}, request(Id, get_catalogue_snapshot_init)),
    ok.

%% `Request` answered by `Id` as a replica's sync session would see it.
request(Id, Request) ->
    bondy_oplog_transport_inline:request(Id, Id, Request, #{}).

%% Reads the snapshot `Cursor` opened on `Id` until the stream ends.
read_to_end(Id, Cursor) ->
    _ = cells_to_end(Id, Cursor, []),
    ok.

%% Every cell of a snapshot opened on `Id`.
snapshot_cells(Id) ->
    {ok, {init, {_, Cursor, _}}} = request(Id, get_catalogue_snapshot_init),
    cells_to_end(Id, Cursor, []).

cells_to_end(Id, Cursor, Acc) ->
    case request(Id, {get_catalogue_snapshot_next, Cursor}) of
        {ok, {done, _}} -> Acc;
        {ok, {batch, {Next, Cells}}} -> cells_to_end(Id, Next, Acc ++ Cells)
    end.

%% Local holds its seqs 1 and 2; the one peer witness claims only seq 1. The
%% compaction truncates seq 1 alone, and records the witnesses' meet, not
%% Local's own frontier: a record of seq 2 would refuse installs that lose
%% nothing.
truncation_records_the_meet() ->
    {Local, _} = setup_fused_instance(),
    Origin = bondy_oplog_registry:origin(Local),
    ok = apply_op(Local, {add, <<"a">>}),
    ok = apply_op(Local, {add, <<"b">>}),
    ?assertMatch(
        {ok, {compacted, _, 1}},
        bondy_oplog_instance:compact(Local, [#{Origin => 1}])
    ),
    ?assertEqual(#{Origin => 1}, bondy_oplog_registry:truncated(Local)),
    teardown(Local).

%% While an install holds the re-fold mark, neither a confirmed compaction nor
%% an operator truncation cuts or records anything. Once the install's target
%% is claimed, the next compaction clears the mark and truncates.
no_truncation_under_the_mark() ->
    {Local, _} = setup_fused_instance(),
    Origin = bondy_oplog_registry:origin(Local),
    ok = apply_op(Local, {add, <<"a">>}),
    Witnesses = [#{Origin => 1}],
    {ok, Token} = bondy_oplog_instance:begin_install(Local, [], #{}),
    ?assertEqual(
        {ok, no_change}, bondy_oplog_instance:compact(Local, Witnesses)
    ),
    ?assertEqual(
        {error, {refold_owed, Local}},
        bondy_oplog_instance:truncate_prefix(
            Local, bondy_oplog:latest_key(Local)
        )
    ),
    ?assertEqual(1, bondy_oplog:size(Local)),
    ?assertEqual(#{}, bondy_oplog_registry:truncated(Local)),
    {ok, _} = bondy_oplog_instance:rederive_projection(Local, Token),
    ok = bondy_oplog_instance:install_target(Local, #{}),
    ?assertMatch(
        {ok, {compacted, _, 1}}, bondy_oplog_instance:compact(Local, Witnesses)
    ),
    ?assertEqual(#{Origin => 1}, bondy_oplog_registry:truncated(Local)),
    teardown(Local).

%% Local truncates its add on a witness that claims it, but Peer never received
%% it, and Peer's later add replaces Local's cell in an install. Its re-fold
%% would find the add in neither the snapshot nor the tree, so the install is
%% refused before it writes anything, the re-fold mark included.
install_behind_truncation_is_refused() ->
    install_behind_truncation_is_refused(#{}).

fused_install_behind_truncation_is_refused() ->
    install_behind_truncation_is_refused(fused_opts()).

install_behind_truncation_is_refused(LocalOpts) ->
    {Peer, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Local, LocalEntry} = setup_instance(
        aw_set, bondy_oplog_crdt_aw_set, LocalOpts
    ),
    Origin = bondy_oplog_registry:origin(Local),
    ok = apply_op(Local, {add, <<"a">>}),
    ok = apply_op(Peer, {add, <<"b">>}),
    ok = bondy_oplog_instance:persist_frontier(Local),
    ?assertMatch(
        {ok, {compacted, _, 1}},
        bondy_oplog_instance:compact(Local, [#{Origin => 1}])
    ),
    ?assertEqual(
        {error, {source_behind_truncation, #{Origin => 1}}},
        bondy_oplog_sync_session:bootstrap_catalogue(Local, Peer, #{})
    ),
    ?assertEqual([<<"a">>], aw_set_value(LocalEntry)),
    ?assertEqual(1, maps:get(Origin, frontier(Local), 0)),
    ?assertNot(bondy_oplog_instance:owes_install(Local)),
    teardown(Peer),
    teardown(Local).

%% Local truncates its seq 1 on a member's confirmation, begins an install
%% and stops before finishing it, which also drops its registry row. The
%% restart owes a re-fold and resets the frontier, and the tree holds only
%% seq 2, so only the record restored from the checkpoint keeps seq 1
%% claimed; without it, seq 2 sits above a hole and the prefix reads 0.
restart_under_the_mark_keeps_truncated_claim() ->
    with_dir(fun(Dir) ->
        Opts = durable_opts(Dir),
        {Local, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set, Opts),
        Origin = bondy_oplog_registry:origin(Local),
        ok = apply_op(Local, {add, <<"a">>}),
        ok = apply_op(Local, {add, <<"b">>}),
        ok = bondy_oplog_instance:persist_frontier(Local),
        ?assertMatch(
            {ok, {compacted, _, 1}},
            bondy_oplog_instance:compact(Local, [#{Origin => 1}])
        ),
        {ok, _Token} = bondy_oplog_instance:begin_install(
            Local, [], #{Origin => 1}
        ),
        ok = bondy_oplog:stop_instance(Local),
        ?assertEqual(#{}, bondy_oplog_registry:truncated(Local)),
        NS = ns_of(Local),
        {ok, _} = bondy_oplog:start_instance(Local, Opts#{
            origin => Origin,
            applier => #{cell_apply_target => {NS, primary, 0}}
        }),
        ok = drain(Local),
        ?assertEqual(#{Origin => 1}, bondy_oplog_registry:truncated(Local)),
        ?assertEqual(2, maps:get(Origin, frontier(Local), 0)),
        teardown(Local)
    end).

await(Pred) ->
    await(Pred, 500).

await(Pred, 0) ->
    error({timeout, Pred});
await(Pred, N) ->
    case Pred() of
        true ->
            ok;
        false ->
            timer:sleep(10),
            await(Pred, N - 1)
    end.

%% The end of the snapshot stream kills `Id`, as a node crash would between
%% the install and anything that follows it.
crash_when_done(Id, {ok, {done, _}}) ->
    crash(Id),
    {error, crashed};
crash_when_done(_Id, Reply) ->
    Reply.

crash(Id) ->
    Inst = bondy_oplog_instance:whereis(Id),
    Wal = bondy_oplog_registry:wal_pid(Id),
    true = exit(Inst, kill),
    ok = bondy_oplog_test_helpers:await_subtree_restart(Id, Inst, Wal, 10_000).

frontier(Id) ->
    bondy_oplog_instance:frontier(Id).

%% A pack-store instance in `Dir`: its frontier checkpoint survives a crash,
%% and its ETS projection is owned by the test, so its cells do too.
durable_opts(Dir) ->
    #{
        backend => bondy_mst_pack_store,
        storage_path => unicode:characters_to_binary(Dir),
        seed => true
    }.

with_dir(Fun) ->
    Dir = filename:join(["/tmp", os:getpid(), binary_to_list(mk_id())]),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    try
        Fun(Dir)
    after
        _ = file:del_dir_r(Dir)
    end.

%% Local writes once, so its origin's entry in the cell's context is the
%% dot of that write.
local_dot(Local) ->
    Origin = bondy_oplog_registry:origin(Local),
    {ok, CC} = cell_context(Local),
    {Origin, _} = lists:keyfind(Origin, 1, CC).

cell_context(Id) ->
    case bondy_oplog_registry:applier_pid(Id) of
        undefined ->
            bondy_oplog_instance:cell_context(
                bondy_oplog_registry:instance_pid(Id), ?B, ?K
            );
        Applier ->
            bondy_oplog_applier:cell_context(Applier, ?B, ?K)
    end.

installed_context_covers(Entry, Dot) ->
    bondy_oplog_crdt_aw_core:dot_observed(
        Dot, bondy_oplog_crdt_aw_set:context_of(aw_set_state(Entry))
    ).

%% Local adds `a` and pulls Peer's `b`; Peer never pulls from Local, and its
%% later `c` gives its cell the higher HLC, so an install replaces Local's.
local_add_unseen_by_peer() ->
    local_add_unseen_by_peer(#{}).

local_add_unseen_by_peer(LocalOpts) ->
    {Peer, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Local, LocalEntry} = setup_instance(
        aw_set, bondy_oplog_crdt_aw_set, LocalOpts
    ),
    ok = apply_op(Local, {add, <<"a">>}),
    ok = apply_op(Peer, {add, <<"b">>}),
    {ok, _} = bondy_oplog_sync_session:run(Local, Peer, #{}),
    ok = drain(Local),
    ok = apply_op(Peer, {add, <<"c">>}),
    ?assertEqual([<<"a">>, <<"b">>], aw_set_value(LocalEntry)),
    {Peer, Local, LocalEntry}.

setup_counter_instance(CrdtMod) ->
    setup_instance(pn_counter, CrdtMod).

setup_instance(FoldModule, CrdtMod) ->
    setup_instance(FoldModule, CrdtMod, #{}).

%% A registry-shaped instance: fused, in-memory WAL, no applier.
setup_fused_instance() ->
    setup_instance(aw_set, bondy_oplog_crdt_aw_set, fused_opts()).

fused_opts() ->
    #{fused => true, wal_backend => mem, durability => ephemeral, seed => true}.

setup_instance(FoldModule, CrdtMod, InstanceOpts) ->
    Id = mk_id(),
    NS = ns_of(Id),
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    Base = #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        overlay => disabled,
        fold_module => FoldModule
    },
    %% The applier resolves its kernel from the registry entry's
    %% (fold_module, crdt_module): a `crdt_module` selects the native
    %% op-based twin (the flipped default), else the legacy fold.
    RegConfig =
        case CrdtMod of
            undefined -> Base;
            _ -> Base#{crdt_module => CrdtMod}
        end,
    ok = bondy_oplog_core_registry:register(NS, primary, 0, RegConfig),
    Applier = maps:get(applier, InstanceOpts, #{}),
    {ok, _} = bondy_oplog:start_instance(Id, InstanceOpts#{
        %% Distinct per-replica origin: a counter accumulates per Origin, so
        %% two replicas sharing an Origin would collide on `{Origin, Seq}`
        %% and dedup each other's increments (the #11 hazard). The default
        %% in-process origin is shared, so pin a fresh one per instance.
        origin => bondy_oplog_origin:new(),
        applier => Applier#{cell_apply_target => {NS, primary, 0}}
    }),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    {Id, Entry}.

drain(Id) ->
    case bondy_oplog_registry:fused(Id) of
        true -> bondy_oplog:await_apply(Id);
        false -> bondy_oplog_test_projection:drain(Id)
    end.

lose_claims(Id) ->
    bondy_oplog_registry:replace_frontier(Id, #{}).

add_at(Id, Key) ->
    _ = bondy_oplog:append(Id, {cell_apply, ?B, Key, {add, Key}}),
    drain(Id).

%% Writes a cell at each of `Keys` straight into the projection, as no event of
%% the log does.
put_stale(Entry, Bucket, Keys) ->
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
    Frame = bondy_oplog_test_helpers:frame(
        aw_set, bondy_oplog_crdt_aw_set:init(), 1
    ),
    Adapter:put_batch(Handle, [{Bucket, Key, Frame} || Key <- Keys]).

bucket_keys(Entry, Bucket) ->
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
    {ok, Rows} = Adapter:range(Handle, Bucket, <<>>, infinity, #{}),
    [Key || {Key, _Frame} <- Rows].

inc(Id, Delta) ->
    apply_op(Id, {inc, Delta}).

apply_op(Id, Op) ->
    _ = bondy_oplog:append(Id, {cell_apply, ?B, ?K, Op}),
    ok = drain(Id),
    ok.

%% As `bondy_db` writes a tier_2 op: stamped with the cell's current context.
apply_ctx_op(Id, Op) ->
    {ok, Ctx} = cell_context(Id),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, ?K, Op}, Ctx),
    ok = drain(Id),
    ok.

%% A full re-fold: an install with nothing staged.
rederive(Id) ->
    maybe
        {ok, _} ?= bondy_oplog_test_helpers:install(Id, []),
        ok
    end.

aw_set_value(Entry) ->
    bondy_oplog_crdt_aw_set:to_value(aw_set_state(Entry)).

aw_set_state(Entry) ->
    cell_state(bondy_oplog_crdt_aw_set, Entry).

ew_flag_value(Entry) ->
    bondy_oplog_crdt_ew_flag:to_value(
        cell_state(bondy_oplog_crdt_ew_flag, Entry)
    ).

counter_value(Entry) ->
    bondy_oplog_crdt_pn_counter:to_value(
        cell_state(bondy_oplog_crdt_pn_counter, Entry)
    ).

%% An absent cell reads as the CRDT's initial state, as the kernel folds it.
cell_state(Mod, Entry) ->
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
    case Adapter:get(Handle, ?B, ?K) of
        not_found ->
            Mod:init();
        {ok, Frame} ->
            {_Hlc, StateBytes, _ValueBytes} =
                bondy_oplog_cell_frame:decode_full(Frame),
            Mod:decode_state(StateBytes)
    end.

teardown(Id) ->
    bondy_oplog:stop_instance(Id),
    NS = ns_of(Id),
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)],
        N =:= NS
    ],
    ok.

mk_id() ->
    iolist_to_binary([
        "brd_", integer_to_binary(erlang:unique_integer([positive]))
    ]).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).
