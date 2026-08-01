%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_core_registry).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Node-shared registry of per-`(namespace, index, shard)` triples for
`bondy_oplog_core`.

Each shard publishes one entry containing the handles `bondy_oplog_core`
needs to satisfy a read:

| Field | Source |
|---|---|
| `shard_count` | namespace configuration |
| `cache_adapter` + `cache_handle` | owner's cache adapter init |
| `projection_adapter` + `projection_handle` | owner's projection open |
| `overlay` | owner's `bondy_oplog_db_overlay:new/0` |
| `fold_module` | namespace's fold strategy |

The table is a single `public set` ETS owned by this gen_server. Reads
go directly to ETS (`lookup/3` is the hot path; no roundtrip).
`register/4` and `unregister/3` are `gen_server:call/2` so the server
can monitor the registering process and tear the row down if the owner
dies. The hot read path remains lock-free.

## Restart semantics

The ETS table is owned by this gen_server; if the gen_server dies the
table dies with it. On supervisor restart, `init/1` creates a fresh
empty table — **all in-memory monitor state is lost and previously
registered shards are orphaned** (their atomics refs still exist, but
the registry has no row pointing to them). Subsequent `lookup/3` calls
will return `not_found` until owners re-register.

There is currently no recovery protocol: owners are not signalled when
the registry restarts. Operators should either set the supervisor's
`intensity` so the registry effectively never restarts, or wire the
applier to periodically validate its own registrations and re-register
on `not_found`. The substrate does not police this.

## Owner DOWN cleanup

When an owner dies, the registry deletes the ETS row and removes the
monitor. It does **not** call `close/1` on the cache, projection, or
overlay adapters — those handles were created by (and may be tied to
the lifecycle of) the owner process. For ETS-based adapters this is
correct: ETS reclaims tables owned by the dead process. Adapters that
own external resources (file handles, sub-processes, connection
pools) MUST set up their own owner-monitoring inside the adapter — the
substrate guarantees registry-row cleanup only.

## Why a separate registry from `bondy_oplog_registry`

`bondy_oplog_registry` is per-instance (effectively per-namespace —
the existing substrate uses `instance_id` as the namespace). The
read API needs a richer key: `(namespace, index, shard)` —
indexes (primary and secondaries) are a new dimension not present in
`bondy_oplog_instance`. Keeping the registries separate avoids
retrofitting `bondy_oplog_registry`'s record with index/shard fields
that would be `undefined` for the 99% of consumers that have not opted
into the read-side projection.

## Why ETS, not persistent_term

