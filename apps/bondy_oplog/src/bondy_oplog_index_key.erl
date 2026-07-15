%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_index_key).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Order-preserving composite `(Term, PrimaryKey)` codec for the secondary
index keyspace.

A secondary index is materialised as an **ordered composite keyspace**
queried by range, rather than via leveled's native 2i (which is
incompatible with `head_only` mode). Each index entry is keyed by

```
SecKey = <<TermEnc/binary, 0, PrimaryKey/binary>>
```

so the entries sort first by the normalised, order-preserving term
encoding and then by the raw primary key. Equality reads scan the
contiguous run for one term; range reads scan a `[Lo, Hi)` window.

## Term encoding (`encode_term/1`)

- **Binary terms** are encoded directly (byte order is the comparison
  order callers want).
- **Integer terms** are first mapped to a fixed-width, sign-biased
  big-endian form `<<(N + (1 bsl 63)):64>>` so two's-complement signed
  order becomes unsigned lexicographic order. v1 restricts integer
  terms to the signed 64-bit range; anything outside raises `badarg`.

The byte string is then run through an **order-preserving,
prefix-free, self-delimiting escape** so the encoded term contains no
`0x00` byte:

```
0x00 -> 0x01 0x01
0x01 -> 0x01 0x02
b    -> b            (b >= 0x02)
```

The single `0x00` separator therefore sorts strictly before any encoded
term byte (all `>= 0x01`), which guarantees the primary-key suffix
never corrupts term order even when one term is a byte-prefix of
another. Recovering the primary key is a scan to the first (and only)
`0x00`.

### Deviation from the naïve byte values

An alternative escape maps `0x00 -> 0x00 0x01` with a *bare* `0x00`
separator. That scheme is not order-preserving for an arbitrary appended
primary key: when term `T1` is a prefix of term `T2`, the byte following
`T1`'s separator is the primary key's first byte, which can compare
greater than the `0x01` that opens `T2`'s escaped continuation —
inverting the intended `T1 < T2` order. We use a prefix-free *monotone*
code (escape into the `0x01` range, reserve `0x00` solely as the
separator) which is provably order-preserving for any primary-key suffix.
Same goal (order-preserving, self-delimiting, recover the key by scanning
to the separator), correct construction.

## Bounds

- `equality_bounds(T)` -> `{<<TermEnc(T), 0>>, <<TermEnc(T), 1>>}`, the
  half-open `[Low, High)` window covering exactly term `T`'s entries.
- `range_bounds(Lo, Hi)` -> `{<<TermEnc(Lo), 0>>, <<TermEnc(Hi), 0>>}`,
  the half-open window covering terms in `[Lo, Hi)`.

Both are half-open `[Low, High)` so callers map them onto
`bondy_oplog_core:range/range_all` (exclusive upper bound) without an
off-by-one.
""").

-export([encode/2]).
-export([encode_term/1]).
-export([encode_col/1]).
-export([decode_col/1]).
-export([col_bounds/1]).
-export([encode_tuple/1]).
-export([decode_tuple/1]).
-export([decode_composite/2]).
-export([decode_pk/1]).
-export([equality_bounds/1]).
-export([range_bounds/2]).
-export([bucket/2]).
-export([bucket_suffix/1]).
-export([trust_marker_loc/3]).
-export([clean_flag_loc/3]).
-export([shard/3]).

-type column() :: binary() | integer() | atom().
%% One column of a composite term, encoded by the type-tagged `encode_col/1`.
-type term_value() :: binary() | integer() | [column()].
%% An index term before order-preserving encoding. A scalar (`binary()` /
%% `integer()`) is a single-column inverted-index term; a **list of columns** is
%% a composite (covering) term — a config-declared collation order — encoded by
%% `encode_tuple/1` into one order-preserving key so any *prefix* of the columns
%% is a bounded range scan (Hexastore / RDF-permutation indices).

-export_type([term_value/0, column/0]).

-define(SEP, 0).
-define(INT_BIAS, (1 bsl 63)).
-define(INT_MIN, -(1 bsl 63)).
-define(INT_MAX, ((1 bsl 63) - 1)).
-define(IDX_INFIX, "/$idx/").
%% Leading type tags for `encode_col/1`, so one column may mix value types
%% (a rolename `binary()` and the reserved atoms `all`/`anonymous`) and still
%% compare unambiguously. Tags are `>= 1` (never the `0x00` separator) and are
%% NOT escaped — `decode_col/1` dispatches on the first byte. Cross-type order
%% follows the tag (`int < atom < binary`); within a type the escaped body is
%% order-preserving. (Cross-type order is irrelevant to the equality bands the
%% only current caller uses; it is fixed only so the codec is total.)
-define(COL_INT, 1).
-define(COL_ATOM, 2).
-define(COL_BIN, 3).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Encode a `(Term, PrimaryKey)` pair into the composite secondary key.
`PrimaryKey` is appended raw after the `0x00` separator.
""".
-spec encode(term_value(), binary()) -> binary().

