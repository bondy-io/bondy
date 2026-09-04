%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Consumer-facing **cell-mechanics facade**, substrate-backed.

`bondy_db` decouples the user-visible model (DB → tables → cells keyed
by `(Realm, Key)`) from the physical layout (which Bookie owns which
shard, which bucket holds which entity type) via the
`bondy_db_topology` behaviour, and wires writes through the substrate
WAL+applier and reads through `bondy_oplog_core`'s cache + projection
merge.

## Substrate wiring

`open_table/3` provisions, **per shard**:

1. A projection adapter handle from the topology
   (`Topology:route(Shard, TableState)`). The handle spans every realm
   in the shard; realm isolation is done by encoding `Realm` into the
   cell key.
2. A per-shard read cache. By default this is a `bondy_oplog_cache_ets`
   table owned by the calling process. A topology that needs its
   per-shard resources to outlive the transient `open_table/3` caller
   (an ephemeral in-memory topology) instead exports `provision_cache/5`
   and hosts the cache in a long-lived owner — see `acquire_cache/4`.
3. A registry entry in `bondy_oplog_core_registry` mapping
   `(Namespace, primary, Shard)` to the
   `{cache_adapter, cache_handle, projection_adapter, projection_handle,
   fold_module}` tuple. The registry's owner-monitor is bound to the
   cache's owner (the caller by default, the topology's resource owner
   when hosted), so the row's lifetime tracks the resources it points
   at.
4. A `bondy_oplog_instance` with `cell_apply_target =>
   {Namespace, primary, Shard}` so the applier writes the projection
   on every replayed `{cell_apply, _, _, _}` event.

The `Namespace` atom is derived deterministically as
`list_to_atom(atom_to_list(DbName) ++ "_" ++ atom_to_list(EntityType))`
so two DBs with a colliding `EntityType` on the same node get distinct
substrate identities.

## Realm → Bucket and storage-key mapping (G-1)

Realm separation happens in one of two places, decided by the topology.
The facade asks the topology — via
`Topology:bucket_for(EntityType, Realm, TableState)` — for the
storage-layer **Bucket**, then derives the **storage key** with
`cell_key/3`:

- **Realm-in-bucket** topologies (`per_entity`: `Bucket = Realm`;
  `single_bookie`: `Bucket = <<Realm, "/", EntityType>>`) are already
  realm-separated at the bucket, so the storage key is the caller's
  `Key`, verbatim.
- **Realm-in-key** topologies (`shared_shards`, `memory`) use the bare
  EntityType as the Bucket — so a per-shard instance can multiplex
  tables by bucket — and the facade folds the realm into the storage
  key instead: `<<Realm/binary, 0, Key/binary>>` (G-1). The NUL
  separator makes realm-scoped scans a contiguous band
  (`[<<Realm,0>>, <<Realm,1>>)`) because realm URIs are NUL-free text;
  the caller's key bytes after the separator are preserved verbatim.

Either way the facade calls `bondy_oplog_core` with
`(NS, primary, Bucket, StorageKey)`, and range scans fold their bounds
the same way (`realm_scan_range/2`). This key encoding is an on-disk
contract, versioned by the topology manifest's `key_encoding_version`.

## Write path

`apply/4` builds `{cell_apply, Bucket, Key, FoldEvent}` and calls
`bondy_oplog:append/2`. The fold-state update happens inside the
applier: the applier reads the current cell
frame, decodes via the fold module, folds the event in via
`apply_event/3`, encodes the new state, and writes it back through the
projection adapter with Bucket and Key as separate operands. After
the append, `apply/4` calls `bondy_oplog:await_apply/1` so the next
`read/3` from the same caller sees the updated cell.

## Read path

`read/3` calls `bondy_oplog_core:read/4`. That goes through:

1. Per-shard cache — a hit returns immediately.
2. Cache miss — read the projection, decode, populate the cache,
   return.

Overlay merging is disabled at the facade level — the shard is
registered with `overlay = disabled`. Read-your-writes is provided by
`apply/4`'s `await_apply` step, not by an overlay merge.

## Lifecycle

```erlang
{ok, Db} = bondy_db:open(my_db, #{
    topology      => bondy_db_topology_per_entity,
    topology_opts => #{sup => MySup, dir => <<"/var/lib/bondy_db">>},
    shard_count   => 8,
    fold_module   => lww_register
}),

{ok, Users}  = bondy_db:open_table(Db, users,  #{}),
{ok, Tags}   = bondy_db:open_table(Db, tags,   #{
    fold_module => g_set
}),

%% Values are domain terms — the substrate serialises them; the write HLC is
%% stamped for you. A read returns the decoded value with its HLC.
ok = bondy_db:apply(Users, <<"r1">>, <<"alice">>, {set, #{name => <<"Alice">>}}),
{ok, {#{name := <<"Alice">>}, _Hlc}} =
    bondy_db:read(Users, <<"r1">>, <<"alice">>),

%% A cleared (or never-written) cell:
ok = bondy_db:apply(Users, <<"r1">>, <<"alice">>, clear),
{error, not_found} = bondy_db:read(Users, <<"r1">>, <<"alice">>),

ok = bondy_db:close_table(Users),
ok = bondy_db:close_table(Tags),
ok = bondy_db:close(Db).
```

`close_table/1` stops the per-shard oplog instances, unregisters the
shards from `bondy_oplog_core_registry`, deletes the per-shard caches,
and asks the topology to release its physical resources for the table.
`close/1` then shuts down the topology (and any Bookies still owned by
it).
""").

-export([apply/4]).
-export([apply_async/4]).
-export([apply_batch/4]).
-export([apply_batch_async/4]).
-export([apply_many/1]).
-export([await/3]).
-export([await_index/2]).
-export([close/1]).
-export([close_table/1]).
-export([cold_start_table_indexes/1]).
-export([counter_inc/4]).
-export([delete/3]).
-export([ensure_fresh/2]).
-export([index_get/5]).
-export([index_lag/2]).
-export([index_prefix/5]).
-export([index_prefix_range/6]).
-export([index_range/6]).
-export([info/1]).
-export([list/2]).
-export([fold_all/4]).
-export([map_update/4]).
-export([namespace/1]).
-export([open/2]).
-export([open_table/3]).
-export([probe_write/1]).
-export([publish_event/1]).
-export([range/5]).
-export([range_all/5]).
-export([read/3]).
-export([rebuild_index/2]).
-export([rebuild_indexes/1]).
-export([reconcile/4]).
-export([shard_count/1]).
-export([shard_for/3]).
-export([start_draining/1]).
-export([tick/1]).

-export_type([db/0, table/0, realm/0, entry/0, row/0]).

-ifdef(TEST).
%% Exposed so the fused-writer rollout can pin the `fused ⇒ ephemeral`
%% guard directly, without spinning a durable (leveled) Bookie just to
%% reach its rejection branch.
-export([assert_fused_requires_ephemeral/2]).
%% Exposed so the strategy-aware routing can be pinned directly without
%% standing up real shards. (`shard_for/3` is now a public API — see above.)
-export([aggregate_root/2]).
-endif.

-define(DEFAULT_SHARD_COUNT, 8).
-define(INDEX, primary).

%% Topologies that fold the realm into the storage KEY rather than isolating
%% it by bucket. The full rationale, and the NUL-separator invariant it rests
%% on, live with `cell_key/3` further down.
-define(FOLDS_REALM(Topology),
    (Topology =:= bondy_db_topology_shared_shards orelse
        Topology =:= bondy_db_topology_memory)
).

%% Reserved bucket/key for the latency idle probe. A bucket no user query
%% targets (reads/ranges scope to a realm-derived bucket via
%% `Topology:bucket_for/3`), so the probe cell is naturally invisible to
%% end users without any read-path filtering. The same `(Bucket, Key)` is
%% reused every probe → one bounded reserved cell per instance.
-define(PROBE_BUCKET, <<"$probe">>).
-define(PROBE_KEY, <<"$probe">>).
-define(PROBE_TOKEN, <<"$probe">>).

-type realm() :: binary().

%% A point read's result: the cell's decoded value paired with the HLC at
%% which it was last written.
-type entry() :: {Value :: term(), Hlc :: bondy_oplog_hlc:hlc()}.

%% A range / list row: a key with its decoded value and write HLC.
-type row() :: {Key :: binary(), Value :: term(), Hlc :: bondy_oplog_hlc:hlc()}.

-type db() :: #{
    name := atom(),
    topology := module(),
    topology_state := bondy_db_topology:state(),
    %% DB-scoped projection provider for `projection_backend => ets`
    %% tables. `undefined` when the DB topology is itself
    %% `bondy_db_topology_memory` (it is its own provider); otherwise a
    %% `bondy_db_topology_memory` state created at `open/2`.
    ets_provider := bondy_db_topology:state() | undefined,
    opts := map(),
    hlc := bondy_oplog_hlc:t()
}.

-type projection_backend() :: leveled | ets.

-type table() :: #{
    db_name := atom(),
    %% The **effective** projection topology for this table: the DB's
    %% topology for `leveled` tables, `bondy_db_topology_memory` for
    %% `ets` (ephemeral) tables. Every read/write/range/teardown path
    %% resolves bucket + route + cache + owner through it, so an ephemeral
    %% table inside a leveled DB needs no special-casing downstream.
    db_topology := module(),
    db_hlc := bondy_oplog_hlc:t(),
    entity_type := atom(),
    namespace := atom(),
    shard_count := pos_integer(),
    fold_module := module() | atom(),
    projection_backend := projection_backend(),
    table_state := bondy_db_topology:table_state(),
    instance_ids := #{non_neg_integer() := binary()},
    cache_handles := #{non_neg_integer() := term()},
    %% Secondary indexes declared via `open_table` `indexes => [Spec]`,
    %% keyed by index name. Each is an independent term-sharded shard-set
    %% under `(Namespace, IndexName, SecShard)`, on the same projection
    %% backend as this table (ets if ephemeral, leveled if durable) — see
    %% `index_provision/0`.
    indexes := #{atom() := index_provision()}
}.

%% A provisioned secondary index: its declarative spec, secondary shard
%% count, the effective topology + table state that own its projection
%% tables (the table's own backend — ets or leveled), and the
%% per-secondary-shard cache handles.
-type index_provision() :: #{
    spec := bondy_oplog_index_spec:spec(),
    sec_shard_count := pos_integer(),
    topology := module(),
    table_state := bondy_db_topology:table_state(),
    cache_handles := #{non_neg_integer() := term()},
    %% Per-secondary-shard `bondy_oplog_secondary_writer` pid.
    writer_pids := #{non_neg_integer() := pid()}
}.

%% =============================================================================
%% API
%% =============================================================================

-doc """
Open a DB instance named `Name` against the topology in `Opts`.

Required keys in `Opts`:

| Key | Type | Meaning |
|---|---|---|
| `topology` | `module()` | A module implementing `bondy_db_topology` |

Optional keys (cascade to table defaults):

| Key | Default | Meaning |
|---|---|---|
| `topology_opts` | `#{}` | Passed to `Topology:init/2` |
| `shard_count` | `8` | Default shard count for tables |
| `fold_module` | `lww_register` | Default fold strategy |

Returns the opaque `Db` handle. Callers MUST eventually call `close/1`
to release the topology's physical resources.
""".
-spec open(Name :: atom(), Opts :: map()) -> {ok, db()} | {error, term()}.

open(Name, Opts) when is_atom(Name), is_map(Opts) ->
    case maps:find(topology, Opts) of
        {ok, Topology} when is_atom(Topology) ->
            TopologyOpts = maps:get(topology_opts, Opts, #{}),
            case Topology:init(Name, TopologyOpts) of
                {ok, State} ->
                    case ensure_ets_provider(Name, Topology) of
                        {ok, EtsProvider} ->
                            Db = #{
                                name => Name,
                                topology => Topology,
                                topology_state => State,
                                ets_provider => EtsProvider,
                                opts => Opts,
                                hlc => bondy_oplog_hlc:new()
                            },
                            {ok, Db};
                        {error, _} = Err ->
                            _ = Topology:shutdown(State),
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        error ->
            {error, {missing_required_opt, topology}}
    end.

%% @private
%% A DB-scoped projection provider for `projection_backend => ets`
%% (ephemeral) tables. A `bondy_db_topology_memory` DB already is one —
%% its own owner serves every table — so it needs no separate provider
%% (`undefined`). Any other topology gets a dedicated
%% `bondy_db_topology_memory` state (one owner gen_server per DB), used
%% only when an ephemeral table is opened and torn down in `close/1`.
ensure_ets_provider(_Name, bondy_db_topology_memory) ->
    {ok, undefined};
ensure_ets_provider(Name, _Topology) ->
    bondy_db_topology_memory:init(Name, #{}).

-doc """
Open a logical table for `EntityType` inside `Db`.

The topology provisions the per-shard projection-adapter handles. The
facade then registers each `(Namespace, primary, Shard)` triple with
`bondy_oplog_core_registry`, starts a `bondy_oplog_instance` per shard
with the substrate write-path wired up, and stashes the resulting
state in the `Table` handle.

Per-table `Opts` override DB-level defaults. The merged `Opts` MUST
include `fold_module`. The chosen fold module determines:

- the cell state representation (`encode_state/1` / `decode_state/1`),
- the event shape accepted by `apply/4`,
- the conflict-resolution rules used during the applier's
  read-modify-write.

## Projection backend (durable vs ephemeral)

`projection_backend => leveled | ets` selects this table's projection
storage, independently per table — so one DB can mix durable and
ephemeral tables:

- `leveled` (default on leveled topologies) — the DB's topology
  provisions a durable leveled projection, as today.
- `ets` (default on `bondy_db_topology_memory`) — an in-RAM
  `bondy_oplog_projection_ets` projection, hosted in the DB's
  `bondy_db_topology_memory` provider; nothing for this table is
  written to disk.

A `projection_backend => ets` table is only fully **ephemeral** when the
rest of its stack is in-memory too. The knobs are low-level and the
caller is responsible for keeping them consistent — set them in the
per-table `oplog_instance_opts` (which replaces, not merges into, the
DB-level one):

```erlang
open_table(Db, registrations, #{
    projection_backend => ets,
    oplog_instance_opts => #{
        backend => ets,          %% in-memory MST store
        durability => ephemeral  %% acknowledge no durable storage;
                                 %% silences the no-storage warning
    }
    %% and NO storage_path anywhere in the cascade
}).
```

`durability => ephemeral` is the explicit "no durable storage is
intended" acknowledgement — it suppresses the loud
`bondy_oplog_instance_sup` warning that otherwise flags a missing
`storage_path` as a kill-restart footgun. It does **not** itself pin
the stack in-memory: it is the caller's `projection_backend => ets` +
`backend => ets` + absent `storage_path` that do that. The WAL still
writes (and fsyncs) to a per-PID tmp path
(`/tmp/bondy_oplog_wal/<os_pid>/...`); ephemerality across a restart
comes from that path being `os:getpid()`-namespaced — a fresh BEAM
never replays the prior run's segments — not from the WAL being
non-durable within a run.
""".
-spec open_table(
    Db :: db(),
    EntityType :: atom(),
    Opts :: map()
) -> {ok, table()} | {error, term()}.

open_table(
    #{topology := Topology} = Db,
    EntityType,
    Opts
) when
    is_atom(EntityType), is_map(Opts)
->
    Merged = merge_opts(maps:get(opts, Db), Opts),
    case maps:find(fold_module, Merged) of
        {ok, FoldModule} when is_atom(FoldModule) ->
            case resolve_backend(Topology, Merged) of
                {ok, Backend} ->
                    {EffTopology, EffState} =
                        effective_topology(Backend, Db),
                    open_table(
                        Db,
                        EntityType,
                        Merged,
                        FoldModule,
                        Backend,
                        EffTopology,
                        EffState
                    );
                {error, _} = Err ->
                    Err
            end;
        error ->
            {error, {missing_required_opt, fold_module}}
    end.

%% @private
open_table(Db, EntityType, Merged, FoldModule, Backend, Topology, State) ->
    %% Validate any declared index specs up front, before provisioning a
    %% single primary shard — a bad spec must not churn instances/Bookies.
    case validate_index_specs(maps:get(indexes, Merged, [])) of
        ok ->
            open_table_provision(
                Db, EntityType, Merged, FoldModule, Backend, Topology, State
            );
        {error, _} = Err ->
            Err
    end.

%% @private
open_table_provision(
    Db, EntityType, Merged, FoldModule, Backend, Topology, State
) ->
    ShardCount = maps:get(shard_count, Merged, ?DEFAULT_SHARD_COUNT),
    %% Strategy-aware shard routing inputs, threaded into the
    %% table state and consumed by `shard_for/3`. The defaults reproduce the
    %% legacy `phash2({Bucket, Key})` placement (strategy `entity`), so a
    %% table declaring neither routes exactly as before.
    PartitionStrategy = maps:get(partition_strategy, Merged, entity),
    RealmPrefixDepth = maps:get(realm_prefix_depth, Merged, 1),
    AggregateRoot = maps:get(aggregate_root, Merged, identity),
    DbName = maps:get(name, Db),
    NS = namespace_atom(DbName, EntityType),
    %% Default the applier's OldValue frame-cache ON for durable
    %% (leveled) projections and OFF for ephemeral (ets) ones. The cache
    %% elides the projection journal read on the per-cell write path: for
    %% leveled that read hits the on-disk journal — the dominant per-shard
    %% durable-write cost (~+47% throughput when cached, measured on Fly
    %% Linux: cell_apply 42ms → 7.5ms) — while for ets the OldValue read is
    %% already in-memory, so the cache is pure overhead. A caller-supplied
    %% `oldstate_cache` (under `oplog_instance_opts.applier`) always wins.
    OplogOpts0 = default_oldstate_cache_opt(
        maps:get(oplog_instance_opts, Merged, #{}), Backend
    ),
    %% Ephemeral fused-writer opt-in (fused-writer rollout, Step 1).
    %% Only an ephemeral (ets projection) table may fuse the applier
    %% `cell_apply` with the instance MST install into one process; a
    %% durable (leveled) table MUST keep the two-process split. The
    %% authoritative ephemeral signal is the resolved projection
    %% `Backend`, not the caller's `durability` acknowledgement — so
    %% the gate lives here, where `Backend` is known. Fail fast at open,
    %% not at the first fused write. Threaded into the instance opts so
    %% each shard's instance records + republishes it; nothing reads it
    %% for behaviour yet (the durable pipeline is untouched).
    Fused = maps:get(fused, Merged, false),
    ok = assert_fused_requires_ephemeral(Fused, Backend),
    %% Retention-bounded MST history (`mst_retention` under
    %% `oplog_instance_opts`) is fused-only — and fused is ephemeral-only
    %% (asserted above) — so a durable table can never be retention-bounded.
    %% The instance re-validates at start; asserting here too makes the
    %% failure a crisp open_table error rather than a child-start crash.
    ok = assert_mst_retention_requires_fused(
        maps:get(mst_retention, OplogOpts0, undefined), Fused
    ),
    %% The DB every shard instance belongs to, carried in the instance opts
    %% so `bondy_oplog:db_of/1` can answer it from the registry row instead
    %% of parsing it back out of the instance id — which would make
    %% `bondy_oplog` depend on this module's id-composition convention.
    OplogOpts1 = OplogOpts0#{fused => Fused, db => DbName},
    %% Opt-in change-notification (`publish => true`): wire every shard's
    %% applier to publish each verified apply (local OR AE-replicated) to the
    %% table namespace via `bondy_oplog_core:publish/4`, so a reactor can
    %% `subscribe(NS, _)` and react (e.g. the API Gateway cowboy-dispatch
    %% rebuild). Off by default — only tables with a reactor pay the cost.
    OplogOpts = maybe_enable_publish(OplogOpts1, NS, Merged),
    %% Native operation-based CRDT for the cell projection. An explicit
    %% `crdt_module` wins; otherwise the `fold_module` is mapped to its
    %% native op-based twin via
    %% `bondy_oplog_cell_kernel:default_crdt_for_fold/1` (every former
    %% fold has a byte-identical CRDT twin, so durable cells decode either
    %% way). An unknown label maps to `undefined`; the kernel's
    %% `from_modules/2` then errors at open. Threaded only into the registry
    %% Config (not the oplog instance opts — that would engage the
    %% monolithic CRDT path).
    CrdtModule =
        case maps:get(crdt_module, Merged, undefined) of
            undefined ->
                bondy_oplog_cell_kernel:default_crdt_for_fold(FoldModule);
            ExplicitCrdt ->
                ExplicitCrdt
        end,
    %% Optional per-table construction config for `CrdtModule`, for a CRDT
    %% that needs more than an event to build its bottom state (e.g.
    %% `bondy_oplog_crdt_struct`'s schema) — see
    %% `bondy_oplog_cell_kernel:init/2`. `#{}` for every other CRDT.
    CrdtOpts = maps:get(crdt_opts, Merged, #{}),
    %% Fail fast: a `tier_2` CRDT MUST be `order_independent` (its eager
    %% `apply_op` must equal the group `interpret_cog`, since the DVV join
    %% is commutative). Catches a mis-declared module at open, not at the
    %% first silent divergence.
    ok = assert_causal_tier_consistency(CrdtModule),
    %% Static secondary-index descriptors (already validated). The primary
    %% appliers need them at start to term-diff and dispatch index updates;
    %% the live writers they dispatch to are resolved from the registry, so
    %% the descriptors only carry the spec + secondary shard count.
    SecIndexes = index_descriptors(
        maps:get(indexes, Merged, []), ShardCount, Topology
    ),
    case Topology:open_table(EntityType, ShardCount, Merged, State) of
        {ok, TableState, _NewState} ->
            case
                provision_shards(
                    NS,
                    DbName,
                    EntityType,
                    ShardCount,
                    FoldModule,
                    CrdtModule,
                    CrdtOpts,
                    OplogOpts,
                    SecIndexes,
                    Topology,
                    TableState
                )
            of
                {ok, InstanceIds, CacheHandles} ->
                    case
                        provision_indexes(Db, NS, Merged, ShardCount, Backend)
                    of
                        {ok, IndexMap} ->
                            %% Cold-start index recovery. For each index, load
                            %% every shard's durable trust marker
                            %% (`index_load_rebuild_marker/1`): a shard that is
                            %% built + clean (marker present, kept complete
                            %% `<= snapshot_wm` by the compaction flush barrier)
                            %% is TRUSTED and only freshened; a shard with no
                            %% marker (a newly-declared index, or one left
                            %% incomplete by a pre-restart drop, or any
                            %% ephemeral/ETS shard whose cells were wiped on
                            %% restart) is REBUILT from the primary. This
                            %% replaces the old unconditional O(table) backfill —
                            %% the common durable restart is now trust + bounded
                            %% tail-replay, never a full re-derive. Freshening
                            %% (or the rebuild's own freshen) keeps a finite
                            %% `max_lag` read passing even on an empty shard.
                            ok = assert_durable_rebuild_invariant(
                                Backend, IndexMap
                            ),
                            %% Defer the index cold-start barrier when the
                            %% founding instance's WAL drain is GATED. The
                            %% barrier `await_drain`s the primary, but a gated
                            %% drain never reaches end-of-log, so running it here
                            %% would DEADLOCK; and the founding instance is
                            %% shared across tables, so draining before the
                            %% siblings register would replay the shared WAL with
                            %% an incomplete routing directory (skipping — and on
                            %% the durable backend LOSING — the not-yet-registered
                            %% tables' cells). The orchestrator runs the deferred
                            %% cold-start via `cold_start_table_indexes/1` once it
                            %% has released every shard's gate (`start_draining/1`).
                            ok =
                                case is_drain_gated(OplogOpts) of
                                    true ->
                                        ok;
                                    false ->
                                        cold_start_indexes(
                                            NS, InstanceIds, IndexMap
                                        )
                                end,
                            {ok, #{
                                db_name => DbName,
                                db_topology => Topology,
                                db_hlc => maps:get(hlc, Db),
                                entity_type => EntityType,
                                namespace => NS,
                                shard_count => ShardCount,
                                partition_strategy => PartitionStrategy,
                                realm_prefix_depth => RealmPrefixDepth,
                                aggregate_root => AggregateRoot,
                                fold_module => FoldModule,
                                crdt_module => CrdtModule,
                                crdt_opts => CrdtOpts,
                                causal_tier => causal_tier_of(CrdtModule),
                                projection_backend => Backend,
                                fused => Fused,
                                table_state => TableState,
                                instance_ids => InstanceIds,
                                cache_handles => CacheHandles,
                                indexes => IndexMap
                            }};
                        {error, _} = Err ->
                            %% Indexes failed after the primary shards came
                            %% up — roll the primary shards back too so the
                            %% caller never inherits a half-built table.
                            lists:foreach(
                                fun(S) ->
                                    teardown_shard(
                                        NS,
                                        S,
                                        InstanceIds,
                                        CacheHandles,
                                        Topology,
                                        TableState
                                    )
                                end,
                                lists:seq(0, ShardCount - 1)
                            ),
                            _ = Topology:close_table(TableState, State),
                            Err
                    end;
                {error, _} = Err ->
                    %% The effective topology's open_table already
                    %% provisioned adapter handles for this table — tear
                    %% them down so a failed provisioning does not leak
                    %% Bookies (leveled) or ETS tables (ets).
                    _ = Topology:close_table(TableState, State),
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% @private
%% Resolve the table's projection backend, rejecting impossible combos.
%% `bondy_db_topology_memory` has no leveled capability, so it is
%% ets-only; every other topology defaults to leveled (preserving prior
%% behaviour) and may opt a table into ets.
resolve_backend(bondy_db_topology_memory, Merged) ->
    case maps:get(projection_backend, Merged, ets) of
        ets ->
            {ok, ets};
        leveled ->
            {error,
                {unsupported_projection_backend,
                    {leveled, bondy_db_topology_memory}}};
        Other ->
            {error, {invalid_projection_backend, Other}}
    end;
resolve_backend(_Topology, Merged) ->
    case maps:get(projection_backend, Merged, leveled) of
        leveled -> {ok, leveled};
        ets -> {ok, ets};
        Other -> {error, {invalid_projection_backend, Other}}
    end.

%% @private
%% Map the resolved backend to the effective projection topology + state
%% for this table. `leveled` uses the DB's own topology; `ets` uses
%% `bondy_db_topology_memory` — the DB's own state when it already is a
%% memory DB, otherwise the dedicated provider created at `open/2`.
effective_topology(leveled, #{topology := Topology, topology_state := S}) ->
    {Topology, S};
effective_topology(ets, #{
    topology := bondy_db_topology_memory, topology_state := S
}) ->
    {bondy_db_topology_memory, S};
effective_topology(ets, #{ets_provider := S}) ->
    {bondy_db_topology_memory, S}.

%% @private
%% The projection backend for an index, given the originating TABLE's backend.
%% Index durability STRICTLY follows the table — an `ets` table gets `ets`
%% indices, a `leveled` table gets `leveled` indices — so index cells live next
%% to the data they index and inherit its lifecycle (cold-start trust marker,
%% compaction flush barrier).
%%
%% ETS indices are an EPHEMERAL-stack-only mode: a durable (`leveled`) table
%% always gets durable indices. Durable data needs a durable index it can trust
%% and rebuild from at cold start (the trust marker + `cell_keys/2` re-fold);
%% volatile ETS indices over durable data would be silently lost on restart, so
%% ETS indices on the durable stack are not a supported mode and there is no knob
%% to force them. (Conversely, durable indices over RAM-only data rebuilt from
%% peers are nonsensical, so `ets` always maps to `ets`.)
%%
%% A per-table / per-index override is a trivial later add HERE — the `Spec` is
%% in scope, so a future `index_backend` key on the spec would slot in without
%% touching the call sites. Kept as a clean seam rather than a knob for now.
index_backend(ets, _Spec) ->
    ets;
index_backend(leveled, _Spec) ->
    leveled.

-doc """
Release the resources owned by `Table`. Stops every per-shard oplog
instance, unregisters every shard from `bondy_oplog_core_registry`,
deletes every per-shard cache table, then asks the topology to release
its physical resources (Bookies, etc.).

