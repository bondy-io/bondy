%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_topology_single_bookie).
-behaviour(bondy_db_topology).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Degenerate reference topology: one leveled Bookie for the whole DB.

```
DB
└── Bookie(single)
    ├── bucket=<<"users">>   <<"R1/alice">>  → frame
    ├── bucket=<<"users">>   <<"R1/bob">>    → frame
    ├── bucket=<<"users">>   <<"R2/carol">>  → frame
    └── bucket=<<"tokens">>  <<"R1/tok-1">>  → frame
```

The Bookie is owned by the topology and shared across every table and
shard. Buckets are keyed by `EntityType` only; realms are encoded into
the key by the facade as `<<Realm/binary, "/", UserKey/binary>>` so
the substrate sees a per-(entity, shard) keyspace without a separate
bucket per realm.

## When to use it

- **Tests** — one filesystem location, one process to clean up.
- **Tiny deployments** — entire DB fits inside one Bookie's
  write-serialised journal pipeline.
- **Bootstrap measurements** — establishes a single-Bookie baseline
  against which sharded topologies can be empirically compared.

NOT suitable when write concurrency matters: every write across every
shard, table, and realm serialises through the single Bookie's
gen_server.

## Required `topology_opts`

| Key | Type | Meaning |
|---|---|---|
| `sup` | `pid()` | The `bondy_db_leveled_sup` the Bookie is spawned under |
| `dir` | `binary() \\| string()` | Where leveled lays out its journal + ledger |

Optional:

| Key | Default | Meaning |
|---|---|---|
| `book_opts_fun` | `default_book_opts/1` | `fun((Dir) -> proplists:proplist())` builder for leveled's `book_start/1` opts |

## State + TableState

This topology starts the Bookie eagerly inside `init/2` so every table
shares it. `TableState` is
`#{bookie := Pid, entity_type := atom(), bucket := binary()}`;
`route/2` returns the same per-shard projection-adapter handle for every
shard, pointing at the shared Bookie with the table's bucket.

`close_table/2` is a no-op (the Bookie stays up until `shutdown/1`),
so opening and closing tables is cheap.

## Bucket format

```
EntityType (UTF-8 binary form of the atom)
```

Realm is folded into the cell key by the facade, not the bucket — the
bucket only disambiguates between entity types inside the single
Bookie.
""").

-export([init/2]).
-export([open_table/4]).
-export([route/2]).
-export([bucket_for/3]).
-export([index_clear_scope/2]).
-export([primary_cell_scope/1]).
-export([close_table/2]).
-export([shutdown/1]).

-define(PROJECTION_ADAPTER, bondy_db_projection_leveled).
-define(COMMON, bondy_db_topology_leveled_common).

%% =============================================================================
%% bondy_db_topology callbacks
%% =============================================================================

init(DbName, Opts) when is_atom(DbName), is_map(Opts) ->
    case maps:find(sup, Opts) of
        {ok, Sup} when is_pid(Sup) ->
            case maps:find(dir, Opts) of
                {ok, Dir0} ->
                    Dir = ?COMMON:normalise_dir(Dir0),
                    BookOptsFun = maps:get(
                        book_opts_fun,
                        Opts,
                        fun ?COMMON:default_book_opts/1
                    ),
                    case ?COMMON:ensure_dir(Dir) of
                        ok ->
                            case
                                bondy_db_leveled_sup:start_bookie(
                                    Sup, BookOptsFun(Dir)
                                )
                            of
                                {ok, Bookie} ->
                                    {ok, #{
                                        db_name => DbName,
                                        sup => Sup,
                                        dir => Dir,
                                        bookie => Bookie
                                    }};
                                {error, _} = Err ->
                                    Err
                            end;
                        {error, _} = Err ->
                            Err
                    end;
                error ->
                    {error, {missing_required_opt, dir}}
            end;
        _ ->
            {error, {missing_required_opt, sup}}
    end.

open_table(
    EntityType,
    _ShardCount,
    _TableOpts,
    #{bookie := Bookie} = State
) when
    is_atom(EntityType)
->
    %% Single_bookie ignores ShardCount at the physical level (there is
    %% only one Bookie); the facade still hashes keys into `shard_count`
    %% slots, but every shard for this topology routes to the same
    %% Bookie. Bucket disambiguation happens via `bucket_for/3`, which
    %% composes `(EntityType, Realm)` since neither the Bookie nor the
    %% NS isolates them.
    TableState = #{
        bookie => Bookie,
        entity_type => EntityType
    },
    {ok, TableState, State}.

route(_Shard, #{bookie := Bookie}) ->
    Handle = #{bookie => Bookie},
    {ok, ?PROJECTION_ADAPTER, Handle}.

-doc """
Single-bookie topology: one Bookie holds every table for every realm.
The Bucket must therefore disambiguate both — `<<Realm, "/", EntityType>>`.
""".
bucket_for(EntityType, Realm, #{entity_type := EntityType}) when
    is_binary(Realm)
->
    <<Realm/binary, "/", (atom_to_binary(EntityType, utf8))/binary>>.

-doc """
Single-bookie holds every table for every realm in one Bookie, so an index wipe
must be confined to this table's entity type — otherwise a co-located table
declaring the same `IndexName` would be over-wiped.
""".
index_clear_scope(IndexName, #{entity_type := ET}) when is_atom(IndexName) ->
    {entity, atom_to_binary(ET, utf8), IndexName}.

-doc """
Single-bookie co-locates every table in one Bookie, so the primary cell
directory must be scoped to this table's entity type — its bucket is
`<<Realm,"/",ET>>`, so the rebuild folds only buckets ending with `/ET`.
""".
primary_cell_scope(#{entity_type := ET}) ->
    {entity, atom_to_binary(ET, utf8)}.

close_table(_TableState, State) ->
    %% No-op: the Bookie is shared and outlives table close. Stopping
    %% the Bookie here would break every other table that has not yet
    %% been closed.
    {ok, State}.

shutdown(#{sup := Sup, bookie := Bookie}) ->
    %% Tell leveled to flush + close before bringing the supervisor
    %% down, tolerating an already-dead Bookie. `stop/1` then reaps
    %% whatever supervisor children remain.
    ok = ?COMMON:stop_bookie_safe(Bookie),
    bondy_db_leveled_sup:stop(Sup).
