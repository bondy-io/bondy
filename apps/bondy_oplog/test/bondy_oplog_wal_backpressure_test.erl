%% =============================================================================
%% Backpressure + telemetry tests for `bondy_oplog_wal`.
%%
%% Covers WAL_DESIGN §13.5 (info shape), §14 (config), §15 (telemetry):
%%
%% 1. `bytes_total` tracks the on-disk size of all live segments.
%% 2. `max_total_wal_size` is enforced — appends past the cap are
%%    refused with `{error, wal_full}`.
%% 3. `max_live_segments` is enforced — once at the cap, appends are
%%    refused regardless of head capacity.
%% 4. `[bondy_oplog, wal, wal_full]` fires on refusal and is debounced.
%% 5. `[bondy_oplog, wal, append]`, `fsync`, `rotate`,
%%    `retention_sweep`, `durable` measurement shapes match §15.
%% 6. `info/1` exposes `bytes_total`, `live_segments_count`,
%%    `backpressure`, `head_lag_ms`, `max_total_wal_size`,
%%    `max_live_segments`.
%% 7. Init-time validation rejects malformed backpressure opts.
%% =============================================================================

-module(bondy_oplog_wal_backpressure_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

%% =============================================================================
%% Fixtures
%% =============================================================================

setup() ->
    {ok, _} = application:ensure_all_started(telemetry),
    ok.

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_oplog_wal_backpressure_test_~p_~p",
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
    <<"wal-backpressure-test-instance">>.

origin() ->
    <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>.

base_opts() ->
    #{
        origin => origin(),
        retention_sweep_interval => 24 * 60 * 60 * 1000
    }.

with_wal(Opts, Fun) ->
    setup(),
    Dir = mktemp_dir(),
    try
        AllOpts0 = (base_opts())#{dir => Dir},
        AllOpts = maps:merge(AllOpts0, Opts),
        {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), AllOpts),
        try
            Fun(Pid, Dir)
        after
            ok = bondy_oplog_wal:close(Pid)
        end
    after
        rmrf(Dir)
    end.

mk_event(Hlc, Seq) ->
    Key = bondy_oplog_event:key(Hlc, origin(), Seq),
    bondy_oplog_event:new(Key, {op, Seq}, undefined).

append1(Pid, HLC, Seq) ->
    Hlc = bondy_oplog_hlc:now(HLC),
    E = mk_event(Hlc, Seq),
    bondy_oplog_wal:append(Pid, E).

%% Attach a telemetry handler that forwards events to `self()` so the
%% test can assert on the emitted measurements/metadata.
attach_capture(Events) ->
    Ref = make_ref(),
    Pid = self(),
    HandlerId = {?MODULE, Ref, erlang:unique_integer()},
    ok = telemetry:attach_many(
        HandlerId,
        Events,
        fun(Event, M, Meta, _) ->
            Pid ! {telemetry, Ref, Event, M, Meta}
        end,
        undefined
    ),
    {Ref, HandlerId}.

detach(HandlerId) ->
    _ = telemetry:detach(HandlerId),
    ok.

recv_events(_Ref, 0, Acc) ->
    lists:reverse(Acc);
recv_events(Ref, N, Acc) ->
    receive
        {telemetry, Ref, E, M, Meta} ->
            recv_events(Ref, N - 1, [{E, M, Meta} | Acc])
    after 500 ->
        lists:reverse(Acc)
    end.

drain(Ref) ->
    receive
        {telemetry, Ref, _, _, _} -> drain(Ref)
    after 0 -> ok
    end.

%% =============================================================================
%% Tests
%% =============================================================================

bytes_total_starts_at_segment_header_test() ->
    with_wal(#{}, fun(Pid, _) ->
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(
            ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES,
            maps:get(bytes_total, Info)
        ),
        ?assertEqual(1, maps:get(live_segments_count, Info))
    end).

