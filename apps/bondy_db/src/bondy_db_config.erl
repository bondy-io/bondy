%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_config).
-behaviour(app_config).
-moduledoc """
Per-database configuration for `bondy_db`'s two databases (`main` |
`registry`). An implementation of the `app_config` behaviour, matching
`bondy_config`, `bondy_mst_config`, `bondy_wamp_config` and
`bondy_http_connector_config` — every value is read once at boot (`init/0`,
called from `bondy_db_sup`), cached in `persistent_term`, and never
re-read from the raw environment afterwards, so a runtime override must go
through `set/2`, not `application:set_env/3`.

Sourced from the Cuttlefish `db.main.*` / `db.registry.*` family
(`schema/bondy.schema`) via the single `databases` env key — Cuttlefish
translation targets are static strings fixed at schema-load time and
cannot be parameterised by `$name`, so every database's options fold into
one nested value: `#{DbName => #{oplog => #{Option => Value}}}`.

The only current consumer is `bondy_namespace_catalog` (in `bondy_router`,
which depends on `bondy_db`) — `bondy_db` itself is opts-driven everywhere
else (`open/2`, `open_table/3` take explicit option maps) and reads no
other application environment. This module exists to give the app that
composes `bondy_db` databases a typed, documented, single-default-per-key
surface to configure them through, rather than reaching into the raw
`databases` env shape directly.
""".

-define(APP, bondy_db).

-export_type([db_name/0]).

-type db_name() :: main | registry.

-export([init/0]).
-export([get/1]).
-export([get/2]).
-export([set/2]).
-export([oplog_shard_count/1]).
-export([oplog_partition_strategy/1]).
-export([oplog_realm_prefix_depth/1]).
-export([oplog_mst_retention/1]).
-export([oplog_on_topology_mismatch/1]).
-export([leveled_opts/0]).
-export([primary_scan_limit/0]).
-export([will_set/2]).
-export([on_set/2]).

-compile({no_auto_import, [get/1]}).

%% =============================================================================
%% API
%% =============================================================================

-doc "Initialises bondy_db configuration.".
-spec init() -> ok.

