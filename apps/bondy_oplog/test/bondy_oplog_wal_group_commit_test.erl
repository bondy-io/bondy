%% =============================================================================
%% Group-commit (boxcar) tests for `bondy_oplog_wal`.
%%
%% Group commit coalesces concurrently-queued `per_write` appends into a
%% single `datasync` per group: the writer writes every queued frame, then
%% issues one fsync and replies to every caller only after it. Durability
%% is identical to plain per_write (durable-on-return); the win is that one
%% fsync amortises across the whole group, removing the
%% one-fsync-per-concurrent-appender wall.
%%
%% The coalescing is made deterministic (no scheduler races) by suspending
%% the writer with `sys:suspend/1`, enqueuing N async requests in HLC order
%% from a single process (so the mailbox holds all N before any is
%% processed), then `sys:resume/1`. The `fsync_count` gauge in `info/1` is
%% the observable:
%%
%% - group_commit = true  : N appends -> 1 datasync (or ceil(N/max)).
%% - group_commit = false : N appends -> N datasyncs (the control).
%%
%% Same workload; the only difference is the `group_commit` flag.
%% =============================================================================

-module(bondy_oplog_wal_group_commit_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

%% =============================================================================
%% Fixture helpers (mirrors bondy_oplog_wal_durability_test)
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_oplog_wal_group_commit_test_~p_~p",
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
    <<"wal-group-commit-test-instance">>.

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

%% N events with strictly increasing HLCs (one clock, N ticks).
mk_monotonic_events(N) ->
    Clock = bondy_oplog_hlc:new(),
    [mk_event(bondy_oplog_hlc:now(Clock), Seq) || Seq <- lists:seq(1, N)].

%% Force `Events` (one single-event batch each) into the writer's mailbox
%% deterministically: suspend, enqueue all N async in order, resume, then
%% collect the unwrapped replies in submit order.
suspend_enqueue_resume(Pid, Events) ->
    ok = sys:suspend(Pid),
    Reqs = [
        gen_server:send_request(Pid, {append_batch, [E]})
     || E <- Events
    ],
    ok = sys:resume(Pid),
    [unwrap_response(gen_server:receive_response(R, 5000)) || R <- Reqs].

unwrap_response({reply, Reply}) -> Reply;
unwrap_response(Other) -> Other.

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
%% Defaults + info
%% =============================================================================

group_commit_on_by_default_test() ->
    with_wal(#{}, fun(Pid, _Dir) ->
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(true, maps:get(group_commit, Info)),
        ?assertEqual(1024, maps:get(group_commit_max, Info)),
        ?assertEqual(0, maps:get(fsync_count, Info))
    end).

%% =============================================================================
%% Coalescing (the headline) + the control
%% =============================================================================

%% N concurrently-queued appends collapse to ONE datasync.
group_commit_coalesces_concurrent_appends_test() ->
    with_wal(#{group_commit => true}, fun(Pid, _Dir) ->
        N = 50,
        Events = mk_monotonic_events(N),
        Replies = suspend_enqueue_resume(Pid, Events),
        %% Every append succeeded...
        [?assertMatch({ok, [_]}, R) || R <- Replies],
        Info = bondy_oplog_wal:info(Pid),
        %% ...and exactly one fsync covered the whole group.
        ?assertEqual(1, maps:get(fsync_count, Info)),
        ?assertEqual(N, maps:get(append_count, Info))
    end).

%% Control: the SAME workload with group commit off fsyncs per append.
%% This is the falsifying comparison — flipping the flag is the only
%% difference, and it changes the fsync count from 1 to N.
group_commit_disabled_fsyncs_per_append_test() ->
    with_wal(#{group_commit => false}, fun(Pid, _Dir) ->
        N = 50,
        Events = mk_monotonic_events(N),
        Replies = suspend_enqueue_resume(Pid, Events),
        [?assertMatch({ok, [_]}, R) || R <- Replies],
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(N, maps:get(fsync_count, Info)),
        ?assertEqual(N, maps:get(append_count, Info))
    end).

%% The per-group cap bounds the coalescing: 25 appends at max 10 -> 3
%% datasyncs (10 + 10 + 5).
group_commit_respects_max_cap_test() ->
    Opts = #{group_commit => true, group_commit_max => 10},
    with_wal(Opts, fun(Pid, _Dir) ->
        N = 25,
        Events = mk_monotonic_events(N),
        Replies = suspend_enqueue_resume(Pid, Events),
        [?assertMatch({ok, [_]}, R) || R <- Replies],
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(3, maps:get(fsync_count, Info)),
        ?assertEqual(N, maps:get(append_count, Info))
    end).

%% =============================================================================
%% Durability contract preserved
%% =============================================================================

%% A group-committed append is durable on return — the per_write
%% durable-on-return contract is unchanged (here a group of one, via the
%% synchronous append/2 path).
group_commit_append_is_durable_on_return_test() ->
    with_wal(#{group_commit => true}, fun(Pid, _Dir) ->
        Clock = bondy_oplog_hlc:new(),
        Hlc = bondy_oplog_hlc:now(Clock),
        E = mk_event(Hlc, 1),
        {ok, Hlc, {Seg, _Start}} = bondy_oplog_wal:append(Pid, E),
        Info = bondy_oplog_wal:info(Pid),
        EndOff = maps:get(head_offset, Info),
        %% durable == head immediately on return
        ?assertEqual({Seg, EndOff}, bondy_oplog_wal:durable_position(Pid)),
        ?assertEqual(EndOff, maps:get(durable_offset, Info)),
        ?assertEqual(
            ok, bondy_oplog_wal:await_durable(Pid, {Seg, EndOff}, 0)
        ),
        %% one fsync for the one-append group
        ?assertEqual(1, maps:get(fsync_count, Info))
    end).

%% After a coalesced group, the durable position covers every event in the
%% group (all replies are durable, not just the last).
group_commit_whole_group_is_durable_test() ->
    with_wal(#{group_commit => true}, fun(Pid, _Dir) ->
        N = 20,
        Events = mk_monotonic_events(N),
        Replies = suspend_enqueue_resume(Pid, Events),
        %% Each reply carries that event's frame position; all must be at
        %% or below the durable boundary.
        DurablePos = bondy_oplog_wal:durable_position(Pid),
        lists:foreach(
            fun({ok, [{_Hlc, Pos}]}) ->
                ?assert(Pos =< DurablePos)
            end,
            Replies
        ),
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(1, maps:get(fsync_count, Info))
    end).

%% A small segment cap forces ≥1 rotation INSIDE a single coalesced group.
%% Frames written before a rotation are made durable by the rotation's own
%% datasync; frames after it by the group's final head fsync. The whole
%% multi-segment group must end durable, and only one head fsync
%% (do_fsync_head) is charged for the group — rotations datasync
%% separately and are not counted in `fsync_count`.
group_commit_mid_group_rotation_all_durable_test() ->
    Opts = #{group_commit => true, max_segment_bytes => 200},
    with_wal(Opts, fun(Pid, _Dir) ->
        N = 6,
        Events = mk_monotonic_events(N),
        Replies = suspend_enqueue_resume(Pid, Events),
        Positions = [Pos || {ok, [{_Hlc, Pos}]} <- Replies],
        ?assertEqual(N, length(Positions)),
        Segs = [S || {S, _Off} <- Positions],
        %% rotation happened mid-group: events span more than one segment
        ?assert(lists:max(Segs) > 0),
        ?assertEqual(0, lists:min(Segs)),
        %% the whole group is durable, including the pre-rotation frames
        DurablePos = bondy_oplog_wal:durable_position(Pid),
        [?assert(Pos =< DurablePos) || Pos <- Positions],
        %% one explicit head fsync for the entire multi-segment group
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(1, maps:get(fsync_count, Info))
    end).

%% =============================================================================
%% Opt validation
%% =============================================================================

invalid_group_commit_rejected_test() ->
    Dir = mktemp_dir(),
    try
        expect_open_error(
            {invalid_opt, group_commit, not_a_boolean},
            fun() ->
                bondy_oplog_wal:start_link(
                    instance_id(),
                    #{
                        dir => Dir,
                        origin => origin(),
                        group_commit => not_a_boolean
                    }
                )
            end
        )
    after
        rmrf(Dir)
    end.

