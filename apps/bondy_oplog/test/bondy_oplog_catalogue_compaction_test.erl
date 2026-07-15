%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Catalogue (projection-backed) compaction — COG_REGROUNDING_PLAN.md
%% §8.2, PR-2 step 1 (α: bound the catalogue MST).
%%
%% Before this change a fold-backed catalogue instance had
%% `crdt_module = undefined`, so `do_compact_async` returned
%% `{error, no_crdt_module}` and the catalogue MST grew unbounded. Now a
%% catalogue instance compacts by truncating the MST's stable prefix —
%% the materialised state lives in the durable projection, so the
%% compaction checkpoint records only the watermark.
%%
%% The new correctness condition (vs. the monolithic `crdt_module` path,
%% which is self-contained) is that truncation must NOT outrun the
%% async projection: a peer-merged event can be in the MST (and thus in
%% the stability frontier) but not yet folded into the projection by the
%% applier. Truncation is therefore capped at the projection's applied
%% high-water. These tests pin both halves:
%%
%%   1. With a projection that has folded every event (await_apply →
%%      high-water covers the frontier), compaction truncates the MST to
%%      empty and reads stay correct (the projection is the durable read
%%      source, untouched by truncation).
%%   2. Without a projection (no `cell_apply_target` → high-water 0),
%%      compaction is *enabled* (not `{error, no_crdt_module}`) but the
%%      safe gate defers truncation — there is no projection holding the
%%      state, so removing MST events would lose data.

-module(bondy_oplog_catalogue_compaction_test).

-include_lib("eunit/include/eunit.hrl").

%% Default cell bucket — substrate `read/3` aliases land on `<<>>`.
-define(B, <<>>).
-define(CRDT, bondy_oplog_crdt_lww_register).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Deterministic: no background sync dispatch, no auto-compaction.
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

catalogue_compaction_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun truncates_and_preserves_reads/0},
        {timeout, 30, fun idempotent_after_truncation/0},
        {timeout, 30, fun no_projection_defers_truncation/0},
        {timeout, 30, fun neither_fold_nor_crdt_returns_error/0},
        {timeout, 30, fun crdt_kernel_compaction_matches_from_scratch/0},
        {timeout, 30, fun remote_event_survives_catalogue_compaction/0},
        {timeout, 30, fun async_catch_up_uses_cast_not_sync_calls/0}
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

