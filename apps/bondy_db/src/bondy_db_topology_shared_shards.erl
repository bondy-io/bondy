%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_topology_shared_shards).
-behaviour(bondy_db_topology).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Topology where **N Bookies are shared across every table**.

```
DB (shard_count = 16)
├── Bookie(0)            ← holds all tables' shard-0 data
│   ├── bucket=<<"t0">>  <<"R1",0,"k1">>  → frame
│   ├── bucket=<<"t1">>  <<"R1",0,"k7">>  → frame
│   └── ...
├── Bookie(1)            ← holds all tables' shard-1 data
│   └── ...
└── Bookie(15)
    └── ...
```

Each table calls `open_table/4` with the same `ShardCount`. The
topology starts N Bookies once (lazily, on first `open_table`) and
reuses them for every subsequent table. The bucket distinguishes
entity types within a Bookie; the facade folds the realm into the
storage key with a NUL separator (`<<Realm, 0, Key>>` — G-1), so each
realm's cells form a contiguous, scannable band within the bucket.

## Why this topology

- **`bondy_db_topology_per_entity`** allocates one Bookie per
  `(EntityType, Shard)` — high write parallelism but for 10 tables ×
  16 shards that's 160 Bookies per node, often too much for tests,
  embedded deployments, or Jepsen-style clusters where each shard
  costs disk + file-descriptors + memory.
- **`bondy_db_topology_single_bookie`** ignores `ShardCount` entirely
  and routes everything through one Bookie — fine for tiny tests but
  serialises every write across every table through one
  gen_server.
- **This topology** keeps the per-shard write-concurrency boundary
  (16 independent Bookie writer pipelines) while amortising the
  Bookie count across tables. 10 tables × 16 shards = still 16
  Bookies per node, not 160.

## Required `topology_opts`

| Key | Type | Meaning |
|---|---|---|
| `sup` | `pid()` | The `bondy_db_leveled_sup` Bookies live under |
| `dir` | `binary() \\| string()` | Root dir; each Bookie at `<Dir>/<shard>` |

Optional:

| Key | Default | Meaning |
|---|---|---|
| `book_opts_fun` | `default_book_opts/1` | leveled `book_start/1` opts builder |

The first `open_table/4` call decides the shard count for the whole
topology — subsequent `open_table/4` calls with a different
`ShardCount` are rejected with `{error, {shard_count_mismatch, _}}`.
This is intentional: the Bookies are *shared* across tables, so the
hash-to-shard map must be identical for every table or routing
becomes inconsistent.

## TableState shape

```erlang
#{
    entity_type := atom(),
    shard_count := pos_integer(),
    bucket      := binary(),
    shards      := #{Shard :: non_neg_integer() := {pt, term()}}
}
```

`shards` is a *view* of the topology-wide Bookies; the topology itself
owns the lifetime. Each value is a `bondy_db_leveled_sup:bookie_ref/2`
routing reference (NOT the raw pid): the projection adapter resolves it
per call through `persistent_term`, so a supervisor restart of a crashed
Bookie is transparently followed by every handle already in circulation
(readers AND the applier).

## Bucket

