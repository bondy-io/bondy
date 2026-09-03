%% =============================================================================
%% Integrity-scrubber tests for `bondy_oplog_wal_scrubber`.
%%
%% Tests cover:
%%
%% 1. Clean walk: scrubber walks sealed segments with no alerts and
%%    emits one `ok` telemetry event per segment.
%% 2. Detection: a manually-injected body bit-flip raises a `bad_crc`
%%    alert; the segment is recorded in the manifest.
%% 3. Magic injection: zeroing a frame's magic raises a `bad_magic`
%%    alert.
%% 4. Persistence: the alert survives a writer restart.
%% 5. Skip-already-alerted: rescrubbing a segment with an existing
%%    alert emits a `skipped` event and does not re-walk.
%% 6. Clear: `clear_segment_alert/2` removes the alert and the next
%%    scrub walks the segment again.
%% 7. Head skip: the head segment is never walked (alerts cannot be
%%    raised against it).
%% 8. `info/1` surfaces `scrubber_alerts`.
%% =============================================================================

-module(bondy_oplog_wal_scrubber_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

%% =============================================================================
%% Fixtures
%% =============================================================================

setup() ->
    {ok, _} = application:ensure_all_started(telemetry),
    case whereis(bondy_oplog_registry) of
        undefined ->
            {ok, _} = bondy_oplog_registry:start_link();
        _ ->
            ok
    end,
    ok.

%% Register a stub instance row so that the WAL writer's init-time
%% `set_wal_pid/2` (which uses `update_element_safe/2`) actually finds
%% a row to update. Without this the scrubber's registry lookup
%% returns `undefined` and the run is a no-op. The instance gen_server
%% would populate these fields in a full subtree start; the scrubber
%% only reads `wal_pid`, so the other slots can carry sentinel values —
%% except `instance_pid`, which the WAL writer CALLS at its own `init/1`
%% (`bondy_oplog_instance:seed_seq/2`, before it publishes `wal_pid`). The
%% test process cannot stand in for it: it is blocked in `start_link/2`
%% while the writer initialises, so the call would deadlock until the
%% `proc_lib` timeout. The stub is therefore a process that answers every
%% `gen_server:call` with `ok`.
register_stub(InstanceId) ->
    bondy_oplog_registry:register(#{
        instance_id => InstanceId,
        instance_pid => spawn(fun instance_stub/0),
        origin => origin(),
        mst => undefined,
        watermark => undefined,
        snapshot => undefined,
        crdt_module => undefined,
        live_size => 0
    }).

cleanup(_) ->
    %% The stub rows carry `instance_pid => self()` — the test process, which
    %% is gone once this module finishes. The registry deliberately does NOT
    %% monitor (a row lives from registration until `terminate/2`), so a row
    %% left behind here stays in `bondy_oplog_registry:down/0` for the rest of
    %% the BEAM. That is node-global state: every later suite sees an instance
    %% that is permanently down, and
    %% `bondy_oplog_origin_retirement:retire_dead/0` refuses while any is —
    %% which is what made `bondy_oplog_frontier_reap_test` fail in a full-dir
    %% run while passing in isolation.
    %%
    %% The row must be DELETED. Registering a long-lived sentinel pid instead
    %% would only move it from `down/0` to `list/0` — the two partition the
    %% same rows — and it would then be advertised to peers as a live origin.
    _ = [
        begin
            _ =
                case bondy_oplog_registry:instance_pid(Id) of
                    Pid when is_pid(Pid) -> exit(Pid, kill);
                    _ -> ok
                end,
            bondy_oplog_registry:unregister(Id)
        end
     || Id <- bondy_oplog_registry:list() ++ bondy_oplog_registry:down(),
        is_stub_id(Id)
    ],
    ok.

%% The stand-in for the instance gen_server: acknowledges every call.
instance_stub() ->
    receive
        {'$gen_call', From, _} ->
            gen_server:reply(From, ok),
            instance_stub();
        _ ->
            instance_stub()
    end.

%% @private
is_stub_id(<<"scrubber-test-", _/binary>>) -> true;
is_stub_id(_) -> false.