invalid_group_commit_max_rejected_test() ->
    Dir = mktemp_dir(),
    try
        expect_open_error(
            {invalid_opt, group_commit_max, 0},
            fun() ->
                bondy_oplog_wal:start_link(
                    instance_id(),
                    #{
                        dir => Dir,
                        origin => origin(),
                        group_commit_max => 0
                    }
                )
            end
        )
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% Group-commit failure injection (the two W1-QA carry-over branches)
%% =============================================================================
%%
%% These cover the two error branches of the boxcar path that the W1
%% Architecture QA flagged as deferred because they need fault injection:
%%
%%   1. `flush_group/3` datasync failure — the group's single shared
%%      `do_fsync_head` fails. per_write promised durability-on-return, so
%%      EVERY ok-write caller in the group must receive the error (not the
%%      `{ok, _}` its own write would otherwise have produced), and the
%%      writer must STAY ALIVE (the failure is recoverable — the non-durable
%%      tail is truncated on the next open).
%%
%%   2. fatal-during-drain reply fan-out — a drained batch trips a rotation
%%      that fails *after* the old segment fd was sealed+closed (a
%%      non-recoverable in-memory/on-disk divergence). Every caller already
%%      accumulated in the group (including the ones whose own frame was
%%      written ok) plus the fatal caller must receive the error, and the
%%      writer must STOP so the supervisor restart runs recovery.

