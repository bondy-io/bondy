%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_topology).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Behaviour for `bondy_db` **physical topologies**.

A topology maps logical addresses `(EntityType, Shard, Realm)` onto
physical `bondy_oplog_projection_adapter` handles. The facade
(`bondy_db`) is topology-agnostic: it tells the topology *what* it needs
(open this table with N shards, route this `(Shard, Realm)` lookup) and
the topology decides *how* to satisfy that — how many Bookies to run,
how to assign shards to them, how to map realms to buckets, where on
disk each Bookie lives.

The two reference implementations bundled with the test profile are:

- `bondy_db_topology_per_entity` — one Bookie per `(EntityType, Shard)`
  shared across realms; bucket = Realm. Suitable when sharding's goal is
  write-concurrency: each shard owns its own Bookie writer pipeline.
- `bondy_db_topology_single_bookie` — one Bookie for the whole DB;
  bucket = `(Realm, EntityType)` composite. Suitable for tests and tiny
  deployments where the per-Bookie write serialiser is not a bottleneck.

Other layouts (per-realm physical isolation, per-realm multi-table)
plug in by implementing this behaviour and supplying a different module
to `bondy_db:open/2` via `Opts#{topology => Mod}`.

## State separation

The behaviour distinguishes two pieces of state:

- `State` — the topology's process-wide bookkeeping, owned by the `Db`
  handle. Typically holds the supervisor pid that owns the Bookies and
  any cross-table state.
- `TableState` — per-table view derived from `State` at `open_table/4`
  time. Typically carries the per-shard `{Bookie, BookieOpts}` map that
  `route/2` resolves against.

`open_table/4` returns both the new global `State` and the per-table
`TableState`; the facade hands `TableState` to subsequent `route/2`
calls and `close_table/2` calls. This separation lets a topology pool
or share Bookies across tables (e.g., single_bookie reuses one Bookie
for every entity type) while still giving each table a stable handle.

## Adapter contract

`route/2` returns `{Adapter, Handle}` where `Adapter` is a module
implementing `bondy_oplog_projection_adapter` and `Handle` is whatever
that adapter expects from its own `open/4`. The facade does not call
the adapter's `open/4` directly — the topology has already done that
inside `open_table/4` and is handing back ready-to-use handles.

The handle is **per-shard**, not per-`(shard, realm)`. The substrate
(`bondy_oplog_core`) is keyed by `(Namespace, Index, Shard)` with no realm
dimension; for topologies whose Bucket does not carry the realm, the
facade folds `Realm` into the storage key with a NUL separator
(`<<Realm/binary, 0, UserKey/binary>>` — G-1, versioned by the manifest's
`key_encoding_version`) so a single per-shard handle serves every realm.

## What the behaviour does NOT cover

- WAL, replication, applier, or overlay wiring — those are substrate
  concerns (`bondy_oplog_core`, `bondy_oplog_*`). The facade wires them
  directly. The one exception is the optional cache-hosting hook
  (`provision_cache/5` + `release_cache/2`): a topology whose per-shard
  resources must outlive the transient `open_table/3` caller (an
  ephemeral in-memory topology) implements it to host the read cache in
  a long-lived owner; topologies that omit it get the default
  caller-owned cache.
- Realm lifecycle (creation, retirement, migration). Topology routes
  realms it is asked about; coordinating which realms exist is the
  caller's concern.
- Telemetry or metrics — left to the adapter.
""").

-export_type([
    state/0,
    table_state/0,
    entity_type/0,
    realm/0,
    bucket/0,
    shard/0
]).

-type state() :: term().
-type table_state() :: term().
-type entity_type() :: atom().
-type realm() :: binary().
-type bucket() :: term().
-type shard() :: non_neg_integer().

%% =============================================================================
%% CALLBACKS
%% =============================================================================

-doc """
Initialise the topology for a DB named `DbName`. Returns the topology's
process-wide state (often a supervisor pid plus bookkeeping). The
returned `State` is opaque to `bondy_db`.

