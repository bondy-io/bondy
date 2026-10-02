%% =============================================================================
%% Unit tests for `bondy_log_segment` (segment header create/read).
%%
%% The header's two identity fields are opaque to the segment module; the
%% oplog adapter's encoding and verification of them are tested in
%% `bondy_oplog_log_adapter_test`. Here `verify/3` is exercised through
%% the oplog adapter only to pin the `{orphan_segment, Reason}` wrapping.
%% =============================================================================

-module(bondy_oplog_wal_segment_test).

-include_lib("eunit/include/eunit.hrl").
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

ctx() -> #{instance_id => instance_id(), origin => origin()}.

identity() ->
    {ok, Identity} = bondy_oplog_log_adapter:encode_identity(ctx()),
    Identity.

%% =============================================================================
%% Construction + header round-trip
%% =============================================================================

create_and_read_header_test() ->
    with_dir(fun(Dir) ->
        SegId = 7,
        Path = filename:join(Dir, bondy_log_segment:filename(SegId)),
        {ok, Fd, Header} =
            bondy_log_segment:create(Path, SegId, identity()),
        ok = prim_file:close(Fd),
        ?assertEqual(SegId, bondy_log_segment:segment_id(Header)),
        ?assertEqual(identity(), bondy_log_segment:identity(Header)),
        %% Reopen and re-parse.
        {ok, Fd2, Header2} = bondy_log_segment:open(Path),
        ok = prim_file:close(Fd2),
        ?assertEqual(Header, Header2)
    end).

filename_is_zero_padded_test() ->
    ?assertEqual(<<"000000000.qdata">>, bondy_log_segment:filename(0)),
    ?assertEqual(<<"000000042.qdata">>, bondy_log_segment:filename(42)),
    ?assertEqual(
        <<"999999999.qdata">>,
        bondy_log_segment:filename(999999999)
    ).

header_bytes_is_48_test() ->
    ?assertEqual(48, bondy_log_segment:header_bytes()).

%% =============================================================================
%% Identity validation (verify/3) — orphan detection through the adapter
%% =============================================================================

verify_match_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, bondy_log_segment:filename(0)),
        {ok, Fd, Header} =
            bondy_log_segment:create(Path, 0, identity()),
        ok = prim_file:close(Fd),
        ?assertEqual(
            ok,
            bondy_log_segment:verify(
                Header, bondy_oplog_log_adapter, ctx()
            )
        )
    end).

%% The adapter's reason travels inside `orphan_segment` untouched.
verify_mismatch_is_an_orphan_segment_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, bondy_log_segment:filename(0)),
        {ok, Fd, Header} =
            bondy_log_segment:create(Path, 0, identity()),
        ok = prim_file:close(Fd),
        ?assertMatch(
            {error, {orphan_segment, instance_id_hash_mismatch}},
            bondy_log_segment:verify(
                Header,
                bondy_oplog_log_adapter,
                (ctx())#{instance_id => <<"other-instance">>}
            )
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
            bondy_log_segment:open(Path)
        ),
        ?assertNot(filelib:is_regular(Path))
    end).

open_truncated_header_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, "truncated.qdata"),
        ok = file:write_file(Path, <<1, 2, 3, 4>>),
        ?assertEqual(
            {error, truncated_header},
            bondy_log_segment:open(Path)
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
        ?assertEqual({error, bad_magic}, bondy_log_segment:open(Path))
    end).

create_refuses_existing_file_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, bondy_log_segment:filename(0)),
        ok = file:write_file(Path, <<0>>),
        ?assertMatch(
            {error, _},
            bondy_log_segment:create(Path, 0, identity())
        )
    end).

%% The header fields are fixed-width; an identity of the wrong shape
%% is refused before the file is created.
create_rejects_malformed_identity_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, bondy_log_segment:filename(0)),
        ?assertError(
            function_clause,
            bondy_log_segment:create(
                Path, 0, (identity())#{id16 => <<1, 2, 3>>}
            )
        ),
        ?assertError(
            function_clause,
            bondy_log_segment:create(
                Path, 0, (identity())#{hash8 => <<1, 2, 3>>}
            )
        ),
        ?assertNot(filelib:is_regular(Path))
    end).

%% =============================================================================
%% File position after read_header
%% =============================================================================

read_header_advances_position_test() ->
    %% After read_header/1 the fd is positioned at offset 48 so the caller
    %% can begin appending frames or scanning forward.
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, bondy_log_segment:filename(0)),
        {ok, Fd, _Header} =
            bondy_log_segment:create(Path, 0, identity()),
        ok = prim_file:close(Fd),
        {ok, Fd2, _Header2} = bondy_log_segment:open(Path),
        {ok, Pos} = prim_file:position(Fd2, {cur, 0}),
        ?assertEqual(48, Pos),
        ok = prim_file:close(Fd2)
    end).
