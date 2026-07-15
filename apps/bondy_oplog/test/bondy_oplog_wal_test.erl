%% =============================================================================
%% Unit tests for the `bondy_oplog_wal` writer — single-event append path.
%%
%% Verifies that a fresh WAL is writable, appended events land on disk
%% in order with monotonic HLCs, segment rotation produces a fresh
%% `.qdata` and an updated manifest, and the raw frame stream decodes
%% back to the appended events. Reader / iterator coverage lives in
%% `bondy_oplog_wal_reader_test`; reopen-and-recover coverage in
%% `bondy_oplog_wal_recovery_test`.
%% =============================================================================

-module(bondy_oplog_wal_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-define(MAGIC, ?BONDY_OPLOG_WAL_FRAME_MAGIC).
-define(SEG_HEADER, ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES).
-define(FRAME_HEADER, ?BONDY_OPLOG_WAL_FRAME_HEADER_BYTES).

%% =============================================================================
%% Fixture helpers
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_oplog_wal_test_~p_~p",
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
    <<"wal-test-instance">>.

origin() ->
    <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>.

base_opts() ->
    #{origin => origin()}.

with_wal(Opts, Fun) ->
    Dir = mktemp_dir(),
    try
        AllOpts = (base_opts())#{dir => Dir},
        AllOpts1 = maps:merge(AllOpts, Opts),
        {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), AllOpts1),
        try
            Fun(Pid, Dir)
        after
            ok = bondy_oplog_wal:close(Pid)
        end
    after
        rmrf(Dir)
    end.

%% Builds an event with `Hlc` and a deterministic `Seq`. Each test that
%% wants strictly-monotonic events should source `Hlc` from a single
%% `bondy_oplog_hlc:t()` instance via `bondy_oplog_hlc:now/1`.
mk_event(Hlc, Seq) ->
    Key = bondy_oplog_event:key(Hlc, origin(), Seq),
    bondy_oplog_event:new(Key, {op, Hlc}, undefined).

%% =============================================================================
%% Open / close
%% =============================================================================

open_creates_dir_and_segment_test() ->
    with_wal(#{}, fun(Pid, Dir) ->
        ?assert(filelib:is_dir(filename:join(Dir, instance_id()))),
        ?assert(
            filelib:is_regular(
                filename:join([
                    Dir,
                    instance_id(),
                    ?BONDY_OPLOG_WAL_MANIFEST_FILENAME
                ])
            )
        ),
        ?assert(
            filelib:is_regular(
                filename:join([Dir, instance_id(), "000000000.qdata"])
            )
        ),
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(instance_id(), maps:get(instance_id, Info)),
        ?assertEqual(0, maps:get(current_segment, Info)),
        ?assertEqual(?SEG_HEADER, maps:get(head_offset, Info)),
        ?assertEqual(0, maps:get(append_count, Info)),
        ?assertEqual(per_write, maps:get(fsync_mode, Info))
    end).

%% `init/1` returns `{stop, Reason}` to refuse a bad open. The linked
%% caller (the test process) receives both the proc_lib `{error, _}`
%% reply AND a linked EXIT signal — trap exits while we exercise these
%% paths so the EXIT signal doesn't kill EUnit's test process.
expect_open_error(Expected, Fun) ->
    OldFlag = process_flag(trap_exit, true),
    try
        Got = Fun(),
        ?assertEqual({error, Expected}, Got),
        %% Drain any linked EXIT delivered by the failing gen_server.
        receive
            {'EXIT', _, _} -> ok
        after 0 -> ok
        end
    after
        process_flag(trap_exit, OldFlag)
    end.

%% Reopening a closed WAL must succeed via the recovery path. This is
%% the basic "clean shutdown round-trip" path: append events, close,
%% reopen, verify state is restored. Per-write fsync means everything
%% appended before close survives.
reopen_recovers_clean_wal_test() ->
    HLC = bondy_oplog_hlc:new(),
    Dir = mktemp_dir(),
    try
        Opts = #{dir => Dir, origin => origin()},
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        %% Append a handful of events, capture HLCs.
        Hlcs = [
            begin
                E = mk_event(bondy_oplog_hlc:now(HLC), Seq),
                {ok, H, _} = bondy_oplog_wal:append(P1, E),
                H
            end
         || Seq <- lists:seq(1, 5)
        ],
        InfoBefore = bondy_oplog_wal:info(P1),
        ok = bondy_oplog_wal:close(P1),
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        InfoAfter = bondy_oplog_wal:info(P2),
        ?assertEqual(
            maps:get(current_segment, InfoBefore),
            maps:get(current_segment, InfoAfter)
        ),
        ?assertEqual(
            maps:get(head_offset, InfoBefore),
            maps:get(head_offset, InfoAfter)
        ),
        ?assertEqual(
            maps:get(first_hlc, InfoBefore),
            maps:get(first_hlc, InfoAfter)
        ),
        ?assertEqual(
            maps:get(last_hlc, InfoBefore),
            maps:get(last_hlc, InfoAfter)
        ),
        %% Continue appending after reopen; new HLC must be > all prior.
        E2 = mk_event(bondy_oplog_hlc:now(HLC), 6),
        {ok, H6, _} = bondy_oplog_wal:append(P2, E2),
        ?assert(H6 > lists:last(Hlcs)),
        ok = bondy_oplog_wal:close(P2)
    after
        rmrf(Dir)
    end.

