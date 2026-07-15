%% =============================================================================
%% Unit tests for `bondy_oplog_wal_recovery` and writer reopen.
%%
%% Tests are organised around the recovery responsibilities:
%%
%% 1. Round-trip — close + reopen restores state and event sequence.
%% 2. Head segment break-and-truncate — corrupt the tail with a
%%    bit-flip, partial frame, or zero-fill; reopen; verify only
%%    intact frames survive.
%% 3. Orphan cleanup — pre-seed stray `.qdata`, `.qidx`, `.tmp`,
%%    `manifest.tmp` files; reopen; verify they're gone.
%% 4. Sealed segment `.qidx` rebuild — delete a sealed segment's
%%    `.qidx`; reopen; verify the file is back and a reader's HLC
%%    seek lands on the right frame.
%% 5. Consumer offset clamping — pre-seed a `consumer.offset` past
%%    EOF or mid-frame; reopen; verify it's clamped to a real
%%    frame boundary ≤ last_valid_offset.
%% 6. Refusal paths — instance_id mismatch, orphan sealed segment.
%% =============================================================================

-module(bondy_oplog_wal_recovery_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-define(SEG_HEADER, ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES).

%% =============================================================================
%% Fixture helpers
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_oplog_wal_rec_~p_~p",
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
    <<"wal-recovery-test-instance">>.

origin() ->
    <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>.

mk_event(Hlc, Seq) ->
    Key = bondy_oplog_event:key(Hlc, origin(), Seq),
    bondy_oplog_event:new(Key, {op, Hlc}, undefined).

generate_events(_HLC, 0, _) ->
    [];
generate_events(HLC, N, Seq) ->
    Hlc = bondy_oplog_hlc:now(HLC),
    [mk_event(Hlc, Seq) | generate_events(HLC, N - 1, Seq + 1)].

instance_dir(Dir) ->
    filename:join(Dir, instance_id()).

%% Drains the WAL into a flat event list via a bounded reader.
read_all(Pid) ->
    {ok, Iter} = bondy_oplog_wal_reader:open(Pid, beginning),
    drain(Iter, []).

drain(Iter, Acc) ->
    case bondy_oplog_wal_reader:next(Iter) of
        {ok, Batch, _, _, NewIter} ->
            drain(NewIter, Acc ++ Batch);
        end_of_log ->
            ok = bondy_oplog_wal_reader:close(Iter),
            Acc;
        {error, _} = E ->
            ok = bondy_oplog_wal_reader:close(Iter),
            E
    end.

%% Helper: open a fresh WAL, run Fun, close, return the close-time
%% list of all appended events.
with_fresh_wal(Opts, Fun) ->
    Dir = mktemp_dir(),
    try
        AllOpts = maps:merge(#{dir => Dir, origin => origin()}, Opts),
        {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), AllOpts),
        Events =
            try
                Fun(Pid)
            after
                ok = bondy_oplog_wal:close(Pid)
            end,
        {Dir, Events}
    catch
        Class:Reason:Stack ->
            rmrf(Dir),
            erlang:raise(Class, Reason, Stack)
    end.

%% =============================================================================
%% 1. Round-trip — close + reopen
%% =============================================================================

clean_close_then_reopen_preserves_events_test() ->
    {Dir, Events} =
        with_fresh_wal(#{}, fun(Pid) ->
            HLC = bondy_oplog_hlc:new(),
            Es = generate_events(HLC, 7, 1),
            [{ok, _, _} = bondy_oplog_wal:append(Pid, E) || E <- Es],
            Es
        end),
    try
        {ok, Pid2} = bondy_oplog_wal:start_link(
            instance_id(), #{dir => Dir, origin => origin()}
        ),
        ?assertEqual(Events, read_all(Pid2)),
        ok = bondy_oplog_wal:close(Pid2)
    after
        rmrf(Dir)
    end.

reopen_continues_appending_test() ->
    HLC = bondy_oplog_hlc:new(),
    Dir = mktemp_dir(),
    try
        Opts = #{dir => Dir, origin => origin()},
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        E1 = mk_event(bondy_oplog_hlc:now(HLC), 1),
        E2 = mk_event(bondy_oplog_hlc:now(HLC), 2),
        {ok, _, _} = bondy_oplog_wal:append(P1, E1),
        {ok, _, _} = bondy_oplog_wal:append(P1, E2),
        ok = bondy_oplog_wal:close(P1),
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        %% Continue appending after reopen.
        E3 = mk_event(bondy_oplog_hlc:now(HLC), 3),
        {ok, _, _} = bondy_oplog_wal:append(P2, E3),
        ?assertEqual([E1, E2, E3], read_all(P2)),
        ok = bondy_oplog_wal:close(P2)
    after
        rmrf(Dir)
    end.

reopen_across_rotation_test() ->
    HLC = bondy_oplog_hlc:new(),
    Dir = mktemp_dir(),
    try
        %% Tight cap so each event triggers a rotation.
        Opts = #{dir => Dir, origin => origin(), max_segment_bytes => 200},
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Events = generate_events(HLC, 6, 1),
        [{ok, _, _} = bondy_oplog_wal:append(P1, E) || E <- Events],
        ok = bondy_oplog_wal:close(P1),
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ?assertEqual(Events, read_all(P2)),
        %% Verify head segment carries on incrementing.
        E7 = mk_event(bondy_oplog_hlc:now(HLC), 7),
        {ok, _, _} = bondy_oplog_wal:append(P2, E7),
        ?assertEqual(Events ++ [E7], read_all(P2)),
        ok = bondy_oplog_wal:close(P2)
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% 2. Head segment break-and-truncate
%% =============================================================================

%% Truncate the head segment by N bytes (simulate a crash mid-write).
%% After reopen the file should be shorter or equal to the truncated
%% size, and reader should surface all frames that were intact below
%% the truncation point.
truncated_tail_recovers_to_last_valid_frame_test() ->
    HLC = bondy_oplog_hlc:new(),
    Dir = mktemp_dir(),
    try
        Opts = #{dir => Dir, origin => origin()},
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Events = generate_events(HLC, 5, 1),
        Positions = [
            begin
                {ok, _, Pos} = bondy_oplog_wal:append(P1, E),
                Pos
            end
         || E <- Events
        ],
        ok = bondy_oplog_wal:close(P1),
        %% Truncate the segment file 10 bytes before EOF — that lops
        %% off the tail of the last frame. Three of the five frames
        %% should survive recovery (depending on frame size, but the
        %% truncation is mid-last-frame so events 1..4 must be there).
        SegPath = filename:join(
            instance_dir(Dir), bondy_oplog_wal_segment:filename(0)
        ),
        {ok, #file_info{size = Size}} = file:read_file_info(SegPath),
        {ok, Fd} = file:open(SegPath, [read, write, raw, binary]),
        {ok, _} = file:position(Fd, Size - 10),
        ok = file:truncate(Fd),
        ok = file:close(Fd),
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Read = read_all(P2),
        %% Every intact frame's last-byte offset is ≤ Size - 10. The
        %% test does not predict the exact survival count (frame sizes
        %% vary slightly with HLC encoding), but it must be a strict
        %% prefix of the appended sequence.
        ?assert(length(Read) < length(Events)),
        ?assertEqual(lists:sublist(Events, length(Read)), Read),
        ok = bondy_oplog_wal:close(P2),
        %% Also: the file size must equal the writer's
        %% current_offset on a quiescent close-reopen.
        {ok, P3} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Info = bondy_oplog_wal:info(P3),
        {ok, #file_info{size = NewSize}} = file:read_file_info(SegPath),
        ?assertEqual(maps:get(head_offset, Info), NewSize),
        %% Lastly the *first* call after recovery must update the
        %% positions sensibly — the new event lands strictly after
        %% the last recovered position.
        E6 = mk_event(bondy_oplog_hlc:now(HLC), 6),
        {ok, _, {SegId, Off}} = bondy_oplog_wal:append(P3, E6),
        ?assertEqual(0, SegId),
        LastSurvivedPos = lists:nth(length(Read), Positions),
        ?assert(Off >= element(2, LastSurvivedPos)),
        ok = bondy_oplog_wal:close(P3)
    after
        rmrf(Dir)
    end.

%% Truncating BEFORE any frame (cut off inside the segment header) is
%% a pathological case — the segment header is fsynced at creation so
%% it should normally be intact. We test the cleaner case where we
%% truncate immediately after the segment header: recovery should see
%% zero frames and reopen cleanly.
truncated_to_just_segment_header_recovers_empty_test() ->
    HLC = bondy_oplog_hlc:new(),
    Dir = mktemp_dir(),
    try
        Opts = #{dir => Dir, origin => origin()},
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        E = mk_event(bondy_oplog_hlc:now(HLC), 1),
        {ok, _, _} = bondy_oplog_wal:append(P1, E),
        ok = bondy_oplog_wal:close(P1),
        SegPath = filename:join(
            instance_dir(Dir), bondy_oplog_wal_segment:filename(0)
        ),
        {ok, Fd} = file:open(SegPath, [read, write, raw, binary]),
        {ok, _} = file:position(Fd, ?SEG_HEADER),
        ok = file:truncate(Fd),
        ok = file:close(Fd),
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ?assertEqual([], read_all(P2)),
        Info = bondy_oplog_wal:info(P2),
        ?assertEqual(?SEG_HEADER, maps:get(head_offset, Info)),
        ok = bondy_oplog_wal:close(P2)
    after
        rmrf(Dir)
    end.

%% Flipping a bit inside the CRC-covered region of the last frame
%% should also trigger break-and-truncate. The earlier frames must
%% survive intact.
bit_flip_in_last_frame_truncates_test() ->
    HLC = bondy_oplog_hlc:new(),
    Dir = mktemp_dir(),
    try
        Opts = #{dir => Dir, origin => origin()},
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Events = generate_events(HLC, 3, 1),
        [{ok, _, _} = bondy_oplog_wal:append(P1, E) || E <- Events],
        ok = bondy_oplog_wal:close(P1),
        SegPath = filename:join(
            instance_dir(Dir), bondy_oplog_wal_segment:filename(0)
        ),
        {ok, Bin} = file:read_file(SegPath),
        Size = byte_size(Bin),
        %% Flip a bit a few bytes before EOF. That lands inside the
        %% last frame's body, breaking CRC.
        FlipIdx = Size - 4,
        <<Pre:FlipIdx/binary, B:8, Post/binary>> = Bin,
        Corrupted = <<Pre/binary, (B bxor 1):8, Post/binary>>,
        ok = file:write_file(SegPath, Corrupted),
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Read = read_all(P2),
        ?assert(length(Read) < length(Events)),
        ?assertEqual(lists:sublist(Events, length(Read)), Read),
        ok = bondy_oplog_wal:close(P2)
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% 3. Orphan cleanup
%% =============================================================================

orphan_tmp_files_removed_on_open_test() ->
    Dir = mktemp_dir(),
    try
        InstDir = instance_dir(Dir),
        Opts = #{dir => Dir, origin => origin()},
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ok = bondy_oplog_wal:close(P1),
        %% Sprinkle some orphan files in the instance directory.
        ok = file:write_file(
            filename:join(InstDir, ?BONDY_OPLOG_WAL_MANIFEST_TMP_FILENAME),
            <<"stale">>
        ),
        ok = file:write_file(
            filename:join(InstDir, "000000007.qdata"),
            <<"stale">>
        ),
        ok = file:write_file(
            filename:join(InstDir, "000000007.qidx"),
            <<"stale">>
        ),
        ok = file:write_file(
            filename:join(InstDir, "random.tmp"),
            <<"stale">>
        ),
        %% A non-WAL file that should be left alone.
        ok = file:write_file(
            filename:join(InstDir, "README"),
            <<"keep me">>
        ),
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ok = bondy_oplog_wal:close(P2),
        ?assertNot(
            filelib:is_regular(
                filename:join(InstDir, ?BONDY_OPLOG_WAL_MANIFEST_TMP_FILENAME)
            )
        ),
        ?assertNot(
            filelib:is_regular(
                filename:join(InstDir, "000000007.qdata")
            )
        ),
        ?assertNot(
            filelib:is_regular(
                filename:join(InstDir, "000000007.qidx")
            )
        ),
        ?assertNot(
            filelib:is_regular(
                filename:join(InstDir, "random.tmp")
            )
        ),
        ?assert(
            filelib:is_regular(
                filename:join(InstDir, "README")
            )
        )
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% 4. Sealed segment .qidx rebuild
%% =============================================================================

sealed_qidx_rebuilt_when_missing_test() ->
    HLC = bondy_oplog_hlc:new(),
    Dir = mktemp_dir(),
    try
        Opts = #{dir => Dir, origin => origin(), max_segment_bytes => 200},
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Events = generate_events(HLC, 6, 1),
        Hlcs = [
            begin
                {ok, H, _} = bondy_oplog_wal:append(P1, E),
                H
            end
         || E <- Events
        ],
        ok = bondy_oplog_wal:close(P1),
        Seg0Idx = filename:join(
            instance_dir(Dir), bondy_oplog_wal_idx:filename(0)
        ),
        ?assert(filelib:is_regular(Seg0Idx)),
        ok = file:delete(Seg0Idx),
        %% Reopen. Recovery should rebuild segment 0's .qidx.
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ?assert(filelib:is_regular(Seg0Idx)),
        {ok, Entries} = bondy_oplog_wal_idx:read_file(Seg0Idx),
        ?assert(length(Entries) >= 1),
        %% And HLC seek into the rebuilt index works.
        Target = lists:nth(2, Hlcs),
        {ok, Iter} = bondy_oplog_wal_reader:open(P2, {hlc, Target}),
        {ok, [First], _, _, _} = bondy_oplog_wal_reader:next(Iter),
        ?assertEqual(lists:nth(2, Events), First),
        ok = bondy_oplog_wal_reader:close(Iter),
        ok = bondy_oplog_wal:close(P2)
    after
        rmrf(Dir)
    end.

sealed_qidx_rebuilt_when_corrupt_test() ->
    HLC = bondy_oplog_hlc:new(),
    Dir = mktemp_dir(),
    try
        Opts = #{dir => Dir, origin => origin(), max_segment_bytes => 200},
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        [
            {ok, _, _} = bondy_oplog_wal:append(P1, E)
         || E <- generate_events(HLC, 4, 1)
        ],
        ok = bondy_oplog_wal:close(P1),
        Seg0Idx = filename:join(
            instance_dir(Dir), bondy_oplog_wal_idx:filename(0)
        ),
        %% Corrupt the .qidx — bad magic header.
        ok = file:write_file(Seg0Idx, <<0:128>>),
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        %% After recovery the .qidx is rewritten with a valid header.
        {ok, _Entries} = bondy_oplog_wal_idx:read_file(Seg0Idx),
        ok = bondy_oplog_wal:close(P2)
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% 5. Consumer offset clamping
%% =============================================================================

%% Pre-seed a consumer.offset with `committed_frame_offset` past the
%% segment's last valid offset. After recovery, it must be clamped
%% down to a real frame boundary ≤ last_valid_offset.
consumer_offset_clamped_to_last_valid_test() ->
    HLC = bondy_oplog_hlc:new(),
    Dir = mktemp_dir(),
    try
        Opts = #{dir => Dir, origin => origin()},
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Events = generate_events(HLC, 3, 1),
        Positions = [
            begin
                {ok, _, Pos} = bondy_oplog_wal:append(P1, E),
                Pos
            end
         || E <- Events
        ],
        InfoBeforeClose = bondy_oplog_wal:info(P1),
        HeadOffset = maps:get(head_offset, InfoBeforeClose),
        ok = bondy_oplog_wal:close(P1),
        InstDir = instance_dir(Dir),
        %% Write a fake commit at a wildly-past-EOF offset.
        CO = bondy_oplog_wal_state:with_position(
            bondy_oplog_wal_state:new_consumer_offset(), 0, 1_000_000
        ),
        ok = bondy_oplog_wal_state:write_consumer_offset(InstDir, CO),
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ok = bondy_oplog_wal:close(P2),
        {ok, Clamped} = bondy_oplog_wal_state:read_consumer_offset(InstDir),
        ClampedOff = bondy_oplog_wal_state:committed_frame_offset(
            Clamped
        ),
        %% Per design §6 the clamp lands on a frame boundary. Legal
        %% values are: any appended frame's start offset, the segment
        %% header (= "nothing applied"), or `head_offset` (= "applier
        %% fully caught up" — the next-frame-to-apply is the one not
        %% yet written).
        ValidOffsets =
            [?SEG_HEADER, HeadOffset | [Off || {_, Off} <- Positions]],
        ?assert(lists:member(ClampedOff, ValidOffsets)),
        %% Past-EOF input → clamp must land within the file.
        ?assert(ClampedOff =< HeadOffset)
    after
        rmrf(Dir)
    end.

%% Pre-seed a consumer.offset pointing at a segment that has been
%% (synthetically) swept — i.e., not in live_segments. Clamping must
%% move it to the first live segment.
consumer_offset_clamped_when_segment_swept_test() ->
    Dir = mktemp_dir(),
    try
        Opts = #{dir => Dir, origin => origin()},
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ok = bondy_oplog_wal:close(P1),
        InstDir = instance_dir(Dir),
        %% Pretend the applier committed past segment 42 even though
        %% we only have segment 0.
        CO = bondy_oplog_wal_state:with_position(
            bondy_oplog_wal_state:new_consumer_offset(), 42, ?SEG_HEADER
        ),
        ok = bondy_oplog_wal_state:write_consumer_offset(InstDir, CO),
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ok = bondy_oplog_wal:close(P2),
        {ok, Clamped} = bondy_oplog_wal_state:read_consumer_offset(InstDir),
        ?assertEqual(
            0, bondy_oplog_wal_state:committed_segment(Clamped)
        ),
        ?assertEqual(
            ?SEG_HEADER,
            bondy_oplog_wal_state:committed_frame_offset(Clamped)
        )
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% 6. Refusal paths
%% =============================================================================

%% Reopening with a different InstanceId points to the wrong directory
%% (the per-instance dir is keyed on InstanceId), so the read of the
%% non-existent manifest hits `bootstrap` rather than `recovery` — no
%% mismatch is raised. The actual mismatch path is exercised by
%% directly calling `bondy_oplog_wal_recovery:recover/4`.
recover_refuses_instance_id_mismatch_test() ->
    Dir = mktemp_dir(),
    try
        Opts = #{dir => Dir, origin => origin()},
        {ok, P} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ok = bondy_oplog_wal:close(P),
        InstDir = instance_dir(Dir),
        ?assertMatch(
            {error, {instance_id_mismatch, <<"different">>, _}},
            bondy_oplog_wal_recovery:recover(
                InstDir,
                <<"different">>,
                origin(),
                #{
                    idx_interval_bytes =>
                        ?BONDY_OPLOG_WAL_IDX_DEFAULT_INTERVAL_BYTES,
                    recovery_mode => strict
                }
            )
        )
    after
        rmrf(Dir)
    end.

%% QA finding C1: if the manifest has `current_segment` not in
%% `live_segments`, recovery MUST refuse to open before doing orphan
%% cleanup — otherwise cleanup would delete the head segment's .qdata,
%% leaving an unrecoverable state.
recover_refuses_manifest_with_current_not_in_live_test() ->
    Dir = mktemp_dir(),
    try
        Opts = #{dir => Dir, origin => origin()},
        {ok, P} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ok = bondy_oplog_wal:close(P),
        InstDir = instance_dir(Dir),
        %% Hand-edit the manifest so `current_segment = 0` but
        %% `live_segments = []`. This is the corruption shape C1 fixes.
        ManifestPath = filename:join(
            InstDir, ?BONDY_OPLOG_WAL_MANIFEST_FILENAME
        ),
        Now = erlang:system_time(millisecond),
        Bin = iolist_to_binary([
            io_lib:format("{manifest_version, 1}.~n", []),
            io_lib:format("{instance_id, ~w}.~n", [instance_id()]),
            io_lib:format("{current_segment, 0}.~n", []),
            io_lib:format("{live_segments, []}.~n", []),
            io_lib:format("{deleted_through, 0}.~n", []),
            io_lib:format("{retention, []}.~n", []),
            io_lib:format("{schema_version, 1}.~n", []),
            io_lib:format("{created_at, ~w}.~n", [Now]),
            io_lib:format("{last_rotated_at, ~w}.~n", [Now])
        ]),
        ok = file:write_file(ManifestPath, Bin),
        SegPath = filename:join(
            InstDir, bondy_oplog_wal_segment:filename(0)
        ),
        %% Sanity: the segment file is on disk pre-recovery.
        ?assert(filelib:is_regular(SegPath)),
        ?assertMatch(
            {error, {manifest, {current_not_in_live, 0, []}}},
            bondy_oplog_wal_recovery:recover(
                InstDir,
                instance_id(),
                origin(),
                #{
                    idx_interval_bytes =>
                        ?BONDY_OPLOG_WAL_IDX_DEFAULT_INTERVAL_BYTES,
                    recovery_mode => strict
                }
            )
        ),
        %% C1 says: validation rejects *before* cleanup runs, so the
        %% segment file survives.
        ?assert(filelib:is_regular(SegPath))
    after
        rmrf(Dir)
    end.

recover_refuses_orphan_segment_test() ->
    Dir = mktemp_dir(),
    try
        Opts = #{dir => Dir, origin => origin()},
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        HLC = bondy_oplog_hlc:new(),
        E1 = mk_event(bondy_oplog_hlc:now(HLC), 1),
        {ok, _, _} = bondy_oplog_wal:append(P1, E1),
        ok = bondy_oplog_wal:close(P1),
        InstDir = instance_dir(Dir),
        SegPath = filename:join(
            InstDir, bondy_oplog_wal_segment:filename(0)
        ),
        %% Rewrite segment 0's first 4 bytes (magic) so it fails
        %% header validation on reopen — simulating an orphan or
        %% wrong-origin segment. The writer's `init/1` returns
        %% `{stop, Reason}`, which surfaces to the linked caller as
        %% both `{error, Reason}` AND a linked EXIT signal — trap
        %% exits while exercising this path.
        {ok, Bin} = file:read_file(SegPath),
        <<_OldMagic:4/binary, Rest/binary>> = Bin,
        ok = file:write_file(SegPath, <<0, 0, 0, 0, Rest/binary>>),
        OldFlag = process_flag(trap_exit, true),
        try
            Got = bondy_oplog_wal:start_link(instance_id(), Opts),
            ?assertMatch({error, {head_segment, 0, _}}, Got),
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

%% =============================================================================
%% 7. Rescan recovery (WAL_DESIGN_V2.md §3 PR2)
%% =============================================================================

%% Helper. Appends N events, closes the WAL, returns the segment-file
%% path plus the list of appended events and their on-disk positions
%% so individual frames can be located for corruption injection.
seed_segment(Opts0) ->
    HLC = bondy_oplog_hlc:new(),
    Dir = mktemp_dir(),
    Opts = maps:merge(#{dir => Dir, origin => origin()}, Opts0),
    {ok, P} = bondy_oplog_wal:start_link(instance_id(), Opts),
    Events = generate_events(HLC, 5, 1),
    Positions = [
        begin
            {ok, _, Pos} = bondy_oplog_wal:append(P, E),
            Pos
        end
     || E <- Events
    ],
    ok = bondy_oplog_wal:close(P),
    SegPath = filename:join(
        instance_dir(Dir), bondy_oplog_wal_segment:filename(0)
    ),
    {Dir, SegPath, Events, Positions}.

%% Corrupts a single byte inside the body of the frame at OnDiskOffset
%% by XOR-flipping its low bit. Picks a byte well past the 16-byte
%% header so the magic stays intact (forces a CRC mismatch on decode,
%% not a header-level break).
corrupt_frame_body(SegPath, OnDiskOffset) ->
    {ok, Fd} = file:open(SegPath, [read, write, raw, binary]),
    TargetOff = OnDiskOffset + 24,
    {ok, <<B>>} = file:pread(Fd, TargetOff, 1),
    ok = file:pwrite(Fd, TargetOff, <<(B bxor 1)>>),
    ok = file:close(Fd).

%% Zeroes the 4-byte magic of the frame at OnDiskOffset, simulating a
%% header-level corruption (bad_magic) rather than a body-level one.
zero_frame_magic(SegPath, OnDiskOffset) ->
    {ok, Fd} = file:open(SegPath, [read, write, raw, binary]),
    ok = file:pwrite(Fd, OnDiskOffset, <<0, 0, 0, 0>>),
    ok = file:close(Fd).

rescan_recovers_after_body_corruption_test() ->
    {Dir, SegPath, Events, Positions} = seed_segment(#{}),
    try
        {_, F3Off} = lists:nth(3, Positions),
        corrupt_frame_body(SegPath, F3Off),
        Opts = #{
            dir => Dir,
            origin => origin(),
            recovery_mode => rescan
        },
        {ok, P} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Read = read_all(P),
        ok = bondy_oplog_wal:close(P),
        ?assert(lists:all(fun(E) -> lists:member(E, Events) end, Read)),
        ?assert(length(Read) >= length(Events) - 1),
        E3 = lists:nth(3, Events),
        ?assertNot(lists:member(E3, Read))
    after
        rmrf(Dir)
    end.

rescan_recovers_after_magic_corruption_test() ->
    {Dir, SegPath, Events, Positions} = seed_segment(#{}),
    try
        {_, F3Off} = lists:nth(3, Positions),
        zero_frame_magic(SegPath, F3Off),
        Opts = #{
            dir => Dir,
            origin => origin(),
            recovery_mode => rescan
        },
        {ok, P} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Read = read_all(P),
        ok = bondy_oplog_wal:close(P),
        ?assert(lists:all(fun(E) -> lists:member(E, Events) end, Read)),
        ?assert(length(Read) >= length(Events) - 1),
        E3 = lists:nth(3, Events),
        ?assertNot(lists:member(E3, Read))
    after
        rmrf(Dir)
    end.

strict_mode_truncates_at_first_corruption_test() ->
    {Dir, SegPath, Events, Positions} = seed_segment(#{}),
    try
        {_, F3Off} = lists:nth(3, Positions),
        corrupt_frame_body(SegPath, F3Off),
        Opts = #{dir => Dir, origin => origin()},
        {ok, P} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Read = read_all(P),
        ok = bondy_oplog_wal:close(P),
        ?assertEqual(lists:sublist(Events, length(Read)), Read),
        ?assert(length(Read) < length(Events))
    after
        rmrf(Dir)
    end.

rescan_with_no_corruption_matches_strict_test() ->
    {Dir, _SegPath, Events, _} = seed_segment(#{}),
    try
        Opts = #{
            dir => Dir,
            origin => origin(),
            recovery_mode => rescan
        },
        {ok, P} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Read = read_all(P),
        ok = bondy_oplog_wal:close(P),
        ?assertEqual(Events, Read)
    after
        rmrf(Dir)
    end.

rescan_rewrite_makes_segment_contiguous_test() ->
    %% After rescan with skips, the on-disk segment must not have any
    %% leftover corrupt bytes — reopening with *strict* mode must read
    %% the recovered prefix back without error.
    {Dir, SegPath, Events, Positions} = seed_segment(#{}),
    try
        {_, F3Off} = lists:nth(3, Positions),
        corrupt_frame_body(SegPath, F3Off),
        OptsRescan = #{
            dir => Dir,
            origin => origin(),
            recovery_mode => rescan
        },
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), OptsRescan),
        Read1 = read_all(P1),
        ok = bondy_oplog_wal:close(P1),
        {ok, P2} = bondy_oplog_wal:start_link(
            instance_id(), #{dir => Dir, origin => origin()}
        ),
        Read2 = read_all(P2),
        ok = bondy_oplog_wal:close(P2),
        ?assertEqual(Read1, Read2),
        ?assert(lists:all(fun(E) -> lists:member(E, Events) end, Read1))
    after
        rmrf(Dir)
    end.

rejects_invalid_recovery_mode_test() ->
    Dir = mktemp_dir(),
    try
        OldFlag = process_flag(trap_exit, true),
        try
            Got = bondy_oplog_wal:start_link(
                instance_id(),
                #{
                    dir => Dir,
                    origin => origin(),
                    recovery_mode => not_a_mode
                }
            ),
            ?assertMatch(
                {error, {invalid_opt, recovery_mode, not_a_mode}},
                Got
            ),
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

