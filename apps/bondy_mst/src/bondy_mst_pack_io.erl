%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_pack_io).

-include("bondy_mst.hrl").
-include("bondy_mst_pack.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Low-level I/O helpers for sealed-pack files, shared by
`bondy_mst_pack_reader` (read-only view) and `bondy_mst_pack_store`
(read-write backend) so they do not drift apart.

The module owns one read primitive — `read_record/3` — and the
private bytes-and-CRC machinery it needs. It is **not** the
abstract sealed-pack reader: it neither tracks fds nor manages
indexes; callers thread an already-opened `#sealed_view{}` in.
""").

-export([read_record/3]).

-type read_error() ::
    {pack_io, non_neg_integer(), term()}
    | {decode, non_neg_integer(), term()}
    | {crc_mismatch, non_neg_integer(), binary()}.

-export_type([read_error/0]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Reads the record at `Offset` from the given sealed view's `.pack`
fd, verifying both the per-record CRC and that the stored hash
matches `Hash`.

Returns:

- `{ok, Body}` on a hit (with a verified body — CRC checked, hash
  agrees with the requested one).
- `not_found` if the record header at the offset names a different
  hash. This can happen when the caller's index lookup was a bloom
  false positive that survived the binary search; the caller falls
  through to the next sealed pack.
- `{error, read_error()}` for any underlying I/O or decode failure,
  surfaced verbatim from the codec.
""").
-spec read_record(
    SealedView :: #sealed_view{},
    Hash :: binary(),
    Offset :: non_neg_integer()
) ->
    {ok, binary()} | not_found | {error, read_error()}.

read_record(#sealed_view{pack_id = PackId, pack_fd = Fd}, Hash, Offset) ->
    HdrBytes = bondy_mst_pack_codec:record_header_bytes(),
    case prim_file:pread(Fd, Offset, HdrBytes) of
        {ok, HBin} when byte_size(HBin) =:= HdrBytes ->
            case bondy_mst_pack_codec:decode_record_header(HBin) of
                {ok, #{hash := H} = Header} when H =:= Hash ->
                    PageLen = maps:get(page_len, Header),
                    read_body(
                        Fd,
                        PackId,
                        Offset + HdrBytes,
                        PageLen,
                        Header,
                        Hash
                    );
                {ok, _} ->
                    %% Header at this offset names a different hash —
                    %% bloom false positive that the binary-search also
                    %% accepted; should not happen on a well-formed .idx.
                    not_found;
                {error, R} ->
                    {error, {decode, PackId, R}}
            end;
        _ ->
            {error, {pack_io, PackId, short_header}}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% `prim_file:pread(_, _, 0)` returns `eof`, so a zero-length page is
%% short-circuited rather than going through the read + size check.
read_body(_Fd, PackId, _BodyOff, 0, Header, Hash) ->
    case bondy_mst_pack_codec:verify_record(Header, <<>>) of
        ok -> {ok, <<>>};
        {error, _} -> {error, {crc_mismatch, PackId, Hash}}
    end;
read_body(Fd, PackId, BodyOff, PageLen, Header, Hash) ->
    case prim_file:pread(Fd, BodyOff, PageLen) of
        {ok, Body} when byte_size(Body) =:= PageLen ->
            case bondy_mst_pack_codec:verify_record(Header, Body) of
                ok -> {ok, Body};
                {error, _} -> {error, {crc_mismatch, PackId, Hash}}
            end;
        _ ->
            {error, {pack_io, PackId, short_body}}
    end.
