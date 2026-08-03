%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% The applier's prepare fence — invariant I1 (prepare-after-deliver, see
%% `bondy_oplog_applier:ensure_remote_caught_up/1` for the invariant and
%% the stability theorem it underwrites) on an applier-backed (non-fused)
%% instance.
%%
%% The window under test: `integrate_peer_root` advances the MST with a
%% peer's events and casts `replay_cell_events` to the applier, but the
%% cast is best-effort and unordered with respect to a client's
%% `cell_context` call (different senders). Without the fence, a context
%% read racing ahead of the replay is served from a projection lagging
%% the replica's own delivered set — minting an op whose causal context
%% under-approximates its causal past (lost causality). The test makes
%% the window deterministic by swallowing the cast trigger outright (the
%% contract already declares it best-effort), then asserts the
%% `cell_context` PREPARE alone brings the projection up to the delivered
%% set before serving.
-module(bondy_db_prepare_fence_test).

-include_lib("eunit/include/eunit.hrl").

-define(MV, bondy_oplog_crdt_mv_register).
-define(R, <<"r">>).
-define(K, <<"k">>).

%% =============================================================================
%% Fixture
%% =============================================================================

prepare_fence_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"cell_context reflects delivered-but-unreplayed remote events",
                {timeout, 60, fun remote_delivery_fences_cell_context/0}}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% No background AE or GC: the test controls sync explicitly, and a
    %% scheduler-driven round would heal the projection behind the
    %% swallowed cast, hiding the very window under test.
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

%% =============================================================================
%% Test
%% =============================================================================

remote_delivery_fences_cell_context() ->
    {DbA, TA, InstA} = open(fence_a),
    {DbB, TB, InstB} = open(fence_b),

    %% B authors a tier_2 event and applies it locally.
    ok = bondy_db:apply(TB, ?R, ?K, {set, <<"bval">>}),
    _ = bondy_oplog_instance:await_apply(InstB),

    %% Swallow the integrate handler's replay trigger — simulating the
    %% cast in flight (or lost; it is best-effort by contract) at the
    %% moment a client prepares an op. The sync session's frontier-gap
    %% settle barrier (`bondy_oplog_applier:barrier/1`) would heal this
    %% exact window before the session returns, so it is swallowed too —
    %% the fence under test here is the one at the PREPARE
    %% (`cell_context`), and it must hold with no other healer running.
    %% Only the public wrappers are stubbed; the fence's own catch-up
    %% runs through the applier's internal replay path and is unaffected.
    ok = meck:new(bondy_oplog_applier, [passthrough]),
    ok = meck:expect(bondy_oplog_applier, replay_cell_events, fun(_) ->
        ok
    end),
    ok = meck:expect(bondy_oplog_applier, barrier, fun(_) ->
        ok
    end),
    try
        %% A pulls B's event: it is now DELIVERED at A (in A's MST, the
        %% remote-delivery generation bumped) but NOT in A's projection
        %% (the replay cast was swallowed). With the whole local settle
        %% stubbed out, the session's frontier-gap check correctly judges
        %% A's projection behind B's installed-consistent frontier — the
        %% session reports the gap, and the pages are integrated
        %% regardless (the gap verdict follows the completed pull).
        ?assertMatch(
            {error, {frontier_gap, _}}, bondy_oplog:sync(InstA, InstB)
        ),
        ?assertMatch({error, not_found}, bondy_db:read(TA, ?R, ?K)),

        %% I1: the PREPARE must reflect every delivered event. The
        %% fence detects the generation gap, catches the projection up,
        %% and only then serves the context — which therefore covers
        %% B's dot (a non-empty version vector for a cell whose only
        %% event is B's).
        APid = bondy_oplog_registry:applier_pid(InstA),
        ?assert(is_pid(APid)),
        Bucket = atom_to_binary(items, utf8),
        CellKey = <<?R/binary, 0, ?K/binary>>,
        {ok, Ctx} = bondy_oplog_applier:cell_context(APid, Bucket, CellKey),
        ?assertMatch([{_, _} | _], Ctx),

        %% And the projection itself is caught up as a consequence.
        ?assertEqual({ok, [<<"bval">>], read_hlc}, norm(bondy_db:read(TA, ?R, ?K)))
    after
        meck:unload(bondy_oplog_applier)
    end,

    ok = bondy_db:close(DbA),
    ok = bondy_db:close(DbB).

%% =============================================================================
%% Helpers
%% =============================================================================

open(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        crdt_module => ?MV,
        oplog_instance_opts => #{origin => Origin}
    }),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    InstanceId = maps:get(0, maps:get(instance_ids, T)),
    {Db, T, InstanceId}.

norm({ok, {V, _Hlc}}) -> {ok, V, read_hlc};
norm(Other) -> Other.