%% =============================================================================
%% 7. Recovery telemetry — `scanned_bytes` is a real metric
%% =============================================================================

%% Drains the next `[bondy_oplog, wal, recovery]` event for a given
%% instance from the inbox, with a short timeout.
recv_recovery_event(Tag) ->
    receive
        {Tag, [bondy_oplog, wal, recovery], Measurements, Metadata} ->
            {Measurements, Metadata}
    after 2000 ->
        erlang:error(recovery_telemetry_timeout)
    end.

%% Attaches a per-test telemetry handler that forwards `recovery`
%% events to `Self`, returning a function that detaches it.
attach_recovery_handler(Tag) ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = {?MODULE, Tag},
    Handler = fun(Event, M, Md, _) -> Self ! {Tag, Event, M, Md} end,
    ok = telemetry:attach(
        HandlerId, [bondy_oplog, wal, recovery], Handler, undefined
    ),
    fun() -> telemetry:detach(HandlerId) end.

recovery_scanned_bytes_reports_head_walked_test() ->
    HLC = bondy_oplog_hlc:new(),
    Dir = mktemp_dir(),
    Tag = scanned_bytes_clean,
    Detach = attach_recovery_handler(Tag),
    try
        Opts = #{dir => Dir, origin => origin()},
        %% Setup: append a known event volume, close cleanly.
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Events = generate_events(HLC, 8, 1),
        [{ok, _, _} = bondy_oplog_wal:append(P1, E) || E <- Events],
        ok = bondy_oplog_wal:close(P1),
        HeadSize = filelib:file_size(
            filename:join(
                instance_dir(Dir),
                bondy_oplog_wal_segment:filename(0)
            )
        ),
        %% Exercise: reopen; capture the recovery telemetry event.
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        {Measurements, Metadata} = recv_recovery_event(Tag),
        ok = bondy_oplog_wal:close(P2),
        Scanned = maps:get(scanned_bytes, Measurements),
        Frames = maps:get(frames_skipped, Measurements),
        Truncated = maps:get(truncated_bytes, Measurements),
        Outcome = maps:get(outcome, Metadata),
        %% Clean close → no skips, no truncation. Scanned bytes is
        %% exactly the head-segment size minus the segment header.
        ?assertEqual(ok, Outcome),
        ?assertEqual(0, Frames),
        ?assertEqual(0, Truncated),
        ?assertEqual(HeadSize - ?SEG_HEADER, Scanned)
    after
        Detach(),
        rmrf(Dir)
    end.

