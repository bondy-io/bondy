%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_relation).
-moduledoc """
A thin **relation / EDB layer** over `bondy_db`.

A relation is a `bondy_db` table viewed as an ordered set of tuples
(facts). This module adds the two things the raw cell facade lacks and
that every "list the things in a realm" call needs:

- **Keyset (cursor) pagination** — `list/3` returns a bounded
  `t:result_set/0` and an opaque `t:cursor/0` to resume from, instead of
  materialising the whole realm. This is the fix for the
  `bondy_db:list/2`-then-`lists:sublist/2` pattern that can OOM a node
  when an operator lists a large realm.
- **A bounded streaming `fold/4`** — for the internal "touch every row"
  operations (rename, bulk-delete) that must be complete but must not
  hold the whole table in memory.

## Pagination modes

A relation's keys are spread across all of a table's shards by the
table's partition strategy (`aggregate` hashes each key's
`(Realm, Aggregate)`; `entity` hashes `{Bucket, Key}`), so a page
cannot come from a single shard for free. There are two ways to assemble it,
and they trade *ordering* against *cost*. `new/2` fixes the mode per
relation (`mode => partition | global`, default `partition`).

Multi-page traversal is **not a snapshot**: pages are independent bounded
scans, so concurrent writes may appear in — or vanish from — later pages
(standard keyset-pagination semantics).

- **`partition` (default)** — walk the shards in index order, filling the
  page from one shard before moving to the next, and stop as soon as `limit`
  accepted rows are collected. A large realm's page is therefore served from
  **one** shard (one bounded `bondy_db:range/5`), not a scatter across all of
  them. The result is *stable, complete, duplicate-free* but **not globally
  key-ordered**: rows are key-sorted *within* a shard and concatenated in
  shard-index order. This is the right mode for "enumerate the things in a
  realm" surfaces, where pages must page cleanly but need not be alphabetical.

- **`global`** — scatter the `[Low, High)` window across **every** shard and
  k-way merge the bounded per-shard results (`bondy_db:range_all/5`), so the
  full result is globally key-ordered. Every page touches every shard. Use it
  only when a caller genuinely needs sorted output.

## Cursor

The cursor is the storage key of the last row returned, plus a `schema_hash`
identifying the `(tag, mode, schema, shard_count)` it was minted for — the
shard count included so a cursor minted before a re-shard is rejected as
stale rather than paging wrongly. In `partition` mode
it also carries the **shard index** that key came from, so resumption
continues that shard just past the key before walking the remaining shards;
in `global` mode the shard is `undefined` and resumption moves a
`range_all/5` open bound past the key. Either way the lower bound moves to
`<<Key, 0>>` (the key's immediate successor), so pages never skip or
duplicate a row even when rejected rows
(see `t:decoder/0`) are interleaved between accepted ones. `encode_cursor/1`
/ `decode_cursor/2` ship the cursor over the wire (base64 of
`term_to_binary/1`), rejecting a cursor minted for a different relation —
or a different mode — with `{error, stale}`.

## Forward-map

The surface mirrors Bondy Language's `Relation.Adapter` behaviour
(`lookup`, paginated `select`, change-feed) so a future Datalog/CHR engine
binds to the same relations with no re-modelling: a relation here is the
adapter's store, a fact is a row, and `list/3`'s keyset pagination is the
adapter's `paginated_select`.
""".

-include_lib("kernel/include/logger.hrl").

%% A relation descriptor: the backing table, the row decoder, and the
%% cursor schema identity. Realm is NOT part of the descriptor — the table
%% spans every realm and the realm is a per-query argument, exactly as in
%% `bondy_db`.
-record(relation, {
    tag :: atom(),
    table :: bondy_db:table(),
    decode :: decoder(),
    schema_hash :: binary(),
    mode = partition :: mode()
}).

%% An opaque resumption token: the storage key of the last emitted row,
%% scoped to the relation/schema/mode that minted it. `shard` is the shard
%% the key came from in `partition` mode (so resumption continues that shard
%% before walking the rest), and `undefined` in `global` mode.
-record(cursor, {
    key :: binary(),
    schema_hash :: binary(),
    shard = undefined :: non_neg_integer() | undefined
}).

-opaque relation() :: #relation{}.
-opaque cursor() :: #cursor{}.

