%% =============================================================================
%% Compaction keeps the MST BOUNDED under sustained writes — the end-to-end
%% validation of the O(diff) read-only stability frontier (task #34).
%%
%% The "runaway" was: each compaction cycle cost O(N) (the O(N) set-LCP
%% frontier fold), so under sustained writes the tree outgrew compaction and
%% the MST grew without bound. With the frontier now O(diff) (and read-only —
%% it walks `bondy_mst:diff_to_list/2`, which no longer mutates the store), the
%% per-cycle cost is governed by the working set, so compaction keeps up and
%% the live MST stays bounded no matter how many events flow through.
%%
%% Two tests:
%%   1. `bounded_under_sustained_load` — many append→compact cycles; assert the
%%      live size never exceeds one batch though far more events flow through.
%%   2. `diff_frontier_bounds_to_recent_batch` — a peer lagging by one batch;
%%      assert the diff-frontier truncates exactly the confirmed prefix and the
%%      live MST is bounded to the unconfirmed batch (exercises the read-only
%%      diff descent against a genuinely-different, reachable peer root).
%% =============================================================================

-module(bondy_oplog_compaction_bounded_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Deterministic: no background sync dispatch, no auto-compaction, no GC
    %% (so a lagging peer root stays reachable for the diff path).
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

%% -----------------------------------------------------------------------------

bounded_under_sustained_load_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {timeout, 60, fun bounded_under_sustained_load/0}}.

bounded_under_sustained_load() ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    {ok, _} = open_instance(InstId, NS, lww_register),
    try
        Iters = 25,
        Batch = 20,
        MaxSize = lists:foldl(
            fun(I, AccMax) ->
                append_batch(InstId, I, Batch),
                _ = bondy_oplog_instance:await_apply(InstId),
                %% Live size after a batch, before compaction.
                SizeBefore = bondy_oplog:size(InstId),
                %% A peer converged to exactly our tree ⇒ frontier = whole
                %% tree ⇒ the stable prefix is dropped each cycle.
                Root = bondy_oplog_instance:root_hash(InstId),
                ?assertMatch(
                    {ok, {compacted, _, _}},
                    bondy_oplog_instance:compact(InstId, [Root])
                ),
                ?assertEqual(0, bondy_oplog:size(InstId)),
                max(AccMax, SizeBefore)
            end,
            0,
            lists:seq(1, Iters)
        ),
        TotalAppended = Iters * Batch,
        %% The tree never accumulated more than one batch, though far more
        %% events flowed through — i.e. compaction kept up (no runaway).
        ?assert(MaxSize =< Batch + 1),
        ?assert(MaxSize * 5 =< TotalAppended),
        ?assertEqual(500, TotalAppended)
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% -----------------------------------------------------------------------------

diff_frontier_bounds_to_recent_batch_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {timeout, 30, fun diff_frontier_bounds_to_recent_batch/0}}.

diff_frontier_bounds_to_recent_batch() ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    {ok, _} = open_instance(InstId, NS, lww_register),
    try
        Batch = 25,
        %% Batch 1: a peer confirms exactly this prefix.
        append_batch(InstId, 1, Batch),
        _ = bondy_oplog_instance:await_apply(InstId),
        PeerRoot = bondy_oplog_instance:root_hash(InstId),

        %% Batch 2: appended locally, NOT yet confirmed by the peer.
        append_batch(InstId, 2, Batch),
        _ = bondy_oplog_instance:await_apply(InstId),
        ?assertEqual(2 * Batch, bondy_oplog:size(InstId)),

        %% The diff-frontier against the lagging peer root descends the
        %% read-only diff to the first unconfirmed (batch-2) event and
        %% truncates exactly the confirmed batch-1 prefix.
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(InstId, [PeerRoot])
        ),
        ?assertEqual(Batch, bondy_oplog:size(InstId)),
        ?assertNotEqual(undefined, bondy_oplog:current_watermark(InstId))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% -----------------------------------------------------------------------------

watermark_reanchored_on_truncated_root_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {timeout, 30, fun watermark_reanchored_on_truncated_root/0}}.