Bucket is the UTF-8 binary form of the entity type atom — same as
per_entity, since the Bookie already partitions by shard.
""").

-export([init/2]).
-export([open_table/4]).
-export([route/2]).
-export([bucket_for/3]).
-export([index_clear_scope/2]).
-export([primary_cell_scope/1]).
-export([instances_strategy/0]).
-export([close_table/2]).
-export([shutdown/1]).

-define(COMMON, bondy_db_topology_leveled_common).

%% =============================================================================
%% bondy_db_topology callbacks
%% =============================================================================

init(DbName, Opts) when is_atom(DbName), is_map(Opts) ->
    case maps:find(sup, Opts) of
        {ok, Sup} when is_pid(Sup) ->
            case maps:find(dir, Opts) of
                {ok, Dir} ->
                    BookOpts = maps:get(
                        book_opts_fun,
                        Opts,
                        fun ?COMMON:default_book_opts/1
                    ),
                    State = #{
                        db_name => DbName,
                        sup => Sup,
                        dir => ?COMMON:normalise_dir(Dir),
                        book_opts_fun => BookOpts,
                        %% Resolved on first `open_table/4`.
                        shard_count => undefined,
                        shards => #{}
                    },
                    {ok, State};
                error ->
                    {error, {missing_required_opt, dir}}
            end;
        _ ->
            {error, {missing_required_opt, sup}}
    end.

open_table(EntityType, ShardCount, _TableOpts, State0) when
    is_atom(EntityType), is_integer(ShardCount), ShardCount > 0
->
    case ensure_shards(ShardCount, State0) of
        {ok, Shards, State1} ->
            TableState = #{
                entity_type => EntityType,
                shard_count => ShardCount,
                shards => Shards
            },
            {ok, TableState, State1};
        {error, _} = Err ->
            Err
    end.

route(Shard, State) when is_integer(Shard) ->
    %% Shared with `bondy_db_topology_per_entity` via the common helper.
    ?COMMON:route(Shard, State).

-doc """
Shared-shards topology disambiguates EntityType by Bucket (the Bookie
holds every entity type). Realm is folded into the cell key by the
facade.
""".
bucket_for(EntityType, Realm, _TableState) when is_binary(Realm) ->
    atom_to_binary(EntityType, utf8).

-doc """
All tables on a shard share one oplog instance, routed by the entity-type
`Bucket` (`bucket_for/3` is realm-independent and `route/2` hands back one shared
Bookie per shard). See `bondy_db_topology:instances_strategy/0`.
""".
instances_strategy() ->
    per_shard.

-doc """
Shared-shards co-locates every entity type in the shared Bookies, so an index
wipe must be confined to this table's entity type — otherwise a sibling table
declaring the same `IndexName` would be over-wiped.
""".
index_clear_scope(IndexName, #{entity_type := ET}) when is_atom(IndexName) ->
    {entity, atom_to_binary(ET, utf8), IndexName}.

-doc """
Shared-shards co-locates every entity type in the shared Bookies, so the primary
cell directory must be scoped to this table's entity type (bucket = `ET`) —
otherwise the rebuild would fold a sibling table's cells. The realm is folded
into the cell key by the facade.
""".
primary_cell_scope(#{entity_type := ET}) ->
    {entity, atom_to_binary(ET, utf8)}.

close_table(_TableState, State) ->
    %% Bookies are shared — closing one table must not stop them; they
    %% stay up until `shutdown/1`. Returning `State` keeps the
    %% topology's Bookie pool intact for the surviving tables.
    {ok, State}.

shutdown(#{sup := Sup}) ->
    bondy_db_leveled_sup:stop(Sup).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Re-derive the N shared Bookies from the supervisor on EVERY
%% `open_table/4`. The pool must live in the (shared) supervisor, NOT in
%% this topology state: `bondy_db` discards the state we return
%% (`{ok, TableState, _NewState}`), so a pool kept here would not survive
%% to the next table — every table would start its own private Bookies
%% and the "shared" pool would never actually be shared. Keying each
%% Bookie by `{shard, K}` and using `get_or_start_bookie/3` makes the
%% supervisor the registry: the first table starts the pool, every later
%% table gets the same pids back.
%%
%% `ShardCount` agreement across tables is enforced against the
%% supervisor's current Bookie count: the first table fixes it; a later
%% table requesting a different count is rejected (a divergent
%% hash-to-shard map would corrupt routing).
ensure_shards(ShardCount, #{sup := Sup} = State) ->
    case bondy_db_leveled_sup:bookie_count(Sup) of
        0 ->
            get_or_start_shards(ShardCount, State);
        ShardCount ->
            get_or_start_shards(ShardCount, State);
        Existing ->
            {error,
                {shard_count_mismatch, [
                    {requested, ShardCount},
                    {existing, Existing}
                ]}}
    end.

%% @private
get_or_start_shards(ShardCount, State) ->
    case get_or_start_shards(0, ShardCount, State, #{}) of
        {ok, Shards} ->
            {ok, Shards, State#{
                shard_count := ShardCount,
                shards := Shards
            }};
        {error, _} = Err ->
            Err
    end.

get_or_start_shards(N, N, _State, Acc) ->
    {ok, Acc};
get_or_start_shards(
    I,
    N,
    #{
        sup := Sup,
        dir := Dir,
        book_opts_fun := BookOptsFun
    } = State,
    Acc
) ->
    ShardDir = shard_dir(Dir, I),
    case ?COMMON:ensure_dir(ShardDir) of
        ok ->
            BookOpts = BookOptsFun(ShardDir),
            case
                bondy_db_leveled_sup:get_or_start_bookie(
                    Sup, {shard, I}, BookOpts
                )
            of
                {ok, _Bookie} ->
                    %% Route by REFERENCE, not pid — the ref survives a
                    %% supervisor restart of the Bookie (crash recovery).
                    Ref = bondy_db_leveled_sup:bookie_ref(Sup, {shard, I}),
                    get_or_start_shards(I + 1, N, State, Acc#{I => Ref});
                {error, _} = Err ->
                    rollback_shards(Sup, Acc),
                    Err
            end;
        {error, _} = Err ->
            rollback_shards(Sup, Acc),
            Err
    end.

%% @private
%% Best-effort rollback of Bookies THIS call started. On the reuse path
%% `get_or_start_bookie/3` returns existing pids without error, so a rollback
%% only fires on the first (creating) table — never closing a pool a sibling
%% table is already using. Must go through `stop_bookie/2` (terminate +
%% delete + handle erase): a plain close would leave a `permanent` child for
%% the supervisor to immediately restart.
rollback_shards(Sup, Acc) ->
    _ = [
        bondy_db_leveled_sup:stop_bookie(Sup, {shard, I})
     || I <- maps:keys(Acc)
    ],
    ok.

shard_dir(Dir, Shard) ->
    filename:join([Dir, integer_to_list(Shard)]).
