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
        {timeout, 30, fun compaction_makes_no_synchronous_applier_call/0}
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
%% carries B's origin) must survive A's catalogue compaction. Compaction
%% folds nothing itself: a remote event the applier's replay has not
%% folded yet is never-applied by the applied VV and the truncation point
%% is capped below it (`capped_truncation_point/2`) — the tick replies
%% `{ok, no_change}` — and once the replay has folded it the next tick
%% truncates. Compacting immediately after the pull (no settle) makes the
%% first outcome possible; the loop below tolerates either and pins the
%% invariant: the tree empties and the remote value is in A's projection.
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
        %% A pulls B's r-event into its MST (B-origin → remote on A).
        {ok, _} = bondy_oplog:sync(AId, BId),
        ok = compact_until_empty(AId, 200),

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
%% just delivered, the compaction handler must make ZERO synchronous calls
%% to the applier — the applier's own synchronous `drain_install_queue`
%% call (`commit_now/1`) deadlocks against any such call the moment a
%% compaction overlaps a commit boundary. Every call from the instance
%% process into `bondy_oplog_applier` during `compact/2` is traced; the
%% only one allowed is the `advance_replayed_root/2` cast that re-anchors
%% the replay cursor after a truncate. (The remote event `r` sits in the
%% whole-tree truncation range, so the compaction has a remote event to be
%% tempted by whether or not the replay has folded it.)
compaction_makes_no_synchronous_applier_call() ->
    AId = mk_id(),
    ANS = ns_of(AId),
    BId = mk_id(),
    BNS = ns_of(BId),
    {AC, AP} = register_shard(ANS, primary, 0, lww_register),
    {BC, BP} = register_shard(BNS, primary, 0, lww_register),
    {ok, _} = open_instance(AId, ANS, bondy_oplog_origin:new(), lww_register),
    {ok, _} = open_instance(BId, BNS, bondy_oplog_origin:new(), lww_register),
    Pattern = {bondy_oplog_applier, '_', '_'},
    try
        append_cell(AId, <<"l">>, 60, <<"lval">>),
        _ = bondy_oplog_instance:await_apply(AId),
        append_cell(BId, <<"r">>, 50, <<"rval">>),
        _ = bondy_oplog_instance:await_apply(BId),
        {ok, _} = bondy_oplog:sync(AId, BId),

        InstancePid = bondy_oplog_instance:whereis(AId),
        _ = erlang:trace_pattern(Pattern, true, [global]),
        _ = erlang:trace(InstancePid, true, [call]),
        try
            ok = compact_until_empty(AId, 200)
        after
            _ = erlang:trace(InstancePid, false, [call]),
            _ = erlang:trace_pattern(Pattern, false, [global])
        end,
        Called = lists:usort(collect_applier_calls([])),
        ?assertEqual([{advance_replayed_root, 2}], Called),
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

%% Drains the call-trace messages for `bondy_oplog_applier`, returning the
%% `{Function, Arity}` of every call the traced process made.
collect_applier_calls(Acc) ->
    receive
        {trace, _, call, {bondy_oplog_applier, F, Args}} ->
            collect_applier_calls([{F, length(Args)} | Acc])
    after 100 ->
        Acc
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

%% Compacts against the instance's own root until the tree is empty, or
%% `Retries` 10ms ticks elapse. A tick that finds a delivered-but-not-yet-
%% folded remote event replies `{ok, no_change}` (the compaction cap); the
%% applier's replay folds it a beat later and the next tick truncates.
compact_until_empty(_InstId, 0) ->
    {error, timeout};
compact_until_empty(InstId, Retries) ->
    Root = bondy_oplog_instance:root_hash(InstId),
    _ = bondy_oplog_instance:compact(InstId, [Root]),
    case bondy_oplog:size(InstId) of
        0 ->
            ok;
        _ ->
            timer:sleep(10),
            compact_until_empty(InstId, Retries - 1)
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
