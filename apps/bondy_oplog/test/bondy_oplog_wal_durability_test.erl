%% =============================================================================
%% Durability tests for `bondy_oplog_wal` (fsync modes, durable
%% position, and `await_durable/3`).
%%
%% Tests cover:
%%
%% 1. `fsync_mode = per_write` — durable ≡ head at all times;
%%    `await_durable/3` returns immediately for any reachable position.
%%
%% 2. `fsync_mode = batched` — appends defer fsync, accumulating
%%    `pending_fsync_bytes`. Durability is reached when either
%%    `batched_fsync_bytes` is exceeded (size trigger) or
%%    `batched_fsync_interval` ms elapse with pending bytes (time
%%    trigger). `await_durable/3` blocks until the next fsync covers
%%    the position; returns `{error, timeout}` on deadline; returns
%%    `ok` if the position is already durable.
%%
%% 3. Rotation always datasyncs the just-sealed segment, advancing
%%    durable to that segment's last frame end and (after new-segment
%%    creation) onto the new segment's header boundary. Waiters at any
%%    position in the old segment are woken on rotation.
%%
%% 4. `sync/1` is the user-facing barrier: forces fsync regardless of
%%    mode, advances durable, and wakes covered waiters.
%%
%% 5. Bad opts (`fsync_mode = foo`, negative interval, zero bytes) are
%%    refused at init.
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
    Hlc = bondy_oplog_hlc:now(HLC),
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
    HLC = bondy_oplog_hlc:new(),
    with_wal(#{}, fun(Pid, _Dir) ->
        {_Hlc, {Seg, _Start}, {Seg, EndOff}} = append_one(Pid, HLC, 1),
        ?assertEqual({Seg, EndOff}, bondy_oplog_wal:durable_position(Pid)),
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(
            maps:get(head_offset, Info), maps:get(durable_offset, Info)
        )
    end).

per_write_await_durable_returns_immediately_test() ->
    HLC = bondy_oplog_hlc:new(),
    with_wal(#{}, fun(Pid, _Dir) ->
        {_Hlc, _Start, EndPos} = append_one(Pid, HLC, 1),
        ?assertEqual(ok, bondy_oplog_wal:await_durable(Pid, EndPos, 0)),
        ?assertEqual(ok, bondy_oplog_wal:await_durable(Pid, EndPos, 5000)),
        ?assertEqual(
            ok, bondy_oplog_wal:await_durable(Pid, EndPos, infinity)
        )
    end).

per_write_pending_bytes_stay_zero_test() ->
    HLC = bondy_oplog_hlc:new(),
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
    HLC = bondy_oplog_hlc:new(),
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
    HLC = bondy_oplog_hlc:new(),
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
    HLC = bondy_oplog_hlc:new(),
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
    HLC = bondy_oplog_hlc:new(),
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
    HLC = bondy_oplog_hlc:new(),
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
    HLC = bondy_oplog_hlc:new(),
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
    HLC = bondy_oplog_hlc:new(),
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
    HLC = bondy_oplog_hlc:new(),
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
    HLC = bondy_oplog_hlc:new(),
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
    HLC = bondy_oplog_hlc:new(),
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
    HLC = bondy_oplog_hlc:new(),
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
    HLC = bondy_oplog_hlc:new(),
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
    HLC = bondy_oplog_hlc:new(),
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