Whether physical resources are actually freed is still the topology's
call — single_bookie keeps its Bookie alive across `close_table/1` and
only stops it on `close/1`.
""".
-spec close_table(Table :: table()) -> ok.

close_table(
    #{
        db_topology := Topology,
        table_state := TableState,
        namespace := NS,
        shard_count := ShardCount,
        instance_ids := InstanceIds,
        cache_handles := CacheHandles
    } = Table
) ->
    teardown_indexes(NS, maps:get(indexes, Table, #{})),
    lists:foreach(
        fun(Shard) ->
            teardown_shard(
                NS, Shard, InstanceIds, CacheHandles, Topology, TableState
            )
        end,
        lists:seq(0, ShardCount - 1)
    ),
    _ = Topology:close_table(TableState, undefined),
    ok.

-doc """
Tear down `Db`: stop every Bookie, release every resource. Calls the
topology's `shutdown/1` and, if a dedicated ETS provider was created at
`open/2` (for `projection_backend => ets` tables on a non-memory
topology), stops it too.

Callers SHOULD `close_table/1` each open table first. `close/1` does
not chase open tables — it only walks the topology.
""".
-spec close(Db :: db()) -> ok.

close(#{topology := Topology, topology_state := State} = Db) ->
    _ =
        case maps:get(ets_provider, Db, undefined) of
            undefined -> ok;
            EtsState -> bondy_db_topology_memory:shutdown(EtsState)
        end,
    Topology:shutdown(State).

-doc """
Release the WAL drain on every collapsed per-shard instance of `Db`.

A `shared_shards` (`per_shard` strategy) DB founds one oplog instance per shard,
each shared by every table and backed by a single WAL. The first table opened on
a shard founds the instance; sibling tables register their cell-apply buckets as
they open. If the founding instance drained its WAL at `init/1` — before the
siblings registered — cells for the not-yet-registered tables would resolve to no
context and be dropped (and lost: the MST install is unconditional, so resume
advances past them). To prevent that, founding instances are started with the
drain GATED (the catalogue passes `drain_gated => true` in
`oplog_instance_opts.applier`). The orchestrator MUST call `start_draining/1`
once, AFTER all of `Db`'s tables are open, to release every shard's drain so the
shared WAL is replayed with a complete routing directory.

A no-op for topologies whose instance-mapping strategy is not `per_shard`
(`per_table_shard` / memory) — nothing is gated there, so callers that never set
`drain_gated` need not call this. Idempotent.
""".
-spec start_draining(Db :: db()) -> ok.

start_draining(#{name := DbName, topology := Topology, opts := Opts}) ->
    case instances_strategy(Topology) of
        per_shard ->
            ShardCount = maps:get(shard_count, Opts, ?DEFAULT_SHARD_COUNT),
            lists:foreach(
                fun(Shard) ->
                    InstanceId = encode_instance_id(DbName, Shard),
                    case bondy_oplog:open_drain_gate(InstanceId) of
                        ok ->
                            ok;
                        {error, Reason} ->
                            ?LOG_WARNING(#{
                                description =>
                                    "bondy_db could not release the per-shard "
                                    "WAL drain gate; the instance may not be "
                                    "running. Its shared WAL will not replay "
                                    "until the gate is released.",
                                db => DbName,
                                instance_id => InstanceId,
                                shard => Shard,
                                reason => Reason
                            })
                    end
                end,
                lists:seq(0, ShardCount - 1)
            );
        _ ->
            ok
    end.

-doc """
Run the deferred secondary-index cold-start for `Table`.

`open_table/3` skips the inline index cold-start barrier (`await_drain` on the
primary, then trust-or-rebuild) when the table's founding instance is provisioned
with the WAL drain GATED (`drain_gated`) — running it before the gate is released
would deadlock and would replay the shared WAL with an incomplete routing
directory. The provisioning orchestrator calls this once per table AFTER
`start_draining/1` has released every shard's drain gate, so the barrier observes
a fully-replayed primary built from the complete routing directory.

A no-op for a table with no secondary indexes (`open_table/3` already keeps that
drain async) and for a table whose instance was never gated (its cold-start ran
inline at open). Idempotent — the trust markers make a re-run cheap.
""".
-spec cold_start_table_indexes(Table :: table()) -> ok.

cold_start_table_indexes(#{
    namespace := NS,
    instance_ids := InstanceIds,
    indexes := IndexMap
}) ->
    cold_start_indexes(NS, InstanceIds, IndexMap).

-doc """
Generate a fresh HLC from the DB's clock. Callers inject this HLC into
fold-specific events before calling `apply/4`.

Strictly greater than the previous value returned by `tick/1` on the
same DB.
""".
-spec tick(Table :: table()) -> bondy_oplog_hlc:hlc().

tick(#{db_hlc := Hlc}) ->
    bondy_oplog_hlc:now(Hlc).

-doc """
Deletes the cell at `(Realm, Key)` in `Table`.

Issues the removal operation the table's CRDT declares via `removal_op/0` —
`clear` for a register, `disable` for the flags. This is an ordinary
operation, not a physical erase: it goes through the log and converges like any
other write.

**When the cell physically disappears is the CRDT's business.** For a register
the removal leaves a tombstone whose only job is to reject a concurrent write
with a lower HLC; the cell is reclaimed later, once that HLC is causally stable
and `stabilize/2` returns `discard`. For types whose removal is redundant on
delivery there is nothing to retain and reclamation is immediate. Callers get
`not_found` from `read/3` either way, from the moment the removal is applied.

Returns `{error, {no_removal_op, Module}}` for a collection type — a set or map
has no whole-cell removal; remove its entries individually.
""".
-spec delete(Table :: table(), Realm :: realm(), Key :: binary()) ->
    ok | {error, term()}.

delete(Table, Realm, Key) when is_binary(Realm), is_binary(Key) ->
    InstanceId = instance_for_shard(Table, shard_for(Table, Realm, Key)),
    case probe_module(InstanceId) of
        undefined ->
            {error, {no_crdt_module, InstanceId}};
        Module ->
            case removal_op(Module) of
                undefined ->
                    {error, {no_removal_op, Module}};
                Op ->
                    ?MODULE:apply(Table, Realm, Key, Op)
            end
    end.

%% @private
%% `removal_op/0` is optional: a CRDT that does not export it has no whole-cell
%% removal.
removal_op(Module) ->
    case erlang:function_exported(Module, removal_op, 0) of
        true -> Module:removal_op();
        false -> undefined
    end.

-doc """
Apply a fold-specific event to `(Realm, Key)` inside `Table`.

Builds `{cell_apply, Bucket, Key, FoldEvent}` (Bucket composed via
`Topology:bucket_for/3`) and appends it through the shard's oplog
instance. Once the WAL append returns, blocks on
`bondy_oplog:await_apply/1` so the projection write is visible to a
subsequent `read/3` from the same caller (read-your-writes).

The event shape is whatever the table's `fold_module:apply_event/3`
accepts. Idempotency and conflict resolution are inherited from the
fold's contract; the facade does not validate event shapes.

Returns `ok` on successful WAL durability + applier commit, or
`{error, _}` if the WAL refuses the append or the applier's drain
times out.
""".
-spec apply(
    Table :: table(),
    Realm :: realm(),
    Key :: binary(),
    Event :: term()
) -> ok | {error, term()}.

apply(
    #{
        db_topology := Topology,
        table_state := TableState,
        entity_type := EntityType
    } = Table,
    Realm,
    Key,
    Event
) when
    is_binary(Realm), is_binary(Key)
->
    Bucket = Topology:bucket_for(EntityType, Realm, TableState),
    %% G-1: fold the realm into the storage key (see cell_key/3).
    SKey = cell_key(Topology, Realm, Key),
    %% Strategy-aware shard placement: pick the shard from the
    %% table's partition strategy (`aggregate` co-locates a subject's facts;
    %% `entity` is the legacy `phash2({Bucket, SKey})`), then map it to its
    %% oplog instance. The point read (`read/3`) derives the same shard.
    InstanceId = instance_for_shard(Table, shard_for(Table, Realm, Key)),
    %% Write→readable latency sampling. The gate is a free `persistent_term`
    %% read; when enabled we time the whole synchronous write (append +
    %% `await_apply`, plus the tier_2 context read) — that span is exactly
    %% the user-perceived time until the value is readable. Only successful
    %% writes are sampled; telemetry never alters the result.
    case bondy_oplog_latency:enabled() of
        false ->
            do_apply(Table, InstanceId, Bucket, SKey, Event, await);
        true ->
            T0 = erlang:monotonic_time(microsecond),
            Result = do_apply(Table, InstanceId, Bucket, SKey, Event, await),
            case Result of
                ok ->
                    bondy_oplog_latency:record(
                        InstanceId, erlang:monotonic_time(microsecond) - T0
                    );
                _ ->
                    ok
            end,
            Result
    end.

-doc """
As `apply/4` but WITHOUT the read-your-writes barrier: returns as soon
as the WAL append is durable, without blocking on the applier/drain
committing the projection write. Under a deep drain backlog `apply/4`'s
`await_apply` barrier makes the caller pay the whole backlog's latency;
this variant costs the caller only the (lock-free, for stateless
validators) append itself.

Use it for fire-and-forget deltas whose consumers are eventually
consistent by design — e.g. the registry RIB summary cells, whose local
routing truth lives elsewhere (the trie/members table, updated
synchronously) and whose replicated view propagates via AE regardless.
Do NOT use it when the caller — or anything the caller unblocks — reads
the cell right after writing: the projection write lands asynchronously
and a `read/3` may see the previous value. A tier_2 table still pays
the origin context-stamp round-trip (`cell_context/3`, a call into the
possibly-busy instance); only the commit barrier is skipped.

No write→readable latency sample is recorded — the metric measures
exactly the barrier this variant does not have.
""".
-spec apply_async(
    Table :: table(),
    Realm :: realm(),
    Key :: binary(),
    Event :: term()
) -> ok | {error, term()}.

apply_async(
    #{
        db_topology := Topology,
        table_state := TableState,
        entity_type := EntityType
    } = Table,
    Realm,
    Key,
    Event
) when
    is_binary(Realm), is_binary(Key)
->
    Bucket = Topology:bucket_for(EntityType, Realm, TableState),
    SKey = cell_key(Topology, Realm, Key),
    InstanceId = instance_for_shard(Table, shard_for(Table, Realm, Key)),
    do_apply(Table, InstanceId, Bucket, SKey, Event, none).

-doc """
The read-your-writes barrier `apply_async/4` skips, on demand: blocks
until `(Realm, Key)`'s shard has committed every projection write
appended before this call, so a subsequent `read/3` observes them. The
companion for the rare caller (tests, admin operations) that mixes
`apply_async/4` with an immediate read.
""".
-spec await(Table :: table(), Realm :: realm(), Key :: binary()) ->
    ok | {error, term()}.

await(Table, Realm, Key) when is_binary(Realm), is_binary(Key) ->
    await(instance_for_shard(Table, shard_for(Table, Realm, Key))).

-doc """
Idempotent set: ensure `(Realm, Key)` in `Table` holds `Value`, emitting a
write **only when the stored value differs**. A no-op when the value already
matches.

This is the write used to apply *declarative configuration* (the security and
API-gateway config files re-read on every boot). Because the substrate is an
operation-based CRDT reconciled by anti-entropy, multi-node agreement needs no
deterministic-version "rebase": re-asserting an unchanged value produces no
operation at all, so the op-set is stable across boots and the per-shard
projection (and the applied frontier over it) never drift. Only a genuine change
emits a fresh `{set, Value}`, which wins by HLC exactly as any later write does.

This relies on `Value` being **deterministic** for a given configuration —
identical on every node and every boot — so an unchanged config compares equal.
Config objects are built to satisfy this (e.g. the security config derives a
deterministic password salt). A value that embeds per-apply state (a wall-clock
timestamp, a random token) would defeat the comparison and must be made
deterministic at its source.

Returns `ok` whether or not a write was emitted; surfaces the underlying
`apply/4` error when a write is attempted and fails.
""".
-spec reconcile(
    Table :: table(),
    Realm :: realm(),
    Key :: binary(),
    Value :: term()
) -> ok | {error, term()}.

reconcile(Table, Realm, Key, Value) ->
    case read(Table, Realm, Key) of
        {ok, {Value, _Hlc}} ->
            %% Stored value already equals the desired value: no write, so no
            %% new operation enters the op-set and convergence is undisturbed.
            ok;
        _ ->
            %% Absent, cleared, changed, or a transient read error — (re)assert
            %% the desired value. A fresh write dominates by HLC.
            apply(Table, Realm, Key, {set, Value})
    end.

-doc """
Atomically apply a batch of events spanning several entities (tables) of the
same DB, grouped onto one WAL frame per shard.

Each write is `{Table, Realm, Key, Event}` — the same arguments `apply/4` takes,
self-describing so a single batch can mix tables. The batch is grouped by the
oplog instance (shard) its writes route to, and each shard's group is appended
as ONE atomic WAL frame (`bondy_oplog:append_many/2` is all-or-nothing). The
atomicity guarantee is therefore **per shard**: every write that lands on a shard
becomes durable together or not at all.

Co-located aggregates are the motivating case. Under aggregate-root placement a
subject's facts across tables — e.g. its `user`, `grants`, and `sources` — share
a shard (same `(Realm, Subject)` hash), so a batch confined to one subject is a
**single frame, fully atomic across the entities**. A batch that fans out across
shards commits one atomic frame per shard; a mid-batch failure leaves the
already-appended shards durable (there is no cross-shard rollback). Blocks on
every touched instance's drain, so a subsequent `read/3` observes every write
(read-your-writes).

A `tier_2` (causal-context-stamped) table is refused with
`{error, {tier_2_batch_unsupported, _}}`: its per-cell context read cannot be
folded into one frame — apply those cells individually with `apply/4`.

