%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_admin).

-include("bondy_mst.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Cold backup and restore for a bondy_mst data tree.

This is the **cold-backup** primitive: it assumes no oplog instance
is currently writing into the source directory. The recommended
sequence is:

```
ok = bondy_oplog:stop_instance(InstanceId),
{ok, Manifest} = bondy_mst_admin:backup(StoragePath, BackupDir),
{ok, _} = bondy_oplog:start_instance(InstanceId, Opts).
```

The library does **not** implement a hot-backup write-barrier —
operators wanting zero-downtime backups use a filesystem-level
snapshot (LVM, ZFS, btrfs, EBS) of `storage_path`, which is then
handed to `backup/3` for the manifest + checksum step.

## What is backed up

The function walks `SourceDir` recursively and copies every regular
file to `BackupDir`, preserving relative paths. The internal layout
(WAL, MST pack-store, compaction checkpoint) is opaque to the backup
tool — it copies the bytes as they sit on disk.

Leveled (the projection store) is **not** in scope. It lives outside
`storage_path`, has its own snapshot primitives, and head-only mode
treats projection loss as "rebuild from peer or backup of leveled's
own data dir" (see the storage architecture notes, §13.5).

## Manifest

The backup root contains `manifest.etf`:

```erlang
{backup_v1, #{
    created_at  := integer(),                          %% microsecond epoch
    source_dir  := binary(),
    file_count  := non_neg_integer(),
    total_bytes := non_neg_integer(),
    files       := [{RelPath :: binary(),
                     Size    :: non_neg_integer(),
                     Sha256  :: binary()}]
}}
```

`verify/1` re-hashes every file and confirms it matches the
manifest. `restore/3` calls `verify/1` first.

## Telemetry

Events emitted on the path `[bondy_mst, admin, ...]`:

| Event | Measurements | Metadata |
|---|---|---|
| `[..., backup, start]` | `#{}` | `#{source, target}` |
| `[..., backup, complete]` | `#{file_count, total_bytes, duration_us}` | `#{source, target}` |
| `[..., backup, failed]` | `#{duration_us}` | `#{source, target, reason}` |
| `[..., verify, start]` | `#{}` | `#{target}` |
| `[..., verify, complete]` | `#{file_count, total_bytes, duration_us}` | `#{target}` |
| `[..., verify, failed]` | `#{duration_us}` | `#{target, reason}` |
| `[..., restore, start]` | `#{}` | `#{source, target}` |
| `[..., restore, complete]` | `#{file_count, total_bytes, duration_us}` | `#{source, target}` |
| `[..., restore, failed]` | `#{duration_us}` | `#{source, target, reason}` |
""").

-export([backup/2]).
-export([backup/3]).
-export([verify/1]).
-export([restore/2]).
-export([restore/3]).

-define(MANIFEST_FILE, "manifest.etf").
-define(MANIFEST_TAG, backup_v1).
-define(HASH_ALGO, sha256).
%% 1 MiB
-define(COPY_CHUNK, 1048576).

-type manifest() :: #{
    created_at := non_neg_integer(),
    source_dir := binary(),
    file_count := non_neg_integer(),
    total_bytes := non_neg_integer(),
    files := [{binary(), non_neg_integer(), binary()}]
}.

-export_type([manifest/0]).

%% =============================================================================
%% API
%% =============================================================================

-spec backup(file:filename_all(), file:filename_all()) ->
    {ok, manifest()} | {error, term()}.

backup(SourceDir, BackupDir) ->
    backup(SourceDir, BackupDir, #{}).

?DOC("""
Copy `SourceDir` into `BackupDir` and write `manifest.etf` recording
every file's size and SHA-256.

`Opts`:
- `allow_nonempty_target` (boolean, default `false`) — when `false`,
  refuses to back up into a non-empty `BackupDir` so a misconfigured
  call cannot trample an unrelated tree.

**The caller is responsible for stopping any oplog instance whose
`storage_path` falls inside `SourceDir`** — a backup taken while the
writer is live would be torn. The recommended cold-backup sequence
is shown at the top of this module.
""").
-spec backup(file:filename_all(), file:filename_all(), map()) ->
    {ok, manifest()} | {error, term()}.

backup(SourceDir, BackupDir, Opts) when is_map(Opts) ->
    Source = to_binary(SourceDir),
    Target = to_binary(BackupDir),
    Start = erlang:monotonic_time(microsecond),
    emit([backup, start], #{}, #{source => Source, target => Target}),
    Result =
        try
            ok = check_source_exists(Source),
            ok = check_target_writable(Target, Opts),
            do_backup(Source, Target)
        catch
            throw:{error, _} = E ->
                E;
            Class:Reason:St ->
                {error, {Class, Reason, St}}
        end,
    DurationUs = erlang:monotonic_time(microsecond) - Start,
    case Result of
        {ok, #{file_count := FC, total_bytes := TB} = Manifest} ->
            emit(
                [backup, complete],
                #{
                    file_count => FC,
                    total_bytes => TB,
                    duration_us => DurationUs
                },
                #{source => Source, target => Target}
            ),
            {ok, Manifest};
        {error, R} ->
            emit(
                [backup, failed],
                #{duration_us => DurationUs},
                #{source => Source, target => Target, reason => R}
            ),
            {error, R}
    end.

?DOC("""
Reads `manifest.etf` from `BackupDir`, then re-hashes every file
listed in the manifest and confirms the hash matches.

Returns `{ok, Manifest}` on success or `{error, Reason}`. Possible
reasons: `{manifest, not_found}`, `{manifest, corrupted}`, `{file,
RelPath, missing}`, `{file, RelPath, size_mismatch}`, `{file,
RelPath, hash_mismatch}`.
""").
-spec verify(file:filename_all()) ->
    {ok, manifest()} | {error, term()}.

verify(BackupDir) ->
    Target = to_binary(BackupDir),
    Start = erlang:monotonic_time(microsecond),
    emit([verify, start], #{}, #{target => Target}),
    Result =
        try
            {ok, Manifest} = read_manifest(Target),
            ok = verify_files(Target, Manifest),
            {ok, Manifest}
        catch
            throw:{error, _} = E -> E
        end,
    DurationUs = erlang:monotonic_time(microsecond) - Start,
    case Result of
        {ok, #{file_count := FC, total_bytes := TB} = M} ->
            emit(
                [verify, complete],
                #{
                    file_count => FC,
                    total_bytes => TB,
                    duration_us => DurationUs
                },
                #{target => Target}
            ),
            {ok, M};
        {error, R} ->
            emit(
                [verify, failed],
                #{duration_us => DurationUs},
                #{target => Target, reason => R}
            ),
            {error, R}
    end.

-spec restore(file:filename_all(), file:filename_all()) ->
    {ok, manifest()} | {error, term()}.

restore(BackupDir, TargetDir) ->
    restore(BackupDir, TargetDir, #{}).

?DOC("""
Verify `BackupDir` (via `verify/1`) and then copy every manifest
entry into `TargetDir`.

`Opts`:
- `allow_nonempty_target` (boolean, default `false`) — refuses to
  restore on top of an existing non-empty target tree unless set.

**The caller is responsible for stopping any oplog instance whose
`storage_path` falls inside `TargetDir`** before calling.
""").
-spec restore(file:filename_all(), file:filename_all(), map()) ->
    {ok, manifest()} | {error, term()}.

restore(BackupDir, TargetDir, Opts) when is_map(Opts) ->
    Source = to_binary(BackupDir),
    Target = to_binary(TargetDir),
    Start = erlang:monotonic_time(microsecond),
    emit([restore, start], #{}, #{source => Source, target => Target}),
    Result =
        try
            {ok, Manifest} = verify(Source),
            ok = check_target_writable(Target, Opts),
            ok = do_restore(Source, Target, Manifest),
            {ok, Manifest}
        catch
            throw:{error, _} = E ->
                E;
            Class:Reason:St ->
                {error, {Class, Reason, St}}
        end,
    DurationUs = erlang:monotonic_time(microsecond) - Start,
    case Result of
        {ok, #{file_count := FC, total_bytes := TB} = M} ->
            emit(
                [restore, complete],
                #{
                    file_count => FC,
                    total_bytes => TB,
                    duration_us => DurationUs
                },
                #{source => Source, target => Target}
            ),
            {ok, M};
        {error, R} ->
            emit(
                [restore, failed],
                #{duration_us => DurationUs},
                #{source => Source, target => Target, reason => R}
            ),
            {error, R}
    end.

%% =============================================================================
%% PRIVATE — pre-checks
%% =============================================================================

%% @private
check_source_exists(Source) ->
    case filelib:is_dir(Source) of
        true -> ok;
        false -> throw({error, {source, enoent, Source}})
    end.

%% @private
check_target_writable(Target, Opts) ->
    AllowNonEmpty = maps:get(allow_nonempty_target, Opts, false),
    case filelib:is_dir(Target) of
        false ->
            case filelib:ensure_path(Target) of
                ok -> ok;
                {error, R} -> throw({error, {target, R, Target}})
            end;
        true when AllowNonEmpty -> ok;
        true ->
            case list_top(Target) of
                {ok, []} -> ok;
                {ok, _} -> throw({error, {target, not_empty, Target}});
                {error, R} -> throw({error, {target, R, Target}})
            end
    end.

%% =============================================================================
%% PRIVATE — backup
%% =============================================================================

%% @private
do_backup(Source, Target) ->
    Files = walk(Source),
    {Entries, TotalBytes} =
        lists:foldl(
            fun(Rel, {Acc, Bytes}) ->
                Src = filename:join(Source, Rel),
                Dst = filename:join(Target, Rel),
                ok = ensure_parent_dir(Dst),
                {Size, Hash} = copy_and_hash(Src, Dst),
                {[{Rel, Size, Hash} | Acc], Bytes + Size}
            end,
            {[], 0},
            Files
        ),
    Manifest = #{
        created_at => erlang:system_time(microsecond),
        source_dir => Source,
        file_count => length(Entries),
        total_bytes => TotalBytes,
        files => lists:reverse(Entries)
    },
    ok = write_manifest(Target, Manifest),
    {ok, Manifest}.

%% @private
%% Recursive walk returning a sorted list of *relative* paths under
%% `Root`. The manifest file itself (if present from a prior backup)
%% is skipped — otherwise re-backups would chain manifests.
walk(Root) ->
    All = filelib:wildcard(
        unicode:characters_to_list(filename:join(Root, "**"))
    ),
    RootList = unicode:characters_to_list(Root),
    Prefix = RootList ++ "/",
    lists:sort([
        list_to_binary(strip_prefix(F, Prefix))
     || F <- All,
        filelib:is_regular(F),
        filename:basename(F) =/= ?MANIFEST_FILE
    ]).

%% @private
strip_prefix(F, Prefix) ->
    case lists:prefix(Prefix, F) of
        true -> lists:nthtail(length(Prefix), F);
        false -> F
    end.

%% @private
%% Stream a file through a SHA-256 context while writing the copy.
%% Returns {Size, HashHex}. Reads in 1 MiB chunks so a multi-GB
%% leveled SST does not pull the whole thing into memory.
copy_and_hash(Src, Dst) ->
    {ok, In} = prim_file:open(Src, [read, raw, binary]),
    try
        {ok, Out} = prim_file:open(Dst, [write, raw, binary]),
        try
            Ctx0 = crypto:hash_init(?HASH_ALGO),
            {Ctx1, Size} = copy_loop(In, Out, Ctx0, 0),
            ok = bondy_mst_io:datasync(Out),
            HashHex = hex(crypto:hash_final(Ctx1)),
            {Size, HashHex}
        after
            _ = prim_file:close(Out)
        end
    after
        _ = prim_file:close(In)
    end.

%% @private
copy_loop(In, Out, Ctx, Acc) ->
    case prim_file:read(In, ?COPY_CHUNK) of
        {ok, Chunk} ->
            ok = prim_file:write(Out, Chunk),
            Ctx1 = crypto:hash_update(Ctx, Chunk),
            copy_loop(In, Out, Ctx1, Acc + byte_size(Chunk));
        eof ->
            {Ctx, Acc};
        {error, R} ->
            throw({error, {read, R}})
    end.

%% =============================================================================
%% PRIVATE — verify
%% =============================================================================

%% @private
verify_files(Target, #{files := Files}) ->
    lists:foreach(
        fun({Rel, Size, Hash}) ->
            Path = filename:join(Target, Rel),
            case filelib:is_regular(Path) of
                false ->
                    throw({error, {file, Rel, missing}});
                true ->
                    ActualSize = filelib:file_size(Path),
                    case ActualSize of
                        Size -> ok;
                        _ -> throw({error, {file, Rel, size_mismatch}})
                    end,
                    case hash_file(Path) of
                        Hash -> ok;
                        _ -> throw({error, {file, Rel, hash_mismatch}})
                    end
            end
        end,
        Files
    ).

%% @private
hash_file(Path) ->
    {ok, Fd} = prim_file:open(Path, [read, raw, binary]),
    try
        hash_loop(Fd, crypto:hash_init(?HASH_ALGO))
    after
        _ = prim_file:close(Fd)
    end.

%% @private
hash_loop(Fd, Ctx) ->
    case prim_file:read(Fd, ?COPY_CHUNK) of
        {ok, Chunk} -> hash_loop(Fd, crypto:hash_update(Ctx, Chunk));
        eof -> hex(crypto:hash_final(Ctx));
        {error, R} -> throw({error, {read, R}})
    end.

%% =============================================================================
%% PRIVATE — restore
%% =============================================================================

%% @private
%% Manifest has already been verified — files exist with matching
%% hashes in `Source`. Copy each into `Target` with the same relative
%% layout, datasync each file, then fsync the top-level target dir.
do_restore(Source, Target, #{files := Files}) ->
    lists:foreach(
        fun({Rel, _Size, _Hash}) ->
            Src = filename:join(Source, Rel),
            Dst = filename:join(Target, Rel),
            ok = ensure_parent_dir(Dst),
            {_, _} = copy_and_hash(Src, Dst)
        end,
        Files
    ),
    bondy_mst_io:fsync_dir(Target).

%% =============================================================================
%% PRIVATE — manifest I/O
%% =============================================================================

%% @private
%% Atomic write: tmp + datasync + rename + dir-fsync. Mirrors the
%% pattern used by the pack manifest and compaction checkpoint.
write_manifest(Target, Manifest) ->
    Path = manifest_path(Target),
    Tmp = <<Path/binary, ".tmp">>,
    Bin = erlang:term_to_binary(
        {?MANIFEST_TAG, Manifest}, [{minor_version, 2}]
    ),
    case write_and_sync(Tmp, Bin) of
        ok ->
            case bondy_mst_io:rename(Tmp, Path) of
                ok ->
                    bondy_mst_io:fsync_dir(Target);
                {error, _} = E ->
                    _ = prim_file:delete(Tmp),
                    throw(E)
            end;
        {error, _} = E ->
            _ = prim_file:delete(Tmp),
            throw(E)
    end.

%% @private
read_manifest(Target) ->
    Path = manifest_path(Target),
    case file:read_file(Path) of
        {ok, Bin} ->
            try erlang:binary_to_term(Bin) of
                {?MANIFEST_TAG, M} when is_map(M) -> {ok, M};
                Other -> throw({error, {manifest, {unexpected_term, Other}}})
            catch
                error:R -> throw({error, {manifest, {corrupted, R}}})
            end;
        {error, enoent} ->
            throw({error, {manifest, not_found}});
        {error, R} ->
            throw({error, {manifest, R}})
    end.

%% @private
manifest_path(Target) ->
    iolist_to_binary(filename:join(Target, ?MANIFEST_FILE)).

%% @private
write_and_sync(TmpPath, Bin) ->
    case prim_file:open(TmpPath, [write, raw, binary]) of
        {ok, Fd} ->
            try
                case prim_file:write(Fd, Bin) of
                    ok -> bondy_mst_io:datasync(Fd);
                    {error, _} = E -> E
                end
            after
                _ = prim_file:close(Fd)
            end;
        {error, _} = E ->
            E
    end.

%% =============================================================================
%% PRIVATE — small helpers
%% =============================================================================

%% @private
ensure_parent_dir(Path) ->
    Parent = filename:dirname(Path),
    case filelib:ensure_path(Parent) of
        ok -> ok;
        {error, R} -> throw({error, {ensure_dir, Parent, R}})
    end.

%% @private
list_top(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} -> {ok, Entries};
        {error, _} = E -> E
    end.

%% @private
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L).

%% @private
hex(Bin) ->
    <<<<(nibble(N))>> || <<N:4>> <= Bin>>.

%% @private
nibble(N) when N < 10 -> $0 + N;
nibble(N) -> $a + N - 10.

%% @private
emit(Suffix, Measurements, Metadata) ->
    telemetry:execute(
        [bondy_mst, admin | Suffix], Measurements, Metadata
    ).
