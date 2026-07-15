%% =============================================================================
%% Unit tests for `bondy_oplog_wal_manifest` (manifest read/write +
%% atomic rename).
%% =============================================================================

-module(bondy_oplog_wal_manifest_test).

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
                "bondy_oplog_wal_mfst_~p_~p",
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

instance_id() -> <<"test-instance-mfst">>.

%% =============================================================================
%% Round-trip
%% =============================================================================

new_and_read_back_test() ->
    with_dir(fun(Dir) ->
        M0 = bondy_oplog_wal_manifest:new(
            instance_id(),
            0,
            [{min_segments, 2}]
        ),
        ok = bondy_oplog_wal_manifest:write(Dir, M0),
        {ok, M1} = bondy_oplog_wal_manifest:read(Dir),
        ?assertEqual(
            instance_id(),
            bondy_oplog_wal_manifest:instance_id(M1)
        ),
        ?assertEqual(0, bondy_oplog_wal_manifest:current_segment(M1)),
        ?assertEqual(
            [{0, undefined}],
            bondy_oplog_wal_manifest:live_segments(M1)
        ),
        ?assertEqual(
            [{min_segments, 2}],
            bondy_oplog_wal_manifest:retention(M1)
        )
    end).

rotation_updates_live_segments_test() ->
    with_dir(fun(Dir) ->
        M0 = bondy_oplog_wal_manifest:new(instance_id(), 0, []),
        M1 = bondy_oplog_wal_manifest:with_current_segment(M0, 1, 1000),
        ok = bondy_oplog_wal_manifest:write(Dir, M1),
        {ok, M2} = bondy_oplog_wal_manifest:read(Dir),
        ?assertEqual(1, bondy_oplog_wal_manifest:current_segment(M2)),
        ?assertEqual(
            [{0, 1000}, {1, undefined}],
            bondy_oplog_wal_manifest:live_segments(M2)
        )
    end).

rotation_preserves_existing_first_hlc_test() ->
    %% Once a segment has a first_hlc, subsequent rotations must not
    %% overwrite it.
    M0 = bondy_oplog_wal_manifest:new(instance_id(), 0, []),
    M1 = bondy_oplog_wal_manifest:with_current_segment(M0, 1, 1000),
    %% Now rotate again from 1 to 2; the old "0" entry's first_hlc must
    %% remain 1000 even though we pass a different value through.
    M2 = bondy_oplog_wal_manifest:with_current_segment(M1, 2, 2000),
    Live = bondy_oplog_wal_manifest:live_segments(M2),
    ?assertEqual({0, 1000}, lists:keyfind(0, 1, Live)),
    ?assertEqual({1, 2000}, lists:keyfind(1, 1, Live)),
    ?assertEqual({2, undefined}, lists:keyfind(2, 1, Live)).

retention_sweep_replaces_live_segments_test() ->
    with_dir(fun(Dir) ->
        M0 = bondy_oplog_wal_manifest:new(instance_id(), 0, []),
        M1 = bondy_oplog_wal_manifest:with_current_segment(M0, 1, 1000),
        M2 = bondy_oplog_wal_manifest:with_live_segments(M1, [{1, undefined}]),
        M3 = bondy_oplog_wal_manifest:with_deleted_through(M2, 0),
        ok = bondy_oplog_wal_manifest:write(Dir, M3),
        {ok, M4} = bondy_oplog_wal_manifest:read(Dir),
        ?assertEqual(
            [{1, undefined}],
            bondy_oplog_wal_manifest:live_segments(M4)
        ),
        ?assertEqual(0, bondy_oplog_wal_manifest:deleted_through(M4))
    end).

%% =============================================================================
%% Atomic rename + crash safety
%% =============================================================================

write_creates_no_tmp_residue_on_success_test() ->
    with_dir(fun(Dir) ->
        M = bondy_oplog_wal_manifest:new(instance_id(), 0, []),
        ok = bondy_oplog_wal_manifest:write(Dir, M),
        TmpPath = filename:join(
            Dir,
            ?BONDY_OPLOG_WAL_MANIFEST_TMP_FILENAME
        ),
        ?assertEqual(false, filelib:is_regular(TmpPath))
    end).