encode(Term, PrimaryKey) when is_binary(PrimaryKey) ->
    <<(encode_term(Term))/binary, ?SEP, PrimaryKey/binary>>.

-doc """
Encode a single term into its order-preserving, `0x00`-free byte form.
Exposed for the bounds helpers and for callers building keys directly.
""".
-spec encode_term(term_value()) -> binary().

encode_term(Term) when is_binary(Term) ->
    escape(Term);
encode_term(Term) when is_integer(Term), Term >= ?INT_MIN, Term =< ?INT_MAX ->
    escape(<<(Term + ?INT_BIAS):64/big-unsigned>>);
encode_term(Term) when is_integer(Term) ->
    %% Outside the signed 64-bit range supported in v1.
    erlang:error(badarg, [Term]);
encode_term(Term) when is_list(Term) ->
    %% A composite (covering) term — a list of columns in collation order.
    encode_tuple(Term).

-doc """
Encode a single **type-tagged** column into its order-preserving,
`0x00`-free byte form — the building block of a composite primary key
(`<<encode_col(C1), 0, encode_col(C2), 0, ...>>`) and of the future
`encode_tuple`.

Unlike `encode_term/1` (which restricts a column to one type), `encode_col/1`
prepends a 1-byte type tag so a column may mix `binary()` with the reserved
atoms (`all`/`anonymous`) — the RBAC role/username leading column — and still
decode unambiguously via `decode_col/1`. Integers reuse the same sign-biased
64-bit form as `encode_term/1`. The body is run through the same monotone
escape, so the whole result contains no `0x00` and a `[<<Col,0>>, <<Col,1>>)`
band (`col_bounds/1`) selects exactly the rows whose leading column equals `C`.
""".
-spec encode_col(binary() | atom() | integer()) -> binary().

encode_col(V) when is_integer(V), V >= ?INT_MIN, V =< ?INT_MAX ->
    <<?COL_INT, (escape(<<(V + ?INT_BIAS):64/big-unsigned>>))/binary>>;
encode_col(V) when is_atom(V) ->
    <<?COL_ATOM, (escape(atom_to_binary(V, utf8)))/binary>>;
encode_col(V) when is_binary(V) ->
    <<?COL_BIN, (escape(V))/binary>>.

-doc """
Inverse of `encode_col/1`. The atom branch uses `binary_to_existing_atom/2`,
so a column atom must already be loaded on the decoding node — true for the
RBAC reserved atoms (`all`/`anonymous`), which the codebase references directly.
""".
-spec decode_col(binary()) -> binary() | atom() | integer().

decode_col(<<?COL_INT, Rest/binary>>) ->
    <<N:64/big-unsigned>> = unescape(Rest),
    N - ?INT_BIAS;
decode_col(<<?COL_ATOM, Rest/binary>>) ->
    binary_to_existing_atom(unescape(Rest), utf8);
decode_col(<<?COL_BIN, Rest/binary>>) ->
    unescape(Rest).

-doc """
Half-open `[Low, High)` bounds selecting exactly the composite keys whose
leading column equals `C`: `{<<encode_col(C), 0>>, <<encode_col(C), 1>>}`. The
`0x00` separator that follows the (escaped, `0x00`-free) column sorts below any
suffix byte, so the band captures every `<<encode_col(C), 0, Suffix>>` and no
other column's keys — the same construction as `equality_bounds/1`.
""".
-spec col_bounds(binary() | atom() | integer()) -> {binary(), binary()}.

