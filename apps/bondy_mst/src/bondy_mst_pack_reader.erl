%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_pack_reader).

-include("bondy_mst.hrl").
-include("bondy_mst_pack.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Read-only view of a pack-store instance.

Reads the manifest at `Dir`, opens each sealed `pack-NNNN.pack`
along with its `.idx`, and exposes `get/2`, `has/2`, and `list/1`
that resolve hashes across all live packs. The reader is a
snapshot at `open/1` time — sealing a new pack does not extend an
already-open reader; the caller closes and reopens to see new
data.

See the pack-store design notes §6.

## Lookup path

For a hash:

1. Iterate sealed packs in reverse pack-id order (newest first —
   most recently written pages are typically the most recently
   accessed, and we want to short-circuit fast).
2. For each pack, consult the `.idx`:
   - The bloom filter rejects the negative case at `O(k)` bit
     lookups; no `pread` needed.
   - On a bloom hit, the fanout table narrows the binary-search
     window to roughly 1/256 of the sorted hash array; the
     binary search itself is `O(log N)` byte comparisons.
3. On a hit, `pread` the record header + body at the recorded
   offset, verify the CRC, return the page.

A `not_found` from the reader means the hash is not in any sealed
pack. Pending pages in a co-located writer's `incoming.pack` are
NOT visible to the reader; the gen_server composes writer + reader
to present a unified view.

## Resource model

`open/1` eagerly opens an fd per sealed pack plus parses each
`.idx` into memory. For a typical instance with a handful of
packs this is cheap. A future LRU layer can be inserted between
`open/1` and `get/2` without changing the API once instance fan-out
gets large.

`close/1` closes every fd; the parsed `.idx` handles drop with
the surrounding state.
""").

-record(?MODULE, {
    dir :: file:filename_all(),
    manifest :: bondy_mst_pack_manifest:t(),
    %% Sealed packs in *descending* pack_id order so `get/2` short-
    %% circuits on the newest packs first.
    sealed :: [#sealed_view{}]
}).

-type t() :: #?MODULE{}.

-type open_error() ::
    {manifest, term()}
    | {sealed_pack, non_neg_integer(), term()}
    | {sealed_idx, non_neg_integer(), term()}.

%% Lifted into `bondy_mst_pack_io:read_error/0` (the shape is shared
%% between the reader and the store's sealed-pack lookup paths).
-type get_error() :: bondy_mst_pack_io:read_error().

-export_type([t/0]).
-export_type([open_error/0]).
-export_type([get_error/0]).

%% Lifecycle
-export([open/1]).
-export([close/1]).

%% Lookups
-export([get/2]).
-export([has/2]).
-export([list/1]).

%% Inspection
-export([dir/1]).
-export([manifest/1]).
-export([sealed_pack_ids/1]).

%% =============================================================================
%% API — lifecycle
%% =============================================================================

?DOC("""
Opens a read-only view of the instance at `Dir`.

Reads the manifest, then opens each sealed pack listed in the
manifest along with its `.idx` companion. Returns
`{ok, R}` or a typed `{error, _}`. On any partial failure (e.g.,
a single pack's `.idx` is missing), all fds opened so far are
closed before the error is returned.
""").
-spec open(file:filename_all()) -> {ok, t()} | {error, open_error()}.

open(Dir) ->
    case bondy_mst_pack_manifest:read(Dir) of
        {ok, M} ->
            PackIds = bondy_mst_pack_manifest:sealed_packs(M),
            Ctx = bondy_mst_pack_sealed_view:open_ctx_from_manifest(M),
            case open_all_sealed(Dir, Ctx, PackIds, []) of
                {ok, Views} ->
                    Sorted = lists:reverse(
                        lists:keysort(#sealed_view.pack_id, Views)
                    ),
                    {ok, #?MODULE{
                        dir = Dir,
                        manifest = M,
                        sealed = Sorted
                    }};
                {error, _} = E ->
                    E
            end;
        {error, R} ->
            {error, {manifest, R}}
    end.

?DOC("""
Closes every open pack fd. Idempotent.
""").
-spec close(t()) -> ok.

close(#?MODULE{sealed = Views}) ->
    lists:foreach(
        fun(#sealed_view{pack_fd = Fd}) -> _ = prim_file:close(Fd) end,
        Views
    ),
    ok.

%% =============================================================================
%% API — lookups
%% =============================================================================

?DOC("""
Resolves `Hash` to its page bytes. Iterates sealed packs newest-
first; returns `{ok, Page}` on the first hit, `not_found` if every
pack rejects, or `{error, _}` on an I/O / corruption error.
""").
-spec get(t(), Hash :: binary()) ->
    {ok, binary()} | not_found | {error, get_error()}.

get(#?MODULE{sealed = Views}, Hash) when is_binary(Hash) ->
    get_loop(Views, Hash).

get_loop([], _) ->
    not_found;
get_loop([V | Rest], Hash) ->
    case bondy_mst_pack_index:lookup(V#sealed_view.idx, Hash) of
        not_found ->
            get_loop(Rest, Hash);
        {ok, Offset} ->
            case bondy_mst_pack_io:read_record(V, Hash, Offset) of
                {ok, Page} ->
                    {ok, Page};
                not_found ->
                    %% Bloom said maybe but the actual hash mismatched —
                    %% fall through to the next pack.
                    get_loop(Rest, Hash);
                {error, _} = E ->
                    E
            end
    end.

?DOC("""
Probabilistic membership probe across all sealed packs.

Returns `true` iff at least one sealed pack's `.idx` claims the
hash *may* be present (bloom hit + binary-search hit). The fast
path uses the bloom filter; on a bloom miss the pack is skipped
without further I/O.

A `true` result is conclusive (the index says the hash is at a
known offset); a `false` result is conclusive too (every pack
rejects). Unlike `get/2`, this does NOT pread the record body
to verify the CRC — that's deferred to `get/2`.
""").
-spec has(t(), Hash :: binary()) -> boolean().

has(#?MODULE{sealed = Views}, Hash) when is_binary(Hash) ->
    lists:any(
        fun(#sealed_view{idx = Idx}) ->
            bondy_mst_pack_index:lookup(Idx, Hash) =/= not_found
        end,
        Views
    ).

?DOC("""
Enumerates every distinct hash across all sealed packs in
descending pack-id, then sorted-hash order. Used for snapshots
and tests; the hot lookup path uses `get/2`.
""").
-spec list(t()) -> [binary()].

list(#?MODULE{sealed = Views}) ->
    Seen = lists:foldl(
        fun(#sealed_view{idx = Idx}, Acc) ->
            lists:foldl(
                fun({H, _}, A) -> A#{H => true} end,
                Acc,
                bondy_mst_pack_index:entries(Idx)
            )
        end,
        #{},
        Views
    ),
    lists:sort(maps:keys(Seen)).

%% =============================================================================
%% API — inspection
%% =============================================================================

-spec dir(t()) -> file:filename_all().
dir(#?MODULE{dir = D}) -> D.

-spec manifest(t()) -> bondy_mst_pack_manifest:t().
manifest(#?MODULE{manifest = M}) -> M.

-spec sealed_pack_ids(t()) -> [non_neg_integer()].
sealed_pack_ids(#?MODULE{sealed = Views}) ->
    [V#sealed_view.pack_id || V <- Views].

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Sealed-pack opens are delegated to `bondy_mst_pack_sealed_view`
%% so the reader inherits the same self-healing rebuild behaviour as
%% the read-write store. A missing or corrupt `.idx` is reconstructed
%% from the authoritative `.pack` on first open; a corrupt `.pack`
%% bubbles up unchanged for operator triage.
open_all_sealed(_Dir, _Ctx, [], Acc) ->
    {ok, Acc};
open_all_sealed(Dir, Ctx, [PackId | Rest], Acc) ->
    case bondy_mst_pack_sealed_view:open(Dir, Ctx, PackId) of
        {ok, View} ->
            open_all_sealed(Dir, Ctx, Rest, [View | Acc]);
        {error, _} = E ->
            lists:foreach(
                fun(#sealed_view{pack_fd = Fd}) -> _ = prim_file:close(Fd) end,
                Acc
            ),
            E
    end.