bytes_total_grows_with_appends_test() ->
    with_wal(#{}, fun(Pid, _) ->
        Hdr = ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES,
        Before = maps:get(bytes_total, bondy_oplog_wal:info(Pid)),
        ?assertEqual(Hdr, Before),
        HLC = bondy_oplog_hlc:new(),
        {ok, _, _} = append1(Pid, HLC, 0),
        After = maps:get(bytes_total, bondy_oplog_wal:info(Pid)),
        ?assert(After > Before)
    end).

bytes_total_recomputed_on_reopen_test() ->
    setup(),
    Dir = mktemp_dir(),
    try
        Opts = (base_opts())#{dir => Dir},
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        HLC = bondy_oplog_hlc:new(),
        [{ok, _, _} = append1(P1, HLC, S) || S <- lists:seq(0, 4)],
        BytesA = maps:get(bytes_total, bondy_oplog_wal:info(P1)),
        ok = bondy_oplog_wal:close(P1),
        %% Reopen
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        try
            BytesB = maps:get(bytes_total, bondy_oplog_wal:info(P2)),
            %% Reopen recomputes from disk; should match (or be very
            %% close to) the pre-close total.
            ?assertEqual(BytesA, BytesB)
        after
            ok = bondy_oplog_wal:close(P2)
        end
    after
        rmrf(Dir)
    end.

bytes_total_decreases_after_sweep_test() ->
    Opts = #{
        max_segment_bytes => 256,
        max_batch_bytes => 200,
        min_live_segments => 1
    },
    with_wal(Opts, fun(Pid, _) ->
        HLC = bondy_oplog_hlc:new(),
        [{ok, _, _} = append1(Pid, HLC, S) || S <- lists:seq(0, 4)],
        Before = maps:get(bytes_total, bondy_oplog_wal:info(Pid)),
        ok = bondy_oplog_wal:set_committed_segment(Pid, 9999),
        ok = bondy_oplog_wal:advance_snapshot_watermark(
            Pid, bondy_oplog_hlc:now(HLC) + 1
        ),
        After = maps:get(bytes_total, bondy_oplog_wal:info(Pid)),
        ?assert(After < Before)
    end).

wal_full_when_max_total_size_exceeded_test() ->
    Hdr = ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES,
    %% Cap exactly at the segment header so `bytes_total = Hdr =
    %% max_total_wal_size` and the very next frame is refused. The
    %% writer's `backpressure` field reflects the at-cap state.
    Opts = #{max_total_wal_size => Hdr, max_segment_bytes => 8192},
    with_wal(Opts, fun(Pid, _) ->
        HLC = bondy_oplog_hlc:new(),
        ?assertEqual({error, wal_full}, append1(Pid, HLC, 0)),
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(0, maps:get(append_count, Info)),
        ?assertMatch(
            {hard, max_total_wal_size},
            maps:get(backpressure, Info)
        )
    end).

wal_full_when_max_live_segments_reached_test() ->
    Opts = #{
        max_live_segments => 1,
        max_segment_bytes => 256,
        max_batch_bytes => 200
    },
    with_wal(Opts, fun(Pid, _) ->
        %% Live count starts at 1 (the bootstrap head). The cap is
        %% hit immediately, so any append is refused.
        HLC = bondy_oplog_hlc:new(),
        ?assertEqual({error, wal_full}, append1(Pid, HLC, 0)),
        Info = bondy_oplog_wal:info(Pid),
        ?assertMatch(
            {hard, max_live_segments},
            maps:get(backpressure, Info)
        )
    end).

invalid_max_total_wal_size_rejected_at_init_test() ->
    setup(),
    Dir = mktemp_dir(),
    try
        OldFlag = process_flag(trap_exit, true),
        try
            Got = bondy_oplog_wal:start_link(
                instance_id(),
                #{
                    dir => Dir,
                    origin => origin(),
                    max_total_wal_size => 0
                }
            ),
            ?assertEqual({error, {invalid_opt, max_total_wal_size, 0}}, Got),
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

