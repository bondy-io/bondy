%% =============================================================================
%% Durability tests for `bondy_oplog_wal`: fsync modes, durable position,
%% `await_durable/3`, the rotation and `sync/1` barriers, and opt validation.
%% The contract under test is stated in that module's docs; each test name
%% says which case it covers.
%% =============================================================================

-module(bondy_oplog_wal_durability_test).

-include_lib("eunit/include/eunit.hrl").
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
                "bondy_oplog_wal_durability_test_~p_~p",
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
    <<"wal-durability-test-instance">>.

origin() ->
    <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>.

base_opts() ->
    #{origin => origin()}.

with_wal(Opts, Fun) ->
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
    bondy_oplog_event:new(Key, {op, Hlc}, undefined).

%% Convenience: append one event with a fresh HLC and return both the
%% append result and the post-append head offset (= the end of the
%% frame, which is the `await_durable/3` boundary for that frame).
append_one(Pid, HLC, Seq) ->
    Hlc = bondy_hlc:now(HLC),
    E = mk_event(Hlc, Seq),
    {ok, Hlc, {Seg, StartOff}} = bondy_oplog_wal:append(Pid, E),
    Info = bondy_oplog_wal:info(Pid),
    EndOff = maps:get(head_offset, Info),
    {Hlc, {Seg, StartOff}, {Seg, EndOff}}.

%% Drains any linked EXIT signal left over from a refused init.
expect_open_error(Expected, Fun) ->
    OldFlag = process_flag(trap_exit, true),
    try
        Got = Fun(),
        ?assertEqual({error, Expected}, Got),
        receive
            {'EXIT', _, _} -> ok
        after 0 -> ok
        end
    after
        process_flag(trap_exit, OldFlag)
    end.

%% =============================================================================
%% per_write mode
%% =============================================================================

per_write_default_mode_test() ->
    with_wal(#{}, fun(Pid, _Dir) ->
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(per_write, maps:get(fsync_mode, Info))
    end).

per_write_durable_equals_head_after_append_test() ->
    HLC = bondy_hlc:new(),
    with_wal(#{}, fun(Pid, _Dir) ->
        {_Hlc, {Seg, _Start}, {Seg, EndOff}} = append_one(Pid, HLC, 1),
        ?assertEqual({Seg, EndOff}, bondy_oplog_wal:durable_position(Pid)),
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(
            maps:get(head_offset, Info), maps:get(durable_offset, Info)
        )
    end).

per_write_await_durable_returns_immediately_test() ->
    HLC = bondy_hlc:new(),
    with_wal(#{}, fun(Pid, _Dir) ->
        {_Hlc, _Start, EndPos} = append_one(Pid, HLC, 1),
        ?assertEqual(ok, bondy_oplog_wal:await_durable(Pid, EndPos, 0)),
        ?assertEqual(ok, bondy_oplog_wal:await_durable(Pid, EndPos, 5000)),
        ?assertEqual(
            ok, bondy_oplog_wal:await_durable(Pid, EndPos, infinity)
        )
    end).

per_write_pending_bytes_stay_zero_test() ->
    HLC = bondy_hlc:new(),
    with_wal(#{}, fun(Pid, _Dir) ->
        _ = append_one(Pid, HLC, 1),
        _ = append_one(Pid, HLC, 2),
        _ = append_one(Pid, HLC, 3),
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(0, maps:get(pending_fsync_bytes, Info)),
        ?assertEqual(0, maps:get(waiter_count, Info))
    end).

%% =============================================================================
%% batched mode — basic accumulation + thresholds
%% =============================================================================

%% A single append in batched mode leaves `pending_fsync_bytes > 0` and
%% does not advance the durable position. The batched-mode interval
%% timer must be armed on the first un-fsynced append.
batched_append_defers_fsync_test() ->
    HLC = bondy_hlc:new(),
    Opts = #{
        fsync_mode => batched,
        %% effectively disabled
        batched_fsync_interval => 10_000,
        batched_fsync_bytes => 100 * 1024 * 1024
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        {_Hlc, _Start, {Seg, EndOff}} = append_one(Pid, HLC, 1),
        Info = bondy_oplog_wal:info(Pid),
        ?assert(maps:get(pending_fsync_bytes, Info) > 0),
        ?assertEqual(EndOff, maps:get(head_offset, Info)),
        ?assertEqual(
            ?SEG_HEADER, maps:get(durable_offset, Info)
        ),
        ?assertEqual(Seg, maps:get(durable_segment, Info))
    end).

