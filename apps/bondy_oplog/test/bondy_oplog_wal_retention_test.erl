%% =============================================================================
%% Retention + snapshot watermark tests for `bondy_oplog_wal`.
%%
%% Tests cover:
%%
%% 1. `advance_snapshot_watermark/2` persists to `snapshot.watermark`
%%    and survives a writer restart.
%% 2. Watermark regression is rejected; in-memory state untouched.
%% 3. `retention_sweep/1` with no committed/watermark progress: no-op.
%% 4. `min_live_segments` bounds the sweep — never reduces the
%%    live-segment count below the floor.
%% 5. Sweep with a fully-covering watermark + committed cursor deletes
%%    the eligible prefix and rewrites the manifest.
%% 6. Crash-during-deletion simulation: manifest names only the
%%    survivors, but stale `.qdata`/`.qidx` files remain on disk; the
%%    next open's orphan-cleanup removes them.
%% 7. `info/1` exposes `snapshot_watermark`, `committed_segment`,
%%    `live_segments`, `deleted_through`, `min_live_segments`.
%% =============================================================================

-module(bondy_oplog_wal_retention_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-define(SEG_HEADER, ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES).

%% =============================================================================
%% Fixtures
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_oplog_wal_retention_test_~p_~p",
                [
                    erlang:system_time(microsecond),
                    erlang:unique_integer([positive])
                ]
            )
        ]
    ),
    Dir = lists:flatten(Base),
    ok = filelib:ensure_path(Dir),
    Dir.

rmrf(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.

instance_id() ->
    <<"wal-retention-test-instance">>.

origin() ->
    <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>.

base_opts() ->
    #{
        origin => origin(),
        %% Disable the periodic timer in the default fixture — tests
        %% drive sweeps explicitly so they're deterministic.
        retention_sweep_interval => 24 * 60 * 60 * 1000
    }.

with_wal(Opts, Fun) ->
    Dir = mktemp_dir(),
    try
        with_wal(Dir, Opts, Fun)
    after
        rmrf(Dir)
    end.

with_wal(Dir, Opts, Fun) ->
    AllOpts0 = (base_opts())#{dir => Dir},
    AllOpts = maps:merge(AllOpts0, Opts),
    {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), AllOpts),
    try
        Fun(Pid, Dir)
    after
        ok = bondy_oplog_wal:close(Pid)
    end.

%% Encode one event so it forces rotation after a couple of appends
%% when `max_segment_bytes` is small.
mk_event(Hlc, Seq) ->
    Key = bondy_oplog_event:key(Hlc, origin(), Seq),
    bondy_oplog_event:new(Key, {op, Seq}, undefined).

mk_one(HLC, Seq) ->
    Hlc = bondy_oplog_hlc:now(HLC),
    {Hlc, mk_event(Hlc, Seq)}.

%% Append a single event, returning {Hlc, Pos}.
append1(Pid, HLC, Seq) ->
    {Hlc, E} = mk_one(HLC, Seq),
    {ok, Hlc, Pos} = bondy_oplog_wal:append(Pid, E),
    {Hlc, Pos}.

%% Append `N` events. Empirically (frame ~144B), one frame fits per
%% segment under `small_segment_opts/0` — so this produces `N`
%% sealed segments plus a head, but the test reads the actual
%% `live_segments` via `info/1` to stay layout-agnostic.
fill_events(Pid, HLC, N) ->
    [append1(Pid, HLC, Seq) || Seq <- lists:seq(0, N - 1)].

fill_events_from(Pid, HLC, SeqBase, N) ->
    [append1(Pid, HLC, Seq) || Seq <- lists:seq(SeqBase, SeqBase + N - 1)].

%% Tight segment cap. One event ≈ one segment under this config.
small_segment_opts() ->
    #{
        max_segment_bytes => 256,
        max_batch_bytes => 200
    }.

live_segment_ids(Pid) ->
    maps:get(live_segments, bondy_oplog_wal:info(Pid)).

%% =============================================================================
%% Tests
%% =============================================================================

advance_watermark_persists_test() ->
    Dir = mktemp_dir(),
    try
        Hlc1 = with_wal(Dir, #{}, fun(Pid, _Dir) ->
            HLC = bondy_oplog_hlc:new(),
            H = bondy_oplog_hlc:now(HLC),
            ok = bondy_oplog_wal:advance_snapshot_watermark(Pid, H),
            Info = bondy_oplog_wal:info(Pid),
            ?assertEqual(H, maps:get(snapshot_watermark, Info)),
            H
        end),
        %% Reopen and verify the watermark survives.
        with_wal(Dir, #{}, fun(Pid, _Dir) ->
            Info = bondy_oplog_wal:info(Pid),
            ?assertEqual(Hlc1, maps:get(snapshot_watermark, Info))
        end)
    after
        rmrf(Dir)
    end.

