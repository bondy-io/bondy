%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_topology_leveled_common).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Shared helpers for the leveled-backed `bondy_db` topologies
(`bondy_db_topology_single_bookie`, `bondy_db_topology_per_entity`,
`bondy_db_topology_shared_shards`).

These topologies differ only in how many Bookies they start and how
they map shards onto them; the directory/Bookie plumbing is identical.
This module is the single source of truth for that plumbing so a change
to (say) the default leveled options lands in every topology at once.

It is **not** a `bondy_db_topology` behaviour — it ships no callbacks,
only the leaf functions the three topology modules call.
""").

-define(PROJECTION_ADAPTER, bondy_db_projection_leveled).

-export([default_book_opts/1]).
-export([ensure_dir/1]).
-export([normalise_dir/1]).
-export([stop_bookie_safe/1]).
-export([route/2]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Default leveled `book_start/1` options for a Bookie rooted at `Dir`.

`head_only=with_lookup` enables `book_mput/2` (atomic batched writes)
and `book_headonly/4` (ledger-only point reads), both required by
`bondy_db_projection_leveled`. With the flag on,
`book_get`/`book_put` are unsupported; the adapter uses `book_headonly`
+ `book_mput` exclusively.

The defaults are tuned for fast tests, not production. Deployments
should override `book_opts_fun` in `topology_opts`.
""").
-spec default_book_opts(Dir :: file:filename_all()) ->
    proplists:proplist().

default_book_opts(Dir) ->
    [
        {root_path, Dir},
        {cache_size, 2000},
        {max_journalsize, 100_000_000},
        {sync_strategy, none},
        {head_only, with_lookup}
    ].

?DOC("Ensures `Dir` exists by creating it (via a sentinel child path).").
-spec ensure_dir(Dir :: file:filename_all()) -> ok | {error, term()}.

ensure_dir(Dir) ->
    filelib:ensure_dir(filename:join(Dir, ".keep")).

?DOC("Normalises a directory to the string form leveled expects.").
-spec normalise_dir(Dir :: binary() | string()) -> string().

normalise_dir(Dir) when is_binary(Dir) -> binary_to_list(Dir);
normalise_dir(Dir) when is_list(Dir) -> Dir.

?DOC("""
Flushes and closes a Bookie, tolerating an already-dead process. The
supervisor reaps the now-dead `temporary` child without restarting it.
""").
-spec stop_bookie_safe(Bookie :: pid() | term()) -> ok.

stop_bookie_safe(Bookie) when is_pid(Bookie) ->
    case is_process_alive(Bookie) of
        true ->
            _ = catch leveled_bookie:book_close(Bookie),
            ok;
        false ->
            ok
    end;
stop_bookie_safe(_) ->
    ok.

?DOC("""
`route/2` callback body shared by the sharded topologies: looks `Shard`
up in the state's `shards` map and returns the per-shard
projection-adapter handle.
""").
-spec route(Shard :: non_neg_integer(), State :: map()) ->
    {ok, module(), map()} | {error, {unknown_shard, non_neg_integer()}}.

route(Shard, #{shards := Shards}) when is_integer(Shard) ->
    case maps:find(Shard, Shards) of
        {ok, Bookie} ->
            Handle = #{bookie => Bookie},
            {ok, ?PROJECTION_ADAPTER, Handle};
        error ->
            {error, {unknown_shard, Shard}}
    end.
