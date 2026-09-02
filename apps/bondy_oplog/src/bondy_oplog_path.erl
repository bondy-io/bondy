%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_path).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-instance storage path layout.

A persistent instance keeps its on-disk artefacts (WAL, MST backend,
compaction checkpoint, origin) under a single per-instance directory
derived from a configured base directory. Two layouts are supported,
selected by the `path_layout` option (default `sharded`):

- `flat` — `<BaseDir>/<InstanceId>/`. Simplest; fine for a small,
  fixed set of instances.
- `sharded` — `<BaseDir>/<hash:2>/<hash:4>/<InstanceId>/`, where the
  shard prefixes are the first 2 and first 4 hex characters of
  `sha256(InstanceId)`. Keeps the per-directory child count
  manageable for installations hosting millions of instances; modern
  filesystems handle the sharded tree efficiently.

This module replaces the former `bondy_oplog_path_strategy` behaviour
(plus its `bondy_oplog_path_flat`/`bondy_oplog_path_sharded`
implementations): the two layouts differ by a couple of lines, so they
are expressed here as a single `layout()` parameter rather than as a
pluggable module.
""").

-type layout() :: flat | sharded.

-export_type([layout/0]).

-export([layout/1]).
-export([validate_instance_id/1]).
-export([storage_path/3]).
-export([instance_dir/3]).
-export([wal_dir/1]).
-export([origin_dir/1]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Resolves the layout from an options map. Reads the `path_layout` key,
defaulting to `sharded`. Crashes on an unrecognised value.
""").
-spec layout(Opts :: map()) -> layout().

layout(Opts) when is_map(Opts) ->
    case maps:get(path_layout, Opts, sharded) of
        flat -> flat;
        sharded -> sharded;
        Other -> error({invalid_path_layout, Other})
    end.

?DOC("""
Checks that `InstanceId` can name ONE directory component. Returns `ok` or
raises `{invalid_instance_id, InstanceId, Reason}`.

An instance id becomes a directory under every base the instance writes to
— its storage path, its WAL directory, its origin directory, its checkpoint
directory — so it has to be representable by the filesystem, confined to
the base, and in one-to-one correspondence with the directory it names.
Each `Reason` closes a failure measured against the real functions:

- `not_utf8` — `file:native_name_encoding()` is `utf8`, so a name with
  bytes that are not valid UTF-8 cannot be created at all:
  `filelib:ensure_path/1` returns `{error, eilseq}`, several frames from
  the id that caused it.
- `nul_byte` — likewise unrepresentable; surfaces as `{error, badarg}`.
- `empty` — `filename:join([Base, <<>>])` is `Base`, so an empty id would
  put the instance's artefacts directly in the shared base directory.
- `relative` — an id of exactly `.` or `..`. `filename:join/1` does NOT
  resolve `..`, so such an id names the base or its parent rather than a
  directory of its own.
- `separator` — a `/` turns the id into path STRUCTURE rather than a name.
  A leading `/` makes `filename:join/2` return an ABSOLUTE path, discarding
  the base entirely; a trailing or doubled `/` makes `main/4`, `main//4` and
  `main/4/` name one directory, so distinct ids would share an instance's
  storage; and an embedded `..` segment escapes the base — MEASURED, an id
  of `../../pwned` created a directory two levels above it. Refusing `/`
  outright makes the id and its directory name the same string.

The library enforces this ONCE, at admission
(`bondy_oplog_instance_dyn_sup:start_instance/2`), so it holds for every
instance regardless of how its directories are configured — an explicit
`wal_dir`, or the per-process `/tmp` default, never pass through
`storage_path/3`. Pinned by `bondy_oplog_lifecycle_test`.
""").
-spec validate_instance_id(InstanceId :: binary()) -> ok.

validate_instance_id(InstanceId) when is_binary(InstanceId) ->
    case classify_instance_id(InstanceId) of
        ok ->
            ok;
        Reason ->
            error({invalid_instance_id, InstanceId, Reason})
    end.

?DOC("""
Returns the per-instance directory for `InstanceId` under `BaseDir`
using the given `Layout`. The result terminates in `<InstanceId>`.

`InstanceId` must satisfy `validate_instance_id/1`, which raises
otherwise. Every instance the library starts has already passed it at
admission (`bondy_oplog_instance_dyn_sup:start_instance/2`); it is
re-checked here because this is a public function with callers of its own.
""").
-spec storage_path(
    InstanceId :: binary(), BaseDir :: binary(), Layout :: layout()
) -> file:filename_all().

storage_path(InstanceId, BaseDir, flat) when
    is_binary(InstanceId), is_binary(BaseDir)
->
    ok = validate_instance_id(InstanceId),
    filename:join([BaseDir, InstanceId]);
storage_path(InstanceId, BaseDir, sharded) when
    is_binary(InstanceId), is_binary(BaseDir)
->
    ok = validate_instance_id(InstanceId),
    {Shard1, Shard2} = shard_prefixes(InstanceId),
    filename:join([BaseDir, Shard1, Shard2, InstanceId]).

?DOC("""
Convenience over `storage_path/3`: resolves the layout from `Opts`
(via `layout/1`) and returns the per-instance directory for
`InstanceId` under `BaseDir`.
""").
-spec instance_dir(
    InstanceId :: binary(), BaseDir :: binary(), Opts :: map()
) -> file:filename_all().

instance_dir(InstanceId, BaseDir, Opts) ->
    storage_path(InstanceId, BaseDir, layout(Opts)).

?DOC("""
Returns the WAL directory an instance keeps inside `InstanceDir`.

Used when no explicit `wal_dir` is configured; see
`bondy_oplog_instance_sup:wal_base_dir/2`.
""").
-spec wal_dir(InstanceDir :: file:filename_all()) -> file:filename_all().

wal_dir(InstanceDir) ->
    internal_dir(InstanceDir, <<"wal">>).

?DOC("""
Returns the origin directory an instance keeps inside `InstanceDir`.

See `bondy_oplog_instance_sup:origin_persist_path/2`.
""").
-spec origin_dir(InstanceDir :: file:filename_all()) -> file:filename_all().

origin_dir(InstanceDir) ->
    internal_dir(InstanceDir, <<"origin">>).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Splits the UTF-8 check off from the byte-level checks: the latter all
%% assume a decodable name. `<<>>` is caught by `classify_utf8/1`.
classify_instance_id(Id) ->
    case unicode:characters_to_binary(Id, utf8, utf8) of
        Id -> classify_utf8(Id);
        _ -> not_utf8
    end.

%% @private
classify_utf8(<<>>) ->
    empty;
classify_utf8(<<".">>) ->
    relative;
classify_utf8(<<"..">>) ->
    relative;
classify_utf8(Id) ->
    case binary:match(Id, <<0>>) of
        nomatch ->
            case binary:match(Id, <<"/">>) of
                nomatch -> ok;
                _ -> separator
            end;
        _ ->
            nul_byte
    end.

%% @private
internal_dir(InstanceDir, Subdir) ->
    filename:join(unicode:characters_to_binary(InstanceDir), Subdir).

%% @private
%% The `<2 hex>/<4 hex>` bucket an id hashes into, so a base directory holding
%% millions of instances never has millions of direct children.
shard_prefixes(InstanceId) ->
    Hash = hex(crypto:hash(sha256, InstanceId)),
    {binary:part(Hash, 0, 2), binary:part(Hash, 0, 4)}.

%% @private
hex(Bin) ->
    <<<<(nibble(N))>> || <<N:4>> <= Bin>>.

%% @private
nibble(N) when N < 10 -> $0 + N;
nibble(N) -> $a + N - 10.
