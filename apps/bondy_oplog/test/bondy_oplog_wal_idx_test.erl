%% =============================================================================
%% Unit tests for `bondy_oplog_wal_idx` (sparse HLC index `.qidx`).
%%
%% Tests cover the three concerns of the index module:
%%
%% 1. Accumulator semantics — first frame always indexed, subsequent
%%    frames indexed only when bytes-since-last crosses the interval,
%%    interval reset on emit, entries returned in HLC-ascending order.
%%    Entries are `{FirstHlc, LastHlc, Offset}` triples.
%% 2. File I/O — header/entry codec round-trip via write_file/read_file;
%%    v2-format writes, v1-format reads (legacy `.qidx` files lifted to
%%    the v2 shape at read time); empty index is valid; atomic rename;
%%    error paths for truncated and bad-magic files.
%% 3. Seek — range-aware binary search returns the entry whose range
%%    contains T (or the largest entry with LastHlc <= T as fallback).
%% =============================================================================

-module(bondy_oplog_wal_idx_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog_wal.hrl").

-define(MAGIC, ?BONDY_OPLOG_WAL_IDX_MAGIC).
-define(HEADER, ?BONDY_OPLOG_WAL_IDX_HEADER_BYTES).
-define(ENTRY_V1, ?BONDY_OPLOG_WAL_IDX_ENTRY_BYTES_V1).
-define(ENTRY_V2, ?BONDY_OPLOG_WAL_IDX_ENTRY_BYTES_V2).
-define(VERSION_V1, ?BONDY_OPLOG_WAL_IDX_VERSION_V1).
-define(VERSION_V2, ?BONDY_OPLOG_WAL_IDX_VERSION_V2).

%% =============================================================================
%% Fixture helpers
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_oplog_wal_idx_test_~p_~p",
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
%% Constants
%% =============================================================================

filename_renders_zero_padded_9_digit_decimal_test() ->
    ?assertEqual(<<"000000000.qidx">>, bondy_oplog_wal_idx:filename(0)),
    ?assertEqual(<<"000000042.qidx">>, bondy_oplog_wal_idx:filename(42)),
    ?assertEqual(<<"123456789.qidx">>, bondy_oplog_wal_idx:filename(123456789)).

header_bytes_is_16_test() ->
    ?assertEqual(16, bondy_oplog_wal_idx:header_bytes()),
    ?assertEqual(16, ?HEADER).

entry_bytes_is_24_for_v2_test() ->
    ?assertEqual(24, bondy_oplog_wal_idx:entry_bytes()),
    ?assertEqual(24, ?ENTRY_V2),
    %% v1 fallback shape remains 16 bytes on-disk.
    ?assertEqual(16, ?ENTRY_V1).

%% =============================================================================
%% Accumulator
%% =============================================================================

new_returns_empty_accumulator_test() ->
    Acc = bondy_oplog_wal_idx:new(),
    ?assertEqual([], bondy_oplog_wal_idx:entries(Acc)),
    ?assertEqual(0, bondy_oplog_wal_idx:entry_count(Acc)),
    ?assertEqual(
        ?BONDY_OPLOG_WAL_IDX_DEFAULT_INTERVAL_BYTES,
        bondy_oplog_wal_idx:interval_bytes(Acc)
    ).

new_with_custom_interval_test() ->
    Acc = bondy_oplog_wal_idx:new(1024),
    ?assertEqual(1024, bondy_oplog_wal_idx:interval_bytes(Acc)).

first_frame_is_always_indexed_test() ->
    %% Even when frame size < interval, the very first frame of a
    %% segment must produce an entry so seek always finds at least one
    %% anchor point.
    Acc0 = bondy_oplog_wal_idx:new(1_000_000),
    Acc1 = bondy_oplog_wal_idx:note_frame(Acc0, 100, 105, 48, 80),
    ?assertEqual(
        [{100, 105, 48}],
        bondy_oplog_wal_idx:entries(Acc1)
    ),
    ?assertEqual(1, bondy_oplog_wal_idx:entry_count(Acc1)).

subsequent_frames_indexed_only_after_interval_test() ->
    %% Interval = 1000 bytes; frames are 100 bytes each.
    Acc0 = bondy_oplog_wal_idx:new(1000),
    Acc1 = bondy_oplog_wal_idx:note_frame(Acc0, 100, 100, 48, 100),
    Acc10 = lists:foldl(
        fun(I, A) ->
            Off = 48 + I * 100,
            Hlc = 100 + I,
            bondy_oplog_wal_idx:note_frame(A, Hlc, Hlc, Off, 100)
        end,
        Acc1,
        lists:seq(1, 9)
    ),
    ?assertEqual(1, bondy_oplog_wal_idx:entry_count(Acc10)),
    %% Frame 10 crosses interval → emit.
    Acc11 = bondy_oplog_wal_idx:note_frame(Acc10, 110, 110, 1048, 100),
    ?assertEqual(2, bondy_oplog_wal_idx:entry_count(Acc11)),
    ?assertEqual(
        [{100, 100, 48}, {110, 110, 1048}],
        bondy_oplog_wal_idx:entries(Acc11)
    ).

entries_are_hlc_ascending_test() ->
    Acc0 = bondy_oplog_wal_idx:new(100),
    %% Three entries: small interval forces emit on every frame.
    Acc1 = bondy_oplog_wal_idx:note_frame(Acc0, 100, 105, 48, 200),
    Acc2 = bondy_oplog_wal_idx:note_frame(Acc1, 110, 115, 248, 200),
    Acc3 = bondy_oplog_wal_idx:note_frame(Acc2, 120, 125, 448, 200),
    ?assertEqual(
        [{100, 105, 48}, {110, 115, 248}, {120, 125, 448}],
        bondy_oplog_wal_idx:entries(Acc3)
    ).

note_indexed_frame_rejects_last_below_first_test() ->
    %% Guard on `note_indexed_frame/4`: LastHlc must be >= FirstHlc.
    Acc = bondy_oplog_wal_idx:new(1000),
    ?assertError(
        function_clause,
        bondy_oplog_wal_idx:note_indexed_frame(Acc, 200, 100, 48)
    ).

interval_resets_on_emit_test() ->
    Acc0 = bondy_oplog_wal_idx:new(500),
    Acc1 = bondy_oplog_wal_idx:note_frame(Acc0, 1, 1, 48, 300),
    Acc2 = bondy_oplog_wal_idx:note_frame(Acc1, 2, 2, 348, 300),
    ?assertEqual(1, bondy_oplog_wal_idx:entry_count(Acc2)),
    Acc3 = bondy_oplog_wal_idx:note_frame(Acc2, 3, 3, 648, 300),
    ?assertEqual(2, bondy_oplog_wal_idx:entry_count(Acc3)),
    Acc4 = bondy_oplog_wal_idx:note_frame(Acc3, 4, 4, 948, 300),
    ?assertEqual(2, bondy_oplog_wal_idx:entry_count(Acc4)).

%% =============================================================================
%% File I/O
%% =============================================================================

write_then_read_roundtrip_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        Entries = [{100, 105, 48}, {200, 210, 1024}, {300, 320, 2048}],
        ok = bondy_oplog_wal_idx:write_file(Path, Entries),
        ?assertEqual({ok, Entries}, bondy_oplog_wal_idx:read_file(Path))
    end).