%% A catalogue with a projection that has folded every event: a peer
%% converged to exactly our tree makes the stability frontier the whole
%% tree, capped at the applied high-water (which covers every applied
%% cell), so compaction truncates the MST to empty. Reads are unchanged
%% — including a key first read *after* truncation, which can only come
%% from the projection — and new writes still work post-compaction.
truncates_and_preserves_reads() ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    {ok, _} = open_instance(InstId, NS, bondy_oplog_origin:new(), lww_register),
    try
        ok = append_cell(InstId, <<"a">>, 10, <<"v-a">>),
        ok = append_cell(InstId, <<"b">>, 20, <<"v-b">>),
        ok = append_cell(InstId, <<"c">>, 30, <<"v-c">>),
        %% Drain into the projection so the applier advances the
        %% per-shard high-water (the safe-truncation cap).
        _ = bondy_oplog_instance:await_apply(InstId),
        %% Read two keys pre-compaction (these warm the read cache).
        %% `<<"b">>` is deliberately left unread until after truncation.
        ?assertEqual(
            {<<"v-a">>, 10}, bondy_oplog_core:read(NS, primary, <<"a">>)
        ),
        ?assertEqual(
            {<<"v-c">>, 30}, bondy_oplog_core:read(NS, primary, <<"c">>)
        ),
        ?assert(bondy_oplog:size(InstId) >= 3),

        %% A peer converged to exactly our tree: frontier = whole tree.
        Root = bondy_oplog_instance:root_hash(InstId),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(InstId, [Root])
        ),
        %% MST is bounded — the stable prefix is gone.
        ?assertEqual(0, bondy_oplog:size(InstId)),
        ?assertNotEqual(undefined, bondy_oplog:current_watermark(InstId)),

        %% Reads survive truncation. `<<"b">>` was never read, so it is
        %% not cached: a correct value here proves the projection (not
        %% the cache) served it AND that truncation left it intact.
        ?assertEqual(
            {<<"v-b">>, 20}, bondy_oplog_core:read(NS, primary, <<"b">>)
        ),
        ?assertEqual(
            {<<"v-a">>, 10}, bondy_oplog_core:read(NS, primary, <<"a">>)
        ),
        ?assertEqual(
            {<<"v-c">>, 30}, bondy_oplog_core:read(NS, primary, <<"c">>)
        ),

        %% The instance is fully functional after compaction: a new
        %% write lands in the projection and is readable.
        ok = append_cell(InstId, <<"d">>, 40, <<"v-d">>),
        _ = bondy_oplog_instance:await_apply(InstId),
        ?assertEqual(
            {<<"v-d">>, 40}, bondy_oplog_core:read(NS, primary, <<"d">>)
        )
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% A second compaction with no new stable events advances nothing.
idempotent_after_truncation() ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    {ok, _} = open_instance(InstId, NS, bondy_oplog_origin:new(), lww_register),
    try
        ok = append_cell(InstId, <<"k">>, 5, <<"v">>),
        _ = bondy_oplog_instance:await_apply(InstId),
        Root = bondy_oplog_instance:root_hash(InstId),
        {ok, {compacted, W1, _}} =
            bondy_oplog_instance:compact(InstId, [Root]),
        ?assertEqual(0, bondy_oplog:size(InstId)),
        %% Nothing new to compact ⇒ no_change, watermark unchanged.
        ?assertEqual(
            {ok, no_change},
            bondy_oplog_instance:compact(InstId, [Root])
        ),
        ?assertEqual(W1, bondy_oplog:current_watermark(InstId))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% A fold instance with NO projection wiring: the applied high-water is
%% 0, so the safe gate refuses to truncate (removing MST events would
%% lose state with no projection to hold it). Compaction is enabled —
%% it returns `{ok, no_change}`, NOT `{error, no_crdt_module}`.
no_projection_defers_truncation() ->
    InstId = mk_id(),
    {ok, _} = bondy_oplog:start_instance(InstId, #{
        origin => bondy_oplog_origin:new(),
        fold_module => lww_register
    }),
    try
        _ = bondy_oplog:append(
            InstId, {cell_apply, ?B, <<"k">>, {set, 1, <<"v">>}}
        ),
        _ = bondy_oplog:append(
            InstId, {cell_apply, ?B, <<"k2">>, {set, 2, <<"v2">>}}
        ),
        _ = bondy_oplog_instance:await_apply(InstId),
        SizeBefore = bondy_oplog:size(InstId),
        ?assert(SizeBefore >= 2),
        Root = bondy_oplog_instance:root_hash(InstId),
        ?assertEqual(
            {ok, no_change},
            bondy_oplog_instance:compact(InstId, [Root])
        ),
        ?assertEqual(SizeBefore, bondy_oplog:size(InstId)),
        ?assertEqual(undefined, bondy_oplog:current_watermark(InstId))
    after
        ok = bondy_oplog:stop_instance(InstId)
    end.