recovery_scanned_bytes_includes_rescan_skips_test() ->
    HLC = bondy_oplog_hlc:new(),
    Dir = mktemp_dir(),
    Tag = scanned_bytes_rescan,
    Detach = attach_recovery_handler(Tag),
    try
        Opts = #{
            dir => Dir,
            origin => origin(),
            recovery_mode => rescan
        },
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        Events = generate_events(HLC, 6, 1),
        [{ok, _, _} = bondy_oplog_wal:append(P1, E) || E <- Events],
        ok = bondy_oplog_wal:close(P1),
        SegPath = filename:join(
            instance_dir(Dir),
            bondy_oplog_wal_segment:filename(0)
        ),
        HeadSize = filelib:file_size(SegPath),
        %% Corrupt a single byte inside the middle frame's body so the
        %% CRC fails. The scanner must skip the frame and resume; the
        %% skipped byte range must be counted in `scanned_bytes`.
        flip_byte_at(SegPath, ?SEG_HEADER + 24),
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        {Measurements, Metadata} = recv_recovery_event(Tag),
        ok = bondy_oplog_wal:close(P2),
        Scanned = maps:get(scanned_bytes, Measurements),
        Frames = maps:get(frames_skipped, Measurements),
        BytesSkipped = maps:get(bytes_skipped, Measurements),
        ?assertEqual(ok, maps:get(outcome, Metadata)),
        ?assert(Frames >= 1),
        ?assert(BytesSkipped >= 1),
        %% The walk covered every byte that was physically present
        %% below `last_valid_offset` pre-compact, which equals the
        %% original head size minus the segment header. Skipped bytes
        %% are part of that walk and are reported in the same number.
        ?assertEqual(HeadSize - ?SEG_HEADER, Scanned)
    after
        Detach(),
        rmrf(Dir)
    end.

%% Flips a single byte (XORs 16#FF) at the given offset.
flip_byte_at(Path, Offset) ->
    {ok, Fd} = file:open(Path, [read, write, binary, raw]),
    {ok, <<B>>} = file:pread(Fd, Offset, 1),
    ok = file:pwrite(Fd, Offset, <<(B bxor 16#FF)>>),
    ok = file:close(Fd).
