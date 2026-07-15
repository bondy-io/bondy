%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_cell_frame).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Codec for **projection cell value frames** (V2).

A projection adapter stores each cell as a binary frame:

```
<<
    2:8,                                              %% version
    HasValueColumn:1, _Reserved:7,                    %% flag byte
    HlcLen:16/big-unsigned, HlcBin:HlcLen/binary,
    StateLen:32/big-unsigned, StateBin:StateLen/binary,
    %% only when HasValueColumn = 1:
    ValueLen:32/big-unsigned, ValueBin:ValueLen/binary
>>
```

- `HlcBin` is a fixed 8-byte big-endian unsigned integer
  (`bondy_oplog_hlc:hlc/0` is 64-bit non-negative). The leading
  `HlcLen:16` byte-length prefix preserves forward compatibility —
  future formats can carry larger HLC representations (HLC vectors,
  version vectors) without a frame-format migration.

- `StateBin` is the output of the fold's `encode_state/1`. Opaque to
  this module.

- `ValueBin` is the output of `term_to_binary(to_value(State))`.
  Opaque to this module — only the substrate produces and consumes it.

- `HasValueColumn = 0` is reserved for folds that declare
  `value_equals_state/0 -> true` (currently only G-Set). For those
  folds the state bytes ARE the value bytes; the column is omitted
  to avoid double-storing and the HEAD path projects state bytes as
  value bytes directly.

The V1 frame format (`<<HlcLen:16, Hlc:HlcLen/binary, Body/binary>>`)
is **not** maintained — the substrate is pre-deployment and no
production data exists yet. Old V1 frames in dev environments are
nuked.

## Invariants

- `decode(encode(Hlc, State, Value, false)) == {Hlc, State, Value}`.
- `decode(encode(Hlc, State, undefined, true)) == {Hlc, State, undefined}`.
- `encode/4` produces a binary whose length is
  `2 + HlcLen + 4 + byte_size(StateBin) + ValueOverhead` where
  `ValueOverhead = 4 + byte_size(ValueBin)` when HasValueColumn=1 and
  `0` otherwise.
- `decode/1` is total over well-formed V2 frames; malformed input
  raises `error:function_clause`.

## HEAD wire format

The leveled tag's metadata extractor (`bondy_db_leveled_tag`)
projects the frame to the user-facing HEAD wire format:

```
<<HlcLen:16/big-unsigned, HlcBin:HlcLen/binary, ValueBytes/binary>>
```

Where `ValueBytes` is `ValueBin` (HasValueColumn=1) or `StateBin`
(HasValueColumn=0). See `bondy_db_leveled_tag:extract_metadata/3`.
""").

-define(VERSION, 2).
-define(HLC_BYTES, 8).
-define(HAS_VALUE_COLUMN, 1).
-define(NO_VALUE_COLUMN, 0).

-export_type([frame/0]).
-export_type([head_metadata/0]).

-type frame() :: binary().
-type head_metadata() :: binary().

-export([encode/4]).
-export([decode_full/1]).
-export([extract_head/1]).
-export([decode_head/1]).
-export([encoded_size/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Encode a V2 cell frame.

`ValueBytes` is `undefined` exactly when the fold declares
`value_equals_state/0 -> true`; the encoder then sets `HasValueColumn=0`
and the state bytes double as value bytes on the HEAD path.

For every other fold, `ValueBytes` is the output of
`term_to_binary(to_value(State))` and the frame carries both columns.

`ValueEqualsState` is the fold's declared mode (the encoder doesn't
look at the fold itself; the caller resolves the boolean via
the CRDT `value_equals_state/0` callback).
""".
-spec encode(
    Hlc :: bondy_oplog_hlc:hlc(),
    StateBytes :: binary(),
    ValueBytes :: binary() | undefined,
    ValueEqualsState :: boolean()
) -> frame().

encode(Hlc, StateBytes, undefined, true) when
    is_integer(Hlc), Hlc >= 0, is_binary(StateBytes)
->
    StateLen = byte_size(StateBytes),
    <<?VERSION:8, ?NO_VALUE_COLUMN:1, 0:7, ?HLC_BYTES:16/big-unsigned,
        Hlc:64/big-unsigned, StateLen:32/big-unsigned, StateBytes/binary>>;
encode(Hlc, StateBytes, ValueBytes, false) when
    is_integer(Hlc),
    Hlc >= 0,
    is_binary(StateBytes),
    is_binary(ValueBytes)