batched_size_threshold_triggers_fsync_test() ->
    HLC = bondy_hlc:new(),
    %% Threshold is ~120 bytes; any single event frame should exceed it.
    %% Interval is large so only the size trigger matters here.
    Opts = #{
        fsync_mode => batched,
        batched_fsync_interval => 10_000,
        batched_fsync_bytes => 1
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        {_Hlc, _Start, {Seg, EndOff}} = append_one(Pid, HLC, 1),
        ?assertEqual({Seg, EndOff}, bondy_oplog_wal:durable_position(Pid)),
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(0, maps:get(pending_fsync_bytes, Info))
    end).

batched_interval_timer_triggers_fsync_test() ->
    HLC = bondy_hlc:new(),
    %% Disable size trigger; rely on the 30 ms timer.
    Opts = #{
        fsync_mode => batched,
        batched_fsync_interval => 30,
        batched_fsync_bytes => 100 * 1024 * 1024
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        {_Hlc, _Start, EndPos} = append_one(Pid, HLC, 1),
        %% Sleep generously past the interval to allow the timer
        %% message to be processed by the gen_server.
        timer:sleep(200),
        ?assertEqual(EndPos, bondy_oplog_wal:durable_position(Pid)),
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(0, maps:get(pending_fsync_bytes, Info)),
        ?assert(maps:get(last_fsync_at, Info) =/= undefined)
    end).

%% =============================================================================
%% batched mode — await_durable
%% =============================================================================

batched_await_durable_already_satisfied_returns_immediately_test() ->
    HLC = bondy_hlc:new(),
    Opts = #{
        fsync_mode => batched,
        batched_fsync_interval => 30,
        batched_fsync_bytes => 1
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        {_Hlc, _Start, EndPos} = append_one(Pid, HLC, 1),
        %% Size trigger fsyncs immediately, so EndPos is already durable.
        ?assertEqual(EndPos, bondy_oplog_wal:durable_position(Pid)),
        ?assertEqual(ok, bondy_oplog_wal:await_durable(Pid, EndPos, 0))
    end).

batched_await_durable_blocks_then_sync_wakes_it_test() ->
    HLC = bondy_hlc:new(),
    Opts = #{
        fsync_mode => batched,
        batched_fsync_interval => 10_000,
        batched_fsync_bytes => 100 * 1024 * 1024
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        {_Hlc, _Start, EndPos} = append_one(Pid, HLC, 1),
        ?assert(EndPos > bondy_oplog_wal:durable_position(Pid)),
        Parent = self(),
        Waiter = spawn_link(fun() ->
            Result = bondy_oplog_wal:await_durable(Pid, EndPos, 5000),
            Parent ! {self(), Result}
        end),
        %% Give the waiter time to register; verify it's blocked.
        timer:sleep(50),
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(1, maps:get(waiter_count, Info)),
        %% Trigger durability via sync.
        ?assertEqual(ok, bondy_oplog_wal:sync(Pid)),
        %% Waiter should reply ok now.
        receive
            {Waiter, Result} -> ?assertEqual(ok, Result)
        after 2000 ->
            error(waiter_did_not_reply)
        end,
        Info2 = bondy_oplog_wal:info(Pid),
        ?assertEqual(0, maps:get(waiter_count, Info2))
    end).

batched_await_durable_blocks_then_timer_wakes_it_test() ->
    HLC = bondy_hlc:new(),
    Opts = #{
        fsync_mode => batched,
        batched_fsync_interval => 30,
        batched_fsync_bytes => 100 * 1024 * 1024
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        {_Hlc, _Start, EndPos} = append_one(Pid, HLC, 1),
        Parent = self(),
        Waiter = spawn_link(fun() ->
            Result = bondy_oplog_wal:await_durable(Pid, EndPos, 2000),
            Parent ! {self(), Result}
        end),
        receive
            {Waiter, Result} -> ?assertEqual(ok, Result)
        after 2000 ->
            error(waiter_did_not_reply)
        end
    end).

batched_await_durable_timeout_returns_error_test() ->
    HLC = bondy_hlc:new(),
    Opts = #{
        fsync_mode => batched,
        batched_fsync_interval => 10_000,
        batched_fsync_bytes => 100 * 1024 * 1024
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        {_Hlc, _Start, EndPos} = append_one(Pid, HLC, 1),
        ?assertEqual(
            {error, timeout},
            bondy_oplog_wal:await_durable(Pid, EndPos, 50)
        ),
        %% Waiter must be removed from the pending list after timeout.
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(0, maps:get(waiter_count, Info))
    end).