Returns `ok` once every shard frame is durable and committed, or `{error, _}`.
An empty batch is `ok`.
""".
-spec apply_many(
    Writes :: [
        {Table :: table(), Realm :: realm(), Key :: binary(), Event :: term()}
    ]
) -> ok | {error, term()}.

apply_many([]) ->
    ok;
apply_many(Writes) when is_list(Writes) ->
    case group_batch(Writes, #{}) of
        {ok, Groups} ->
            commit_batch_groups(maps:to_list(Groups));
        {error, _} = Err ->
            Err
    end.

%% @private
%% Resolve each write to its shard instance and `{Op, Meta}` item, accumulating
%% `#{InstanceId => [Item]}` so co-located writes share one frame. Per-bucket
%% arrival order is preserved (reverse on exit). tier_2 tables are refused — the
%% batch path stamps no per-cell causal context.
group_batch([], Acc) ->
    {ok, maps:map(fun(_K, Items) -> lists:reverse(Items) end, Acc)};
group_batch([{Table, Realm, Key, Event} | Rest], Acc) when
    is_map(Table) andalso is_binary(Realm) andalso is_binary(Key)
->
    case maps:get(causal_tier, Table, tier_0) of
        tier_2 ->
            {error,
                {tier_2_batch_unsupported,
                    maps:get(namespace, Table, undefined)}};
        _ ->
            #{
                db_topology := Topology,
                table_state := TableState,
                entity_type := EntityType
            } = Table,
            Bucket = Topology:bucket_for(EntityType, Realm, TableState),
            SKey = cell_key(Topology, Realm, Key),
            InstanceId = instance_for_shard(
                Table, shard_for(Table, Realm, Key)
            ),
            Item = {{cell_apply, Bucket, SKey, Event}, undefined},
            Acc1 = maps:update_with(
                InstanceId, fun(L) -> [Item | L] end, [Item], Acc
            ),
            group_batch(Rest, Acc1)
    end;
group_batch([Bad | _], _Acc) ->
    {error, {invalid_batch_write, Bad}}.

%% @private
%% Append each shard group's atomic frame (pipelining the WAL appends), then
%% await each touched instance's drain so the whole batch is read-your-writes.
commit_batch_groups(Groups) ->
    case append_batch_groups(Groups, []) of
        {ok, Instances} ->
            await_instances(Instances);
        {error, _} = Err ->
            Err
    end.

%% @private
append_batch_groups([], Acc) ->
    {ok, Acc};
append_batch_groups([{InstanceId, Items} | Rest], Acc) ->
    try bondy_oplog:append_many(InstanceId, Items) of
        {error, _} = Err ->
            Err;
        _Keys ->
            append_batch_groups(Rest, [InstanceId | Acc])
    catch
        exit:{noproc, _} ->
            {error, {instance_unavailable, InstanceId}};
        exit:{shutdown, _} ->
            {error, {instance_unavailable, InstanceId}}
    end.

%% @private
await_instances([]) ->
    ok;
await_instances([InstanceId | Rest]) ->
    case await(InstanceId) of
        ok ->
            await_instances(Rest);
        {error, _} = Err ->
            Err
    end.

%% @private
do_apply(Table, InstanceId, Bucket, Key, Event, Barrier) ->
    case maps:get(causal_tier, Table, tier_0) of
        tier_2 ->
            apply_with_context(InstanceId, Bucket, Key, Event, Barrier);
        _ ->
            %% tier_0 / tier_1 write path: the op carries whatever
            %% causality the type needs in-band, so the write is a
            %% straight WAL append with no server-side round-trip.
            append_with_barrier(
                InstanceId,
                {cell_apply, Bucket, Key, Event},
                undefined,
                Barrier
            )
    end.

%% @private
%% tier_2 write path: stamp the cell's CURRENT causal context (a version
%% vector, read in the applier's single-cell scope) into the event
%% `meta`, so `interpret_cog/2` can resolve concurrency. The op itself
%% stays pure (no state-inspecting resolution). This is the ORIGIN
%% stamp; remote events arrive
%% already-stamped via `append_remote` and are never re-stamped.
%% Read-your-writes holds because `await/1` commits each write's
%% projection before the next write reads context.
apply_with_context(InstanceId, Bucket, Key, Event, Barrier) ->
    try cell_context(InstanceId, Bucket, Key) of
        {error, _} = Err ->
            Err;
        {ok, Context} ->
            Op = {cell_apply, Bucket, Key, Event},
            append_with_barrier(InstanceId, Op, Context, Barrier)
    catch
        exit:{noproc, _} ->
            {error, {instance_unavailable, InstanceId}};
        exit:{shutdown, _} ->
            {error, {instance_unavailable, InstanceId}}
    end.

%% @private
%% `Barrier = await` blocks on the applier/drain committing the write's
%% projection (read-your-writes; `apply/4`); `none` returns at WAL
%% durability (`apply_async/4`).
append_with_barrier(InstanceId, Op, Meta, Barrier) ->
    try bondy_oplog:append(InstanceId, Op, Meta) of
        {error, _} = Err ->
            Err;
        _EventKey when Barrier =:= none ->
            ok;
        _EventKey ->
            await(InstanceId)
    catch
        exit:{noproc, _} ->
            {error, {instance_unavailable, InstanceId}};
        exit:{shutdown, _} ->
            {error, {instance_unavailable, InstanceId}}
    end.

%% @private
%% Read the cell's current causal context (`context_of/1`) in the
%% applier's single-cell scope (so it reflects committed writes for
%% read-your-writes). Returns `{ok, undefined}` when the CRDT does not
%% carry a context. A fused instance has no separate applier process —
%% falls back to the instance's own equivalent handler
%% (`bondy_oplog_instance:cell_context/3`) in that case.
cell_context(InstanceId, Bucket, Key) ->
    case bondy_oplog_registry:applier_pid(InstanceId) of
        undefined ->
            case bondy_oplog_registry:fused(InstanceId) of
                true ->
                    case bondy_oplog_registry:instance_pid(InstanceId) of
                        undefined ->
                            {error, {instance_unavailable, InstanceId}};
                        InstancePid ->
                            bondy_oplog_instance:cell_context(
                                InstancePid, Bucket, Key
                            )
                    end;
                false ->
                    {error, {instance_unavailable, InstanceId}}
            end;
        ApplierPid ->
            bondy_oplog_applier:cell_context(ApplierPid, Bucket, Key)
    end.

-doc """
Write a single benign, type-correct op to the reserved probe cell of
`InstanceId`, returning `ok` once it is committed and readable — same
synchronous path (and same write→readable span) as a real user write.

For the latency **idle probe**: it lets an idle instance be measured
without any real traffic. The op is chosen per the instance's CRDT type
(`probe_op_for/1`); it is value-stable and overwrites the one reserved
cell, so the instance's state stays bounded. The reserved bucket
(`?PROBE_BUCKET`) is one no user query targets, so the cell is invisible
to end-user reads.

This IS a real, replicated write (anti-entropy ships the reserved cell
like any other) — appropriate for the occasional heartbeat of an
otherwise-idle instance, which is why the idle probe is opt-in.

Returns `{skip, Reason}` for instances whose type has no benign probe op
(e.g. `lww_register` is supported; an unknown/internal type is skipped),
and `{error, _}` if the instance is unavailable.
""".
-spec probe_write(binary()) ->
    ok | {skip, term()} | {error, term()}.

probe_write(InstanceId) when is_binary(InstanceId) ->
    case probe_module(InstanceId) of
        undefined ->
            {skip, no_crdt_module};
        Mod ->
            case probe_op_for(Mod) of
                skip ->
                    {skip, {no_probe_op, Mod}};
                Op ->
                    probe_dispatch(InstanceId, Mod, Op)
            end
    end.

%% @private
probe_dispatch(InstanceId, Mod, Op) ->
    case Mod:causal_tier() of
        tier_2 ->
            apply_with_context(
                InstanceId, ?PROBE_BUCKET, ?PROBE_KEY, Op, await
            );
        _ ->
            append_with_barrier(
                InstanceId,
                {cell_apply, ?PROBE_BUCKET, ?PROBE_KEY, Op},
                undefined,
                await
            )
    end.

%% @private
%% The instance's effective CRDT module — resolved exactly as the applier
%% does: from its shard's `bondy_oplog_core_registry` entry via
%% `from_modules/2` (`crdt_module` wins, else the `fold_module` twin). The
%% per-instance `bondy_oplog_registry` `crdt_module` field is NOT
%% authoritative (it can be `undefined` even for a configured CRDT), so we
%% go through the applier's `cell_apply_target` like the write path does.
%% `undefined` when the instance has no projection target (not probeable).
probe_module(InstanceId) ->
    case cell_apply_target_for(InstanceId) of
        {ok, {NS, Index, Shard}} ->
            probe_module_from_entry(NS, Index, Shard);
        undefined ->
            undefined
    end.

%% @private
%% `InstanceId`'s resolved `cell_apply_target`, from whichever process
%% actually holds it: the applier, or — when there is none, a fused
%% instance has no separate applier by design — the fused instance itself.
cell_apply_target_for(InstanceId) ->
    case bondy_oplog_registry:applier_pid(InstanceId) of
        undefined ->
            case bondy_oplog_registry:fused(InstanceId) of
                true ->
                    case bondy_oplog_registry:instance_pid(InstanceId) of
                        undefined ->
                            undefined;
                        InstancePid ->
                            safe_cell_apply_target(
                                bondy_oplog_instance, InstancePid
                            )
                    end;
                _ ->
                    undefined
            end;
        ApplierPid ->
            safe_cell_apply_target(bondy_oplog_applier, ApplierPid)
    end.

%% @private
safe_cell_apply_target(Mod, Pid) ->
    try Mod:cell_apply_target(Pid) of
        {ok, _} = OK -> OK;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

%% @private
probe_module_from_entry(NS, Index, Shard) ->
    case bondy_oplog_core_registry:lookup(NS, Index, Shard) of
        {ok, Entry} ->
            try
                {crdt, Mod} = bondy_oplog_cell_kernel:from_modules(
                    bondy_oplog_core_registry:entry_fold_module(Entry),
                    bondy_oplog_core_registry:entry_crdt_module(Entry)
                ),
                Mod
            catch
                _:_ -> undefined
            end;
        _ ->
            undefined
    end.

%% @private
%% A benign, value-stable op per CRDT type for the reserved probe cell.
%% Repeated application keeps the cell bounded (counters: zero-delta; sets
%% /maps/flags: a fixed token under a fresh dot that the context-stamp
%% collapses; registers: a constant). `lww_register` needs a fresh HLC in
%% the op to overwrite the prior probe. `skip` => not idle-probed.
probe_op_for(bondy_oplog_crdt_pn_counter) ->
    {inc, 0};
probe_op_for(bondy_oplog_crdt_g_counter) ->
    {inc, 0};
probe_op_for(bondy_oplog_crdt_g_set) ->
    {add, ?PROBE_TOKEN};
probe_op_for(bondy_oplog_crdt_two_p_set) ->
    {add, ?PROBE_TOKEN};
probe_op_for(bondy_oplog_crdt_aw_set) ->
    {add, ?PROBE_TOKEN};
probe_op_for(bondy_oplog_crdt_rw_set) ->
    {add, ?PROBE_TOKEN};
probe_op_for(bondy_oplog_crdt_aw_map) ->
    {put, ?PROBE_TOKEN, ?PROBE_TOKEN};
probe_op_for(bondy_oplog_crdt_mv_register) ->
    {set, ?PROBE_TOKEN};
probe_op_for(bondy_oplog_crdt_ew_flag) ->
    enable;
probe_op_for(bondy_oplog_crdt_dw_flag) ->
    enable;
probe_op_for(bondy_oplog_crdt_max_register) ->
    {set, 0};
probe_op_for(bondy_oplog_crdt_min_register) ->
    {set, 0};
probe_op_for(bondy_oplog_crdt_lww_register) ->
    {set, bondy_oplog_hlc:now(bondy_oplog_hlc:new()), ?PROBE_TOKEN};
probe_op_for(_Other) ->
    skip.

-doc """
Increment the PN-Counter at `(Realm, Key)` in `Table` by `Delta`.

Convenience wrapper over `apply/4` for tables backed by the
`pn_counter` fold. `Delta` may be negative (a "decrement" is just
`counter_inc(_, _, _, -K)`). The fold absorbs the event under the
per-Origin Seq number tracked in the WAL event key — duplicate
delivery and replay are no-ops by construction.

That idempotence covers SUBSTRATE re-delivery only. A CALLER retry
after `{error, timeout}` mints a fresh event and is a genuine second
increment if the first append was in fact durable — a counter is the
one fold where at-least-once caller behaviour is observable in the
value. Callers that need exactly-once must layer an idempotency-key
pattern of their own.

Returns `ok` once the WAL append is durable and the applier has
committed the projection write, or `{error, _}` on substrate failure.

The fold module is **not** validated here; using this helper against
a non-`pn_counter` table will route a `{inc, Delta}` event into a
fold that does not understand it and `apply/4` will fail at the
projection layer.
""".
-spec counter_inc(
    Table :: table(),
    Realm :: realm(),
    Key :: binary(),
    Delta :: integer()
) -> ok | {error, term()}.

counter_inc(Table, Realm, Key, Delta) when is_integer(Delta) ->
    ?MODULE:apply(Table, Realm, Key, {inc, Delta}).

-doc """
Apply a list of CRDT commands to a single Map (or set) cell `(Realm, Key)`
as one atomic, packed operation.

The commands are packed into a single `{batch, Ops}` event — **one** WAL
entry, **one** MST entry, **one** projection read-modify-write — and
expanded at the CRDT seam on apply, read and compaction. Compared with N
separate `apply/4` calls this collapses N WAL fsyncs, N `await`s, N tier_2
context round-trips and the N successive whole-cell re-serialisations (which
grow super-linearly as a map is built field-by-field) down to one of each.

All commands share one causal identity (dot) and one observed context, so
the batch is a single **atomic, mutually-concurrent** causal unit: the
commands do **not** observe each other (a `{put, K, V}` and a `{rmv, K}` in
the same batch resolve add-wins — the put survives), and a concurrent
remote operation either observed the whole batch or none of it.

`Ops` is a list of the table CRDT's own operations, e.g. for an add-wins
map `[{put, Field, Value}, {rmv, Field}, ...]`. An empty list is a no-op
(`ok`).

Only CRDTs whose operations are identified per sub-key/value — the
dot-store and grow-set types (add-wins / remove-wins maps and sets, 2P-set,
G-set, the flags, the struct) — may be batched; they declare the
`batchable` callback of `bondy_oplog_crdt_commutative`. Counters and
scalar registers dedup / resolve by the event sequence or HLC, so packing
several of their ops under one identity would silently collapse them:
`apply_batch/4` refuses such a table with `{error, {not_batchable,
Module}}`. Merge those client-side and use `apply/4` / `counter_inc/4`.

The same collapse applies WITHIN a batchable type's **nested sub-ops**:
a nested `{apply, FieldOrKey, ...}` accumulates in the target's dot-store
*by dot*, and a batch is one dot — so a batch may carry at most ONE
sub-op per field/key (the registration-RIB shape: one batch touching four
*different* fields). A second sub-op on the same field/key in the same
batch would silently replace the first in the dot-store, so both batch
entry points reject such a batch with `{error, {duplicate_batch_subop,
Targets}}` before the WAL append (the async path included). Merge
same-field sub-ops client-side, or issue separate `apply/4` calls
(distinct dots).

Returns `ok` once the WAL append is durable and the applier has committed
the projection write (read-your-writes holds), or `{error, _}`.
""".
-spec apply_batch(
    Table :: table(),
    Realm :: realm(),
    Key :: binary(),
    Ops :: [term()]
) -> ok | {error, term()}.

apply_batch(_Table, Realm, Key, []) when is_binary(Realm), is_binary(Key) ->
    ok;
apply_batch(Table, Realm, Key, Ops) when
    is_binary(Realm), is_binary(Key), is_list(Ops)
->
    case assert_batch(Table, Ops) of
        ok ->
            ?MODULE:apply(Table, Realm, Key, {batch, Ops});
        {error, _} = Err ->
            Err
    end.

-doc """
As `apply_batch/4` but through `apply_async/4`: one packed batch event,
no read-your-writes barrier. Same contract and caveats as
`apply_async/4`.
""".
-spec apply_batch_async(
    Table :: table(),
    Realm :: realm(),
    Key :: binary(),
    Ops :: [term()]
) -> ok | {error, term()}.

apply_batch_async(_Table, Realm, Key, []) when
    is_binary(Realm), is_binary(Key)
->
    ok;
apply_batch_async(Table, Realm, Key, Ops) when
    is_binary(Realm), is_binary(Key), is_list(Ops)
->
    case assert_batch(Table, Ops) of
        ok ->
            apply_async(Table, Realm, Key, {batch, Ops});
        {error, _} = Err ->
            Err
    end.

-doc """
Declarative Map-edit sugar over `apply_batch/4`. `Edit` is a map with
optional `put` and `rmv` keys:

```erlang
bondy_db:map_update(Users, <<"realm">>, <<"alice">>, #{
    put => #{<<"name">> => <<"Alice">>, <<"age">> => 30},
    rmv => [<<"temp">>]
}).
```

`put` is a `#{Field => Value}` map of field assignments; `rmv` is a list of
fields to observed-remove. They are translated to `[{put, Field, Value}]`
followed by `[{rmv, Field}]` and applied as a single packed batch (see
`apply_batch/4` for the atomic, mutually-concurrent semantics — order
between the entries is irrelevant). An unrecognised top-level `Edit` key
returns `{error, {unknown_map_edit_keys, _}}`; a malformed `put`/`rmv`
shape returns `{error, {invalid_map_edit, _}}`.
""".
-spec map_update(
    Table :: table(),
    Realm :: realm(),
    Key :: binary(),
    Edit :: map()
) -> ok | {error, term()}.

map_update(Table, Realm, Key, Edit) when
    is_binary(Realm), is_binary(Key), is_map(Edit)
->
    case edit_to_ops(Edit) of
        {ok, Ops} -> apply_batch(Table, Realm, Key, Ops);
        {error, _} = Err -> Err
    end.

-doc """
Read the decoded value for `(Realm, Key)` from `Table`.

Routes through `bondy_oplog_core:read/4`, which hits the per-shard cache
on the fast path and falls back to the projection + cache-populate on
miss. The fold-decoded value is returned together with the cell's
recorded HLC as an `t:entry/0`.

Returns:

- `{ok, {Value, Hlc}}` — the cell's current value and the HLC at which it
  was last written. `Value` is the fold's decoded value: a term for a
  register, a sibling list `[term()]` for a multi-value register, a map for
  an `aw_map`, etc. The caller works with domain terms — no manual
  `binary_to_term/1`.
- `{error, not_found}` — no live cell exists for `(Realm, Key)` (never
  written, or cleared).
- `{error, _}` — adapter or substrate failure.
""".
-spec read(
    Table :: table(),
    Realm :: realm(),
    Key :: binary()
) ->
    {ok, entry()} | {error, not_found} | {error, term()}.

read(
    #{
        namespace := NS,
        db_topology := Topology,
        table_state := TableState,
        entity_type := EntityType
    } = Table,
    Realm,
    Key
) when
    is_binary(Realm), is_binary(Key)
->
    Bucket = Topology:bucket_for(EntityType, Realm, TableState),
    %% G-1: fold the realm into the storage key (see cell_key/3).
    SKey = cell_key(Topology, Realm, Key),
    %% Force the read onto the same shard the write chose: under any
    %% non-`entity` strategy the shard is NOT `phash2({Bucket, SKey})`, so the
    %% explicit override is what keeps write and read addressing one shard.
    Shard = shard_for(Table, Realm, Key),
    case bondy_oplog_core:read(NS, ?INDEX, Bucket, SKey, #{shard => Shard}) of
        {Value, Hlc} when Value =/= undefined ->
            {ok, {Value, Hlc}};
        undefined ->
            {error, not_found};
        {error, _} = Err ->
            Err
    end.

-doc """
Single-shard range scan over `(Realm, [Low, High))`.

The shard defaults to the one holding `Low` under the table's partition
strategy (`shard_for/3` — for the legacy `entity` strategy this is
`phash2({Bucket, Low})`), unless the caller passes `Opts#{shard => N}`.
Callers whose `[Low, High)` spans more than one shard / aggregate MUST scatter
across shards themselves and merge the results (see `range_all/5` / `list/2`);
the facade does not do scatter-merge here.

Routes through `bondy_oplog_core:range/4`. Facade shards register with
`overlay = disabled`, so the scan reads the projection only;
read-your-writes comes from `apply/4`'s `await_apply` step, not an
overlay merge. Under a realm-folding topology the realm is folded into
both bounds so the substrate scan stays inside the realm's band.

Returns `{ok, [Row]}` — one `t:row/0` (`{Key, Value, Hlc}`) per cell
present in the range, in ascending key order. `Value` is the fold's
decoded value (a domain term, never raw bytes).
""".
-spec range(
    Table :: table(),
    Realm :: realm(),
    Low :: binary(),
    High :: binary() | infinity,
    Opts :: bondy_oplog_core:range_opts()
) ->
    {ok, [row()]} | {error, term()}.

range(
    #{
        namespace := NS,
        db_topology := Topology,
        table_state := TableState,
        entity_type := EntityType
    } = Table,
    Realm,
    Low,
    High,
    Opts
) when
    is_binary(Realm),
    is_binary(Low),
    (is_binary(High) orelse High =:= infinity),
    is_map(Opts)
->
    Bucket = Topology:bucket_for(EntityType, Realm, TableState),
    %% G-1: fold the realm into the bounds (no-op for realm-in-bucket
    %% topologies, so their shard formula `phash2({Bucket, Low})` is preserved).
    Lo = cell_key(Topology, Realm, Low),
    Hi = fold_high(Topology, Realm, High),
    %% Single-shard scan: default to the shard holding `Low` under the table's
    %% partition strategy (for `entity` this is the legacy
    %% `phash2({Bucket, Lo})`). A range spanning more than one shard / aggregate
    %% MUST scatter via `range_all/5`; this default is for within-shard scans.
    Shard = maps:get(shard, Opts, shard_for(Table, Realm, Low)),
    AdapterOpts = (maps:without([shard], Opts))#{shard => Shard},
    case bondy_oplog_core:range(NS, ?INDEX, Bucket, {Lo, Hi}, AdapterOpts) of
        {ok, Rows} ->
            {ok, [
                {uncell_key(Topology, Realm, K), V, Hlc}
             || {K, V, Hlc} <- Rows
            ]};
        {error, _} = Err ->
            Err
    end.

-doc """
Enumerates **every** cell in `Realm` across all shards of `Table`.

