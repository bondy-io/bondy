%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_pack_seal).

-include("bondy_mst.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Sealed-pack write pipeline.

Owns the `pack-NNNN.pack` + `.idx` write + rename + manifest-commit
sequence that turns either an `incoming.pack` (the writer's seal
path) or a list of surviving hashes (the store's GC compaction path)
into a numbered sealed pack on disk.

Extracted from `bondy_mst_pack_writer` so the seal flow lives apart
from the writer's mutable state. The writer still owns the staged
root, the in-memory pending map, and the orchestration glue around
`do_seal/1`; this module owns the bytes-on-disk half — anything that
takes `(Dir, IH, HashAlgo, PackId, Hashes, Reader)` and turns it
into durable files.

See the pack-store design notes §3 (pack format) and
§5 (seal flow).

## Public entry points

- `create_sealed_pack/6` — streams the sealed `.pack` + `.idx` pair
  from a `(Hashes, Reader)` source. The writer's `seal/1` uses this
  with a closure over the pending map; the store's `gc/2` uses it
  with a closure over the existing sealed views.
- `commit_manifest/3` — atomic manifest swap that finalises a seal
  (adds the new pack id, clears `incoming_pack`). The writer calls
  this from `commit_seal/4` after the sealed pair is on disk; the
  store's GC has its own manifest-commit flow because it also
  retires old packs in the same swap.
- `delete_sealed_pack_files/2` — idempotent on-disk delete of a
  retired sealed pack, used by GC after the manifest swap.

## What lives where

```
writer (state-owning)            seal (stateless pipeline)
-----------------------          -----------------------------
seal/1, do_seal/1                create_sealed_pack/6
pending_reader/2                  ├─ stream_sealed_pack/6
commit_seal/4   ─────────────┐    ├─ write_sealed_idx_from_entries/3
close_and_unlink_incoming/2  │    └─ rename_sealed_pair/2
reopen_fresh_incoming/3      │
                             └──► commit_manifest/3
```

## Crash safety

The pipeline preserves the §5 ordering:

1. Stream record bodies into `pack-NNNN.pack.tmp`, accumulating the
   running sha256 in a `crypto:hash_init/1` context — peak RAM is
   one record body.
2. `datasync` the tmp pack file, then build + write `.idx.tmp`.
3. Rename both tmp files into final names; fsync the directory.
4. Manifest swap (caller's `commit_manifest/3` or store's own GC
   commit) — this is the linearisation point.

A crash before step 4 leaves orphan `*.tmp` or `pack-NNNN.*` files
that the writer's orphan scanner deletes on next open. A crash after
step 4 leaves a stale `incoming.pack` that the writer also reconciles
on next open.
""").

-export([create_sealed_pack/6]).
-export([commit_manifest/3]).
-export([delete_sealed_pack_files/2]).

-export_type([reader/0]).
-export_type([create_error/0]).
-export_type([commit_error/0]).

-type reader() :: fun((binary()) -> {ok, binary()} | {error, term()}).

-type create_error() ::
    {idx_build, bondy_mst_pack_index:build_error()}
    | {rename_pack, term()}
    | {rename_idx, term()}
    | term().

-type commit_error() :: {manifest, term()}.

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Streams a new sealed `pack-NNNN.pack` + `.idx` pair from `Hashes`
(sorted ascending, no duplicates) and a `Reader` function that
returns the body bytes for each hash on demand.

For each hash the writer pread's the body via `Reader`, encodes the
record, writes it to the tmp pack file, and folds it into a running
sha256 context — so peak RAM is one record body, not the full pack.
After the last record the running sha256 becomes the pack's trailer.
The `.idx` is built from the offsets accumulated during the stream
(small — 32-byte hash + 8-byte offset per entry).

Performs the full pipeline: tmp write, datasync, rename, dir fsync,
with tmp cleanup on any failure. Does NOT touch the manifest or
`incoming.pack` — those are the caller's concern (the writer's own
`seal/1` does the manifest swap; the store's `gc/2` does its own
atomic swap).

A `Reader` failure for any hash aborts the stream and surfaces as
`{error, _}`; the tmp files are cleaned up.
""").
-spec create_sealed_pack(
    Dir :: file:filename_all(),
    InstanceHash :: non_neg_integer(),
    HashAlgo :: atom(),
    PackId :: pos_integer(),
    Hashes :: [binary()],
    Reader :: reader()
) -> ok | {error, create_error()}.

create_sealed_pack(Dir, InstanceHash, HashAlgo, PackId, Hashes, Reader) ->
    case
        stream_sealed_pack(
            Dir,
            InstanceHash,
            HashAlgo,
            PackId,
            Hashes,
            Reader
        )
    of
        {ok, Entries} ->
            case write_sealed_idx_from_entries(Dir, PackId, Entries) of
                ok ->
                    case rename_sealed_pair(Dir, PackId) of
                        ok ->
                            ok;
                        {error, _} = E ->
                            cleanup_tmp(Dir, PackId),
                            E
                    end;
                {error, R} ->
                    cleanup_tmp(Dir, PackId),
                    {error, R}
            end;
        {error, R} ->
            cleanup_tmp(Dir, PackId),
            {error, R}
    end.

?DOC("""
Atomic manifest swap that finalises a seal: adds `PackId` to
`sealed_packs` and clears `incoming_pack`. Returns the updated
manifest on success.

The caller is expected to have already produced `pack-NNNN.pack` +
`.idx` on disk via `create_sealed_pack/6`. The manifest write is the
linearisation point: pre-write the seal is invisible; post-write the
sealed pack is durable and the incoming pack is reclaimable.

Note that the store's `gc/2` does NOT call this — GC retires old
packs in the same swap and so writes its own composite manifest.
""").
-spec commit_manifest(
    file:filename_all(),
    bondy_mst_pack_manifest:t(),
    pos_integer()
) ->
    {ok, bondy_mst_pack_manifest:t()} | {error, commit_error()}.

commit_manifest(Dir, M, PackId) ->
    M1 = bondy_mst_pack_manifest:with_incoming_pack(
        bondy_mst_pack_manifest:add_sealed_pack(M, PackId),
        absent
    ),
    case bondy_mst_pack_manifest:write(Dir, M1) of
        ok -> {ok, M1};
        {error, R} -> {error, {manifest, R}}
    end.

?DOC("""
Deletes the on-disk `pack-NNNN.pack` and `pack-NNNN.idx` for a
retired sealed pack. Missing files are tolerated (idempotent — safe
to call on a half-rolled-back compaction).
""").
-spec delete_sealed_pack_files(file:filename_all(), non_neg_integer()) -> ok.

delete_sealed_pack_files(Dir, PackId) ->
    _ = prim_file:delete(bondy_mst_pack_paths:sealed_pack_path(Dir, PackId)),
    _ = prim_file:delete(bondy_mst_pack_paths:sealed_idx_path(Dir, PackId)),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Streams the sealed pack to disk one record at a time, accumulating
%% the running sha256 in a `crypto:hash_init/1` context. Returns
%% `{ok, Entries}` (the `.idx` entries built inline) on success.
stream_sealed_pack(Dir, IH, HashAlgo, PackId, Hashes, Reader) ->
    TmpPath = bondy_mst_pack_paths:sealed_pack_tmp_path(Dir, PackId),
    Header = bondy_mst_pack_codec:encode_pack_header(#{
        version => bondy_mst_pack_codec:version(),
        flags => 0,
        pack_id => PackId,
        instance_hash => IH,
        hash_algo => HashAlgo,
        created_at => erlang:system_time(millisecond),
        record_count => length(Hashes)
    }),
    case prim_file:open(TmpPath, [write, raw, binary, exclusive]) of
        {ok, Fd} ->
            try
                stream_sealed_pack_body(Fd, Header, Hashes, Reader)
            after
                _ = prim_file:close(Fd)
            end;
        {error, _} = E ->
            E
    end.

