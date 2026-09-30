%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_io).

-include("bondy_mst.hrl").
-include_lib("kernel/include/logger.hrl").

-moduledoc #{format => "text/markdown"}.
-moduledoc """
File durability primitives for the WAL and the MST pack store.

`write/2`, `datasync/1` and `rename/2` each make one `prim_file` call.
`fsync_dir/1` opens, syncs and closes a directory. `write_file_atomic/2` calls
`datasync/1`, `rename/2` and `fsync_dir/1` through their `?MODULE:` names, so a
mock of any of them is seen by it; it writes with `prim_file` directly, so a
mock of `write/2`, which the WAL's frame appends use, is not.

## A directory fsync that fails after a rename

It leaves the new file visible but not known to be durable. No return value
would be true, so `write_file_atomic/2` raises `{dir_fsync_failed, Dir,
Reason}`: a caller whose rollback assumed nothing had changed would undo what
the renamed file now refers to. Two such rollbacks, in the pack store's GC and
in WAL rotation, are pinned by
`gc_manifest_dir_sync_failure_loses_no_page_test` in
`bondy_mst_pack_store_test` and by
`rotation_manifest_dir_sync_failure_keeps_the_log_openable_test` in
`bondy_oplog_wal_durability_test`. A caller catches it and returns it instead
when its crash would stop the node, when it owns state other processes read,
or when the file is one recovery rebuilds.

A crash can therefore leave such a file behind, so a store that trusts files
in a directory fsyncs that directory, with `fsync_dir/1`, before it reads them.

This module exists so that:

1. Platform-specific tightening (macOS `F_FULLFSYNC` via a NIF,
   Linux `io_uring`-based sync, `O_TMPFILE`-based tmp writes,
   etc.) can land in one place rather than being duplicated
   across every persistence layer.
2. Each operation is a single named meck seam so the test suite
   can fault-inject I/O failures at well-defined points. Mocking
   `prim_file` itself is unsafe because `file:write_file/2`,
   `file:open/2`, and the emulator's own I/O flow through it.

Tests that fault-inject these functions must hold the
`?MODULE` global lock (see `with_io_fault_lock/1` in the test
suites) so concurrent test modules don't see each other's mocks.
""".

-export([fsync_dir/1]).
-export([datasync/1]).
-export([write/2]).
-export([rename/2]).
-export([write_file_atomic/2]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Fsyncs directory `Dir`, meant to make a rename into it, or a file created in
it, survive a power loss. On Darwin OTP issues `F_BARRIERFSYNC` rather than a
full flush to the media (`efile_sync` in OTP's `unix_prim_file.c`).

The directory is opened in `directory` mode: without it OTP refuses to open a
directory, with `{error, eisdir}` on every Unix (`efile_open`, same file).
Any error, including a `Dir` that is not a directory, is returned
(`bondy_mst_io_test`); an open error is also logged, once per VM.
""").
-spec fsync_dir(file:filename_all()) -> ok | {error, term()}.

fsync_dir(Dir) ->
    case prim_file:open(Dir, [read, raw, directory]) of
        {ok, DirFd} ->
            Result = prim_file:sync(DirFd),
            _ = prim_file:close(DirFd),
            Result;
        {error, Reason} = E ->
            warn_once(fsync_dir_failed, Dir, Reason),
            E
    end.

?DOC("""
Datasync seam. Every disk-durability point in the project funnels
through here so platform-specific tightening (macOS `F_FULLFSYNC`,
Linux `io_uring`-based sync, etc.) lands in one place and the test
suite has a single named callsite for fault injection.

The wrapper is intentionally thin — production behaviour is
byte-identical to `prim_file:datasync/1`. Test code that fault-injects
this function must hold the `?MODULE` global lock (see
`with_io_fault_lock/1` in the test suites) so concurrent test modules
don't see another suite's mock.
""").
-spec datasync(file:fd()) -> ok | {error, term()}.

datasync(Fd) ->
    prim_file:datasync(Fd).

?DOC("""
Write seam — same rationale as `datasync/1`. The WAL's frame appends
funnel through here, so a test can make a write fail after only part of
its bytes reached the file, as `enospc` can.
""").
-spec write(file:fd(), iodata()) -> ok | {error, term()}.

write(Fd, Bytes) ->
    prim_file:write(Fd, Bytes).

?DOC("""
Rename seam — same rationale as `datasync/1`. Every atomic
rename-into-place in the project (WAL manifest, sparse index,
consumer offset, snapshot watermark; pack manifest, sealed pack
+ idx, tombstones) funnels through here.
""").
-spec rename(file:filename_all(), file:filename_all()) ->
    ok | {error, term()}.

rename(From, To) ->
    prim_file:rename(From, To).

?DOC("""
Replaces the file at `Path` with `Bytes`, meant to leave either the whole old
file or the whole new one after a crash or power loss: writes `<Path>.tmp`,
datasyncs it, renames it over `Path`, then fsyncs the enclosing directory.

Returns `{error, _}` only for a failure before the rename, which leaves the old
file and no temp file. A failed directory fsync raises `{dir_fsync_failed,
Dir, Reason}` (`bondy_mst_io_test`); see the moduledoc.
""").
-spec write_file_atomic(file:filename_all(), iodata()) ->
    ok | {error, term()}.

write_file_atomic(Path, Bytes) ->
    Tmp = unicode:characters_to_list([Path, ".tmp"]),
    case write_synced(Tmp, Bytes) of
        ok ->
            case ?MODULE:rename(Tmp, Path) of
                ok ->
                    Dir = filename:dirname(Path),
                    case ?MODULE:fsync_dir(Dir) of
                        ok ->
                            ok;
                        {error, Reason} ->
                            error({dir_fsync_failed, Dir, Reason})
                    end;
                {error, _} = Err ->
                    _ = prim_file:delete(Tmp),
                    Err
            end;
        {error, _} = Err ->
            _ = prim_file:delete(Tmp),
            Err
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
write_synced(Path, Bytes) ->
    case prim_file:open(Path, [write, raw, binary]) of
        {ok, Fd} ->
            try prim_file:write(Fd, Bytes) of
                ok -> ?MODULE:datasync(Fd);
                {error, _} = Err -> Err
            after
                _ = prim_file:close(Fd)
            end;
        {error, _} = Err ->
            Err
    end.

%% @private
%% Logs a WARNING once per VM lifetime per `Tag`. Used to surface
%% unexpected platform behaviour without flooding the logs.
warn_once(Tag, Dir, Reason) ->
    Key = {?MODULE, warn_once, Tag},
    case persistent_term:get(Key, undefined) of
        undefined ->
            ok = persistent_term:put(Key, true),
            ?LOG_WARNING(#{
                description =>
                    "bondy_mst_io:fsync_dir/1 could not fsync a directory; "
                    "a rename or file creation in it may not survive a "
                    "power loss",
                tag => Tag,
                dir => Dir,
                reason => Reason
            });
        _ ->
            ok
    end.
