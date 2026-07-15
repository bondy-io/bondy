%% =============================================================================
%% Unit tests for `bondy_oplog_wal_state` — the persistent state-file
%% module that owns `consumer.offset` (applier commit position) and
%% `snapshot.watermark` (retention watermark).
%%
%% Tests cover:
%% 1. `new_consumer_offset/0` defaults — segment 0, offset at the
%%    segment header boundary, no HLC, count 0.
%% 2. Read of a missing consumer.offset returns `new_consumer_offset/0`
%%    (a never-committed WAL is indistinguishable from a fresh-and-empty
%%    one).
%% 3. Consumer-offset write/read round-trip preserves all fields.
%% 4. Atomic rename — after a successful write the `.tmp` is gone.
%% 5. Parse errors — bad terms, missing fields, unsupported version.
%% 6. with_position / with_hlc / with_commit_count setters.
%% =============================================================================

-module(bondy_oplog_wal_state_test).

-include_lib("eunit/include/eunit.hrl").
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
                "bondy_oplog_wal_state_test_~p_~p",
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

with_tmp_dir(Fun) ->
    Dir = mktemp_dir(),
    try
        Fun(Dir)
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% new_consumer_offset/0
%% =============================================================================

new_returns_defaults_test() ->
    CO = bondy_oplog_wal_state:new_consumer_offset(),
    ?assertEqual(0, bondy_oplog_wal_state:committed_segment(CO)),
    ?assertEqual(
        ?SEG_HEADER,
        bondy_oplog_wal_state:committed_frame_offset(CO)
    ),
    ?assertEqual(
        undefined, bondy_oplog_wal_state:committed_hlc(CO)
    ),
    ?assertEqual(0, bondy_oplog_wal_state:commit_count(CO)).

%% =============================================================================
%% read/write round-trip
%% =============================================================================

read_missing_file_returns_new_test() ->
    with_tmp_dir(fun(Dir) ->
        ?assertEqual(
            {ok, bondy_oplog_wal_state:new_consumer_offset()},
            bondy_oplog_wal_state:read_consumer_offset(Dir)
        )
    end).

write_then_read_roundtrip_test() ->
    with_tmp_dir(fun(Dir) ->
        CO0 = bondy_oplog_wal_state:new_consumer_offset(),
        CO1 = bondy_oplog_wal_state:with_position(CO0, 5, 1024),
        CO2 = bondy_oplog_wal_state:with_hlc(CO1, 1715520000123),
        CO3 = bondy_oplog_wal_state:with_commit_count(CO2, 42),
        ok = bondy_oplog_wal_state:write_consumer_offset(Dir, CO3),
        {ok, Read} = bondy_oplog_wal_state:read_consumer_offset(Dir),
        ?assertEqual(5, bondy_oplog_wal_state:committed_segment(Read)),
        ?assertEqual(
            1024,
            bondy_oplog_wal_state:committed_frame_offset(Read)
        ),
        ?assertEqual(
            1715520000123,
            bondy_oplog_wal_state:committed_hlc(Read)
        ),
        ?assertEqual(42, bondy_oplog_wal_state:commit_count(Read))
    end).

write_uses_tmp_then_rename_test() ->
    with_tmp_dir(fun(Dir) ->
        CO = bondy_oplog_wal_state:new_consumer_offset(),
        ok = bondy_oplog_wal_state:write_consumer_offset(Dir, CO),
        FinalPath = filename:join(
            Dir, ?BONDY_OPLOG_WAL_CONSUMER_OFFSET_FILENAME
        ),
        TmpPath = filename:join(
            Dir, ?BONDY_OPLOG_WAL_CONSUMER_OFFSET_TMP_FILENAME
        ),
        ?assert(filelib:is_regular(FinalPath)),
        ?assertNot(filelib:is_regular(TmpPath))
    end).

write_overwrites_existing_test() ->
    with_tmp_dir(fun(Dir) ->
        CO1 = bondy_oplog_wal_state:with_commit_count(
            bondy_oplog_wal_state:new_consumer_offset(), 1
        ),
        ok = bondy_oplog_wal_state:write_consumer_offset(Dir, CO1),
        CO2 = bondy_oplog_wal_state:with_commit_count(CO1, 2),
        ok = bondy_oplog_wal_state:write_consumer_offset(Dir, CO2),
        {ok, Read} = bondy_oplog_wal_state:read_consumer_offset(Dir),
        ?assertEqual(2, bondy_oplog_wal_state:commit_count(Read))
    end).

%% =============================================================================
%% Parse errors
%% =============================================================================

read_missing_required_field_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(
            Dir, ?BONDY_OPLOG_WAL_CONSUMER_OFFSET_FILENAME
        ),
        %% Missing committed_frame_offset.
        ok = file:write_file(
            Path,
            "{committed_segment, 0}.\n"
            "{commit_count, 0}.\n"
        ),
        ?assertMatch(
            {error, {missing_field, committed_frame_offset}},
            bondy_oplog_wal_state:read_consumer_offset(Dir)
        )
    end).

read_unsupported_schema_version_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(
            Dir, ?BONDY_OPLOG_WAL_CONSUMER_OFFSET_FILENAME
        ),
        ok = file:write_file(
            Path,
            "{committed_segment, 0}.\n"
            "{committed_frame_offset, 48}.\n"
            "{schema_version, 99}.\n"
        ),
        ?assertMatch(
            {error, {unsupported_schema_version, 99}},
            bondy_oplog_wal_state:read_consumer_offset(Dir)
        )
    end).

read_invalid_committed_segment_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(
            Dir, ?BONDY_OPLOG_WAL_CONSUMER_OFFSET_FILENAME
        ),
        ok = file:write_file(
            Path,
            "{committed_segment, not_a_number}.\n"
            "{committed_frame_offset, 48}.\n"
        ),
        ?assertMatch(
            {error, {invalid_field, committed_segment, _}},
            bondy_oplog_wal_state:read_consumer_offset(Dir)
        )
    end).

read_negative_offset_rejected_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(
            Dir, ?BONDY_OPLOG_WAL_CONSUMER_OFFSET_FILENAME
        ),
        ok = file:write_file(
            Path,
            "{committed_segment, 0}.\n"
            "{committed_frame_offset, -1}.\n"
        ),
        ?assertMatch(
            {error, {invalid_field, committed_frame_offset, _}},
            bondy_oplog_wal_state:read_consumer_offset(Dir)
        )
    end).

%% =============================================================================
%% with_* setters
%% =============================================================================

with_position_updates_both_fields_test() ->
    CO = bondy_oplog_wal_state:with_position(
        bondy_oplog_wal_state:new_consumer_offset(), 7, 2048
    ),
    ?assertEqual(7, bondy_oplog_wal_state:committed_segment(CO)),
    ?assertEqual(
        2048, bondy_oplog_wal_state:committed_frame_offset(CO)
    ).

with_hlc_accepts_integer_and_undefined_test() ->
    CO0 = bondy_oplog_wal_state:new_consumer_offset(),
    CO1 = bondy_oplog_wal_state:with_hlc(CO0, 1234567890),
    ?assertEqual(
        1234567890, bondy_oplog_wal_state:committed_hlc(CO1)
    ),
    CO2 = bondy_oplog_wal_state:with_hlc(CO1, undefined),
    ?assertEqual(
        undefined, bondy_oplog_wal_state:committed_hlc(CO2)
    ).

with_commit_count_test() ->
    CO = bondy_oplog_wal_state:with_commit_count(
        bondy_oplog_wal_state:new_consumer_offset(), 100
    ),
    ?assertEqual(100, bondy_oplog_wal_state:commit_count(CO)).
