%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_wal_frame).

-include("bondy_doc.hrl").
-include("bondy_oplog_wal.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Pure encode/decode of WAL frame headers and bodies.

Every batch is written as one frame; a single-event append is a
one-element batch. The frame layout is:

```
Offset  Size  Field           Description
------  ----  -----           -----------
   0     4    Magic           0x42444F50  ("BDOP")
   4     4    FrameLen        total frame length in bytes, including header
   8     4    CRC             over bytes [4 .. FrameLen)
  12     1    FrameVersion    schema version (1 or 2)
  13     3    Flags           bit 0: compressed body (v2 only)
                              bit 1: encrypted body  (v2 only)
                              bit 2: CRC32C          (v2 only — reserved)
                              bits 3..23: reserved, zero
  16   var    Body            encoded list of bondy_oplog_event
```

The CRC covers `FrameLen || FrameVersion || Flags || Body` — i.e.
bytes `[4 .. FrameLen)`. It does **not** cover Magic or CRC itself;
Magic and CRC are validated as separate sniff checks during recovery,
so a corrupted Magic produces a distinct error type from a CRC
mismatch.

CRC algorithm choice is encoded on-disk via `Flags` bit 2. v1 frames
and v2 frames with the bit clear use zlib CRC32 (`erlang:crc32/1`).
CRC32C activation was evaluated and deferred: on representative
workloads the win falls below the 5 % threshold. The on-disk seam —
`Flags` bit 2 reserved, `crc_algo/2` and `compute_crc/2` dispatch on
algorithm — is retained so a future change can land a CRC32C provider
as a one-line widening of `compute_crc/2` without a format change. The
dispatch lives in the private `compute_crc/2` / `default_crc/1` helpers
at the bottom of this module — kept module-local because the frame
format is the only consumer.

### Versions

- **v1** — original schema. `Flags` must be zero; v1 readers reject
  any bit set. v2 readers accept v1 frames unchanged.
- **v2** — current writer version. Same layout as v1 on the wire
  except the version byte. Flag bits 0 (compression) and 1
  (encryption) are active; bit 2 (CRC32C) is reserved on-disk but
  unused — the CRC32C upgrade was evaluated and deferred. v2 readers
  accept both v1 and v2; v1 readers meeting a v2 frame return
  `unsupported_version`.

`encode/1,2` returns the frame as iodata so callers (the writer,
tests) that hand the result to `prim_file:write/2` avoid an extra
binary copy of the body. Wrap with `iolist_to_binary/1` if a
contiguous binary is needed.

This module is pure: no I/O. It is the building block used by the
writer (`bondy_oplog_wal`), the reader (`bondy_oplog_wal_reader`), and
the recovery scanner (`bondy_oplog_wal_recovery`).
""").

-define(MAGIC, ?BONDY_OPLOG_WAL_FRAME_MAGIC).
-define(HEADER_BYTES, ?BONDY_OPLOG_WAL_FRAME_HEADER_BYTES).
-define(VERSION_V1, ?BONDY_OPLOG_WAL_FRAME_VERSION_V1).
-define(VERSION_V2, ?BONDY_OPLOG_WAL_FRAME_VERSION_V2).
-define(VERSION_CURRENT, ?BONDY_OPLOG_WAL_FRAME_VERSION).
-define(KNOWN_FLAGS_V1, ?BONDY_OPLOG_WAL_FRAME_KNOWN_FLAGS_V1).
-define(KNOWN_FLAGS_V2, ?BONDY_OPLOG_WAL_FRAME_KNOWN_FLAGS_V2).

-type body() :: iodata().
-type frame() :: iodata().
-type flags() :: 0..16#FFFFFF.
-type frame_version() :: 0..16#FF.
-type decode_error() ::
    bad_magic
    | crc_mismatch
    | length_invalid
    | truncated_header
    | truncated_body
    | trailing_bytes
    | unsupported_version
    | unknown_flag.

-export_type([body/0]).
-export_type([frame/0]).
-export_type([flags/0]).
-export_type([frame_version/0]).
-export_type([decode_error/0]).

-export([encode/1]).
-export([encode/2]).
-export([decode/1]).
-export([decode_header/1]).
-export([header_bytes/0]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("Returns the fixed frame header size in bytes (16).").
-spec header_bytes() -> pos_integer().

header_bytes() ->
    ?HEADER_BYTES.

?DOC("""
Encodes `Body` into a frame with default version and zero flags.

Equivalent to `encode(Body, [])`.
""").
-spec encode(body()) -> frame().

encode(Body) ->
    encode(Body, []).

?DOC("""
Encodes `Body` into a frame. `Opts` may contain:

- `{version, FrameVersion}` — defaults to the current writer version
  (`?BONDY_OPLOG_WAL_FRAME_VERSION`). Accepts `1` or `2`; explicit `1`
  is intended for tests producing legacy fixtures.
- `{flags, Flags}` — only bits in the version's known-flags mask are
  accepted; any other bit produces `badarg` at encode-time so the
  on-disk format stays clean of forward contamination. Defaults to
  `0`.

`Body` may be any `iodata()`. The returned frame is also `iodata()` —
callers that pass it to `prim_file:write/2` avoid an extra body copy.
Wrap with `iolist_to_binary/1` if a contiguous binary is needed.
""").
-spec encode(body(), [{version, frame_version()} | {flags, flags()}]) ->
    frame().

encode(Body, Opts) when is_list(Opts) ->
    Version = proplists:get_value(version, Opts, ?VERSION_CURRENT),
    Flags = proplists:get_value(flags, Opts, 0),
    valid_version(Version) orelse error({badarg, {version, Version}}),
    valid_flags(Version, Flags) orelse
        error({badarg, {flags, Flags}}),
    BodySize = iolist_size(Body),
    FrameLen = ?HEADER_BYTES + BodySize,
    %% Layout: Magic(4) | FrameLen(4) | Crc(4) | Version(1) | Flags(3) | Body.
    %% CRC scope: FrameLen | Version | Flags | Body — i.e. bytes [4..FrameLen).
    %% Reusing `VerFlags` between the CRC input and the on-disk frame
    %% avoids the second body copy that a single contiguous binary
    %% would require.
    VerFlags = <<Version:8/unsigned, Flags:24/big-unsigned>>,
    Crc = default_crc(
        [<<FrameLen:32/big-unsigned>>, VerFlags, Body]
    ),
    [
        <<?MAGIC:32/big-unsigned, FrameLen:32/big-unsigned,
            Crc:32/big-unsigned>>,
        VerFlags,
        Body
    ].

?DOC("""
Decodes a single frame from `Binary`. The binary must contain **exactly
one complete frame**; both too-few and too-many bytes are errors.

Returns `{ok, Body, Meta}` where `Meta = #{version => V, flags => F}`,
or `{error, Reason}`. See `decode_error/0` for the reason space.

Errors used by the recovery scanner to drive break-and-truncate:
- `truncated_header` — fewer than 16 bytes available.
- `truncated_body` — declared FrameLen exceeds the available bytes.
- `trailing_bytes` — declared FrameLen is shorter than the available
  bytes; caller has read past the frame end.
- `bad_magic` — Magic field is not `BDOP`.
- `crc_mismatch` — the frame's CRC (algorithm selected by version
  and `Flags` bit 2) does not match the computed value over
  `[4..FrameLen)`.