`Opts` is the `topology_opts` map from the DB's `Opts`. Topology
implementations document their own required keys.
""".
-callback init(DbName :: atom(), Opts :: map()) ->
    {ok, state()} | {error, term()}.

-doc """
Provision the physical resources for `EntityType` with `ShardCount`
shards. Returns the per-table view `TableState` and the updated
process-wide `State`. The facade stashes `TableState` in the `Table`
handle and threads `State` back through the DB handle.

`Opts` is the table's effective opts (DB defaults cascaded with the
caller's per-table opts).
""".
-callback open_table(
    EntityType :: entity_type(),
    ShardCount :: pos_integer(),
    Opts :: map(),
    State :: state()
) -> {ok, table_state(), state()} | {error, term()}.

-doc """
Resolve `Shard` inside the table represented by `TableState`.
Returns the projection adapter module and the handle to call it with.

The handle spans every realm inside the shard — realm separation is
done above the topology, by the facade (`bondy_db`) folding `Realm`
into the cell key before invoking the adapter. Topologies therefore
do not see realms at all; their job is purely shard placement.

The handle is the same shape the adapter expects from its `open/4` —
the topology has already opened it at `open_table/4` time and is
handing back the ready handle.
""".
-callback route(
    Shard :: shard(),
    TableState :: table_state()
) -> {ok, Adapter :: module(), Handle :: term()} | {error, term()}.

-doc """
Compose the storage-layer **Bucket** for `(EntityType, Realm)` inside
the table represented by `TableState`. Bucket is the leveled/Riak-style
partition tag that travels with every projection-adapter call; the
topology owns the composition rule because it knows what its Bookie
layout disambiguates by Bucket vs by NS.

Examples:

- **per_entity** topology (one Bookie per `(EntityType, Shard)`, shared
  across realms): `bucket_for(_, Realm, _) -> Realm` — EntityType is
  already implicit in the Bookie, Bucket isolates realms inside it.
- **single_bookie** topology (one Bookie for everything):
  `bucket_for(EntityType, Realm, _) -> <<Realm, "/", EntityType>>` —
  Bucket has to disambiguate both EntityType and Realm.
""".
-callback bucket_for(
    EntityType :: entity_type(),
    Realm :: realm(),
    TableState :: table_state()
) -> bucket().

-doc """
The `bondy_oplog_projection_adapter:clear_scope()` the secondary-index rebuild
must use when wiping an index of the table represented by `TableState` before a
re-fold. The topology owns this because the right scope is a property of its
**Bookie/handle layout**, not of the index:

- A topology whose handle co-locates several entity types in one keyspace
  (`shared_shards`, `single_bookie`) returns `{entity, EntityTypeBin, IndexName}`
  so the wipe stays confined to this table — a sibling table sharing the same
  `IndexName` in the same Bookie is left untouched.