invalid_max_live_segments_rejected_at_init_test() ->
    setup(),
    Dir = mktemp_dir(),
    try
        OldFlag = process_flag(trap_exit, true),
        try
            Got = bondy_oplog_wal:start_link(
                instance_id(),
                #{
                    dir => Dir,
                    origin => origin(),
                    max_live_segments => -1
                }
            ),
            ?assertEqual({error, {invalid_opt, max_live_segments, -1}}, Got),
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

wal_full_telemetry_emitted_test() ->
    setup(),
    Hdr = ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES,
    Opts = #{max_total_wal_size => Hdr, max_segment_bytes => 8192},
    {Ref, HandlerId} = attach_capture([[bondy_oplog, wal, wal_full]]),
    try
        with_wal(Opts, fun(Pid, _) ->
            HLC = bondy_oplog_hlc:new(),
            ?assertEqual({error, wal_full}, append1(Pid, HLC, 0))
        end),
        [{Event, M, Meta} | _] = recv_events(Ref, 1, []),
        ?assertEqual([bondy_oplog, wal, wal_full], Event),
        ?assertEqual(max_total_wal_size, maps:get(reason, Meta)),
        ?assert(maps:get(bytes_total, M) >= Hdr),
        ?assert(is_integer(maps:get(live_segments_count, M)))
    after
        detach(HandlerId)
    end.

wal_full_telemetry_debounced_test() ->
    setup(),
    Hdr = ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES,
    Opts = #{max_total_wal_size => Hdr, max_segment_bytes => 8192},
    {Ref, HandlerId} = attach_capture([[bondy_oplog, wal, wal_full]]),
    try
        with_wal(Opts, fun(Pid, _) ->
            HLC = bondy_oplog_hlc:new(),
            [
                ?assertEqual({error, wal_full}, append1(Pid, HLC, S))
             || S <- lists:seq(0, 9)
            ]
        end),
        Events = recv_events(Ref, 10, []),
        %% Debounce: only the first refusal in the window emits.
        ?assertEqual(1, length(Events))
    after
        detach(HandlerId)
    end.

append_telemetry_emitted_test() ->
    setup(),
    {Ref, HandlerId} = attach_capture([[bondy_oplog, wal, append]]),
    try
        with_wal(#{}, fun(Pid, _) ->
            HLC = bondy_oplog_hlc:new(),
            {ok, Hlc, _} = append1(Pid, HLC, 0),
            [{Event, M, Meta}] = recv_events(Ref, 1, []),
            ?assertEqual([bondy_oplog, wal, append], Event),
            ?assert(is_integer(maps:get(frame_len, M))),
            ?assert(maps:get(frame_len, M) > 0),
            ?assertEqual(
                maps:get(frame_len, M) - 16,
                maps:get(body_len, M)
            ),
            ?assertEqual(1, maps:get(batch_size, M)),
            ?assertEqual(Hlc, maps:get(hlc, M)),
            ?assertEqual(instance_id(), maps:get(instance_id, Meta)),
            ?assert(is_integer(maps:get(segment, Meta))),
            ?assert(is_integer(maps:get(offset, Meta)))
        end)
    after
        detach(HandlerId)
    end.

fsync_telemetry_emitted_test() ->
    setup(),
    {Ref, HandlerId} = attach_capture([[bondy_oplog, wal, fsync]]),
    try
        with_wal(#{}, fun(Pid, _) ->
            HLC = bondy_oplog_hlc:new(),
            {ok, _, _} = append1(Pid, HLC, 0),
            %% per_write mode: fsync was issued during the append.
            [{Event, M, Meta} | _] = recv_events(Ref, 1, []),
            ?assertEqual([bondy_oplog, wal, fsync], Event),
            ?assert(is_integer(maps:get(duration_us, M))),
            ?assert(is_integer(maps:get(bytes_synced, M))),
            ?assertEqual(per_write, maps:get(mode, Meta))
        end)
    after
        detach(HandlerId)
    end.

