%% =============================================================================
%% Tests for `bondy_log_io:write_atomic/2,3`.
%%
%% The property under test: the target path never shows anything but its
%% previous complete content or the new complete content — under a failing
%% datasync, a failing rename, and a caller killed between the tmp write and
%% the rename. The I/O seams are mocked through `bondy_mst_io`, holding the
%% global lock the other fault-injecting suites use so mocks never overlap.
%% =============================================================================

-module(bondy_log_io_test).

-include_lib("eunit/include/eunit.hrl").

-define(OLD, <<"old content\n">>).
-define(NEW, <<"new content, longer than the old one\n">>).

%% =============================================================================
%% Happy paths
%% =============================================================================

replaces_content_and_leaves_no_tmp_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, "manifest"),
        ok = file:write_file(Path, ?OLD),
        ?assertEqual(ok, bondy_log_io:write_atomic(Path, ?NEW)),
        ?assertEqual({ok, ?NEW}, file:read_file(Path)),
        ?assertEqual([<<"manifest">>], entries(Dir))
    end).

creates_when_absent_and_accepts_iodata_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, "fresh.qidx"),
        ?assertEqual(
            ok, bondy_log_io:write_atomic(Path, [<<"a">>, [$b, <<"c">>]])
        ),
        ?assertEqual({ok, <<"abc">>}, file:read_file(Path)),
        ?assertEqual([<<"fresh.qidx">>], entries(Dir))
    end).

binary_path_uses_binary_tmp_name_test() ->
    with_dir(fun(Dir) ->
        Path = unicode:characters_to_binary(filename:join(Dir, "state")),
        with_io_fault_lock(fun() ->
            ok = bondy_log_io:write_atomic(Path, ?NEW),
            ?assertEqual(
                [{<<Path/binary, ".tmp">>, Path}],
                [
                    {From, To}
                 || {_, {bondy_mst_io, rename, [From, To]}, _} <- meck:history(
                        bondy_mst_io
                    )
                ]
            )
        end),
        ?assertEqual({ok, ?NEW}, file:read_file(Path))
    end).

explicit_tmp_path_is_the_one_renamed_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, "manifest"),
        Tmp = filename:join(Dir, "manifest.staging"),
        with_io_fault_lock(fun() ->
            ok = bondy_log_io:write_atomic(Path, ?NEW, #{tmp_path => Tmp}),
            ?assert(meck:called(bondy_mst_io, rename, [Tmp, Path])),
            ?assert(meck:called(bondy_mst_io, fsync_dir, [Dir]))
        end),
        ?assertEqual({ok, ?NEW}, file:read_file(Path)),
        ?assertEqual([<<"manifest">>], entries(Dir))
    end).

%% =============================================================================
%% Failures before the rename never touch the target
%% =============================================================================

datasync_failure_leaves_target_and_removes_tmp_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, "manifest"),
        ok = file:write_file(Path, ?OLD),
        with_io_fault_lock(fun() ->
            meck:expect(bondy_mst_io, datasync, fun(_) -> {error, eio} end),
            ?assertEqual({error, eio}, bondy_log_io:write_atomic(Path, ?NEW)),
            ?assertNot(meck:called(bondy_mst_io, rename, '_'))
        end),
        ?assertEqual({ok, ?OLD}, file:read_file(Path)),
        ?assertEqual([<<"manifest">>], entries(Dir))
    end).

%% =============================================================================
%% A directory fsync that fails after the rename
%% =============================================================================

%% The rename has happened, so neither `ok` nor `{error, _}` would be true:
%% the new content is visible and not known to be durable. It raises, so a
%% caller's rollback does not undo what the renamed file now names.
dir_sync_failure_after_the_rename_raises_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, "manifest"),
        ok = file:write_file(Path, ?OLD),
        with_io_fault_lock(fun() ->
            meck:expect(bondy_mst_io, fsync_dir, fun(_) -> {error, eio} end),
            ?assertError(
                {dir_fsync_failed, Dir, eio},
                bondy_log_io:write_atomic(Path, ?NEW)
            )
        end),
        %% The new content is in place despite the raise.
        ?assertEqual({ok, ?NEW}, file:read_file(Path)),
        ?assertEqual([<<"manifest">>], entries(Dir))
    end).