- A topology whose handle holds a single logical table (`per_entity`'s dedicated
  Bookie, `memory`'s per-`(NS, Index, Shard)` table) returns `{suffix, IndexName}`
  — there is no sibling to over-wipe, so the cheaper bare-suffix scope suffices.

`EntityType` (an atom) is the same value passed to `bucket_for/3`; the binary in
the `{entity, _, _}` scope MUST equal `bucket_for/3`'s `EntityType` component
(`atom_to_binary(EntityType, utf8)`).
""".
-callback index_clear_scope(
    IndexName :: atom(),
    TableState :: table_state()
) -> bondy_oplog_projection_adapter:clear_scope().

-doc """
The `bondy_oplog_projection_adapter:cell_keys_scope()` a secondary-index rebuild
passes to the projection adapter's `cell_keys/2` to enumerate this table's
PRIMARY cell directory from the durable projection.

The topology owns it because it knows its own keyspace layout:

- A backend whose primary bucket encodes the entity type — `shared_shards`
  (bucket = `ET`) and `single_bookie` (bucket = `<<Realm,"/",ET>>`) — returns
  `{entity, atom_to_binary(EntityType, utf8)}`, so a co-located sibling table is
  excluded.
- A DEDICATED single-table Bookie whose primary bucket is realm-keyed
  (`per_entity`, bucket = `<<Realm>>`) returns `all_primary` — every non-index
  bucket is one of this table's primary buckets, and the entity type is not in
  the bucket to filter on.

The binary in an `{entity, _}` scope MUST equal `bucket_for/3`'s `EntityType`
component (`atom_to_binary(EntityType, utf8)`).
""".
-callback primary_cell_scope(
    TableState :: table_state()
) -> bondy_oplog_projection_adapter:cell_keys_scope().

-doc """
Release the resources owned by `TableState`. Returns the updated
process-wide `State`.

A topology MAY skip releasing resources that are shared with other
tables (e.g., a single_bookie topology keeps its Bookie alive until
`shutdown/1` even after every `close_table/2` is invoked).
""".
-callback close_table(
    TableState :: table_state(),
    State :: state()
) -> {ok, state()}.

-doc """
Tear down the topology: stop every Bookie, release every resource,
unlink supervisors. Called from `bondy_db:close/1`.
""".
-callback shutdown(State :: state()) -> ok.

-doc """
**Optional.** Provision the per-shard read cache for `(NS, Index, Shard)`
and name the long-lived process that owns it.

A topology implements this when its per-shard substrate resources must
outlive the transient process that calls `bondy_db:open_table/3` — the
motivating case is an ephemeral in-memory topology whose ETS tables
must survive the caller so the node-global appliers keep writing them.
The returned `owner` is the process the facade attributes BOTH the
cache table AND the `bondy_oplog_core_registry` monitor to: when it dies,
the registration is torn down and (for an ETS cache) the table is
reclaimed by the VM.

Topologies that omit this callback get the default **long-lived caller**
contract — the facade creates a `bondy_oplog_cache_ets` table owned by,
and registers a registry monitor on, the calling process. A topology
that exports `provision_cache/5` MUST also export `release_cache/2`.

`Opts` mirrors the 4th argument of `bondy_oplog_cache_adapter:init/4`.
Returns `#{owner := pid(), adapter := module(), handle := term()}` —
the adapter/handle pair is registered verbatim and used on the read
path exactly as a caller-owned cache would be.
""".
-callback provision_cache(
    NS :: atom(),
    Index :: atom(),
    Shard :: shard(),
    Opts :: map(),
    TableState :: table_state()
) ->
    {ok, #{owner := pid(), adapter := module(), handle := term()}}
    | {error, term()}.

-doc """
**Optional.** Release a cache provisioned by `provision_cache/5`.

Runs the whole-table delete inside the owning process — for an ETS
cache the facade cannot do it itself (`ets:delete/1` is owner-only).
Paired with `provision_cache/5`; a topology that exports one MUST
export the other.
""".
-callback release_cache(
    Handle :: term(),
    TableState :: table_state()
) -> ok.

-doc """
**Optional.** Declares how this topology maps tables onto `bondy_oplog`
instances.

- `per_table_shard` (the default for a topology that omits this callback) — each
  `(EntityType, Shard)` gets its own instance: one WAL + MST + applier per table
  per shard. Required when the topology's `bucket_for/3` is not realm-independent
  (`per_entity`, `single_bookie`, `memory`), because the bucket carried in each
  event cannot by itself identify the table.

- `per_shard` — all tables on a shard share **one** instance (one WAL + MST +
  applier), distinguished by the `bucket` each event carries. Valid ONLY for a
  topology whose `bucket_for/3` returns the realm-independent entity-type tag
  (`atom_to_binary(EntityType, utf8)`) and whose `route/2` returns one shared
  projection handle per shard — i.e. `shared_shards`. The shared instance's
  lifecycle is refcounted across the tables on the shard, exactly as the shared
  Bookie's is.
""".
-callback instances_strategy() -> per_table_shard | per_shard.

-optional_callbacks([
    provision_cache/5, release_cache/2, instances_strategy/0
]).

-export([instances_strategy/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Resolve a topology module's `instances_strategy/0`, defaulting to
`per_table_shard` when the module omits the optional callback. The single
resolver shared by the provisioning path (`bondy_db`) and the topology manifest
(`bondy_db_manifest`), so both agree on a topology's instance-mapping strategy.
""".
-spec instances_strategy(Module :: module()) ->
    per_table_shard | per_shard.

instances_strategy(Module) when is_atom(Module) ->
    case erlang:function_exported(Module, instances_strategy, 0) of
        true -> Module:instances_strategy();
        false -> per_table_shard
    end.