- `length_invalid` — FrameLen is smaller than the header itself.
- `unsupported_version` — FrameVersion is not v1 or v2.
- `unknown_flag` — a flag bit outside the version's known mask is
  set.

For streaming decode (multiple frames in a stream), use
`decode_header/1` to read the header from the first 16 bytes, then read
`FrameLen - 16` more bytes and pass the complete frame here.
""").
-spec decode(binary()) ->
    {ok, binary(), #{version := frame_version(), flags := flags()}}
    | {error, decode_error()}.

decode(Bin) when is_binary(Bin), byte_size(Bin) < ?HEADER_BYTES ->
    %% Size check is first so a too-short input is reported as
    %% truncated regardless of whatever bytes it happens to contain.
    {error, truncated_header};
decode(
    <<?MAGIC:32/big-unsigned, FrameLen:32/big-unsigned, Crc:32/big-unsigned,
        Version:8/unsigned, Flags:24/big-unsigned, Rest/binary>>
) ->
    decode_validated(FrameLen, Crc, Version, Flags, Rest);
decode(<<Magic:32/big-unsigned, _/binary>>) when Magic =/= ?MAGIC ->
    {error, bad_magic}.

?DOC("""
Decodes only the 16-byte frame header. Used by the streaming recovery
scanner that reads the body separately after sizing.

Returns `{ok, Header}` where `Header = #{frame_len => integer(),
crc => integer(), version => frame_version(), flags => flags()}`, or
`{error, Reason}`.