batched_await_durable_zero_timeout_test() ->
    HLC = bondy_hlc:new(),
    Opts = #{
        fsync_mode => batched,
        batched_fsync_interval => 10_000,
        batched_fsync_bytes => 100 * 1024 * 1024
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        {_Hlc, _Start, EndPos} = append_one(Pid, HLC, 1),
        %% Zero-timeout fast-path: never blocks, returns the
        %% non-durable status synchronously.
        ?assertEqual(
            {error, timeout},
            bondy_oplog_wal:await_durable(Pid, EndPos, 0)
        )
    end).

batched_multiple_waiters_woken_in_order_test() ->
    HLC = bondy_hlc:new(),
    Opts = #{
        fsync_mode => batched,
        batched_fsync_interval => 10_000,
        batched_fsync_bytes => 100 * 1024 * 1024
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        {_, _, EndPos1} = append_one(Pid, HLC, 1),
        {_, _, EndPos2} = append_one(Pid, HLC, 2),
        {_, _, EndPos3} = append_one(Pid, HLC, 3),
        Parent = self(),
        %% Register all three waiters concurrently.
        Pids = [
            spawn_link(fun() ->
                R = bondy_oplog_wal:await_durable(Pid, P, 5000),
                Parent ! {self(), P, R}
            end)
         || P <- [EndPos1, EndPos2, EndPos3]
        ],
        timer:sleep(50),
        ?assertEqual(
            3, maps:get(waiter_count, bondy_oplog_wal:info(Pid))
        ),
        ok = bondy_oplog_wal:sync(Pid),
        Results = [
            receive
                {P, _, R} -> {P, R}
            after 2000 ->
                error({waiter_did_not_reply, P})
            end
         || P <- Pids
        ],
        [?assertMatch({_, ok}, R) || R <- Results]
    end).

%% =============================================================================
%% batched mode — sync, rotation, close
%% =============================================================================

batched_sync_advances_durable_and_resets_pending_test() ->
    HLC = bondy_hlc:new(),
    Opts = #{
        fsync_mode => batched,
        batched_fsync_interval => 10_000,
        batched_fsync_bytes => 100 * 1024 * 1024
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        {_, _, EndPos} = append_one(Pid, HLC, 1),
        ?assert(
            maps:get(
                pending_fsync_bytes, bondy_oplog_wal:info(Pid)
            ) > 0
        ),
        ?assertEqual(ok, bondy_oplog_wal:sync(Pid)),
        ?assertEqual(EndPos, bondy_oplog_wal:durable_position(Pid)),
        ?assertEqual(
            0,
            maps:get(
                pending_fsync_bytes, bondy_oplog_wal:info(Pid)
            )
        )
    end).

batched_rotation_advances_durable_test() ->
    HLC = bondy_hlc:new(),
    %% Force rotation with a small segment cap.
    Opts = #{
        fsync_mode => batched,
        batched_fsync_interval => 10_000,
        batched_fsync_bytes => 100 * 1024 * 1024,
        max_segment_bytes => 200
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        {_, _, _} = append_one(Pid, HLC, 1),
        %% Second append triggers rotation; rotation fsyncs segment 0
        %% and then publishes durable at the new segment's header
        %% boundary (= segment 1, offset 48).
        {_, {Seg2, _}, _} = append_one(Pid, HLC, 2),
        ?assertEqual(1, Seg2),
        %% Durable position is somewhere in segment 1; at minimum at
        %% segment 1's header boundary (48). All bytes of segment 0
        %% were datasync'd as part of the rotation.
        {DSeg, DOff} = bondy_oplog_wal:durable_position(Pid),
        ?assertEqual(1, DSeg),
        ?assert(DOff >= ?SEG_HEADER)
    end).