col_bounds(V) ->
    Col = encode_col(V),
    {<<Col/binary, 0>>, <<Col/binary, 1>>}.

-doc """
Encode a **composite term** — a list of columns in collation order — into one
order-preserving binary: `«encode_col(c1), 0, encode_col(c2), 0, …, encode_col(ck)»`.

This is the covering-permutation key (Hexastore / RDF-3X): each column is the
type-tagged, `0x00`-free `encode_col/1`, joined by the `0x00` separator. Because
every column is `0x00`-free, a **prefix** of the columns `[c1,…,cj]` (`j ≤ k`)
has `encode_tuple([c1,…,cj])` as a byte-prefix of the full tuple's encoding, so
`equality_bounds/1` on that prefix is a bounded range scan over every fact whose
first `j` columns match — the property that makes a single index serve every
prefix access pattern. An empty list encodes to `<<>>`.
""".
-spec encode_tuple([column()]) -> binary().

encode_tuple(Cols) when is_list(Cols) ->
    iolist_to_binary(lists:join(<<0>>, [encode_col(C) || C <- Cols])).

-doc """
Inverse of `encode_tuple/1`: split a composite-term encoding back into its
columns. The input must be exactly the tuple bytes (no trailing primary key) —
each column is `0x00`-free, so splitting on `0x00` recovers them. `<<>>` decodes
to `[]`.
""".
-spec decode_tuple(binary()) -> [column()].

decode_tuple(<<>>) ->
    [];
decode_tuple(Bin) when is_binary(Bin) ->
    [decode_col(C) || C <- binary:split(Bin, <<0>>, [global])].

-doc """
Split a composite index entry's `«enc(c1),0,…,0,enc(ck),0,PrimaryKey»` body
(the bytes *after* any realm prefix) into its `Arity` decoded columns and the
trailing primary key. The columns are `0x00`-free so the first `Arity`
separators delimit them; everything past the `Arity`-th separator is the primary
key (which MAY contain `0x00`). Used by the read path for covering composite
indices, where the columns are the answer.
""".
-spec decode_composite(binary(), pos_integer()) -> {[column()], binary()}.

decode_composite(Bin, Arity) when
    is_binary(Bin), is_integer(Arity), Arity > 0
->
    {ColBins, PK} = take_columns(Bin, Arity, []),
    {[decode_col(C) || C <- ColBins], PK}.

-doc """
Recover the primary key from a composite secondary key by scanning to
the single `0x00` separator. The encoded term contains no `0x00` byte,
so the first match is unambiguously the separator.
""".
-spec decode_pk(binary()) -> binary().

decode_pk(SecKey) when is_binary(SecKey) ->
    case binary:match(SecKey, <<?SEP>>) of
        {Pos, 1} ->
            binary:part(SecKey, Pos + 1, byte_size(SecKey) - Pos - 1);
        nomatch ->
            erlang:error(badarg, [SecKey])
    end.

-doc """
Half-open `[Low, High)` bounds covering exactly the entries for term
`T`. `Low` is `T`'s smallest possible key (empty primary key); `High`
is the first key strictly greater than every `T` entry yet less than any
other term's entries.
""".
-spec equality_bounds(term_value()) -> {binary(), binary()}.

equality_bounds(T) ->
    Enc = encode_term(T),
    {<<Enc/binary, 0>>, <<Enc/binary, 1>>}.

-doc """
Half-open `[Low, High)` bounds covering terms in `[Lo, Hi)`. `Lo` is
included (its smallest key), `Hi` is excluded (its smallest key is the
exclusive upper bound).
""".
-spec range_bounds(term_value(), term_value()) -> {binary(), binary()}.

range_bounds(Lo, Hi) ->
    {<<(encode_term(Lo))/binary, 0>>, <<(encode_term(Hi))/binary, 0>>}.

-doc """
The storage-layer bucket for an index's cells:
`<<PrimaryBucket, "/$idx/", IndexName>>`. Each `(NS, IndexName, SecShard)`
already has its own shard-set, so this only needs to isolate realms (the
`PrimaryBucket` prefix); the `IndexName` suffix keeps the bucket
self-describing. Reader and writer MUST agree on this layout — it is the
single source of truth.
""".
-spec bucket(binary(), atom()) -> binary().

