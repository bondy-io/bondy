%% =============================================================================
%% Atomic batch frame tests for `bondy_oplog_wal`.
%%
%% Tests cover:
%%
%% 1. `append_batch/2` writes N events as one frame and returns N
%%    `{Hlc, Pos}` entries sharing the same `Pos`.
%% 2. `append/2` remains a single-event sugar over `append_batch/2`.
%% 3. Pre-rotation: a batch that wouldn't fit in the current segment
%%    triggers rotation before the write, leaving the batch intact in
%%    the new segment.
%% 4. `{error, batch_too_large}` is returned when the encoded body
%%    exceeds `max_batch_bytes`.
%% 5. `{error, empty_batch}` for the empty list; `{error,
%%    {invalid_batch, non_event}}` for non-event members.
%% 6. Init rejects a `max_batch_bytes` that wouldn't fit in a fresh
%%    segment.
%% 7. The reader returns the full batch as a single `next/1` result.
%% =============================================================================

-module(bondy_oplog_wal_batch_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-define(SEG_HEADER, ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES).
-define(FRAME_HEADER, ?BONDY_OPLOG_WAL_FRAME_HEADER_BYTES).

%% =============================================================================
%% Fixtures
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_oplog_wal_batch_test_~p_~p",
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
    <<"wal-batch-test-instance">>.

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

%% Build N events with strictly ascending HLCs sourced from `HLC`. Seq
%% is `Base..Base+N-1`.
mk_batch(HLC, Base, N) ->
    [
        begin
            Hlc = bondy_oplog_hlc:now(HLC),
            mk_event(Hlc, Seq)
        end
     || Seq <- lists:seq(Base, Base + N - 1)
    ].

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
%% Tests
%% =============================================================================

append_batch_returns_one_entry_per_event_test() ->
    with_wal(#{}, fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        Events = mk_batch(HLC, 1, 5),
        {ok, Entries} = bondy_oplog_wal:append_batch(Pid, Events),
        ?assertEqual(5, length(Entries)),
        %% All entries share the same `Pos`: it's the frame start.
        Positions = [Pos || {_Hlc, Pos} <- Entries],
        ?assertEqual([hd(Positions)], lists:usort(Positions)),
        %% HLCs in the entries match the events' HLCs in order.
        EventHlcs = [
            bondy_oplog_event:key_hlc(bondy_oplog_event:key(E))
         || E <- Events
        ],
        EntryHlcs = [H || {H, _} <- Entries],
        ?assertEqual(EventHlcs, EntryHlcs),
        ok
    end).

append_one_is_batch_of_one_test() ->
    with_wal(#{}, fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        Hlc = bondy_oplog_hlc:now(HLC),
        E = mk_event(Hlc, 1),
        {ok, Hlc2, Pos} = bondy_oplog_wal:append(Pid, E),
        ?assertEqual(Hlc, Hlc2),
        ?assertMatch({0, _}, Pos),
        ok
    end).

empty_batch_rejected_test() ->
    with_wal(#{}, fun(Pid, _Dir) ->
        ?assertEqual(
            {error, empty_batch}, bondy_oplog_wal:append_batch(Pid, [])
        ),
        ok
    end).

non_event_member_rejected_test() ->
    with_wal(#{}, fun(Pid, _Dir) ->
        ?assertEqual(
            {error, {invalid_batch, non_event}},
            bondy_oplog_wal:append_batch(Pid, [not_an_event])
        ),
        ok
    end).

non_monotonic_hlcs_rejected_test() ->
    %% A batch whose HLCs aren't strictly ascending is rejected; the
    %% writer's state is untouched so subsequent valid appends still
    %% succeed.
    with_wal(#{}, fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        [E1, E2] = mk_batch(HLC, 1, 2),
        ?assertEqual(
            {error, {invalid_batch, hlc_not_monotonic}},
            bondy_oplog_wal:append_batch(Pid, [E2, E1])
        ),
        %% Duplicate HLC also rejected (same HLC twice is not strictly
        %% increasing).
        ?assertEqual(
            {error, {invalid_batch, hlc_not_monotonic}},
            bondy_oplog_wal:append_batch(Pid, [E1, E1])
        ),
        %% Writer still healthy.
        ?assertMatch(
            {ok, [{_, _}, {_, _}]},
            bondy_oplog_wal:append_batch(Pid, [E1, E2])
        ),
        ok
    end).

oversize_batch_rejected_test() ->
    %% Small max_batch_bytes so we can trip the threshold easily.
    %% Segment must remain big enough to satisfy validate_batch_opts.
    Opts = #{
        max_batch_bytes => 4096,
        max_segment_bytes => 1 * 1024 * 1024
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        %% Big payload per event to force the body past 4 KiB.
        Big = binary:copy(<<"x">>, 1024),
        Events = [
            begin
                Hlc = bondy_oplog_hlc:now(HLC),
                Key = bondy_oplog_event:key(Hlc, origin(), Seq),
                bondy_oplog_event:new(Key, {op, Big}, undefined)
            end
         || Seq <- lists:seq(1, 10)
        ],
        ?assertEqual(
            {error, batch_too_large},
            bondy_oplog_wal:append_batch(Pid, Events)
        ),
        %% Writer is still alive and accepts a smaller batch.
        Small = mk_batch(HLC, 11, 1),
        ?assertMatch({ok, [{_, _}]}, bondy_oplog_wal:append_batch(Pid, Small)),
        ok
    end).

