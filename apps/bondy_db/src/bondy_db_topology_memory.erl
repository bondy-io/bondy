%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_topology_memory).
-behaviour(bondy_db_topology).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
In-memory `bondy_db` topology: one `bondy_oplog_projection_ets` table per
`(EntityType, Shard)`, no leveled Bookie, no filesystem.

```
DB (ephemeral)
├── users
│   ├── ETS(users, 0)
│   ├── ETS(users, 1)
│   └── ...
└── sessions
    └── ETS(sessions, 0)
```

This is the projection backing for **ephemeral** namespaces — state that
must die with the node and reconverge from peers, never be resurrected
from disk (see `bondy_oplog_projection_ets` for the WAMP-registration
rationale). It is the per-namespace "projection backend = ETS" selection:
open the namespace's DB with `topology => bondy_db_topology_memory` and the
whole projection layer is in RAM. Pair it with an in-memory MST store
(`oplog_instance_opts => #{backend => ets}`) and no `storage_path` for a
fully ephemeral stack.

The facade stays topology-agnostic — `route/2` returns the ETS adapter
exactly as the leveled topologies return the leveled adapter, so every
read/write/range path is unchanged.

## Required `topology_opts`

None. `sup` / `dir` (if present, e.g. when reusing a leveled topology's
opts) are accepted and ignored — there is no Bookie to supervise and no
directory to lay out.

## TableState shape

```erlang
#{
    entity_type := atom(),
    shard_count := pos_integer(),
    shards      := #{Shard :: non_neg_integer() := ets:tid()},
    owner       := pid()
}
```

## Ownership

The per-shard ETS tables are **not** owned by the transient process that
calls `bondy_db:open_table/3`. `init/2` starts a dedicated DB-scoped
owner process (`bondy_db_topology_memory_owner`) — the in-RAM analogue of
`bondy_db_leveled_sup` — and every table is created and destroyed inside
it. The owner's lifetime is bracketed by `init/2` → `shutdown/1`,
mirroring the explicit start/stop lifecycle of the appliers that write
the tables; a facade caller dying no longer wipes them (and so no longer
crashes a live applier on a dead tid). `close_table/2` asks the owner to
delete a table's shards on orderly teardown; `shutdown/1` stops the owner,
which deletes every remaining table. See `bondy_db_topology_memory_owner`
for the ownership rationale and the deliberate non-linking.

The same owner also hosts the per-shard **read caches**: this topology
implements the optional `provision_cache/5` + `release_cache/2` hooks so
the facade creates the cache table inside the owner instead of the
caller, and binds the `bondy_oplog_core_registry` monitor to the owner too.
With the projection table, the cache, and the registry row all anchored
in the owner, a write+read driven through the surviving substrate keeps
working after the `open_table/3` caller is gone — full ephemeral
survival, not just the projection.

## Bucket and instance strategy

Bucket is the entity type — exactly like `bondy_db_topology_shared_shards` —
and the realm is folded into the cell key by the facade (G-1). This lets the
topology declare `instances_strategy/0 => per_shard`: one oplog instance
(WAL + MST + applier) per shard, shared by every table on it and multiplexed by
the entity-type bucket. The per-`(EntityType, Shard)` ETS projections stay
separate (each table routes to its own handle); only the replication log is
shared per shard.
""").

-export([init/2]).
-export([open_table/4]).
-export([route/2]).
-export([bucket_for/3]).
-export([instances_strategy/0]).
-export([index_clear_scope/2]).
-export([primary_cell_scope/1]).
-export([close_table/2]).
-export([shutdown/1]).
-export([provision_cache/5]).
-export([release_cache/2]).

-define(PROJECTION_ADAPTER, bondy_oplog_projection_ets).
-define(CACHE_ADAPTER, bondy_oplog_cache_ets).

%% =============================================================================
%% bondy_db_topology callbacks
%% =============================================================================

init(DbName, Opts) when is_atom(DbName), is_map(Opts) ->
    %% No physical backing store. Any `sup`/`dir` in Opts (e.g. carried
    %% over from a leveled topology's opts) are ignored. We start a
    %% dedicated DB-scoped owner for the ETS tables (decoupled from the
    %% transient caller — see `bondy_db_topology_memory_owner`).
    case bondy_db_topology_memory_owner:start() of
        {ok, Owner} ->
            {ok, #{db_name => DbName, owner => Owner}};
        {error, _} = Err ->
            Err
    end.

open_table(EntityType, ShardCount, _TableOpts, State) when
    is_atom(EntityType), is_integer(ShardCount), ShardCount > 0
->
    #{db_name := DbName, owner := Owner} = State,
    case
        bondy_db_topology_memory_owner:open_table(
            Owner, DbName, EntityType, ShardCount
        )
    of
        {ok, Shards} ->
            TableState = #{
                entity_type => EntityType,
                shard_count => ShardCount,
                shards => Shards,
                owner => Owner
            },
            {ok, TableState, State};
        {error, _} = Err ->
            Err
    end.

route(Shard, #{shards := Shards}) when is_integer(Shard) ->
    case maps:find(Shard, Shards) of
        {ok, Handle} ->
            {ok, ?PROJECTION_ADAPTER, Handle};
        error ->
            {error, {unknown_shard, Shard}}
    end.

-doc """
The entity-type as a binary — exactly like `bondy_db_topology_shared_shards`.