write_empty_index_is_valid_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        ok = bondy_oplog_wal_idx:write_file(Path, []),
        ?assertEqual({ok, []}, bondy_oplog_wal_idx:read_file(Path)),
        %% File should be exactly 16 bytes (header only).
        {ok, FileInfo} = file:read_file_info(Path),
        ?assertEqual(16, element(2, FileInfo))
    end).

write_produces_v2_header_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        ok = bondy_oplog_wal_idx:write_file(Path, [{100, 105, 48}]),
        {ok, Bin} = file:read_file(Path),
        <<_Magic:32/big, Version:8, _:24, EntryCount:32/big, _:32, Body/binary>> =
            Bin,
        ?assertEqual(?VERSION_V2, Version),
        ?assertEqual(1, EntryCount),
        ?assertEqual(?ENTRY_V2, byte_size(Body))
    end).

read_v1_lifts_entries_to_v2_shape_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        %% Hand-craft a v1 file: header version = 1, 16-byte entries
        %% (HLC + Offset). Mixes a single-HLC range and a "v1 batch"
        %% (which v2 readers see as a single-point range).
        Header =
            <<?MAGIC:32/big-unsigned, ?VERSION_V1:8/unsigned, 0:24/big-unsigned,
                2:32/big-unsigned, 0:32/big-unsigned>>,
        V1Entries =
            <<100:64/big-unsigned, 48:64/big-unsigned, 200:64/big-unsigned,
                1024:64/big-unsigned>>,
        ok = file:write_file(Path, [Header, V1Entries]),
        %% Reader lifts each `(H, Off)` to `(H, H, Off)`.
        ?assertEqual(
            {ok, [{100, 100, 48}, {200, 200, 1024}]},
            bondy_oplog_wal_idx:read_file(Path)
        )
    end).