->
    StateLen = byte_size(StateBytes),
    ValueLen = byte_size(ValueBytes),
    <<?VERSION:8, ?HAS_VALUE_COLUMN:1, 0:7, ?HLC_BYTES:16/big-unsigned,
        Hlc:64/big-unsigned, StateLen:32/big-unsigned, StateBytes/binary,
        ValueLen:32/big-unsigned, ValueBytes/binary>>.

-doc """
Decode a V2 cell frame into `{Hlc, StateBytes, ValueBytes}`.

When `HasValueColumn=0` (G-Set and any future `value_equals_state`
fold), `ValueBytes` is returned as `undefined` — callers needing the
value bytes for those folds use `StateBytes` directly.
""".
-spec decode_full(frame()) ->
    {bondy_oplog_hlc:hlc(), binary(), binary() | undefined}.

decode_full(
    <<?VERSION:8, HasValueColumn:1, _Reserved:7, HlcLen:16/big-unsigned,
        HlcBin:HlcLen/binary, StateLen:32/big-unsigned,
        StateBytes:StateLen/binary, Rest/binary>>
) ->
    Hlc = binary:decode_unsigned(HlcBin, big),
    case HasValueColumn of
        ?HAS_VALUE_COLUMN ->
            <<ValueLen:32/big-unsigned, ValueBytes:ValueLen/binary>> = Rest,
            {Hlc, StateBytes, ValueBytes};
        ?NO_VALUE_COLUMN ->
            <<>> = Rest,
            {Hlc, StateBytes, undefined}
    end.

-doc """
Project a V2 frame to the HEAD wire format
`<<HlcLen:16, HlcBin:HlcLen/binary, ValueBytes/binary>>` consumed by
`bondy_db:read/3`.

For `HasValueColumn=1`, `ValueBytes` is the frame's value column.
For `HasValueColumn=0`, `ValueBytes` is the state bytes (the fold
declared `value_equals_state/0 -> true`).

This is the same projection performed by the leveled custom tag's
`extract_metadata/3` and is part of the substrate contract. Adapters
that don't surface HEAD via a native backend mechanism can implement
their `head/3` callback as `extract_head(get(Handle, Bucket, Key))`.
""".
-spec extract_head(frame()) -> head_metadata().

extract_head(
    <<?VERSION:8, HasValueColumn:1, _Reserved:7, HlcLen:16/big-unsigned,
        HlcBin:HlcLen/binary, StateLen:32/big-unsigned,
        StateBytes:StateLen/binary, Rest/binary>>
) ->
    case HasValueColumn of
        ?HAS_VALUE_COLUMN ->
            <<ValueLen:32/big-unsigned, ValueBytes:ValueLen/binary>> = Rest,
            <<HlcLen:16/big-unsigned, HlcBin/binary, ValueBytes/binary>>;
        ?NO_VALUE_COLUMN ->
            <<>> = Rest,
            <<HlcLen:16/big-unsigned, HlcBin/binary, StateBytes/binary>>
    end.

-doc """
Decode the HEAD wire format produced by `extract_head/1` (or by the
leveled extractor `bondy_db_leveled_tag:extract_metadata/3`) into
`{Hlc, ValueBytes}`.

Total over well-formed HEAD bytes; malformed input raises
`error:function_clause`.
""".
-spec decode_head(head_metadata()) -> {bondy_oplog_hlc:hlc(), binary()}.

decode_head(
    <<HlcLen:16/big-unsigned, HlcBin:HlcLen/binary, ValueBytes/binary>>
) ->
    Hlc = binary:decode_unsigned(HlcBin, big),
    {Hlc, ValueBytes}.

-spec encoded_size(
    StateBytes :: non_neg_integer(),
    ValueBytes :: non_neg_integer() | undefined,
    ValueEqualsState :: boolean()
) -> non_neg_integer().

encoded_size(StateSize, undefined, true) when
    is_integer(StateSize), StateSize >= 0
->
    %% 1 (version) + 1 (flag byte) + 2 + ?HLC_BYTES + 4 + StateSize.
    1 + 1 + 2 + ?HLC_BYTES + 4 + StateSize;
encoded_size(StateSize, ValueSize, false) when
    is_integer(StateSize),
    StateSize >= 0,
    is_integer(ValueSize),
    ValueSize >= 0
->
    %% Same as above plus 4 + ValueSize for the optional value column.
    1 + 1 + 2 + ?HLC_BYTES + 4 + StateSize + 4 + ValueSize.