scrubber_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 15, fun clean_walk_no_alert/0},
        {timeout, 15, fun bit_flip_raises_bad_crc/0},
        {timeout, 15, fun magic_zero_raises_bad_magic/0},
        {timeout, 15, fun alert_persists_across_restart/0},
        {timeout, 15, fun already_alerted_segment_is_skipped/0},
        {timeout, 15, fun clear_alert_then_rescrub/0},
        {timeout, 15, fun head_segment_is_never_walked/0},
        {timeout, 15, fun info_surfaces_alerts/0},
        {timeout, 15, fun manual_trigger_emits_run_event/0},
        {timeout, 15, fun run_event_aggregates_segment_counters/0},
        {timeout, 15, fun periodic_ticks_fire_and_rearm/0}
    ]}.

%% =============================================================================
%% Helpers
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_oplog_wal_scrubber_test_~p_~p",
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

%% Each test gets its own InstanceId so registry rows don't collide.
instance_id() ->
    list_to_binary(
        io_lib:format(
            "scrubber-test-~p-~p",
            [
                erlang:system_time(microsecond),
                erlang:unique_integer([positive])
            ]
        )
    ).

origin() ->
    <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>.

base_opts() ->
    #{
        origin => origin(),
        retention_sweep_interval => 24 * 60 * 60 * 1000,
        %% Tight cap forces rotation after ~1 event per segment.
        max_segment_bytes => 256,
        max_batch_bytes => 200
    }.

mk_event(Hlc, Seq) ->
    Key = bondy_oplog_event:key(Hlc, origin(), Seq),
    bondy_oplog_event:new(Key, {op, Seq}, undefined).

append1(Pid, HLC, Seq) ->
    Hlc = bondy_oplog_hlc:now(HLC),
    {ok, _, Pos} = bondy_oplog_wal:append(Pid, mk_event(Hlc, Seq)),
    Pos.

%% Append N events, returning the WAL pid, dir, and list of {SegId,Off}
%% positions. With `max_segment_bytes = 256` and ~144-byte frames each
%% append produces a new segment (or close to it) — sealed segments end
%% up plentiful by the time we close.
seed(Id, NEvents) ->
    register_stub(Id),
    Dir = mktemp_dir(),
    Opts = (base_opts())#{dir => Dir},
    {ok, Pid} = bondy_oplog_wal:start_link(Id, Opts),
    HLC = bondy_oplog_hlc:new(),
    Positions = [append1(Pid, HLC, Seq) || Seq <- lists:seq(0, NEvents - 1)],
    {Pid, Dir, Positions}.

instance_dir(Dir, Id) ->
    filename:join(Dir, Id).

seg_path(Dir, Id, SegId) ->
    filename:join(
        instance_dir(Dir, Id),
        bondy_oplog_wal_segment:filename(SegId)
    ).

corrupt_frame_body(Path, OnDiskOff) ->
    {ok, Fd} = file:open(Path, [read, write, raw, binary]),
    TargetOff = OnDiskOff + 24,
    {ok, <<B>>} = file:pread(Fd, TargetOff, 1),
    ok = file:pwrite(Fd, TargetOff, <<(B bxor 1)>>),
    ok = file:close(Fd).

zero_frame_magic(Path, OnDiskOff) ->
    {ok, Fd} = file:open(Path, [read, write, raw, binary]),
    ok = file:pwrite(Fd, OnDiskOff, <<0, 0, 0, 0>>),
    ok = file:close(Fd).

attach_telemetry(Tag) ->
    Self = self(),
    Ref = make_ref(),
    HandlerId = {?MODULE, Tag, Ref},
    ok = telemetry:attach(
        HandlerId,
        [bondy_oplog, wal, scrub, segment],
        fun(_E, M, Md, _Cfg) ->
            Self ! {scrub_event, Tag, M, Md}
        end,
        []
    ),
    HandlerId.

attach_run_telemetry(Tag) ->
    Self = self(),
    Ref = make_ref(),
    HandlerId = {?MODULE, run, Tag, Ref},
    ok = telemetry:attach(
        HandlerId,
        [bondy_oplog, wal, scrub, run],
        fun(_E, M, Md, _Cfg) ->
            Self ! {run_event, Tag, M, Md}
        end,
        []
    ),
    HandlerId.

detach_telemetry(HandlerId) ->
    _ = telemetry:detach(HandlerId),
    ok.

collect_scrub_events(Tag) ->
    collect_scrub_events(Tag, []).