%% @private
stream_sealed_pack_body(Fd, Header, Hashes, Reader) ->
    case prim_file:write(Fd, Header) of
        ok ->
            Ctx = crypto:hash_update(crypto:hash_init(sha256), Header),
            stream_records(Fd, Ctx, byte_size(Header), Hashes, Reader, []);
        {error, _} = E ->
            E
    end.

%% @private
stream_records(Fd, Ctx, _Off, [], _Reader, Acc) ->
    Trailer = crypto:hash_final(Ctx),
    case prim_file:write(Fd, Trailer) of
        ok ->
            case bondy_mst_io:datasync(Fd) of
                ok -> {ok, lists:reverse(Acc)};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end;
stream_records(Fd, Ctx, Off, [Hash | Rest], Reader, Acc) ->
    case Reader(Hash) of
        {ok, Body} when is_binary(Body) ->
            Record = bondy_mst_pack_codec:encode_record(Hash, Body),
            case prim_file:write(Fd, Record) of
                ok ->
                    Ctx1 = crypto:hash_update(Ctx, Record),
                    RecBytes =
                        bondy_mst_pack_codec:record_header_bytes() +
                            byte_size(Body),
                    stream_records(
                        Fd,
                        Ctx1,
                        Off + RecBytes,
                        Rest,
                        Reader,
                        [{Hash, Off} | Acc]
                    );
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% Entries are `[{Hash, Offset}]` already in sort-by-hash order — the
%% stream produced them in that order because the caller passes
%% `Hashes` sorted.
write_sealed_idx_from_entries(Dir, PackId, Entries) ->
    case bondy_mst_pack_index:build(Entries) of
        {ok, IO} ->
            write_sealed_idx_bin(Dir, PackId, iolist_to_binary(IO));
        {error, Reason} ->
            {error, {idx_build, Reason}}
    end.

%% @private
write_sealed_idx_bin(Dir, PackId, Bin) ->
    TmpPath = bondy_mst_pack_paths:sealed_idx_tmp_path(Dir, PackId),
    case prim_file:open(TmpPath, [write, raw, binary, exclusive]) of
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
rename_sealed_pair(Dir, PackId) ->
    PackTmp = bondy_mst_pack_paths:sealed_pack_tmp_path(Dir, PackId),
    Pack = bondy_mst_pack_paths:sealed_pack_path(Dir, PackId),
    IdxTmp = bondy_mst_pack_paths:sealed_idx_tmp_path(Dir, PackId),
    Idx = bondy_mst_pack_paths:sealed_idx_path(Dir, PackId),
    case bondy_mst_io:rename(PackTmp, Pack) of
        ok ->
            case bondy_mst_io:rename(IdxTmp, Idx) of
                ok ->
                    _ = bondy_mst_io:fsync_dir(Dir),
                    ok;
                {error, R} ->
                    _ = prim_file:delete(Pack),
                    {error, {rename_idx, R}}
            end;
        {error, R} ->
            {error, {rename_pack, R}}
    end.

%% @private
cleanup_tmp(Dir, PackId) ->
    _ = prim_file:delete(
        bondy_mst_pack_paths:sealed_pack_tmp_path(Dir, PackId)
    ),
    _ = prim_file:delete(bondy_mst_pack_paths:sealed_idx_tmp_path(Dir, PackId)),
    ok.