read_v1_via_open_seeks_correctly_test() ->
    %% A v1 file lifted to v2 shape behaves identically to v1's
    %% "largest HLC <= T" semantics for any T (since every range is a
    %% single point).
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        Header =
            <<?MAGIC:32/big-unsigned, ?VERSION_V1:8/unsigned, 0:24/big-unsigned,
                3:32/big-unsigned, 0:32/big-unsigned>>,
        V1Entries =
            <<100:64/big-unsigned, 48:64/big-unsigned, 200:64/big-unsigned,
                1024:64/big-unsigned, 300:64/big-unsigned,
                2048:64/big-unsigned>>,
        ok = file:write_file(Path, [Header, V1Entries]),
        {ok, Handle} = bondy_oplog_wal_idx:open(Path),
        ?assertEqual(none, bondy_oplog_wal_idx:seek(Handle, 50)),
        ?assertEqual({ok, 48}, bondy_oplog_wal_idx:seek(Handle, 100)),
        ?assertEqual({ok, 48}, bondy_oplog_wal_idx:seek(Handle, 150)),
        ?assertEqual({ok, 1024}, bondy_oplog_wal_idx:seek(Handle, 200)),
        ?assertEqual({ok, 1024}, bondy_oplog_wal_idx:seek(Handle, 299)),
        ?assertEqual({ok, 2048}, bondy_oplog_wal_idx:seek(Handle, 300)),
        ?assertEqual({ok, 2048}, bondy_oplog_wal_idx:seek(Handle, 99999))
    end).

read_nonexistent_file_returns_enoent_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "does_not_exist.qidx"),
        ?assertEqual({error, enoent}, bondy_oplog_wal_idx:read_file(Path))
    end).

read_truncated_header_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        ok = file:write_file(Path, <<1, 2, 3, 4, 5, 6, 7, 8>>),
        ?assertEqual(
            {error, truncated_header},
            bondy_oplog_wal_idx:read_file(Path)
        )
    end).

read_bad_magic_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        ok = file:write_file(
            Path, <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
        ),
        ?assertEqual({error, bad_magic}, bondy_oplog_wal_idx:read_file(Path))
    end).

read_unsupported_version_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        %% Valid magic but version = 99.
        Bin = <<?MAGIC:32/big-unsigned, 99:8, 0:24, 0:32, 0:32>>,
        ok = file:write_file(Path, Bin),
        ?assertEqual(
            {error, unsupported_version},
            bondy_oplog_wal_idx:read_file(Path)
        )
    end).

read_truncated_entries_v2_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        %% Header claims 2 entries but only 1 entry's worth of bytes
        %% follows.
        Header =
            <<?MAGIC:32/big-unsigned, ?VERSION_V2:8/unsigned, 0:24,
                2:32/big-unsigned, 0:32/big-unsigned>>,
        Entry =
            <<100:64/big-unsigned, 105:64/big-unsigned, 48:64/big-unsigned>>,
        ok = file:write_file(Path, [Header, Entry]),
        ?assertEqual(
            {error, truncated_entries},
            bondy_oplog_wal_idx:read_file(Path)
        )
    end).

read_truncated_entries_v1_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        Header =
            <<?MAGIC:32/big-unsigned, ?VERSION_V1:8/unsigned, 0:24,
                2:32/big-unsigned, 0:32/big-unsigned>>,
        Entry = <<100:64/big-unsigned, 48:64/big-unsigned>>,
        ok = file:write_file(Path, [Header, Entry]),
        ?assertEqual(
            {error, truncated_entries},
            bondy_oplog_wal_idx:read_file(Path)
        )
    end).

