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
-export([storage_path/3]).
-export([instance_dir/3]).
-export([discover/2]).

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
Returns the per-instance directory for `InstanceId` under `BaseDir`
using the given `Layout`. The result terminates in `<InstanceId>`.
""").
-spec storage_path(
    InstanceId :: binary(), BaseDir :: binary(), Layout :: layout()
) -> file:filename_all().

storage_path(InstanceId, BaseDir, flat) when
    is_binary(InstanceId), is_binary(BaseDir)
->
    filename:join([BaseDir, InstanceId]);
storage_path(InstanceId, BaseDir, sharded) when
    is_binary(InstanceId), is_binary(BaseDir)
->
    Hash = hex(crypto:hash(sha256, InstanceId)),
    Shard1 = binary:part(Hash, 0, 2),
    Shard2 = binary:part(Hash, 0, 4),
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
Enumerates the instance ids discoverable on disk under `BaseDir` for
the given `Layout`. Suitable for boot-time enumeration.
""").
-spec discover(BaseDir :: binary(), Layout :: layout()) ->
    [InstanceId :: binary()].

discover(BaseDir, flat) when is_binary(BaseDir) ->
    Pattern = unicode:characters_to_list(filename:join(BaseDir, "*")),
    dirs(Pattern);
discover(BaseDir, sharded) when is_binary(BaseDir) ->
    Pattern = unicode:characters_to_list(
        filename:join([BaseDir, "*", "*", "*"])
    ),
    dirs(Pattern).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
dirs(Pattern) ->
    [
        unicode:characters_to_binary(filename:basename(P))
     || P <- filelib:wildcard(Pattern),
        filelib:is_dir(P)
    ].

%% @private
hex(Bin) ->
    <<<<(nibble(N))>> || <<N:4>> <= Bin>>.

%% @private
nibble(N) when N < 10 -> $0 + N;
nibble(N) -> $a + N - 10.
