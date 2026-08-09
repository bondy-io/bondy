%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_compaction_checkpoint_file).
-behaviour(bondy_oplog_compaction_checkpoint).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
File-backed compaction checkpoint store. Durable, single-checkpoint,
atomic.

One file per instance, holding the latest `{Watermark, Checkpoint}`
as an Erlang External Term Format binary. Writes use the standard
tmp + datasync + atomic-rename + dir-fsync idiom; a partial write or
power failure leaves the previous good file in place, and readers
see either the old checkpoint or the new one, never a partial mix.

## Opts

| Key    | Required | Meaning |
|---|---|---|
| `path` | yes      | Base directory. The instance's checkpoint is stored at `<path>/<InstanceId>/checkpoint.etf`. |

## Durability sequence (`put_checkpoint/3`)

1. Encode `{Watermark, Checkpoint}` as ETF.
2. Open `<dir>/checkpoint.etf.tmp` raw, write the body, datasync the
   fd, close. After this point the data bytes are on disk.
3. `rename(tmp, final)` via `bondy_mst_io:rename/2` — POSIX-atomic.
4. `bondy_mst_io:fsync_dir/1` on the enclosing directory so the
   dirent change is durable. Required on ext4 / xfs.

If any step fails the function returns `{error, Reason}`; the tmp
file is removed and the prior on-disk checkpoint is left intact.

## Corruption detection

`get_checkpoint/1` and `current_watermark/1` wrap the
`binary_to_term/1` call in a `try/catch`: a truncated or otherwise
corrupted file surfaces as `{error, {corrupted, Reason}}` rather
than a silent crash inside the instance gen_server. The instance
init treats this as fatal so the operator can restore from backup
instead of silently rebuilding from a partial state.

## On-disk envelope

The file content is `term_to_binary({checkpoint_v1, Watermark,
Checkpoint}, [{minor_version, 2}])`. The `checkpoint_v1` tag is the
versioning seam for future schema evolution.

## Why not DETS

DETS earns its keep on none of the dimensions that matter for a
single-row checkpoint store: it has no real transactional guarantees,
requires atom-named tables (an atom-table footgun with many
instances), and runs a slow repair pass on dirty restart.
`file:rename/2` is atomic on POSIX by specification, which is all this
store needs.
""").

-record(state, {
    instance_id :: instance_id(),
    dir :: file:filename_all(),
    path :: file:filename_all()
}).

-export([init/2]).
-export([put_checkpoint/3]).
-export([get_checkpoint/1]).
-export([current_watermark/1]).
-export([close/1]).

%% =============================================================================
%% bondy_oplog_compaction_checkpoint CALLBACKS
%% =============================================================================

init(InstanceId, Opts) when is_binary(InstanceId), is_map(Opts) ->
    case maps:find(path, Opts) of
        error ->
            {error, {missing_option, path}};
        {ok, BaseDir} ->
            Dir = filename:join(BaseDir, InstanceId),
            File = filename:join(Dir, "checkpoint.etf"),
            ok = filelib:ensure_dir(File),
            {ok, #state{instance_id = InstanceId, dir = Dir, path = File}}
    end.

put_checkpoint(#state{dir = Dir, path = Path}, Watermark, Checkpoint) ->
    Bin = erlang:term_to_binary(
        {checkpoint_v1, Watermark, Checkpoint},
        [{minor_version, 2}]
    ),
    Tmp = tmp_path(Path),
    case write_and_sync(Tmp, Bin) of
        ok ->
            case bondy_mst_io:rename(Tmp, Path) of
                ok ->
                    bondy_mst_io:fsync_dir(Dir);
                {error, _} = E ->
                    _ = prim_file:delete(Tmp),
                    E
            end;
        {error, _} = E ->
            _ = prim_file:delete(Tmp),
            E
    end.

get_checkpoint(#state{path = Path}) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            decode(Bin);
        {error, enoent} ->
            not_found;
        {error, _} = E ->
            E
    end.

current_watermark(#state{path = Path}) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case decode(Bin) of
                {ok, W, _} -> W;
                not_found -> undefined;
                {error, _} = E -> E
            end;
        {error, enoent} ->
            undefined;
        {error, _} = E ->
            E
    end.

close(#state{}) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Same shape as bondy_mst_pack_manifest:write_and_sync/2: open raw,
%% write, datasync via the shared seam, close. The fd is closed even
%% if write or datasync fails so the tmp delete in the caller can
%% proceed.
write_and_sync(TmpPath, Bin) ->
    case prim_file:open(TmpPath, [write, raw, binary]) of
        {ok, Fd} ->
            try
                case prim_file:write(Fd, Bin) of
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
%% Safe-decode: any crash inside binary_to_term surfaces as
%% `{error, {corrupted, Reason}}` rather than killing the caller.
decode(Bin) ->
    %% `[safe]` (C-2 hygiene): this reads a local checkpoint file, but decoding
    %% with `[safe]` keeps it consistent with the merge decoders and rejects
    %% funs/novel atoms should the file be tampered with; the `try` still maps a
    %% rejection to `{error, {corrupted, _}}`.
    try erlang:binary_to_term(Bin, [safe]) of
        {checkpoint_v1, W, S} ->
            {ok, W, S};
        Other ->
            {error, {corrupted, {unexpected_term, Other}}}
    catch
        error:Reason ->
            {error, {corrupted, Reason}}
    end.

%% @private
tmp_path(Path) when is_list(Path) ->
    Path ++ ".tmp";
tmp_path(Path) when is_binary(Path) ->
    <<Path/binary, ".tmp">>.