Unlike `range/5` (single-shard), this scatters a full scan across every
shard and merges the results in ascending key order, paging internally
until the realm band is exhausted — the result is COMPLETE, never
silently truncated at the substrate's default range cap. Use it for the
small, list-all tables (e.g. the API Gateway specs) — it is O(table),
not a point read, and it materialises the whole realm's rows in memory;
for an unbounded / large enumeration use `bondy_relation`'s keyset
pagination (`bondy_relation:list/3`) or `bondy_relation:fold/4` instead.
Returns `{ok, [Row]}` of `t:row/0` (`{Key, Value, Hlc}`);
`Value` is the fold-decoded value (a caller filters retracted cells whose
value is the fold's empty value if its policy requires).
""".
-spec list(Table :: table(), Realm :: realm()) ->
    {ok, [row()]} | {error, term()}.

list(#{namespace := NS, db_topology := Topology} = Table, Realm) when
    is_binary(Realm)
->
    Bucket = primary_bucket(Table, Realm),
    %% G-1: under a realm-folding topology scope the scatter-scan to the realm's
    %% key band and recover the caller's keys; otherwise the Bucket already
    %% isolates the realm and keys are passed through verbatim.
    {Lo, Hi} = realm_scan_range(Topology, Realm),
    case list_pages(NS, Bucket, Lo, Hi, []) of
        {ok, Rows} ->
            {ok, [
                {uncell_key(Topology, Realm, K), V, Hlc}
             || {K, V, Hlc} <- Rows
            ]};
        {error, _} = Err ->
            Err
    end.

-doc """
Streams **every** cell of `Table`, across **every realm**, into `Fun`.

The counterpart to `list/2` for callers that need the whole table and cannot
name the realms up front. `list/2` narrows to one realm purely through
`realm_scan_range/2`; dropping that narrowing is the entire difference.

## Why this exists

Without it, "every realm with data in `Table`" has to be approximated by
`bondy_realm:list/0` — but realms are themselves replicated state in the
`main` DB, and nothing orders one DB's anti-entropy bootstrap before
another's. A caller rebuilding derived state on a freshly bootstrapped node
therefore sees an empty or partial realm list and silently skips cells,
intermittently, depending on which bootstrap won the race. Enumerating the
data directly removes the dependency rather than sequencing it.

## Contract

`Fun` receives `{StorageKey, Value, Hlc}` — the **storage** key
`<<Realm, 0, Key>>`, NOT the caller-facing key `list/2` recovers via
`uncell_key/3`. The realm cannot be stripped here because this function does
not know it; callers that need it split on the FIRST NUL, which is exact:
`assert_nul_free_realm/1` guarantees a realm URI contains none, while the
key's own bytes (which may) are preserved verbatim after the separator.

Streams. Rows arrive in ascending storage-key order, one merged page at a
time (`limit`, default 1000), so a table of millions of cells never
materialises. This is why it is a fold and not a `list_all/1`.

## Partial by construction

Only realm-FOLDING topologies can be scanned this way — `?FOLDS_REALM`, i.e.
`bondy_db_topology_memory` and `bondy_db_topology_shared_shards`, which is
both DBs Bondy ships. The others carry the realm in the BUCKET, and nothing
in `bondy_db`, `bondy_oplog_core` or the projection adapters enumerates
buckets. Raises `{unsupported_topology, _}` rather than returning `{ok, Acc0}`
— a silent empty fold would look exactly like an empty table.
""".
-spec fold_all(
    Table :: table(),
    Fun :: fun(({binary(), term(), term()}, Acc) -> Acc),
    Acc0 :: Acc,
    Opts :: map()
) -> {ok, Acc} | {error, term()} when Acc :: term().

fold_all(
    #{namespace := NS, db_topology := Topology} = Table, Fun, Acc0, Opts
) when
    is_function(Fun, 2), is_map(Opts)
->
    ?FOLDS_REALM(Topology) orelse error({unsupported_topology, Topology}),
    %% `bucket_for/3` ignores the realm under a folding topology (the realm is
    %% in the key), so the bucket is the whole table.
    Bucket = primary_bucket(Table, <<>>),
    Limit = maps:get(limit, Opts, 1000),
    fold_all_pages(NS, Bucket, <<>>, Limit, Fun, Acc0).

%% @private
%% `list_pages/5`'s loop, applying `Fun` per page instead of accumulating the
%% rows: same paging contract (advance the inclusive lower bound to the
%% successor of the last STORAGE key; a short page ends the scan), no upper
%% bound, and no per-page retention of what has already been folded.
fold_all_pages(NS, Bucket, Lo, Limit, Fun, Acc) ->
    Opts = #{limit => Limit},
    case bondy_oplog_core:range_all(NS, ?INDEX, Bucket, {Lo, infinity}, Opts) of
        {ok, Rows} ->
            Acc1 = lists:foldl(Fun, Acc, Rows),
            case length(Rows) < Limit of
                true ->
                    {ok, Acc1};
                false ->
                    {LastKey, _, _} = lists:last(Rows),
                    fold_all_pages(
                        NS, Bucket, <<LastKey/binary, 0>>, Limit, Fun, Acc1
                    )
            end;
        {error, _} = Err ->
            Err
    end.

-doc """
Bounded, globally-ordered range scan over `(Realm, [Low, High))` across
**every** shard of `Table`.

Like `range/5` but scatters the `[Low, High)` window to every shard and
merges the per-shard results into one ascending key-ordered list, capped
at `Opts`' `limit`
(default 1000). The merge is correct because each shard is internally
sorted and every key in the global top-`limit` appears in some shard's
top-`limit` (see `bondy_oplog_core:range_all/5`).

This is the keyset-pagination primitive for globally-ordered windows: a
realm's keys are spread across shards by the table's partition strategy
(`aggregate` hashes each key's `(Realm, Aggregate)`; `entity` hashes
`{Bucket, Key}`), so a single-shard `range/5` returns only the fraction
of the window that hashes to one shard — an incomplete page. The G-1
realm band bounds each per-shard scan to the realm; this function
assembles the global window across shards.

`Low`/`High` are realm-folded exactly as `range/5`; `High => infinity`
scans to the end of the realm band. Returns `{ok, [Row]}` of `t:row/0`
(`{Key, Value, Hlc}`) in key order; `Value` is the fold-decoded value.
""".
-spec range_all(
    Table :: table(),
    Realm :: realm(),
    Low :: binary(),
    High :: binary() | infinity,
    Opts :: bondy_oplog_core:range_opts()
) ->
    {ok, [row()]} | {error, term()}.

range_all(
    #{namespace := NS, db_topology := Topology} = Table,
    Realm,
    Low,
    High,
    Opts
) when
    is_binary(Realm),
    is_binary(Low),
    (is_binary(High) orelse High =:= infinity),
    is_map(Opts)
->
    Bucket = primary_bucket(Table, Realm),
    %% G-1: fold the realm into both bounds (no-op for realm-in-bucket
    %% topologies, so their scan stays inside the realm's bucket).
    Lo = cell_key(Topology, Realm, Low),
    Hi = fold_high(Topology, Realm, High),
    case bondy_oplog_core:range_all(NS, ?INDEX, Bucket, {Lo, Hi}, Opts) of
        {ok, Rows} ->
            {ok, [
                {uncell_key(Topology, Realm, K), V, Hlc}
             || {K, V, Hlc} <- Rows
            ]};
        {error, _} = Err ->
            Err
    end.

-doc """
Equality lookup against secondary index `IndexName`: the primary keys
(and any denormalised columns) whose indexed term equals `Term` within
`Realm`.

`Term` is normalised through the index's spec (e.g. `downcase`) so it
matches the stored terms, then resolved to the single secondary shard
that holds it (`phash2({SecBucket, Term}, SecShardCount)`) and scanned
over that term's contiguous key window.

The scan is **realm-scoped**: under a realm-folding topology (G-1) the
index entry key is `<<enc(Term), 0, Realm, 0, Key>>` (the primary key is
realm-folded), so one realm's entries for a term are a contiguous
sub-band and the read restricts to `[<<enc(Term),0,Realm,0>>,
<<enc(Term),0,Realm,1>>)`. Cross-realm entries that share a term are
therefore never returned.

The term-RANGE `index_range/6` cannot use that sub-band, because a term range
spans realms non-contiguously. It is realm-CORRECT — `index_rows/3` filters
rows on the realm prefix rather than assuming it — but not realm-EFFICIENT: it
scans every shard and discards what it filters. Making it efficient would mean
ordering the index entry key realm-before-term, so a realm's whole term range
is one contiguous band; that is a repartitioning (the index is term-sharded,
so the shard function would have to change too, and every existing entry would
move), and it buys nothing until a range read is actually on a hot path.

## Opts

- `max_lag` — refuse with `{error, {stale_secondary, IndexName, Lag}}`
  unless the touched shard was freshened within `max_lag` ms (defaults to
  the spec's `max_lag`, itself `infinity` = never refuse). `Lag` is the
  shard's wall-clock ms lag, or `infinity` when it was never freshened or
  is flagged for rebuild. The startup backfill freshens every shard at
  open, so a finite `max_lag` over an up-to-date index passes; refusal
  signals a genuinely lagging or rebuilding shard.
- `fallback => primary` — instead of refusing a stale read, scan the
  primary directly and recompute the matching keys (slow but correct).
  Bounded by an internal cell cap.
- `limit` — forwarded to the underlying range scan (and the
  fallback).
- `after_key => PrimaryKey` — resume strictly after this primary key,
  scanning only the term's remaining entries (keyset pagination within one
  term's realm-scoped band). Combine with `limit` to page a high-cardinality
  term (a popular index value) without materialising all its matches.
  (Named `after_key`, not `after` — `after` is a reserved word.)

Returns `{ok, [{PrimaryKey, Columns}]}` (in `(term, primary-key)` order;
`Columns` is the decoded projection map, `#{}` for a pointer-only index),
`{error, {unknown_index, IndexName}}`, or a substrate `{error, _}`.
Retracted entries (tombstones) are filtered out by the substrate.
""".
-spec index_get(
    Table :: table(),
    Realm :: realm(),
    IndexName :: atom(),
    Term :: bondy_oplog_index_key:term_value(),
    Opts :: map()
) ->
    {ok, [{PrimaryKey :: binary(), Columns :: map()}]}
    | {error, term()}.

index_get(Table, Realm, IndexName, Term, Opts) when
    is_binary(Realm), is_atom(IndexName), is_map(Opts)
->
    with_index(Table, IndexName, fun(Spec, SecShardCount) ->
        NS = maps:get(namespace, Table),
        Topology = maps:get(db_topology, Table),
        SecBucket = index_bucket(Table, Realm, IndexName),
        Norm = bondy_oplog_index_spec:normalize_term(Spec, Term),
        MaxLag = maps:get(max_lag, Opts, bondy_oplog_index_spec:max_lag(Spec)),
        SecShard =
            bondy_oplog_index_key:shard(SecBucket, Norm, SecShardCount),
        case ensure_shard_fresh(NS, IndexName, SecShard, MaxLag) of
            ok ->
                After = maps:get(after_key, Opts, undefined),
                {Low, High} = index_eq_bounds(Topology, Realm, Norm, After),
                RangeOpts = (index_range_opts(Opts))#{shard => SecShard},
                read_index(
                    Topology,
                    Realm,
                    NS,
                    IndexName,
                    SecBucket,
                    Low,
                    High,
                    RangeOpts
                );
            {stale, Lag} ->
                stale_or_fallback(
                    Opts,
                    IndexName,
                    Lag,
                    fun() ->
                        primary_scan_eq(Table, Realm, Spec, Norm, Opts)
                    end
                )
        end
    end).

-doc """
Ordered range scan against secondary index `IndexName`: the primary keys
(and columns) whose indexed term is in the half-open `[LoTerm, HiTerm)`
within `Realm`.

Both bounds are normalised through the index's spec. The scan scatters
across every secondary shard (terms span all shards) and the merged
result is globally ordered by `(term, primary-key)`. `Opts` are as for
`index_get/5` (`max_lag` refusal, `limit`); `limit` caps the
merged result.

Returns `{ok, [{PrimaryKey, Columns}]}`,
`{error, {unknown_index, IndexName}}`, or a substrate `{error, _}`
(a single failing shard aborts the whole scan — no partial results).
""".
-spec index_range(
    Table :: table(),
    Realm :: realm(),
    IndexName :: atom(),
    LoTerm :: bondy_oplog_index_key:term_value(),
    HiTerm :: bondy_oplog_index_key:term_value(),
    Opts :: map()
) ->
    {ok, [{PrimaryKey :: binary(), Columns :: map()}]}
    | {error, term()}.

index_range(Table, Realm, IndexName, LoTerm, HiTerm, Opts) when
    is_binary(Realm), is_atom(IndexName), is_map(Opts)
->
    with_index(Table, IndexName, fun(Spec, SecShardCount) ->
        NS = maps:get(namespace, Table),
        Topology = maps:get(db_topology, Table),
        SecBucket = index_bucket(Table, Realm, IndexName),
        Lo = bondy_oplog_index_spec:normalize_term(Spec, LoTerm),
        Hi = bondy_oplog_index_spec:normalize_term(Spec, HiTerm),
        MaxLag = maps:get(max_lag, Opts, bondy_oplog_index_spec:max_lag(Spec)),
        case ensure_index_fresh(NS, IndexName, SecShardCount, MaxLag) of
            ok ->
                {Low, High} = bondy_oplog_index_key:range_bounds(Lo, Hi),
                case
                    bondy_oplog_core:range_all(
                        NS,
                        IndexName,
                        SecBucket,
                        {Low, High},
                        index_range_opts(Opts)
                    )
                of
                    {ok, Rows} -> {ok, index_rows(Topology, Realm, Rows)};
                    {error, _} = Err -> Err
                end;
            {stale, Lag} ->
                stale_or_fallback(
                    Opts,
                    IndexName,
                    Lag,
                    fun() ->
                        primary_scan_range(Table, Realm, Spec, Lo, Hi, Opts)
                    end
                )
        end
    end).

-doc """
Composite (covering) index PREFIX scan: every fact whose leading collation
columns equal `PrefixCols` — a list shorter than, or equal to, the index's
declared `collation` — within `Realm`.

Returns `{ok, [{Columns, Projections}]}` where `Columns` is the **full** decoded
collation tuple (the fact's indexed columns, in collation order) and
`Projections` is the denormalised-columns map (`#{}` when none). This is the
covering read: a single prefix scan answers the query without a primary fetch.

Realm-scoped: on a realm-folding topology (G-1) the composite index is keyed
realm-first (`«Realm, 0, enc(Tuple), 0, Key»`), so the prefix band stays inside
`Realm`; on a non-folding topology the index bucket already isolates the realm.
The scan scatters across all secondary shards (a composite index is sharded by
the full tuple) and the merged result is ordered by the collation.
""".
-spec index_prefix(
    Table :: table(),
    Realm :: realm(),
    IndexName :: atom(),
    PrefixCols :: [bondy_oplog_index_key:column()],
    Opts :: map()
) ->
    {ok, [{Columns :: [bondy_oplog_index_key:column()], Projections :: map()}]}
    | {error, term()}.

index_prefix(Table, Realm, IndexName, PrefixCols, Opts) when
    is_binary(Realm), is_atom(IndexName), is_list(PrefixCols), is_map(Opts)
->
    with_index(Table, IndexName, fun(Spec, SecShardCount) ->
        case bondy_oplog_index_spec:is_composite(Spec) of
            false ->
                {error, {not_a_composite_index, IndexName}};
            true ->
                Topology = maps:get(db_topology, Table),
                Enc = composite_enc(Spec, PrefixCols),
                Bounds = composite_eq_bounds(Topology, Realm, Enc),
                composite_scan(
                    Table, Realm, IndexName, Spec, SecShardCount, Bounds, Opts
                )
        end
    end).

-doc """
Composite index range scan over the half-open prefix range `[LoCols, HiCols)`:
every fact whose leading collation columns sort in that range, within `Realm`.
Same `{ok, [{Columns, Projections}]}` shape and realm-scoping as
`index_prefix/5`; use it to scan a contiguous slice of a collation order (e.g.
all facts with `p = P0` and `o` in `[O1, O2)`).
""".
-spec index_prefix_range(
    Table :: table(),
    Realm :: realm(),
    IndexName :: atom(),
    LoCols :: [bondy_oplog_index_key:column()],
    HiCols :: [bondy_oplog_index_key:column()],
    Opts :: map()
) ->
    {ok, [{Columns :: [bondy_oplog_index_key:column()], Projections :: map()}]}
    | {error, term()}.

index_prefix_range(Table, Realm, IndexName, LoCols, HiCols, Opts) when
    is_binary(Realm),
    is_atom(IndexName),
    is_list(LoCols),
    is_list(HiCols),
    is_map(Opts)
->
    with_index(Table, IndexName, fun(Spec, SecShardCount) ->
        case bondy_oplog_index_spec:is_composite(Spec) of
            false ->
                {error, {not_a_composite_index, IndexName}};
            true ->
                Topology = maps:get(db_topology, Table),
                EncLo = composite_enc(Spec, LoCols),
                EncHi = composite_enc(Spec, HiCols),
                Bounds = composite_range_bounds(Topology, Realm, EncLo, EncHi),
                composite_scan(
                    Table, Realm, IndexName, Spec, SecShardCount, Bounds, Opts
                )
        end
    end).

-doc """
Rebuild secondary index `IndexName` of `Table` from the primary: clear its
projection shards, re-fold every live primary cell, and re-dispatch a `put` for
every term. For a **durable table** (any leveled topology) the cell directory
is the complete durable projection (`cell_keys/2`, scoped per the topology —
`{entity, ET}` for `shared_shards`/`single_bookie`, `all_primary` for
`per_entity`); only the ephemeral ETS adapter falls back to the MST — see
`bondy_oplog_cell_utils:primary_cell_directory/4`. Synchronous — returns once the
index has been re-materialised and its shards freshened, so a `max_lag` read
issued after this passes. `{error, {unknown_index, IndexName}}` for an unknown
index.

The same recovery the substrate runs autonomously on a saturation drop or
a writer crash; exposed for operators (and tests) to force on demand.
""".
-spec rebuild_index(Table :: table(), IndexName :: atom()) ->
    ok | {error, term()}.

rebuild_index(Table, IndexName) when is_atom(IndexName) ->
    with_index(Table, IndexName, fun(_Spec, _SecShardCount) ->
        bondy_oplog_index_rebuild:rebuild_sync(
            maps:get(namespace, Table), IndexName
        )
    end).

-doc "Rebuild every secondary index declared on `Table` (see `rebuild_index/2`).".
-spec rebuild_indexes(Table :: table()) -> ok.

rebuild_indexes(Table) ->
    NS = maps:get(namespace, Table),
    maps:foreach(
        fun(IndexName, _Provision) ->
            _ = bondy_oplog_index_rebuild:rebuild_sync(NS, IndexName)
        end,
        maps:get(indexes, Table, #{})
    ).

-doc """
Per-secondary-shard lag diagnostics for `IndexName`. Returns
`#{SecShard => #{lag => infinity | non_neg_integer(), inflight =>
non_neg_integer(), needs_rebuild => boolean()}}`, where `lag` is the
wall-clock ms since the shard was last freshened (`infinity` when never
freshened or flagged for rebuild), `inflight` is the writer's
dispatched-but-unflushed backlog, and `needs_rebuild` whether a rebuild is
pending. `{error, {unknown_index, IndexName}}` for an unknown index.
""".
-spec index_lag(Table :: table(), IndexName :: atom()) ->
    {ok, #{non_neg_integer() := map()}} | {error, term()}.

index_lag(Table, IndexName) when is_atom(IndexName) ->
    with_index(Table, IndexName, fun(_Spec, SecShardCount) ->
        NS = maps:get(namespace, Table),
        Map = maps:from_list([
            {Shard, shard_lag_info(NS, IndexName, Shard)}
         || Shard <- lists:seq(0, SecShardCount - 1)
        ]),
        {ok, Map}
    end).

-doc """
Flush every pending secondary-index write for `IndexName` of `Table`,
returning once each shard's writer has drained its coalesce buffer into
the projection.

The secondary writer is asynchronous (a `coalesce_ms` timer), so an
`apply/4` returns before its index ops are visible to `index_get`/
`index_range` — read-your-writes does NOT hold for the index. This is the
read-side barrier that restores it: after `await_index/2` returns, an
index read reflects every `apply/4` that returned before the call. Use it
when a caller must enumerate an index *completely* — e.g. draining a
relation's reverse access path before deleting its key, where a missed
entry would leak a dangling reference.

Cost is `O(pending ops)`, not `O(table)` — it flushes buffers, it does not
re-derive (that is `rebuild_index/2`). `{error, {unknown_index, IndexName}}`
for an unknown index.
""".
-spec await_index(Table :: table(), IndexName :: atom()) ->
    ok | {error, term()}.

await_index(Table, IndexName) when is_atom(IndexName) ->
    with_index(Table, IndexName, fun(_Spec, SecShardCount) ->
        NS = maps:get(namespace, Table),
        lists:foreach(
            fun(Shard) ->
                case bondy_oplog_core_registry:lookup(NS, IndexName, Shard) of
                    {ok, Entry} ->
                        case
                            bondy_oplog_core_registry:entry_writer_pid(Entry)
                        of
                            Pid when is_pid(Pid) ->
                                bondy_oplog_secondary_writer:flush_sync(Pid);
                            _ ->
                                ok
                        end;
                    not_found ->
                        ok
                end
            end,
            lists:seq(0, SecShardCount - 1)
        )
    end).

-doc """
Return an informational map about `Db` or `Table`. Intended for
operator introspection and tests; the shape is not stable across
versions.
""".
-spec info(db() | table()) -> map().

info(#{name := Name, topology := Topology, opts := Opts}) ->
    #{
        kind => db,
        name => Name,
        topology => Topology,
        opts => Opts
    };
info(
    #{
        entity_type := ET,
        shard_count := SC,
        fold_module := Fold,
        db_name := DbName,
        db_topology := Topology,
        namespace := NS
    } = Table
) ->
    #{
        kind => table,
        db_name => DbName,
        topology => Topology,
        projection_backend => maps:get(projection_backend, Table, leveled),
        entity_type => ET,
        namespace => NS,
        shard_count => SC,
        fold_module => Fold,
        crdt_module => maps:get(crdt_module, Table, undefined),
        crdt_opts => maps:get(crdt_opts, Table, #{}),
        causal_tier => maps:get(causal_tier, Table, tier_0),
        fused => maps:get(fused, Table, false),
        indexes => maps:map(
            fun(_Name, Provision) ->
                #{
                    sec_shard_count => maps:get(sec_shard_count, Provision),
                    projects => bondy_oplog_index_spec:projects(
                        maps:get(spec, Provision)
                    )
                }
            end,
            maps:get(indexes, Table, #{})
        )
    }.

-doc """
The oplog namespace of `Table` — the atom a reactor passes to
`bondy_oplog_core:subscribe/2` to receive this table's change events (when the
table was opened with `publish => true`).
""".
-spec namespace(Table :: table()) -> atom().

namespace(#{namespace := NS}) ->
    NS.

-doc """
The number of primary shards `Table` is partitioned into.

A cell's shard is `shard_for/3`; a cross-shard read must visit `0..N-1`.
Used by the relation layer to walk shards for partition-ordered pagination
(`bondy_relation:list/3` in `partition` mode).
""".
-spec shard_count(Table :: table()) -> pos_integer().

shard_count(#{shard_count := SC}) ->
    SC.

-doc """
The application-facing AE freshness fence (`STORAGE_ARCHITECTURE` §9.1/§10.5).

Returns `ok` when every shard of every given table has completed an
anti-entropy round within `MaxLag` milliseconds, or `{stale, NSs}` naming the
namespaces whose AE is staler than the bound. `infinity` always passes.

Each table maps to its oplog namespace (`t:table/0`'s `namespace`), so callers
pass table handles (e.g. the `security_users` / grant tables for the auth path)
rather than raw namespace atoms.

IMPORTANT: with anti-entropy **disabled** (`bondy_oplog` `aae_enabled = false`,
the default) the per-shard AE atomics are never advanced past their
"infinitely stale" sentinel, so a finite `MaxLag` returns `{stale, _}` for every
namespace. Callers MUST gate enforcement on AAE being enabled — the fence is a
cross-node-staleness guard and there is no cross-node window with AAE off.
""".
-spec ensure_fresh(
    Tables :: [table()],
    MaxLag :: non_neg_integer() | infinity
) -> ok | {stale, [atom()]}.

ensure_fresh(Tables, MaxLag) when is_list(Tables) ->
    NSs = [maps:get(namespace, T) || T <- Tables],
    bondy_oplog_core:ensure_fresh(NSs, MaxLag).

-doc """
The `publish_fun` used by a `publish => true` table: derives the
`{Key, FoldOp}` pair forwarded to `bondy_oplog_core` subscribers from a verified
`cell_apply` event. Non-`cell_apply` events are skipped. Exported so the applier
can hold a named fun (stable across instance restarts) rather than a closure.
""".
-spec publish_event(Event :: bondy_oplog_event:t()) ->
    {Key :: binary(), Op :: term()} | skip.

publish_event(Event) ->
    case bondy_oplog_event:op(Event) of
        {cell_apply, _Bucket, Key, FoldOp} ->
            {Key, FoldOp};
        _ ->
            skip
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Atom is derived once per `open_table` from values supplied by the
%% caller's own code — a bounded set, no atom-leak risk from untrusted
%% input.
namespace_atom(DbName, EntityType) ->
    list_to_atom(
        atom_to_list(DbName) ++ "_" ++ atom_to_list(EntityType)
    ).

%% @private
%% A table may be packed via `apply_batch/4` only when its CRDT advertises
%% `batchable/0` — the dot-store / grow-set types, whose ops are identified
%% per sub-key/value. Counters and scalar registers dedup / resolve by the
%% event Seq or HLC and would collapse ops sharing one packed identity, so
%% they are refused here.
assert_batchable(#{crdt_module := Mod}) when Mod =/= undefined ->
    case bondy_oplog_crdt_commutative:is_batchable(Mod) of
        true -> ok;
        false -> {error, {not_batchable, Mod}}
    end;
assert_batchable(_Table) ->
    {error, {not_batchable, undefined}}.

%% @private
%% Both batch preconditions, checked at the write API — before the WAL
%% append, so the sync AND async paths fail loudly: the table's CRDT must
%% be batchable, and the batch must carry at most one nested sub-op per
%% target (`assert_batch_ops/1`).
assert_batch(Table, Ops) ->
    case assert_batchable(Table) of
        ok -> assert_batch_ops(Ops);
        {error, _} = Err -> Err
    end.

%% @private
%% A batch is ONE dot, and a nested sub-op accumulates in its target's
%% dot-store BY dot (`bondy_oplog_crdt_nested_core:put_nested/7`) — so a
%% second sub-op on the same field/key under one packed identity would
%% silently replace the first, losing its contribution. The nested-op
%% shapes are the convention shared by every nested-capable type: the
%% struct's `{apply, FieldKey, SubOp}` and the collections'
%% `{apply, Key, SubMod, SubOp}`. Flat forms (`put`/`rmv`/`add`) are
%% exempt: sharing one dot is exactly their documented atomic,
%% mutually-concurrent batch semantics.
assert_batch_ops(Ops) ->
    Targets = [T || Op <- Ops, T <- batch_subop_targets(Op)],
    case Targets -- lists:usort(Targets) of
        [] -> ok;
        Dups -> {error, {duplicate_batch_subop, lists:usort(Dups)}}
    end.

%% @private
batch_subop_targets({apply, Target, _SubOp}) -> [Target];
batch_subop_targets({apply, Target, _SubMod, _SubOp}) -> [Target];
batch_subop_targets(_Op) -> [].

%% @private
%% Translate a declarative `#{put => #{F => V}, rmv => [F]}` map edit into
%% the flat op list `apply_batch/4` consumes. Order is irrelevant — the
%% packed ops are mutually-concurrent and target distinct map keys.
edit_to_ops(Edit) ->
    case maps:keys(Edit) -- [put, rmv] of
        [] ->
            Puts = maps:get(put, Edit, #{}),
            Rmvs = maps:get(rmv, Edit, []),
            case is_map(Puts) andalso is_list(Rmvs) of
                true ->
                    PutOps = maps:fold(
                        fun(F, V, Acc) -> [{put, F, V} | Acc] end, [], Puts
                    ),
                    RmvOps = [{rmv, F} || F <- Rmvs],
                    {ok, PutOps ++ RmvOps};
                false ->
                    {error, {invalid_map_edit, Edit}}
            end;
        Unknown ->
            {error, {unknown_map_edit_keys, Unknown}}
    end.

%% @private
%% Provision shards `0 .. Count-1` with rollback. `ProvisionFun(Shard)`
%% returns `{ok, ValA, ValB}` — the per-shard result pair, folded into two
%% accumulator maps keyed by `Shard` — or `{error, _}`. On any failure
%% every shard already built (`0 .. Shard-1`) is handed to
%% `TeardownFun(S, AccA, AccB)` (best-effort) and the error is returned.
%% Shared by the primary-shard and secondary-index-shard loops; the (A, B)
%% pair carries (instance-id, cache) for the primary and (cache, writer)
%% for an index, in provision-then-teardown order.
provision_seq(Count, ProvisionFun, TeardownFun) ->
    provision_seq(Count, ProvisionFun, TeardownFun, 0, #{}, #{}).

provision_seq(Count, _ProvisionFun, _TeardownFun, Count, AccA, AccB) ->
    {ok, AccA, AccB};
provision_seq(Count, ProvisionFun, TeardownFun, Shard, AccA, AccB) ->
    case ProvisionFun(Shard) of
        {ok, ValA, ValB} ->
            provision_seq(
                Count,
                ProvisionFun,
                TeardownFun,
                Shard + 1,
                AccA#{Shard => ValA},
                AccB#{Shard => ValB}
            );
        {error, _} = Err ->
            lists:foreach(
                fun(S) -> TeardownFun(S, AccA, AccB) end,
                lists:seq(0, Shard - 1)
            ),
            Err
    end.

%% @private
%% Provision every shard of a newly opened table. On any failure, roll
%% back partial provisioning so the caller does not inherit a half-built
%% table. `OplogOpts` is a map of extra options forwarded verbatim to
%% `bondy_oplog:start_instance/2` per shard — typically used to set
%% `backend` (e.g. `bondy_mst_pack_store`), `storage_path`, or
%% `fsync_mode`. Per-shard `fold_module`, `applier`, and `wal` opts
%% take precedence over keys with the same name in `OplogOpts`.
provision_shards(
    NS,
    DbName,
    EntityType,
    ShardCount,
    FoldModule,
    CrdtModule,
    CrdtOpts,
    OplogOpts,
    SecIndexes,
    Topology,
    TableState
) ->
    provision_seq(
        ShardCount,
        fun(Shard) ->
            provision_shard(
                NS,
                DbName,
                EntityType,
                ShardCount,
                FoldModule,
                CrdtModule,
                CrdtOpts,
                OplogOpts,
                SecIndexes,
                Topology,
                TableState,
                Shard
            )
        end,
        fun(S, Ids, Caches) ->
            teardown_shard(NS, S, Ids, Caches, Topology, TableState)
        end
    ).

%% @private
provision_shard(
    NS,
    DbName,
    EntityType,
    ShardCount,
    FoldModule,
    CrdtModule,
    CrdtOpts,
    OplogOpts,
    SecIndexes,
    Topology,
    TableState,
    Shard
) ->
    Strategy = instances_strategy(Topology),
    InstanceId = instance_id_for(Strategy, DbName, EntityType, Shard),
    case Topology:route(Shard, TableState) of
        {ok, ProjAdapter, ProjHandle} ->
            case acquire_cache(Topology, TableState, NS, ?INDEX, Shard) of
                {ok, Owner, CacheAdapter, CacheHandle} ->
                    Config = #{
                        shard_count => ShardCount,
                        cache_adapter => CacheAdapter,
                        cache_handle => CacheHandle,
                        projection_adapter => ProjAdapter,
                        projection_handle => ProjHandle,
                        fold_module => FoldModule,
                        %% Optional native CRDT for the cell projection;
                        %% `undefined` keeps the legacy fold path.
                        crdt_module => CrdtModule,
                        %% Optional per-table construction config for
                        %% `CrdtModule` (`#{}` default) — see
                        %% `bondy_oplog_cell_kernel:init/2`.
                        crdt_opts => CrdtOpts,
                        %% The CRDT's declared causal tier (default tier_0).
                        %% tier_2 provisions the per-cell DVV context stamp.
                        causal_tier => causal_tier_of(CrdtModule),
                        overlay => disabled,
                        %% Recorded so a secondary-index rebuild can find
                        %% this primary shard's applier from the registry.
                        instance_id => InstanceId,
                        %% The rebuild's primary-cell enumeration scope. The
                        %% topology owns it (it knows its keyspace layout):
                        %% `{entity, ET}` on a backend whose bucket carries the
                        %% entity type (`shared_shards`, `single_bookie`);
                        %% `all_primary` on a dedicated-Bookie backend whose
                        %% bucket is realm-keyed (`per_entity`). Lets the rebuild
                        %% derive the complete cell directory from the durable
                        %% projection (`cell_keys/2`) rather than the truncatable
                        %% MST — see `bondy_oplog_cell_utils:primary_cell_directory/4`.
                        primary_cell_scope =>
                            Topology:primary_cell_scope(TableState),
                        %% Per-table routing config persisted so a multiplexed
                        %% (`per_shard`) instance can rebuild its cell-apply
                        %% source from the registry alone after a subtree restart
                        %% (`bondy_oplog_applier:rebuild_dir_source/4`). The
                        %% bucket is the realm-independent entity-type tag the
                        %% multiplexer routes on; `undefined` for a single-table
                        %% (`per_table_shard`) instance. `publish_ns` and
                        %% `secondary_indexes` make the restart-rebuilt ctx keep
                        %% emitting merge events and dispatching index ops.
                        cell_apply_bucket =>
                            case Strategy of
                                per_shard -> collapse_bucket(EntityType);
                                _ -> undefined
                            end,
                        publish_ns => maps:get(
                            publish_ns,
                            maps:get(applier, OplogOpts, #{}),
                            undefined
                        ),
                        secondary_indexes => SecIndexes,
                        %% Bind the registry monitor to the topology's
                        %% long-lived owner (the calling process when the
                        %% topology has none), so the row survives the
                        %% transient open_table caller exactly as the
                        %% projection + cache do.
                        owner => Owner
                    },
                    case
                        bondy_oplog_core_registry:register(
                            NS, ?INDEX, Shard, Config
                        )
                    of
                        ok ->
                            start_or_join_shard_instance(
                                Strategy,
                                NS,
                                InstanceId,
                                Shard,
                                EntityType,
                                FoldModule,
                                OplogOpts,
                                SecIndexes,
                                CacheHandle,
                                Topology,
                                TableState
                            );
                        {error, _} = Err ->
                            ok = release_cache(
                                Topology, TableState, CacheHandle
                            ),
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% @private
%% A CRDT module's declared causal tier, or `tier_0` when no native CRDT
%% is configured (the legacy fold path). `tier_2` provisions the per-cell
%% DVV causal-context stamp for the table's writes.
causal_tier_of(undefined) ->
    tier_0;
causal_tier_of(CrdtModule) when is_atom(CrdtModule) ->
    %% `ensure_loaded` first: `function_exported/3` reports `false` for a
    %% not-yet-loaded module, which would silently mis-classify a tier_2
    %% CRDT as tier_0 (skipping both the DVV stamp and the safety
    %% assertion). `causal_tier/0` is a required `bondy_oplog_crdt`
    %% callback, so a loaded native CRDT always exports it.
    _ = code:ensure_loaded(CrdtModule),
    case erlang:function_exported(CrdtModule, causal_tier, 0) of
        true -> CrdtModule:causal_tier();
        false -> tier_0
    end.

%% @private
%% Fail fast at open: a `tier_2` CRDT MUST be `order_independent` — its
%% eager `apply_op` must equal the group `interpret_cog` (the DVV join is
%% commutative). A tier_2 type that is not order-independent would diverge
%% silently between the write and read paths.
assert_causal_tier_consistency(undefined) ->
    ok;
assert_causal_tier_consistency(CrdtModule) when is_atom(CrdtModule) ->
    case causal_tier_of(CrdtModule) of
        tier_2 ->
            IsOI =
                erlang:function_exported(CrdtModule, order_independent, 0) andalso
                    CrdtModule:order_independent(),
            case IsOI of
                true -> ok;
                false -> error({tier_2_requires_order_independent, CrdtModule})
            end;
        _ ->
            ok
    end.

%% @private
%% A fused writer fuses the applier `cell_apply` with the instance MST
%% install into one gen_server — valid ONLY for an ephemeral (ets
%% projection) table. A durable (leveled) table MUST keep the
%% two-process split, so reject `fused => true` on it at open_table.
-spec assert_fused_requires_ephemeral(boolean(), ets | leveled) -> ok.

assert_fused_requires_ephemeral(false, _Backend) ->
    ok;
assert_fused_requires_ephemeral(true, ets) ->
    ok;
assert_fused_requires_ephemeral(true, Backend) ->
    error({fused_requires_ephemeral, Backend}).

%% @private
%% Retention-bounded MST history is sound only where the projection holds
%% all applied state and a restart wipes everything anyway — the fused
%% (⇒ ephemeral) shape. A durable table's history is protected by
%% peer-confirmed compaction and must never be bounded by local policy.
-spec assert_mst_retention_requires_fused(map() | undefined, boolean()) -> ok.

assert_mst_retention_requires_fused(undefined, _Fused) ->
    ok;
assert_mst_retention_requires_fused(#{}, true) ->
    ok;
assert_mst_retention_requires_fused(Policy, false) ->
    error({mst_retention_requires_fused, Policy}).

%% @private
%% Provision the per-shard read cache. A topology that wants its
%% per-shard resources to outlive the transient open_table caller (an
%% ephemeral in-memory topology) exports `provision_cache/5` and hosts
%% the cache in a long-lived owner, returning that owner pid so the
%% registry monitor can bind to it too. Topologies that omit the callback
%% get the default: a `bondy_oplog_cache_ets` table owned by — and a
%% registry monitor on — the calling process (`self()`).
acquire_cache(Topology, TableState, NS, Index, Shard) ->
    case erlang:function_exported(Topology, provision_cache, 5) of
        true ->
            case Topology:provision_cache(NS, Index, Shard, #{}, TableState) of
                {ok, #{owner := Owner, adapter := Adapter, handle := Handle}} ->
                    {ok, Owner, Adapter, Handle};
                {error, _} = Err ->
                    Err
            end;
        false ->
            case bondy_oplog_cache_ets:init(NS, Index, Shard, #{}) of
                {ok, Handle} ->
                    {ok, self(), bondy_oplog_cache_ets, Handle};
                {error, _} = Err ->
                    Err
            end
    end.

%% @private
%% Release a cache acquired by `acquire_cache/5`. The owner-hosted path
%% runs the whole-table delete inside the owner (the facade caller cannot
%% — `ets:delete/1` is owner-only); the default path deletes the
%% caller-owned table directly.
release_cache(Topology, TableState, CacheHandle) ->
    case erlang:function_exported(Topology, release_cache, 2) of
        true ->
            _ = Topology:release_cache(CacheHandle, TableState),
            ok;
        false ->
            _ = bondy_oplog_cache_ets:close(CacheHandle),
            ok
    end.

%% NOTE (oplog opts merge): `OplogOpts` is merged into the per-shard
%% instance opts. `fold_module` and the applier's *routing* keys
%% (`cell_apply_target`, `secondary_indexes`) are pinned — they carry
%% per-shard routing the caller cannot meaningfully provide — and
%% override any caller value. Caller-provided applier *tuning* (e.g.
%% `apply_batch_max_events`, `oldstate_cache`) is merged in *under* the
%% pinned routing keys, so it reaches the applier instead of being
%% dropped. Everything else (`backend`, `storage_path`, `fsync_mode`,
%% `max_install_in_flight`, etc.) is forwarded verbatim.

%% @private
%% Context-sensitive default for the applier's OldValue frame-cache:
%% ON for durable (leveled) projections, OFF for ephemeral (ets). A
%% caller-supplied value under `oplog_instance_opts.applier.oldstate_cache`
%% is preserved (it always wins). See the call site in
%% `open_table_provision/7` for why.
default_oldstate_cache_opt(OplogOpts, Backend) ->
    Applier = maps:get(applier, OplogOpts, #{}),
    case maps:is_key(oldstate_cache, Applier) of
        true ->
            OplogOpts;
        false ->
            OplogOpts#{
                applier => Applier#{oldstate_cache => Backend =:= leveled}
            }
    end.

%% @private
%% When `publish => true`, wire the applier's publish keys into the shard
%% instance opts (under `applier`, where `start_shard_instance` preserves
%% caller applier tuning). All shards publish to the same table namespace `NS`,
%% so a reactor subscribes once. A named fun (not a closure) survives instance
%% restarts.
maybe_enable_publish(OplogOpts, NS, Merged) ->
    case maps:get(publish, Merged, false) of
        true ->
            Applier = maps:get(applier, OplogOpts, #{}),
            OplogOpts#{
                applier => Applier#{
                    publish_ns => NS,
                    publish_fun => fun ?MODULE:publish_event/1
                }
            };
        false ->
            OplogOpts
    end.

%% @private
%% `OplogOpts` is merged into the per-shard instance opts. `fold_module`
%% and the applier's *routing* keys (`cell_apply_target`,
%% `secondary_indexes`) are pinned — they carry per-shard routing the
%% caller cannot meaningfully provide — and override any caller value.
%% Caller-provided applier *tuning* (e.g. `apply_batch_max_events`,
%% `oldstate_cache`) is merged in *under* the pinned routing keys, so it
%% reaches the applier instead of being dropped. Everything else
%% (`backend`, `storage_path`, `fsync_mode`, `max_install_in_flight`,
%% etc.) is forwarded verbatim.
start_shard_instance(
    NS,
    InstanceId,
    Shard,
    FoldModule,
    OplogOpts,
    SecIndexes,
    CacheHandle,
    Topology,
    TableState,
    MaybeBucket
) ->
    CallerApplier0 = maps:get(applier, OplogOpts, #{}),
    %% A founding bucket (`per_shard` strategy) starts the applier's cell-apply
    %% source in `{dir, _}` mode keyed by this table's entity-type bucket, so
    %% sibling tables can join the shared instance via
    %% `bondy_oplog_instance:register_table/4`. `undefined` (`per_table_shard`)
    %% keeps the single-table source, byte-identical to the pre-collapse path.
    CallerApplier =
        case MaybeBucket of
            undefined -> CallerApplier0;
            Bucket -> CallerApplier0#{cell_apply_bucket => Bucket}
        end,
    Pinned = #{
        fold_module => FoldModule,
        %% This shard's read-side AE freshness target: the applier bumps it on
        %% each commit and the AE heartbeat (`bondy_oplog_sync_session`) on each
        %% successful round, so an idle primary shard still stays fresh — which
        %% the auth freshness fence (STORAGE_ARCHITECTURE §9.1/§9.2) depends on.
        ae_targets => [{NS, ?INDEX, Shard}],
        applier => CallerApplier#{
            cell_apply_target => {NS, ?INDEX, Shard},
            secondary_indexes => SecIndexes
        }
    },
    Opts = maps:merge(OplogOpts, Pinned),
    case bondy_oplog:start_instance(InstanceId, Opts) of
        {ok, _Sup} ->
            {ok, InstanceId, CacheHandle};
        {error, _} = Err ->
            ok = bondy_oplog_core_registry:unregister(NS, ?INDEX, Shard),
            ok = release_cache(Topology, TableState, CacheHandle),
            Err
    end.

%% @private
%% A topology's instance-mapping strategy, defaulting to `per_table_shard`.
%% Delegates to the shared resolver so the provisioning path and the topology
%% manifest agree.
instances_strategy(Topology) ->
    bondy_db_topology:instances_strategy(Topology).

%% @private
instance_id_for(per_shard, DbName, _EntityType, Shard) ->
    encode_instance_id(DbName, Shard);
instance_id_for(_PerTableShard, DbName, EntityType, Shard) ->
    encode_instance_id(DbName, EntityType, Shard).

%% @private
%% The realm-independent entity-type bucket the `per_shard` multiplexer routes
%% on. Equals `bondy_db_topology_shared_shards:bucket_for/3`, the same value the
%% write path stamps into every `{cell_apply, Bucket, _, _}` event for this
%% table — so the applier's directory key matches the events it must route.
collapse_bucket(EntityType) ->
    atom_to_binary(EntityType, utf8).

%% @private
%% Provision this table's `bondy_oplog` instance for `Shard` under the topology's
%% instance-mapping strategy. `per_table_shard` starts a dedicated instance;
%% `per_shard` founds the shared instance with this table as the seed, or — when
%% a sibling table already founded it — joins it by registering this table's
%% entity-type bucket. Both return `{ok, InstanceId, CacheHandle}` so the caller
%% accumulates the shard's instance id and cache handle uniformly.
start_or_join_shard_instance(
    per_shard,
    NS,
    InstanceId,
    Shard,
    EntityType,
    FoldModule,
    OplogOpts,
    SecIndexes,
    CacheHandle,
    Topology,
    TableState
) ->
    Bucket = collapse_bucket(EntityType),
    case bondy_oplog_instance:whereis(InstanceId) of
        undefined ->
            %% First table on this shard: found the shared instance, seeding its
            %% cell-apply directory with this table's bucket.
            start_shard_instance(
                NS,
                InstanceId,
                Shard,
                FoldModule,
                OplogOpts,
                SecIndexes,
                CacheHandle,
                Topology,
                TableState,
                Bucket
            );
        _Pid ->
            %% A sibling already founded the shard instance: register this
            %% table's bucket so its events route to this table's projection.
            %% Carry the caller's applier opts through verbatim — they hold
            %% `publish_ns`/`publish_fun` (a `publish => true` table's
            %% merge-event emission) and `oldstate_cache`, which
            %% `resolve_cell_apply_ctx/1` reads off these opts. `fold_module`
            %% comes from the registry entry, not here. Without this, a sibling
            %% table that opted into publishing would silently stop firing
            %% remote-merge reactor events.
            CallerApplier = maps:get(applier, OplogOpts, #{}),
            TableOpts = CallerApplier#{secondary_indexes => SecIndexes},
            case
                bondy_oplog_instance:register_table(
                    InstanceId, Bucket, {NS, ?INDEX, Shard}, TableOpts
                )
            of
                ok ->
                    {ok, InstanceId, CacheHandle};
                {error, _} = Err ->
                    ok = bondy_oplog_core_registry:unregister(
                        NS, ?INDEX, Shard
                    ),
                    ok = release_cache(Topology, TableState, CacheHandle),
                    Err
            end
    end;
start_or_join_shard_instance(
    _PerTableShard,
    NS,
    InstanceId,
    Shard,
    _EntityType,
    FoldModule,
    OplogOpts,
    SecIndexes,
    CacheHandle,
    Topology,
    TableState
) ->
    start_shard_instance(
        NS,
        InstanceId,
        Shard,
        FoldModule,
        OplogOpts,
        SecIndexes,
        CacheHandle,
        Topology,
        TableState,
        undefined
    ).

%% @private
%% Three-step per-shard teardown shared by primary shards and index shards:
%% stop the shard's worker (`StopFun`, guarded — `undefined` when never
%% started), unregister the `(NS, Index, Shard)` row, release its cache
%% (guarded). Best-effort: a dead worker or stale handle never aborts the
%% teardown (it is also the rollback path for a half-built table).
teardown_shard_common(
    NS, Index, Shard, WorkerMap, StopFun, CacheHandles, Topology, TableState
) ->
    case maps:get(Shard, WorkerMap, undefined) of
        undefined ->
            ok;
        Worker ->
            _ = StopFun(Worker),
            ok
    end,
    _ = bondy_oplog_core_registry:unregister(NS, Index, Shard),
    case maps:get(Shard, CacheHandles, undefined) of
        undefined ->
            ok;
        CacheHandle ->
            _ = release_cache(Topology, TableState, CacheHandle),
            ok
    end,
    ok.

%% @private
teardown_shard(NS, Shard, InstanceIds, CacheHandles, Topology, TableState) ->
    case instances_strategy(Topology) of
        per_shard ->
            teardown_shared_shard(
                NS, Shard, InstanceIds, CacheHandles, Topology, TableState
            );
        _ ->
            teardown_shard_common(
                NS,
                ?INDEX,
                Shard,
                InstanceIds,
                fun bondy_oplog:stop_instance/1,
                CacheHandles,
                Topology,
                TableState
            )
    end.

%% @private
%% Refcounted teardown of a shard instance shared by several tables (`per_shard`
%% strategy). Drops this table's routing from the shared instance, unregisters
%% its read-side registry entry, and releases its cache — then stops the shared
%% instance only once no other table's entry still references it (mirroring the
%% shared Bookie, which stays up until DB shutdown). Best-effort throughout: a
%% dead instance or stale handle never aborts the teardown (it is also the
%% rollback path for a half-built table).
teardown_shared_shard(
    NS, Shard, InstanceIds, CacheHandles, Topology, TableState
) ->
    Bucket = collapse_bucket(maps:get(entity_type, TableState)),
    InstanceId = maps:get(Shard, InstanceIds, undefined),
    _ =
        case InstanceId of
            undefined ->
                ok;
            _ ->
                _ = bondy_oplog_instance:unregister_table(InstanceId, Bucket),
                ok
        end,
    _ = bondy_oplog_core_registry:unregister(NS, ?INDEX, Shard),
    _ =
        case maps:get(Shard, CacheHandles, undefined) of
            undefined ->
                ok;
            CacheHandle ->
                _ = release_cache(Topology, TableState, CacheHandle),
                ok
        end,
    _ =
        case InstanceId of
            undefined ->
                ok;
            _ ->
                case bondy_oplog_core_registry:instance_id_in_use(InstanceId) of
                    true ->
                        ok;
                    false ->
                        _ = bondy_oplog:stop_instance(InstanceId),
                        ok
                end
        end,
    ok.

%% =============================================================================
%% PRIVATE — secondary index provisioning
%% =============================================================================

%% @private
%% Provision every secondary index declared in `indexes => [Spec]`. Each
%% index is an independent term-sharded shard-set under
%% `(NS, IndexName, SecShard)`, provisioned on the **same projection backend
%% as the originating table** (`Backend` — `ets` for an ephemeral table,
%% `leveled` for a durable one), so a durable table's indices persist in
%% leveled alongside its data and an ephemeral table's stay in ets. No
%% `bondy_oplog_instance` is started — the secondary writer (a lightweight
%% gen_server) drives these cells, not the primary applier subtree. Specs are
%% validated up front (fail before any table is created); a mid-loop failure
%% rolls back the indexes already built.
provision_indexes(Db, NS, Merged, DefaultShardCount, Backend) ->
    %% Specs were already validated in `open_table/7` before any shard was
    %% provisioned.
    Specs = maps:get(indexes, Merged, []),
    provision_indexes_loop(Db, NS, Specs, DefaultShardCount, Backend, #{}).

%% @private
validate_index_specs(Specs) when is_list(Specs) ->
    validate_index_specs(Specs, sets:new([{version, 2}]));
validate_index_specs(Other) ->
    {error, {invalid_indexes, Other}}.

validate_index_specs([], _Seen) ->
    ok;
validate_index_specs([Spec | Rest], Seen) ->
    case bondy_oplog_index_spec:validate(Spec) of
        ok ->
            Name = bondy_oplog_index_spec:name(Spec),
            case check_index_name(Name, Seen) of
                ok ->
                    case check_sec_shard_count(Spec) of
                        ok ->
                            validate_index_specs(
                                Rest, sets:add_element(Name, Seen)
                            );
                        {error, _} = Err ->
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, Reason} ->
            {error, {invalid_index_spec, Reason}}
    end.

%% @private
check_index_name(?INDEX, _Seen) ->
    %% `primary` is the substrate's reserved index id.
    {error, {reserved_index_name, ?INDEX}};
check_index_name(Name, Seen) ->
    case sets:is_element(Name, Seen) of
        true -> {error, {duplicate_index_name, Name}};
        false -> ok
    end.

%% @private
check_sec_shard_count(Spec) ->
    case maps:get(sec_shard_count, Spec, default) of
        default -> ok;
        N when is_integer(N), N > 0 -> ok;
        Bad -> {error, {invalid_sec_shard_count, Bad}}
    end.

%% @private
provision_indexes_loop(_Db, _NS, [], _DefaultShardCount, _Backend, Acc) ->
    {ok, Acc};
provision_indexes_loop(Db, NS, [Spec | Rest], DefaultShardCount, Backend, Acc) ->
    case provision_index(Db, NS, Spec, DefaultShardCount, Backend) of
        {ok, Name, Provision} ->
            provision_indexes_loop(
                Db, NS, Rest, DefaultShardCount, Backend, Acc#{
                    Name => Provision
                }
            );
        {error, _} = Err ->
            teardown_indexes(NS, Acc),
            Err
    end.

%% @private
%% Provision one index on the **same projection backend as the originating
%% table** (`Backend`): `ets` routes to the DB's memory provider (ephemeral
%% table), `leveled` routes to the DB's own durable topology (durable table),
%% so index cells live next to the data they index. Creates the index's
%% shard-set in that topology, then registers a secondary shard per
%% `SecShard` with the `index_entry` CRDT. The shard count defaults to the
%% primary's but can be overridden per index via `sec_shard_count`.
provision_index(Db, NS, Spec, DefaultShardCount, Backend) ->
    Name = bondy_oplog_index_spec:name(Spec),
    SecShardCount = maps:get(sec_shard_count, Spec, DefaultShardCount),
    CoalesceMs = bondy_oplog_index_spec:coalesce_ms(Spec),
    {Topology, EffState} = effective_topology(index_backend(Backend, Spec), Db),
    DbName = maps:get(name, Db),
    Strategy = instances_strategy(Topology),
    case Topology:open_table(Name, SecShardCount, #{}, EffState) of
        {ok, TableState, _NewState} ->
            case
                provision_index_shards(
                    NS,
                    Name,
                    SecShardCount,
                    CoalesceMs,
                    Topology,
                    TableState,
                    DbName,
                    Strategy
                )
            of
                {ok, CacheHandles, Writers} ->
                    {ok, Name, #{
                        spec => Spec,
                        sec_shard_count => SecShardCount,
                        topology => Topology,
                        table_state => TableState,
                        cache_handles => CacheHandles,
                        writer_pids => Writers
                    }};
                {error, _} = Err ->
                    _ = Topology:close_table(TableState, EffState),
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% @private
provision_index_shards(
    NS, Name, SecShardCount, CoalesceMs, Topology, TableState, DbName, Strategy
) ->
    provision_seq(
        SecShardCount,
        fun(Shard) ->
            provision_index_shard(
                NS,
                Name,
                SecShardCount,
                CoalesceMs,
                Topology,
                TableState,
                DbName,
                Strategy,
                Shard
            )
        end,
        fun(S, Caches, Writers) ->
            teardown_index_shard(
                NS, Name, S, Caches, Writers, Topology, TableState
            )
        end
    ).

%% @private
%% A secondary shard is a projection table + cache + registry entry + a
%% `bondy_oplog_secondary_writer` — no oplog instance. The
%% `bondy_oplog_crdt_index_entry` CRDT gives the substrate's read/range path
%% the right decode; the writer (started after the row is registered so its
%% `set_writer_pid/4` stamp lands) drains dispatched index ops into the
%% projection.
provision_index_shard(
    NS,
    Name,
    SecShardCount,
    CoalesceMs,
    Topology,
    TableState,
    DbName,
    Strategy,
    Shard
) ->
    WriterKey = writer_key_for(Strategy, DbName, NS, Name, Shard),
    case Topology:route(Shard, TableState) of
        {ok, ProjAdapter, ProjHandle} ->
            case acquire_cache(Topology, TableState, NS, Name, Shard) of
                {ok, Owner, CacheAdapter, CacheHandle} ->
                    Config = #{
                        shard_count => SecShardCount,
                        cache_adapter => CacheAdapter,
                        cache_handle => CacheHandle,
                        projection_adapter => ProjAdapter,
                        projection_handle => ProjHandle,
                        %% The index cell kernel is the native op-based CRDT
                        %% twin; `fold_module` is left unset (the read path
                        %% selects the crdt_module). Byte-identical encoding,
                        %% so existing durable index cells decode unchanged.
                        fold_module => undefined,
                        crdt_module => bondy_oplog_crdt_index_entry,
                        overlay => disabled,
                        %% Back-pressure atomics (in-flight count +
                        %% needs_rebuild flag). Index shards only.
                        inflight_atomics => atomics:new(2, [{signed, true}]),
                        %% The rebuild's wipe scope. The topology owns it (it
                        %% knows whether its Bookie co-locates entity types):
                        %% `{entity, ET, Name}` on a shared Bookie so a sibling
                        %% table sharing this `IndexName` is not over-wiped;
                        %% `{suffix, Name}` on a single-table handle.
                        index_clear_scope =>
                            Topology:index_clear_scope(Name, TableState),
                        %% The secondary-writer grouping key. A `per_shard`
                        %% backend shares one writer across every index of every
                        %% table on the shard; `per_table_shard` gives this index
                        %% shard its own. Recorded on the entry so a writer can
                        %% self-heal its stream set and the facade can refcount
                        %% the writer's teardown.
                        writer_key => WriterKey,
                        owner => Owner
                    },
                    case
                        bondy_oplog_core_registry:register(
                            NS, Name, Shard, Config
                        )
                    of
                        ok ->
                            case
                                find_or_start_index_writer(
                                    WriterKey, Shard, CoalesceMs
                                )
                            of
                                {ok, WriterPid} ->
                                    %% Stamp the (possibly shared) writer onto
                                    %% this stream synchronously, so the next
                                    %% index shard's find-or-start sees it and a
                                    %% dispatch can route here immediately.
                                    _ = bondy_oplog_core_registry:set_writer_pid(
                                        NS, Name, Shard, WriterPid
                                    ),
                                    {ok, CacheHandle, WriterPid};
                                {error, _} = Err ->
                                    _ = bondy_oplog_core_registry:unregister(
                                        NS, Name, Shard
                                    ),
                                    ok = release_cache(
                                        Topology, TableState, CacheHandle
                                    ),
                                    Err
                            end;
                        {error, _} = Err ->
                            ok = release_cache(
                                Topology, TableState, CacheHandle
                            ),
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% @private
%% Find the live `bondy_oplog_secondary_writer` already driving `WriterKey`, or
%% start one. Discovery is via the registry — the same registry-as-membership
%% pattern the primary collapse uses (`bondy_oplog_instance:whereis/1`): a
%% sibling index shard provisioned earlier under the same key stamped its
%% writer's pid onto its row, which `index_entries_for_writer/1` returns. Index
%% provisioning is serialised under `open_table/7`, and the founding shard's
%% `set_writer_pid/4` stamp is synchronous, so this needs no in-flight
%% accumulator: by the time a joining index shard runs, the founding one's row
%% already carries the live pid. On a `per_table_shard` backend the key is
%% unique per index shard, so this always starts a fresh writer.
find_or_start_index_writer(WriterKey, Shard, CoalesceMs) ->
    case live_writer_for(WriterKey) of
        {ok, Pid} ->
            {ok, Pid};
        none ->
            start_index_writer(WriterKey, Shard, CoalesceMs)
    end.

%% @private
live_writer_for(WriterKey) ->
    Entries = bondy_oplog_core_registry:index_entries_for_writer(WriterKey),
    Pids = [
        P
     || E <- Entries,
        P <- [bondy_oplog_core_registry:entry_writer_pid(E)],
        is_pid(P),
        is_process_alive(P)
    ],
    case Pids of
        [Pid | _] -> {ok, Pid};
        [] -> none
    end.

%% @private
start_index_writer(WriterKey, Shard, CoalesceMs) ->
    Args0 = #{writer_key => WriterKey, shard => Shard},
    Args =
        case CoalesceMs of
            undefined -> Args0;
            _ -> Args0#{coalesce_ms => CoalesceMs}
        end,
    bondy_oplog_secondary_sup:start_writer(Args).

%% @private
teardown_indexes(NS, IndexMap) ->
    maps:foreach(
        fun(Name, Provision) ->
            #{
                sec_shard_count := SecShardCount,
                topology := Topology,
                table_state := TableState,
                cache_handles := Caches,
                writer_pids := Writers
            } = Provision,
            lists:foreach(
                fun(Shard) ->
                    teardown_index_shard(
                        NS, Name, Shard, Caches, Writers, Topology, TableState
                    )
                end,
                lists:seq(0, SecShardCount - 1)
            ),
            _ = Topology:close_table(TableState, undefined),
            ok
        end,
        IndexMap
    ).

%% @private
%% Refcounted teardown of an index shard whose `bondy_oplog_secondary_writer`
%% may be shared by several index shards (`per_shard`) or its own
%% (`per_table_shard`). Drops this shard's registry entry + cache, then stops the
%% writer only once no index shard still references its `writer_key` — exactly as
%% `teardown_shared_shard/6` refcounts a shared primary instance. For a unique
%% (`per_table_shard`) key the refcount degenerates to "stop now". Best-effort
%% throughout (it is also the rollback path for a half-built index).
teardown_index_shard(
    NS, Name, Shard, CacheHandles, Writers, Topology, TableState
) ->
    %% Clean-shutdown sequence: durably flush this shard's writer and stamp its
    %% clean flag BEFORE the writer/registry row are torn down, so a graceful
    %% close leaves the index complete-to-head and the next open trusts it
    %% (`cold_start_indexes/2`). Must precede the unregister, which drops the
    %% entry whose projection handle the flag is written through.
    ok = flush_and_mark_clean(NS, Name, Shard, Writers),
    %% Read the writer's grouping key + live pid off the row before it is
    %% unregistered (the refcount and the stop both need them).
    {WriterKey, WriterPid} =
        case bondy_oplog_core_registry:lookup(NS, Name, Shard) of
            {ok, Entry} ->
                {
                    bondy_oplog_core_registry:entry_writer_key(Entry),
                    bondy_oplog_core_registry:entry_writer_pid(Entry)
                };
            not_found ->
                {undefined, undefined}
        end,
    _ = bondy_oplog_core_registry:unregister(NS, Name, Shard),
    case maps:get(Shard, CacheHandles, undefined) of
        undefined ->
            ok;
        CacheHandle ->
            _ = release_cache(Topology, TableState, CacheHandle),
            ok
    end,
    maybe_stop_index_writer(WriterKey, WriterPid, Shard, Writers),
    ok.

%% @private
%% Stop the index writer only once its `writer_key` is no longer referenced by
%% any registry entry. `undefined` key means the row was already gone (an
%% idempotent re-teardown) — the writer was handled when its last referencing
%% entry went, so there is nothing to do.
maybe_stop_index_writer(undefined, _WriterPid, _Shard, _Writers) ->
    ok;
maybe_stop_index_writer(WriterKey, WriterPid, Shard, Writers) ->
    case bondy_oplog_core_registry:writer_key_in_use(WriterKey) of
        true ->
            ok;
        false ->
            Pid =
                case WriterPid of
                    P when is_pid(P) -> P;
                    _ -> maps:get(Shard, Writers, undefined)
                end,
            case Pid of
                P2 when is_pid(P2) ->
                    _ = bondy_oplog_secondary_sup:stop_writer(P2),
                    ok;
                _ ->
                    ok
            end
    end.

%% @private
%% `flush_sync` the shard's writer (so its coalesce buffer reaches disk) then
%% stamp the durable clean-shutdown flag, both via the still-registered entry.
%% Best-effort: a dead/wedged writer or a gone row just leaves the shard dirty,
%% which a rebuild on the next open recovers. On an ephemeral (ets) index the
%% flag is wiped with the table on restart — harmless (the index rebuilds).
flush_and_mark_clean(NS, Name, Shard, Writers) ->
    case maps:get(Shard, Writers, undefined) of
        Pid when is_pid(Pid) ->
            _ =
                try
                    bondy_oplog_secondary_writer:flush_sync(Pid)
                catch
                    _:_ -> ok
                end;
        _ ->
            ok
    end,
    case bondy_oplog_core_registry:lookup(NS, Name, Shard) of
        {ok, Entry} ->
            bondy_oplog_core_registry:index_mark_clean(Entry);
        _ ->
            ok
    end.

%% @private
%% Build the static secondary-index descriptors handed to each primary
%% applier (term-diff + dispatch). `sec_shard_count` defaults to the
%% primary's shard count, matching `provision_index/5`.
index_descriptors(Specs, DefaultShardCount, Topology) ->
    %% Composite (collation) indexes on a realm-folding topology (G-1) are keyed
    %% realm-FIRST («Realm,0,enc(Tuple),0,Key») so a prefix/range scan stays
    %% inside one realm. Scalar indexes keep their term-first layout regardless
    %% (realm-scoped via the equality sub-band, `index_eq_bounds/4`). `?FOLDS_REALM`
    %% is defined later in the file, so the comparison is inlined here.
    RealmFolded =
        Topology =:= bondy_db_topology_shared_shards orelse
            Topology =:= bondy_db_topology_memory,
    [
        #{
            index_name => bondy_oplog_index_spec:name(Spec),
            spec => Spec,
            sec_shard_count => maps:get(
                sec_shard_count, Spec, DefaultShardCount
            ),
            %% Back-pressure cap, read by the primary applier at dispatch
            %% to decide whether to drop a saturating batch.
            max_inflight => bondy_oplog_index_spec:max_inflight(Spec),
            realm_folded => RealmFolded
        }
     || Spec <- Specs
    ].

%% @private
%% Invariant tripwire for the durable-index rebuild. A durable (leveled) table
%% that declares secondary indexes relies on its projection adapter exporting
%% `cell_keys/2` to enumerate the COMPLETE cell directory (under the topology's
%% `cell_keys_scope()`) — without it the rebuild would silently fall back to the
%% truncatable MST and miss every compacted cell (see
%% `bondy_oplog_cell_utils:primary_cell_directory/4`). The leveled adapter always
%% exports it, so this never fires in the current design; it pins the contract
%% so a future durable adapter — or a deletion of `cell_keys/2` from the leveled
%% adapter — fails loudly at open instead of silently degrading to the MST.
%% (Ephemeral/ETS tables legitimately omit it and fall back to the MST by
%% design, so only the `leveled` backend is asserted.)
assert_durable_rebuild_invariant(leveled, IndexMap) when
    map_size(IndexMap) > 0
->
    case
        bondy_oplog_projection_adapter:cell_keys_exported(
            bondy_db_projection_leveled
        )
    of
        true ->
            ok;
        false ->
            error(
                {missing_optional_callback,
                    {bondy_db_projection_leveled, cell_keys, 2}}
            )
    end;
assert_durable_rebuild_invariant(_Backend, _IndexMap) ->
    ok.

%% @private
%% `true` when this table's founding instance is provisioned with the WAL drain
%% gated (`oplog_instance_opts.applier.drain_gated`). The inline index cold-start
%% barrier is deferred for such tables — see the call site and
%% `cold_start_table_indexes/1`.
is_drain_gated(OplogOpts) ->
    maps:get(drain_gated, maps:get(applier, OplogOpts, #{}), false) =:= true.

cold_start_indexes(_NS, _InstanceIds, IndexMap) when map_size(IndexMap) =:= 0 ->
    %% No secondary indexes ⇒ no trust/rebuild decision and no barrier. Skipping
    %% keeps the WAL drain ASYNC for index-less tables (forcing it here would
    %% serialise every `open_table` behind a full drain — and `read/3` is meant
    %% to return from the overlay before the drain completes).
    ok;
cold_start_indexes(NS, InstanceIds, IndexMap) ->
    %% Barrier the primary shards FIRST: drain each WAL to end-of-log and apply
    %% the tail into the projection (and MST), so the trust/rebuild decision and
    %% any rebuild observe a fully-replayed primary. Without this a `rebuild_sync`
    %% derives its cell directory (the durable projection via `cell_keys/2` for a
    %% durable table, else the MST for the ephemeral ETS adapter — see
    %% `bondy_oplog_cell_utils:primary_cell_directory/4`) while the tail is still
    %% being applied, yielding an empty or partial index. Best-effort: a missing
    %% applier just leaves the prior (racy) behaviour, never blocks open.
    ok = await_primary_shards(InstanceIds),
    maps:foreach(
        fun(Name, #{sec_shard_count := SecShardCount}) ->
            case load_index_trust_markers(NS, Name, SecShardCount) of
                trusted ->
                    %% Every shard built + cleanly closed: trust the persisted
                    %% cells, just freshen so finite-`max_lag` reads pass.
                    freshen_index_shards(NS, Name, SecShardCount);
                needs_rebuild ->
                    %% A shard is unbuilt or was not cleanly closed — rebuild
                    %% the index from the (now fully-replayed) primary.
                    _ = bondy_oplog_index_rebuild:rebuild_sync(NS, Name)
            end
        end,
        IndexMap
    ).

%% @private
%% Drain + install every primary shard to end-of-log before the cold-start index
%% decision. `await_drain` flushes the WAL tail into the overlay;
%% `await_apply` installs the overlay into the MST. Both best-effort.
await_primary_shards(InstanceIds) ->
    maps:foreach(
        fun(_Shard, InstanceId) ->
            _ =
                try
                    bondy_oplog:await_drain(InstanceId)
                catch
                    _:_ -> ok
                end,
            _ =
                try
                    bondy_oplog:await_apply(InstanceId)
                catch
                    _:_ -> ok
                end
        end,
        InstanceIds
    ).

%% @private
%% Decide trust-vs-rebuild for the whole index and prime per-shard state. Per
%% shard it applies BOTH cold-start gates: the durable trust marker (built?) AND
%% the durable clean-shutdown flag (cleanly closed to head last lifetime?). The
%% index is trusted only if every shard passes both. As a side effect it loads
%% the trust marker into the in-memory `needs_rebuild` flag (so a later read
%% sees the right state) and CLEARS the clean-shutdown flag (so a crash this
%% lifetime leaves the shard dirty → rebuilt on the next open).
load_index_trust_markers(NS, Name, SecShardCount) ->
    Flags = [
        shard_needs_rebuild(NS, Name, Shard)
     || Shard <- lists:seq(0, SecShardCount - 1)
    ],
    case lists:member(true, Flags) of
        true -> needs_rebuild;
        false -> trusted
    end.

%% @private
shard_needs_rebuild(NS, Name, Shard) ->
    case bondy_oplog_core_registry:lookup(NS, Name, Shard) of
        {ok, Entry} ->
            %% Gate 1 — built? (loads the durable trust marker into the
            %% in-memory `needs_rebuild` flag as a side effect).
            MarkerNeedsRebuild =
                bondy_oplog_core_registry:index_load_rebuild_marker(Entry),
            %% Gate 2 — cleanly closed to head last lifetime? Read the
            %% clean-shutdown flag, then clear it so a crash this lifetime
            %% rebuilds (the clear is journalled before any post-open index
            %% write; leveled's prefix recovery makes a partial crash safe).
            WasClean = bondy_oplog_core_registry:index_has_clean(Entry),
            ok = bondy_oplog_core_registry:index_clear_clean(Entry),
            MarkerNeedsRebuild orelse (not WasClean);
        _ ->
            %% No registry entry (shouldn't happen post-provision) — be safe
            %% and force a rebuild.
            true
    end.

%% @private
%% Freshen every shard of a trusted index (bump AE) so a finite `max_lag` read
%% passes without a rebuild — including an empty shard, which a write path
%% would otherwise leave sentinel-stale forever.
freshen_index_shards(NS, Name, SecShardCount) ->
    Now = erlang:monotonic_time(millisecond),
    lists:foreach(
        fun(Shard) ->
            _ = bondy_oplog_core_registry:bump_ae(NS, Name, Shard, Now)
        end,
        lists:seq(0, SecShardCount - 1)
    ).

%% =============================================================================
%% PRIVATE — secondary index reads
%% =============================================================================

%% @private
%% Resolve an index by name and hand its spec + secondary shard count to
%% `Fun`. `{error, {unknown_index, _}}` when the table has no such index.
with_index(Table, IndexName, Fun) ->
    Indexes = maps:get(indexes, Table, #{}),
    case maps:find(IndexName, Indexes) of
        {ok, #{spec := Spec, sec_shard_count := SecShardCount}} ->
            Fun(Spec, SecShardCount);
        error ->
            {error, {unknown_index, IndexName}}
    end.

%% @private
index_bucket(
    #{db_topology := Topology, table_state := TableState, entity_type := ET},
    Realm,
    IndexName
) ->
    PrimaryBucket = Topology:bucket_for(ET, Realm, TableState),
    bondy_oplog_index_key:bucket(PrimaryBucket, IndexName).

%% @private
%% The `{max_lag, Ms}` gate, scoped to exactly the secondary shards the
%% read touches. An un-freshened (never-written) secondary shard reads as
%% maximally stale (the registry inits its `ae_atomics` to a sentinel), so
%% any finite bound refuses until the relevant writer has flushed (bumping
%% that shard's freshness).
%%
%% Granularity matches the read shape because the index is **term-sharded**
%% — a single write freshens only the one shard its term hashes to:
%%   - equality (`index_get`) touches one shard, so it checks one shard;
%%   - range (`index_range`) scatters, so it checks every shard.
%%
%% A namespace-wide freshness check would conflate the index's freshness with
%% the *primary* shards' (and every sibling index's): the primary applier never
%% bumps its own freshness here, so a namespace-wide finite `max_lag` would
%% refuse forever even after the index caught up — and a per-shard term-sharded
%% write could never satisfy an all-shards check. The freshness signal a reader
%% actually wants is "are the shard(s) I am about to read current".
%%
%% The gate also returns the worst observed lag (so the caller — and the
%% `{stale_secondary, IndexName, Lag}` error — carries a diagnostic), and a
%% shard whose `needs_rebuild` flag is set (saturation drop / writer crash) is
%% unconditionally stale (`Lag = infinity`) until a rebuild clears it,
%% regardless of its AE timestamp.
ensure_shard_fresh(_NS, _IndexName, _Shard, infinity) ->
    ok;
ensure_shard_fresh(NS, IndexName, Shard, MaxLag) ->
    case shard_lag(NS, IndexName, Shard) of
        Lag when Lag =< MaxLag -> ok;
        Lag -> {stale, Lag}
    end.

%% @private
ensure_index_fresh(_NS, _IndexName, _SecShardCount, infinity) ->
    ok;
ensure_index_fresh(NS, IndexName, SecShardCount, MaxLag) ->
    WorstLag = lists:foldl(
        fun(Shard, Acc) -> max_lag(Acc, shard_lag(NS, IndexName, Shard)) end,
        0,
        lists:seq(0, SecShardCount - 1)
    ),
    case WorstLag =< MaxLag of
        true -> ok;
        false -> {stale, WorstLag}
    end.

%% @private
%% Per-shard lag: `infinity` for an unknown shard, a shard flagged
%% `needs_rebuild`, or a never-freshened shard; otherwise the wall-clock ms
%% since its last AE bump.
shard_lag(NS, IndexName, Shard) ->
    case bondy_oplog_core_registry:lookup(NS, IndexName, Shard) of
        not_found ->
            infinity;
        {ok, Entry} ->
            case bondy_oplog_core_registry:index_needs_rebuild(Entry) of
                true ->
                    infinity;
                false ->
                    case
                        bondy_oplog_core_registry:entry_ever_freshened(Entry)
                    of
                        false ->
                            infinity;
                        true ->
                            Now = erlang:monotonic_time(millisecond),
                            erlang:max(
                                0,
                                Now -
                                    bondy_oplog_core_registry:entry_last_ae(
                                        Entry
                                    )
                            )
                    end
            end
    end.

%% @private
max_lag(infinity, _) -> infinity;
max_lag(_, infinity) -> infinity;
max_lag(A, B) when is_integer(A), is_integer(B) -> erlang:max(A, B).

%% @private
%% Diagnostic snapshot of one secondary shard's lag, in-flight backlog,
%% and rebuild flag (for `index_lag/2`).
shard_lag_info(NS, IndexName, Shard) ->
    Lag = shard_lag(NS, IndexName, Shard),
    {Inflight, NeedsRebuild} =
        case bondy_oplog_core_registry:lookup(NS, IndexName, Shard) of
            {ok, Entry} ->
                {
                    bondy_oplog_core_registry:index_inflight(Entry),
                    bondy_oplog_core_registry:index_needs_rebuild(Entry)
                };
            not_found ->
                {0, false}
        end,
    #{lag => Lag, inflight => Inflight, needs_rebuild => NeedsRebuild}.

%% @private
%% Forward only the scan-shaping opts to the substrate; `max_lag`/`shard`
%% are facade-level and must not leak into the adapter opts.
index_range_opts(Opts) ->
    maps:with([limit], Opts).

%% @private
%% A stale index read either refuses with the lag diagnostic, or — when
%% the caller passes `fallback => primary` — runs the supplied
%% primary-scan thunk (slow but correct).
stale_or_fallback(Opts, IndexName, Lag, FallbackFun) ->
    case maps:get(fallback, Opts, refuse) of
        primary -> FallbackFun();
        refuse -> {error, {stale_secondary, IndexName, Lag}}
    end.

%% @private
%% Run a stale-index fallback scan: enumerate the realm's primary cells and
%% hand them to `RowsFun` (which recomputes terms/columns and produces the
%% sorted, limited `[{Key, ColumnsMap}]`). Propagates a scan error verbatim.
primary_scan(Table, Realm, RowsFun) ->
    case primary_cells(Table, Realm) of
        {ok, Cells} -> {ok, RowsFun(Cells)};
        {error, _} = Err -> Err
    end.

%% @private
cell_terms(Spec, Value) ->
    lists:usort(bondy_oplog_index_spec:terms(Spec, Value)).

%% @private
%% Equality fallback: enumerate the realm's primary cells, recompute each
%% value's index terms, and keep the keys whose terms include `NormTerm`.
%% Returns the same `{Key, ColumnsMap}` shape as `index_get/5`.
primary_scan_eq(Table, Realm, Spec, NormTerm, Opts) ->
    Limit = maps:get(limit, Opts, bondy_oplog_core:default_range_limit()),
    primary_scan(Table, Realm, fun(Cells) ->
        Rows = [
            {Key, recompute_columns(Spec, Value)}
         || {Key, Value, _Hlc} <- Cells,
            lists:member(NormTerm, cell_terms(Spec, Value))
        ],
        lists:sublist(lists:keysort(1, Rows), Limit)
    end).

%% @private
%% Range fallback: emit one `{Key, ColumnsMap}` per (matching term, key)
%% in `[Lo, Hi)`, globally ordered by `(term, key)` to match
%% `index_range/6`.
primary_scan_range(Table, Realm, Spec, Lo, Hi, Opts) ->
    Limit = maps:get(limit, Opts, bondy_oplog_core:default_range_limit()),
    primary_scan(Table, Realm, fun(Cells) ->
        Rows = [
            {Term, Key, recompute_columns(Spec, Value)}
         || {Key, Value, _Hlc} <- Cells,
            Term <- cell_terms(Spec, Value),
            Term >= Lo,
            Term < Hi
        ],
        Sorted = lists:sublist(lists:sort(Rows), Limit),
        [{K, C} || {_T, K, C} <- Sorted]
    end).

%% @private
recompute_columns(Spec, Value) ->
    bondy_oplog_index_spec:decode_projection(
        bondy_oplog_index_spec:project(Spec, Value)
    ).

%% @private
%% Enumerate every primary cell in `Realm` (materialised values), across
%% all primary shards, with overlay disabled. Bounded by
%% `db.primary_scan_limit`; a scan that fills it is logged as potentially
%% incomplete.
%%
%% Scoped and un-folded exactly like `list/2`, and for the same reason: a whole
%% bucket scan (`{<<>>, infinity}`) returning raw storage keys would, under a
%% realm-folding topology, hand a stale-index fallback read OTHER realms' cells
%% still carrying their `<<Realm, 0>>` prefix — so the fallback would disagree
%% with the very `index_get/5` result it stands in for, both in which rows it
%% produces and in the shape of their keys.
primary_cells(#{namespace := NS, db_topology := Topology} = Table, Realm) ->
    PrimaryBucket = primary_bucket(Table, Realm),
    {Lo, Hi} = realm_scan_range(Topology, Realm),
    ScanLimit = bondy_db_config:primary_scan_limit(),
    case
        bondy_oplog_core:range_all(
            NS,
            ?INDEX,
            PrimaryBucket,
            {Lo, Hi},
            #{limit => ScanLimit, include_overlay => false}
        )
    of
        {ok, Cells} ->
            case length(Cells) >= ScanLimit of
                true ->
                    ?LOG_WARNING(#{
                        description =>
                            "bondy_db primary-scan fallback hit its cell "
                            "cap; the stale-index fallback result may be "
                            "incomplete.",
                        namespace => NS,
                        realm => Realm,
                        cap => ScanLimit
                    });
                false ->
                    ok
            end,
            {ok, [
                {uncell_key(Topology, Realm, K), V, Hlc}
             || {K, V, Hlc} <- Cells
            ]};
        {error, _} = Err ->
            Err
    end.

%% @private
primary_bucket(
    #{db_topology := Topology, table_state := TableState, entity_type := ET},
    Realm
) ->
    Topology:bucket_for(ET, Realm, TableState).

%% @private
read_index(Topology, Realm, NS, IndexName, SecBucket, Low, High, RangeOpts) ->
    case
        bondy_oplog_core:range(NS, IndexName, SecBucket, {Low, High}, RangeOpts)
    of
        {ok, Rows} -> {ok, index_rows(Topology, Realm, Rows)};
        {error, _} = Err -> Err
    end.

%% @private
%% A range row is `{SecKey, Columns, _Hlc}` where `SecKey` is the
%% `(Term, PrimaryKey)` composite and `Columns` is the index entry's
%% `to_value/1` (the denormalised columns binary, `<<>>` for pointer-only).
%% Recover the primary key from the composite and decode the columns.
%%
%% `PrimaryKey` is the cell's storage key, which a realm-folding topology
%% (G-1) has NUL-prefixed with the realm — undo that so callers get the key
%% they wrote (and can feed back to `read/3`).
%%
%% The secondary index bucket is realm-agnostic, so cross-realm entries sharing
%% a term are physically co-located. `index_get/5` never sees another realm's
%% row because it restricts its scan to the term's realm sub-band
%% (`index_eq_bounds/4`); the term-RANGE `index_range/6` cannot, because a term
%% range spans realms non-contiguously.
%%
%% So this FILTERS on the realm rather than assuming it. Rows belonging to
%% another realm are dropped, which is what a caller asking about `Realm` means
%% — and is the only safe option, since blindly stripping `byte_size(Realm) + 1`
%% bytes off a foreign key yields a corrupted key indistinguishable from a real
%% one. `index_range/6` is therefore realm-CORRECT; it is still not realm-
%% EFFICIENT, since it scans every shard and discards the rows it filters. See
%% `index_get/5`'s docs for what making it efficient would cost.
index_rows(Topology, Realm, Rows) ->
    lists:filtermap(
        fun({SecKey, Columns, _Hlc}) ->
            PK = bondy_oplog_index_key:decode_pk(SecKey),
            case uncell_key_of_realm(Topology, Realm, PK) of
                {ok, Key} ->
                    {true, {
                        Key, bondy_oplog_index_spec:decode_projection(Columns)
                    }};
                mismatch ->
                    false
            end
        end,
        Rows
    ).

%% @private
instance_for_shard(#{instance_ids := Ids}, Shard) ->
    maps:get(Shard, Ids).

-doc """
The shard index a `(Realm, Key)` cell routes to under `Table`'s
`partition_strategy`. Write (`apply/4`) and point read (`read/3`) both call this
so they always address the same shard; a caller that wants to read a band on its
co-located shard (e.g. the membership group join) passes the band's lower bound
as `Key`.

- `entity` — legacy `phash2({Bucket, FoldedKey}, N)`, where `FoldedKey` is the
  realm-folded cell key. Byte-identical to hash-only routing, so a table
  that declares no strategy routes exactly as before.
- `aggregate` — `phash2({Realm, AggregateRoot}, N)`: a subject's record + its
  grants + sources co-locate on one shard (atomic batch), while subjects
  spread across shards so a single realm still fills every core. The shard is
  independent of the Bucket, which is precisely what co-locates different entity
  types of one subject (`aggregate_root/2` picks the root from the key).
- `realm` — `phash2(realm_prefix(Realm, Depth), N)`: a whole realm (or a shared
  dotted-prefix group of realms) on one shard. Single realm ⇒ one shard (use
  only when per-realm atomicity outweighs the lost write parallelism).
""".
-spec shard_for(Table :: table(), Realm :: realm(), Key :: binary()) ->
    non_neg_integer().

shard_for(#{shard_count := SC} = Table, Realm, Key) ->
    case maps:get(partition_strategy, Table, entity) of
        entity ->
            #{
                db_topology := Topology,
                entity_type := ET,
                table_state := TS
            } = Table,
            Bucket = Topology:bucket_for(ET, Realm, TS),
            SKey = cell_key(Topology, Realm, Key),
            erlang:phash2({Bucket, SKey}, SC);
        aggregate ->
            Root = aggregate_root(
                maps:get(aggregate_root, Table, identity), Key
            ),
            erlang:phash2({Realm, Root}, SC);
        realm ->
            Prefix = realm_prefix(
                Realm, maps:get(realm_prefix_depth, Table, 1)
            ),
            erlang:phash2(Prefix, SC)
    end.

%% @private
%% Extract the aggregate root from a cell key per the table's `aggregate_root`:
%%
%%   identity   — the subject IS the key (e.g. a user record keyed by username),
%%                so the whole key is the root.
%%   leading_col — the subject prefixes an order-preserving composite key
%%                 (`encode_col(Subject), 0, term_to_binary(Rest)`, as in
%%                 `bondy_rbac:encode_key/1` / `bondy_rbac_source:encode_key/1`).
%%                 Decode that leading column so the grant/source hashes to the
%%                 SAME `{Realm, Subject}` shard as the subject's own record —
%%                 the record keys by the plain (un-encoded) subject, so the
%%                 column MUST be decoded back to that term to match.
%%   second_col — the subject is the SECOND column of a band-tagged composite
%%                 key `encode_col(Tag), 0, encode_col(Subject), 0, ...` (the
%%                 permutation-index pattern, as in the `security_group_members`
%%                 forward `[?MEMBER_FWD, User, Group]` / reverse
%%                 `[?MEMBER_REV, Group, User]` bands). The leading column is a
%%                 band marker shared by every cell, so routing on it would
%%                 collapse a band onto one shard; routing on the second column
%%                 instead co-locates each fact with its leading ENTITY — a
%%                 forward cell with its user (the user record's shard), a
%%                 reverse cell with its group (the group record's shard). The
%%                 codec leaves exactly one `0x00` per column boundary (columns
%%                 are escaped `0x00`-free), so the second column is the bytes
%%                 between the 1st and 2nd separator, decoded back to its term.
aggregate_root(identity, Key) ->
    Key;
aggregate_root(leading_col, Key) when is_binary(Key) ->
    case binary:match(Key, <<0>>) of
        {Pos, 1} ->
            ColBin = binary:part(Key, 0, Pos),
            bondy_oplog_index_key:decode_col(ColBin);
        nomatch ->
            %% No separator (a non-composite key under a leading_col table):
            %% defensively treat the whole key as the root.
            Key
    end;
aggregate_root(second_col, Key) when is_binary(Key) ->
    case binary:match(Key, <<0>>) of
        {Pos1, 1} ->
            Rest = binary:part(Key, Pos1 + 1, byte_size(Key) - Pos1 - 1),
            ColBin =
                case binary:match(Rest, <<0>>) of
                    {Pos2, 1} -> binary:part(Rest, 0, Pos2);
                    nomatch -> Rest
                end,
            bondy_oplog_index_key:decode_col(ColBin);
        nomatch ->
            %% No separator (a non-composite key): nothing to co-locate on.
            Key
    end.

%% @private
%% The shard key for `partition_strategy = realm`: the first `Depth` dotted
%% components of the realm URI joined by `.` (so realms sharing that prefix
%% co-locate), or the whole realm when it has at most `Depth` components or
%% `Depth =< 0`.
realm_prefix(Realm, Depth) when is_integer(Depth), Depth >= 1 ->
    case binary:split(Realm, <<".">>, [global]) of
        Parts when length(Parts) > Depth ->
            iolist_to_binary(lists:join(<<".">>, lists:sublist(Parts, Depth)));
        _ ->
            Realm
    end;
realm_prefix(Realm, _Depth) ->
    Realm.

%% @private
%% Realm separation (G-1). The topology does pure shard placement and never
%% sees realms — see `bondy_db_topology:route/2`: "realm separation is done
%% above the topology, by the facade folding Realm into the cell key". The
%% bucket-as-entity-type topologies need this: their Bucket is just the
%% EntityType (so a `per_shard` instance can multiplex tables by bucket), and
%% two realms with the same Key would otherwise collide on one cell — so the
%% facade folds Realm into the key instead. `shared_shards` and `memory` are
%% these. The remaining topologies (`per_entity`, `single_bookie`) put the realm
%% in the Bucket, so their cells are already realm-separated and their Key is
%% passed through verbatim (keeping their shard formula `phash2({Bucket, Key})`
%% unchanged).
%%
%% A NUL separator isolates the realm prefix for realm-scoped range scans
%% (`list/2`): realm URIs are NUL-free text, so `[<<Realm,0>>, <<Realm,1>>)`
%% captures exactly that realm's keys, and the original key is recovered by
%% stripping the known `byte_size(Realm) + 1` prefix (the key's own bytes,
%% which MAY contain NULs, are preserved verbatim after the separator).
%% (`?FOLDS_REALM/1` itself is defined with the other macros at the top of
%% this module; a macro must precede every use, and `fold_all/4` — a public
%% export — uses it far above here. The rationale above stays with the code it
%% explains.)

cell_key(Topology, Realm, Key) when is_binary(Realm), is_binary(Key) ->
    case ?FOLDS_REALM(Topology) of
        true ->
            ok = assert_nul_free_realm(Realm),
            <<Realm/binary, 0, Key/binary>>;
        false ->
            Key
    end.

%% @private
%% G-1's injectivity precondition, ENFORCED. A NUL inside `Realm` makes the
%% fold non-injective — realms `<<"a">>` and `<<"a",0,"b">>` collide distinct
%% `(Realm, Key)` pairs onto one storage cell — and `realm_scan_range/2`'s
%% band for the shorter realm then CONTAINS the longer realm's rows, leaking
%% reads across the tenancy boundary. Realm URIs are validated upstream, but
%% this facade's contract cannot borrow another app's validation: one
%% comparison here, cold next to the I/O it fronts, closes the boundary.
assert_nul_free_realm(Realm) ->
    binary:match(Realm, <<0>>) =:= nomatch orelse
        error({badarg, {realm_contains_nul, Realm}}),
    ok.

%% @private
%% Recover the caller's key from a (possibly folded) storage key, for the paths
%% whose scan was ALREADY bounded to `Realm`'s key band (`range/5`, `list/2`,
%% `range_all/5`, and `index_get/5` via `index_eq_bounds/4`). A key from another
%% realm cannot occur there, so it is a broken invariant rather than input, and
%% is raised instead of guessed at.
uncell_key(Topology, Realm, Stored) ->
    case uncell_key_of_realm(Topology, Realm, Stored) of
        {ok, Key} ->
            Key;
        mismatch ->
            error({badarg, {foreign_realm_key, Realm, Stored}})
    end.

%% @private
%% The realm-checked inverse of `cell_key/3`: `mismatch` when `Stored` does not
%% carry exactly `<<Realm, 0>>`.
%%
%% The check is the point. Stripping a FIXED `byte_size(Realm) + 1` bytes is
%% only correct if the key really is this realm's — given another realm's key it
%% silently returns a corrupted suffix (or badmatches when the key is shorter),
%% and the caller cannot tell either outcome from a real key. That is unreachable
%% for the realm-bounded scans above, but NOT for the term-range `index_range/6`,
%% whose band spans realms non-contiguously.
%%
%% Matching the bound `Realm` in the pattern also makes the test exact: a prefix
%% that merely starts with the same bytes (realm `<<"a">>` vs `<<"ab">>`) fails,
%% because the `0` separator must land immediately after it. That is the same
%% injectivity `assert_nul_free_realm/1` protects on the write side.
uncell_key_of_realm(Topology, Realm, Stored) when
    is_binary(Realm), is_binary(Stored)
->
    case ?FOLDS_REALM(Topology) of
        true ->
            Size = byte_size(Realm),
            case Stored of
                <<Realm:Size/binary, 0, Key/binary>> -> {ok, Key};
                _ -> mismatch
            end;
        false ->
            %% Realm-in-bucket topologies store the key verbatim; the Bucket
            %% already isolates the realm, so there is no prefix to check.
            {ok, Stored}
    end.

%% @private
%% The `[Lo, Hi)` storage-key range covering exactly `Realm`'s cells. Under a
%% realm-folding topology this is the realm's NUL-prefixed key band; otherwise
%% the Bucket already isolates the realm, so it is the whole bucket.
realm_scan_range(Topology, Realm) when is_binary(Realm) ->
    case ?FOLDS_REALM(Topology) of
        true ->
            %% Guarded on the SCAN side too: even with all writes guarded, a
            %% NUL-bearing realm's band is a sub-band of the NUL-free prefix
            %% realm's band, so an unguarded scan would read the victim
            %% realm's rows.
            ok = assert_nul_free_realm(Realm),
            {<<Realm/binary, 0>>, <<Realm/binary, 1>>};
        false ->
            {<<>>, infinity}
    end.

%% @private
%% Page a cross-shard scatter-scan to completion: `range_all/5` caps each
%% merged page (default 1000), so `list/2` loops, advancing the inclusive
%% lower bound to the successor of the last STORAGE key, until a short page
%% signals band exhaustion. Rows accumulate in ascending storage-key order;
%% the caller unfolds keys once, on the complete result.
list_pages(NS, Bucket, Lo, Hi, Acc) ->
    Limit = 1000,
    Opts = #{limit => Limit},
    case bondy_oplog_core:range_all(NS, ?INDEX, Bucket, {Lo, Hi}, Opts) of
        {ok, Rows} when length(Rows) < Limit ->
            {ok, lists:append(lists:reverse([Rows | Acc]))};
        {ok, Rows} ->
            {LastKey, _, _} = lists:last(Rows),
            list_pages(NS, Bucket, <<LastKey/binary, 0>>, Hi, [Rows | Acc]);
        {error, _} = Err ->
            Err
    end.

%% @private
%% Fold a single-shard range's upper bound. `infinity` becomes the realm's
%% upper bound under a folding topology so the scan stays within `Realm`.
fold_high(Topology, Realm, infinity) ->
    case ?FOLDS_REALM(Topology) of
        true ->
            {_, Hi} = realm_scan_range(Topology, Realm),
            Hi;
        false ->
            infinity
    end;
fold_high(Topology, Realm, High) when is_binary(High) ->
    cell_key(Topology, Realm, High).

%% @private
%% Realm-scoped equality bounds for `index_get/5`. An index entry key is
%% `<<enc(Term), 0, PrimaryKey>>`. Under a realm-folding topology (G-1) the
%% `PrimaryKey` is itself `<<Realm, 0, Key>>`, so within a term's band the
%% entries group by realm and one realm's entries are the contiguous
%% sub-band `[<<enc(Term),0,Realm,0>>, <<enc(Term),0,Realm,1>>)` — the same
%% NUL-separator argument as `realm_scan_range/2`, one level deeper.
%% Restricting to that sub-band is what makes the read realm-correct on the
%% shared (realm-agnostic) index bucket. `After` (a primary key in caller
%% terms — for a folding topology the un-folded `Key`) resumes strictly
%% after that entry: `<<…, After, 0>>` is the smallest key greater than
%% `After`'s, so its own entry is excluded and the next page begins.
%% Non-folding topologies isolate the realm in the bucket, so they scan the
%% plain term band (`equality_bounds/1`) with the same `After` successor.
index_eq_bounds(Topology, Realm, Norm, After) ->
    Enc = bondy_oplog_index_key:encode_term(Norm),
    case ?FOLDS_REALM(Topology) of
        true ->
            Lo =
                case After of
                    undefined ->
                        <<Enc/binary, 0, Realm/binary, 0>>;
                    _ when is_binary(After) ->
                        <<Enc/binary, 0, Realm/binary, 0, After/binary, 0>>
                end,
            {Lo, <<Enc/binary, 0, Realm/binary, 1>>};
        false ->
            Lo =
                case After of
                    undefined ->
                        <<Enc/binary, 0>>;
                    _ when is_binary(After) ->
                        <<Enc/binary, 0, After/binary, 0>>
                end,
            {Lo, <<Enc/binary, 1>>}
    end.

%% @private
%% The order-preserving tuple encoding of a composite query (a prefix of, or full,
%% collation), per-column normalised the same way the stored term was.
composite_enc(Spec, Cols) ->
    bondy_oplog_index_key:encode_tuple(
        bondy_oplog_index_spec:normalize_term(Spec, Cols)
    ).

%% @private
%% Realm-scoped prefix-equality bounds for a composite index. Under a folding
%% topology (G-1) the index key is realm-FIRST («Realm,0,enc(Tuple),0,Key»), so
%% the band stays inside `Realm`; non-folding topologies isolate the realm in the
%% bucket and scan the plain prefix band. `Enc` is the prefix's tuple encoding,
%% so the `0`/`1` suffix selects every fact whose leading columns match.
composite_eq_bounds(Topology, Realm, Enc) ->
    case ?FOLDS_REALM(Topology) of
        true ->
            {
                <<Realm/binary, 0, Enc/binary, 0>>,
                <<Realm/binary, 0, Enc/binary, 1>>
            };
        false ->
            {<<Enc/binary, 0>>, <<Enc/binary, 1>>}
    end.

%% @private
%% Realm-scoped half-open range bounds `[LoCols, HiCols)` for a composite index,
%% realm-FIRST under a folding topology (so the term range stays in one realm).
composite_range_bounds(Topology, Realm, EncLo, EncHi) ->
    case ?FOLDS_REALM(Topology) of
        true ->
            {
                <<Realm/binary, 0, EncLo/binary, 0>>,
                <<Realm/binary, 0, EncHi/binary, 0>>
            };
        false ->
            {<<EncLo/binary, 0>>, <<EncHi/binary, 0>>}
    end.

%% @private
%% Freshness-gated scatter scan of a composite index over `{Low, High}`, decoding
%% each entry's full collation tuple. A composite index is sharded by the whole
%% tuple, so a prefix/range scatters across all shards and merges (`range_all`).
composite_scan(Table, Realm, IndexName, Spec, SecShardCount, {Low, High}, Opts) ->
    NS = maps:get(namespace, Table),
    Topology = maps:get(db_topology, Table),
    SecBucket = index_bucket(Table, Realm, IndexName),
    Arity = bondy_oplog_index_spec:arity(Spec),
    MaxLag = maps:get(max_lag, Opts, bondy_oplog_index_spec:max_lag(Spec)),
    case ensure_index_fresh(NS, IndexName, SecShardCount, MaxLag) of
        ok ->
            case
                bondy_oplog_core:range_all(
                    NS,
                    IndexName,
                    SecBucket,
                    {Low, High},
                    index_range_opts(Opts)
                )
            of
                {ok, Rows} ->
                    {ok, composite_rows(Topology, Realm, Arity, Rows)};
                {error, _} = Err ->
                    Err
            end;
        {stale, Lag} ->
            {error, {stale_secondary, IndexName, Lag}}
    end.

%% @private
%% Decode each composite entry into `{Columns, Projections}`: strip the realm
%% prefix (folding topology only), then split the body into its `Arity` collation
%% columns (the fact) and the trailing primary key (discarded — the covering
%% answer is the columns).
composite_rows(Topology, Realm, Arity, Rows) ->
    Folded = ?FOLDS_REALM(Topology),
    [
        composite_row(Folded, Realm, Arity, SecKey, Columns)
     || {SecKey, Columns, _Hlc} <- Rows
    ].

composite_row(true, Realm, Arity, SecKey, Columns) ->
    Skip = byte_size(Realm) + 1,
    <<_:Skip/binary, Body/binary>> = SecKey,
    {Cols, _PK} = bondy_oplog_index_key:decode_composite(Body, Arity),
    {Cols, bondy_oplog_index_spec:decode_projection(Columns)};
composite_row(false, _Realm, Arity, SecKey, Columns) ->
    {Cols, _PK} = bondy_oplog_index_key:decode_composite(SecKey, Arity),
    {Cols, bondy_oplog_index_spec:decode_projection(Columns)}.

%% @private
%% Per-table-shard instance id (`DbName-EntityType-Shard`): one oplog instance
%% (WAL + MST + applier) per table per shard. Used by the `per_table_shard`
%% topologies.
%% `-` and not `/`: an instance id names ONE directory, and `bondy_oplog`
%% refuses an id containing `/` when the instance is started
%% (`bondy_oplog_path:validate_instance_id/1`) — a `/` would turn the id into
%% path structure, so the id could no longer be recovered from the path and
%% every consumer doing path arithmetic on it would mis-parse the result. No
%% catalogue db or entity-type atom contains `-`, and they are snake_case, so
%% `-` separates visibly where `_` would not.
encode_instance_id(DbName, EntityType, Shard) ->
    iolist_to_binary([
        id_part(DbName),
        $-,
        id_part(EntityType),
        $-,
        integer_to_binary(Shard)
    ]).

%% @private
%% A component may not contain the separator, because the encoding has to be
%% INJECTIVE: an instance id names one storage directory, so two distinct
%% instances sharing an id would share a WAL and an MST. Without this check the two arities collide —
%% `encode_instance_id('a-b', 1)` and `encode_instance_id(a, b, 1)` both give
%% `<<"a-b-1">>` — and the differing arity no longer separates them. Refused
%% here, where the id is built, rather than discovered as two tables writing
%% the same files.
id_part(Atom) when is_atom(Atom) ->
    Bin = atom_to_binary(Atom, utf8),
    case binary:match(Bin, <<"-">>) of
        nomatch -> Bin;
        _ -> error({invalid_instance_id_component, Atom})
    end.

%% @private
%% Per-shard instance id (`DbName-Shard`): one oplog instance shared by every
%% table on the shard, routed by the entity-type bucket. Used by the `per_shard`
%% topology (`shared_shards`). Dropping the entity type collapses the WAL/MST
%% paths to `wal/<DbName>/<Shard>` and `mst/.../<DbName>/<Shard>` — the instance
%% appends `/<InstanceId>` to the shared base path, so the shard owns one WAL and
%% one MST regardless of how many tables it carries.
encode_instance_id(DbName, Shard) ->
    iolist_to_binary([id_part(DbName), $-, integer_to_binary(Shard)]).

%% @private
%% The grouping key of the `bondy_oplog_secondary_writer` that drives an index
%% shard — the secondary-side twin of `instance_id_for/4`. `per_shard` collapses
%% every index of every table on a secondary shard onto one writer
%% (`DbName/idx/SecShard`); `per_table_shard` keeps one writer per index shard
%% (`NS/IndexName/idx/SecShard`). The two forms have different arity, so they
%% never collide.
writer_key_for(per_shard, DbName, _NS, _IName, SecShard) ->
    encode_writer_key(DbName, SecShard);
writer_key_for(_PerTableShard, _DbName, NS, IName, SecShard) ->
    encode_writer_key(NS, IName, SecShard).

%% @private
%% Per-shard secondary-writer key (`DbName/idx/SecShard`): one writer shared by
%% every index of every table on the shard, demuxing by `(NS, IndexName)` stream.
encode_writer_key(DbName, SecShard) ->
    iolist_to_binary([
        atom_to_binary(DbName, utf8),
        "/idx/",
        integer_to_binary(SecShard)
    ]).

%% @private
%% Per-table-shard secondary-writer key (`NS/IndexName/idx/SecShard`): one writer
%% per index shard (a degenerate single-stream directory).
encode_writer_key(NS, IName, SecShard) ->
    iolist_to_binary([
        atom_to_binary(NS, utf8),
        $/,
        atom_to_binary(IName, utf8),
        "/idx/",
        integer_to_binary(SecShard)
    ]).

%% @private
await(InstanceId) ->
    case bondy_oplog:await_apply(InstanceId) of
        ok -> ok;
        {error, timeout} = Err -> Err
    end.

merge_opts(DbOpts, TableOpts) ->
    %% Per-table opts win over DB defaults. `topology` and
    %% `topology_opts` are DB-level only and intentionally dropped from
    %% the cascade — a per-table override of those would be incoherent.
    Cascadable = maps:without([topology, topology_opts], DbOpts),
    maps:merge(Cascadable, TableOpts).
