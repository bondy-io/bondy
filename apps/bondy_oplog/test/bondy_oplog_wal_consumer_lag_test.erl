%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% `bondy_oplog_wal:info/1` `consumer_lag_bytes`: the drain backlog — bytes
%% appended but not yet committed by the log's consumer, computed against
%% the on-disk `consumer.offset`. This is the health signal that exposes a
%% wedged or starved applier on a node whose MSTs otherwise compare
%% converged.
-module(bondy_oplog_wal_consumer_lag_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Fixture (the bare-WAL pattern of bondy_oplog_wal_batch_test)
%% =============================================================================

mktemp_dir() ->
    Base = io_lib:format(
        "/tmp/bondy_wal_lag_~b_~b",
        [erlang:system_time(microsecond), erlang:unique_integer([positive])]
    ),
    Dir = lists:flatten(Base),
    ok = filelib:ensure_path(Dir),
    Dir.

origin() ->
    <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>.

with_wal(Opts, Fun) ->
    Dir = mktemp_dir(),
    try
        AllOpts = maps:merge(#{origin => origin(), dir => Dir}, Opts),
        {ok, Pid} = bondy_oplog_wal:start_link(<<"wal-lag-test">>, AllOpts),
        try
            %% The WAL nests its files under `Dir/<InstanceId>/` — the
            %% consumer offset and the segments live THERE.
            Fun(Pid, maps:get(dir, bondy_oplog_wal:info(Pid)))
        after
            ok = bondy_oplog_wal:close(Pid)
        end
    after
        _ = file:del_dir_r(Dir),
        ok
    end.

mk_event(HLC, Seq) ->
    Hlc = bondy_oplog_hlc:now(HLC),
    Key = bondy_oplog_event:key(Hlc, origin(), Seq),
    bondy_oplog_event:new(Key, {op, Hlc}, undefined).

append_n(Pid, HLC, Base, N) ->
    [
        begin
            {ok, _, Pos} = bondy_oplog_wal:append(Pid, mk_event(HLC, Seq)),
            Pos
        end
     || Seq <- lists:seq(Base, Base + N - 1)
    ].

commit_at(Dir, {Seg, Off}) ->
    CO0 = bondy_oplog_wal_state:new_consumer_offset(),
    CO1 = bondy_oplog_wal_state:with_position(CO0, Seg, Off),
    CO = bondy_oplog_wal_state:with_commit_count(CO1, 1),
    ok = bondy_oplog_wal_state:write_consumer_offset(Dir, CO).

lag(Pid) ->
    maps:get(consumer_lag_bytes, bondy_oplog_wal:info(Pid)).

%% =============================================================================
%% Tests
%% =============================================================================

%% A consumer that never committed owes the whole live log.
never_committed_is_whole_log_test() ->
    with_wal(#{}, fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        _ = append_n(Pid, HLC, 1, 5),
        #{bytes_total := Total} = bondy_oplog_wal:info(Pid),
        ?assert(Total > 0),
        ?assertEqual(Total, lag(Pid))
    end).

%% Committing at the head clears the lag; a mid-log commit owes exactly the
%% distance from the committed frame to the head.
committed_positions_test() ->
    with_wal(#{}, fun(Pid, Dir) ->
        HLC = bondy_oplog_hlc:new(),
        Positions = append_n(Pid, HLC, 1, 8),
        #{
            current_segment := HeadSeg,
            head_offset := HeadOff
        } = bondy_oplog_wal:info(Pid),

        %% At the head: nothing owed.
        ok = commit_at(Dir, {HeadSeg, HeadOff}),
        ?assertEqual(0, lag(Pid)),

        %% At the start of the 4th frame: exactly the remaining bytes.
        {MidSeg, MidOff} = lists:nth(4, Positions),
        ?assertEqual(HeadSeg, MidSeg),
        ok = commit_at(Dir, {MidSeg, MidOff}),
        ?assertEqual(HeadOff - MidOff, lag(Pid))
    end).

%% Across a segment rotation the lag spans the committed segment's tail
%% plus every byte of the newer segments.
rotated_segments_test() ->
    %% A tiny segment cap forces rotation after a few frames.
    with_wal(#{max_segment_bytes => 512}, fun(Pid, Dir) ->
        HLC = bondy_oplog_hlc:new(),
        Positions = append_n(Pid, HLC, 1, 40),
        #{
            current_segment := HeadSeg,
            head_offset := HeadOff
        } = bondy_oplog_wal:info(Pid),
        %% Pick a committed position in a PRIOR segment.
        {CSeg, COff} = lists:last([P || {S, _} = P <- Positions, S < HeadSeg]),
        ?assert(CSeg < HeadSeg),
        ok = commit_at(Dir, {CSeg, COff}),

        %% Independent arithmetic: the committed segment's remainder, every
        %% whole segment in between, and the head segment's bytes.
        SegSize = fun(Id) ->
            Name = bondy_oplog_wal_segment:filename(Id),
            filelib:file_size(filename:join(Dir, Name))
        end,
        Expected =
            (SegSize(CSeg) - COff) +
                lists:sum([
                    SegSize(S)
                 || S <- lists:seq(CSeg + 1, HeadSeg - 1)
                ]) +
                HeadOff,
        ?assertEqual(Expected, lag(Pid))
    end).

%% A committed position ahead of the head (a rotation race artefact) is
%% reported as zero, never negative.
committed_ahead_is_zero_test() ->
    with_wal(#{}, fun(Pid, Dir) ->
        HLC = bondy_oplog_hlc:new(),
        [{_, Off} | _] = append_n(Pid, HLC, 1, 3),
        #{current_segment := HeadSeg} = bondy_oplog_wal:info(Pid),
        ok = commit_at(Dir, {HeadSeg + 7, Off}),
        ?assertEqual(0, lag(Pid))
    end).