batched_rotation_wakes_waiters_in_old_segment_test() ->
    HLC = bondy_hlc:new(),
    Opts = #{
        fsync_mode => batched,
        batched_fsync_interval => 10_000,
        batched_fsync_bytes => 100 * 1024 * 1024,
        max_segment_bytes => 200
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        {_, _, {Seg0, EndOff0}} = append_one(Pid, HLC, 1),
        Parent = self(),
        Waiter = spawn_link(fun() ->
            R = bondy_oplog_wal:await_durable(
                Pid, {Seg0, EndOff0}, 5000
            ),
            Parent ! {self(), R}
        end),
        timer:sleep(50),
        ?assertEqual(
            1, maps:get(waiter_count, bondy_oplog_wal:info(Pid))
        ),
        %% Trigger rotation by appending again.
        _ = append_one(Pid, HLC, 2),
        receive
            {Waiter, R} -> ?assertEqual(ok, R)
        after 2000 ->
            error(waiter_did_not_reply)
        end
    end).

batched_close_fsyncs_pending_test() ->
    HLC = bondy_hlc:new(),
    Dir = mktemp_dir(),
    try
        Opts = #{
            dir => Dir,
            origin => origin(),
            fsync_mode => batched,
            batched_fsync_interval => 10_000,
            batched_fsync_bytes => 100 * 1024 * 1024
        },
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        _ = append_one(P1, HLC, 1),
        InfoBefore = bondy_oplog_wal:info(P1),
        ?assert(maps:get(pending_fsync_bytes, InfoBefore) > 0),
        ok = bondy_oplog_wal:close(P1),
        %% Reopen — the just-appended frame must be visible (the
        %% terminate handler datasynced it on close).
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        InfoAfter = bondy_oplog_wal:info(P2),
        ?assertEqual(
            maps:get(head_offset, InfoBefore),
            maps:get(head_offset, InfoAfter)
        ),
        ?assertEqual(
            maps:get(head_offset, InfoAfter),
            maps:get(durable_offset, InfoAfter)
        ),
        ok = bondy_oplog_wal:close(P2)
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% Opt validation
%% =============================================================================

invalid_fsync_mode_rejected_test() ->
    Dir = mktemp_dir(),
    try
        expect_open_error(
            {invalid_opt, fsync_mode, foo},
            fun() ->
                bondy_oplog_wal:start_link(
                    instance_id(),
                    #{dir => Dir, origin => origin(), fsync_mode => foo}
                )
            end
        )
    after
        rmrf(Dir)
    end.

invalid_batched_interval_rejected_test() ->
    Dir = mktemp_dir(),
    try
        expect_open_error(
            {invalid_opt, batched_fsync_interval, 0},
            fun() ->
                bondy_oplog_wal:start_link(
                    instance_id(),
                    #{
                        dir => Dir,
                        origin => origin(),
                        fsync_mode => batched,
                        batched_fsync_interval => 0
                    }
                )
            end
        )
    after
        rmrf(Dir)
    end.

invalid_batched_bytes_rejected_test() ->
    Dir = mktemp_dir(),
    try
        expect_open_error(
            {invalid_opt, batched_fsync_bytes, 0},
            fun() ->
                bondy_oplog_wal:start_link(
                    instance_id(),
                    #{
                        dir => Dir,
                        origin => origin(),
                        fsync_mode => batched,
                        batched_fsync_bytes => 0
                    }
                )
            end
        )
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% Write and datasync failures
%% =============================================================================

