%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_pack_index).

-include("bondy_mst.hrl").
-include("bondy_mst_pack.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Pure codec for the MST pack-store `.idx` files.

An `.idx` accelerates random-access lookup in a sealed `.pack`
by mapping `Hash → ByteOffset` without scanning the pack
linearly. Built once on seal and parsed once on open; the
runtime lookup path is `fanout_table` → `binary_search` →
`offset_array`. See the pack-store design notes
§4.

## On-disk layout (v1)

```
Header (16 bytes):
   0     4    Magic           0x4244494E ("BDIN")
   4     1    Version         = 1
   5     1    Flags           bit 0 = bloom section present
   6     2    Reserved
   8     4    RecordCount
  12     4    HashLen         hash length in bytes (default 32)

[ Bloom section (variable) — if Flags & 1 ]:
  See `bondy_mst_pack_bloom`. 16-byte sub-header + payload.

Fanout table (1024 bytes):
  256 × 4 bytes (big-endian u32). Entry `i` is the count of
  records whose first hash byte is ≤ `i`.

Sorted hash array:
  RecordCount × HashLen bytes, sorted ascending.

Offset array:
  RecordCount × 8 bytes (big-endian u64). offset[i] is the
  byte offset of record `i` (the smallest-hash record is at
  index 0) within the corresponding `.pack`.
```

The fanout table is git's classic trick: cumulative count of
hashes by leading byte, narrowing the binary-search window to
~1/256 of the array. For a 10 000-record pack the average
bucket holds ~39 hashes, binary-searched in ~6 comparisons.

## Why bloom up-front

For a hash that is NOT in the pack, the fanout + binary search
still costs `O(log N)` `pread` calls. The bloom filter
short-circuits the negative case at `O(k)` byte-level lookups —
critical when the lookup path traverses several packs to find
a page, and the first few may not contain it. A `false` from
the bloom is conclusive; a `true` falls through to the
fanout + binary-search path that actually reads the pack.

## Build contract

`build/2` takes a list of `{Hash, Offset}` pairs (any order) and
options. It sorts by hash, deduplicates (last write wins for a
duplicate hash — though duplicates are not produced by the
pack writer in practice), and emits the iodata for the `.idx`
file. The caller `prim_file:write/2`s the result.

Options:

```
#{
    hash_len    => pos_integer(),     % default 32
    bloom       => boolean(),          % default true
    bloom_p     => float()              % default 0.01
}
```

## Open / lookup contract

`open/1` parses an `.idx` binary in one pass and returns an
opaque handle.  Subsequent `lookup/2` calls run against the
handle without further parsing.  Both functions are pure;
nothing about the parsed handle is process-bound (it's all
sub-binaries of the input).

A typical caller (`bondy_mst_pack_store`) `mmap`s or `pread`s
the `.idx` file as one binary, calls `open/1`, then caches the
handle for the lifetime of the open pack.
""").

-record(?MODULE, {
    version :: pos_integer(),
    flags :: non_neg_integer(),
    record_count :: non_neg_integer(),
    hash_len :: pos_integer(),
    bloom :: bondy_mst_pack_bloom:t() | undefined,
    %% Fixed 1024-byte fanout table; kept as a binary for cheap
    %% `binary:at`/`binary:part` access in `lookup/2`.
    fanout :: binary(),
    %% Sorted hash array: RecordCount × HashLen contiguous bytes.
    hashes :: binary(),
    %% Offset array: RecordCount × 8 bytes (big-endian u64).
    offsets :: binary()
}).

-type t() :: #?MODULE{}.
-type entry() :: {Hash :: binary(), Offset :: non_neg_integer()}.

-type build_opts() :: #{
    hash_len => pos_integer(),
    bloom => boolean(),
    bloom_p => float()
}.

-type open_error() ::
    truncated_header
    | truncated_trailer
    | integrity_mismatch
    | bad_magic
    | {bad_version, non_neg_integer()}
    | {bad_hash_len, non_neg_integer()}
    | truncated_fanout
    | truncated_hashes
    | truncated_offsets
    | {fanout_inconsistent, term()}
    | {bloom, term()}.

-type build_error() ::
    {bad_hash_size, Expected :: pos_integer(), Got :: non_neg_integer()}
    | {bad_hash_len, non_neg_integer()}.

-export_type([t/0]).
-export_type([entry/0]).
-export_type([build_opts/0]).
-export_type([build_error/0]).
-export_type([open_error/0]).

%% Constants
-export([magic/0]).
-export([version/0]).
-export([header_bytes/0]).
-export([fanout_bytes/0]).
-export([offset_bytes/0]).

%% Build
-export([build/1]).
-export([build/2]).

%% Open / lookup
-export([open/1]).
-export([lookup/2]).
-export([may_contain/2]).

%% Inspection
-export([record_count/1]).
-export([hash_len/1]).
-export([has_bloom/1]).
-export([fanout/1]).
-export([hash_at/2]).
-export([offset_at/2]).
-export([entries/1]).

-define(MAGIC, ?BONDY_MST_PACK_IDX_MAGIC).
-define(VERSION, ?BONDY_MST_PACK_IDX_VERSION).
-define(HEADER_BYTES, ?BONDY_MST_PACK_IDX_HEADER_BYTES).
-define(FANOUT_BYTES, ?BONDY_MST_PACK_IDX_FANOUT_BYTES).
-define(FANOUT_ENTRIES, ?BONDY_MST_PACK_IDX_FANOUT_ENTRIES).
-define(OFFSET_BYTES, ?BONDY_MST_PACK_IDX_OFFSET_BYTES).
-define(TRAILER_BYTES, ?BONDY_MST_PACK_IDX_TRAILER_BYTES).
-define(FLAG_BLOOM, ?BONDY_MST_PACK_IDX_FLAG_BLOOM).
-define(DEFAULT_HASH_LEN, ?BONDY_MST_PACK_HASH_BYTES).

%% =============================================================================
%% API — constants
%% =============================================================================

-spec magic() -> non_neg_integer().
magic() -> ?MAGIC.

-spec version() -> pos_integer().
version() -> ?VERSION.

-spec header_bytes() -> pos_integer().
header_bytes() -> ?HEADER_BYTES.

-spec fanout_bytes() -> pos_integer().
fanout_bytes() -> ?FANOUT_BYTES.

-spec offset_bytes() -> pos_integer().
offset_bytes() -> ?OFFSET_BYTES.

%% =============================================================================
%% API — build
%% =============================================================================

?DOC("""
Builds an `.idx` binary from `Entries` with default options
(`hash_len = 32`, bloom enabled at `p = 0.01`).
""").
-spec build([entry()]) -> {ok, iodata()} | {error, build_error()}.

build(Entries) ->
    build(Entries, #{}).

?DOC("""
Builds an `.idx` binary from `Entries`.  `Entries` is a list of
`{Hash, Offset}` pairs in any order; the builder sorts and
deduplicates.

Options:

- `hash_len` — bytes per hash (default `32`). The page-store
  always uses 32 in v1; right-pad shorter algorithms.
- `bloom` — `true` (default) emits a bloom section sized to the
  entry count; `false` omits it.
- `bloom_p` — target false-positive rate for the bloom filter
  (default `0.01`).

Returns `{ok, IoData}` with iodata suitable for `prim_file:write/2`,
or `{error, build_error()}` on contract violations (hash size or
`hash_len` option out of range). The tagged shape lets the seal
writer roll back the in-progress sealed pack instead of crashing.
""").
-spec build([entry()], build_opts()) ->
    {ok, iodata()} | {error, build_error()}.

build(Entries, Opts) when is_list(Entries), is_map(Opts) ->
    try
        {ok, do_build(Entries, Opts)}
    catch
        throw:{?MODULE, build_error, Reason} ->
            {error, Reason}
    end.

%% @private
do_build(Entries, Opts) ->
    HashLen = maps:get(hash_len, Opts, ?DEFAULT_HASH_LEN),
    EmitBloom = maps:get(bloom, Opts, true),
    BloomP = maps:get(bloom_p, Opts, 0.01),
    ok = ensure_hash_len(HashLen),
    Sorted = dedup_sorted(lists:keysort(1, Entries), HashLen),
    RecordCount = length(Sorted),
    Hashes = <<<<H/binary>> || {H, _} <- Sorted>>,
    Offsets = <<<<O:64/big-unsigned>> || {_, O} <- Sorted>>,
    Fanout = build_fanout(Sorted),
    {Flags, BloomBin} =
        case EmitBloom andalso RecordCount > 0 of
            true ->
                BF = bondy_mst_pack_bloom:build(
                    [H || {H, _} <- Sorted],
                    #{capacity => max(RecordCount, 1), p => BloomP}
                ),
                {?FLAG_BLOOM, bondy_mst_pack_bloom:to_binary(BF)};
            false ->
                {0, <<>>}
        end,
    Header = encode_header(?VERSION, Flags, RecordCount, HashLen),
    Body = [Header, BloomBin, Fanout, Hashes, Offsets],
    Trailer = crypto:hash(sha256, Body),
    [Body, Trailer].

%% =============================================================================
%% API — open
%% =============================================================================

?DOC("""
Parses an `.idx` binary. Returns `{ok, Handle}` or a typed
`{error, _}`.

The handle holds sub-binaries of the input; callers should keep
the original binary alive (or use a `binary:copy/1` if memory
pressure from large reference binaries is a concern).

The trailing 32 bytes are an sha256 over the rest of the file
(symmetric to `.pack`'s trailer). The trailer is verified before
the body is parsed; a mismatch surfaces as
`{error, integrity_mismatch}` so a silent bit-flip in the fanout
or offset array cannot route lookups to the wrong record.
""").
-spec open(binary()) -> {ok, t()} | {error, open_error()}.

open(Bin) when byte_size(Bin) < ?HEADER_BYTES + ?TRAILER_BYTES ->
    case byte_size(Bin) < ?HEADER_BYTES of
        true -> {error, truncated_header};
        false -> {error, truncated_trailer}
    end;
open(Bin) ->
    BodySize = byte_size(Bin) - ?TRAILER_BYTES,
    <<Body:BodySize/binary, Trailer:?TRAILER_BYTES/binary>> = Bin,
    case crypto:hash(sha256, Body) of
        Trailer ->
            open_verified_body(Body);
        _ ->
            {error, integrity_mismatch}
    end.

%% @private
open_verified_body(
    <<?MAGIC:32/big-unsigned, Version:8, Flags:8, _Reserved:16,
        RecordCount:32/big-unsigned, HashLen:32/big-unsigned, Rest/binary>>
) ->
    case Version =:= ?VERSION of
        false ->
            {error, {bad_version, Version}};
        true ->
            case validate_hash_len(HashLen) of
                ok ->
                    open_body(Flags, RecordCount, HashLen, Rest);
                {error, _} = E ->
                    E
            end
    end;
open_verified_body(_Bin) ->
    {error, bad_magic}.

%% =============================================================================
%% API — lookup
%% =============================================================================

?DOC("""
Looks up `Hash` in the index. Returns `{ok, Offset}` if the hash
is present in the underlying pack, `not_found` otherwise.

The lookup path:

1. If a bloom section is present and reports `false`, return
   `not_found` immediately.
2. Read `fanout[H[0]-1..H[0]]` to narrow the candidate range.
3. Binary-search the candidate range in the sorted hash array.
4. If found at index `i`, return `offset_array[i]`.

For a 10 000-record pack with the average bucket holding 39
hashes, that's at most ~6 comparisons after the bloom + fanout.
""").
-spec lookup(t(), binary()) ->
    {ok, non_neg_integer()} | not_found.

lookup(#?MODULE{record_count = 0}, _) ->
    not_found;
lookup(#?MODULE{} = T, Hash) when
    is_binary(Hash), byte_size(Hash) =:= T#?MODULE.hash_len
->
    case may_contain(T, Hash) of
        false ->
            not_found;
        true ->
            <<FirstByte:8, _/binary>> = Hash,
            {Lo, Hi} = fanout_range(T#?MODULE.fanout, FirstByte),
            case binary_search(T, Hash, Lo, Hi) of
                {ok, I} -> {ok, decode_offset_at(T, I)};
                not_found -> not_found
            end
    end.

?DOC("""
Cheap probabilistic membership check via the bloom filter.

Returns `false` if the filter is present and indicates absence
(conclusive); returns `true` if the filter is absent or reports
possible membership.  Callers should NOT use this as a final
answer — `lookup/2` does that — but it's exposed for callers
that want to skip an `.idx` entirely (e.g., the multi-pack
fan-out in `bondy_mst_pack_store:get/2`).
""").
-spec may_contain(t(), binary()) -> boolean().

may_contain(#?MODULE{bloom = undefined}, _Hash) ->
    true;
may_contain(#?MODULE{bloom = BF}, Hash) ->
    bondy_mst_pack_bloom:member(Hash, BF).

%% =============================================================================
%% API — inspection
%% =============================================================================

-spec record_count(t()) -> non_neg_integer().
record_count(#?MODULE{record_count = N}) -> N.

-spec hash_len(t()) -> pos_integer().
hash_len(#?MODULE{hash_len = L}) -> L.

-spec has_bloom(t()) -> boolean().
has_bloom(#?MODULE{bloom = undefined}) -> false;
has_bloom(#?MODULE{}) -> true.

-spec fanout(t()) -> binary().
fanout(#?MODULE{fanout = F}) -> F.

?DOC("""
Returns the hash at sort-index `I` (0-based). Raises `badarg`
on out-of-range index.
""").
-spec hash_at(t(), non_neg_integer()) -> binary().

hash_at(#?MODULE{hashes = H, hash_len = L, record_count = N}, I) when
    is_integer(I), I >= 0, I < N
->
    binary:part(H, I * L, L).

?DOC("""
Returns the byte offset (into the corresponding `.pack`) at
sort-index `I`.
""").
-spec offset_at(t(), non_neg_integer()) -> non_neg_integer().

offset_at(#?MODULE{} = T, I) when
    is_integer(I), I >= 0, I < T#?MODULE.record_count
->
    decode_offset_at(T, I).

?DOC("""
Enumerates `(Hash, Offset)` pairs in sorted hash order.  Pure
fold for inspection / tests; the lookup path never uses this.
""").
-spec entries(t()) -> [entry()].

entries(#?MODULE{record_count = N} = T) ->
    [{hash_at(T, I), decode_offset_at(T, I)} || I <- lists:seq(0, N - 1)].

%% =============================================================================
%% PRIVATE — build
%% =============================================================================

%% @private
%% `open/1` path: tagged return — corrupt-file errors propagate to
%% callers that decide whether to surface or recover.
validate_hash_len(L) when is_integer(L), L > 0, L =< 64 -> ok;
validate_hash_len(L) -> {error, {bad_hash_len, L}}.

%% @private
%% `build/2` path: throws a `{?MODULE, build_error, Reason}` tagged
%% throw caught at the top of `build/2`, which maps it to
%% `{error, Reason}`. Throw rather than `error/1` so the writer can
%% roll back the in-progress sealed pack on a contract violation.
ensure_hash_len(L) when is_integer(L), L > 0, L =< 64 -> ok;
ensure_hash_len(L) -> throw({?MODULE, build_error, {bad_hash_len, L}}).

%% @private
%% `lists:keysort/2` is stable, so duplicates retain insertion
%% order; we then collapse adjacent duplicates by hash, keeping
%% the first (= earliest-inserted) offset. Pack-writer duplicates
%% should not happen by construction, but the codec stays robust.
dedup_sorted([], _) ->
    [];
dedup_sorted([{H, _} = E | Rest], HashLen) ->
    ensure_hash_size(H, HashLen),
    dedup_sorted_loop(Rest, E, HashLen, []).

dedup_sorted_loop([], Last, _, Acc) ->
    lists:reverse([Last | Acc]);
dedup_sorted_loop([{H, _} | Rest], {H, _} = Last, HashLen, Acc) ->
    %% Duplicate hash — keep the first (Last), skip the new pair.
    ensure_hash_size(H, HashLen),
    dedup_sorted_loop(Rest, Last, HashLen, Acc);
dedup_sorted_loop([{H, _} = E | Rest], Last, HashLen, Acc) ->
    ensure_hash_size(H, HashLen),
    dedup_sorted_loop(Rest, E, HashLen, [Last | Acc]).

%% @private
ensure_hash_size(H, HashLen) when byte_size(H) =:= HashLen ->
    ok;
ensure_hash_size(H, HashLen) ->
    throw({?MODULE, build_error, {bad_hash_size, HashLen, byte_size(H)}}).

%% @private
%% Cumulative count of records whose first hash byte is ≤ i, for
%% i in 0..255. Entry 255 must equal `RecordCount`.
build_fanout(Sorted) ->
    Counts = count_first_bytes(
        Sorted, array:new(?FANOUT_ENTRIES, [{default, 0}, {fixed, true}])
    ),
    Cumulative = cumulative_fold(Counts),
    iolist_to_binary(
        [<<C:32/big-unsigned>> || C <- Cumulative]
    ).

%% @private
count_first_bytes([], Counts) ->
    Counts;
count_first_bytes([{<<B:8, _/binary>>, _} | Rest], Counts) ->
    Cur = array:get(B, Counts),
    count_first_bytes(Rest, array:set(B, Cur + 1, Counts)).

%% @private
cumulative_fold(Counts) ->
    {Cum, _} = lists:foldl(
        fun(I, {Acc, Sum}) ->
            S = Sum + array:get(I, Counts),
            {[S | Acc], S}
        end,
        {[], 0},
        lists:seq(0, ?FANOUT_ENTRIES - 1)
    ),
    lists:reverse(Cum).

%% @private
encode_header(Version, Flags, RecordCount, HashLen) ->
    <<?MAGIC:32/big-unsigned, Version:8, Flags:8, 0:16,
        RecordCount:32/big-unsigned, HashLen:32/big-unsigned>>.

%% =============================================================================
%% PRIVATE — open
%% =============================================================================

%% @private
open_body(Flags, RecordCount, HashLen, Bin0) ->
    case maybe_parse_bloom(Flags, Bin0) of
        {ok, Bloom, Bin1} ->
            FanoutBytes = ?FANOUT_BYTES,
            HashesBytes = RecordCount * HashLen,
            OffsetsBytes = RecordCount * ?OFFSET_BYTES,
            case Bin1 of
                <<Fanout:FanoutBytes/binary, Hashes:HashesBytes/binary,
                    Offsets:OffsetsBytes/binary, _Tail/binary>> ->
                    case validate_fanout(Fanout, RecordCount) of
                        ok ->
                            {ok, #?MODULE{
                                version = ?VERSION,
                                flags = Flags,
                                record_count = RecordCount,
                                hash_len = HashLen,
                                bloom = Bloom,
                                fanout = Fanout,
                                hashes = Hashes,
                                offsets = Offsets
                            }};
                        {error, R} ->
                            {error, {fanout_inconsistent, R}}
                    end;
                _ ->
                    section_truncation_error(
                        Bin1, FanoutBytes, HashesBytes, OffsetsBytes
                    )
            end;
        {error, _} = E ->
            E
    end.

%% @private
maybe_parse_bloom(Flags, Bin) when Flags band ?FLAG_BLOOM =:= 0 ->
    {ok, undefined, Bin};
maybe_parse_bloom(_Flags, Bin) ->
    case bondy_mst_pack_bloom:from_binary(Bin) of
        {ok, BF, Rest} -> {ok, BF, Rest};
        {error, R} -> {error, {bloom, R}}
    end.

%% @private
section_truncation_error(Bin, FanoutBytes, _HashesBytes, _OffsetsBytes) when
    byte_size(Bin) < FanoutBytes
->
    {error, truncated_fanout};
section_truncation_error(Bin, FanoutBytes, HashesBytes, _OffsetsBytes) when
    byte_size(Bin) < FanoutBytes + HashesBytes
->
    {error, truncated_hashes};
section_truncation_error(_, _, _, _) ->
    {error, truncated_offsets}.

%% @private
validate_fanout(Fanout, RecordCount) ->
    %% Entries must be monotone non-decreasing; the last entry
    %% must equal RecordCount.
    check_fanout_monotone(Fanout, 0, 0, RecordCount).

%% @private
check_fanout_monotone(_Fanout, 256, Prev, Expected) ->
    case Prev =:= Expected of
        true -> ok;
        false -> {error, {final_count_mismatch, Prev, Expected}}
    end;
check_fanout_monotone(Fanout, I, Prev, Expected) ->
    <<_:I/binary-unit:32, V:32/big-unsigned, _/binary>> = Fanout,
    case V >= Prev of
        true -> check_fanout_monotone(Fanout, I + 1, V, Expected);
        false -> {error, {non_monotone_at, I, Prev, V}}
    end.

%% =============================================================================
%% PRIVATE — lookup
%% =============================================================================

%% @private
%% `Lo` is inclusive, `Hi` is exclusive. Entry `i` in the fanout
%% holds `count of records with first-byte ≤ i`; so the range for
%% first byte `B` is `[fanout[B-1], fanout[B])` (with the B = 0
%% special case `[0, fanout[0])`).
fanout_range(Fanout, 0) ->
    <<Hi:32/big-unsigned, _/binary>> = Fanout,
    {0, Hi};
fanout_range(Fanout, B) ->
    PrevOffset = (B - 1) * 4,
    <<_:PrevOffset/binary, Lo:32/big-unsigned, Hi:32/big-unsigned, _/binary>> =
        Fanout,
    {Lo, Hi}.

%% @private
binary_search(_T, _Hash, Lo, Hi) when Lo >= Hi ->
    not_found;
binary_search(T, Hash, Lo, Hi) ->
    Mid = Lo + (Hi - Lo) div 2,
    MidHash = binary:part(
        T#?MODULE.hashes, Mid * T#?MODULE.hash_len, T#?MODULE.hash_len
    ),
    case MidHash of
        Hash ->
            {ok, Mid};
        _ when MidHash < Hash ->
            binary_search(T, Hash, Mid + 1, Hi);
        _ ->
            binary_search(T, Hash, Lo, Mid)
    end.

%% @private
decode_offset_at(#?MODULE{offsets = Bin}, I) ->
    Off = I * ?OFFSET_BYTES,
    <<_:Off/binary, V:64/big-unsigned, _/binary>> = Bin,
    V.