rename_failure_leaves_target_and_removes_tmp_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, "manifest"),
        ok = file:write_file(Path, ?OLD),
        with_io_fault_lock(fun() ->
            meck:expect(bondy_mst_io, rename, fun(_, _) -> {error, exdev} end),
            ?assertEqual(
                {error, exdev}, bondy_log_io:write_atomic(Path, ?NEW)
            ),
            ?assertNot(meck:called(bondy_mst_io, fsync_dir, '_'))
        end),
        ?assertEqual({ok, ?OLD}, file:read_file(Path)),
        ?assertEqual([<<"manifest">>], entries(Dir))
    end).

open_failure_is_returned_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join([Dir, "missing-subdir", "manifest"]),
        ?assertEqual({error, enoent}, bondy_log_io:write_atomic(Path, ?NEW)),
        ?assertEqual([], entries(Dir))
    end).

%% =============================================================================
%% Crash between the tmp write and the rename
%% =============================================================================

%% Falsifies partial-write visibility: while the writer is parked between
%% datasync and rename the target still reads as the OLD content, and after
%% the writer is killed the target is intact with the stray tmp beside it.
%% The next `write_atomic` then truncates that stray tmp and lands cleanly.
killed_before_rename_test_() ->
    {timeout, 10, fun killed_before_rename/0}.

killed_before_rename() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, "manifest"),
        Tmp = Path ++ ".tmp",
        ok = file:write_file(Path, ?OLD),
        Self = self(),
        with_io_fault_lock(fun() ->
            meck:expect(bondy_mst_io, rename, fun(From, To) ->
                Self ! {parked, self(), From, To},
                receive
                    never -> ok
                end
            end),
            Writer = spawn(fun() -> bondy_log_io:write_atomic(Path, ?NEW) end),
            receive
                {parked, Writer, From, To} ->
                    ?assertEqual({Tmp, Path}, {From, To})
            after 5000 ->
                error(writer_never_reached_rename)
            end,
            %% Parked after datasync, before rename: the tmp carries the
            %% new bytes, the target still the old ones.
            ?assertEqual({ok, ?NEW}, file:read_file(Tmp)),
            ?assertEqual({ok, ?OLD}, file:read_file(Path)),
            Mon = monitor(process, Writer),
            exit(Writer, kill),
            receive
                {'DOWN', Mon, process, Writer, killed} -> ok
            after 5000 ->
                error(writer_not_killed)
            end
        end),
        %% The crash left the stray tmp and the intact target.
        ?assertEqual({ok, ?OLD}, file:read_file(Path)),
        ?assertEqual([<<"manifest">>, <<"manifest.tmp">>], entries(Dir)),
        %% The next write consumes the stray tmp.
        ?assertEqual(ok, bondy_log_io:write_atomic(Path, <<"third">>)),
        ?assertEqual({ok, <<"third">>}, file:read_file(Path)),
        ?assertEqual([<<"manifest">>], entries(Dir))
    end).

%% =============================================================================
%% Helpers
%% =============================================================================

with_dir(Fun) ->
    Dir = lists:flatten(
        io_lib:format(
            "/tmp/bondy_log_io_test_~p_~p",
            [erlang:system_time(microsecond), erlang:unique_integer([positive])]
        )
    ),
    ok = filelib:ensure_path(Dir),
    try
        Fun(Dir)
    after
        _ = file:del_dir_r(Dir)
    end.

entries(Dir) ->
    {ok, Names} = file:list_dir(Dir),
    lists:sort([unicode:characters_to_binary(N) || N <- Names]).

%% Same lock as `bondy_oplog_wal_proper_test:with_io_fault_lock/1`: the
%% suites that mock `bondy_mst_io` serialise on it so a passthrough mock
%% installed here never shadows another suite's expectations.
with_io_fault_lock(Body) ->
    Lock = {meck_vm_lock, bondy_mst_io},
    global:trans(
        {Lock, self()},
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
