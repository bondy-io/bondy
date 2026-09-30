%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_mst_io_test).

-include_lib("eunit/include/eunit.hrl").

fsync_dir_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun syncs_a_real_directory/1,
        fun a_regular_file_is_not_a_directory/1,
        fun a_missing_directory_is_an_error/1,
        fun a_failed_dir_sync_after_the_rename_raises/1
    ]}.

setup() ->
    Dir = filename:join([
        "/tmp",
        "bondy_mst_io_test_" ++ os:getpid(),
        integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_path(Dir),
    Dir.

cleanup(Dir) ->
    _ = file:del_dir_r(filename:dirname(Dir)),
    ok.

%% The sync must reach an open descriptor of the directory. Observed by call
%% tracing `prim_file`, not by mocking it, so the real open and sync run.
syncs_a_real_directory(Dir) ->
    fun() ->
        Syncs = traced_syncs(fun() -> bondy_mst_io:fsync_dir(Dir) end),
        ?assertEqual(ok, maps:get(result, Syncs)),
        ?assertMatch([_ | _], maps:get(calls, Syncs))
    end.

%% Opening in directory mode is what makes the sync reach a directory, so a
%% regular file is refused rather than synced.
a_regular_file_is_not_a_directory(Dir) ->
    fun() ->
        File = filename:join(Dir, "f"),
        ok = file:write_file(File, <<"x">>),
        ?assertEqual({error, enotdir}, bondy_mst_io:fsync_dir(File))
    end.

a_missing_directory_is_an_error(Dir) ->
    fun() ->
        Missing = filename:join(Dir, "missing"),
        ?assertEqual({error, enoent}, bondy_mst_io:fsync_dir(Missing))
    end.

%% The rename has happened, so no return value would be true: the new file is
%% visible and not known to be durable.
a_failed_dir_sync_after_the_rename_raises(Dir) ->
    fun() ->
        Path = filename:join(Dir, "f"),
        ok = file:write_file(Path, <<"old">>),
        with_io_fault_lock(fun() ->
            ok = meck:expect(bondy_mst_io, fsync_dir, fun(_) -> {error, eio} end),
            ?assertError(
                {dir_fsync_failed, Dir, eio},
                bondy_mst_io:write_file_atomic(Path, <<"new">>)
            )
        end),
        ?assertEqual({ok, <<"new">>}, file:read_file(Path))
    end.

traced_syncs(Fun) ->
    Self = self(),
    Pid = spawn(fun() ->
        receive
            go -> Self ! {done, self(), Fun()}
        end
    end),
    _ = erlang:trace_pattern({prim_file, sync, 1}, true, [global]),
    _ = erlang:trace_pattern({prim_file, datasync, 1}, true, [global]),
    1 = erlang:trace(Pid, true, [call]),
    try
        Pid ! go,
        Result =
            receive
                {done, Pid, R} -> R
            after 5000 -> error(timeout)
            end,
        #{result => Result, calls => drain_traces(Pid)}
    after
        _ = erlang:trace_pattern({prim_file, sync, 1}, false, [global]),
        _ = erlang:trace_pattern({prim_file, datasync, 1}, false, [global])
    end.

drain_traces(Pid) ->
    receive
        {trace, Pid, call, {prim_file, F, _}} -> [F | drain_traces(Pid)]
    after 100 -> []
    end.

%% The node-wide lock every suite that mocks `bondy_mst_io` takes.
with_io_fault_lock(Body) ->
    global:trans(
        {{meck_vm_lock, bondy_mst_io}, self()},
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