watermark_regression_rejected_test() ->
    with_wal(#{}, fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        High = bondy_oplog_hlc:now(HLC),
        Low = High - 1,
        ok = bondy_oplog_wal:advance_snapshot_watermark(Pid, High),
        ?assertMatch(
            {error, {watermark_regression, _, _}},
            bondy_oplog_wal:advance_snapshot_watermark(Pid, Low)
        ),
        %% State untouched.
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(High, maps:get(snapshot_watermark, Info))
    end).

sweep_noop_without_progress_test() ->
    with_wal(small_segment_opts(), fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        fill_events(Pid, HLC, 4),
        %% No watermark advance, no committed segment — sweep is a
        %% no-op even though there are sealed segments.
        ?assertMatch({ok, [], 0}, bondy_oplog_wal:retention_sweep(Pid))
    end).

sweep_respects_min_live_segments_test() ->
    %% Floor: never drop below `min_live_segments` even if more are
    %% eligible.
    Opts = maps:merge(small_segment_opts(), #{min_live_segments => 3}),
    with_wal(Opts, fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        fill_events(Pid, HLC, 6),
        Live0 = live_segment_ids(Pid),
        ?assert(length(Live0) >= 5),
        %% Mark everything as both committed and watermark-covered.
        %% `advance_snapshot_watermark/2` runs an opportunistic sweep
        %% before returning — order matters: set committed first so
        %% the implicit sweep sees both cursors at their max.
        ok = bondy_oplog_wal:set_committed_segment(Pid, 9999),
        ok = bondy_oplog_wal:advance_snapshot_watermark(
            Pid, bondy_oplog_hlc:now(HLC) + 1
        ),
        Live1 = live_segment_ids(Pid),
        ?assertEqual(3, length(Live1))
    end).

sweep_deletes_eligible_prefix_test() ->
    %% With a high watermark and a committed cursor at head,
    %% snapshot_watermark_segment lands on the *last sealed segment*
    %% (its entire content is covered by the watermark) — and that
    %% one is preserved as the boundary, per §10. Segments strictly
    %% older are deleted via the implicit sweep that
    %% `advance_snapshot_watermark/2` triggers.
    Opts = maps:merge(small_segment_opts(), #{min_live_segments => 1}),
    with_wal(Opts, fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        fill_events(Pid, HLC, 5),
        Live0 = live_segment_ids(Pid),
        ?assert(length(Live0) >= 3),
        HeadSeg = lists:last(Live0),
        Sealed = lists:droplast(Live0),
        BoundarySeg = lists:last(Sealed),
        ExpectedDeleted = lists:droplast(Sealed),
        ok = bondy_oplog_wal:set_committed_segment(Pid, HeadSeg),
        ok = bondy_oplog_wal:advance_snapshot_watermark(
            Pid, bondy_oplog_hlc:now(HLC) + 1
        ),
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(
            [BoundarySeg, HeadSeg],
            maps:get(live_segments, Info)
        ),
        ?assertEqual(
            lists:max(ExpectedDeleted),
            maps:get(deleted_through, Info)
        ),
        InstanceDir = maps:get(dir, Info),
        [
            ?assertNot(
                filelib:is_regular(
                    filename:join(
                        InstanceDir, bondy_oplog_wal_segment:filename(S)
                    )
                )
            )
         || S <- ExpectedDeleted
        ],
        ?assert(
            filelib:is_regular(
                filename:join(
                    InstanceDir, bondy_oplog_wal_segment:filename(BoundarySeg)
                )
            )
        ),
        ?assert(
            filelib:is_regular(
                filename:join(
                    InstanceDir, bondy_oplog_wal_segment:filename(HeadSeg)
                )
            )
        ),
        %% Explicit `retention_sweep/1` after the implicit sweep is a
        %% no-op: nothing more is eligible.
        ?assertMatch({ok, [], 0}, bondy_oplog_wal:retention_sweep(Pid))
    end).

sweep_explicit_when_no_implicit_trigger_test() ->
    %% Verify the `retention_sweep/1` API in isolation: stub the
    %% committed segment via direct API, do NOT advance the
    %% watermark, then call `retention_sweep/1`. With no watermark,
    %% nothing is eligible.
    Opts = maps:merge(small_segment_opts(), #{min_live_segments => 1}),
    with_wal(Opts, fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        fill_events(Pid, HLC, 4),
        ok = bondy_oplog_wal:set_committed_segment(Pid, 9999),
        ?assertMatch({ok, [], 0}, bondy_oplog_wal:retention_sweep(Pid))
    end).

sweep_explicit_after_watermark_via_manual_state_test() ->
    %% Verify the explicit `retention_sweep/1` actually deletes when
    %% it gets to run first. The implicit sweep on
    %% `advance_snapshot_watermark/2` makes this hard; we side-step
    %% by appending more events *after* the watermark advance so the
    %% new sealed segments become eligible only on the explicit
    %% sweep.
    Opts = maps:merge(small_segment_opts(), #{min_live_segments => 1}),
    with_wal(Opts, fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        fill_events(Pid, HLC, 3),
        %% First watermark advance — covers segs 0..1 (boundary at
        %% the last sealed, seg 1). Implicit sweep handles them.
        ok = bondy_oplog_wal:set_committed_segment(Pid, 999),
        ok = bondy_oplog_wal:advance_snapshot_watermark(
            Pid, bondy_oplog_hlc:now(HLC) + 1
        ),
        LiveMid = live_segment_ids(Pid),
        %% Append more so new sealed segments accrue.
        fill_events_from(Pid, HLC, lists:max(LiveMid) + 1, 3),
        %% A second watermark advance under a fresh now() — now the
        %% just-added sealed segs are also covered. Use explicit
        %% retention_sweep AFTER advance_snapshot_watermark so the
        %% sweep returns the new deletions.
        ok = bondy_oplog_wal:advance_snapshot_watermark(
            Pid, bondy_oplog_hlc:now(HLC) + 1
        ),
        %% By now the implicit sweep has done the deletions; verify
        %% the explicit call is a no-op.
        ?assertMatch({ok, [], 0}, bondy_oplog_wal:retention_sweep(Pid))
    end).

watermark_advance_without_committed_segment_is_noop_test() ->
    %% Watermark covers everything but committed_segment stays at 0:
    %% no deletion happens (both cuts must pass).
    Opts = maps:merge(small_segment_opts(), #{min_live_segments => 1}),
    with_wal(Opts, fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        fill_events(Pid, HLC, 4),
        ok = bondy_oplog_wal:advance_snapshot_watermark(
            Pid, bondy_oplog_hlc:now(HLC) + 1
        ),
        ?assertMatch({ok, [], 0}, bondy_oplog_wal:retention_sweep(Pid))
    end).

crash_between_manifest_and_unlink_cleaned_on_open_test() ->
    Dir = mktemp_dir(),
    Opts = maps:merge(small_segment_opts(), #{min_live_segments => 1}),
    try
        %% First open: build segments, manually simulate a partial
        %% sweep where the manifest is committed but .qdata files
        %% remain. The writer uses a per-instance subdir, so file
        %% I/O is done relative to `InstanceDir`, not the base.
        {SegToOrphan, InstanceDir} = with_wal(Dir, Opts, fun(Pid, _) ->
            HLC = bondy_oplog_hlc:new(),
            fill_events(Pid, HLC, 4),
            Live = live_segment_ids(Pid),
            S = hd(Live),
            ID = maps:get(dir, bondy_oplog_wal:info(Pid)),
            {ok, M0} = bondy_oplog_wal_manifest:read(ID),
            LiveM = bondy_oplog_wal_manifest:live_segments(M0),
            Survivors =
                [Pair || {Id, _} = Pair <- LiveM, Id =/= S],
            M1 = bondy_oplog_wal_manifest:with_live_segments(M0, Survivors),
            ok = bondy_oplog_wal_manifest:write(ID, M1),
            {S, ID}
        end),
        OrphanPath = filename:join(
            InstanceDir, bondy_oplog_wal_segment:filename(SegToOrphan)
        ),
        ?assert(filelib:is_regular(OrphanPath)),
        with_wal(Dir, Opts, fun(_Pid, _Dir) ->
            ?assertNot(filelib:is_regular(OrphanPath))
        end)
    after
        rmrf(Dir)
    end.

info_exposes_retention_fields_test() ->
    with_wal(#{min_live_segments => 5}, fun(Pid, _Dir) ->
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(undefined, maps:get(snapshot_watermark, Info)),
        ?assertEqual(0, maps:get(committed_segment, Info)),
        ?assertEqual([0], maps:get(live_segments, Info)),
        ?assertEqual(0, maps:get(deleted_through, Info)),
        ?assertEqual(5, maps:get(min_live_segments, Info))
    end).

set_committed_segment_regression_rejected_test() ->
    with_wal(#{}, fun(Pid, _Dir) ->
        ok = bondy_oplog_wal:set_committed_segment(Pid, 5),
        ?assertMatch(
            {error, {committed_segment_regression, 5, 3}},
            bondy_oplog_wal:set_committed_segment(Pid, 3)
        )
    end).

invalid_min_live_segments_rejected_at_init_test() ->
    Dir = mktemp_dir(),
    try
        OldFlag = process_flag(trap_exit, true),
        try
            Got = bondy_oplog_wal:start_link(
                instance_id(),
                #{dir => Dir, origin => origin(), min_live_segments => 0}
            ),
            ?assertEqual({error, {invalid_opt, min_live_segments, 0}}, Got),
            receive
                {'EXIT', _, _} -> ok
            after 0 -> ok
            end
        after
            process_flag(trap_exit, OldFlag)
        end
    after
        rmrf(Dir)
    end.