%% How `list/3` assembles a page from a multi-shard relation. `partition`
%% (default) walks shards and is partition-ordered; `global` scatter-merges
%% and is globally key-ordered. See the moduledoc.
-type mode() :: partition | global.

%% Maps a raw `bondy_db` row to the caller's tuple, or rejects it. Rejection
%% lets one physical table back more than one logical relation (e.g. the
%% user table interleaves user cells with alias-pointer cells): a rejected
%% row is skipped and the page is back-filled from the next row, so a page
%% always holds `limit` accepted rows when the band has that many.
-type decoder() :: fun((bondy_db:row()) -> {ok, term()} | skip).

-type page_opts() :: #{
    limit := pos_integer(),
    cursor => cursor() | undefined
}.

-type result_set() :: #{
    values := [term()],
    next := cursor() | undefined,
    has_more := boolean()
}.

-export_type([relation/0]).
-export_type([cursor/0]).
-export_type([mode/0]).
-export_type([page_opts/0]).
-export_type([result_set/0]).

%% Over-fetch above the page size per scatter round so a band with
%% interleaved rejected rows still fills a page in few rounds.
-define(CHUNK_MIN, 64).
%% Schema-hash width. The hash only guards a client replaying a cursor
%% minted for a different relation/schema; 16 bytes makes an accidental
%% collision negligible.
-define(HASH_BYTES, 16).