%% (1) A failed group datasync fans the error out to every grouped caller
%% and leaves the writer alive. Distinct from the proper-test per-append
%% fault: this exercises the *group* path (`flush_group/3`), where one
%% datasync covers many callers.
group_commit_flush_group_datasync_failure_errors_whole_group_test() ->
    Dir = mktemp_dir(),
    try
        {ok, Pid} = bondy_oplog_wal:start_link(
            instance_id(), (base_opts())#{dir => Dir, group_commit => true}
        ),
        try
            N = 5,
            Events = mk_monotonic_events(N),
            {Replies, Alive, FsyncCount} = with_meck(
                bondy_mst_io,
                fun() ->
                    ok = meck:expect(
                        bondy_mst_io, datasync, fun(_Fd) -> {error, eio} end
                    ),
                    Rs = suspend_enqueue_resume(Pid, Events),
                    {
                        Rs,
                        is_process_alive(Pid),
                        maps:get(fsync_count, bondy_oplog_wal:info(Pid))
                    }
                end
            ),
            %% Every grouped caller observes the datasync failure.
            ?assertEqual(N, length(Replies)),
            [?assertEqual({error, eio}, R) || R <- Replies],
            %% The writer survives — `flush_group/3` returns `{noreply, _}`.
            ?assert(Alive),
            %% A failed `do_fsync_head` is not counted (bumps only on ok).
            ?assertEqual(0, FsyncCount)
        after
            ok = bondy_oplog_wal:close(Pid)
        end
    after
        rmrf(Dir)
    end.

