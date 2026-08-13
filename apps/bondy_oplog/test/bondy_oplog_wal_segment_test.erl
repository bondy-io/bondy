%% =============================================================================
%% Unit tests for `bondy_oplog_wal_segment` (segment header create/read).
%% =============================================================================

-module(bondy_oplog_wal_segment_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

%% =============================================================================
%% Fixture helpers
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_oplog_wal_seg_~p_~p",
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

with_dir(Fun) ->
    Dir = mktemp_dir(),
    try
        Fun(Dir)
    after
        rmrf(Dir)
    end.

instance_id() -> <<"test-instance-1">>.
origin() -> <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>.

%% =============================================================================
%% Construction + header round-trip
%% =============================================================================

create_and_read_header_test() ->
    with_dir(fun(Dir) ->
        SegId = 7,
        Path = filename:join(Dir, bondy_oplog_wal_segment:filename(SegId)),
        {ok, Fd, Header} =
            bondy_oplog_wal_segment:create(
                Path, SegId, instance_id(), origin()
            ),
        ok = prim_file:close(Fd),
        ?assertEqual(SegId, bondy_oplog_wal_segment:segment_id(Header)),
        ?assertEqual(origin(), bondy_oplog_wal_segment:origin(Header)),
        %% Reopen and re-parse.
        {ok, Fd2, Header2} = bondy_oplog_wal_segment:open(Path),
        ok = prim_file:close(Fd2),
        ?assertEqual(Header, Header2)
    end).

filename_is_zero_padded_test() ->
    ?assertEqual(<<"000000000.qdata">>, bondy_oplog_wal_segment:filename(0)),
    ?assertEqual(<<"000000042.qdata">>, bondy_oplog_wal_segment:filename(42)),
    ?assertEqual(
        <<"999999999.qdata">>,
        bondy_oplog_wal_segment:filename(999999999)
    ).

instance_id_hash_is_8_bytes_test() ->
    Hash = bondy_oplog_wal_segment:instance_id_hash(instance_id()),
    ?assertEqual(8, byte_size(Hash)).

instance_id_hash_is_stable_test() ->
    ?assertEqual(
        bondy_oplog_wal_segment:instance_id_hash(<<"abc">>),
        bondy_oplog_wal_segment:instance_id_hash(<<"abc">>)
    ),
    ?assertNotEqual(
        bondy_oplog_wal_segment:instance_id_hash(<<"abc">>),
        bondy_oplog_wal_segment:instance_id_hash(<<"abd">>)
    ).

header_bytes_is_48_test() ->
    ?assertEqual(48, bondy_oplog_wal_segment:header_bytes()).

%% =============================================================================
%% Identity validation (verify/3) — orphan detection
%% =============================================================================

verify_match_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, bondy_oplog_wal_segment:filename(0)),
        {ok, Fd, Header} =
            bondy_oplog_wal_segment:create(Path, 0, instance_id(), origin()),
        ok = prim_file:close(Fd),
        ?assertEqual(
            ok,
            bondy_oplog_wal_segment:verify(
                Header,
                instance_id(),
                origin()
            )
        )
    end).

verify_instance_mismatch_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, bondy_oplog_wal_segment:filename(0)),
        {ok, Fd, Header} =
            bondy_oplog_wal_segment:create(Path, 0, instance_id(), origin()),
        ok = prim_file:close(Fd),
        ?assertMatch(
            {error, {orphan_segment, instance_id_hash_mismatch}},
            bondy_oplog_wal_segment:verify(
                Header,
                <<"other-instance">>,
                origin()
            )
        )
    end).

verify_origin_mismatch_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, bondy_oplog_wal_segment:filename(0)),
        {ok, Fd, Header} =
            bondy_oplog_wal_segment:create(Path, 0, instance_id(), origin()),
        ok = prim_file:close(Fd),
        OtherOrigin = <<16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1>>,
        ?assertMatch(
            {error, {orphan_segment, origin_mismatch}},
            bondy_oplog_wal_segment:verify(Header, instance_id(), OtherOrigin)
        )
    end).

%% =============================================================================
%% Open failure modes
%% =============================================================================

open_missing_file_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, "does-not-exist.qdata"),
        %% An absent segment is reported as absent, NOT as a corrupt
        %% header, and probing for it must not bring it into existence.
        %% Opening `[read, write]` here would create a 0-byte file and
        %% report `truncated_header`, which then looks like real
        %% corruption to every later open.
        ?assertEqual(
            {error, missing_segment},
            bondy_oplog_wal_segment:open(Path)
        ),
        ?assertNot(filelib:is_regular(Path))
    end).

open_truncated_header_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, "truncated.qdata"),
        ok = file:write_file(Path, <<1, 2, 3, 4>>),
        ?assertEqual(
            {error, truncated_header},
            bondy_oplog_wal_segment:open(Path)
        )
    end).

open_bad_magic_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, "bad-magic.qdata"),
        Garbage = crypto:strong_rand_bytes(48),
        %% Make sure the first 4 bytes aren't accidentally the BDSG magic.
        <<_:32, Rest/binary>> = Garbage,
        Bin = <<16#DEADBEEF:32, Rest/binary>>,
        ok = file:write_file(Path, Bin),
        ?assertEqual({error, bad_magic}, bondy_oplog_wal_segment:open(Path))
    end).

create_refuses_existing_file_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, bondy_oplog_wal_segment:filename(0)),
        ok = file:write_file(Path, <<0>>),
        ?assertMatch(
            {error, _},
            bondy_oplog_wal_segment:create(
                Path,
                0,
                instance_id(),
                origin()
            )
        )
    end).

create_rejects_invalid_origin_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, bondy_oplog_wal_segment:filename(0)),
        TooShort = <<1, 2, 3>>,
        ?assertError(
            function_clause,
            bondy_oplog_wal_segment:create(Path, 0, instance_id(), TooShort)
        )
    end).

%% =============================================================================
%% File position after read_header
%% =============================================================================

read_header_advances_position_test() ->
    %% After read_header/1 the fd is positioned at offset 48 so the caller
    %% can begin appending frames or scanning forward.
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, bondy_oplog_wal_segment:filename(0)),
        {ok, Fd, _Header} =
            bondy_oplog_wal_segment:create(Path, 0, instance_id(), origin()),
        ok = prim_file:close(Fd),
        {ok, Fd2, _Header2} = bondy_oplog_wal_segment:open(Path),
        {ok, Pos} = prim_file:position(Fd2, {cur, 0}),
        ?assertEqual(48, Pos),
        ok = prim_file:close(Fd2)
    end).