%% The catalogue's per-cell `interpret_cog` checkpoint IS the durable
%% projection, maintained by the applier's CRDT kernel. This pins the
%% invariant — **post-compaction read == from-scratch `interpret_cog`** —
%% on the NATIVE `crdt_module` path (the tests above exercise only the
%% fold kernel).
%%
%% Two instances apply the SAME event set (LWW overwrites in non-HLC
%% order, plus a clear). Instance A compacts (stable prefix truncated from
%% the MST); instance B never compacts. Every cell must read identically
%% on both — and equal to the hand-computed `interpret_cog` winner —
%% proving truncation does not change any cell's value when the projection
%% is the checkpoint.
crdt_kernel_compaction_matches_from_scratch() ->
    Events = [
        {<<"x">>, {set, 10, <<"x1">>}},
        {<<"x">>, {set, 30, <<"x3">>}},
        {<<"x">>, {set, 20, <<"x2">>}},
        {<<"y">>, {set, 15, <<"y1">>}},
        {<<"y">>, {set, 5, <<"y0">>}},
        {<<"z">>, {set, 25, <<"z1">>}},
        {<<"z">>, {clear, 40}}
    ],
    %% From-scratch `interpret_cog` (LWW): highest HLC wins per cell;
    %% `z` is cleared by the HLC-40 clear above the HLC-25 set.
    Expected = [
        {<<"x">>, {<<"x3">>, 30}},
        {<<"y">>, {<<"y1">>, 15}},
        {<<"z">>, undefined}
    ],

    %% Instance A — compacts to truncation.
    AId = mk_id(),
    ANS = ns_of(AId),
    {AC, AP} = register_shard_crdt(ANS, primary, 0, lww_register, ?CRDT),
    {ok, _} = open_instance(AId, ANS, bondy_oplog_origin:new(), lww_register),
    %% Instance B — from scratch, never compacted.
    BId = mk_id(),
    BNS = ns_of(BId),
    {BC, BP} = register_shard_crdt(BNS, primary, 0, lww_register, ?CRDT),
    {ok, _} = open_instance(BId, BNS, bondy_oplog_origin:new(), lww_register),
    try
        [append_op(AId, K, Op) || {K, Op} <- Events],
        [append_op(BId, K, Op) || {K, Op} <- Events],
        _ = bondy_oplog_instance:await_apply(AId),
        _ = bondy_oplog_instance:await_apply(BId),

        %% A: a peer converged to exactly our tree ⇒ frontier = whole
        %% tree; the stable prefix is truncated. Do NOT read A before
        %% compacting, so post-truncation reads can only come from the
        %% projection (the checkpoint), not a warm cache.
        ARoot = bondy_oplog_instance:root_hash(AId),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(AId, [ARoot])
        ),
        ?assertEqual(0, bondy_oplog:size(AId)),
        ?assertNotEqual(undefined, bondy_oplog:current_watermark(AId)),

        %% Every cell reads identically on the compacted (A) and
        %% from-scratch (B) instances, and equals the interpret_cog winner.
        lists:foreach(
            fun({K, Want}) ->
                ARead = bondy_oplog_core:read(ANS, primary, K),
                BRead = bondy_oplog_core:read(BNS, primary, K),
                ?assertEqual(Want, ARead),
                ?assertEqual(ARead, BRead)
            end,
            Expected
        )
    after
        ok = bondy_oplog:stop_instance(AId),
        ok = bondy_oplog:stop_instance(BId),
        ok = bondy_oplog_core_registry:unregister(ANS, primary, 0),
        ok = bondy_oplog_core_registry:unregister(BNS, primary, 0),
        close_shard(AC, AP),
        close_shard(BC, BP)
    end.