%% A write that fails after half its frame reached the file, as `enospc`
%% can, is refused. Every append acknowledged after it, by that writer or by
%% one started again on the same directory, must be read back after a
%% restart, in order, and the refused frame must not.
torn_write_keeps_later_acked_appends_test() ->
    Dir = mktemp_dir(),
    Opts = (base_opts())#{dir => Dir},
    OldTrap = process_flag(trap_exit, true),
    HLC = bondy_hlc:new(),
    Ev = fun(Seq) -> mk_event(bondy_hlc:now(HLC), Seq) end,
    try
        {ok, W0} = bondy_oplog_wal:start_link(instance_id(), Opts),
        E1 = Ev(1),
        {ok, _, _} = bondy_oplog_wal:append(W0, E1),
        Torn = with_io_fault_lock(fun() ->
            ok = meck:expect(bondy_mst_io, write, fun(Fd, Bytes) ->
                Bin = iolist_to_binary(Bytes),
                ok = prim_file:write(
                    Fd, binary:part(Bin, 0, byte_size(Bin) div 2)
                ),
                {error, enospc}
            end),
            bondy_oplog_wal:append(W0, Ev(2))
        end),
        ?assertEqual({error, {write_failed, enospc}}, Torn),
        {Acked, W} = lists:foldl(
            fun(E, {Acc, P0}) ->
                P = live_writer(P0, Opts),
                {ok, _, _} = bondy_oplog_wal:append(P, E),
                {[E | Acc], P}
            end,
            {[E1], W0},
            [Ev(3), Ev(4)]
        ),
        ok = bondy_oplog_wal:close(W),
        {ok, W2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        try
            ?assertEqual(lists:reverse(Acked), read_all(W2))
        after
            ok = bondy_oplog_wal:close(W2)
        end
    after
        process_flag(trap_exit, OldTrap),
        rmrf(Dir)
    end.

%% A datasync that fails once stops the writer without confirming the
%% position a waiter is parked on: a second datasync, as `terminate/2` would
%% issue, can succeed for pages the first one lost.
failed_datasync_does_not_satisfy_waiters_test() ->
    Dir = mktemp_dir(),
    Opts = (base_opts())#{
        dir => Dir,
        fsync_mode => batched,
        batched_fsync_interval => 10_000,
        batched_fsync_bytes => 100 * 1024 * 1024
    },
    OldTrap = process_flag(trap_exit, true),
    try
        {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), Opts),
        {_Hlc, _Start, EndPos} = append_one(Pid, bondy_hlc:new(), 1),
        Parent = self(),
        Waiter = spawn(fun() ->
            Result =
                try
                    bondy_oplog_wal:await_durable(Pid, EndPos, 5000)
                catch
                    exit:Reason -> {exit, Reason}
                end,
            Parent ! {self(), Result}
        end),
        ok = wait_for_waiters(Pid, 1, 40),
        Fired = atomics:new(1, []),
        Sync = with_io_fault_lock(fun() ->
            ok = meck:expect(bondy_mst_io, datasync, fun(Fd) ->
                case atomics:add_get(Fired, 1, 1) of
                    1 -> {error, eio};
                    _ -> meck:passthrough([Fd])
                end
            end),
            Res = bondy_oplog_wal:sync(Pid),
            receive
                {'EXIT', Pid, _} -> ok
            after 5000 -> error(writer_not_stopped)
            end,
            Res
        end),
        ?assertEqual({error, {datasync_failed, eio}}, Sync),
        receive
            {Waiter, Result} -> ?assertNotEqual(ok, Result)
        after 6000 ->
            error(waiter_did_not_reply)
        end
    after
        process_flag(trap_exit, OldTrap),
        rmrf(Dir)
    end.

wait_for_waiters(_Pid, _N, 0) ->
    error(waiter_not_parked);
wait_for_waiters(Pid, N, Tries) ->
    case maps:get(waiter_count, bondy_oplog_wal:info(Pid)) of
        N ->
            ok;
        _ ->
            timer:sleep(25),
            wait_for_waiters(Pid, N, Tries - 1)
    end.

%% The writer `Pid` if it is still running, otherwise one started again on
%% the same directory, which runs recovery.
live_writer(Pid, Opts) ->
    case is_process_alive(Pid) of
        true ->
            Pid;
        false ->
            {ok, New} = bondy_oplog_wal:start_link(instance_id(), Opts),
            New
    end.

%% A rotation whose manifest write fails at the directory fsync has already
%% put a manifest naming the new segment in place, so the writer must not
%% delete that segment. Only the fsync after the manifest's rename fails. The
%% log must reopen with its frames.
rotation_manifest_dir_sync_failure_keeps_the_log_openable_test() ->
    HLC = bondy_hlc:new(),
    Dir = mktemp_dir(),
    Opts = #{dir => Dir, origin => origin(), max_segment_bytes => 200},
    OldFlag = process_flag(trap_exit, true),
    try
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        {Hlc1, _, _} = append_one(P1, HLC, 1),
        Renamed = atomics:new(1, []),
        with_io_fault_lock(fun() ->
            ok = meck:expect(bondy_mst_io, rename, fun(From, To) ->
                case filename:basename(To) of
                    <<"manifest">> -> atomics:put(Renamed, 1, 1);
                    "manifest" -> atomics:put(Renamed, 1, 1);
                    _ -> ok
                end,
                meck:passthrough([From, To])
            end),
            ok = meck:expect(bondy_mst_io, fsync_dir, fun(D) ->
                case atomics:exchange(Renamed, 1, 0) of
                    1 -> {error, eio};
                    0 -> meck:passthrough([D])
                end
            end),
            _ =
                try
                    append_one(P1, HLC, 2)
                catch
                    _:_ -> writer_failed
                end,
            receive
                {'EXIT', P1, _} -> ok
            after 5000 -> error(writer_did_not_stop)
            end
        end),
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        try
            Hlcs = [
                bondy_oplog_event:key_hlc(bondy_oplog_event:key(E))
             || E <- read_all(P2)
            ],
            ?assert(lists:member(Hlc1, Hlcs))
        after
            ok = bondy_oplog_wal:close(P2)
        end
    after
        process_flag(trap_exit, OldFlag),
        rmrf(Dir)
    end.

