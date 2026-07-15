%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_pack_codec).

-include("bondy_mst.hrl").
-include("bondy_mst_pack.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Pure pack-file codec for the MST page-store backend.

Owns the on-disk wire format described in
the pack-store design notes §3 — the 48-byte pack
header, the per-record envelope (`Hash` + `PageLen` + `PageCrc32`
+ Page bytes), and the 32-byte sha256 trailer that seals an
immutable pack. No file I/O; callers (`bondy_mst_pack_store`) own
the file handle and supply bytes.

## Why a pure codec module

A pack file is a content-addressed log of MST pages: sealed,
immutable, sorted-by-hash. Both the writer (sealing an incoming
pack into a numbered one) and the reader (random-access lookup
of an already-sealed pack) need to read and write the same byte
layout. Keeping the bytewise encode/decode in this module lets
tests poke the wire format directly with binaries, and lets
PropEr round-trip arbitrary records / headers without spinning
up a store.

## Wire format

### Pack header (48 bytes, §3.1)

```
Offset  Size  Field           Notes
   0     4    Magic           0x42445047 ("BDPG")
   4     1    Version         pack format version (1)
   5     3    Flags           reserved; must be 0 in v1
   8     8    PackId          monotonic per-instance, big-endian
  16     4    InstanceHash    erlang:phash2(InstanceId) — sanity guard
  20     4    HashAlgo        1 = sha256
  24     8    CreatedAt       wall-clock millis at header write time
  32     4    RecordCount     0 for an in-progress incoming pack;
                              written on seal
  36     4    Reserved
  40     8    Reserved
```

`HashAlgo` is recorded once per pack so a future blake3 swap-in
costs nothing on existing files: the reader trusts the pack's
declared algorithm and refuses on mismatch with the store's
configured algorithm. The hash field in each record is always
32 bytes; shorter algorithms (blake3 truncated to 24) right-pad
with zeros. v1 only ships sha256, so right-padding is dormant.

### Record (40 + PageLen bytes, §3.2)

```
   0    32    Hash             content hash (32 bytes; right-padded
                               for sub-32 algos)
  32     4    PageLen          length of page bytes
  36     4    PageCrc32        crc32 over the page body
  40   var    Page             encoded page bytes (`PageLen` bytes)
```

`PageCrc32` is the same `erlang:crc32/1` used by the WAL frame
codec. It catches single-bit flips inside the page body that the
pack-level trailer would also catch but more diffusely — the
per-record CRC localises the corruption to a single page so the
caller can decide whether to drop just that page or invalidate
the whole pack.

### Trailer (32 bytes)

A sealed pack ends with a 32-byte sha256 over every byte from
offset 0 to `EOF - 32`. The incoming (in-progress) pack has no
trailer. The trailer is the only pack-level integrity guard;
recovery uses it to detect bit-rot on the whole file, falling
back to the per-record CRC for finer-grained localisation.

## Encode contract

- `encode_pack_header/1` and `encode_record/2` return iodata
  ready for `prim_file:write/2`; the caller appends them in
  order.
- `compute_trailer/1` computes the sha256 over the pack body
  bytes (header through last record); the caller appends the
  returned 32-byte digest.

## Decode contract

- `decode_pack_header/1` validates `Magic`, `Version`,
  `HashAlgo`, and the reserved bits, returning either a typed
  map or `{error, Reason}`. Never crashes on garbage input.
- `decode_record_header/1` parses the fixed-size header out of
  the first 40 bytes of a record. `verify_record/2` is the
  composed check the reader runs after pread'ing the body: it
  re-derives the CRC and compares.
- `verify_trailer/2` is the seal-time integrity check on a full
  pack body.

All decode functions return `{ok, Term}` or `{error, Reason}`;
none throw. Callers (`bondy_mst_pack_store`) translate the
typed errors into telemetry events and recovery actions.
""").

%% Magic / version / sizes — exported so writer/reader and tests
%% can reference them without re-including the header.
-export([magic/0]).
-export([version/0]).
-export([header_bytes/0]).
-export([record_header_bytes/0]).
-export([trailer_bytes/0]).
-export([hash_bytes/0]).
-export([hash_algo_id/1]).
-export([hash_algo_atom/1]).

%% Pack header.
-export([encode_pack_header/1]).
-export([decode_pack_header/1]).

%% Records.
-export([encode_record/2]).
-export([decode_record_header/1]).
-export([record_size/1]).
-export([verify_record/2]).

%% Trailer.
-export([compute_trailer/1]).
-export([verify_trailer/2]).

-export_type([pack_header/0]).
-export_type([record_header/0]).
-export_type([decode_error/0]).

-type hash_algo() :: sha256.

-type pack_header() :: #{
    version := non_neg_integer(),
    flags := non_neg_integer(),
    pack_id := non_neg_integer(),
    instance_hash := non_neg_integer(),
    hash_algo := hash_algo(),
    created_at := non_neg_integer(),
    record_count := non_neg_integer()
}.

-type record_header() :: #{
    hash := binary(),
    page_len := non_neg_integer(),
    page_crc := non_neg_integer()
}.

-type decode_error() ::
    bad_magic
    | {bad_version, non_neg_integer()}
    | {bad_flags, non_neg_integer()}
    | {bad_hash_algo, non_neg_integer()}
    | truncated_header
    | truncated_record_header
    | truncated_trailer
    | {crc_mismatch, Got :: non_neg_integer(), Want :: non_neg_integer()}
    | {trailer_mismatch, Got :: binary(), Want :: binary()}
    | {bad_hash_size, non_neg_integer()}
    | {bad_page_len, non_neg_integer()}.

-define(MAGIC, ?BONDY_MST_PACK_MAGIC).
-define(VERSION, ?BONDY_MST_PACK_VERSION).
-define(HEADER_BYTES, ?BONDY_MST_PACK_HEADER_BYTES).
-define(REC_HDR_BYTES, ?BONDY_MST_PACK_RECORD_HEADER_BYTES).
-define(HASH_BYTES, ?BONDY_MST_PACK_HASH_BYTES).
-define(TRAILER_BYTES, ?BONDY_MST_PACK_TRAILER_BYTES).
-define(HASH_SHA256, ?BONDY_MST_PACK_HASH_ALGO_SHA256).

%% =============================================================================
%% API — constants
%% =============================================================================

-spec magic() -> non_neg_integer().

magic() -> ?MAGIC.

-spec version() -> non_neg_integer().

version() -> ?VERSION.

-spec header_bytes() -> pos_integer().

header_bytes() -> ?HEADER_BYTES.

-spec record_header_bytes() -> pos_integer().

record_header_bytes() -> ?REC_HDR_BYTES.

-spec trailer_bytes() -> pos_integer().

trailer_bytes() -> ?TRAILER_BYTES.

-spec hash_bytes() -> pos_integer().

hash_bytes() -> ?HASH_BYTES.

?DOC("""
Encodes a hash algorithm atom into its on-disk byte id.
""").
-spec hash_algo_id(hash_algo()) -> non_neg_integer().

hash_algo_id(sha256) -> ?HASH_SHA256.

?DOC("""
Decodes a hash algorithm byte id into its atom. Returns
`{error, {bad_hash_algo, Id}}` for unknown ids; the codec never
crashes on garbage input.
""").
-spec hash_algo_atom(non_neg_integer()) ->
    {ok, hash_algo()} | {error, decode_error()}.

hash_algo_atom(?HASH_SHA256) -> {ok, sha256};
hash_algo_atom(Other) -> {error, {bad_hash_algo, Other}}.

%% =============================================================================
%% API — pack header
%% =============================================================================

?DOC("""
Encodes a 48-byte pack header per §3.1. `Header` must carry every
field listed in the type `pack_header()`. The output is a binary
suitable for `prim_file:write/2`.

`record_count = 0` is the convention for the in-progress incoming
pack; the seal path rewrites the header in-place with the final
record count.
""").
-spec encode_pack_header(pack_header()) -> binary().

encode_pack_header(#{
    version := Version,
    flags := Flags,
    pack_id := PackId,
    instance_hash := InstanceHash,
    hash_algo := HashAlgo,
    created_at := CreatedAt,
    record_count := RecordCount
}) when
    is_integer(Version),
    Version >= 0,
    Version =< 16#FF,
    is_integer(Flags),
    Flags >= 0,
    Flags =< 16#FFFFFF,
    is_integer(PackId),
    PackId >= 0,
    PackId =< 16#FFFFFFFFFFFFFFFF,
    is_integer(InstanceHash),
    InstanceHash >= 0,
    is_integer(CreatedAt),
    CreatedAt >= 0,
    is_integer(RecordCount),
    RecordCount >= 0
->
    AlgoId = hash_algo_id(HashAlgo),
    <<?MAGIC:32/big-unsigned, Version:8, Flags:24/big-unsigned,
        PackId:64/big-unsigned, InstanceHash:32/big-unsigned,
        AlgoId:32/big-unsigned, CreatedAt:64/big-unsigned,
        RecordCount:32/big-unsigned, 0:32, 0:64>>.

?DOC("""
Decodes a 48-byte pack header. Validates `Magic`, `Version`,
and `HashAlgo`. Returns `{ok, Header}` or a typed `{error, _}`.

Reserved bytes are not validated for content (they're allowed to
carry anything), but the magic / version / algo gate is strict —
this is the file-recognition step and the caller should refuse
to open the pack on any error here.
""").
-spec decode_pack_header(binary()) ->
    {ok, pack_header()} | {error, decode_error()}.

decode_pack_header(Bin) when byte_size(Bin) < ?HEADER_BYTES ->
    {error, truncated_header};
decode_pack_header(
    <<?MAGIC:32/big-unsigned, Version:8, Flags:24/big-unsigned,
        PackId:64/big-unsigned, InstanceHash:32/big-unsigned,
        AlgoId:32/big-unsigned, CreatedAt:64/big-unsigned,
        RecordCount:32/big-unsigned, _Reserved1:32, _Reserved2:64,
        _Rest/binary>>
) ->
    case Version =:= ?VERSION of
        false ->
            {error, {bad_version, Version}};
        true ->
            case hash_algo_atom(AlgoId) of
                {ok, Algo} ->
                    {ok, #{
                        version => Version,
                        flags => Flags,
                        pack_id => PackId,
                        instance_hash => InstanceHash,
                        hash_algo => Algo,
                        created_at => CreatedAt,
                        record_count => RecordCount
                    }};
                {error, _} = E ->
                    E
            end
    end;
decode_pack_header(_) ->
    %% Magic mismatch: anything else of length >= 48 lands here.
    {error, bad_magic}.

%% =============================================================================
%% API — record
%% =============================================================================

?DOC("""
Encodes a page record as `<<Hash:32, PageLen:32, PageCrc:32, Page>>`.

`Hash` must be exactly `hash_bytes()` (32) bytes — shorter
algorithms must be right-padded with zeros before this call so
the on-disk record header has a fixed length.

The CRC is computed by this module; the caller passes the raw
page bytes.
""").
-spec encode_record(binary(), binary()) -> iodata().

encode_record(Hash, Page) when
    is_binary(Hash),
    byte_size(Hash) =:= ?HASH_BYTES,
    is_binary(Page)
->
    PageLen = byte_size(Page),
    Crc = erlang:crc32(Page),
    [<<Hash/binary, PageLen:32/big-unsigned, Crc:32/big-unsigned>>, Page].

?DOC("""
Decodes the fixed 40-byte record header. Returns `{ok, #{hash,
page_len, page_crc}}` or `{error, truncated_record_header}`.

The body bytes are not touched here; the caller pread's
`page_len` bytes after the header and runs them through
`verify_record/2` to confirm the CRC.
""").
-spec decode_record_header(binary()) ->
    {ok, record_header()} | {error, decode_error()}.

decode_record_header(Bin) when byte_size(Bin) < ?REC_HDR_BYTES ->
    {error, truncated_record_header};
decode_record_header(
    <<Hash:?HASH_BYTES/binary, PageLen:32/big-unsigned, Crc:32/big-unsigned,
        _Rest/binary>>
) ->
    {ok, #{hash => Hash, page_len => PageLen, page_crc => Crc}}.

?DOC("""
Returns the total on-disk size of a record with `PageLen`-byte
body: 40 + PageLen.
""").
-spec record_size(non_neg_integer()) -> pos_integer().

record_size(PageLen) when is_integer(PageLen), PageLen >= 0 ->
    ?REC_HDR_BYTES + PageLen.

?DOC("""
Verifies that the supplied page bytes match the CRC recorded in
the header. Returns `ok` or `{error, {crc_mismatch, Got, Want}}`.

A bit-flip inside the page body is guaranteed to surface here
rather than as a silently-corrupted page returned to the caller.
""").
-spec verify_record(record_header(), binary()) ->
    ok | {error, decode_error()}.

verify_record(#{page_len := PageLen}, Page) when
    byte_size(Page) =/= PageLen
->
    {error, {bad_page_len, byte_size(Page)}};
verify_record(#{page_crc := Want}, Page) ->
    case erlang:crc32(Page) of
        Want -> ok;
        Got -> {error, {crc_mismatch, Got, Want}}
    end.

%% =============================================================================
%% API — trailer
%% =============================================================================

?DOC("""
Computes the 32-byte sha256 trailer over the supplied pack body
bytes (header + all records, in disk order). The caller appends
the returned binary as the last 32 bytes of the pack on seal.

Accepts iodata so the writer can chain header iodata + record
iodata without first flattening to a binary.
""").
-spec compute_trailer(iodata()) -> binary().

compute_trailer(BodyIoData) ->
    crypto:hash(sha256, BodyIoData).

?DOC("""
Verifies a pack trailer.  `BodyIoData` is the bytes from offset 0
up to but not including the trailer; `Trailer` is the 32 bytes at
the tail of the pack.  Returns `ok` or a typed
`{error, {trailer_mismatch, _, _}}` / `{error, truncated_trailer}`.
""").
-spec verify_trailer(iodata(), binary()) ->
    ok | {error, decode_error()}.

verify_trailer(_BodyIoData, Trailer) when
    byte_size(Trailer) =/= ?TRAILER_BYTES
->
    {error, truncated_trailer};
verify_trailer(BodyIoData, Trailer) ->
    Want = compute_trailer(BodyIoData),
    case Want of
        Trailer -> ok;
        _ -> {error, {trailer_mismatch, Trailer, Want}}
    end.