%% A genuinely-REMOTE event (authored on B, pulled into A via sync, so it
%% carries B's origin) must survive A's catalogue compaction. The pre-truncate
%% catch-up runs only when `remote_events_pending` is set (by
%% `integrate_peer_root`), and folds only remote-origin events
%% (`remote_pairs/2`). If either gate were wrong the remote event would be
%% dropped by the truncate and lost — this pins that it is folded into A's
%% projection before the truncate.
remote_event_survives_catalogue_compaction() ->
    AId = mk_id(),
    ANS = ns_of(AId),
    BId = mk_id(),
    BNS = ns_of(BId),
    {AC, AP} = register_shard(ANS, primary, 0, lww_register),
    {BC, BP} = register_shard(BNS, primary, 0, lww_register),
    {ok, _} = open_instance(AId, ANS, bondy_oplog_origin:new(), lww_register),
    {ok, _} = open_instance(BId, BNS, bondy_oplog_origin:new(), lww_register),
    try
        %% A local event on A.
        append_cell(AId, <<"l">>, 60, <<"lval">>),
        _ = bondy_oplog_instance:await_apply(AId),
        %% A remote event authored on B.
        append_cell(BId, <<"r">>, 50, <<"rval">>),
        _ = bondy_oplog_instance:await_apply(BId),
        %% A pulls B's r-event into its MST (B-origin → remote on A). This
        %% sets A's `remote_events_pending`. Compact immediately (no await)
        %% so the catch-up — not the async replay — does the fold.
        {ok, _} = bondy_oplog:sync(AId, BId),

        %% Frontier = whole tree ⇒ truncate everything, including r.
        ARoot = bondy_oplog_instance:root_hash(AId),
        %% With a remote event pending, the catch-up is ASYNCHRONOUS: the
        %% instance hands the remote pairs to the applier (`catch_up_apply/3`)
        %% and DEFERS the truncate until the applier casts `{catch_up_done}`
        %% back — the cross-node deadlock fix. So `compact/2` returns
        %% `{ok, compaction_pending}` and the MST empties a beat later. (If
        %% the async `replay_cell_events` had already folded r, the remote
        %% set is empty and the truncate runs inline as `{ok, {compacted,…}}`
        %% — either reply is acceptable.)
        Res = bondy_oplog_instance:compact(AId, [ARoot]),
        ?assert(
            Res =:= {ok, compaction_pending} orelse
                (is_tuple(Res) andalso element(1, Res) =:= ok)
        ),
        ok = await_size(AId, 0, 200),

        %% Both cells read back from A's projection post-truncation.
        ?assertEqual(
            {<<"rval">>, 50}, bondy_oplog_core:read(ANS, primary, <<"r">>)
        ),
        ?assertEqual(
            {<<"lval">>, 60}, bondy_oplog_core:read(ANS, primary, <<"l">>)
        )
    after
        ok = bondy_oplog:stop_instance(AId),
        ok = bondy_oplog:stop_instance(BId),
        ok = bondy_oplog_core_registry:unregister(ANS, primary, 0),
        ok = bondy_oplog_core_registry:unregister(BNS, primary, 0),
        close_shard(AC, AP),
        close_shard(BC, BP)
    end.

%% Falsifies the cross-node compaction↔commit deadlock. With a remote event
%% pending, the compaction commit MUST hand the projection fold to the
%% applier via a CAST (`catch_up_apply/3`) and make ZERO synchronous calls
%% back to the applier. The removed synchronous calls — `last_replayed_root/1`
%% and `apply_replayed_pairs/3` — are exactly what deadlocked against the
%% applier's own synchronous `drain_install_queue` call (`commit_now/1`) the
%% moment a compaction overlapped a commit boundary. We trace the applier API
%% during `compact/2` and assert the sync calls are gone and the cast is used.
%% (The remote event `r` sits in the whole-tree truncation range, so the
%% async path is taken deterministically — `RemotePairs` is non-empty.)
async_catch_up_uses_cast_not_sync_calls() ->
    AId = mk_id(),
    ANS = ns_of(AId),
    BId = mk_id(),
    BNS = ns_of(BId),
    {AC, AP} = register_shard(ANS, primary, 0, lww_register),
    {BC, BP} = register_shard(BNS, primary, 0, lww_register),
    {ok, _} = open_instance(AId, ANS, bondy_oplog_origin:new(), lww_register),
    {ok, _} = open_instance(BId, BNS, bondy_oplog_origin:new(), lww_register),
    Patterns = [
        {bondy_oplog_applier, last_replayed_root, 1},
        {bondy_oplog_applier, apply_replayed_pairs, 3},
        {bondy_oplog_applier, catch_up_apply, 3}
    ],
    try
        append_cell(AId, <<"l">>, 60, <<"lval">>),
        _ = bondy_oplog_instance:await_apply(AId),
        append_cell(BId, <<"r">>, 50, <<"rval">>),
        _ = bondy_oplog_instance:await_apply(BId),
        %% A pulls B's r-event in → A.remote_events_pending = true.
        {ok, _} = bondy_oplog:sync(AId, BId),

        [erlang:trace_pattern(P, true, [global]) || P <- Patterns],
        _ = erlang:trace(all, true, [call]),
        try
            ARoot = bondy_oplog_instance:root_hash(AId),
            _ = bondy_oplog_instance:compact(AId, [ARoot]),
            ok = await_size(AId, 0, 200)
        after
            _ = erlang:trace(all, false, [call]),
            [erlang:trace_pattern(P, false, [global]) || P <- Patterns]
        end,
        {LastRoot, ApplyPairs, CatchUp} = collect_applier_trace(0, 0, 0),
        %% The deadlock-causing synchronous calls are GONE.
        ?assertEqual(0, LastRoot),
        ?assertEqual(0, ApplyPairs),
        %% The async cast path was taken (and the deferred truncate landed —
        %% `await_size` above already proved that).
        ?assert(CatchUp >= 1),
        %% And the remote event survived the truncate.
        ?assertEqual(
            {<<"rval">>, 50}, bondy_oplog_core:read(ANS, primary, <<"r">>)
        )
    after
        ok = bondy_oplog:stop_instance(AId),
        ok = bondy_oplog:stop_instance(BId),
        ok = bondy_oplog_core_registry:unregister(ANS, primary, 0),
        ok = bondy_oplog_core_registry:unregister(BNS, primary, 0),
        close_shard(AC, AP),
        close_shard(BC, BP)
    end.

%% Drains call-trace messages for the three applier MFAs, returning the
%% per-MFA counts.
collect_applier_trace(L, A, C) ->
    receive
        {trace, _, call, {bondy_oplog_applier, last_replayed_root, _}} ->
            collect_applier_trace(L + 1, A, C);
        {trace, _, call, {bondy_oplog_applier, apply_replayed_pairs, _}} ->
            collect_applier_trace(L, A + 1, C);
        {trace, _, call, {bondy_oplog_applier, catch_up_apply, _}} ->
            collect_applier_trace(L, A, C + 1)
    after 100 ->
        {L, A, C}
    end.

%% An instance with neither a fold nor a crdt module still reports
%% `{error, no_crdt_module}` — the guard only enables compaction when at
%% least one is configured.
neither_fold_nor_crdt_returns_error() ->
    InstId = mk_id(),
    {ok, _} = bondy_oplog:start_instance(InstId),
    try
        ?assertEqual(
            {error, no_crdt_module},
            bondy_oplog_instance:compact(InstId, [])
        )
    after
        ok = bondy_oplog:stop_instance(InstId)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

%% Polls `bondy_oplog:size/1` until it reaches `Want` (the async compaction
%% truncate lands a beat after `compact/2` returns `{ok, compaction_pending}`)
%% or `Retries` 10ms ticks elapse.
await_size(_InstId, _Want, 0) ->
    {error, timeout};
await_size(InstId, Want, Retries) ->
    case bondy_oplog:size(InstId) of
        Want ->
            ok;
        _ ->
            timer:sleep(10),
            await_size(InstId, Want, Retries - 1)
    end.

mk_id() ->
    list_to_binary(
        "catcomp_" ++
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

%% Like `register_shard/4` but also wires a `crdt_module`, so the
%% applier's cell kernel selects the operation-based `{crdt, _}` branch.
%% `fold_module` remains (a required registry field + the native CRDT
%% shares its state-byte format).
register_shard_crdt(NS, Index, Shard, FoldModule, CrdtModule) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => FoldModule,
        crdt_module => CrdtModule,
        overlay => disabled
    }),
    {Cache, Proj}.

close_shard(Cache, Proj) ->
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

open_instance(InstanceId, NS, Origin, FoldModule) ->
    bondy_oplog:start_instance(InstanceId, #{
        origin => Origin,
        fold_module => FoldModule,
        applier => #{
            cell_apply_target => {NS, primary, 0}
        }
    }).

append_cell(InstanceId, Key, Hlc, Value) ->
    append_op(InstanceId, Key, {set, Hlc, Value}).

append_op(InstanceId, Key, Op) ->
    _ = bondy_oplog:append(InstanceId, {cell_apply, ?B, Key, Op}),
    _ = bondy_oplog:projection(InstanceId),
    ok.
