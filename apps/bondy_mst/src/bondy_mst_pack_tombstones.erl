%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_pack_tombstones).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mst.hrl").
-include("bondy_mst_pack.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-instance tombstone file for the MST pack-store backend.

A tombstone is a hash whose page bytes still exist on disk in a
sealed pack but which the store has logically deleted via
`bondy_mst_store:delete/2` or freed via `free/3`. The next
compaction (`bondy_mst_pack_store:gc/2`) drops applied
tombstones from the rewritten pack and prunes the in-memory set.

Without on-disk persistence the set would evaporate at close, and
a reopen would re-expose deleted pages — diverging from the
sibling backends (`bondy_mst_map_store`, `bondy_mst_ets_store`)
that delete in place.

## On-disk layout (v1)

```
Header (16 bytes):
   0     4    Magic           0x42445453 ("BDTS")
   4     1    Version         = 1
   5     3    Reserved
   8     4    Count           number of hash entries
  12     4    HashLen         hash length in bytes (32)

Body:
  Count × HashLen bytes (hashes, in any order — set membership is
  the only access pattern).

Trailer (32 bytes):
  sha256 over header + body. Symmetric to `.pack` and `.idx`
  trailers — a single-bit flip surfaces as `{error,
  integrity_mismatch}` on read.
```

## Durability sequence

`write/2` mirrors the manifest's tmp-write + datasync + rename +
fsync-dir sequence:

1. Encode the set to the binary form above.
2. Write to `tombstones.tmp`, datasync the fd, close.
3. `bondy_mst_io:rename("tombstones.tmp", "tombstones")` —
   atomic.
4. `bondy_mst_io:fsync_dir/1` so the dirent change is
   durable.

Failure at any step leaves the prior on-disk tombstones intact
and removes the tmp file.

## Recovery

`read/1` validates magic, version, count vs. body length, and
the sha256 trailer. Any structural error is reported as a typed
`{error, _}`; the caller decides whether to surface (e.g.,
recovery) or fall back to an empty set (e.g., open in lenient
mode).
""").

-export([path/1]).
-export([tmp_path/1]).
-export([read/1]).
-export([write/2]).
-export([delete/1]).
-export([encode/1]).
-export([decode/1]).

-type read_error() ::
    enoent
    | truncated_header
    | truncated_trailer
    | bad_magic
    | {bad_version, non_neg_integer()}
    | {bad_hash_len, non_neg_integer()}
    | {bad_count, non_neg_integer()}
    | integrity_mismatch
    | term().

-export_type([read_error/0]).

-define(MAGIC, ?BONDY_MST_PACK_TOMBSTONES_MAGIC).
-define(VERSION, ?BONDY_MST_PACK_TOMBSTONES_VERSION).
-define(HEADER_BYTES, ?BONDY_MST_PACK_TOMBSTONES_HEADER_BYTES).
-define(TRAILER_BYTES, ?BONDY_MST_PACK_TOMBSTONES_TRAILER_BYTES).
-define(HASH_LEN, ?BONDY_MST_PACK_HASH_BYTES).

%% =============================================================================
%% API — paths
%% =============================================================================

-spec path(file:filename_all()) -> file:filename_all().
path(Dir) ->
    filename:join(Dir, ?BONDY_MST_PACK_TOMBSTONES_FILENAME).

-spec tmp_path(file:filename_all()) -> file:filename_all().
tmp_path(Dir) ->
    filename:join(Dir, ?BONDY_MST_PACK_TOMBSTONES_TMP_FILENAME).

%% =============================================================================
%% API — read / write
%% =============================================================================

?DOC("""
Reads and decodes the tombstones file at `Dir`.

Returns:

- `{ok, Set}` — `sets:set/0` (v2) of binary hashes.
- `{error, enoent}` — file does not exist; treat as empty set.
- `{error, Reason}` — structural decode error.
""").
-spec read(Dir :: file:filename_all()) ->
    {ok, sets:set(binary())} | {error, read_error()}.

read(Dir) ->
    Path = path(Dir),
    case file:read_file(Path) of
        {ok, Bin} ->
            decode(Bin);
        {error, _} = E ->
            E
    end.

?DOC("""
Atomically writes `Set` (a `sets:set/0`) to `Dir`.

Returns `ok` on success, `{error, Reason}` on any I/O failure.
On error the prior on-disk file is intact and the tmp file is
removed.
""").
-spec write(Dir :: file:filename_all(), sets:set(binary())) ->
    ok | {error, term()}.

write(Dir, Set) ->
    TmpPath = tmp_path(Dir),
    FinalPath = path(Dir),
    Bin = encode(Set),
    case write_and_sync(TmpPath, Bin) of
        ok ->
            case bondy_mst_io:rename(TmpPath, FinalPath) of
                ok ->
                    bondy_mst_io:fsync_dir(Dir);
                {error, _} = E ->
                    _ = prim_file:delete(TmpPath),
                    E
            end;
        {error, _} = E ->
            _ = prim_file:delete(TmpPath),
            E
    end.

?DOC("""
Removes the tombstones file from `Dir`. Idempotent — a missing
file is not an error.
""").
-spec delete(file:filename_all()) -> ok | {error, term()}.

delete(Dir) ->
    case prim_file:delete(path(Dir)) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} = E -> E
    end.

%% =============================================================================
%% API — pure codec
%% =============================================================================

?DOC("""
Encodes a tombstone set to its on-disk binary form. Pure;
useful for tests and for callers that want to inspect the
proposed bytes before committing.
""").
-spec encode(sets:set(binary())) -> binary().

encode(Set) ->
    Hashes = sets:to_list(Set),
    Count = length(Hashes),
    Header = <<
        ?MAGIC:32/big-unsigned,
        ?VERSION:8,
        0:24,
        Count:32/big-unsigned,
        ?HASH_LEN:32/big-unsigned
    >>,
    Body = <<<<H/binary>> || H <- Hashes, byte_size(H) =:= ?HASH_LEN>>,
    HeaderAndBody = <<Header/binary, Body/binary>>,
    Trailer = crypto:hash(sha256, HeaderAndBody),
    <<HeaderAndBody/binary, Trailer/binary>>.

?DOC("""
Decodes a binary into a tombstone set. Returns the decoded
`sets:set/0` or a typed `{error, _}`.
""").
-spec decode(binary()) -> {ok, sets:set(binary())} | {error, read_error()}.

decode(Bin) when byte_size(Bin) < ?HEADER_BYTES + ?TRAILER_BYTES ->
    case byte_size(Bin) < ?HEADER_BYTES of
        true -> {error, truncated_header};
        false -> {error, truncated_trailer}
    end;
decode(Bin) ->
    BodySize = byte_size(Bin) - ?TRAILER_BYTES,
    <<Body:BodySize/binary, Trailer:?TRAILER_BYTES/binary>> = Bin,
    case crypto:hash(sha256, Body) of
        Trailer ->
            decode_verified(Body);
        _ ->
            {error, integrity_mismatch}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
decode_verified(
    <<?MAGIC:32/big-unsigned, Version:8, _Reserved:24, Count:32/big-unsigned,
        HashLen:32/big-unsigned, Rest/binary>>
) ->
    case Version =:= ?VERSION of
        false ->
            {error, {bad_version, Version}};
        true ->
            case HashLen =:= ?HASH_LEN of
                false ->
                    {error, {bad_hash_len, HashLen}};
                true ->
                    decode_hashes(Count, HashLen, Rest)
            end
    end;
decode_verified(_) ->
    {error, bad_magic}.

%% @private
decode_hashes(Count, HashLen, Body) when byte_size(Body) =:= Count * HashLen ->
    Hashes =
        [
            binary:part(Body, I * HashLen, HashLen)
         || I <- lists:seq(0, Count - 1)
        ],
    {ok, sets:from_list(Hashes, [{version, 2}])};
decode_hashes(Count, _HashLen, _Body) ->
    {error, {bad_count, Count}}.

%% @private
%% Mirror of `bondy_mst_pack_manifest:write_and_sync/2`.
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