%% (2) A fatal rotation hit by a *drained* batch errors every caller in the
%% group (incl. the already-ok ones) and the fatal caller, then stops the
%% writer for a supervisor restart + recovery.
group_commit_fatal_during_drain_errors_group_and_stops_test() ->
    %% At max_segment_bytes=200 the K-th single-event append is the first to
    %% rotate into segment 1. The group leader (event 1) can never rotate
    %% (the `maybe_rotate/2` `Cur > SEG_HEADER` guard), so K >= 2: events
    %% 1..K-1 ride the group as oks, event K trips the (injected) fatal.
    K = probe_rotation_event(200),
    ?assert(K >= 2),
    Dir = mktemp_dir(),
    OldTrap = process_flag(trap_exit, true),
    try
        {ok, Pid} = bondy_oplog_wal:start_link(
            instance_id(),
            (base_opts())#{
                dir => Dir, group_commit => true, max_segment_bytes => 200
            }
        ),
        Events = mk_monotonic_events(K),
        Reason = {rotation_failed_after_seal, injected},
        Replies = with_meck(
            bondy_oplog_wal_segment,
            fun() ->
                %% New-segment creation fails => `open_next_segment/1` fails
                %% *after* the old fd is sealed+closed => `rotate/1` returns
                %% `{fatal, {rotation_failed_after_seal, injected}, _}`.
                ok = meck:expect(
                    bondy_oplog_wal_segment,
                    create,
                    fun(_Path, _SegId, _Iid, _Origin) -> {error, injected} end
                ),
                suspend_enqueue_resume(Pid, Events)
            end
        ),
        %% Every caller in the coalesced group — including the K-1 whose own
        %% frame was written ok — plus the fatal caller gets the error.
        ?assertEqual(K, length(Replies)),
        [?assertEqual({error, Reason}, R) || R <- Replies],
        %% The writer stopped (supervisor restart will run recovery).
        receive
            {'EXIT', Pid, Reason} -> ok
        after 5000 ->
            error(writer_did_not_stop)
        end,
        ?assertNot(is_process_alive(Pid))
    after
        _ = process_flag(trap_exit, OldTrap),
        rmrf(Dir)
    end.

%% =============================================================================
%% Failure-injection helpers
%% =============================================================================

%% Serialises any test that mecks a VM-wide module (meck:new/2 swaps it in
%% the code server) and guarantees unload even on assertion failure. Mirrors
%% `bondy_oplog_wal_proper_test:with_io_fault_lock/1`.
%%
%% The lock resource is keyed by the MOCKED module, so mocking `bondy_mst_io`
%% here contends on the SAME `{meck_vm_lock, bondy_mst_io}` resource as the
%% sibling suites — a `?MODULE`-scoped key would let them clobber each other's
%% VM-wide expectations (intermittent injected-fault leak).
with_meck(Mod, Body) ->
    Lock = {meck_vm_lock, Mod},
    global:trans(
        {Lock, self()},
        fun() ->
            ok = meck:new(Mod, [passthrough]),
            try
                Body()
            after
                _ = meck:unload(Mod)
            end
        end,
        [node()],
        infinity
    ).

%% Open a throwaway WAL at `MaxSegBytes` and append single events (one HLC
%% clock, strictly increasing) until one lands in segment > 0; return its
%% 1-based index. This is the deterministic rotation point reused by the
%% fatal-during-drain test so the injected failure lands on the last enqueued
%% event (no orphaned requests after the writer stops).
probe_rotation_event(MaxSegBytes) ->
    Dir = mktemp_dir(),
    try
        {ok, Pid} = bondy_oplog_wal:start_link(
            instance_id(),
            (base_opts())#{
                dir => Dir,
                group_commit => true,
                max_segment_bytes => MaxSegBytes
            }
        ),
        try
            find_rotation_index(Pid, bondy_oplog_hlc:new(), 1, 50)
        after
            ok = bondy_oplog_wal:close(Pid)
        end
    after
        rmrf(Dir)
    end.

find_rotation_index(_Pid, _Clock, I, Max) when I > Max ->
    error({probe_no_rotation_within, Max});
find_rotation_index(Pid, Clock, I, Max) ->
    E = mk_event(bondy_oplog_hlc:now(Clock), I),
    {ok, _Hlc, {Seg, _Off}} = bondy_oplog_wal:append(Pid, E),
    case Seg > 0 of
        true -> I;
        false -> find_rotation_index(Pid, Clock, I + 1, Max)
    end.
