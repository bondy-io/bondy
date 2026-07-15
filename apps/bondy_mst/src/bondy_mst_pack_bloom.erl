%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_pack_bloom).

-include("bondy_mst.hrl").
-include("bondy_mst_pack.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Partitioned Bloom filter for the MST pack-store `.idx` files.

Implements the same partitioned-bloom math as
`bloomfi` (Almeida et al., 2007) but operates on raw binaries we
own end-to-end — `bloomfi`'s atomics-backed `bitvector` has no
serialisation API, and reaching into its private record from a
sibling module would couple the on-disk pack format to an
upstream library's internal layout. The conceptual model is
identical; we just keep the bit arrays as binaries we can
`pread` directly off disk.

Used at two points:

- **Build time** (sealing a pack into a `.idx`): the writer
  feeds the page hashes into `add/2` to construct the filter
  and calls `to_binary/1` to serialise its payload bytes for
  the `.idx` bloom section.
- **Read time** (negative-lookup short-circuit in
  `bondy_mst_pack_index:lookup/2`): the reader parses the
  payload via `from_binary/2` and calls `member/2`. A `false`
  is conclusive (no on-disk lookup needed); a `true` is
  probabilistic and the caller still performs the fanout +
  binary search.

## Sizing

Filter parameters are derived from the desired capacity `N` and
target false-positive rate `P`:

```
SliceCount  = 1 + ⌊log2(1/P)⌋
FPP         = P^(1/SliceCount)
SliceBits   = 1 + ⌊-log2(1 - (1 - FPP)^(1/N))⌋
SliceBitLen = 1 bsl SliceBits
```

`SliceBits` is the **log2** of each slice's bit length, so a
slice's length in bits is `1 bsl SliceBits` and its length in
bytes is `1 bsl (SliceBits - 3)`. For the page-store defaults
(`P = 0.01`, `N = 10_000`):

- `SliceCount = 1 + ⌊log2(100)⌋ = 7`
- `SliceBitLen ≈ 16_384`, so each slice is 2 KB on disk.
- Total payload: 7 × 2 KB = 14 KB.

The filter degrades gracefully when actual element count
exceeds `Capacity`: the false-positive rate rises but the
filter still correctly answers `true` on any inserted hash.

## Hashing

A 64-bit double-hash is derived from `Element` (the page hash
binary) via:

```
H0 = erlang:phash2({Element}, 1 bsl 32),
H1 = erlang:phash2([Element], 1 bsl 32).
```

For each slice `s` (0..k-1), the bit index is:

```
I(s) = (I0 + s * I1) band Mask
where Mask = SliceBitLen - 1
```

`I0` / `I1` are derived from `H0` / `H1` per bloomfi's `make_
indexes/2` to match `bloomfi`'s on-the-wire semantics
exactly — should we ever decide to interop with a
bloomfi-built filter (e.g. for the ETS store) the bits would
be set in the same positions.

## Wire format (16 B header + payload)

See the pack-store design notes §4 / §15.

```
Offset  Size  Field           Notes
   0     2    SliceCount      big-endian u16
   2     1    SliceBits       log2(SliceBitLen)
   3     1    Reserved
   4     4    Capacity        max-items the filter was sized for
   8     4    ItemCount       items actually inserted
  12     4    PayloadBytes    = SliceCount * SliceBitLen / 8
  16   var    Payload         payload bytes
```

## Purity

This module performs no I/O and holds no process state. The
build path returns an opaque `builder()` you fold updates into;
the read path returns a `t()` you query. Both are plain
immutable records and safe to pass across processes.
""").

-record(builder, {
    slice_count :: pos_integer(),
    %% log2(SliceBitLen)
    slice_bits :: pos_integer(),
    %% SliceBitLen div 8
    slice_byte_len :: pos_integer(),
    mask :: non_neg_integer(),
    capacity :: pos_integer(),
    item_count :: non_neg_integer(),
    %% Per-slice mutable bit buffer represented as a list of
    %% byte-sized integers (length = slice_byte_len). Slices are
    %% stored in slice-0..slice-(k-1) order. Mutations go through
    %% `set_bit/3` which rewrites a single byte.
    slices :: [array:array(byte())]
}).

-record(?MODULE, {
    slice_count :: pos_integer(),
    slice_bits :: pos_integer(),
    slice_byte_len :: pos_integer(),
    mask :: non_neg_integer(),
    capacity :: pos_integer(),
    item_count :: non_neg_integer(),
    %% On read, slices are kept as binaries for cheap pread-style
    %% lookups: bit `i` of slice `s` lives at `binary:at(slice_s,
    %% i bsr 3) band (1 bsl (i band 7))`.
    slices :: [binary()]
}).

-type t() :: #?MODULE{}.
-type builder() :: #builder{}.

-type build_opts() :: #{
    capacity := pos_integer(),
    p => float()
}.

-export_type([t/0]).
-export_type([builder/0]).
-export_type([build_opts/0]).

%% Build path
-export([new/1]).
-export([add/2]).
-export([finalise/1]).

%% One-shot helper combining new + fold + finalise.
-export([build/2]).

%% Read path
-export([from_binary/1]).
-export([member/2]).
-export([to_binary/1]).

%% Inspection
-export([slice_count/1]).
-export([slice_bits/1]).
-export([capacity/1]).
-export([item_count/1]).
-export([payload_bytes/1]).
-export([header_bytes/0]).

-define(HEADER_BYTES, ?BONDY_MST_PACK_BLOOM_HEADER_BYTES).
-define(DEFAULT_P, ?BONDY_MST_PACK_BLOOM_DEFAULT_P).
%% 64 bits / 8 bytes minimum per slice
-define(MIN_SLICE_BITS, 6).
%% guards against pathological sizing
-define(MAX_SLICE_BITS, 32).

%% =============================================================================
%% API — sizing helpers
%% =============================================================================

-spec header_bytes() -> pos_integer().

header_bytes() -> ?HEADER_BYTES.

%% =============================================================================
%% API — build
%% =============================================================================

?DOC("""
Starts a new partitioned-bloom builder sized for `Capacity`
items at false-positive rate `p` (default `0.01`).

Sizing follows the bloomfi formula (see module docstring); the
returned builder has all bits cleared and `item_count = 0`.
""").
-spec new(build_opts()) -> builder().

new(#{capacity := Capacity} = Opts) when
    is_integer(Capacity), Capacity > 0
->
    P = maps:get(p, Opts, ?DEFAULT_P),
    valid_p_or_die(P),
    SliceCount = 1 + trunc(log2(1 / P)),
    SliceBits = compute_slice_bits(Capacity, P, SliceCount),
    SliceBitLen = 1 bsl SliceBits,
    SliceByteLen = SliceBitLen bsr 3,
    Mask = SliceBitLen - 1,
    EmptySlice = array:new(SliceByteLen, [{default, 0}, {fixed, true}]),
    #builder{
        slice_count = SliceCount,
        slice_bits = SliceBits,
        slice_byte_len = SliceByteLen,
        mask = Mask,
        capacity = Capacity,
        item_count = 0,
        slices = [EmptySlice || _ <- lists:seq(1, SliceCount)]
    }.

?DOC("""
Adds `Element` (a binary — typically a 32-byte page hash) to the
builder. Returns a new builder. Idempotent on duplicates: if all
target bits are already set, `item_count` is unchanged.
""").
-spec add(binary(), builder()) -> builder().

add(Element, #builder{} = B) when is_binary(Element) ->
    {I0, I1} = make_indexes(Element, B#builder.slice_bits, B#builder.mask),
    {Slices, AnyNew} = set_slices(
        B#builder.slices, I0, I1, B#builder.mask, false
    ),
    case AnyNew of
        true ->
            B#builder{slices = Slices, item_count = B#builder.item_count + 1};
        false ->
            B#builder{slices = Slices}
    end.

?DOC("""
Finalises the builder, converting the mutable slice arrays into
read-only binaries.  The result has the same membership
semantics as the builder but consumes less memory and is what
the index codec serialises via `to_binary/1`.
""").
-spec finalise(builder()) -> t().

finalise(#builder{} = B) ->
    Slices = [
        slice_to_binary(S, B#builder.slice_byte_len)
     || S <- B#builder.slices
    ],
    #?MODULE{
        slice_count = B#builder.slice_count,
        slice_bits = B#builder.slice_bits,
        slice_byte_len = B#builder.slice_byte_len,
        mask = B#builder.mask,
        capacity = B#builder.capacity,
        item_count = B#builder.item_count,
        slices = Slices
    }.

?DOC("""
One-shot helper: build a finalised filter from a list of
elements. Equivalent to `finalise(lists:foldl(fun add/2, new(Opts),
Elements))`.
""").
-spec build([binary()], build_opts()) -> t().

build(Elements, Opts) when is_list(Elements), is_map(Opts) ->
    finalise(lists:foldl(fun add/2, new(Opts), Elements)).

%% =============================================================================
%% API — read
%% =============================================================================

?DOC("""
Tests whether `Element` may be in the filter.

`false` is conclusive — the element was never inserted.
`true` is probabilistic — at the target FPR `p`, a `true` may
correspond to a never-inserted element with probability ~`p`.
""").
-spec member(binary(), t()) -> boolean().

member(Element, #?MODULE{slice_bits = SliceBits, mask = Mask, slices = Slices}) when
    is_binary(Element)
->
    {I0, I1} = make_indexes(Element, SliceBits, Mask),
    all_set(Slices, I0, I1, Mask).

?DOC("""
Serialises a filter to its on-disk envelope (header + payload).
The result is a single binary suitable for embedding in an
`.idx` bloom section.
""").
-spec to_binary(t()) -> binary().

to_binary(#?MODULE{} = T) ->
    Payload = iolist_to_binary(T#?MODULE.slices),
    PayloadBytes = byte_size(Payload),
    <<
        (T#?MODULE.slice_count):16/big-unsigned,
        (T#?MODULE.slice_bits):8,
        0:8,
        (T#?MODULE.capacity):32/big-unsigned,
        (T#?MODULE.item_count):32/big-unsigned,
        PayloadBytes:32/big-unsigned,
        Payload/binary
    >>.

?DOC("""
Parses a previously-serialised filter. Returns
`{ok, T, RestBytes}` where `RestBytes` is whatever followed the
filter envelope (zero bytes when the envelope is exact). Returns
typed `{error, _}` for malformed input.
""").
-spec from_binary(binary()) ->
    {ok, t(), binary()} | {error, term()}.

from_binary(Bin) when byte_size(Bin) < ?HEADER_BYTES ->
    {error, truncated_bloom_header};
from_binary(
    <<SliceCount:16/big-unsigned, SliceBits:8, _Reserved:8,
        Capacity:32/big-unsigned, ItemCount:32/big-unsigned,
        PayloadBytes:32/big-unsigned, Rest/binary>>
) ->
    case validate_params(SliceCount, SliceBits, Capacity, PayloadBytes) of
        ok ->
            case Rest of
                <<Payload:PayloadBytes/binary, Tail/binary>> ->
                    SliceByteLen = PayloadBytes div SliceCount,
                    {ok,
                        build_t(
                            SliceCount,
                            SliceBits,
                            SliceByteLen,
                            Capacity,
                            ItemCount,
                            Payload
                        ),
                        Tail};
                _ ->
                    {error, truncated_bloom_payload}
            end;
        {error, _} = E ->
            E
    end.

%% =============================================================================
%% API — inspection
%% =============================================================================

-spec slice_count(t() | builder()) -> pos_integer().

slice_count(#?MODULE{slice_count = V}) -> V;
slice_count(#builder{slice_count = V}) -> V.

-spec slice_bits(t() | builder()) -> pos_integer().

slice_bits(#?MODULE{slice_bits = V}) -> V;
slice_bits(#builder{slice_bits = V}) -> V.

-spec capacity(t() | builder()) -> pos_integer().

capacity(#?MODULE{capacity = V}) -> V;
capacity(#builder{capacity = V}) -> V.

-spec item_count(t() | builder()) -> non_neg_integer().

item_count(#?MODULE{item_count = V}) -> V;
item_count(#builder{item_count = V}) -> V.

-spec payload_bytes(t()) -> non_neg_integer().

payload_bytes(#?MODULE{slice_count = K, slice_byte_len = L}) -> K * L.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
valid_p_or_die(P) when is_float(P), P > 0, P < 1 -> ok;
valid_p_or_die(P) -> error({invalid_p, P}).

%% @private
%% Bloomfi's `new(size, Capacity, P)` slice-bits derivation: pick
%% the smallest power-of-two slice size that keeps the per-slice
%% false-positive contribution below `FPP = P^(1/k)`. We bound to
%% `[MIN_SLICE_BITS, MAX_SLICE_BITS]` so a tiny capacity doesn't
%% produce a degenerate slice (under 8 bytes) or a giant one (over
%% 4 GB).
compute_slice_bits(Capacity, P, SliceCount) ->
    FPP = math:pow(P, 1 / SliceCount),
    Raw = 1 + trunc(-log2(1 - math:pow(1 - FPP, 1 / Capacity))),
    max(?MIN_SLICE_BITS, min(?MAX_SLICE_BITS, Raw)).

%% @private
log2(X) -> math:log(X) / math:log(2).

%% @private
%% Mirrors `bloomfi:make_hashes/2` + `make_indexes/2`:
%%
%%   Mask > 1 bsl 16 → masked_pair(Mask, H0, H1)
%%   Mask =< 1 bsl 16 → masked_pair(Mask, H0 bsr 16, H0)
%%
%% Producing `{I0, I1}` where `I0` is the seed index and `I1` is
%% the per-slice step.  The set of indices visited is
%% `{I0, (I0+I1) band Mask, (I0+2*I1) band Mask, ...}`.
make_indexes(Element, SliceBits, Mask) when SliceBits =< 16 ->
    H0 = erlang:phash2({Element}, 1 bsl 32),
    masked_pair(Mask, H0 bsr 16, H0);
make_indexes(Element, _SliceBits, Mask) ->
    H0 = erlang:phash2({Element}, 1 bsl 32),
    H1 = erlang:phash2([Element], 1 bsl 32),
    masked_pair(Mask, H0, H1).

%% @private
masked_pair(Mask, X, Y) -> {Y band Mask, X band Mask}.

%% @private
%% Sets bit `I` in each slice in turn, advancing `I` by `I1` (mod
%% Mask+1) after each. Returns the rewritten slice list plus a
%% boolean indicating whether any bit was newly-set (used to
%% advance the item count).
set_slices([], _I, _I1, _Mask, AnyNew) ->
    {[], AnyNew};
set_slices([Slice | Rest], I, I1, Mask, AnyNew) ->
    {Slice2, Changed} = array_set_bit(Slice, I),
    {Rest2, AnyNew2} = set_slices(
        Rest, (I + I1) band Mask, I1, Mask, AnyNew orelse Changed
    ),
    {[Slice2 | Rest2], AnyNew2}.

%% @private
array_set_bit(Slice, BitIx) ->
    ByteIx = BitIx bsr 3,
    Mask = 1 bsl (BitIx band 7),
    Byte = array:get(ByteIx, Slice),
    case Byte band Mask of
        Mask -> {Slice, false};
        0 -> {array:set(ByteIx, Byte bor Mask, Slice), true}
    end.

%% @private
slice_to_binary(Slice, ByteLen) ->
    list_to_binary([array:get(I, Slice) || I <- lists:seq(0, ByteLen - 1)]).

%% @private
all_set([], _I, _I1, _Mask) ->
    true;
all_set([SliceBin | Rest], I, I1, Mask) ->
    ByteIx = I bsr 3,
    BitMask = 1 bsl (I band 7),
    Byte = binary:at(SliceBin, ByteIx),
    case Byte band BitMask of
        0 -> false;
        _ -> all_set(Rest, (I + I1) band Mask, I1, Mask)
    end.

%% @private
validate_params(SliceCount, SliceBits, _Capacity, PayloadBytes) when
    SliceCount > 0,
    SliceBits >= ?MIN_SLICE_BITS,
    SliceBits =< ?MAX_SLICE_BITS,
    PayloadBytes > 0
->
    ExpectedPayload = SliceCount * (1 bsl (SliceBits - 3)),
    case ExpectedPayload =:= PayloadBytes of
        true -> ok;
        false -> {error, {bad_payload_size, PayloadBytes, ExpectedPayload}}
    end;
validate_params(SliceCount, SliceBits, _Capacity, _PayloadBytes) ->
    {error,
        {bad_bloom_params, #{
            slice_count => SliceCount,
            slice_bits => SliceBits
        }}}.

%% @private
build_t(SliceCount, SliceBits, SliceByteLen, Capacity, ItemCount, Payload) ->
    Slices = split_payload(Payload, SliceByteLen, SliceCount),
    Mask = (1 bsl SliceBits) - 1,
    #?MODULE{
        slice_count = SliceCount,
        slice_bits = SliceBits,
        slice_byte_len = SliceByteLen,
        mask = Mask,
        capacity = Capacity,
        item_count = ItemCount,
        slices = Slices
    }.

%% @private
split_payload(Payload, _ByteLen, 1) ->
    [Payload];
split_payload(Payload, ByteLen, N) ->
    <<Head:ByteLen/binary, Rest/binary>> = Payload,
    [Head | split_payload(Rest, ByteLen, N - 1)].