write_overwrites_prior_manifest_test() ->
    %% Atomic rename overwrites the prior file. After two writes, the
    %% second one is what's read back; no tmp residue.
    with_dir(fun(Dir) ->
        M0 = bondy_oplog_wal_manifest:new(instance_id(), 0, []),
        ok = bondy_oplog_wal_manifest:write(Dir, M0),
        M1 = bondy_oplog_wal_manifest:with_current_segment(M0, 1, 1000),
        ok = bondy_oplog_wal_manifest:write(Dir, M1),
        {ok, M2} = bondy_oplog_wal_manifest:read(Dir),
        ?assertEqual(1, bondy_oplog_wal_manifest:current_segment(M2)),
        TmpPath = filename:join(
            Dir,
            ?BONDY_OPLOG_WAL_MANIFEST_TMP_FILENAME
        ),
        ?assertEqual(false, filelib:is_regular(TmpPath))
    end).

%% Simulate the "crash after partial tmp write, before rename" scenario:
%% leave a partial tmp file and the prior manifest. The next read must
%% see the prior manifest. The next write must succeed (the tmp file is
%% replaced).
crash_before_rename_recovers_test() ->
    with_dir(fun(Dir) ->
        M0 = bondy_oplog_wal_manifest:new(instance_id(), 0, []),
        ok = bondy_oplog_wal_manifest:write(Dir, M0),
        %% Inject a partial tmp file alongside the good manifest.
        TmpPath = filename:join(
            Dir,
            ?BONDY_OPLOG_WAL_MANIFEST_TMP_FILENAME
        ),
        ok = file:write_file(TmpPath, <<"partial garbage">>),
        {ok, M1} = bondy_oplog_wal_manifest:read(Dir),
        ?assertEqual(0, bondy_oplog_wal_manifest:current_segment(M1)),
        %% A second successful write must overwrite the partial tmp.
        M2 = bondy_oplog_wal_manifest:with_current_segment(M1, 1, 1000),
        ok = bondy_oplog_wal_manifest:write(Dir, M2),
        {ok, M3} = bondy_oplog_wal_manifest:read(Dir),
        ?assertEqual(1, bondy_oplog_wal_manifest:current_segment(M3))
    end).

%% =============================================================================
%% Read error paths
%% =============================================================================

read_missing_file_test() ->
    with_dir(fun(Dir) ->
        ?assertMatch({error, _}, bondy_oplog_wal_manifest:read(Dir))
    end).

read_malformed_file_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, ?BONDY_OPLOG_WAL_MANIFEST_FILENAME),
        ok = file:write_file(Path, <<"not erlang terms[[[">>),
        ?assertMatch({error, _}, bondy_oplog_wal_manifest:read(Dir))
    end).

read_missing_required_field_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, ?BONDY_OPLOG_WAL_MANIFEST_FILENAME),
        %% No instance_id field — required.
        ok = file:write_file(
            Path,
            <<
                "{manifest_version, 1}.\n"
                "{current_segment, 0}.\n"
                "{live_segments, [{0, undefined}]}.\n"
            >>
        ),
        ?assertEqual(
            {error, {missing_field, instance_id}},
            bondy_oplog_wal_manifest:read(Dir)
        )
    end).

read_unsupported_version_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, ?BONDY_OPLOG_WAL_MANIFEST_FILENAME),
        ok = file:write_file(
            Path,
            <<
                "{manifest_version, 999}.\n"
                "{instance_id, <<\"x\">>}.\n"
                "{current_segment, 0}.\n"
                "{live_segments, [{0, undefined}]}.\n"
            >>
        ),
        ?assertEqual(
            {error, {unsupported_manifest_version, 999}},
            bondy_oplog_wal_manifest:read(Dir)
        )
    end).

read_invalid_live_segments_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, ?BONDY_OPLOG_WAL_MANIFEST_FILENAME),
        ok = file:write_file(
            Path,
            <<
                "{manifest_version, 1}.\n"
                "{instance_id, <<\"x\">>}.\n"
                "{current_segment, 0}.\n"
                "{live_segments, [{not_an_id, 1}]}.\n"
            >>
        ),
        ?assertMatch(
            {error, {invalid_live_segment, _}},
            bondy_oplog_wal_manifest:read(Dir)
        )
    end).

%% =============================================================================
%% Forward compatibility — unknown fields are tolerated
%% =============================================================================

unknown_fields_are_ignored_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, ?BONDY_OPLOG_WAL_MANIFEST_FILENAME),
        ok = file:write_file(
            Path,
            <<
                "{manifest_version, 1}.\n"
                "{instance_id, <<\"x\">>}.\n"
                "{current_segment, 0}.\n"
                "{live_segments, [{0, undefined}]}.\n"
                "{some_future_field, [a, b, c]}.\n"
            >>
        ),
        {ok, M} = bondy_oplog_wal_manifest:read(Dir),
        ?assertEqual(<<"x">>, bondy_oplog_wal_manifest:instance_id(M))
    end).