init() ->
    ok = app_config:init(?APP, #{callback_mod => ?MODULE}),
    ok.

-doc "Gets a config value by key.".
-spec get(Key :: list() | atom() | tuple()) -> term().

get(Key) ->
    app_config:get(?APP, Key).

-doc "Gets a config value by key, falling back to `Default` when unset.".
-spec get(Key :: list() | atom() | tuple(), Default :: term()) -> term().

get(Key, Default) ->
    app_config:get(?APP, Key, Default).

-doc """
Sets a config value at runtime. Test/operator override seam — updates both
the cached `persistent_term` value `get/1,2` reads and the underlying
`application` environment.
""".
-spec set(Key :: key_value:key() | tuple(), Value :: term()) -> ok.

set(Key, Value) ->
    app_config:set(?APP, Key, Value).

-doc "Shard count for `DbName` (default `16`).".
-spec oplog_shard_count(DbName :: db_name()) -> pos_integer().

oplog_shard_count(DbName) ->
    get([databases, DbName, oplog, shard_count], 16).

-doc """
Partition strategy for `DbName` (default `aggregate`). Only meaningful for
`main` — `registry` is ephemeral, has no on-disk manifest, and never sets
this key.
""".
-spec oplog_partition_strategy(DbName :: db_name()) ->
    aggregate | realm | entity.

oplog_partition_strategy(DbName) ->
    get([databases, DbName, oplog, partition_strategy], aggregate).

-doc """
Realm-prefix co-location depth for `DbName` (default `1`), used only when
`oplog_partition_strategy/1` is `realm`. `main`-only; see
`oplog_partition_strategy/1`.
""".
-spec oplog_realm_prefix_depth(DbName :: db_name()) -> pos_integer().

oplog_realm_prefix_depth(DbName) ->
    get([databases, DbName, oplog, realm_prefix_depth], 1).

-doc """
Boot behaviour when `DbName`'s on-disk topology manifest disagrees with the
configured topology (default `warn`). `main`-only; see
`oplog_partition_strategy/1`.
""".
-spec oplog_on_topology_mismatch(DbName :: db_name()) -> warn | stop.

oplog_on_topology_mismatch(DbName) ->
    get([databases, DbName, oplog, on_topology_mismatch], warn).

-doc """
MST-history retention policy for `DbName`'s per-shard op-log instances
(`db.<name>.retention.max_age_ms` / `.max_events`), or `undefined` when
both knobs are `0` — the DEFAULT: peer-confirmed compaction is the
primary history bound for ephemeral instances exactly as for durable
ones, and it never truncates an event a live peer still needs, which is
what keeps a live re-bootstrap's `replace`-mode install + rederive a
complete remedy. Retention is an explicit opt-in OVERLOAD BACKSTOP
(`registry`-only, fused-only): it truncates by local age/size when the
confirmed frontier yields nothing, at the cost of that soundness
invariant — a peer lagging past the window must recover via catalogue
re-bootstrap, and cells clobbered outside the retained window cannot be
restored by rederive. Durable databases are never retention-bounded.
""".
-spec oplog_mst_retention(DbName :: db_name()) ->
    #{max_age_ms := non_neg_integer(), max_events := non_neg_integer()}
    | undefined.

oplog_mst_retention(DbName) ->
    Policy = get([databases, DbName, oplog, retention], #{}),
    MaxAge = maps:get(max_age_ms, Policy, 0),
    MaxEvents = maps:get(max_events, Policy, 0),
    case {MaxAge, MaxEvents} of
        {0, 0} -> undefined;
        _ -> #{max_age_ms => MaxAge, max_events => MaxEvents}
    end.

-doc """
Maximum number of primary cells a single stale-index fallback read will
enumerate (default 1,000,000).

When an index is stale, `bondy_db` answers the query by scanning every
primary cell in the realm and recomputing each value's index terms. This
bounds that scan so the "slow but correct" path cannot run unbounded.

A scan that fills the cap returns a **potentially incomplete** result and
logs a warning; the caller is not told. Deployments whose realms hold more
cells than this should raise it, since the right value follows from realm
size and nothing else.
""".
-spec primary_scan_limit() -> pos_integer().

primary_scan_limit() ->
    get(primary_scan_limit, 1_000_000).

-doc """
Tunable `leveled_bookie:book_start/1` options, sourced from the
`db.leveled.*` Cuttlefish family.

Global rather than per-database: every durable Bookie a node starts uses
the same values, matching how `db.wal.*` behaves. The ephemeral
`registry` database keeps its projection in memory and starts no Bookie,
so none of these apply to it.

Two options are deliberately absent, because `bondy_db` fixes them rather
than exposing them:

- `root_path` is derived per Bookie by the topology from the data
  directory. An operator-supplied value would collide across shards.
- `head_only` must be `with_lookup`. `bondy_db_projection_leveled` is
  built on `book_headonly/4` and `book_mput/2`, and `book_get`/`book_put`
  are unsupported under that flag, so any other value only breaks the
  adapter.

Every default is leveled's own (`?OPTION_DEFAULTS` in `leveled_bookie`),
which applied before by omission, with two exceptions.

`cache_size` stays at 2000, the value `bondy_db` has always passed. It sits
20% under leveled's 2500 and the difference is not worth a behaviour change.

`max_journalsize` is leveled's 1 GB rather than the 100 MB `bondy_db`
previously passed. That 100 MB came from a default the code itself
described as tuned for fast tests, and it costs a large store ten times the
journal files, file handles and compaction runs it needs. The option is the
inker's roll threshold for the head file, not a format parameter, so raising
it leaves sealed journals untouched and only makes files rolled from now on
larger.
""".
-spec leveled_opts() -> proplists:proplist().

leveled_opts() ->
    [
        %% Ledger cache and journal sizing.
        {cache_size, get(leveled_cache_size, 2000)},
        {cache_multiple, get(leveled_cache_multiple, 2)},
        {max_journalsize, get(leveled_max_journalsize, 1_000_000_000)},
        {max_journalobjectcount, get(leveled_max_journalobjectcount, 200_000)},
        {max_pencillercachesize, get(leveled_max_pencillercachesize, 28_000)},
        {max_mergebelow, get(leveled_max_mergebelow, 24)},
        {ledger_preloadpagecache_level,
            get(leveled_ledger_preloadpagecache_level, 4)},

        %% Durability.
        {sync_strategy, get(leveled_sync_strategy, none)},

        %% Journal compaction.
        {waste_retention_period,
            optional(get(leveled_waste_retention_period, off))},
        {max_run_length, optional(get(leveled_max_run_length, default))},
        {singlefile_compactionpercentage,
            get(leveled_singlefile_compactionpercentage, 30.0)},
        {maxrunlength_compactionpercentage,
            get(leveled_maxrunlength_compactionpercentage, 70.0)},
        {journalcompaction_scoreonein,
            get(leveled_journalcompaction_scoreonein, 1)},

        %% Compression.
        {compression_method, get(leveled_compression_method, lz4)},
        {compression_point, get(leveled_compression_point, on_receipt)},
        {compression_level, get(leveled_compression_level, 1)},
        {ledger_compression, get(leveled_ledger_compression, as_store)},

        %% Snapshots.
        {snapshot_timeout_short, get(leveled_snapshot_timeout_short, 900)},
        {snapshot_timeout_long, get(leveled_snapshot_timeout_long, 43_200)},

        %% Logging and statistics.
        {log_level, get(leveled_log_level, info)},
        {stats_percentage, get(leveled_stats_percentage, 10)},
        {stats_logfrequency, get(leveled_stats_logfrequency, 30)}
    ].


%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
%% Leveled spells two different absences as `undefined`: "retain no waste
%% on compaction" and "use the built-in compaction run length of 8".
%% Neither is a value an operator can write in a `.conf` file, so the
%% schema takes `off` and `default` respectively and this maps either
%% back.
optional(off) -> undefined;
optional(default) -> undefined;
optional(Value) -> Value.


-spec will_set(Key :: key_value:key(), Value :: any()) ->
    ok | {ok, NewValue :: any()} | {error, Reason :: any()}.

will_set(_, _) ->
    ok.

-spec on_set(Key :: key_value:key(), Value :: any()) -> ok.

on_set(_, _) ->
    ok.
