%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_pack_manifest).

-include("bondy_mst.hrl").
-include("bondy_mst_pack.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-instance pack-store manifest with atomic rename semantics.

See the pack-store design notes §5 and §10. The
manifest is the single source of truth for which packs are live
in an instance's pack-store directory; on every open the page
store reads it to decide which `.pack` / `.idx` files to map,
and on every state change (seal, GC, set-root) it is rewritten
atomically so an interrupted update can never expose a partial
view.

## On-disk format

A sequence of `file:consult/1`-readable Erlang terms, one per
line, for human debuggability:

```erlang
{manifest_version, 1}.
{instance_id, <<\"registry-shard-17\">>}.
{hash_algo, sha256}.
{current_root, <<32 bytes>>}.       %% or `undefined`
{sealed_packs, [42, 43, 45, 46]}.   %% live pack ids, ascending
{deleted_through, 41}.               %% no sealed id =< this exists
{incoming_pack, present}.            %% present | absent
{schema_version, 1}.
{created_at, 1715520000000}.
{last_compacted_at, 1715522400000}.
```

The format mirrors the WAL manifest (`bondy_oplog_wal_manifest`).
Forward-compat: unknown fields parsed from disk are tolerated
and dropped; missing required fields produce a typed parse
error. The fault-injection seam (`bondy_mst_io:rename/2`,
`bondy_mst_io:fsync_dir/1`) is reused so crash tests can
inject failure at the rename / dir-sync steps without re-mocking
`prim_file`.

## Durability sequence (write/2)

Identical to the WAL manifest:

1. Encode the manifest to a binary.
2. Write to `manifest.tmp`, then `prim_file:datasync` the fd.
3. `bondy_mst_io:rename(\"manifest.tmp\", \"manifest\")` —
   atomic on POSIX same-filesystem.
4. `bondy_mst_io:fsync_dir/1` so the dirent change
   survives a power loss on ext4 / xfs.

A failure at any step leaves the prior manifest intact; the
caller's pack-store gen_server holds the manifest in memory and
will retry on the next state transition.

## Field semantics

- `sealed_packs` — strictly ascending list of live pack ids.
  The page-store opens each in turn for the read path; lookups
  iterate newest-first (largest id first) so recently-written
  pages are found in fewer probes.
- `deleted_through` — a watermark; no sealed pack id ≤ this
  value exists in `sealed_packs`. After GC retires pack 42, the
  manifest reflects `sealed_packs := old_list \\ [42]` AND
  `deleted_through := max(old_deleted_through, 42)`.
- `current_root` — the MST root the writer last `set_root`'d to;
  mirrored to the `root` file for fast boot. Manifest is
  authoritative on conflict.
- `incoming_pack` — `present` when `incoming.pack` exists with
  content; `absent` otherwise. The page store consults this on
  open to decide whether to scan + truncate the incoming pack.

## Purity boundary

This module performs file I/O (read, write, rename, fsync). The
encode / decode of terms is pure and exposed for testing; the
read / write functions touch the filesystem.
""").

-record(?MODULE, {
    manifest_version = ?BONDY_MST_PACK_MANIFEST_VERSION :: pos_integer(),
    instance_id :: binary(),
    hash_algo :: atom(),
    current_root :: hash() | undefined,
    sealed_packs = [] :: [non_neg_integer()],
    deleted_through = 0 :: non_neg_integer(),
    incoming_pack = absent :: present | absent,
    schema_version = 1 :: pos_integer(),
    created_at :: non_neg_integer(),
    last_compacted_at :: non_neg_integer()
}).

-type t() :: #?MODULE{}.
-type parse_error() ::
    {missing_field, atom()}
    | {bad_manifest_version, term()}
    | {bad_instance_id, term()}
    | {bad_hash_algo, term()}
    | {bad_current_root, term()}
    | {bad_sealed_packs, term()}
    | {bad_deleted_through, term()}
    | {bad_incoming_pack, term()}
    | not_proplist.

-export_type([t/0]).
-export_type([parse_error/0]).

%% Lifecycle
-export([new/2]).
-export([read/1]).
-export([write/2]).

%% Pure codec — exported for testing
-export([encode/1]).
-export([decode/1]).

%% Accessors
-export([instance_id/1]).
-export([hash_algo/1]).
-export([current_root/1]).
-export([sealed_packs/1]).
-export([deleted_through/1]).
-export([incoming_pack/1]).
-export([created_at/1]).
-export([last_compacted_at/1]).
-export([manifest_version/1]).

%% Setters (immutable; return a new manifest)
-export([with_current_root/2]).
-export([add_sealed_pack/2]).
-export([remove_sealed_packs/2]).
-export([with_incoming_pack/2]).
-export([with_last_compacted_at/2]).

%% File paths
-export([path/1]).
-export([tmp_path/1]).

%% =============================================================================
%% API — lifecycle
%% =============================================================================

?DOC("""
Constructs a fresh manifest for a new pack-store instance.

`InstanceId` is the user-supplied identifier (the same one
`bondy_oplog_instance` uses). `HashAlgo` is one of the algorithms
supported by `bondy_mst_pack_codec` (currently only `sha256`).

The fresh manifest carries no sealed packs, no current root,
and `incoming_pack = absent`.
""").
-spec new(InstanceId :: binary(), HashAlgo :: atom()) -> t().

new(InstanceId, HashAlgo) when
    is_binary(InstanceId),
    byte_size(InstanceId) > 0,
    is_atom(HashAlgo)
->
    Now = erlang:system_time(millisecond),
    #?MODULE{
        instance_id = InstanceId,
        hash_algo = HashAlgo,
        current_root = undefined,
        sealed_packs = [],
        deleted_through = 0,
        incoming_pack = absent,
        created_at = Now,
        last_compacted_at = Now
    }.

?DOC("""
Reads and parses the manifest at `Dir`. Returns `{ok, T}` or
`{error, Reason}`.

`Reason` is either an I/O error from `file:consult/1` (missing
file, permission, etc.) or a parse error from `decode/1`.
""").
-spec read(Dir :: file:filename_all()) ->
    {ok, t()} | {error, term()}.

read(Dir) ->
    Path = path(Dir),
    case file:consult(Path) of
        {ok, Terms} ->
            case decode(Terms) of
                {ok, _} = OK -> OK;
                {error, R} -> unreadable(Path, R)
            end;
        {error, enoent} = E ->
            %% NOT wrapped: `enoent` is the fresh-instance case and
            %% `bondy_mst_pack_writer:load_or_create_manifest/3` branches on
            %% it to create the first manifest. Classifying it would turn
            %% every first open into a hard failure.
            E;
        {error, R} ->
            unreadable(Path, R)
    end.

%% @private
%% A manifest that exists but cannot be used — an I/O error, or terms that
%% fail `decode/1`. Named with its path because this error becomes the raise
%% from `bondy_mst_pack_store:open_writer/4`, which is the whole of what an
%% operator sees when a node will not boot; a bare
%% `{4, file_io_server, invalid_unicode}` identifies neither the instance nor
%% the file to act on.
%%
%% Classified HERE rather than at a caller: `read/1` has three of them
%% (`bondy_mst_pack_writer`, `bondy_mst_pack_recovery`,
%% `bondy_mst_pack_reader`), and classifying at one left the other two
%% reporting the same condition in the original bare shape.
unreadable(Path, Reason) ->
    {error, {unreadable, Path, Reason}}.

?DOC("""
Atomically writes `Manifest` to `Dir`.

Implements the four-step durability sequence from the module
docstring. Returns `ok` or `{error, Reason}`; on error the prior
on-disk manifest (if any) is left intact and the tmp file is
cleaned up.
""").
-spec write(Dir :: file:filename_all(), t()) ->
    ok | {error, term()}.

write(Dir, #?MODULE{} = Manifest) ->
    TmpPath = tmp_path(Dir),
    FinalPath = path(Dir),
    Bin = encode(Manifest),
    case write_and_sync(TmpPath, Bin) of
        ok ->
            case bondy_mst_io:rename(TmpPath, FinalPath) of
                ok ->
                    bondy_mst_io:fsync_dir(Dir);
                {error, _} = E ->
                    _ = prim_file:delete(TmpPath),
                    E
            end;
        {error, _} = E ->
            _ = prim_file:delete(TmpPath),
            E
    end.

%% =============================================================================
%% API — pure codec
%% =============================================================================

?DOC("""
Encodes a manifest to its on-disk binary representation. Pure;
useful for tests and for callers that want to inspect the
proposed bytes before committing them.
""").
-spec encode(t()) -> binary().

encode(#?MODULE{} = M) ->
    Terms = [
        {manifest_version, M#?MODULE.manifest_version},
        {instance_id, M#?MODULE.instance_id},
        {hash_algo, M#?MODULE.hash_algo},
        {current_root, M#?MODULE.current_root},
        {sealed_packs, M#?MODULE.sealed_packs},
        {deleted_through, M#?MODULE.deleted_through},
        {incoming_pack, M#?MODULE.incoming_pack},
        {schema_version, M#?MODULE.schema_version},
        {created_at, M#?MODULE.created_at},
        {last_compacted_at, M#?MODULE.last_compacted_at}
    ],
    consult_encode(Terms).

%% @private
%% The bytes of a `file:consult/1` file, one term per line.
%%
%% `io_lib:format/2` yields CHARACTERS (code points), and `file:consult/1`
%% decodes the file as UTF-8, so the characters must be UTF-8 encoded —
%% `unicode:characters_to_binary/1`, never `iolist_to_binary/1`, which
%% writes each code point as one byte: a character in 160..255 then lands
%% as a byte that is not valid UTF-8 and `file:consult/1` rejects the file
%% with `{Line, file_io_server, invalid_unicode}`. Which terms produce such
%% characters depends on the directive. `~p` string-renders a binary of
%% printable latin-1 bytes as `<<"...">>`; `current_root` is a raw sha256,
%% so ~0.04% of roots did (measured 21/50000) and bricked every replica of
%% the shard at once — pinned by `encode_survives_high_byte_roots_test_`,
%% `write_read_survives_high_byte_root_test_` and
%% `prop_encode_decode_roundtrip`, all through the real `file:consult/1`.
%% `~tw` never string-renders a binary, but it does write an atom such as
%% `'café'` verbatim, so the directive alone was not the fix (measured
%% against `io_lib` + `file:consult/1`, 2026-09-03). With this manifest's
%% schema no atom field is free (`hash_algo` must be `sha256`), so that
%% class is not reachable through `t()` and is NOT pinned here; the byte
%% encoding is what keeps it unreachable as the schema grows.
%%
%% `~tw` rather than `~p` for layout: one line per term, so manifests diff
%% across versions.
%%
%% This is the same two-step as `bondy_consult:encode/1` in the umbrella's
%% `bondy_stdlib`, which this library cannot depend on (it builds standalone
%% from its own `rebar.config`); that module's tests pin every term class.
consult_encode(Terms) ->
    unicode:characters_to_binary([io_lib:format("~tw.~n", [T]) || T <- Terms]).

?DOC("""
Decodes a list of `file:consult/1`-style terms into a manifest
record. Validates required fields, type-checks each known field,
tolerates unknown fields for forward compatibility.
""").
-spec decode(list()) -> {ok, t()} | {error, parse_error()}.

decode(Terms) when is_list(Terms) ->
    case to_map(Terms) of
        {ok, Map} ->
            try
                ManifestVersion = required(manifest_version, Map),
                validate_manifest_version(ManifestVersion),
                InstanceId = required(instance_id, Map),
                validate_instance_id(InstanceId),
                HashAlgo = required(hash_algo, Map),
                validate_hash_algo(HashAlgo),
                CurrentRoot = required(current_root, Map),
                validate_current_root(CurrentRoot),
                SealedPacks = required(sealed_packs, Map),
                validate_sealed_packs(SealedPacks),
                DeletedThrough = maps:get(deleted_through, Map, 0),
                validate_deleted_through(DeletedThrough),
                Incoming = maps:get(incoming_pack, Map, absent),
                validate_incoming_pack(Incoming),
                SchemaVersion = maps:get(schema_version, Map, 1),
                CreatedAt = maps:get(created_at, Map, 0),
                LastCompactedAt = maps:get(last_compacted_at, Map, CreatedAt),
                {ok, #?MODULE{
                    manifest_version = ManifestVersion,
                    instance_id = InstanceId,
                    hash_algo = HashAlgo,
                    current_root = CurrentRoot,
                    sealed_packs = SealedPacks,
                    deleted_through = DeletedThrough,
                    incoming_pack = Incoming,
                    schema_version = SchemaVersion,
                    created_at = CreatedAt,
                    last_compacted_at = LastCompactedAt
                }}
            catch
                throw:{error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

%% =============================================================================
%% API — accessors
%% =============================================================================

-spec manifest_version(t()) -> pos_integer().
manifest_version(#?MODULE{manifest_version = V}) -> V.

-spec instance_id(t()) -> binary().
instance_id(#?MODULE{instance_id = V}) -> V.

-spec hash_algo(t()) -> atom().
hash_algo(#?MODULE{hash_algo = V}) -> V.

-spec current_root(t()) -> hash() | undefined.
current_root(#?MODULE{current_root = V}) -> V.

-spec sealed_packs(t()) -> [non_neg_integer()].
sealed_packs(#?MODULE{sealed_packs = V}) -> V.

-spec deleted_through(t()) -> non_neg_integer().
deleted_through(#?MODULE{deleted_through = V}) -> V.

-spec incoming_pack(t()) -> present | absent.
incoming_pack(#?MODULE{incoming_pack = V}) -> V.

-spec created_at(t()) -> non_neg_integer().
created_at(#?MODULE{created_at = V}) -> V.

-spec last_compacted_at(t()) -> non_neg_integer().
last_compacted_at(#?MODULE{last_compacted_at = V}) -> V.

%% =============================================================================
%% API — setters
%% =============================================================================

?DOC("""
Returns a manifest with `current_root` set to `Root` (a 32-byte
binary or `undefined`).
""").
-spec with_current_root(t(), hash() | undefined) -> t().

with_current_root(#?MODULE{} = M, undefined) ->
    M#?MODULE{current_root = undefined};
with_current_root(#?MODULE{} = M, Root) when is_binary(Root) ->
    M#?MODULE{current_root = Root}.

?DOC("""
Adds a sealed pack id to `sealed_packs`. The pack id must be
strictly greater than every existing entry (sealed packs are
created monotonically). Returns the manifest with the new pack
appended.
""").
-spec add_sealed_pack(t(), non_neg_integer()) -> t().

add_sealed_pack(#?MODULE{sealed_packs = []} = M, PackId) when
    is_integer(PackId), PackId >= 0
->
    M#?MODULE{sealed_packs = [PackId]};
add_sealed_pack(#?MODULE{sealed_packs = Packs} = M, PackId) when
    is_integer(PackId), PackId > 0
->
    Last = lists:last(Packs),
    case PackId > Last of
        true ->
            M#?MODULE{sealed_packs = Packs ++ [PackId]};
        false ->
            error({non_monotone_pack_id, PackId, Last})
    end.

?DOC("""
Removes the given pack ids from `sealed_packs` and advances
`deleted_through` to `max(deleted_through, max(Retired))`.

Pack ids that aren't currently in `sealed_packs` are ignored
(idempotent — the caller may pass a closed-set of retired ids
without filtering).
""").
-spec remove_sealed_packs(t(), [non_neg_integer()]) -> t().

remove_sealed_packs(#?MODULE{} = M, []) ->
    M;
remove_sealed_packs(
    #?MODULE{sealed_packs = Packs, deleted_through = DT} = M,
    Retired
) when is_list(Retired) ->
    RetiredSet = sets:from_list(Retired),
    Remaining = [P || P <- Packs, not sets:is_element(P, RetiredSet)],
    NewDT =
        case Retired of
            [] -> DT;
            _ -> max(DT, lists:max(Retired))
        end,
    M#?MODULE{sealed_packs = Remaining, deleted_through = NewDT}.

-spec with_incoming_pack(t(), present | absent) -> t().

with_incoming_pack(#?MODULE{} = M, present) ->
    M#?MODULE{incoming_pack = present};
with_incoming_pack(#?MODULE{} = M, absent) ->
    M#?MODULE{incoming_pack = absent}.

-spec with_last_compacted_at(t(), non_neg_integer()) -> t().

with_last_compacted_at(#?MODULE{} = M, T) when is_integer(T), T >= 0 ->
    M#?MODULE{last_compacted_at = T}.

%% =============================================================================
%% API — file paths
%% =============================================================================

-spec path(file:filename_all()) -> file:filename_all().
path(Dir) ->
    filename:join(Dir, ?BONDY_MST_PACK_MANIFEST_FILENAME).

-spec tmp_path(file:filename_all()) -> file:filename_all().
tmp_path(Dir) ->
    filename:join(Dir, ?BONDY_MST_PACK_MANIFEST_TMP_FILENAME).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
to_map(Terms) ->
    try
        {ok,
            lists:foldl(
                fun
                    ({K, V}, Acc) when is_atom(K) ->
                        Acc#{K => V};
                    (Other, _Acc) ->
                        throw({not_proplist, Other})
                end,
                #{},
                Terms
            )}
    catch
        throw:{not_proplist, _} ->
            {error, not_proplist}
    end.

%% @private
required(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, V} -> V;
        error -> throw({error, {missing_field, Key}})
    end.

%% @private
validate_manifest_version(V) when is_integer(V), V >= 1 -> ok;
validate_manifest_version(V) -> throw({error, {bad_manifest_version, V}}).

%% @private
validate_instance_id(V) when is_binary(V), byte_size(V) > 0 -> ok;
validate_instance_id(V) -> throw({error, {bad_instance_id, V}}).

%% @private
%% v1 ships only sha256; reject anything else loudly so a misconfigured
%% deploy doesn't silently open the wrong store. New algorithms will
%% bump `manifest_version` so a forward-compatible reader can recognise
%% them.
validate_hash_algo(sha256) -> ok;
validate_hash_algo(V) -> throw({error, {bad_hash_algo, V}}).

%% @private
validate_current_root(undefined) ->
    ok;
validate_current_root(V) when
    is_binary(V), byte_size(V) =:= ?BONDY_MST_PACK_HASH_BYTES
->
    ok;
validate_current_root(V) ->
    throw({error, {bad_current_root, V}}).

%% @private
%% Must be a strictly ascending list of non-negative integers. Empty
%% list is the fresh-store state.
validate_sealed_packs([]) ->
    ok;
validate_sealed_packs([First | _] = L) when is_integer(First), First >= 0 ->
    case is_strictly_ascending(L) of
        true -> ok;
        false -> throw({error, {bad_sealed_packs, L}})
    end;
validate_sealed_packs(V) ->
    throw({error, {bad_sealed_packs, V}}).

%% @private
is_strictly_ascending([_]) ->
    true;
is_strictly_ascending([A, B | Rest]) when is_integer(B), A < B ->
    is_strictly_ascending([B | Rest]);
is_strictly_ascending(_) ->
    false.

%% @private
validate_deleted_through(V) when is_integer(V), V >= 0 -> ok;
validate_deleted_through(V) -> throw({error, {bad_deleted_through, V}}).

%% @private
validate_incoming_pack(present) -> ok;
validate_incoming_pack(absent) -> ok;
validate_incoming_pack(V) -> throw({error, {bad_incoming_pack, V}}).

%% @private
%% Mirror of `bondy_oplog_wal_manifest:write_and_sync/2`: open in
%% raw binary write mode, write the body, datasync via the
%% shared seam, close.
write_and_sync(TmpPath, Bin) ->
    case prim_file:open(TmpPath, [write, raw, binary]) of
        {ok, Fd} ->
            try
                case prim_file:write(Fd, Bin) of
                    ok ->
                        bondy_mst_io:datasync(Fd);
                    {error, _} = E ->
                        E
                end
            after
                _ = prim_file:close(Fd)
            end;
        {error, _} = E ->
            E
    end.