bucket(PrimaryBucket, IndexName) when
    is_binary(PrimaryBucket), is_atom(IndexName)
->
    <<PrimaryBucket/binary, ?IDX_INFIX,
        (atom_to_binary(IndexName, utf8))/binary>>.

-doc """
The trailing fragment every index bucket ends with, in every topology:
`<<"/$idx/", IndexName>>`. Since `bucket/2` always appends `?IDX_INFIX ++
IndexName` after the topology's primary bucket, this suffix uniquely
identifies index `IndexName`'s cells *within a Bookie/handle that holds a
single logical table* (`per_entity`'s dedicated Bookie, the ETS adapter's
per-`(NS, Index, Shard)` table). The rebuild's wipe uses it for the
`{suffix, IndexName}` `clear_scope()` on exactly those single-table handles.

**Shared backends use a different scope.** On a backend that co-locates
several logical tables in one keyspace (`shared_shards`, `single_bookie`)
this suffix does NOT include the `EntityType`, so two co-located tables that
declare the **same** `IndexName` would share it. Those topologies therefore
do NOT use this suffix for the wipe — they return the `{entity, ET, IndexName}`
`clear_scope()` (see `bondy_db_topology:index_clear_scope/2`), which confines
the wipe to one entity type's index buckets. Co-located tables may thus safely
declare the same `IndexName`.
""".
-spec bucket_suffix(atom()) -> binary().

bucket_suffix(IndexName) when is_atom(IndexName) ->
    <<?IDX_INFIX, (atom_to_binary(IndexName, utf8))/binary>>.

-doc """
Storage location `{Bucket, Key}` of an index shard's **durable trust
marker** — a reserved cell whose **presence means the shard is built and
clean** (trustworthy on cold-start) and whose **absence means it must be
rebuilt** using the durable-marker approach.

Inverted ("trusted") rather than "dirty" semantics so that *absence* — the
default with no on-disk state — uniformly covers BOTH cases that require a
rebuild on open:

- a **newly-declared index over an already-populated table** (never built, so
  no marker → rebuild from the primary), and
- a shard **left incomplete by a pre-restart drop / wedged flush** (the drop
  removed the marker → rebuild).

A clean build/rebuild writes the marker (`index_clear_rebuild/1`); a drop
removes it (`index_mark_rebuild/1`). The compaction flush barrier keeps a
trusted shard's durable cells complete `≤ snapshot_wm`, so a restart trusts
+ freshens + tail-replays — never an O(table) re-derive.

The marker lives in the reserved bucket `<<"$idx_trusted">>`, deliberately
**outside** the index keyspace:

- it contains no `?IDX_INFIX` (`"/$idx/"`), so the suffix-scoped `clear/2`
  (the rebuild's orphan-wipe) never touches it;
- index range scans target the per-index bucket
  (`bucket/2 = <<…, "/$idx/", IndexName>>`), never `<<"$idx_trusted">>`, so a
  marker can never surface as a phantom index entry.

The key encodes `(NS, IndexName, Shard)` so a single shared backend
(`shared_shards`, `single_bookie`) — whose one Bookie holds many shards in
this reserved bucket — keeps every shard's marker distinct.
""".
-spec trust_marker_loc(atom(), atom(), non_neg_integer()) ->
    {binary(), binary()}.

trust_marker_loc(NS, IndexName, Shard) when
    is_atom(NS), is_atom(IndexName), is_integer(Shard), Shard >= 0
->
    Key = <<
        (atom_to_binary(NS, utf8))/binary,
        ?SEP,
        (atom_to_binary(IndexName, utf8))/binary,
        ?SEP,
        (integer_to_binary(Shard))/binary
    >>,
    {<<"$idx_trusted">>, Key}.