`unknown_flag`, `unsupported_version` and `crc_mismatch` are **not**
reported here; this is a sniff function. The caller must read the body
and call `decode/1` for full validation.
""").
-spec decode_header(binary()) ->
    {ok, #{
        frame_len := pos_integer(),
        crc := non_neg_integer(),
        version := frame_version(),
        flags := flags()
    }}
    | {error, bad_magic | length_invalid | truncated_header}.

decode_header(Bin) when is_binary(Bin), byte_size(Bin) < ?HEADER_BYTES ->
    {error, truncated_header};
decode_header(
    <<?MAGIC:32/big-unsigned, FrameLen:32/big-unsigned, Crc:32/big-unsigned,
        Version:8/unsigned, Flags:24/big-unsigned, _/binary>>
) when FrameLen >= ?HEADER_BYTES ->
    {ok, #{
        frame_len => FrameLen,
        crc => Crc,
        version => Version,
        flags => Flags
    }};
decode_header(
    <<?MAGIC:32/big-unsigned, FrameLen:32/big-unsigned, _/binary>>
) when
    FrameLen < ?HEADER_BYTES
->
    {error, length_invalid};
decode_header(<<Magic:32/big-unsigned, _/binary>>) when Magic =/= ?MAGIC ->
    {error, bad_magic}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
decode_validated(FrameLen, _Crc, _Version, _Flags, _Rest) when
    FrameLen < ?HEADER_BYTES
->
    {error, length_invalid};
decode_validated(FrameLen, Crc, Version, Flags, Rest) ->
    BodyLen = FrameLen - ?HEADER_BYTES,
    RestLen = byte_size(Rest),
    if
        RestLen < BodyLen ->
            {error, truncated_body};
        RestLen > BodyLen ->
            {error, trailing_bytes};
        true ->
            verify_crc_and_decode(Crc, Version, Flags, FrameLen, Rest)
    end.

%% @private
%% Version validation precedes CRC verification: a frame with an
%% unknown version must be reported as `unsupported_version` even if
%% its CRC happens to match, because a forward-version frame's body
%% bytes have no v1/v2 reader interpretation. Flag validation is
%% version-scoped (each version has its own known-flags mask) and runs
%% after CRC so a CRC-broken frame doesn't mask as `unknown_flag`.
verify_crc_and_decode(Crc, Version, Flags, FrameLen, Body) ->
    case valid_version(Version) of
        false ->
            {error, unsupported_version};
        true ->
            LenVerFlags =
                <<FrameLen:32/big-unsigned, Version:8/unsigned,
                    Flags:24/big-unsigned>>,
            Algo = crc_algo(Version, Flags),
            case compute_crc(Algo, [LenVerFlags, Body]) of
                Crc ->
                    case valid_flags(Version, Flags) of
                        false ->
                            {error, unknown_flag};
                        true ->
                            {ok, Body, #{version => Version, flags => Flags}}
                    end;
                _ ->
                    {error, crc_mismatch}
            end
    end.

%% @private
%% The CRC algorithm a frame was written with is encoded in `Flags`.
%% Only `crc32` is ever produced today; CRC32C was evaluated and
%% deferred (the win falls below the 5 % threshold in every realistic
%% configuration). The switch is structural rather than behavioural so
%% a future widening to `crc32c` on `Flags` bit 2 is a one-line change
%% to this function plus a new clause in `compute_crc/2`.
crc_algo(?VERSION_V1, _Flags) ->
    crc32;
crc_algo(?VERSION_V2, _Flags) ->
    crc32.

%% @private
valid_version(V) when is_integer(V), V >= 0, V =< 16#FF ->
    V =:= ?VERSION_V1 orelse V =:= ?VERSION_V2;
valid_version(_) ->
    false.

%% @private
valid_flags(Version, F) when is_integer(F), F >= 0, F =< 16#FFFFFF ->
    Mask = known_flags(Version),
    F band (bnot Mask band 16#FFFFFF) =:= 0;
valid_flags(_Version, _F) ->
    false.

%% @private
known_flags(?VERSION_V1) -> ?KNOWN_FLAGS_V1;
known_flags(?VERSION_V2) -> ?KNOWN_FLAGS_V2.

%% -----------------------------------------------------------------------------
%% CRC helpers
%% -----------------------------------------------------------------------------
%%
%% The algorithm is encoded on-disk via the frame's `Flags` field, not
%% implicitly. v1 frames and v2 frames with `Flags` bit 2 clear use
%% zlib CRC32 (`erlang:crc32/1`). CRC32C activation (Flags bit 2 set)
%% is reserved on-disk but unimplemented — the upgrade was evaluated
%% and deferred. When/if it lands, it is a second clause of
%% `compute_crc/2` plus a `crc_algo/2` switch on bit 2.
%% `default_crc/1` is the writer hot-path entry point — it collapses
%% the two-call shape (`compute_crc(default_crc_algo(), _)`) into one
%% local call without leaving the frame module.

-type crc_algo() :: crc32.

%% @private
-spec compute_crc(crc_algo(), iodata()) -> 0..16#FFFFFFFF.
compute_crc(crc32, Input) ->
    erlang:crc32(Input).

%% @private
-spec default_crc(iodata()) -> 0..16#FFFFFFFF.
default_crc(Input) ->
    compute_crc(default_crc_algo(), Input).

%% @private
-spec default_crc_algo() -> crc_algo().
default_crc_algo() ->
    crc32.
