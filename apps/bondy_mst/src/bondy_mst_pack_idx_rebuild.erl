%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_pack_idx_rebuild).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mst.hrl").
-include("bondy_mst_pack.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Rebuilds the `pack-NNNN.idx` companion of a sealed `pack-NNNN.pack`
by streaming the pack and re-emitting the index file.

The `.idx` is purely derived state — every `(Hash, Offset)` pair it
records is also encoded inside the corresponding `.pack`. When the
`.idx` is missing, truncated, magic-mismatched, version-bumped,
fanout-corrupted, or the trailing sha256 fails verification, the
opener routes the failure here. The pack itself is treated as
authoritative: header (magic / version / instance_hash / hash_algo)
must validate, every record's CRC must verify, and the pack-level
sha256 trailer must match what the rebuild scan re-derives. Any
failure of those checks is surfaced as `{error, {pack, _}}` — the
sealed pack itself is damaged, beyond what an index rebuild can
fix; the caller raises and the operator deals with it. The pack
store sits beneath a WAL for the *recent* tail (incoming.pack);
sealed packs are the long-term store and a corrupt sealed pack is
genuine data loss that the rebuild path must not silently paper
over.

See the pack-store design notes §10.3.

## Trigger

`bondy_mst_pack_store:open_sealed_view/2` classifies the failing
`.idx` open as rebuildable when the cause is one of:

- `enoent` on `prim_file:read_file/1` (the file is gone).
- Any `bondy_mst_pack_index:open_error()` — `truncated_header`,
  `truncated_trailer`, `bad_magic`, `{bad_version, _}`,
  `{bad_hash_len, _}`, `truncated_fanout`, `truncated_hashes`,
  `truncated_offsets`, `integrity_mismatch`,
  `{fanout_inconsistent, _}`, `{bloom, _}`.

All other file-system errors on the `.idx` (`eacces`, `emfile`,
…) are bubbled up unchanged — they would also fail the rebuild
write, so retrying through here is pointless.

## On-success contract

After `rebuild/4` returns `{ok, _}` the caller invokes
`prim_file:read_file/1` + `bondy_mst_pack_index:open/1` again and
expects them to succeed. The new `.idx` is atomically renamed
into place (tmp+datasync+rename+fsync_dir), so a crash mid-rebuild
either leaves the original (corrupt or missing) `.idx` in place
— in which case the next open re-enters this module — or commits
the new `.idx`.

## Outcome map

```erlang
#{
    records_recovered :: non_neg_integer(),
    pack_bytes        :: non_neg_integer(),
    idx_bytes         :: non_neg_integer()
}
```
""").

-export([rebuild/4]).

-type outcome() :: #{
    records_recovered := non_neg_integer(),
    pack_bytes := non_neg_integer(),
    idx_bytes := non_neg_integer()
}.

-type pack_error() ::
    {open, term()}
    | {stat, term()}
    | {short_header, non_neg_integer()}
    | {header_decode, term()}
    | {instance_mismatch, Got :: non_neg_integer(), Want :: non_neg_integer()}
    | {hash_algo_mismatch, Got :: atom(), Want :: atom()}
    | {short_record_header, non_neg_integer()}
    | {record_header_decode, non_neg_integer(), term()}
    | {short_record_body, non_neg_integer()}
    | {body_read, non_neg_integer(), term()}
    | {record_crc, non_neg_integer(), term()}
    | {short_trailer, non_neg_integer() | term()}
    | trailer_mismatch
    | empty.

-type reason() ::
    {pack, pack_error()}
    | {idx_write, term()}.

-export_type([outcome/0]).
-export_type([reason/0]).

%% =============================================================================
%% API
%% =============================================================================

-spec rebuild(
    Dir :: file:filename_all(),
    PackId :: non_neg_integer(),
    InstanceHash :: non_neg_integer(),
    HashAlgo :: atom()
) -> {ok, outcome()} | {error, reason()}.

rebuild(Dir, PackId, InstanceHash, HashAlgo) when
    is_integer(PackId),
    PackId >= 0,
    is_integer(InstanceHash),
    InstanceHash >= 0,
    is_atom(HashAlgo)
->
    PackPath = bondy_mst_pack_paths:sealed_pack_path(Dir, PackId),
    case scan_pack(PackPath, InstanceHash, HashAlgo) of
        {ok, Entries, PackBytes} ->
            write_idx(Dir, PackId, Entries, PackBytes);
        {error, _} = E ->
            E
    end.

%% =============================================================================
%% PRIVATE — pack scan
%% =============================================================================

scan_pack(PackPath, InstanceHash, HashAlgo) ->
    case prim_file:open(PackPath, [read, raw, binary]) of
        {ok, Fd} ->
            try
                do_scan(Fd, InstanceHash, HashAlgo)
            after
                _ = prim_file:close(Fd)
            end;
        {error, R} ->
            {error, {pack, {open, R}}}
    end.

do_scan(Fd, InstanceHash, HashAlgo) ->
    HeaderBytes = bondy_mst_pack_codec:header_bytes(),
    TrailerBytes = bondy_mst_pack_codec:trailer_bytes(),
    case prim_file:position(Fd, eof) of
        {ok, FileSize} when FileSize < HeaderBytes + TrailerBytes ->
            {error, {pack, empty}};
        {ok, FileSize} ->
            case read_header(Fd, HeaderBytes, InstanceHash, HashAlgo) of
                {ok, HBin} ->
                    Ctx0 = crypto:hash_update(crypto:hash_init(sha256), HBin),
                    BodyEnd = FileSize - TrailerBytes,
                    scan_records(
                        Fd,
                        HeaderBytes,
                        BodyEnd,
                        Ctx0,
                        [],
                        0,
                        FileSize,
                        TrailerBytes
                    );
                {error, _} = E ->
                    E
            end;
        {error, R} ->
            {error, {pack, {stat, R}}}
    end.

read_header(Fd, HeaderBytes, InstanceHash, HashAlgo) ->
    case prim_file:pread(Fd, 0, HeaderBytes) of
        {ok, HBin} when byte_size(HBin) =:= HeaderBytes ->
            case bondy_mst_pack_codec:decode_pack_header(HBin) of
                {ok, #{instance_hash := IH}} when IH =/= InstanceHash ->
                    {error, {pack, {instance_mismatch, IH, InstanceHash}}};
                {ok, #{hash_algo := A}} when A =/= HashAlgo ->
                    {error, {pack, {hash_algo_mismatch, A, HashAlgo}}};
                {ok, _} ->
                    {ok, HBin};
                {error, R} ->
                    {error, {pack, {header_decode, R}}}
            end;
        {ok, Short} ->
            {error, {pack, {short_header, byte_size(Short)}}};
        eof ->
            {error, {pack, {short_header, 0}}};
        {error, R} ->
            {error, {pack, {header_decode, R}}}
    end.

scan_records(
    Fd, Offset, BodyEnd, Ctx, Acc, RecCount, FileSize, TrailerBytes
) when
    Offset =:= BodyEnd
->
    finalise(Fd, Ctx, Acc, RecCount, FileSize, TrailerBytes);
scan_records(
    _Fd,
    Offset,
    BodyEnd,
    _Ctx,
    _Acc,
    _RecCount,
    _FileSize,
    _TrailerBytes
) when
    Offset > BodyEnd
->
    %% Last record's body advanced us past `BodyEnd`: the trailing
    %% bytes don't form a complete record framed by the trailer.
    {error, {pack, {short_record_body, BodyEnd - Offset}}};
scan_records(Fd, Offset, BodyEnd, Ctx, Acc, RecCount, FileSize, TrailerBytes) ->
    HdrBytes = bondy_mst_pack_codec:record_header_bytes(),
    case prim_file:pread(Fd, Offset, HdrBytes) of
        {ok, HBin} when byte_size(HBin) =:= HdrBytes ->
            case bondy_mst_pack_codec:decode_record_header(HBin) of
                {ok, #{hash := Hash, page_len := PageLen} = Header} ->
                    BodyOffset = Offset + HdrBytes,
                    case
                        read_and_verify_body(Fd, BodyOffset, PageLen, Header)
                    of
                        {ok, Body} ->
                            Ctx1 = crypto:hash_update(Ctx, HBin),
                            Ctx2 = crypto:hash_update(Ctx1, Body),
                            scan_records(
                                Fd,
                                BodyOffset + PageLen,
                                BodyEnd,
                                Ctx2,
                                [{Hash, Offset} | Acc],
                                RecCount + 1,
                                FileSize,
                                TrailerBytes
                            );
                        {error, _} = E ->
                            E
                    end;
                {error, R} ->
                    {error, {pack, {record_header_decode, Offset, R}}}
            end;
        {ok, Short} ->
            {error, {pack, {short_record_header, byte_size(Short)}}};
        eof ->
            {error, {pack, {short_record_header, 0}}};
        {error, R} ->
            {error, {pack, {record_header_decode, Offset, R}}}
    end.

read_and_verify_body(_Fd, _BodyOffset, 0, Header) ->
    case bondy_mst_pack_codec:verify_record(Header, <<>>) of
        ok -> {ok, <<>>};
        {error, R} -> {error, {pack, {record_crc, 0, R}}}
    end;
read_and_verify_body(Fd, BodyOffset, PageLen, Header) ->
    case prim_file:pread(Fd, BodyOffset, PageLen) of
        {ok, Body} when byte_size(Body) =:= PageLen ->
            case bondy_mst_pack_codec:verify_record(Header, Body) of
                ok -> {ok, Body};
                {error, R} -> {error, {pack, {record_crc, BodyOffset, R}}}
            end;
        {ok, Short} ->
            {error, {pack, {short_record_body, byte_size(Short)}}};
        eof ->
            {error, {pack, {short_record_body, 0}}};
        {error, R} ->
            {error, {pack, {body_read, BodyOffset, R}}}
    end.

finalise(Fd, Ctx, Acc, _RecCount, FileSize, TrailerBytes) ->
    Computed = crypto:hash_final(Ctx),
    TrailerOffset = FileSize - TrailerBytes,
    case prim_file:pread(Fd, TrailerOffset, TrailerBytes) of
        {ok, Trailer} when byte_size(Trailer) =:= TrailerBytes ->
            case Trailer of
                Computed ->
                    {ok, lists:reverse(Acc), FileSize};
                _ ->
                    {error, {pack, trailer_mismatch}}
            end;
        {ok, Short} ->
            {error, {pack, {short_trailer, byte_size(Short)}}};
        eof ->
            {error, {pack, {short_trailer, 0}}};
        {error, R} ->
            {error, {pack, {short_trailer, R}}}
    end.

%% =============================================================================
%% PRIVATE — idx write
%% =============================================================================

write_idx(Dir, PackId, Entries, PackBytes) ->
    case bondy_mst_pack_index:build(Entries) of
        {ok, IoData} ->
            Bin = iolist_to_binary(IoData),
            case write_and_install(Dir, PackId, Bin) of
                ok ->
                    log_action(
                        rebuilt,
                        #{
                            dir => Dir,
                            pack_id => PackId,
                            idx_bytes => byte_size(Bin),
                            records => length(Entries)
                        }
                    ),
                    {ok, #{
                        records_recovered => length(Entries),
                        pack_bytes => PackBytes,
                        idx_bytes => byte_size(Bin)
                    }};
                {error, R} ->
                    {error, {idx_write, R}}
            end;
        {error, R} ->
            {error, {idx_write, {idx_build, R}}}
    end.

write_and_install(Dir, PackId, Bin) ->
    TmpPath = bondy_mst_pack_paths:sealed_idx_tmp_path(Dir, PackId),
    FinalPath = bondy_mst_pack_paths:sealed_idx_path(Dir, PackId),
    _ = prim_file:delete(TmpPath),
    case prim_file:open(TmpPath, [write, raw, binary, exclusive]) of
        {ok, Fd} ->
            Res = write_and_sync(Fd, Bin),
            _ = prim_file:close(Fd),
            case Res of
                ok ->
                    case bondy_mst_io:rename(TmpPath, FinalPath) of
                        ok ->
                            _ = bondy_mst_io:fsync_dir(Dir),
                            ok;
                        {error, _} = E ->
                            _ = prim_file:delete(TmpPath),
                            E
                    end;
                {error, _} = E ->
                    _ = prim_file:delete(TmpPath),
                    E
            end;
        {error, _} = E ->
            E
    end.

write_and_sync(Fd, Bin) ->
    case prim_file:write(Fd, Bin) of
        ok ->
            bondy_mst_io:datasync(Fd);
        {error, _} = E ->
            E
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

log_action(Action, Ctx) ->
    ?LOG_NOTICE(Ctx#{
        event => mst_pack_idx_rebuild_action,
        action => Action
    }).