-doc """
Storage location `{Bucket, Key}` of an index shard's **durable
clean-shutdown flag** — a reserved cell whose **presence means the shard
was durably flushed to the primary head at a clean shutdown**.

It is the second gate of the cold-start trust decision, alongside the trust
marker (`trust_marker_loc/3`): a shard is trusted on open only if it is both
*built* (trust marker present) **and** *cleanly closed* (this flag present).
`bondy_db:close_table/1` writes it after `flush_sync`-ing the writer; cold-start
**clears** it on open (so a crash this run leaves the shard dirty → rebuilt next
open). The clear is safe under leveled's prefix recovery: it is journalled
before any post-open index write, so a partial crash either keeps the clear
(→ rebuild, safe) or loses both clear and writes (→ nothing new lost, trust is
correct).

Unlike the trust marker — written once at build completion, content-blind —
this flag is per-run: it certifies that *this lifetime's* writes reached disk,
which the trust marker alone cannot (it would trust a built-then-crashed shard
that lost its in-flight coalesce buffer).

Lives in the reserved bucket `<<"$idx_clean">>`, outside the index keyspace for
the same reasons as the trust marker (no `?IDX_INFIX`, so `clear/2` and range
scans never touch it). The key encodes `(NS, IndexName, Shard)` so a shared
backend keeps every shard's flag distinct.
""".
-spec clean_flag_loc(atom(), atom(), non_neg_integer()) ->
    {binary(), binary()}.

clean_flag_loc(NS, IndexName, Shard) when
    is_atom(NS), is_atom(IndexName), is_integer(Shard), Shard >= 0
->
    Key = <<
        (atom_to_binary(NS, utf8))/binary,
        ?SEP,
        (atom_to_binary(IndexName, utf8))/binary,
        ?SEP,
        (integer_to_binary(Shard))/binary
    >>,
    {<<"$idx_clean">>, Key}.

-doc """
The secondary shard a term lands in: `phash2({Bucket, Term}, ShardCount)`.
Term-sharded, so all `(Term, _)` entries for one term live in one shard —
an equality read hits exactly that shard; a range read scatters. `Term`
is the *normalised* term value (the reader and writer normalise
identically via the index spec). The single source of truth for placement,
shared by `bondy_db` reads and the secondary writer.
""".
-spec shard(binary(), term(), pos_integer()) -> non_neg_integer().

shard(Bucket, Term, ShardCount) when
    is_binary(Bucket), is_integer(ShardCount), ShardCount > 0
->
    erlang:phash2({Bucket, Term}, ShardCount).

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% Order-preserving, prefix-free escape into the `0x01` range so the
%% result contains no `0x00`. `0x00 -> 0x01 0x01`, `0x01 -> 0x01 0x02`,
%% every other byte unchanged. The code is monotone and prefix-free, so
%% lexicographic order of encoded strings matches that of the originals.
escape(Bin) ->
    %% Fast path: the overwhelmingly common term contains no `0x00`/`0x01`,
    %% so a single C-level scan lets us return the input binary unchanged
    %% instead of rebuilding it byte-by-byte. `encode_term/1` is on the hot
    %% indexed-write path and is called again per bound on every read.
    case binary:match(Bin, [<<0>>, <<1>>]) of
        nomatch -> Bin;
        _ -> <<<<(esc_byte(B))/binary>> || <<B>> <= Bin>>
    end.

esc_byte(0) -> <<1, 1>>;
esc_byte(1) -> <<1, 2>>;
esc_byte(B) -> <<B>>.

%% Inverse of `escape/1`: `0x01 0x01 -> 0x00`, `0x01 0x02 -> 0x01`, every other
%% byte unchanged. Fast path returns the input unchanged when it holds no escape
%% intro byte (`0x01`) — the common case for validated names (no bytes `<= 0x20`).
unescape(Bin) ->
    case binary:match(Bin, <<1>>) of
        nomatch -> Bin;
        _ -> unescape(Bin, <<>>)
    end.

unescape(<<>>, Acc) ->
    Acc;
unescape(<<1, 1, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, 0>>);
unescape(<<1, 2, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, 1>>);
unescape(<<B, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, B>>).

%% Peel `Arity` `0x00`-delimited columns off the front; the remainder (past the
%% Arity-th separator) is the primary key, returned verbatim (it may contain
%% `0x00`).
take_columns(Bin, 0, Acc) ->
    {lists:reverse(Acc), Bin};
take_columns(Bin, N, Acc) ->
    case binary:split(Bin, <<0>>) of
        [Col, Rest] -> take_columns(Rest, N - 1, [Col | Acc]);
        [Col] -> {lists:reverse([Col | Acc]), <<>>}
    end.
