%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PR-G op-replay gate: a LIVE replica re-bootstrapping from a peer must
%% NOT lose a per-Origin-accumulating CRDT's contributions.
%%
%% The catalogue snapshot install is `replace` (skip-if-older by HLC).
%% That is correct for a register (the higher-HLC value wins) but WRONG for
%% a counter: replacing a counter cell with the peer's higher-HLC state
%% drops the contributions of any Origin that state does not carry. What
%% restores them is the post-bootstrap full re-derive (`op-replay`), which
%% re-folds the complete local+peer event set.
%%
%% This pins the convergence: two live replicas each increment the same
%% counter cell under a distinct Origin, then one re-bootstraps from the
%% other. The peer's cell HLC is forced higher so the replace genuinely
%% INSTALLS (clobbers) the local cell (verified: installed=1, not skipped),
%% and the result must still be the SUM. The post-bootstrap op-replay (a
%% full re-fold of the merged MST) is what guarantees this in general,
%% independent of how a cell's events are laid out across MST pages.

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
        {"aw_set, claim B: the installed context misses an unseen local dot",
            {timeout, 30, fun claim_b_install_misses_unseen_dot/0}},
        {"aw_set, a held add folds after a later add that saw it",
            {timeout, 30, fun held_add_folds_after_a_later_add_that_saw_it/0}},
        {"aw_set, a held add folds after its remove",
            {timeout, 30, fun held_add_folds_after_its_remove/0}},
        {"aw_set, a member silent past the peer timeout holds compaction",
            {timeout, 30, fun silent_member_holds_compaction/0}},
        {"aw_set, both sides of a partition keep their own writes",
            {timeout, 30, fun partitioned_pairs_keep_their_writes/0}},
        {"aw_set, a node cut off alone keeps its unsynced write",
            {timeout, 30, fun cut_off_node_keeps_its_unsynced_write/0}},
        {"aw_set, an event a peer drops at its watermark leaves a gap",
            {timeout, 30, fun watermark_door_leaves_a_gap/0}}
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
%% `bondy_oplog_crdt_pn_counter` twin exercises the flipped op-based kernel
%% (the default after PR-G). The rederive mechanism is kernel-agnostic, so
%% both must converge identically.
converges_after_clobber(CrdtMod) ->
    {Peer, _} = setup_counter_instance(CrdtMod),
    {Local, LocalEntry} = setup_counter_instance(CrdtMod),

    %% Each live replica increments the SAME counter cell under its own
    %% Origin. Local writes once; Peer writes TWICE (the second is an HLC-
    %% bumping `+0` no-op), so Peer's cell HLC is deterministically higher
    %% than Local's and wins the skip-if-older `replace` — genuinely
    %% INSTALLING (clobbering) Local's +5 in the projection (installed=1,
    %% not skipped). The post-bootstrap op-replay (full re-fold of the
    %% merged MST) is what guarantees convergence to the SUM in general,
    %% independent of how a cell's events are laid out across MST pages.
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

claim_b_install_misses_unseen_dot() ->
    {Peer, Local, LocalEntry} = local_add_unseen_by_peer(),
    LocalDot = local_dot(Local),
    {error, _} = failing_bootstrap(Local, Peer),
    ?assertEqual([<<"b">>, <<"c">>], aw_set_value(LocalEntry)),
    ?assertNot(installed_context_covers(LocalEntry, LocalDot)),
    teardown(Peer),
    teardown(Local).

%% Local cannot route Origin's first event, so the contiguity hold parks
%% Origin's add of `a` while Writer's later event, whose context covers that
%% add, folds. The add then folds second, once the table is routable.
held_add_folds_after_a_later_add_that_saw_it() ->
    {Local, LocalEntry, ADot} = held_add_after(add, <<"b">>),
    ?assertEqual([<<"b">>], aw_set_value(LocalEntry)),
    ?assert(installed_context_covers(LocalEntry, ADot)),
    ok = register_other_table(Local),
    ?assertEqual([<<"a">>, <<"b">>], aw_set_value(LocalEntry)).

held_add_folds_after_its_remove() ->
    {Local, LocalEntry, _ADot} = held_add_after(rmv, <<"a">>),
    ?assertEqual([], aw_set_value(LocalEntry)),
    ok = register_other_table(Local),
    ?assertEqual([], aw_set_value(LocalEntry)).