read_trailing_bytes_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        Header =
            <<?MAGIC:32/big-unsigned, ?VERSION_V2:8/unsigned, 0:24,
                0:32/big-unsigned, 0:32/big-unsigned>>,
        ok = file:write_file(Path, [Header, <<"garbage">>]),
        ?assertEqual(
            {error, trailing_bytes},
            bondy_oplog_wal_idx:read_file(Path)
        )
    end).

write_is_atomic_rename_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        TmpPath = iolist_to_binary([Path, ".tmp"]),
        ok = bondy_oplog_wal_idx:write_file(Path, [{100, 105, 48}]),
        ?assert(filelib:is_regular(Path)),
        ?assertNot(filelib:is_regular(TmpPath))
    end).

write_overwrites_existing_file_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        ok = bondy_oplog_wal_idx:write_file(Path, [{100, 105, 48}]),
        ok = bondy_oplog_wal_idx:write_file(
            Path, [{100, 105, 48}, {200, 210, 1024}]
        ),
        ?assertEqual(
            {ok, [{100, 105, 48}, {200, 210, 1024}]},
            bondy_oplog_wal_idx:read_file(Path)
        )
    end).

write_accumulator_entries_round_trip_test() ->
    with_tmp_dir(fun(Dir) ->
        Acc0 = bondy_oplog_wal_idx:new(100),
        Acc1 = bondy_oplog_wal_idx:note_frame(Acc0, 1, 5, 48, 100),
        Acc2 = bondy_oplog_wal_idx:note_frame(Acc1, 10, 15, 148, 100),
        Acc3 = bondy_oplog_wal_idx:note_frame(Acc2, 20, 25, 248, 100),
        Entries = bondy_oplog_wal_idx:entries(Acc3),
        Path = filename:join(Dir, "000000000.qidx"),
        ok = bondy_oplog_wal_idx:write_file(Path, Entries),
        ?assertEqual({ok, Entries}, bondy_oplog_wal_idx:read_file(Path))
    end).

%% =============================================================================
%% Reader handle / seek (v2 range semantics)
%% =============================================================================

from_entries_empty_returns_handle_test() ->
    Handle = bondy_oplog_wal_idx:from_entries([]),
    ?assertEqual([], bondy_oplog_wal_idx:handle_entries(Handle)),
    ?assertEqual(none, bondy_oplog_wal_idx:seek(Handle, 100)).

seek_finds_exact_match_at_first_hlc_test() ->
    Handle = bondy_oplog_wal_idx:from_entries(
        [{100, 110, 48}, {200, 210, 1024}, {300, 320, 2048}]
    ),
    ?assertEqual({ok, 1024}, bondy_oplog_wal_idx:seek(Handle, 200)).

seek_target_inside_range_returns_that_entry_test() ->
    %% T = 205 is inside {200, 210, 1024}'s range.
    Handle = bondy_oplog_wal_idx:from_entries(
        [{100, 110, 48}, {200, 210, 1024}, {300, 320, 2048}]
    ),
    ?assertEqual({ok, 1024}, bondy_oplog_wal_idx:seek(Handle, 205)),
    %% T = 210 is at the upper bound of that range — still inside.
    ?assertEqual({ok, 1024}, bondy_oplog_wal_idx:seek(Handle, 210)),
    %% T = 320 is the upper bound of the last range — still inside.
    ?assertEqual({ok, 2048}, bondy_oplog_wal_idx:seek(Handle, 320)).

seek_target_between_ranges_returns_fallback_test() ->
    %% T = 150 falls between {100, 110} and {200, 210}; v1-style
    %% fallback returns the previous entry's offset.
    Handle = bondy_oplog_wal_idx:from_entries(
        [{100, 110, 48}, {200, 210, 1024}, {300, 320, 2048}]
    ),
    ?assertEqual({ok, 48}, bondy_oplog_wal_idx:seek(Handle, 150)),
    %% T = 250 between {200, 210} and {300, 320}.
    ?assertEqual({ok, 1024}, bondy_oplog_wal_idx:seek(Handle, 250)),
    %% T = 211 just past {200, 210}.
    ?assertEqual({ok, 1024}, bondy_oplog_wal_idx:seek(Handle, 211)).

seek_target_above_all_ranges_returns_last_test() ->
    Handle = bondy_oplog_wal_idx:from_entries(
        [{100, 110, 48}, {200, 210, 1024}, {300, 320, 2048}]
    ),
    ?assertEqual({ok, 2048}, bondy_oplog_wal_idx:seek(Handle, 1000)).

