%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_log_io).

-moduledoc """
The atomic whole-file write used for every small metadata file in the
storage stack: the WAL manifest, the sparse index, the consumer offset,
the snapshot watermark and the compaction checkpoint.

`write_atomic/2,3` performs the four-step sequence

1. write the complete content to a temporary file next to the target,
2. `bondy_mst_io:datasync/1` that file,
3. `bondy_mst_io:rename/2` it over the target — POSIX renames a path
   atomically, so a reader sees either the old file or the new one,
4. `bondy_mst_io:fsync_dir/1` the enclosing directory so the new
   directory entry is durable (see `bondy_mst_io` for the platform
   notes on that step).

Any failure before the rename leaves the target untouched; the
temporary file is deleted and the error returned. A crash between the
write and the rename leaves the temporary file behind: the next
`write_atomic` to the same target truncates and reuses it, and
directory scanners that enumerate `.tmp` files remove strays on open.
`bondy_log_io_test` exercises the failure and the crash interleavings
against the target's content.

All three I/O seams go through `bondy_mst_io` so fault-injecting tests
have one module to mock (hold its global lock while doing so — see the
`bondy_mst_io` documentation).
""".

-type opts() :: #{tmp_path => file:filename_all()}.

-export_type([opts/0]).

-export([write_atomic/2]).
-export([write_atomic/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Equivalent to `write_atomic(Path, IoData, #{})`: the temporary file is
`<Path>.tmp`.
""".
-spec write_atomic(file:filename_all(), iodata()) -> ok | {error, term()}.

write_atomic(Path, IoData) ->
    write_atomic(Path, IoData, #{}).

-doc """
Atomically replaces the content of `Path` with `IoData`.

Options:

- `tmp_path` — the temporary file to stage the content in. Defaults
  to `<Path>.tmp`. It must live on the same filesystem as `Path`
  (rename does not cross filesystems); callers whose on-disk layout
  names the temporary file explicitly pass it here so the scanner
  that cleans strays and the writer agree on the name by
  construction.

Returns `ok` once the rename and the directory fsync have completed,
or `{error, Reason}` from the first failing step, in which case
`Path` still holds its previous content (or is still absent) and the
temporary file has been deleted. A failing directory fsync is reported
as `{dir_fsync_failed, Dir, Reason}`: the content is renamed into place
but the directory entry is not durable, which a caller that confirms a
checkpoint must tell apart from a failure that wrote nothing.
""".
-spec write_atomic(file:filename_all(), iodata(), opts()) ->
    ok | {error, term()}.

write_atomic(Path, IoData, Opts) when is_map(Opts) ->
    TmpPath = maps:get(tmp_path, Opts, default_tmp_path(Path)),
    case write_and_sync(TmpPath, IoData) of
        ok ->
            case bondy_mst_io:rename(TmpPath, Path) of
                ok ->
                    fsync_dir(filename:dirname(Path));
                {error, _} = E ->
                    _ = prim_file:delete(TmpPath),
                    E
            end;
        {error, _} = E ->
            _ = prim_file:delete(TmpPath),
            E
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Open raw, write, datasync, close. The fd is closed even when the
%% write or the datasync fails so the caller's tmp delete can proceed.
write_and_sync(TmpPath, IoData) ->
    case prim_file:open(TmpPath, [write, raw, binary]) of
        {ok, Fd} ->
            try
                case prim_file:write(Fd, IoData) of
                    ok ->
                        bondy_mst_io:datasync(Fd);
                    {error, _} = E ->
                        E
                end
            after
                _ = prim_file:close(Fd)
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% Tagged so a caller can tell "the bytes are in place but the directory
%% entry is not durable" from a failure that wrote nothing at all.
fsync_dir(Dir) ->
    case bondy_mst_io:fsync_dir(Dir) of
        ok -> ok;
        {error, Reason} -> {error, {dir_fsync_failed, Dir, Reason}}
    end.

%% @private
default_tmp_path(Path) when is_binary(Path) ->
    <<Path/binary, ".tmp">>;
default_tmp_path(Path) when is_list(Path) ->
    Path ++ ".tmp".