%% API
-export([decode_cursor/2]).
-export([encode_cursor/1]).
-export([fold/4]).
-export([list/3]).
-export([lookup/3]).
-export([new/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Build a relation descriptor for `Tag`.

`Opts` MUST carry:

- `table` — the `bondy_db:table/0` handle backing the relation.
- `decode` — a `t:decoder/0` mapping a raw row to the caller's tuple (or
  `skip` to reject it).

`Opts` MAY carry:

- `mode` — `partition` (default) or `global`, fixing how `list/3` assembles
  a page (see the moduledoc). The mode is part of the cursor identity, so a
  cursor minted under one mode is rejected by a relation built with the other.
- `schema` (any term) which, with `Tag` and `mode`, fixes the cursor
  `schema_hash`; it defaults to `Tag`. Change it whenever a relation's key
  encoding changes so old cursors are rejected as stale.
""".
-spec new(Tag :: atom(), Opts :: map()) -> relation().

new(Tag, #{table := Table, decode := Decode} = Opts) when
    is_atom(Tag), is_function(Decode, 1)
->
    Schema = maps:get(schema, Opts, Tag),
    Mode = maps:get(mode, Opts, partition),
    (Mode =:= partition orelse Mode =:= global) orelse
        error({badarg, {mode, Mode}}),
    #relation{
        tag = Tag,
        table = Table,
        decode = Decode,
        %% The table's shard count is part of the cursor identity: a
        %% partition-mode cursor pins a shard INDEX, so a cursor minted
        %% under one shard count resumed after a re-shard would page
        %% wrongly (skips/duplicates) instead of failing. Resharding is
        %% already placement-breaking; the cursor must fail loudly with it.
        schema_hash = schema_hash(
            Tag, {Mode, Schema, bondy_db:shard_count(Table)}
        ),
        mode = Mode
    }.

-doc """
Point lookup of the tuple stored under `Key` in `Realm`.

Returns `{ok, Tuple}` (the decoder's output), `{error, not_found}` when no
live cell exists or the decoder rejects it, or a substrate `{error, _}`.
""".
-spec lookup(
    Relation :: relation(),
    Realm :: bondy_db:realm(),
    Key :: binary()
) ->
    {ok, term()} | {error, not_found} | {error, term()}.

lookup(#relation{table = Table, decode = Decode}, Realm, Key) when
    is_binary(Realm), is_binary(Key)
->
    case bondy_db:read(Table, Realm, Key) of
        {ok, {Value, Hlc}} ->
            case Decode({Key, Value, Hlc}) of
                {ok, Tuple} -> {ok, Tuple};
                skip -> {error, not_found}
            end;
        {error, _} = Err ->
            Err
    end.

-doc """
Keyset page over the tuples of `Relation` in `Realm`.

`Opts` is a `t:page_opts/0`:

- `limit` (required) — page size; the relation is scanned for at most
  `limit + 1` accepted rows so `has_more` needs no count.
- `cursor` — a `t:cursor/0` from a previous page's `next`, or `undefined`
  (the first page). The cursor MUST have been minted by this relation.

Pages are in ascending storage-key order (partition mode: within each
shard). There is no descending mode — the projection adapters scan
ascending only.

Returns `{ok, ResultSet}` where `ResultSet` is a `t:result_set/0`
(`values`, `next`, `has_more`), or a substrate `{error, _}`. `next` is
`undefined` exactly when `has_more` is `false`.
""".
-spec list(
    Relation :: relation(),
    Realm :: bondy_db:realm(),
    Opts :: page_opts()
) ->
    {ok, result_set()} | {error, term()}.

list(#relation{mode = global} = Relation, Realm, #{limit := Limit} = Opts) when
    is_binary(Realm), is_integer(Limit), Limit > 0
->
    After = maps:get(cursor, Opts, undefined),
    ok = assert_cursor(Relation, After),
    Lo = scan_low(After),
    case collect(Relation, Realm, Lo, infinity, Limit + 1, []) of
        {ok, AccRev} ->
            {ok, finalize_page(Relation, lists:reverse(AccRev), Limit)};
        {error, _} = Err ->
            Err
    end;
list(
    #relation{mode = partition} = Relation, Realm, #{limit := Limit} = Opts
) when
    is_binary(Realm), is_integer(Limit), Limit > 0
->
    After = maps:get(cursor, Opts, undefined),
    ok = assert_cursor(Relation, After),
    NShards = bondy_db:shard_count(Relation#relation.table),
    Walk = lists:seq(start_shard(After), NShards - 1),
    Lo0 = scan_low(After),
    case collect_partition(Relation, Realm, Walk, Lo0, Limit + 1, []) of
        {ok, AccRev} ->
            {ok, finalize_page_p(Relation, lists:reverse(AccRev), Limit)};
        {error, _} = Err ->
            Err
    end.

-doc """
Stream every tuple of `Relation` in `Realm` through `Fun` in ascending
storage-key order, accumulating into `Acc0`.

Unlike collecting `list/3` pages, this never materialises the whole
relation: it pages internally with a bounded window. Use it for the
"touch every row" admin operations (rename, bulk-delete) that must be
complete but must stay within bounded memory. Rejected rows (the
decoder's `skip`) are not passed to `Fun`.

Returns `{ok, Acc}` or a substrate `{error, _}`.
""".
-spec fold(
    Relation :: relation(),
    Realm :: bondy_db:realm(),
    Fun :: fun((Tuple :: term(), AccIn :: term()) -> AccOut :: term()),
    Acc0 :: term()
) ->
    {ok, term()} | {error, term()}.

fold(#relation{} = Relation, Realm, Fun, Acc0) when
    is_binary(Realm), is_function(Fun, 2)
->
    do_fold(Relation, Realm, <<>>, Fun, Acc0).

-doc """
Encode `Cursor` to an opaque, URL-safe-ish binary for transport on a list
endpoint. The inverse is `decode_cursor/2`.
""".
-spec encode_cursor(Cursor :: cursor()) -> binary().

encode_cursor(#cursor{} = Cursor) ->
    base64:encode(term_to_binary(Cursor)).

-doc """
Decode a wire cursor produced by `encode_cursor/1`, validating that it was
minted by `Relation`.

Returns `{ok, Cursor}`, `{error, stale}` if the cursor's `schema_hash`
does not match the relation (the relation was re-keyed, or the cursor
belongs to a different relation — the caller should restart from the first
page), or `{error, malformed}` if the binary is not a decodable cursor.
""".
-spec decode_cursor(Relation :: relation(), Bin :: binary()) ->
    {ok, cursor()} | {error, stale | malformed}.

decode_cursor(#relation{schema_hash = Hash}, Bin) when is_binary(Bin) ->
    try binary_to_term(base64:decode(Bin), [safe]) of
        #cursor{schema_hash = Hash} = Cursor ->
            {ok, Cursor};
        #cursor{} ->
            {error, stale};
        _ ->
            {error, malformed}
    catch
        _:_ ->
            {error, malformed}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Gather at least `Target` accepted rows (or exhaust the band), pulling
%% scatter chunks and advancing the open window past the last raw key of
%% each chunk. Returns the accumulator newest-first.
collect(#relation{table = Table} = Relation, Realm, Lo, Hi, Target, Acc) ->
    Chunk = erlang:max(Target, ?CHUNK_MIN),
    RangeOpts = #{limit => Chunk},
    case bondy_db:range_all(Table, Realm, Lo, Hi, RangeOpts) of
        {ok, Rows} ->
            {Acc1, LastRawKey} = decode_rows(Relation, Rows, Acc),
            Enough = length(Acc1) >= Target,
            Exhausted = length(Rows) < Chunk,
            case Enough orelse Exhausted of
                true ->
                    {ok, Acc1};
                false ->
                    Lo1 = advance(LastRawKey),
                    collect(Relation, Realm, Lo1, Hi, Target, Acc1)
            end;
        {error, _} = Err ->
            Err
    end.

%% @private
%% Decode a chunk, dropping rejected rows. Returns the accumulator extended
%% (newest first) with accepted `{Key, Tuple}` pairs, and the raw key of the
%% last row in the chunk (for window advancement; `undefined` for an empty
%% chunk, which only occurs at band exhaustion where it is unused).
decode_rows(#relation{decode = Decode}, Rows, Acc0) ->
    lists:foldl(
        fun({Key, _Value, _Hlc} = Row, {Acc, _Last}) ->
            case Decode(Row) of
                {ok, Tuple} -> {[{Key, Tuple} | Acc], Key};
                skip -> {Acc, Key}
            end
        end,
        {Acc0, undefined},
        Rows
    ).

%% @private
%% Slide the scan window past the last raw key of the previous chunk: raise
%% the inclusive lower bound to the key's immediate successor.
advance(LastKey) ->
    <<LastKey/binary, 0>>.

%% @private
%% The initial inclusive lower bound. The whole realm band starts at `<<>>`
%% (the facade folds the realm in); a cursor resumes just past the last
%% emitted key.
scan_low(undefined) ->
    <<>>;
scan_low(#cursor{key = Key}) ->
    <<Key/binary, 0>>.

%% @private
%% Build the result set from up to `Target = Limit + 1` accepted rows in
%% scan order. More than `Limit` ⇒ there is a next page; the cursor is the
%% last in-page key. The `Limit + 1` fetch makes `has_more` exact without a
%% count.
finalize_page(Relation, Accepted, Limit) ->
    case length(Accepted) > Limit of
        true ->
            Page = lists:sublist(Accepted, Limit),
            {LastKey, _} = lists:last(Page),
            #{
                values => values(Page),
                next => mk_cursor(Relation, LastKey),
                has_more => true
            };
        false ->
            #{
                values => values(Accepted),
                next => undefined,
                has_more => false
            }
    end.

%% =============================================================================
%% PRIVATE: partition-mode pagination
%% =============================================================================

%% @private
%% Walk `Shards` (already in scan order) filling the page one shard at a time,
%% stopping as soon as `Target` accepted rows are gathered. The first shard
%% resumes from `(Lo, Hi)` (the cursor's intra-shard window); every later shard
%% starts from the full per-shard band. The accumulator is newest-first and
%% each entry is tagged with the shard it came from (so the cursor can name it).
collect_partition(_Relation, _Realm, [], _Lo, _Target, Acc) ->
    {ok, Acc};
collect_partition(Relation, Realm, [Shard | Rest], Lo, Target, Acc) ->
    case collect_shard(Relation, Realm, Shard, Lo, Target, Acc) of
        {filled, Acc1} ->
            {ok, Acc1};
        {exhausted, Acc1} ->
            %% Every later shard starts from its full per-shard band.
            collect_partition(Relation, Realm, Rest, <<>>, Target, Acc1);
        {error, _} = Err ->
            Err
    end.

%% @private
%% Page a single shard with a bounded `range/5` forced onto `Shard`, advancing
%% the intra-shard window past each chunk's last raw key, until either the
%% global `Target` is reached (`{filled, Acc}`) or the shard's band is
%% exhausted (`{exhausted, Acc}`). Mirrors `collect/7` but single-shard and
%% shard-tagging, so a chunk's over-fetch absorbs the decoder's rejected rows.
collect_shard(
    #relation{table = Table} = Relation, Realm, Shard, Lo, Target, Acc
) ->
    Remaining = Target - length(Acc),
    Chunk = erlang:max(Remaining, ?CHUNK_MIN),
    RangeOpts = #{limit => Chunk, shard => Shard},
    case bondy_db:range(Table, Realm, Lo, infinity, RangeOpts) of
        {ok, Rows} ->
            {Acc1, LastRawKey} = decode_rows_p(Relation, Shard, Rows, Acc),
            case length(Acc1) >= Target of
                true ->
                    {filled, Acc1};
                false ->
                    case length(Rows) < Chunk of
                        true ->
                            {exhausted, Acc1};
                        false ->
                            collect_shard(
                                Relation,
                                Realm,
                                Shard,
                                advance(LastRawKey),
                                Target,
                                Acc1
                            )
                    end
            end;
        {error, _} = Err ->
            Err
    end.

%% @private
%% Decode a single shard's chunk, dropping rejected rows. Returns the
%% accumulator extended (newest first) with accepted `{Shard, Key, Tuple}`
%% triples, and the raw key of the last row (for intra-shard advancement).
decode_rows_p(#relation{decode = Decode}, Shard, Rows, Acc0) ->
    lists:foldl(
        fun({Key, _Value, _Hlc} = Row, {Acc, _Last}) ->
            case Decode(Row) of
                {ok, Tuple} -> {[{Shard, Key, Tuple} | Acc], Key};
                skip -> {Acc, Key}
            end
        end,
        {Acc0, undefined},
        Rows
    ).

%% @private
%% As `finalize_page/3` but for shard-tagged accepted rows: the cursor records
%% the shard of the last in-page row so resumption continues there before
%% walking the remaining shards.
finalize_page_p(Relation, Accepted, Limit) ->
    case length(Accepted) > Limit of
        true ->
            Page = lists:sublist(Accepted, Limit),
            {Shard, LastKey, _} = lists:last(Page),
            #{
                values => values_p(Page),
                next => mk_cursor_p(Relation, Shard, LastKey),
                has_more => true
            };
        false ->
            #{
                values => values_p(Accepted),
                next => undefined,
                has_more => false
            }
    end.

%% @private
values_p(Triples) ->
    [Tuple || {_Shard, _Key, Tuple} <- Triples].

%% @private
mk_cursor_p(#relation{schema_hash = Hash}, Shard, Key) ->
    #cursor{key = Key, shard = Shard, schema_hash = Hash}.

%% @private
%% The shard the page starts at: a cursor pins its shard; a fresh page
%% starts at shard 0.
start_shard(#cursor{shard = Shard}) when is_integer(Shard) ->
    Shard;
start_shard(undefined) ->
    0.

%% @private
do_fold(
    #relation{table = Table, decode = Decode} = Relation, Realm, Lo, Fun, Acc
) ->
    RangeOpts = #{limit => ?CHUNK_MIN},
    case bondy_db:range_all(Table, Realm, Lo, infinity, RangeOpts) of
        {ok, []} ->
            {ok, Acc};
        {ok, Rows} ->
            Acc1 = lists:foldl(
                fun({_Key, _V, _H} = Row, A) ->
                    case Decode(Row) of
                        {ok, Tuple} -> Fun(Tuple, A);
                        skip -> A
                    end
                end,
                Acc,
                Rows
            ),
            case length(Rows) < ?CHUNK_MIN of
                true ->
                    {ok, Acc1};
                false ->
                    {LastKey, _, _} = lists:last(Rows),
                    do_fold(Relation, Realm, <<LastKey/binary, 0>>, Fun, Acc1)
            end;
        {error, _} = Err ->
            Err
    end.

%% @private
values(Pairs) ->
    [Tuple || {_Key, Tuple} <- Pairs].

%% @private
mk_cursor(#relation{schema_hash = Hash}, Key) ->
    #cursor{key = Key, schema_hash = Hash}.

%% @private
schema_hash(Tag, Schema) ->
    Full = crypto:hash(sha256, term_to_binary({Tag, Schema})),
    binary:part(Full, 0, ?HASH_BYTES).

%% @private
%% A supplied cursor MUST belong to this relation — a mismatch means the
%% caller threaded a foreign or pre-re-key cursor, a programming error.
assert_cursor(_Relation, undefined) ->
    ok;
assert_cursor(#relation{schema_hash = Hash}, #cursor{schema_hash = Hash}) ->
    ok;
assert_cursor(#relation{tag = Tag}, #cursor{}) ->
    error({stale_cursor, Tag}).