seek_returns_none_for_t_below_first_first_hlc_test() ->
    Handle = bondy_oplog_wal_idx:from_entries(
        [{100, 110, 48}, {200, 210, 1024}, {300, 320, 2048}]
    ),
    ?assertEqual(none, bondy_oplog_wal_idx:seek(Handle, 50)),
    %% T = 99 is one below the first FirstHlc — none.
    ?assertEqual(none, bondy_oplog_wal_idx:seek(Handle, 99)).

seek_single_entry_test() ->
    Handle = bondy_oplog_wal_idx:from_entries([{100, 110, 48}]),
    ?assertEqual({ok, 48}, bondy_oplog_wal_idx:seek(Handle, 100)),
    ?assertEqual({ok, 48}, bondy_oplog_wal_idx:seek(Handle, 105)),
    ?assertEqual({ok, 48}, bondy_oplog_wal_idx:seek(Handle, 110)),
    %% Above range — fallback to this entry.
    ?assertEqual({ok, 48}, bondy_oplog_wal_idx:seek(Handle, 1000)),
    ?assertEqual(none, bondy_oplog_wal_idx:seek(Handle, 99)).

seek_at_t_equals_first_hlc_returns_first_test() ->
    Handle = bondy_oplog_wal_idx:from_entries(
        [{100, 110, 48}, {200, 210, 1024}]
    ),
    ?assertEqual({ok, 48}, bondy_oplog_wal_idx:seek(Handle, 100)).

seek_large_index_test() ->
    %% Build an index with 1000 entries, each indexing a batch of 5
    %% HLCs. Entries are {H, H+4, Off}; HLCs start at 10 and stride by 10.
    Entries = [{H, H + 4, H * 1000} || H <- lists:seq(10, 10000, 10)],
    Handle = bondy_oplog_wal_idx:from_entries(Entries),
    %% T = 9 → below first FirstHlc → none.
    ?assertEqual(none, bondy_oplog_wal_idx:seek(Handle, 9)),
    %% T = 10 → inside {10, 14, 10000}.
    ?assertEqual({ok, 10000}, bondy_oplog_wal_idx:seek(Handle, 10)),
    %% T = 14 → still inside that range (upper bound).
    ?assertEqual({ok, 10000}, bondy_oplog_wal_idx:seek(Handle, 14)),
    %% T = 15 → in gap → fallback to {10, 14, 10000}.
    ?assertEqual({ok, 10000}, bondy_oplog_wal_idx:seek(Handle, 15)),
    %% T = 1234 → in gap between {1230, 1234, ...} and {1240, 1244, ...}.
    %% {1230, 1234, 1230000} contains 1234 (upper bound) → in-range hit.
    ?assertEqual({ok, 1230000}, bondy_oplog_wal_idx:seek(Handle, 1234)),
    %% T = 1235 → gap → fallback to {1230, 1234, 1230000}.
    ?assertEqual({ok, 1230000}, bondy_oplog_wal_idx:seek(Handle, 1235)),
    %% T = 5000 → inside {5000, 5004, 5000000}.
    ?assertEqual({ok, 5000000}, bondy_oplog_wal_idx:seek(Handle, 5000)),
    %% T = 10005 → above last range → fallback to last.
    ?assertEqual({ok, 10000000}, bondy_oplog_wal_idx:seek(Handle, 10005)),
    %% T = 10_000_000 → far above → still fallback to last.
    ?assertEqual({ok, 10000000}, bondy_oplog_wal_idx:seek(Handle, 10000000)).

open_round_trips_via_file_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "000000000.qidx"),
        Entries = [{100, 110, 48}, {200, 210, 1024}, {300, 320, 2048}],
        ok = bondy_oplog_wal_idx:write_file(Path, Entries),
        {ok, Handle} = bondy_oplog_wal_idx:open(Path),
        ?assertEqual(Entries, bondy_oplog_wal_idx:handle_entries(Handle)),
        ?assertEqual({ok, 1024}, bondy_oplog_wal_idx:seek(Handle, 205))
    end).

open_propagates_file_errors_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = filename:join(Dir, "missing.qidx"),
        ?assertEqual({error, enoent}, bondy_oplog_wal_idx:open(Path))
    end).