%% Returning stops syncing for longer than `peer_timeout_ms` and adds `d`; Peer
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
    ok = application:set_env(bondy_oplog, peer_timeout_ms, 200),
    try
        timer:sleep(300),
        ok = apply_op(Returning, {add, <<"d">>}),
        ok = apply_ctx_op(Peer, {rmv, <<"a">>}),
        ok = apply_op(Peer, {add, <<"c">>}),
        ?assertEqual([<<"c">>], aw_set_value(PeerEntry)),
        ok = converge(Peer, Witness),
        ?assertMatch(
            {ok, {compacted, _, 1}},
            bondy_oplog_test_helpers:compact_among(
                Peer, [Peer, Witness, Returning]
            )
        ),
        ok = converge(Returning, Peer),
        ?assertEqual([<<"c">>, <<"d">>], aw_set_value(PeerEntry)),
        ?assertEqual([<<"c">>, <<"d">>], aw_set_value(ReturningEntry))
    after
        application:unset_env(bondy_oplog, peer_timeout_ms)
    end,
    teardown(Peer),
    teardown(Witness),
    teardown(Returning).

%% Four nodes converge on `s`, then split into two pairs for longer than
%% `peer_timeout_ms`, so each holds a confirmed but stale row for the other
%% pair. Each pair writes and syncs within itself; compaction truncates only
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
    ok = application:set_env(bondy_oplog, peer_timeout_ms, 200),
    try
        timer:sleep(300),
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
        )
    after
        application:unset_env(bondy_oplog, peer_timeout_ms)
    end,
    [teardown(Id) || {Id, _} <- Nodes],
    ok.

%% A node cut off from its only peer truncates what that peer confirmed and
%% keeps the write it accepted alone.
cut_off_node_keeps_its_unsynced_write() ->
    {Lone, LoneEntry} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Peer, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    ok = apply_op(Lone, {add, <<"a">>}),
    ok = converge(Lone, Peer),
    ok = application:set_env(bondy_oplog, peer_timeout_ms, 200),
    try
        timer:sleep(300),
        ok = apply_op(Lone, {add, <<"b">>}),
        ?assertMatch(
            {ok, {compacted, _, 1}},
            bondy_oplog_test_helpers:compact_among(Lone, [Lone, Peer])
        ),
        ?assertEqual(1, bondy_oplog:size(Lone)),
        ?assertEqual([<<"a">>, <<"b">>], aw_set_value(LoneEntry))
    after
        application:unset_env(bondy_oplog, peer_timeout_ms)
    end,
    teardown(Lone),
    teardown(Peer).