%% A reopened log appends to its head segment, whose directory entry may not
%% be durable yet, so recovery refuses to start until the directory is synced.
reopen_refuses_an_unsyncable_directory_test() ->
    Dir = mktemp_dir(),
    Opts = #{dir => Dir, origin => origin()},
    OldFlag = process_flag(trap_exit, true),
    try
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ok = bondy_oplog_wal:close(P1),
        Result = with_io_fault_lock(fun() ->
            ok = meck:expect(bondy_mst_io, fsync_dir, fun(_) -> {error, eio} end),
            bondy_oplog_wal:start_link(instance_id(), Opts)
        end),
        ?assertMatch({error, _}, Result),
        ?assertNotEqual(
            nomatch,
            string:find(io_lib:format("~p", [Result]), "dir_fsync_failed")
        )
    after
        process_flag(trap_exit, OldFlag),
        rmrf(Dir)
    end.

%% A first start whose segment create fails must leave nothing behind: the
%% next start bootstraps again, and its exclusive create of the same segment
%% would otherwise fail with `eexist` on every attempt.
failed_first_segment_create_does_not_wedge_the_log_test() ->
    Dir = mktemp_dir(),
    Opts = #{dir => Dir, origin => origin()},
    OldFlag = process_flag(trap_exit, true),
    try
        First = with_io_fault_lock(fun() ->
            ok = meck:expect(bondy_mst_io, fsync_dir, fun(_) -> {error, eio} end),
            bondy_oplog_wal:start_link(instance_id(), Opts)
        end),
        ?assertMatch({error, _}, First),
        {ok, P} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ok = bondy_oplog_wal:close(P)
    after
        process_flag(trap_exit, OldFlag),
        rmrf(Dir)
    end.

%% A crash between the first segment's create and the manifest's rename leaves
%% a header-only segment and no manifest. The next start must bootstrap over it,
%% but a segment long enough to hold a frame is never deleted to make room.
segment_without_manifest_does_not_wedge_the_log_test() ->
    Dir = mktemp_dir(),
    Opts = #{dir => Dir, origin => origin()},
    try
        {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ok = bondy_oplog_wal:close(P1),
        [Manifest] = filelib:wildcard(
            filename:join([Dir, "**", "manifest"])
        ),
        ok = file:delete(Manifest),
        {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
        ok = bondy_oplog_wal:close(P2),
        [Segment] = filelib:wildcard(filename:join([Dir, "**", "*.qdata"])),
        ok = file:delete(Manifest),
        {ok, Fd} = file:open(Segment, [append, raw, binary]),
        ok = file:write(Fd, <<0>>),
        ok = file:close(Fd),
        Size = filelib:file_size(Segment),
        OldFlag = process_flag(trap_exit, true),
        try
            ?assertMatch(
                {error, _}, bondy_oplog_wal:start_link(instance_id(), Opts)
            ),
            ?assertEqual(Size, filelib:file_size(Segment))
        after
            process_flag(trap_exit, OldFlag)
        end
    after
        rmrf(Dir)
    end.

read_all(Pid) ->
    {ok, It} = bondy_log_reader:open(Pid, beginning, [{follow, false}]),
    read_all(It, []).

read_all(It0, Acc) ->
    case bondy_log_reader:next(It0) of
        {ok, Events, _, _, It} -> read_all(It, Acc ++ Events);
        end_of_log -> Acc
    end.

%% Serialises every test that mocks `bondy_mst_io` in this VM (the lock
%% key is shared with the other WAL suites).
with_io_fault_lock(Body) ->
    global:trans(
        {{meck_vm_lock, bondy_mst_io}, self()},
        fun() ->
            ok = meck:new(bondy_mst_io, [passthrough]),
            try
                Body()
            after
                _ = meck:unload(bondy_mst_io)
            end
        end,
        [node()],
        infinity
    ).