durable_telemetry_emitted_test() ->
    setup(),
    {Ref, HandlerId} = attach_capture([[bondy_oplog, wal, durable]]),
    try
        with_wal(#{}, fun(Pid, _) ->
            HLC = bondy_oplog_hlc:new(),
            drain(Ref),
            {ok, _, _} = append1(Pid, HLC, 0),
            [{Event, M, Meta} | _] = recv_events(Ref, 1, []),
            ?assertEqual([bondy_oplog, wal, durable], Event),
            ?assert(is_integer(maps:get(durable_offset, M))),
            ?assert(is_integer(maps:get(segment, Meta)))
        end)
    after
        detach(HandlerId)
    end.

rotate_telemetry_emitted_test() ->
    setup(),
    {Ref, HandlerId} = attach_capture([[bondy_oplog, wal, rotate]]),
    try
        with_wal(
            #{max_segment_bytes => 256, max_batch_bytes => 200},
            fun(Pid, _) ->
                HLC = bondy_oplog_hlc:new(),
                [{ok, _, _} = append1(Pid, HLC, S) || S <- lists:seq(0, 2)],
                Events = recv_events(Ref, 3, []),
                ?assert(length(Events) >= 1),
                [{Event, M, Meta} | _] = Events,
                ?assertEqual([bondy_oplog, wal, rotate], Event),
                ?assertEqual(size, maps:get(reason, Meta)),
                ?assert(is_integer(maps:get(old_size_bytes, M))),
                ?assert(
                    maps:get(new_segment, Meta) >
                        maps:get(old_segment, Meta)
                )
            end
        )
    after
        detach(HandlerId)
    end.

retention_sweep_telemetry_emitted_test() ->
    setup(),
    {Ref, HandlerId} = attach_capture(
        [[bondy_oplog, wal, retention_sweep]]
    ),
    try
        Opts = #{
            max_segment_bytes => 256,
            max_batch_bytes => 200,
            min_live_segments => 1
        },
        with_wal(Opts, fun(Pid, _) ->
            HLC = bondy_oplog_hlc:new(),
            [{ok, _, _} = append1(Pid, HLC, S) || S <- lists:seq(0, 4)],
            drain(Ref),
            {ok, _, _} = bondy_oplog_wal:retention_sweep(Pid),
            [{Event, M, Meta} | _] = recv_events(Ref, 1, []),
            ?assertEqual([bondy_oplog, wal, retention_sweep], Event),
            ?assert(is_integer(maps:get(deleted_segments, M))),
            ?assert(is_integer(maps:get(freed_bytes, M))),
            ?assert(is_integer(maps:get(duration_us, M))),
            ?assertEqual(instance_id(), maps:get(instance_id, Meta))
        end)
    after
        detach(HandlerId)
    end.

info_exposes_backpressure_fields_test() ->
    with_wal(
        #{
            max_total_wal_size => 1024 * 1024,
            max_live_segments => 4
        },
        fun(Pid, _) ->
            Info = bondy_oplog_wal:info(Pid),
            ?assertEqual(1024 * 1024, maps:get(max_total_wal_size, Info)),
            ?assertEqual(4, maps:get(max_live_segments, Info)),
            ?assertEqual(ok, maps:get(backpressure, Info)),
            ?assertEqual(undefined, maps:get(head_lag_ms, Info)),
            ?assert(is_integer(maps:get(bytes_total, Info))),
            ?assert(is_integer(maps:get(live_segments_count, Info)))
        end
    ).

head_lag_ms_populated_after_append_test() ->
    with_wal(#{}, fun(Pid, _) ->
        HLC = bondy_oplog_hlc:new(),
        ?assertEqual(
            undefined,
            maps:get(head_lag_ms, bondy_oplog_wal:info(Pid))
        ),
        {ok, _, _} = append1(Pid, HLC, 0),
        timer:sleep(20),
        Info = bondy_oplog_wal:info(Pid),
        Lag = maps:get(head_lag_ms, Info),
        ?assert(is_integer(Lag)),
        ?assert(Lag >= 0)
    end).