`persistent_term:put/2` triggers a global GC scan on every process on
the node. With many shards doing many config refreshes (e.g., a
secondary's lag bound changing), that's a non-starter. ETS `insert` is
constant-time, no global side effects, and `read_concurrency: true`
keeps reads parallel.
""").

-define(TABLE, bondy_oplog_core_registry_tab).

%% "Infinitely stale" freshness sentinel. Chosen so that on a node whose
%% `monotonic_time(millisecond)` offset is large and negative,
%% `Now - sentinel` is always a huge positive number — an un-bumped (or
%% deliberately invalidated) shard fails any finite `max_lag` check.
%% `-(1 bsl 62)` leaves headroom above the signed-int64 floor so the
%% subtraction never wraps.
-define(STALE_SENTINEL, -(1 bsl 62)).

%% The reserved `Index` value of a primary shard's registry key
%% (`{NS, primary, Shard}`); secondary-index shards key on the index name.
%% Mirrors `bondy_oplog_instance:?PRIMARY_INDEX` / `bondy_db:?INDEX`.
-define(PRIMARY_INDEX, primary).

%% Atomics slot layout for an index shard's `inflight_ref` (back-pressure).
%% Slot 1 counts ops dispatched to the secondary writer but not yet flushed
%% (the unbounded-mailbox bound); slot 2 is a `needs_rebuild` flag (0 | 1)
%% raised on a saturation drop or a writer crash and cleared only by a
%% completed rebuild.
-define(INFLIGHT_SLOT, 1).
-define(NEEDS_REBUILD_SLOT, 2).

-record(entry, {
    key :: shard_key(),
    shard_count :: pos_integer(),
    cache_adapter :: module(),
    cache_handle :: term(),
    projection_adapter :: module(),
    projection_handle :: term(),
    overlay :: disabled | bondy_oplog_db_overlay:tid(),
    fold_module :: atom() | undefined,
    %% Per-shard freshness counter, written by the applier on each
    %% projection commit (or by anti-entropy on each successful round).
    %% Stored as `monotonic_time(millisecond)`; read wait-free by
    %% `ensure_fresh/2`.
    ae_atomics :: atomics:atomics_ref(),
    %% Per-shard high-water HLC mark
    %% (`bondy_oplog_high_water`). Tracks the highest HLC of any
    %% `cell_apply` event the applier has materialised into the
    %% shard's projection. Allocated here so it can be shared between
    %% the applier (writer) and read-only consumers
    %% (catalogue-freshness reporting, bootstrap finalisation) without
    %% threading through the applier's process state.
    high_water_ref :: bondy_oplog_high_water:ref(),
    %% Per-namespace policy. `ap` (default) places no constraint on reads;
    %% `cp` rejects `eventual`-consistency batch reads to prevent unfenced
    %% staleness. Owners pass this on `register/4`; the substrate trusts the
    %% value to be consistent across shards of the same namespace (consumer
    %% responsibility).
    consistency_class :: ap | cp,
    %% Secondary-index writer pid for this `(NS, IndexName, SecShard)`
    %% triple. `undefined` for primary shards and for index shards whose
    %% `bondy_oplog_secondary_writer` has not yet stamped itself (a brief
    %% startup window). The primary applier reads it via
    %% `entry_writer_pid/1` to dispatch index updates after a successful
    %% projection write. Set out-of-band via `set_writer_pid/4` (a
    %% single-field `ets:update_element`, no monitor change) — the
    %% projection-handle owner, not the writer, owns the registry monitor.
    writer_pid = undefined :: pid() | undefined,
    %% Per-index-shard back-pressure atomics. `undefined` for primary shards.
    %% Two slots: in-flight op count (slot `?INFLIGHT_SLOT`) and a
    %% `needs_rebuild` flag (slot `?NEEDS_REBUILD_SLOT`). The primary applier
    %% reads slot 1 at dispatch to decide whether to drop a saturating batch;
    %% the secondary writer decrements it on flush. Slot 2 gates
    %% `index_get`/`index_range` freshness so reads refuse from a saturation
    %% drop until a rebuild clears it. Allocated by the facade on index-shard
    %% registration.
    inflight_ref = undefined :: atomics:atomics_ref() | undefined,
    %% Primary shard's oplog `instance_id` (`bondy_oplog`), recorded so a
    %% secondary-index rebuild can discover the primary appliers for a
    %% namespace from the registry alone (no table handle), re-fold each
    %% one's MST, and re-dispatch the index ops. `undefined` for secondary
    %% (index) shards, which have no oplog instance.
    instance_id = undefined :: binary() | undefined,
    %% Optional native operation-based CRDT module
    %% (`bondy_oplog_crdt`) for this table's cell projection. When set,
    %% the applier's cell kernel routes through `interpret_cog`/`apply_op`
    %% instead of the `fold_module`. `undefined` (default) keeps the legacy
    %% fold path, so the selector is reversible per table. Appended last so
    %% existing `#entry`-index `ets:update_element` writes stay valid.
    crdt_module = undefined :: module() | undefined,
    %% The CRDT module's declared causal tier (`bondy_oplog_crdt:tier()`),
    %% read from `crdt_module:causal_tier()` at table open. `tier_0`
    %% (default) = scalar HLC only; `tier_2` = the applier stamps a
    %% per-cell causal context (DVV) into the event `meta` for this
    %% table's writes. Appended last so existing `#entry`-index
    %% `ets:update_element` writes stay valid.
    causal_tier = tier_0 :: bondy_oplog_crdt:tier(),
    %% Index shards only. The `bondy_oplog_projection_adapter:clear_scope()`
    %% the rebuild passes to `Adapter:clear/2` when wiping this shard before a
    %% re-fold. The owner (`bondy_db`) computes it from the topology's keyspace
    %% layout: `{entity, ET, IndexName}` on a backend that co-locates several
    %% tables in one Bookie (`shared_shards`, `single_bookie`) so a sibling
    %% table sharing the same `IndexName` is not over-wiped; `{suffix, _}` on a
    %% single-table handle. `undefined` for primary shards and as a backward-
    %% compatible default — `reset_target_shard/1` then falls back to the
    %% bare-suffix scope. Appended last so existing `#entry`-index
    %% `ets:update_element` writes stay valid.
    index_clear_scope = undefined ::
        bondy_oplog_projection_adapter:clear_scope() | undefined,
    %% Primary shards only. The `bondy_oplog_projection_adapter:cell_keys_scope()`
    %% the secondary-index rebuild passes to `Adapter:cell_keys/2` to enumerate
    %% this primary's complete cell directory from the durable projection. The
    %% owner (`bondy_db`) computes it from the topology's keyspace layout:
    %% `{entity, ET}` on a backend whose primary bucket carries the entity type
    %% (`shared_shards`, `single_bookie`); `all_primary` on a dedicated-Bookie
    %% backend whose bucket is realm-keyed (`per_entity`). `undefined` for index
    %% shards and as a backward-compatible default — the rebuild then falls back
    %% to the MST walk. Appended last so existing `#entry`-index
    %% `ets:update_element` writes stay valid.
    primary_cell_scope = undefined ::
        bondy_oplog_projection_adapter:cell_keys_scope() | undefined,
    %% Primary shards only. The per-table routing config the multiplexer needs to
    %% (re)build a cell-apply ctx from the registry ALONE, so a `one_for_all`
    %% instance-subtree restart can self-heal its `cell_apply_source` for every
    %% table on the shard (the runtime `register_table/4` adds are otherwise lost
    %% on restart). The registry entry survives the restart; the applier/fused
    %% instance rebuilds its source from every primary entry whose `instance_id`
    %% matches.
    %%
    %% `cell_apply_bucket`: the entity-type Bucket this table's events carry —
    %% the multiplexer's directory key. Set only for a `per_shard` (collapsed)
    %% instance, where it is realm-independent (`atom_to_binary(ET)`); `undefined`
    %% for a `per_table_shard` (single-table) instance, whose source is keyless.
    %% Appended last so existing `#entry`-index `ets:update_element` writes stay
    %% valid.
    cell_apply_bucket = undefined :: binary() | undefined,
    %% `publish_ns`: the namespace remote-merge events publish under
    %% (`publish => true` tables), or `undefined`. Authoritative here so a
    %% restart-rebuilt ctx keeps emitting; `undefined` falls back to the opts.
    %% Appended last.
    publish_ns = undefined :: atom() | undefined,
    %% `secondary_indexes`: the index descriptors the applier dispatches index
    %% ops against. Authoritative here so a restart-rebuilt ctx keeps indexing;
    %% `undefined` (NOT `[]`) means "unset — fall back to the opts" (a raw,
    %% non-`bondy_db` registration), while `[]` means "no indexes". Appended last.
    secondary_indexes = undefined :: [map()] | undefined,
    %% Index shards only. The grouping key of the `bondy_oplog_secondary_writer`
    %% that drives this index shard — the secondary-side twin of `instance_id`.
    %% A single writer serves every index shard sharing a `writer_key`, demuxing
    %% the dispatched ops back to each `(NS, IndexName, SecShard)` stream. The
    %% owner (`bondy_db`) sets its granularity from the topology's instance
    %% strategy: coarse (`DbName/idx/SecShard`, shared across every index of the
    %% DB on that secondary shard) on a `per_shard` backend; fine
    %% (`NS/IndexName/idx/SecShard`, one writer per index shard) on a
    %% `per_table_shard` backend. `undefined` for primary shards and for a raw
    %% registration. The durable basis for refcounted writer teardown
    %% (`writer_key_in_use/1`) and crash/epoch self-healing
    %% (`index_entries_for_writer/1`), exactly as `instance_id` is for primaries.
    %% Appended last so existing `#entry`-index `ets:update_element` writes stay
    %% valid.
    writer_key = undefined :: binary() | undefined,
    %% Optional per-table construction config for a `crdt_module` that needs
    %% more than an event to build its bottom state (e.g.
    %% `bondy_oplog_crdt_struct`'s schema) — passed to
    %% `bondy_oplog_cell_kernel:init/2` instead of the plain `init/1` at
    %% cold-start. `#{}` (default) for every CRDT whose `init/0` needs
    %% nothing. Appended last so existing `#entry`-index `ets:update_element`
    %% writes stay valid.
    crdt_opts = #{} :: map()
}).

-record(state, {
    %% MonitorRef -> shard_key()
    mon_to_key = #{} :: #{reference() := shard_key()},
    %% shard_key() -> MonitorRef
    key_to_mon = #{} :: #{shard_key() := reference()},
    %% Fresh `make_ref()` per gen_server start. Exposed via
    %% `current_epoch/0` and broadcast on `bondy_oplog_core_events`
    %% under topic `bondy_oplog_core_registry_started`. Owners cache the
    %% epoch and treat a change as "registry was restarted; re-register".
    epoch :: reference()
}).

-type shard_key() :: {atom(), atom(), non_neg_integer()}.
-type shard_entry() :: #entry{}.
-type config() :: #{
    shard_count := pos_integer(),
    cache_adapter := module(),
    cache_handle := term(),
    projection_adapter := module(),
    projection_handle := term(),
    fold_module := atom() | undefined,
    %% Optional. Native operation-based CRDT module for the cell
    %% projection; when present it takes precedence over `fold_module`.
    crdt_module => module(),
    %% Optional. Per-table construction config for `crdt_module`, passed to
    %% `bondy_oplog_cell_kernel:init/2` at cold-start (see `#entry.crdt_opts`).
    %% `#{}` (default) for every CRDT whose `init/0` needs nothing.
    crdt_opts => map(),
    %% Optional. The `crdt_module`'s declared `causal_tier()`. Defaults
    %% to `tier_0` (scalar HLC). `tier_2` provisions the per-cell DVV
    %% causal-context stamp for this table's writes.
    causal_tier => bondy_oplog_crdt:tier(),
    %% Required. Pass `disabled` to opt out of overlay-merge on the read
    %% path (the facade does this — `apply/4`'s `await_apply` step
    %% provides read-your-writes without an overlay). Pass a `tid()`
    %% when overlay-merge is desired.
    overlay := disabled | bondy_oplog_db_overlay:tid(),
    %% Optional. If absent, the registry allocates a single-counter
    %% atomics ref on register. Owners that want shared accounting
    %% (e.g., across a hot/cold reload) can pass their own ref.
    ae_atomics => atomics:atomics_ref(),
    %% Optional. Pid the registry will monitor; when this process exits
    %% the registration is torn down automatically. Defaults to the
    %% calling process.
    owner => pid(),
    %% Optional. Per-namespace consistency policy. Defaults to `ap`. See
    %% `read_batch/2` for the enforcement rule.
    consistency_class => ap | cp,
    %% Optional. Per-index-shard back-pressure atomics. Allocated by the
    %% facade for index shards (`atomics:new(2, [{signed, true}])`); absent
    %% for primary shards.
    inflight_atomics => atomics:atomics_ref(),
    %% Optional. The owning oplog `instance_id` for a primary shard, so a
    %% rebuild can find the primary applier. Absent for index shards.
    instance_id => binary(),
    %% Optional. Index shards only. The
    %% `bondy_oplog_projection_adapter:clear_scope()` the rebuild passes to
    %% `Adapter:clear/2`. Absent ⇒ `reset_target_shard/1` falls back to the
    %% bare-suffix scope.
    index_clear_scope => bondy_oplog_projection_adapter:clear_scope(),
    %% Optional. Primary shards only. The
    %% `bondy_oplog_projection_adapter:cell_keys_scope()` the rebuild passes to
    %% `Adapter:cell_keys/2` to enumerate this primary's cells. Absent ⇒ the
    %% rebuild falls back to the MST walk.
    primary_cell_scope => bondy_oplog_projection_adapter:cell_keys_scope()
}.

-export_type([shard_entry/0, config/0]).

-export([child_spec/0]).
-export([start_link/0]).

-export([register/4]).
-export([unregister/3]).
-export([set_writer_pid/4]).
-export([lookup/3]).
-export([shard_count/2]).
-export([list/0]).

%% Restart-recovery protocol.
-export([current_epoch/0]).

%% Diagnostic / invariant-checking helper.
-export([snapshot_for_invariants/0]).

%% Freshness.
-export([bump_ae/3]).
-export([bump_ae/4]).
-export([high_water_hlc/3]).
-export([bump_ae_targets/1]).
-export([bump_ae_targets/2]).
-export([last_ae_at/3]).
-export([ever_freshened/3]).
-export([shards_for/1]).
-export([primary_shards_for/1]).
-export([instance_id_in_use/1]).
-export([primary_entries_for_instance/1]).
-export([writer_key_in_use/1]).
-export([index_entries_for_writer/1]).
-export([namespaces/0]).

%% Field accessors (so callers do not need the header).
-export([entry_key/1]).
-export([entry_cache_adapter/1]).
-export([entry_cache_handle/1]).
-export([entry_projection_adapter/1]).
-export([entry_projection_handle/1]).
-export([entry_overlay/1]).
-export([entry_fold_module/1]).
-export([entry_shard_count/1]).
-export([entry_ae_atomics/1]).
-export([entry_high_water_ref/1]).
-export([entry_consistency_class/1]).
-export([entry_writer_pid/1]).
-export([entry_instance_id/1]).
-export([entry_crdt_module/1]).
-export([entry_crdt_opts/1]).
-export([entry_causal_tier/1]).
-export([entry_index_clear_scope/1]).
-export([entry_primary_cell_scope/1]).
-export([entry_cell_apply_bucket/1]).
-export([entry_publish_ns/1]).
-export([entry_secondary_indexes/1]).
-export([entry_writer_key/1]).
-export([entry_last_ae/1]).
-export([entry_ever_freshened/1]).

%% Index-shard back-pressure helpers. Operate on the entry's `inflight_ref`;
%% all are wait-free and a strict no-op (or `false`) when the ref is
%% `undefined` (a primary shard).
-export([index_inflight_add/2]).
-export([index_inflight_sub/2]).
-export([index_inflight/1]).
-export([index_inflight_reset/1]).
-export([index_mark_rebuild/1]).
-export([index_clear_rebuild/1]).
-export([index_needs_rebuild/1]).
-export([index_load_rebuild_marker/1]).
-export([index_mark_clean/1]).
-export([index_has_clean/1]).
-export([index_clear_clean/1]).
-export([reset_stale_ae/1]).

%% Namespace-level consistency_class lookup.
-export([consistency_class/1]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% =============================================================================
%% API
%% =============================================================================

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register(
    Namespace :: atom(),
    Index :: atom(),
    Shard :: non_neg_integer(),
    Config :: config()
) -> ok | {error, {missing_required_field, atom()}}.

register(NS, Index, Shard, Config) when
    is_atom(NS),
    is_atom(Index),
    is_integer(Shard),
    Shard >= 0,
    is_map(Config)
->
    %% Validate required keys here, before the gen_server call. A bad
    %% config crashing inside the gen_server would wipe the monitor
    %% bookkeeping for every other registration on the node — a
    %% single misconfigured call is not allowed to take the substrate
    %% down with it.
    case validate_config(Config) of
        ok ->
            Owner = maps:get(owner, Config, self()),
            gen_server:call(
                ?MODULE, {register, NS, Index, Shard, Owner, Config}
            );
        {error, _} = Err ->
            Err
    end.

-spec unregister(atom(), atom(), non_neg_integer()) -> ok.

unregister(NS, Index, Shard) ->
    gen_server:call(?MODULE, {unregister, {NS, Index, Shard}}).

-doc """
Stamp the secondary-index writer pid onto an already-registered
`(NS, IndexName, SecShard)` row. A single-field `ets:update_element/3`:
lock-free, no monitor change (the registry monitor stays bound to the
projection-handle owner from `register/4` — the writer is a client, not
the owner, of that row). Returns `not_found` when no row exists for the
triple (e.g. the index shard was torn down, or the registry restarted
and the owner has not re-registered yet). Called by
`bondy_oplog_secondary_writer` at init and on the registry-restart epoch.
""".
-spec set_writer_pid(atom(), atom(), non_neg_integer(), pid()) ->
    ok | not_found.

set_writer_pid(NS, Index, Shard, Pid) when
    is_atom(NS), is_atom(Index), is_integer(Shard), Shard >= 0, is_pid(Pid)
->
    case
        ets:update_element(
            ?TABLE, {NS, Index, Shard}, {#entry.writer_pid, Pid}
        )
    of
        true -> ok;
        false -> not_found
    end.

-doc """
Return the current epoch reference. A new epoch is allocated on each
gen_server start and broadcast on
`bondy_oplog_core_events:notify(bondy_oplog_core_registry_started, Epoch)`.
Owners cache the epoch they last saw and treat any change as
"registry was restarted; re-register every shard I own".
""".
-spec current_epoch() -> reference().

current_epoch() ->
    gen_server:call(?MODULE, current_epoch).

-doc """
Atomic snapshot of `(ETS entries, mon_to_key, key_to_mon)` for
invariant-checking callers. Runs inside the gen_server so the ETS
read and the in-memory maps come from the same instant — an outside
observer combining `sys:get_state/1` with `lookup/3` would race against
DOWN handlers and unregister calls. Intended for tests and operator
diagnostics; ordinary callers should use `lookup/3`.
""".
-spec snapshot_for_invariants() ->
    #{
        entries := [shard_entry()],
        mon_to_key := #{reference() := shard_key()},
        key_to_mon := #{shard_key() := reference()}
    }.

snapshot_for_invariants() ->
    gen_server:call(?MODULE, snapshot_for_invariants).

-spec lookup(atom(), atom(), non_neg_integer()) ->
    {ok, shard_entry()} | not_found.

lookup(NS, Index, Shard) ->
    case ets:lookup(?TABLE, {NS, Index, Shard}) of
        [#entry{} = E] -> {ok, E};
        [] -> not_found
    end.

-spec shard_count(atom(), atom()) -> {ok, pos_integer()} | not_found.

shard_count(NS, Index) ->
    MS = [
        {
            #entry{
                key = {NS, Index, '_'},
                shard_count = '$1',
                _ = '_'
            },
            [],
            ['$1']
        }
    ],
    case ets:select(?TABLE, MS, 1) of
        {[Count], _} -> {ok, Count};
        '$end_of_table' -> not_found
    end.

-spec list() -> [shard_entry()].

list() ->
    ets:select(?TABLE, [{'_', [], ['$_']}]).

-doc """
Record on the shard's atomics counter that the shard has just had a
fresh round of applier activity (or anti-entropy convergence). Wait-free.

Uses `erlang:monotonic_time(millisecond)` as the bump timestamp. For
applier loops that bump several shards in one logical step and want
to reuse the same "now" across them, see `bump_ae/4`.
""".
-spec bump_ae(atom(), atom(), non_neg_integer()) -> ok | not_found.

bump_ae(NS, Index, Shard) ->
    bump_ae(NS, Index, Shard, erlang:monotonic_time(millisecond)).

-doc """
Like `bump_ae/3` but caller supplies the monotonic millisecond
timestamp so the same "now" can be reused across a batch of shards.
""".
-spec bump_ae(atom(), atom(), non_neg_integer(), integer()) ->
    ok | not_found.

bump_ae(NS, Index, Shard, Now) when is_integer(Now) ->
    case lookup(NS, Index, Shard) of
        {ok, #entry{ae_atomics = Ref}} ->
            atomics:put(Ref, 1, Now),
            ok;
        not_found ->
            not_found
    end.

-doc """
Read the per-shard high-water HLC mark
(`bondy_oplog_high_water`).

Returns `{ok, Hlc}` when at least one `cell_apply` event has been
materialised into the shard's projection since the shard's last
registration (or `finalize_catalogue_bootstrap/3` call), `{ok,
no_watermark}` otherwise, and `not_found` when no shard is
registered under the given key.

The watermark is *not* durable across instance restarts — see
`bondy_oplog_high_water` module docs.
""".
-spec high_water_hlc(atom(), atom(), non_neg_integer()) ->
    {ok, non_neg_integer()} | {ok, no_watermark} | not_found.

high_water_hlc(NS, Index, Shard) ->
    case lookup(NS, Index, Shard) of
        {ok, #entry{high_water_ref = Ref}} ->
            bondy_oplog_high_water:read(Ref);
        not_found ->
            not_found
    end.

-doc """
Bump every shard in `Targets` with a single shared
`erlang:monotonic_time(millisecond)` so the batch observes the same
"now". Returns `{Bumped, NotFound}` counts for telemetry. An empty
list is a strict no-op and returns `{0, 0}`.
""".
-spec bump_ae_targets([shard_key()]) ->
    {non_neg_integer(), non_neg_integer()}.

bump_ae_targets([]) ->
    {0, 0};
bump_ae_targets(Targets) when is_list(Targets) ->
    bump_ae_targets(Targets, erlang:monotonic_time(millisecond)).

-doc """
Like `bump_ae_targets/1` but caller supplies the monotonic
millisecond timestamp so the same "now" can be reused across multiple
target lists (e.g., when both the applier and an AE round complete in
the same logical tick).
""".
-spec bump_ae_targets([shard_key()], integer()) ->
    {non_neg_integer(), non_neg_integer()}.

bump_ae_targets([], _Now) ->
    {0, 0};
bump_ae_targets(Targets, Now) when is_list(Targets), is_integer(Now) ->
    lists:foldl(
        fun({NS, Index, Shard}, {B, NF}) ->
            case bump_ae(NS, Index, Shard, Now) of
                ok -> {B + 1, NF};
                not_found -> {B, NF + 1}
            end
        end,
        {0, 0},
        Targets
    ).

-doc """
Return the monotonic millisecond timestamp of the shard's last AE bump.
Wait-free.

A shard that has never been bumped reads `-(1 bsl 62)` (an
"infinitely stale" sentinel chosen so `Now - sentinel` is a very large
positive number regardless of the node's `monotonic_time` offset).
The sentinel ensures un-bumped shards reliably fail any finite
`max_lag` check until the applier or AE has driven the counter
forward at least once.
""".
-spec last_ae_at(atom(), atom(), non_neg_integer()) ->
    integer() | not_found.

last_ae_at(NS, Index, Shard) ->
    case lookup(NS, Index, Shard) of
        {ok, #entry{ae_atomics = Ref}} ->
            atomics:get(Ref, 1);
        not_found ->
            not_found
    end.

-doc """
Whether the shard has ever been freshened (AE bumped past the
"infinitely stale" sentinel). Used by a restarting secondary writer to
tell a crash-restart of a previously-populated shard (rebuild to recover
the lost buffer) from a first-ever start (the startup backfill handles
it). `false` for an unknown or never-bumped shard.
""".
-spec ever_freshened(atom(), atom(), non_neg_integer()) -> boolean().

ever_freshened(NS, Index, Shard) ->
    case last_ae_at(NS, Index, Shard) of
        not_found -> false;
        ?STALE_SENTINEL -> false;
        _ -> true
    end.

-doc """
Return all entries registered for the namespace. Used by callers that
need the atomics ref directly to avoid the second `lookup/3`.
""".
-spec shards_for(atom()) -> [shard_entry()].

shards_for(NS) when is_atom(NS) ->
    MS = [
        {
            #entry{
                key = {NS, '_', '_'},
                _ = '_'
            },
            [],
            ['$_']
        }
    ],
    ets:select(?TABLE, MS).

-doc """
List of all distinct namespaces registered. Used by callers that want
to apply a freshness check over "every namespace this node knows about"
without spelling them out.
""".
-spec namespaces() -> [atom()].

namespaces() ->
    MS = [
        {
            #entry{
                key = {'$1', '_', '_'},
                _ = '_'
            },
            [],
            ['$1']
        }
    ],
    lists:usort(ets:select(?TABLE, MS)).

-doc """
Like `shards_for/1` but only the namespace's PRIMARY shards
(`{NS, primary, _}`), excluding secondary-index shards.

The auth freshness fence (`ensure_fresh/2`) reads primary-projection
cells (user / grant), so it gates on primary freshness only; index-read
staleness is governed separately by the `index_get` `max_lag` path.
""".
-spec primary_shards_for(atom()) -> [shard_entry()].

primary_shards_for(NS) when is_atom(NS) ->
    MS = [
        {
            #entry{
                key = {NS, ?PRIMARY_INDEX, '_'},
                _ = '_'
            },
            [],
            ['$_']
        }
    ],
    ets:select(?TABLE, MS).

-doc """
True when any registered primary shard entry still names `InstanceId` as its
oplog instance.

Backs the facade's refcounted teardown of a shard instance shared by several
tables (one-log-per-shard): the shared instance is stopped only once the last
table's registry entry has been unregistered, exactly as a shared Bookie stays
up until the DB shuts down. Secondary (index) shards carry no `instance_id`, so
they never count.
""".
-spec instance_id_in_use(InstanceId :: binary()) -> boolean().

instance_id_in_use(InstanceId) when is_binary(InstanceId) ->
    MS = [
        {
            #entry{instance_id = InstanceId, _ = '_'},
            [],
            [true]
        }
    ],
    case ets:select(?TABLE, MS, 1) of
        '$end_of_table' -> false;
        {[true], _Cont} -> true
    end.

-doc """
Every primary shard entry whose oplog `instance_id` is `InstanceId`.

The durable basis for self-healing the per-shard multiplexer: an instance shared
by several tables rebuilds its `cell_apply_source` from these entries on
applier/fused init, so a `one_for_all` subtree restart restores routing for
every table on the shard (not just the founding one) without re-running
provisioning. On a fresh start only the founding entry exists; on a restart all
of the shard's tables' entries do.
""".
-spec primary_entries_for_instance(InstanceId :: binary()) ->
    [shard_entry()].

primary_entries_for_instance(InstanceId) when is_binary(InstanceId) ->
    MS = [
        {
            #entry{instance_id = InstanceId, _ = '_'},
            [],
            ['$_']
        }
    ],
    ets:select(?TABLE, MS).

-doc """
Whether any index shard entry still references the `bondy_oplog_secondary_writer`
grouping key `WriterKey`.

The secondary-side twin of `instance_id_in_use/1`: backs the facade's refcounted
teardown of a writer shared by several index shards (one-writer-per-secondary-
shard), so the shared writer is stopped only once the last index shard's registry
entry has been unregistered. Primary shards carry no `writer_key`, so they never
count.
""".
-spec writer_key_in_use(WriterKey :: binary()) -> boolean().

writer_key_in_use(WriterKey) when is_binary(WriterKey) ->
    MS = [
        {
            #entry{writer_key = WriterKey, _ = '_'},
            [],
            [true]
        }
    ],
    case ets:select(?TABLE, MS, 1) of
        '$end_of_table' -> false;
        {[true], _Cont} -> true
    end.

-doc """
Every index shard entry whose `bondy_oplog_secondary_writer` grouping key is
`WriterKey`.

The secondary-side twin of `primary_entries_for_instance/1`: the durable basis
for a shared writer's crash/epoch self-healing. A writer that serves several
index shards re-stamps its pid onto every one of these entries (and re-checks
each for a pending rebuild) on init and on a registry-restart epoch event, so a
writer crash or a registry flush restores dispatch for every stream on the shard
— not just the founding one — without re-running provisioning.
""".
-spec index_entries_for_writer(WriterKey :: binary()) -> [shard_entry()].

index_entries_for_writer(WriterKey) when is_binary(WriterKey) ->
    MS = [
        {
            #entry{writer_key = WriterKey, _ = '_'},
            [],
            ['$_']
        }
    ],
    ets:select(?TABLE, MS).

%% =============================================================================
%% Accessors
%% =============================================================================

entry_key(#entry{key = V}) -> V.
entry_cache_adapter(#entry{cache_adapter = V}) -> V.
entry_cache_handle(#entry{cache_handle = V}) -> V.
entry_projection_adapter(#entry{projection_adapter = V}) -> V.
entry_projection_handle(#entry{projection_handle = V}) -> V.
entry_overlay(#entry{overlay = V}) -> V.
entry_fold_module(#entry{fold_module = V}) -> V.
entry_shard_count(#entry{shard_count = V}) -> V.
entry_ae_atomics(#entry{ae_atomics = V}) -> V.
entry_high_water_ref(#entry{high_water_ref = V}) -> V.
entry_consistency_class(#entry{consistency_class = V}) -> V.
entry_writer_pid(#entry{writer_pid = V}) -> V.
entry_instance_id(#entry{instance_id = V}) -> V.
entry_crdt_module(#entry{crdt_module = V}) -> V.

-doc """
Per-table construction config for `crdt_module` (`#{}` default) — see
`#entry.crdt_opts`.
""".
-spec entry_crdt_opts(shard_entry()) -> map().

entry_crdt_opts(#entry{crdt_opts = V}) -> V.

-doc "The shard's CRDT causal tier (`tier_0` default).".
-spec entry_causal_tier(shard_entry()) -> bondy_oplog_crdt:tier().

entry_causal_tier(#entry{causal_tier = V}) -> V.

-doc """
The index shard's `bondy_oplog_projection_adapter:clear_scope()` (the scope the
rebuild passes to `Adapter:clear/2`), or `undefined` for a primary shard or a
registration that predates the field.
""".
-spec entry_index_clear_scope(shard_entry()) ->
    bondy_oplog_projection_adapter:clear_scope() | undefined.

entry_index_clear_scope(#entry{index_clear_scope = V}) -> V.

-doc """
The primary shard's `bondy_oplog_projection_adapter:cell_keys_scope()` (the
scope the secondary-index rebuild passes to `Adapter:cell_keys/2` to enumerate
its complete cell directory), or `undefined` for an index shard or a
registration that predates the field (the rebuild then falls back to the MST).
""".
-spec entry_primary_cell_scope(shard_entry()) ->
    bondy_oplog_projection_adapter:cell_keys_scope() | undefined.

entry_primary_cell_scope(#entry{primary_cell_scope = V}) -> V.

%% The multiplexer routing bucket (entity-type tag) for a `per_shard` primary
%% shard, or `undefined` for a `per_table_shard` shard / a registration that
%% predates the field.
entry_cell_apply_bucket(#entry{cell_apply_bucket = V}) -> V.

%% The remote-merge publish namespace (`publish => true` tables), or `undefined`.
entry_publish_ns(#entry{publish_ns = V}) -> V.

%% The secondary-index descriptors, `undefined` when unset (fall back to opts),
%% or `[]` for a table with no indexes.
entry_secondary_indexes(#entry{secondary_indexes = V}) -> V.

%% The index shard's `bondy_oplog_secondary_writer` grouping key (the
%% secondary-side twin of `instance_id`), `undefined` for primary shards.
entry_writer_key(#entry{writer_key = V}) -> V.

%% Last AE-freshness timestamp (monotonic ms), read straight off the
%% entry's atomics — the sentinel `?STALE_SENTINEL` for a never-freshened
%% shard. Lets a caller that already holds the entry compute the lag
%% without a second `lookup/3`.
entry_last_ae(#entry{ae_atomics = Ref}) -> atomics:get(Ref, 1).

%% Whether this shard has ever been freshened (AE bumped past the stale
%% sentinel).
entry_ever_freshened(#entry{ae_atomics = Ref}) ->
    atomics:get(Ref, 1) =/= ?STALE_SENTINEL.

%% =============================================================================
%% Index-shard back-pressure
%% =============================================================================

-doc """
Add `N` to the index shard's in-flight op counter and return the new
value. Called by the primary applier when it accepts a batch for the
secondary writer. A no-op returning `0` for a primary shard (no
`inflight_ref`).
""".
-spec index_inflight_add(shard_entry(), non_neg_integer()) ->
    non_neg_integer().

index_inflight_add(#entry{inflight_ref = undefined}, _N) ->
    0;
index_inflight_add(#entry{inflight_ref = Ref}, N) when is_integer(N), N >= 0 ->
    atomics:add_get(Ref, ?INFLIGHT_SLOT, N).

-doc """
Subtract `N` from the index shard's in-flight op counter, flooring at
`0` (a flush can never legitimately drive it negative, but a concurrent
reset must not leave it below zero). No-op for a primary shard.
""".
-spec index_inflight_sub(shard_entry(), non_neg_integer()) -> ok.

index_inflight_sub(#entry{inflight_ref = undefined}, _N) ->
    ok;
index_inflight_sub(#entry{inflight_ref = Ref}, N) when is_integer(N), N >= 0 ->
    case atomics:sub_get(Ref, ?INFLIGHT_SLOT, N) of
        V when V < 0 -> atomics:put(Ref, ?INFLIGHT_SLOT, 0);
        _ -> ok
    end.

-doc "Current in-flight op count for the index shard (`0` for a primary).".
-spec index_inflight(shard_entry()) -> non_neg_integer().

index_inflight(#entry{inflight_ref = undefined}) ->
    0;
index_inflight(#entry{inflight_ref = Ref}) ->
    erlang:max(0, atomics:get(Ref, ?INFLIGHT_SLOT)).

-doc """
Reset the in-flight counter to `0`. Used by a rebuild before it re-folds
the primary, since the rebuild also discards the writer's buffer — the
counter and the buffer are reset together so they stay consistent.
""".
-spec index_inflight_reset(shard_entry()) -> ok.

index_inflight_reset(#entry{inflight_ref = undefined}) ->
    ok;
index_inflight_reset(#entry{inflight_ref = Ref}) ->
    atomics:put(Ref, ?INFLIGHT_SLOT, 0).

-doc """
Raise the index shard's `needs_rebuild` flag (a saturation drop or a
writer crash lost ops). While set, `index_get`/`index_range` treat the
shard as stale regardless of its AE timestamp, so reads refuse (or fall
back to the primary) until a rebuild clears the flag. No-op for a primary.
""".
-spec index_mark_rebuild(shard_entry()) -> ok.

index_mark_rebuild(#entry{inflight_ref = undefined}) ->
    ok;
index_mark_rebuild(#entry{inflight_ref = Ref} = E) ->
    %% Durable trust marker: on the 0→1 transition, REMOVE the trust marker so
    %% the "not trusted" state survives restart — a dropped/wedged durable shard
    %% is then rebuilt on the next open instead of trusted incomplete. The
    %% removal MUST be synchronous (an async removal could be lost in a crash,
    %% leaving the marker present → a silently-incomplete index trusted on
    %% restart), so we keep it inline but gate it on the transition: a sustained
    %% saturation calling this per dropped batch then pays the projection
    %% `delete` only ONCE (until a rebuild clears the flag), not per drop.
    %% `atomics:exchange` makes the test-and-set race-free across concurrent
    %% markers. On an ephemeral (ETS) projection the marker set is wiped with
    %% the table on restart anyway, which is also correct (the index rebuilds).
    case atomics:exchange(Ref, ?NEEDS_REBUILD_SLOT, 1) of
        1 -> ok;
        _ -> remove_trust_marker(E)
    end.

-doc """
Clear the `needs_rebuild` flag (in-memory) and WRITE the durable trust marker.
Called by a completed (re)build, so the shard is marked trustworthy for the
next cold-start.
""".
-spec index_clear_rebuild(shard_entry()) -> ok.

index_clear_rebuild(#entry{inflight_ref = undefined}) ->
    ok;
index_clear_rebuild(#entry{inflight_ref = Ref} = E) ->
    atomics:put(Ref, ?NEEDS_REBUILD_SLOT, 0),
    persist_trust_marker(E).

-doc "Whether the index shard's `needs_rebuild` flag is set (`false` for a primary).".
-spec index_needs_rebuild(shard_entry()) -> boolean().

index_needs_rebuild(#entry{inflight_ref = undefined}) ->
    false;
index_needs_rebuild(#entry{inflight_ref = Ref}) ->
    atomics:get(Ref, ?NEEDS_REBUILD_SLOT) =/= 0.

-doc """
Cold-start: read the index shard's durable **trust marker** and set the
in-memory `needs_rebuild` flag from it — `needs_rebuild = NOT trusted`.
Returns whether the shard needs a rebuild. Called by `bondy_db` at index-shard
provisioning so that:

- a shard with the trust marker (built + clean, kept complete by the flush
  barrier) is trusted and only freshened — no O(table) re-derive;
- a shard WITHOUT it (a newly-declared index, or one left incomplete by a
  pre-restart drop) refuses reads and is rebuilt.

Returns `false` (no rebuild) for a primary or an entry without `inflight_ref`.
For an index entry an absent/unreadable marker returns `true` (rebuild) — the
safe default.
""".
-spec index_load_rebuild_marker(shard_entry()) -> boolean().

index_load_rebuild_marker(#entry{inflight_ref = undefined}) ->
    false;
index_load_rebuild_marker(#entry{inflight_ref = Ref} = E) ->
    case has_trust_marker(E) of
        true ->
            atomics:put(Ref, ?NEEDS_REBUILD_SLOT, 0),
            false;
        false ->
            atomics:put(Ref, ?NEEDS_REBUILD_SLOT, 1),
            true
    end.

-doc """
Reset the shard's AE freshness counter to the "infinitely stale"
sentinel, so any finite `max_lag` read refuses until the shard is
freshened again. Used by a saturation drop. No-op when the entry has
no AE atomics.
""".
-spec reset_stale_ae(shard_entry()) -> ok.

reset_stale_ae(#entry{ae_atomics = undefined}) ->
    ok;
reset_stale_ae(#entry{ae_atomics = Ref}) ->
    atomics:put(Ref, 1, ?STALE_SENTINEL).

-doc """
Return the consistency class declared for the namespace. Reads it from
any registered shard of the namespace (the substrate trusts the value
to be consistent across shards — see `register/4`). Returns `ap` for an
unknown namespace, matching the default.
""".
-spec consistency_class(atom()) -> ap | cp.

consistency_class(NS) when is_atom(NS) ->
    MS = [
        {
            #entry{
                key = {NS, '_', '_'},
                consistency_class = '$1',
                _ = '_'
            },
            [],
            ['$1']
        }
    ],
    case ets:select(?TABLE, MS, 1) of
        {[Class], _} -> Class;
        '$end_of_table' -> ap
    end.

%% =============================================================================
%% PRIVATE: durable index trust marker
%% =============================================================================
%% The durable twin of the in-memory `needs_rebuild` atomic, with INVERTED
%% ("trusted") semantics — presence = built + clean, absence = rebuild.
%% Stored as a reserved cell in the index shard's own projection at
%% `bondy_oplog_index_key:trust_marker_loc/3` (bucket `<<"$idx_trusted">>`,
%% outside the index keyspace, so `clear/2` and range scans never see it).
%% All three are best-effort (`catch`) — a persistence failure degrades to the
%% prior in-memory-only behaviour and never raises into the caller (a
%% saturation drop, a wedged-flush backstop, a completed rebuild).

%% @private
persist_trust_marker(#entry{
    key = {NS, IndexName, Shard},
    projection_adapter = A,
    projection_handle = H
}) when A =/= undefined ->
    {B, K} = bondy_oplog_index_key:trust_marker_loc(NS, IndexName, Shard),
    _ = catch A:put_batch(H, [{B, K, trust_marker_frame()}]),
    ok;
persist_trust_marker(_) ->
    ok.

%% @private
remove_trust_marker(#entry{
    key = {NS, IndexName, Shard},
    projection_adapter = A,
    projection_handle = H
}) when A =/= undefined ->
    {B, K} = bondy_oplog_index_key:trust_marker_loc(NS, IndexName, Shard),
    _ = catch A:delete(H, B, K),
    ok;
remove_trust_marker(_) ->
    ok.

%% @private
has_trust_marker(#entry{
    key = {NS, IndexName, Shard},
    projection_adapter = A,
    projection_handle = H
}) when A =/= undefined ->
    {B, K} = bondy_oplog_index_key:trust_marker_loc(NS, IndexName, Shard),
    case catch A:get(H, B, K) of
        {ok, _} -> true;
        _ -> false
    end;
has_trust_marker(_) ->
    false.

%% @private
%% A minimal `value_equals_state` V2 frame (HLC 0, empty state, value
%% omitted). The marker carries no payload — only presence/absence matters.
trust_marker_frame() ->
    bondy_oplog_cell_frame:encode(0, <<>>, undefined, true).

%% =============================================================================
%% API: durable index clean-shutdown flag
%% =============================================================================
%% The cold-start trust decision's second gate. The trust marker says a shard
%% was *built*; this flag says it was *cleanly closed* — its in-flight coalesce
%% buffer reached disk before shutdown. A shard is trusted on open only if both
%% are present; otherwise it is rebuilt. `bondy_db:close_table/1` sets it after
%% `flush_sync`; cold-start reads then clears it (so a crash this run leaves the
%% shard dirty → rebuilt next open). Presence-only, reusing the trust marker's
%% payload-free frame. Stored at `bondy_oplog_index_key:clean_flag_loc/3`
%% (reserved bucket `<<"$idx_clean">>`, outside the index keyspace). All
%% best-effort (`catch`): a persistence failure degrades to a rebuild on the next
%% open, never raising into the caller.

-doc """
Write the durable clean-shutdown flag for an index shard, certifying it was
flushed to head at a clean shutdown. Called by `bondy_db:close_table/1` after
`flush_sync`. No-op for a primary or an entry without a projection.
""".
-spec index_mark_clean(shard_entry()) -> ok.

index_mark_clean(#entry{
    key = {NS, IndexName, Shard},
    projection_adapter = A,
    projection_handle = H
}) when A =/= undefined ->
    {B, K} = bondy_oplog_index_key:clean_flag_loc(NS, IndexName, Shard),
    _ = catch A:put_batch(H, [{B, K, trust_marker_frame()}]),
    ok;
index_mark_clean(_) ->
    ok.

-doc """
Whether the index shard's durable clean-shutdown flag is present. Read by
cold-start as the second trust gate. `false` for a primary, an entry without a
projection, or any unreadable/absent flag (the safe default — rebuild).
""".
-spec index_has_clean(shard_entry()) -> boolean().

index_has_clean(#entry{
    key = {NS, IndexName, Shard},
    projection_adapter = A,
    projection_handle = H
}) when A =/= undefined ->
    {B, K} = bondy_oplog_index_key:clean_flag_loc(NS, IndexName, Shard),
    case catch A:get(H, B, K) of
        {ok, _} -> true;
        _ -> false
    end;
index_has_clean(_) ->
    false.

-doc """
Clear the durable clean-shutdown flag for an index shard, marking it dirty for
this lifetime. Called by cold-start on open (after reading it), so a crash
before the next clean `close_table/1` rebuilds the shard. No-op for a primary or
an entry without a projection.
""".
-spec index_clear_clean(shard_entry()) -> ok.

index_clear_clean(#entry{
    key = {NS, IndexName, Shard},
    projection_adapter = A,
    projection_handle = H
}) when A =/= undefined ->
    {B, K} = bondy_oplog_index_key:clean_flag_loc(NS, IndexName, Shard),
    _ = catch A:delete(H, B, K),
    ok;
index_clear_clean(_) ->
    ok.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([]) ->
    _ = ets:new(?TABLE, [
        set,
        public,
        named_table,
        {keypos, #entry.key},
        {read_concurrency, true}
    ]),
    Epoch = erlang:make_ref(),
    %% Broadcast asynchronously after init returns so subscribers wake
    %% up *after* the registry is in `ready` state. Synchronous notify
    %% from inside init would still work because the subscribers are
    %% other processes, but doing the work inline keeps init fast.
    self() ! {broadcast_started, Epoch},
    {ok, #state{epoch = Epoch}}.

handle_call({register, NS, Index, Shard, Owner, Config}, _From, State0) ->
    Key = {NS, Index, Shard},
    %% If a previous registration exists for this key, demonitor it
    %% before installing the new owner.
    State1 = drop_monitor_for_key(Key, State0),
    Mon = erlang:monitor(process, Owner),
    Ae =
        case maps:find(ae_atomics, Config) of
            {ok, ExistingRef} ->
                ExistingRef;
            error ->
                NewRef = atomics:new(1, [{signed, true}]),
                %% Initialise to the "infinitely stale" sentinel so an
                %% un-bumped shard fails any finite freshness check.
                ok = atomics:put(NewRef, 1, ?STALE_SENTINEL),
                NewRef
        end,
    HighWater = bondy_oplog_high_water:new(),
    Entry = #entry{
        key = Key,
        shard_count = maps:get(shard_count, Config),
        cache_adapter = maps:get(cache_adapter, Config),
        cache_handle = maps:get(cache_handle, Config),
        projection_adapter = maps:get(projection_adapter, Config),
        projection_handle = maps:get(projection_handle, Config),
        overlay = maps:get(overlay, Config),
        fold_module = maps:get(fold_module, Config),
        ae_atomics = Ae,
        high_water_ref = HighWater,
        consistency_class = maps:get(consistency_class, Config, ap),
        inflight_ref = maps:get(inflight_atomics, Config, undefined),
        instance_id = maps:get(instance_id, Config, undefined),
        crdt_module = maps:get(crdt_module, Config, undefined),
        causal_tier = maps:get(causal_tier, Config, tier_0),
        index_clear_scope = maps:get(index_clear_scope, Config, undefined),
        primary_cell_scope = maps:get(primary_cell_scope, Config, undefined),
        cell_apply_bucket = maps:get(cell_apply_bucket, Config, undefined),
        publish_ns = maps:get(publish_ns, Config, undefined),
        secondary_indexes = maps:get(secondary_indexes, Config, undefined),
        writer_key = maps:get(writer_key, Config, undefined),
        crdt_opts = maps:get(crdt_opts, Config, #{})
    },
    true = ets:insert(?TABLE, Entry),
    State2 = State1#state{
        mon_to_key = maps:put(Mon, Key, State1#state.mon_to_key),
        key_to_mon = maps:put(Key, Mon, State1#state.key_to_mon)
    },
    {reply, ok, State2};
handle_call({unregister, Key}, _From, State0) ->
    State1 = drop_monitor_for_key(Key, State0),
    true = ets:delete(?TABLE, Key),
    {reply, ok, State1};
handle_call(current_epoch, _From, #state{epoch = E} = State) ->
    {reply, E, State};
handle_call(snapshot_for_invariants, _From, State) ->
    Snapshot = #{
        entries => ets:select(?TABLE, [{'_', [], ['$_']}]),
        mon_to_key => State#state.mon_to_key,
        key_to_mon => State#state.key_to_mon
    },
    {reply, Snapshot, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_, State) -> {noreply, State}.

handle_info({broadcast_started, Epoch}, State) ->
    %% `bondy_oplog_core_events` is started before this module in
    %% `bondy_oplog_sup`, so the notify is safe at init time. If the
    %% events module is down, swallow the error — it is a diagnostic
    %% gap, not a substrate-correctness issue.
    catch bondy_oplog_core_events:notify(
        bondy_oplog_core_registry_started,
        Epoch
    ),
    {noreply, State};
handle_info({'DOWN', Mon, process, _Pid, _Reason}, State0) ->
    case maps:take(Mon, State0#state.mon_to_key) of
        {Key, MonToKey1} ->
            true = ets:delete(?TABLE, Key),
            State1 = State0#state{
                mon_to_key = MonToKey1,
                key_to_mon = maps:remove(Key, State0#state.key_to_mon)
            },
            {noreply, State1};
        error ->
            {noreply, State0}
    end;
handle_info(_, State) ->
    {noreply, State}.

terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.

%% =============================================================================
%% Internal
%% =============================================================================

-define(REQUIRED_FIELDS, [
    shard_count,
    cache_adapter,
    cache_handle,
    projection_adapter,
    projection_handle,
    fold_module,
    overlay
]).

validate_config(Config) ->
    case [K || K <- ?REQUIRED_FIELDS, not maps:is_key(K, Config)] of
        [] -> validate_consistency_class(Config);
        [K | _] -> {error, {missing_required_field, K}}
    end.

validate_consistency_class(Config) ->
    case maps:find(consistency_class, Config) of
        {ok, V} when V =:= ap; V =:= cp -> ok;
        {ok, Bad} -> {error, {invalid_consistency_class, Bad}};
        error -> ok
    end.

drop_monitor_for_key(Key, State) ->
    case maps:take(Key, State#state.key_to_mon) of
        {OldMon, KeyToMon1} ->
            true = erlang:demonitor(OldMon, [flush]),
            State#state{
                mon_to_key = maps:remove(OldMon, State#state.mon_to_key),
                key_to_mon = KeyToMon1
            };
        error ->
            State
    end.