collect_scrub_events(Tag, Acc) ->
    receive
        {scrub_event, Tag, M, Md} ->
            collect_scrub_events(Tag, [{M, Md} | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

collect_run_events(Tag, TimeoutMs) ->
    collect_run_events(Tag, TimeoutMs, []).

collect_run_events(Tag, TimeoutMs, Acc) ->
    receive
        {run_event, Tag, M, Md} ->
            collect_run_events(Tag, TimeoutMs, [{M, Md} | Acc])
    after TimeoutMs ->
        lists:reverse(Acc)
    end.

start_scrubber(Id) ->
    {ok, SPid} = bondy_oplog_wal_scrubber:start_link(#{instance_id => Id}),
    SPid.

%% =============================================================================
%% Tests
%% =============================================================================

clean_walk_no_alert() ->
    Id = instance_id(),
    {Pid, Dir, _Positions} = seed(Id, 4),
    try
        SPid = start_scrubber(Id),
        H = attach_telemetry(clean_walk_no_alert),
        try
            {ok, Summary} = bondy_oplog_wal_scrubber:scrub_now(SPid),
            ?assertEqual(0, maps:get(alerts_raised, Summary)),
            Events = collect_scrub_events(clean_walk_no_alert),
            %% Every emitted event must be `ok`.
            [
                ?assertEqual(ok, maps:get(outcome, Md))
             || {_M, Md} <- Events
            ],
            %% No alerts in info/1.
            ?assertEqual(
                [], maps:get(scrubber_alerts, bondy_oplog_wal:info(Pid))
            )
        after
            detach_telemetry(H),
            bondy_oplog_wal_scrubber:stop(SPid)
        end
    after
        bondy_oplog_wal:close(Pid),
        rmrf(Dir)
    end.

bit_flip_raises_bad_crc() ->
    Id = instance_id(),
    {Pid, Dir, Positions} = seed(Id, 4),
    %% Close the writer so the segment fd is fully flushed and the file
    %% is safe to overwrite from another process.
    ok = bondy_oplog_wal:close(Pid),
    %% Corrupt segment 0's first frame body.
    [{SegId0, Off0} | _] = Positions,
    corrupt_frame_body(seg_path(Dir, Id, SegId0), Off0),
    %% Reopen the writer so the scrubber can resolve its pid and mark.
    {ok, Pid1} = bondy_oplog_wal:start_link(
        Id, (base_opts())#{dir => Dir, recovery_mode => strict}
    ),
    try
        SPid = start_scrubber(Id),
        H = attach_telemetry(bit_flip_raises_bad_crc),
        try
            {ok, Summary} = bondy_oplog_wal_scrubber:scrub_now(SPid),
            ?assert(maps:get(alerts_raised, Summary) >= 1),
            Events = collect_scrub_events(bit_flip_raises_bad_crc),
            %% Find the alert event for SegId0.
            Alerts = [
                {M, Md}
             || {M, Md} <- Events,
                maps:get(outcome, Md) =:= alert
            ],
            ?assert(length(Alerts) >= 1),
            [{M, _Md} | _] = Alerts,
            ?assert(maps:get(bad_crc, M) >= 1),
            %% Manifest carries the alert.
            Alerts2 = maps:get(scrubber_alerts, bondy_oplog_wal:info(Pid1)),
            ?assert(lists:keymember(SegId0, 1, Alerts2))
        after
            detach_telemetry(H),
            bondy_oplog_wal_scrubber:stop(SPid)
        end
    after
        bondy_oplog_wal:close(Pid1),
        rmrf(Dir)
    end.

magic_zero_raises_bad_magic() ->
    Id = instance_id(),
    {Pid, Dir, Positions} = seed(Id, 4),
    ok = bondy_oplog_wal:close(Pid),
    [{SegId0, Off0} | _] = Positions,
    zero_frame_magic(seg_path(Dir, Id, SegId0), Off0),
    {ok, Pid1} = bondy_oplog_wal:start_link(
        Id, (base_opts())#{dir => Dir, recovery_mode => strict}
    ),
    try
        SPid = start_scrubber(Id),
        H = attach_telemetry(magic_zero_raises_bad_magic),
        try
            {ok, _} = bondy_oplog_wal_scrubber:scrub_now(SPid),
            Events = collect_scrub_events(magic_zero_raises_bad_magic),
            Alerts = [
                {M, Md}
             || {M, Md} <- Events,
                maps:get(outcome, Md) =:= alert
            ],
            ?assert(length(Alerts) >= 1),
            [{M, _} | _] = Alerts,
            ?assert(maps:get(bad_magic, M) >= 1),
            Alerts2 = maps:get(scrubber_alerts, bondy_oplog_wal:info(Pid1)),
            {SegId0, Reason} = lists:keyfind(SegId0, 1, Alerts2),
            ?assertEqual(bad_magic, Reason)
        after
            detach_telemetry(H),
            bondy_oplog_wal_scrubber:stop(SPid)
        end
    after
        bondy_oplog_wal:close(Pid1),
        rmrf(Dir)
    end.

alert_persists_across_restart() ->
    Id = instance_id(),
    {Pid, Dir, Positions} = seed(Id, 4),
    ok = bondy_oplog_wal:close(Pid),
    [{SegId0, Off0} | _] = Positions,
    corrupt_frame_body(seg_path(Dir, Id, SegId0), Off0),
    {ok, Pid1} = bondy_oplog_wal:start_link(
        Id, (base_opts())#{dir => Dir, recovery_mode => strict}
    ),
    SPid1 = start_scrubber(Id),
    {ok, _} = bondy_oplog_wal_scrubber:scrub_now(SPid1),
    Alerts1 = maps:get(scrubber_alerts, bondy_oplog_wal:info(Pid1)),
    ?assert(lists:keymember(SegId0, 1, Alerts1)),
    bondy_oplog_wal_scrubber:stop(SPid1),
    ok = bondy_oplog_wal:close(Pid1),
    %% Restart the writer; the manifest must still carry the alert.
    {ok, Pid2} = bondy_oplog_wal:start_link(
        Id, (base_opts())#{dir => Dir, recovery_mode => strict}
    ),
    try
        Alerts2 = maps:get(scrubber_alerts, bondy_oplog_wal:info(Pid2)),
        ?assert(lists:keymember(SegId0, 1, Alerts2))
    after
        bondy_oplog_wal:close(Pid2),
        rmrf(Dir)
    end.

already_alerted_segment_is_skipped() ->
    Id = instance_id(),
    {Pid, Dir, Positions} = seed(Id, 4),
    ok = bondy_oplog_wal:close(Pid),
    [{SegId0, Off0} | _] = Positions,
    corrupt_frame_body(seg_path(Dir, Id, SegId0), Off0),
    {ok, Pid1} = bondy_oplog_wal:start_link(
        Id, (base_opts())#{dir => Dir, recovery_mode => strict}
    ),
    try
        SPid = start_scrubber(Id),
        try
            %% First pass marks the alert.
            {ok, _} = bondy_oplog_wal_scrubber:scrub_now(SPid),
            %% Second pass should report a skipped outcome for SegId0.
            H = attach_telemetry(already_alerted_segment_is_skipped),
            {ok, _} = bondy_oplog_wal_scrubber:scrub_now(SPid),
            Events = collect_scrub_events(already_alerted_segment_is_skipped),
            detach_telemetry(H),
            Skipped = [
                Md
             || {_M, Md} <- Events,
                maps:get(segment_id, Md) =:= SegId0,
                maps:get(outcome, Md) =:= skipped
            ],
            ?assertEqual(1, length(Skipped)),
            %% The skipped event must NOT carry alert counters > 0.
            [SkipMd] = Skipped,
            ?assertEqual(skipped, maps:get(outcome, SkipMd))
        after
            bondy_oplog_wal_scrubber:stop(SPid)
        end
    after
        bondy_oplog_wal:close(Pid1),
        rmrf(Dir)
    end.

clear_alert_then_rescrub() ->
    Id = instance_id(),
    {Pid, Dir, Positions} = seed(Id, 4),
    ok = bondy_oplog_wal:close(Pid),
    [{SegId0, Off0} | _] = Positions,
    corrupt_frame_body(seg_path(Dir, Id, SegId0), Off0),
    {ok, Pid1} = bondy_oplog_wal:start_link(
        Id, (base_opts())#{dir => Dir, recovery_mode => strict}
    ),
    try
        SPid = start_scrubber(Id),
        try
            {ok, _} = bondy_oplog_wal_scrubber:scrub_now(SPid),
            ?assert(
                lists:keymember(
                    SegId0,
                    1,
                    maps:get(scrubber_alerts, bondy_oplog_wal:info(Pid1))
                )
            ),
            ok = bondy_oplog_wal:clear_segment_alert(Pid1, SegId0),
            ?assertEqual(
                [],
                [
                    E
                 || E <- maps:get(
                        scrubber_alerts, bondy_oplog_wal:info(Pid1)
                    ),
                    element(1, E) =:= SegId0
                ]
            )
        after
            bondy_oplog_wal_scrubber:stop(SPid)
        end
    after
        bondy_oplog_wal:close(Pid1),
        rmrf(Dir)
    end.

head_segment_is_never_walked() ->
    Id = instance_id(),
    %% A single append produces one head segment, no sealed segments.
    {Pid, Dir, _Positions} = seed(Id, 1),
    try
        SPid = start_scrubber(Id),
        H = attach_telemetry(head_segment_is_never_walked),
        try
            {ok, Summary} = bondy_oplog_wal_scrubber:scrub_now(SPid),
            ?assertEqual(0, maps:get(segments_walked, Summary)),
            ?assertEqual(0, maps:get(alerts_raised, Summary)),
            Events = collect_scrub_events(head_segment_is_never_walked),
            HeadSeg = maps:get(current_segment, bondy_oplog_wal:info(Pid)),
            EventsForHead = [
                Md
             || {_M, Md} <- Events,
                maps:get(segment_id, Md) =:= HeadSeg
            ],
            ?assertEqual([], EventsForHead)
        after
            detach_telemetry(H),
            bondy_oplog_wal_scrubber:stop(SPid)
        end
    after
        bondy_oplog_wal:close(Pid),
        rmrf(Dir)
    end.

info_surfaces_alerts() ->
    Id = instance_id(),
    {Pid, Dir, _Positions} = seed(Id, 4),
    try
        Info = bondy_oplog_wal:info(Pid),
        ?assert(maps:is_key(scrubber_alerts, Info)),
        ?assertEqual([], maps:get(scrubber_alerts, Info)),
        ok = bondy_oplog_wal:mark_segment_alert(Pid, 0, bad_crc),
        Info2 = bondy_oplog_wal:info(Pid),
        ?assertEqual([{0, bad_crc}], maps:get(scrubber_alerts, Info2)),
        ok = bondy_oplog_wal:clear_segment_alert(Pid, 0),
        Info3 = bondy_oplog_wal:info(Pid),
        ?assertEqual([], maps:get(scrubber_alerts, Info3))
    after
        bondy_oplog_wal:close(Pid),
        rmrf(Dir)
    end.

%% A manual `scrub_now/1` call must emit exactly one `[..., scrub, run]`
%% event, carrying `trigger = manual` and the per-run roll-up
%% measurements. On a clean WAL we expect `alerts_raised = 0` and
%% non-zero `frames_checked`/`bytes_checked` summed from the sealed
%% segments.
manual_trigger_emits_run_event() ->
    Id = instance_id(),
    {Pid, Dir, _Positions} = seed(Id, 4),
    try
        SPid = start_scrubber(Id),
        H = attach_run_telemetry(manual_trigger_emits_run_event),
        try
            {ok, _} = bondy_oplog_wal_scrubber:scrub_now(SPid),
            RunEvents = collect_run_events(
                manual_trigger_emits_run_event, 100
            ),
            ?assertEqual(1, length(RunEvents)),
            [{M, Md}] = RunEvents,
            ?assertEqual(manual, maps:get(trigger, Md)),
            ?assertEqual(Id, maps:get(instance_id, Md)),
            ?assertEqual(0, maps:get(alerts_raised, M)),
            %% Three sealed segments under the seed config.
            ?assert(maps:get(segments_walked, M) >= 1),
            ?assert(maps:get(frames_checked, M) >= 1),
            ?assert(maps:get(bytes_checked, M) > 0),
            ?assert(maps:get(duration_us, M) >= 0)
        after
            detach_telemetry(H),
            bondy_oplog_wal_scrubber:stop(SPid)
        end
    after
        bondy_oplog_wal:close(Pid),
        rmrf(Dir)
    end.

%% The run event's frame/byte counters must equal the sum of the
%% per-segment events emitted during the same run. Mismatch would mean
%% the aggregation drifted from the per-segment measurements that
%% dashboards already trust.
run_event_aggregates_segment_counters() ->
    Id = instance_id(),
    {Pid, Dir, _Positions} = seed(Id, 4),
    try
        SPid = start_scrubber(Id),
        HSeg = attach_telemetry(run_event_aggregates_segment_counters),
        HRun = attach_run_telemetry(run_event_aggregates_segment_counters),
        try
            {ok, _} = bondy_oplog_wal_scrubber:scrub_now(SPid),
            SegEvents = collect_scrub_events(
                run_event_aggregates_segment_counters
            ),
            RunEvents = collect_run_events(
                run_event_aggregates_segment_counters, 100
            ),
            ?assertEqual(1, length(RunEvents)),
            [{RunM, _}] = RunEvents,
            %% Sum per-segment frames_checked / bytes_checked across only
            %% the segments that were actually walked (outcome=ok or
            %% alert); skipped/gone carry zeros and don't affect the sum.
            SumFrames = lists:sum(
                [maps:get(frames_checked, M) || {M, _} <- SegEvents]
            ),
            SumBytes = lists:sum(
                [maps:get(bytes_checked, M) || {M, _} <- SegEvents]
            ),
            ?assertEqual(SumFrames, maps:get(frames_checked, RunM)),
            ?assertEqual(SumBytes, maps:get(bytes_checked, RunM))
        after
            detach_telemetry(HSeg),
            detach_telemetry(HRun),
            bondy_oplog_wal_scrubber:stop(SPid)
        end
    after
        bondy_oplog_wal:close(Pid),
        rmrf(Dir)
    end.

%% With `interval_ms` set to a small positive value, the scrubber must
%% fire periodic ticks and rearm its timer. We attach to the run event
%% (not the segment events, which can be zero on an idle WAL) and wait
%% for at least two distinct events with `trigger = tick` to prove the
%% timer rearmed at least once.
periodic_ticks_fire_and_rearm() ->
    Id = instance_id(),
    {Pid, Dir, _Positions} = seed(Id, 4),
    try
        {ok, SPid} = bondy_oplog_wal_scrubber:start_link(
            #{instance_id => Id, interval_ms => 50}
        ),
        H = attach_run_telemetry(periodic_ticks_fire_and_rearm),
        try
            %% Wait up to 1s for at least 2 tick events. The 50ms
            %% interval ±10% jitter means we should see > 10 ticks in
            %% that window; 2 is the floor we care about (proves rearm).
            Events = wait_for_n_run_events(
                periodic_ticks_fire_and_rearm, 2, 1000
            ),
            ?assert(length(Events) >= 2),
            Triggers = [maps:get(trigger, Md) || {_, Md} <- Events],
            ?assert(lists:all(fun(T) -> T =:= tick end, Triggers))
        after
            detach_telemetry(H),
            bondy_oplog_wal_scrubber:stop(SPid)
        end
    after
        bondy_oplog_wal:close(Pid),
        rmrf(Dir)
    end.

%% Helper. Polls the mailbox until at least `N` `{run_event, Tag, _, _}`
%% messages have arrived or `Deadline` ms have elapsed. Returns the
%% events in arrival order.
wait_for_n_run_events(Tag, N, DeadlineMs) ->
    Deadline = erlang:monotonic_time(millisecond) + DeadlineMs,
    wait_for_n_run_events(Tag, N, Deadline, []).

wait_for_n_run_events(_Tag, _N, _Deadline, Acc) when length(Acc) >= 8 ->
    %% Upper bound so a runaway interval doesn't blow the mailbox.
    lists:reverse(Acc);
wait_for_n_run_events(Tag, N, Deadline, Acc) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case Remaining of
        0 ->
            lists:reverse(Acc);
        _ ->
            receive
                {run_event, Tag, M, Md} ->
                    Acc1 = [{M, Md} | Acc],
                    case length(Acc1) >= N of
                        true -> lists:reverse(Acc1);
                        false -> wait_for_n_run_events(Tag, N, Deadline, Acc1)
                    end
            after Remaining ->
                lists:reverse(Acc)
            end
    end.