pre_rotation_when_batch_does_not_fit_test() ->
    %% Fill segment 0 with a single batch, then write a batch that
    %% wouldn't fit alongside it. Expect rotation before the second
    %% batch lands so it begins at offset SEG_HEADER of segment 1.
    %% Sized so each batch's frame is ~9 KiB; the 16 KiB segment fits
    %% exactly one such frame.
    Opts = #{
        max_batch_bytes => 12 * 1024,
        max_segment_bytes => 16 * 1024
    },
    with_wal(Opts, fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        Payload = binary:copy(<<"a">>, 256),
        MkBatch = fun(Base, N) ->
            [
                begin
                    Hlc = bondy_oplog_hlc:now(HLC),
                    Key = bondy_oplog_event:key(Hlc, origin(), Seq),
                    bondy_oplog_event:new(Key, {op, Payload}, undefined)
                end
             || Seq <- lists:seq(Base, Base + N - 1)
            ]
        end,
        Batch1 = MkBatch(1, 30),
        {ok, [{_, {Seg1, Off1}} | _]} =
            bondy_oplog_wal:append_batch(Pid, Batch1),
        ?assertEqual(0, Seg1),
        ?assertEqual(?SEG_HEADER, Off1),
        InfoAfter1 = bondy_oplog_wal:info(Pid),
        ?assertEqual(0, maps:get(current_segment, InfoAfter1)),
        Batch2 = MkBatch(100, 30),
        {ok, [{_, {Seg2, Off2}} | _]} =
            bondy_oplog_wal:append_batch(Pid, Batch2),
        ?assertEqual(1, Seg2),
        ?assertEqual(?SEG_HEADER, Off2),
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(1, maps:get(current_segment, Info)),
        ok
    end).

reader_returns_full_batch_test() ->
    with_wal(#{}, fun(Pid, _Dir) ->
        HLC = bondy_oplog_hlc:new(),
        Events = mk_batch(HLC, 1, 4),
        {ok, Entries} = bondy_oplog_wal:append_batch(Pid, Events),
        ExpectedHlcs = [H || {H, _} <- Entries],
        {ok, Iter} = bondy_oplog_wal_reader:open(Pid, beginning),
        case bondy_oplog_wal_reader:next(Iter) of
            {ok, Batch, Hlcs, _Pos, _Iter2} ->
                ?assertEqual(length(Events), length(Batch)),
                ?assertEqual(ExpectedHlcs, Hlcs);
            Other ->
                error({unexpected, Other})
        end,
        ok
    end).

invalid_max_batch_bytes_rejected_at_init_test() ->
    Dir = mktemp_dir(),
    try
        expect_open_error(
            {invalid_opt, max_batch_bytes, 0},
            fun() ->
                bondy_oplog_wal:start_link(
                    instance_id(),
                    #{dir => Dir, origin => origin(), max_batch_bytes => 0}
                )
            end
        )
    after
        rmrf(Dir)
    end.

info_exposes_max_batch_bytes_test() ->
    with_wal(#{max_batch_bytes => 12345}, fun(Pid, _Dir) ->
        Info = bondy_oplog_wal:info(Pid),
        ?assertEqual(12345, maps:get(max_batch_bytes, Info)),
        ok
    end).