The bucket carries the entity type (not the realm) so a `per_shard` instance can
multiplex its tables by bucket; the realm is folded into the cell key by the
facade (G-1) instead, isolating realms there. Each `(EntityType, Shard)` still
has its own ETS table, so the bucket also keeps a table's cells contiguous
within it.
""".
bucket_for(EntityType, Realm, _TableState) when
    is_atom(EntityType), is_binary(Realm)
->
    atom_to_binary(EntityType, utf8).

-doc """
One oplog instance per shard, shared by every table on it and multiplexed by the
entity-type bucket — the same collapse `bondy_db_topology_shared_shards` uses.
The per-table ETS projections stay separate (each table routes to its own
handle); only the WAL/MST/applier are shared per shard.
""".
instances_strategy() ->
    per_shard.

-doc """
Memory gives each `(EntityType, Shard)` its own ETS table (the ETS projection
adapter ignores the scope and clears its single backing table), so the
bare-suffix scope is exact — there is no co-located sibling to over-wipe.
""".
index_clear_scope(IndexName, _TableState) when is_atom(IndexName) ->
    {suffix, IndexName}.

-doc """
Memory is ETS-backed; its projection adapter does not export `cell_keys/2`, so
the rebuild always takes the MST walk and this scope is never consulted. A value
is returned only to satisfy the behaviour — `all_primary` matches the dedicated
per-`(EntityType, Shard)` ETS table conceptually.
""".
primary_cell_scope(_TableState) ->
    all_primary.

close_table(#{shards := Shards, owner := Owner}, State) ->
    %% The owner performs the whole-table `ets:delete/1` (the only
    %% process the VM permits to). State may be `undefined` here — the
    %% facade passes it that way on orderly teardown — so the owner pid
    %% is carried in TableState, not read back from State.
    ok = bondy_db_topology_memory_owner:close_table(Owner, Shards),
    {ok, State}.

shutdown(#{owner := Owner}) ->
    bondy_db_topology_memory_owner:stop(Owner).

-doc """
Host the per-shard read cache in the DB-scoped owner (the same process
that owns the projection tables) rather than the transient
`open_table/3` caller, so it survives caller death along with the
projection. Returns the owner pid — the facade also binds the
`bondy_oplog_core_registry` monitor to it.
""".
provision_cache(NS, Index, Shard, Opts, #{owner := Owner}) when
    is_atom(NS), is_atom(Index), is_integer(Shard), is_map(Opts)
->
    case
        bondy_db_topology_memory_owner:open_cache(
            Owner, ?CACHE_ADAPTER, NS, Index, Shard, Opts
        )
    of
        {ok, Handle} ->
            {ok, #{
                owner => Owner,
                adapter => ?CACHE_ADAPTER,
                handle => Handle
            }};
        {error, _} = Err ->
            Err
    end.

-doc """
Release a cache hosted by `provision_cache/5`. The owner performs the
whole-table `ets:delete/1` (the only process the VM permits to).
""".
release_cache(Handle, #{owner := Owner}) ->
    bondy_db_topology_memory_owner:close_cache(Owner, Handle).