%% Replay of `ConfirmedCompaction_RootVV3_Door_NoGap.cfg` on fused instances,
%% every member reachable. Middle compacts its own `b` once Left and Right
%% hold it, then pulls Left's earlier `a`: `a` sorts below Middle's watermark,
%% so the merge applies it and drops it from Middle's tree. Right, which has
%% not seen `a`, must not be told it is behind a peer that cannot ship it.
watermark_door_leaves_a_gap() ->
    {Left, _} = setup_fused_instance(),
    {Middle, _} = setup_fused_instance(),
    {Right, _} = setup_fused_instance(),
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
    ?assertEqual(0, bondy_oplog:size(Middle)),
    ?assertEqual(
        1, maps:get(LeftOrigin, bondy_oplog_instance:frontier(Middle))
    ),
    ?assertEqual(
        0, maps:get(LeftOrigin, bondy_oplog_instance:frontier(Right), 0)
    ),
    ?assertMatch({ok, _}, bondy_oplog_sync_session:run(Right, Middle, #{})),
    teardown(Left),
    teardown(Middle),
    teardown(Right).

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
    {Origin, _} = setup_two_table_instance(),
    {Writer, WriterEntry} = setup_two_table_instance(),
    {Local, LocalEntry} = setup_two_table_instance(),
    _ = bondy_oplog:append(
        Origin, {cell_apply, ?OTHER, <<"k">>, {set, 1, <<"v">>}}
    ),
    ok = apply_op(Origin, {add, <<"a">>}),
    ADot = local_dot(Origin),
    _ = bondy_oplog_sync_session:run(Writer, Origin, #{}),
    ok = drain(Writer),
    ?assertEqual([<<"a">>], aw_set_value(WriterEntry)),
    ok = apply_ctx_op(Writer, {Tag, E}),
    ok = bondy_oplog_applier:unregister_table(
        bondy_oplog_registry:applier_pid(Local), ?OTHER
    ),
    _ = bondy_oplog_sync_session:run(Local, Writer, #{}),
    ok = drain(Local),
    {AOrigin, ASeq} = ADot,
    ?assert(maps:get(AOrigin, bondy_oplog_instance:frontier(Local), 0) < ASeq),
    {Local, LocalEntry, ADot}.

%% An aw_set table at bucket `?B` sharing its instance with an lww table.
setup_two_table_instance() ->
    Id = mk_id(),
    NS = ns_of(Id),
    OtherNS = binary_to_atom(<<"other_", Id/binary>>, utf8),
    ok = register_table_entry(NS, Id, ?B, #{
        fold_module => aw_set, crdt_module => bondy_oplog_crdt_aw_set
    }),
    ok = register_table_entry(OtherNS, Id, ?OTHER, #{
        fold_module => lww_register
    }),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        origin => bondy_oplog_origin:new(),
        applier => #{
            cell_apply_target => {NS, primary, 0}, cell_apply_bucket => ?B
        }
    }),
    ok = bondy_oplog_applier:register_table(
        bondy_oplog_registry:applier_pid(Id), ?OTHER, {OtherNS, primary, 0}, #{}
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
    ok = bondy_oplog_applier:register_table(
        bondy_oplog_registry:applier_pid(Id), ?OTHER, {OtherNS, primary, 0}, #{}
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
    ok = meck:new(bondy_oplog_transport_inline, [passthrough]),
    try
        ok = meck:expect(
            bondy_oplog_transport_inline,
            request,
            fun
                (_, _, get_root, _) -> {error, {partisan_call_failed, timeout}};
                (P, I, R, O) -> meck:passthrough([P, I, R, O])
            end
        ),
        bondy_oplog_sync_session:bootstrap_catalogue(Local, Peer, #{})
    after
        meck:unload(bondy_oplog_transport_inline)
    end.

%% Local writes once, so its origin's entry in the cell's context is the
%% dot of that write.
local_dot(Local) ->
    Origin = bondy_oplog_registry:origin(Local),
    Applier = bondy_oplog_registry:applier_pid(Local),
    {ok, CC} = bondy_oplog_applier:cell_context(Applier, ?B, ?K),
    {Origin, _} = lists:keyfind(Origin, 1, CC).

installed_context_covers(Entry, Dot) ->
    bondy_oplog_crdt_aw_core:dot_observed(
        Dot, bondy_oplog_crdt_aw_set:context_of(aw_set_state(Entry))
    ).

%% Local adds `a` and pulls Peer's `b`; Peer never pulls from Local, and its
%% later `c` gives its cell the higher HLC, so an install replaces Local's.
local_add_unseen_by_peer() ->
    {Peer, _} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
    {Local, LocalEntry} = setup_instance(aw_set, bondy_oplog_crdt_aw_set),
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
    setup_instance(aw_set, bondy_oplog_crdt_aw_set, #{
        fused => true, wal_backend => mem, durability => ephemeral, seed => true
    }).

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
    {ok, _} = bondy_oplog:start_instance(Id, InstanceOpts#{
        %% Distinct per-replica origin: a counter accumulates per Origin, so
        %% two replicas sharing an Origin would collide on `{Origin, Seq}`
        %% and dedup each other's increments (the #11 hazard). The default
        %% in-process origin is shared, so pin a fresh one per instance.
        origin => bondy_oplog_origin:new(),
        applier => #{cell_apply_target => {NS, primary, 0}}
    }),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    {Id, Entry}.

drain(Id) ->
    case bondy_oplog_registry:fused(Id) of
        true -> bondy_oplog:await_apply(Id);
        false -> bondy_oplog_test_projection:drain(Id)
    end.

inc(Id, Delta) ->
    apply_op(Id, {inc, Delta}).

apply_op(Id, Op) ->
    _ = bondy_oplog:append(Id, {cell_apply, ?B, ?K, Op}),
    ok = drain(Id),
    ok.

%% As `bondy_db` writes a tier_2 op: stamped with the cell's current context.
apply_ctx_op(Id, Op) ->
    Applier = bondy_oplog_registry:applier_pid(Id),
    {ok, Ctx} = bondy_oplog_applier:cell_context(Applier, ?B, ?K),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, ?K, Op}, Ctx),
    ok = drain(Id),
    ok.

rederive(Id) ->
    bondy_oplog_applier:rederive_projection_sync(
        bondy_oplog_registry:applier_pid(Id)
    ).

aw_set_value(Entry) ->
    bondy_oplog_crdt_aw_set:to_value(aw_set_state(Entry)).

aw_set_state(Entry) ->
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
    case Adapter:get(Handle, ?B, ?K) of
        not_found ->
            bondy_oplog_crdt_aw_set:init();
        {ok, Frame} ->
            {_Hlc, StateBytes, _ValueBytes} =
                bondy_oplog_cell_frame:decode_full(Frame),
            bondy_oplog_crdt_aw_set:decode_state(StateBytes)
    end.

counter_value(Entry) ->
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
    case Adapter:get(Handle, ?B, ?K) of
        not_found ->
            0;
        {ok, Frame} ->
            {_Hlc, StateBytes, _ValueBytes} =
                bondy_oplog_cell_frame:decode_full(Frame),
            bondy_oplog_crdt_pn_counter:to_value(
                bondy_oplog_crdt_pn_counter:decode_state(StateBytes)
            )
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