%% Regression for the compaction "runaway under sustained writes" that the
%% durable Fly bench surfaced: the applier's replay cursor
%% (`last_replayed_root`) sits on the PRE-truncate root, then the truncate
%% frees that root's pages. Unless the cursor is re-anchored on the
%% post-truncate (live) root, the NEXT replay's
%% `diff_to_list/2` raises (root gone) and falls back to a full `to_list/1` of
%% the whole tree — an O(N)-per-cycle synchronous fold that starves the applier
%% and stalls writes. This pins the invariant: after a partial-truncate
%% compaction the cursor equals the current (truncated, non-empty) root, so the
%% next diff stays incremental.
watermark_reanchored_on_truncated_root() ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    {ok, _} = open_instance(InstId, NS, lww_register),
    try
        Batch = 25,
        %% Batch 1: a peer confirms exactly this prefix.
        append_batch(InstId, 1, Batch),
        _ = bondy_oplog_instance:await_apply(InstId),
        PeerRoot1 = bondy_oplog_instance:root_hash(InstId),

        %% Batch 2: local, unconfirmed.
        append_batch(InstId, 2, Batch),
        _ = bondy_oplog_instance:await_apply(InstId),

        %% Compact against the lagging peer → truncate batch 1, leave batch 2
        %% (a PARTIAL truncate: the tree is non-empty afterwards).
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(InstId, [PeerRoot1])
        ),
        Root2 = bondy_oplog_instance:root_hash(InstId),
        ?assertEqual(Batch, bondy_oplog:size(InstId)),
        ?assertNotEqual(undefined, Root2),

        %% The applier's replay cursor was re-anchored on the live truncated
        %% root — NOT left on the freed pre-truncate root. The re-anchor is an
        %% async cast (it MUST be, to avoid an instance↔applier deadlock under
        %% load — see `bondy_oplog_applier:advance_replayed_root/2`), so poll.
        ApplierPid = bondy_oplog_registry:applier_pid(InstId),
        ?assert(await_replayed_root(ApplierPid, Root2, 100)),

        %% And the next cycle still works (incremental diff against the live
        %% root): batch 3, peer confirms the full tree, compaction drops it.
        append_batch(InstId, 3, Batch),
        _ = bondy_oplog_instance:await_apply(InstId),
        Root3 = bondy_oplog_instance:root_hash(InstId),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(InstId, [Root3])
        ),
        ?assertEqual(0, bondy_oplog:size(InstId))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% -----------------------------------------------------------------------------

%% =============================================================================
%% Helpers
%% =============================================================================

mk_id() ->
    list_to_binary(
        "cbound_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

register_shard(NS, Index, Shard, FoldModule) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => FoldModule,
        overlay => disabled
    }),
    {Cache, Proj}.

close_shard(Cache, Proj) ->
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

open_instance(InstanceId, NS, FoldModule) ->
    bondy_oplog:start_instance(InstanceId, #{
        origin => bondy_oplog_origin:new(),
        fold_module => FoldModule,
        applier => #{cell_apply_target => {NS, primary, 0}}
    }).

%% Append `Batch` distinct cells under iteration `I`; each is a separate MST
%% event. The lww op timestamp tracks a monotonic counter so values are
%% well-defined, but the MST event order is the instance's own append HLC.
append_batch(InstanceId, I, Batch) ->
    lists:foreach(
        fun(J) ->
            Key = key(I, J),
            Hlc = I * 1000 + J,
            _ = bondy_oplog:append(
                InstanceId, {cell_apply, ?B, Key, {set, Hlc, Key}}
            ),
            _ = bondy_oplog:projection(InstanceId)
        end,
        lists:seq(1, Batch)
    ).

key(I, J) ->
    <<"k_", (integer_to_binary(I))/binary, "_", (integer_to_binary(J))/binary>>.

%% Polls the applier's replay cursor until it reaches `Root` (the re-anchor
%% is an async cast). Returns `true` once it matches, `false` if it never
%% does within `Retries` × 10ms.
await_replayed_root(_ApplierPid, _Root, 0) ->
    false;
await_replayed_root(ApplierPid, Root, Retries) ->
    case bondy_oplog_applier:last_replayed_root(ApplierPid) of
        Root ->
            true;
        _ ->
            timer:sleep(10),
            await_replayed_root(ApplierPid, Root, Retries - 1)
    end.