open_rejects_missing_origin_test() ->
    Dir = mktemp_dir(),
    try
        expect_open_error(
            {missing_opt, origin},
            fun() ->
                bondy_oplog_wal:start_link(instance_id(), #{dir => Dir})
            end
        )
    after
        rmrf(Dir)
    end.

open_rejects_missing_dir_test() ->
    expect_open_error(
        {missing_opt, dir},
        fun() ->
            bondy_oplog_wal:start_link(instance_id(), #{origin => origin()})
        end
    ).

open_rejects_invalid_origin_test() ->
    Dir = mktemp_dir(),
    try
        expect_open_error(
            {invalid_origin, invalid_origin},
            fun() ->
                bondy_oplog_wal:start_link(
                    instance_id(), #{dir => Dir, origin => <<>>}
                )
            end
        )
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% Append
%% =============================================================================

single_append_test() ->
    with_wal(#{}, fun(Pid, Dir) ->
        E = mk_event(1, 1),
        {ok, 1, {0, Offset}} = bondy_oplog_wal:append(Pid, E),
        ?assertEqual(?SEG_HEADER, Offset),
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(1, maps:get(append_count, Info)),
        ?assertEqual(1, maps:get(first_hlc, Info)),
        ?assertEqual(1, maps:get(last_hlc, Info)),
        %% Raw scan confirms the frame is on disk and decodes.
        Events = scan_segment(Dir, 0),
        ?assertEqual([E], Events)
    end).

append_1000_events_test() ->
    HLC = bondy_oplog_hlc:new(),
    with_wal(#{}, fun(Pid, Dir) ->
        Events = generate_events(HLC, 1000, 1),
        Results = [bondy_oplog_wal:append(Pid, E) || E <- Events],
        ?assertEqual(1000, length(Results)),
        %% Every append succeeded; HLCs are strictly increasing.
        Hlcs = [Hlc || {ok, Hlc, _} <- Results],
        ?assertEqual(1000, length(Hlcs)),
        ?assert(is_strictly_increasing(Hlcs)),
        %% Default max_segment_bytes is 64 MiB; all frames fit in
        %% segment 0.
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(0, maps:get(current_segment, Info)),
        ?assertEqual(1000, maps:get(append_count, Info)),
        %% Raw scan recovers the events in order.
        Scanned = scan_segment(Dir, 0),
        ?assertEqual(1000, length(Scanned)),
        ?assertEqual(Events, Scanned)
    end).

hlc_returned_matches_event_test() ->
    HLC = bondy_oplog_hlc:new(),
    with_wal(#{}, fun(Pid, _Dir) ->
        Events = generate_events(HLC, 5, 1),
        Pairs = [
            begin
                {ok, ReturnedHlc, _} = bondy_oplog_wal:append(Pid, E),
                {ReturnedHlc,
                    bondy_oplog_event:key_hlc(
                        bondy_oplog_event:key(E)
                    )}
            end
         || E <- Events
        ],
        [?assertEqual(A, B) || {A, B} <- Pairs]
    end).

%% =============================================================================
%% Segment rotation
%% =============================================================================

rotation_creates_new_segment_test() ->
    %% Force rotation after every event by setting a tight segment cap.
    %% A small event encodes to ~50–80 bytes of frame; setting the cap
    %% just above one frame guarantees rotation on the second append.
    %% We use 200 bytes so 1 event fits but 2 do not.
    HLC = bondy_oplog_hlc:new(),
    with_wal(#{max_segment_bytes => 200}, fun(Pid, Dir) ->
        Events = generate_events(HLC, 4, 1),
        Results = [bondy_oplog_wal:append(Pid, E) || E <- Events],
        %% Each event lands in its own segment (0, 1, 2, 3).
        Segs = [Seg || {ok, _, {Seg, _}} <- Results],
        ?assertEqual([0, 1, 2, 3], Segs),
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(3, maps:get(current_segment, Info)),
        %% Four .qdata files on disk.
        [
            ?assert(
                filelib:is_regular(
                    filename:join(
                        [
                            Dir,
                            instance_id(),
                            bondy_oplog_wal_segment:filename(S)
                        ]
                    )
                )
            )
         || S <- [0, 1, 2, 3]
        ],
        %% Each segment holds exactly one event.
        [
            ?assertEqual([lists:nth(S + 1, Events)], scan_segment(Dir, S))
         || S <- [0, 1, 2, 3]
        ]
    end).

manifest_updated_after_rotation_test() ->
    HLC = bondy_oplog_hlc:new(),
    with_wal(#{max_segment_bytes => 200}, fun(Pid, Dir) ->
        Events = generate_events(HLC, 3, 1),
        [bondy_oplog_wal:append(Pid, E) || E <- Events],
        InstanceDir = filename:join(Dir, instance_id()),
        {ok, M} = bondy_oplog_wal_manifest:read(InstanceDir),
        ?assertEqual(2, bondy_oplog_wal_manifest:current_segment(M)),
        Live = bondy_oplog_wal_manifest:live_segments(M),
        ?assertEqual([0, 1, 2], [Id || {Id, _} <- Live]),
        %% Segment 0 and 1 are now sealed; their first_hlc fields
        %% should be the HLC of their single event (the events were
        %% appended in HLC order so segment N's first_hlc is the
        %% (N+1)th HLC in the sequence).
        Hlcs = [
            bondy_oplog_event:key_hlc(bondy_oplog_event:key(E))
         || E <- Events
        ],
        ?assertEqual(lists:nth(1, Hlcs), proplists:get_value(0, Live)),
        ?assertEqual(lists:nth(2, Hlcs), proplists:get_value(1, Live)),
        %% Segment 2 is the head — first_hlc is `undefined` until the
        %% next rotation persists it.
        ?assertEqual(undefined, proplists:get_value(2, Live))
    end).

rotation_resets_offset_test() ->
    HLC = bondy_oplog_hlc:new(),
    with_wal(#{max_segment_bytes => 200}, fun(Pid, _Dir) ->
        Events = generate_events(HLC, 3, 1),
        Results = [bondy_oplog_wal:append(Pid, E) || E <- Events],
        %% Every frame starts at the post-segment-header offset since
        %% each event ends up alone in its segment.
        [
            ?assertEqual(?SEG_HEADER, Off)
         || {ok, _, {_Seg, Off}} <- Results
        ]
    end).

%% =============================================================================
%% sync / close
%% =============================================================================

sync_returns_ok_test() ->
    with_wal(#{}, fun(Pid, _Dir) ->
        E = mk_event(7, 1),
        {ok, _, _} = bondy_oplog_wal:append(Pid, E),
        ?assertEqual(ok, bondy_oplog_wal:sync(Pid))
    end).

close_is_idempotent_test() ->
    Dir = mktemp_dir(),
    try
        Opts = #{dir => Dir, origin => origin()},
        {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ok = bondy_oplog_wal:close(Pid),
        ?assertEqual(ok, bondy_oplog_wal:close(Pid))
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

generate_events(_HLC, 0, _) ->
    [];
generate_events(HLC, N, Seq) ->
    Hlc = bondy_oplog_hlc:now(HLC),
    [mk_event(Hlc, Seq) | generate_events(HLC, N - 1, Seq + 1)].

is_strictly_increasing([_]) ->
    true;
is_strictly_increasing([A, B | Rest]) when A < B ->
    is_strictly_increasing([B | Rest]);
is_strictly_increasing(_) ->
    false.

%% Reads a segment file, skips the 48-byte segment header, walks the
%% frame stream using `bondy_oplog_wal_frame:decode/1`, and returns the
%% decoded events (each frame body is a one-element list under the
%% current single-event batch-of-1 framing).
scan_segment(Dir, SegId) ->
    Path = filename:join(
        [Dir, instance_id(), bondy_oplog_wal_segment:filename(SegId)]
    ),
    {ok, Bin} = file:read_file(Path),
    <<_:?SEG_HEADER/binary, Frames/binary>> = Bin,
    scan_frames(Frames).

scan_frames(<<>>) ->
    [];
scan_frames(Bin) when byte_size(Bin) < ?FRAME_HEADER ->
    %% Trailing bytes — the writer never produces these. Fail loudly
    %% so the test surfaces a regression rather than silently dropping.
    error({trailing_bytes, byte_size(Bin)});
scan_frames(<<?MAGIC:32, FrameLen:32, _/binary>> = Bin) ->
    <<Frame:FrameLen/binary, Rest/binary>> = Bin,
    {ok, Body, _} = bondy_oplog_wal_frame:decode(Frame),
    [Event] = binary_to_term(Body),
    [Event | scan_frames(Rest)].
