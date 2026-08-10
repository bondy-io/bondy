%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_registry).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Node-shared per-instance read-snapshot registry.

A single ETS `set` table per node, keyed by `instance_id()`, holding
the latest read-relevant state of every running instance:

| Field          | Refreshed on |
|---|---|
| `instance_pid` | `init/terminate` of the instance gen_server |
| `origin`       | `init` (immutable thereafter) |
| `mst`          | every state-mutating handle_call |
| `watermark`    | compact / load_snapshot |
| `snapshot`     | compact / load_snapshot |
| `crdt_module`  | `init` (immutable thereafter) |
| `fold_module`  | `init` (immutable thereafter) |
| `fold_opts`    | `init` (immutable thereafter) |
| `live_size`    | every state-mutating handle_call |
| `wal_pid`      | `bondy_oplog_wal:init/1` |
| `applier_pid`  | `bondy_oplog_applier:init/1` |
| `sup_pid`      | `bondy_oplog_instance_dyn_sup:start_instance/2` |
| `overlay_tab`  | `init` of the instance gen_server (immutable thereafter) |
| `fused`        | `init` (immutable thereafter) |

## Why ETS, not persistent_term

`persistent_term:put/2` triggers a *global GC scan of every process*
on the node. With many instances doing many writes, that's a
non-starter. ETS `insert` is constant-time, no global side effects,
and `read_concurrency: true` lets readers run in parallel with
writes.

## Concurrency model

The table is `public` so each instance gen_server writes its own row
directly — no roundtrip through this module's gen_server on the hot
write path. The contract: **only the owning instance gen_server
writes its row**. Other processes are read-only.

This module's gen_server exists only to own the table (so the table
survives any single instance gen_server crash) and to keep the
table's lifecycle tied to a supervisor child.
""").

-define(TABLE, bondy_oplog_registry_tab).

-record(entry, {
    instance_id :: instance_id(),
    instance_pid :: pid(),
    origin :: bondy_oplog_origin:t(),
    mst :: bondy_mst:t(),
    watermark :: undefined | bondy_oplog_event:event_key(),
    snapshot :: undefined | {bondy_oplog_event:event_key(), term()},
    crdt_module :: module() | undefined,
    %% Per-namespace fold strategy. `undefined` means no fold is
    %% configured for the instance (legacy event-storage path).
    %% Published once by the instance gen_server's `init/1` (and
    %% kept fresh by `publish/1`, though in practice it is
    %% immutable for the instance's lifetime).
    fold_module :: module() | atom() | undefined,
    %% Opaque fold-module-specific options. `#{}` when no fold is
    %% configured.
    fold_opts :: map(),
    live_size :: non_neg_integer(),
    %% Filled in by `bondy_oplog_wal:init/1` after the row exists.
    %% Stays `undefined` between an instance gen_server start and the
    %% WAL writer's first publish, and after a one_for_all subtree
    %% restart between the instance's init and the WAL's init.
    wal_pid :: pid() | undefined,
    %% Caller-side WAL append handle. For the **mem** (ephemeral fused) WAL
    %% this is `#{backend => mem, tab, atomics, pid, max_live_events}` — the
    %% fast path appends lock-free directly into the ETS table via
    %% `bondy_oplog_wal_mem:append_local/2`, with no `gen_server:call`.
    %% `undefined` for the disk WAL (which appends via `gen_server:call`).
    %% Published by `bondy_oplog_wal_mem:init/1`.
    wal_handle :: undefined | map(),
    %% Filled in by `bondy_oplog_applier:init/1` once the applier has
    %% resolved its siblings and opened its reader.
    applier_pid :: pid() | undefined,
    %% Filled in by `bondy_oplog_instance_dyn_sup:start_instance/2`
    %% after `supervisor:start_child/2` returns. Used by the dyn_sup
    %% to make `start_instance/2` idempotent and to stop the whole
    %% per-instance subtree on `stop_instance/1`.
    sup_pid :: pid() | undefined,
    %% Per-instance overlay table. Created by the instance gen_server's
    %% `init/1` and published once; not refreshed by `publish/1`. The
    %% applier reads it at its own `init/1` and uses it for HLC-conditional
    %% eviction after applying a batch. Dies with the instance gen_server
    %% (no heir) — the row's `overlay_tab` field is then stale until the
    %% next instance `init/1` republishes a fresh tid.
    overlay_tab :: ets:tid() | undefined,
    %% Bundle of per-instance handles + immutable opts that the
    %% `bondy_oplog_instance:append_fast/2,3` path needs to build
    %% an event entirely in the caller's process. Set once, at
    %% instance init, to either:
    %% - `undefined` when the configured validator is *not* stateless
    %%   (or the consumer disabled the fast path explicitly): all
    %%   appends route through the instance gen_server.
    %% - a map with `hlc`, `seq`, `overlay_counters`, `origin`,
    %%   `validator_module`, `validator_state`, and the overlay /
    %%   working-set caps: the caller signs in-process, calls the
    %%   WAL directly, inserts the overlay row itself, and bumps the
    %%   shared atomics.
    fast_path :: undefined | fast_path(),
    %% Substrate read-side freshness targets. The list of
    %% `{Namespace, Index, Shard}` tuples that the applier (on every
    %% successful commit) and AE rounds (on every successful sync) bump via
    %% `bondy_oplog_core_registry:bump_ae_targets/1,2`. Published once at
    %% instance init via `set_ae_targets/2`; unchanged for the
    %% instance's lifetime. Empty list = wiring disabled.
    ae_targets = [] :: [{atom(), atom(), non_neg_integer()}],
    %% Per-instance applied-frontier version vector: `#{Origin => max Seq}` over
    %% every `{HLC, Origin, Seq}` event materialised by this instance (across all
    %% shards it multiplexes). Because the op-log is delivered causally (no gaps
    %% per origin), the max Seq per origin faithfully identifies the applied event
    %% set, so two nodes with equal frontiers have converged — a compaction-
    %% invariant convergence oracle (the cumulative applied position is unchanged
    %% by compaction). Maintained by the applier at the commit barrier
    %% (`merge_frontier/2`, a max-merge), read lock-free by the observer / AAE
    %% responder (`frontier/1`). O(#origins); persisted with the checkpoint.
    frontier = #{} :: #{binary() => non_neg_integer()},
    %% Demand-based applier→instance flow control. Single-slot atomic
    %% counter shared between the applier (increments before
    %% dispatching an `install_local_batch` cast) and the instance
    %% (decrements after handling). When the value reaches
    %% `max_install_in_flight`, the applier defers reading the next
    %% WAL batch and waits for the instance to send a `drain_resume`
    %% cast. Bounds the instance's mailbox at `cap × batch_size`
    %% events regardless of write throughput. Published once at
    %% instance init; `undefined` between the entry's creation and
    %% the instance's `init/1` finishing (a brief race the applier
    %% tolerates by treating it as "no cap" until visible).
    install_in_flight :: atomics:atomics_ref() | undefined,
    max_install_in_flight :: pos_integer() | undefined,
    %% Remote-delivery generation (slot 1): bumped by the instance at the
    %% END of every `integrate_peer_root` handler — the point at which
    %% peer-merged events count as locally DELIVERED. The applier caches
    %% this ref and compares it against the generation it last replayed
    %% to, so its prepare fence (`{cell_context, _, _}`) detects "events
    %% delivered but not yet folded into my projection" with a single
    %% atomic read — see the I1 invariant note at that handler. Published
    %% once at instance init; `undefined` between the entry's creation
    %% and the instance's `init/1` finishing (nothing can have been
    %% integrated before then, so the applier safely treats it as
    %% generation 0).
    remote_gen :: atomics:atomics_ref() | undefined,
    %% Per-instance bootstrap lifecycle handle
    %% (`bondy_oplog_bootstrap_lifecycle`). Created at instance init —
    %% see `bondy_oplog_bootstrap_lifecycle:open/2` — and published
    %% once. The applier reads this row at its own `init/1` and caches
    %% the handle; the gate check in the drain loop is then a single
    %% atomic read. `undefined` between the entry's creation and the
    %% instance's `init/1` finishing; treated as "live" by the
    %% applier when missing (no gate).
    lifecycle :: bondy_oplog_bootstrap_lifecycle:handle() | undefined,
    %% Ephemeral fused-writer flag. `true` only for ephemeral (ets
    %% projection) instances that opt into the single-process write
    %% path (applier `cell_apply` + instance MST install fused into
    %% one gen_server, eliminating the install round-trip H1). Seeded
    %% at instance `init/1` via the register-fallback (immutable
    %% thereafter); `false` for every durable instance and for
    %% ephemeral instances that have not opted in. Defaults to `false`
    %% for any row created by a caller that omits it.
    fused = false :: boolean(),
    %% Retention-bounded MST history flag (`mst_retention` instance opt
    %% present). Set at `init` (immutable thereafter), read by the sync
    %% scheduler (join-time catalogue bootstrap seeding) and the sync
    %% session (frontier-gap detection gates peer-frontier adoption).
    mst_retention = false :: boolean()
}).

-record(state, {}).

-type fast_path() :: #{
    hlc := bondy_oplog_hlc:t(),
    seq := atomics:atomics_ref(),
    overlay_counters := atomics:atomics_ref(),
    origin := bondy_oplog_origin:t(),
    validator_module := module(),
    validator_state := term(),
    max_overlay_events := pos_integer(),
    max_overlay_bytes := pos_integer(),
    max_working_set := pos_integer() | infinity,
    overlay_throttle := drop
}.

-type entry() :: #{
    instance_id := instance_id(),
    instance_pid := pid(),
    origin := bondy_oplog_origin:t(),
    mst := bondy_mst:t(),
    watermark := undefined | bondy_oplog_event:event_key(),
    snapshot := undefined | {bondy_oplog_event:event_key(), term()},
    crdt_module := module() | undefined,
    fold_module := module() | atom() | undefined,
    fold_opts := map(),
    live_size := non_neg_integer(),
    wal_pid => pid() | undefined,
    applier_pid => pid() | undefined,
    sup_pid => pid() | undefined,
    overlay_tab => ets:tid() | undefined,
    fast_path => undefined | fast_path(),
    ae_targets => [{atom(), atom(), non_neg_integer()}],
    fused => boolean(),
    mst_retention => boolean()
}.

-export_type([entry/0]).
-export_type([fast_path/0]).

%% Lifecycle
-export([start_link/0]).
-export([child_spec/0]).

%% Per-instance gen_server hooks
-export([register/1]).
-export([unregister/1]).
-export([publish/1]).

%% Reads
-export([lookup/1]).
-export([list/0]).
-export([instance_pid/1]).
-export([origin/1]).
-export([mst/1]).
-export([watermark/1]).
-export([snapshot/1]).
-export([crdt_module/1]).
-export([fold_module/1]).
-export([fold_opts/1]).
-export([live_size/1]).
-export([wal_pid/1]).
-export([wal_handle/1]).
-export([applier_pid/1]).
-export([sup_pid/1]).
-export([overlay_tab/1]).
-export([fast_path/1]).
-export([ae_targets/1]).
-export([frontier/1]).
-export([fused/1]).
-export([mst_retention/1]).
-export([install_in_flight/1]).
-export([remote_gen/1]).
-export([max_install_in_flight/1]).
-export([lifecycle/1]).
-export([instance_id_by_sup_pid/1]).
%% Composite reads — pull several fields in one ETS lookup. Used by
%% hot lock-free reader paths in `bondy_oplog_instance` that would
%% otherwise issue two `ets:lookup_element/3` calls back-to-back.
-export([read_overlay_and_mst/1]).
-export([read_overlay_and_live_size/1]).

%% Sibling pid management
-export([set_wal_pid/2]).
-export([set_wal_handle/2]).
-export([set_applier_pid/2]).
-export([set_sup_pid/2]).
-export([set_overlay_tab/2]).
-export([set_fast_path/2]).
-export([set_ae_targets/2]).
-export([merge_frontier/2]).
-export([set_install_in_flight/3]).
-export([set_lifecycle/2]).
-export([set_remote_gen/2]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

%% =============================================================================
%% LIFECYCLE
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

%% =============================================================================
%% INSTANCE-FACING WRITES
%% =============================================================================

?DOC("""
Inserts (or replaces) the row for an instance. Called by the instance
gen_server in `init/1` once the initial MST handle and snapshot state
are computed. Direct ETS write — no roundtrip through this module's
gen_server.
""").
-spec register(entry()) -> ok.

register(Entry) when is_map(Entry) ->
    true = ets:insert(?TABLE, to_record(Entry)),
    ok.

?DOC("""
Removes the row for an instance. Called by the instance gen_server in
`terminate/2`.
""").
-spec unregister(instance_id()) -> ok.

unregister(InstanceId) when is_binary(InstanceId) ->
    true = ets:delete(?TABLE, InstanceId),
    ok.

?DOC("""
Updates the mutable per-instance fields in place (`instance_pid`,
`mst`, `watermark`, `snapshot`, `crdt_module`, `live_size`). Called
by the instance gen_server after every state-mutating handle_call.
Leaves `wal_pid`, `applier_pid`, and `sup_pid` alone so a publish
from the instance doesn't clobber a sibling's pid set independently
by the WAL writer, applier, or dyn supervisor.

If no row exists yet (e.g. the very first `init/1` call sequence),
falls back to `register/1` so the row is created from this snapshot.

`instance_pid` IS published here (it's the field this gen_server
owns); `wal_pid`, `applier_pid`, and `sup_pid` are not — those are
owned by other processes and updated via their dedicated setters.
""").
-spec publish(entry()) -> ok.

publish(#{instance_id := Id} = Entry) ->
    Updates = [
        {#entry.instance_pid, maps:get(instance_pid, Entry)},
        {#entry.mst, maps:get(mst, Entry)},
        {#entry.watermark, maps:get(watermark, Entry)},
        {#entry.snapshot, maps:get(snapshot, Entry)},
        {#entry.crdt_module, maps:get(crdt_module, Entry)},
        {#entry.fold_module, maps:get(fold_module, Entry, undefined)},
        {#entry.fold_opts, maps:get(fold_opts, Entry, #{})},
        {#entry.live_size, maps:get(live_size, Entry)}
    ],
    case update_element_safe(Id, Updates) of
        true -> ok;
        false -> register(Entry)
    end.

%% =============================================================================
%% READS
%% =============================================================================

?DOC("""
Returns the full registry row for an instance, or `not_found`.
A single ETS lookup; safe to call from any process.
""").
-spec lookup(instance_id()) -> {ok, entry()} | not_found.

lookup(InstanceId) when is_binary(InstanceId) ->
    case ets:lookup(?TABLE, InstanceId) of
        [Entry] -> {ok, to_map(Entry)};
        [] -> not_found
    end.

?DOC("""
Every live instance id. A single `ets:select` returning just the keys —
intended for periodic sweeps (e.g. the latency idle probe) that need to
enumerate all instances without materialising full entries.
""").
-spec list() -> [instance_id()].

list() ->
    ets:select(?TABLE, [{#entry{instance_id = '$1', _ = '_'}, [], ['$1']}]).

-spec instance_pid(instance_id()) -> pid() | undefined.

instance_pid(InstanceId) ->
    field(InstanceId, #entry.instance_pid).

-spec origin(instance_id()) -> bondy_oplog_origin:t() | undefined.

origin(InstanceId) ->
    field(InstanceId, #entry.origin).

-spec mst(instance_id()) -> bondy_mst:t() | undefined.

mst(InstanceId) ->
    field(InstanceId, #entry.mst).

-spec watermark(instance_id()) ->
    undefined | bondy_oplog_event:event_key().

watermark(InstanceId) ->
    field(InstanceId, #entry.watermark).

-spec snapshot(instance_id()) ->
    undefined | {bondy_oplog_event:event_key(), term()}.

snapshot(InstanceId) ->
    field(InstanceId, #entry.snapshot).

-spec crdt_module(instance_id()) -> module() | undefined.

crdt_module(InstanceId) ->
    field(InstanceId, #entry.crdt_module).

-spec fold_module(instance_id()) -> module() | atom() | undefined.

fold_module(InstanceId) ->
    field(InstanceId, #entry.fold_module).

-spec fold_opts(instance_id()) -> map() | undefined.

fold_opts(InstanceId) ->
    field(InstanceId, #entry.fold_opts).

-spec live_size(instance_id()) -> non_neg_integer() | undefined.

live_size(InstanceId) ->
    field(InstanceId, #entry.live_size).

-spec wal_pid(instance_id()) -> pid() | undefined.

wal_pid(InstanceId) ->
    field(InstanceId, #entry.wal_pid).

-spec wal_handle(instance_id()) -> map() | undefined.

wal_handle(InstanceId) ->
    field(InstanceId, #entry.wal_handle).

-spec applier_pid(instance_id()) -> pid() | undefined.

applier_pid(InstanceId) ->
    field(InstanceId, #entry.applier_pid).

-spec sup_pid(instance_id()) -> pid() | undefined.

sup_pid(InstanceId) ->
    field(InstanceId, #entry.sup_pid).

-spec overlay_tab(instance_id()) -> ets:tid() | undefined.

overlay_tab(InstanceId) ->
    field(InstanceId, #entry.overlay_tab).

?DOC("""
Returns the demand-based flow-control counter for the applier→instance
`install_local_batch` channel, or `undefined` when the entry has not
yet been published. The applier reads this once at `init/1` and caches
the ref; both processes update it via `atomics:add_get/3` and
`atomics:sub/3`.
""").
-spec install_in_flight(instance_id()) ->
    atomics:atomics_ref() | undefined.

install_in_flight(InstanceId) ->
    field(InstanceId, #entry.install_in_flight).

?DOC("""
Returns the remote-delivery generation counter ref for `InstanceId`, or
`undefined` when the entry has not yet been published (nothing can have
been integrated before the instance's `init/1`, so callers treat the
absence as generation 0). See the `remote_gen` field note.
""").
-spec remote_gen(instance_id()) -> atomics:atomics_ref() | undefined.

remote_gen(InstanceId) ->
    field(InstanceId, #entry.remote_gen).

?DOC("""
Returns the configured cap on the applier's in-flight
`install_local_batch` casts to the instance, or `undefined` when the
entry has not yet been published. Read by the applier when computing
its dispatch budget.
""").
-spec max_install_in_flight(instance_id()) -> pos_integer() | undefined.

max_install_in_flight(InstanceId) ->
    field(InstanceId, #entry.max_install_in_flight).

?DOC("""
Returns the bootstrap lifecycle handle for `InstanceId`, or `undefined`
when the entry has not yet been published. The applier reads this once
at `init/1` and caches the handle; the gate check then collapses to a
single `atomics:get/2`.
""").
-spec lifecycle(instance_id()) ->
    bondy_oplog_bootstrap_lifecycle:handle() | undefined.

lifecycle(InstanceId) ->
    field(InstanceId, #entry.lifecycle).

?DOC("""
Returns the cached fast-path bundle for an instance, or `undefined`
when none is published (callers must route through the instance
gen_server).
""").
-spec fast_path(instance_id()) -> undefined | fast_path().

fast_path(InstanceId) ->
    field(InstanceId, #entry.fast_path).

?DOC("""
Returns the AE-target list stored for `InstanceId`, or `[]` when the
row exists but the consumer has not configured targets, or
`undefined` when no row exists. Used by `bondy_oplog_applier` (commit
boundary) and `bondy_oplog_sync_session` (round completion) to know
which substrate shards to bump via
`bondy_oplog_core_registry:bump_ae_targets/2`.
""").
-spec ae_targets(instance_id()) ->
    [{atom(), atom(), non_neg_integer()}] | undefined.

ae_targets(InstanceId) ->
    field(InstanceId, #entry.ae_targets).

?DOC("""
Returns the instance's applied-frontier version vector `#{Origin => max Seq}`,
or `#{}` if the instance has no published row yet. Read lock-free by the AAE
responder / observer to compare against a peer's frontier (equal ⇒ converged).
""").
-spec frontier(instance_id()) -> #{binary() => non_neg_integer()}.

frontier(InstanceId) ->
    case field(InstanceId, #entry.frontier) of
        Map when is_map(Map) -> Map;
        _ -> #{}
    end.

?DOC("""
Returns the instance's ephemeral fused-writer flag. `true` only for
ephemeral (ets projection) instances that opted into the fused
single-process write path; `false` for every durable instance and
for ephemeral instances that did not opt in. `undefined` when the row
is absent (treated as `false` by readers).
""").
-spec fused(instance_id()) -> boolean() | undefined.

fused(InstanceId) ->
    field(InstanceId, #entry.fused).

?DOC("""
Returns whether the instance is retention-bounded (`mst_retention`
instance opt). `true` only for fused ephemeral catalogue instances whose
MST history is truncated by local policy — the signal that peers of this
instance ALSO truncate (uniform policy), so a sync session must not adopt
a peer frontier it has not materially caught up to, and a fresh instance
needs a join-time catalogue bootstrap (page-sync alone covers only the
retention window).
""").
-spec mst_retention(instance_id()) -> boolean() | undefined.

mst_retention(InstanceId) ->
    field(InstanceId, #entry.mst_retention).

?DOC("""
Returns `{OverlayTab, MST}` for an instance in **one** ETS lookup,
or `undefined` when the row is absent. Used by the hot lock-free
read paths (`get/2`, `fold_range/5`, `first_key/1`,
`latest_key/1`) which would otherwise issue two consecutive
`lookup_element/3` calls — each one a separate ETS access serialised
on the per-key slot lock.
""").
-spec read_overlay_and_mst(instance_id()) ->
    undefined | {ets:tid() | undefined, bondy_mst:t()}.

read_overlay_and_mst(InstanceId) when is_binary(InstanceId) ->
    try ets:lookup(?TABLE, InstanceId) of
        [#entry{overlay_tab = T, mst = M}] -> {T, M};
        [] -> undefined
    catch
        error:badarg -> undefined
    end.

?DOC("""
Returns `{OverlayTab, LiveSize}` for an instance in one ETS lookup,
or `undefined`. Used by `size/1`.
""").
-spec read_overlay_and_live_size(instance_id()) ->
    undefined | {ets:tid() | undefined, non_neg_integer()}.

read_overlay_and_live_size(InstanceId) when is_binary(InstanceId) ->
    try ets:lookup(?TABLE, InstanceId) of
        [#entry{overlay_tab = T, live_size = L}] -> {T, L};
        [] -> undefined
    catch
        error:badarg -> undefined
    end.

?DOC("""
Reverse lookup: returns the `instance_id()` whose registry row has
the given `sup_pid`, or `undefined`. Used by the dyn supervisor's
`stop_instance(Pid)` path to drop the row alongside the supervisor
child.
""").
-spec instance_id_by_sup_pid(pid()) -> instance_id() | undefined.

instance_id_by_sup_pid(SupPid) when is_pid(SupPid) ->
    MatchSpec = [
        {#entry{instance_id = '$1', sup_pid = SupPid, _ = '_'}, [], ['$1']}
    ],
    case ets:select(?TABLE, MatchSpec, 1) of
        {[Id], _Cont} -> Id;
        '$end_of_table' -> undefined;
        _ -> undefined
    end.

?DOC("""
Records the per-instance WAL writer pid. Called by the WAL writer's
`init/1` after the row has been created by the instance gen_server.
Silently returns `ok` if the row is absent (e.g. the subtree is
shutting down) so the WAL doesn't crash on a benign race.
""").
-spec set_wal_pid(instance_id(), pid()) -> ok.

set_wal_pid(InstanceId, Pid) when is_binary(InstanceId), is_pid(Pid) ->
    _ = update_field(InstanceId, #entry.wal_pid, Pid),
    ok.

-spec set_wal_handle(instance_id(), map()) -> ok.

set_wal_handle(InstanceId, Handle) when
    is_binary(InstanceId), is_map(Handle)
->
    _ = update_field(InstanceId, #entry.wal_handle, Handle),
    ok.

?DOC("""
Records the per-instance applier pid. Same contract as
`set_wal_pid/2`.
""").
-spec set_applier_pid(instance_id(), pid()) -> ok.

set_applier_pid(InstanceId, Pid) when is_binary(InstanceId), is_pid(Pid) ->
    _ = update_field(InstanceId, #entry.applier_pid, Pid),
    ok.

?DOC("""
Records the per-instance subtree supervisor pid. Called by
`bondy_oplog_instance_dyn_sup:start_instance/2` after the supervisor
returns. Same tolerance as the sibling setters — a missing row is a
benign no-op.
""").
-spec set_sup_pid(instance_id(), pid()) -> ok.

set_sup_pid(InstanceId, Pid) when is_binary(InstanceId), is_pid(Pid) ->
    _ = update_field(InstanceId, #entry.sup_pid, Pid),
    ok.

?DOC("""
Records the per-instance overlay ETS table id. Called by the instance
gen_server's `init/1` once, immediately after the table is created and
before the registry row is published, so the applier (which starts
later in the one_for_all subtree) finds the tid already in place.
Same tolerance as the sibling setters — a missing row is a benign
no-op so a one_for_all restart race does not crash either process.
""").
-spec set_overlay_tab(instance_id(), ets:tid()) -> ok.

set_overlay_tab(InstanceId, Tab) when is_binary(InstanceId) ->
    _ = update_field(InstanceId, #entry.overlay_tab, Tab),
    ok.

?DOC("""
Publishes the lock-free `append_fast` bundle for an instance, or
clears it when the validator is not stateless. Set once by the
instance gen_server's `init/1`. Same benign-race tolerance as
`set_overlay_tab/2`.
""").
-spec set_fast_path(instance_id(), undefined | fast_path()) -> ok.

set_fast_path(InstanceId, FastPath) when is_binary(InstanceId) ->
    _ = update_field(InstanceId, #entry.fast_path, FastPath),
    ok.

?DOC("""
Stores the substrate read-side AE targets for `InstanceId`. Symmetric
with `set_overlay_tab/2`; published once at instance init and never
updated for the instance's lifetime.
""").
-spec set_ae_targets(
    instance_id(), [{atom(), atom(), non_neg_integer()}]
) -> ok.

set_ae_targets(InstanceId, Targets) when
    is_binary(InstanceId),
    is_list(Targets)
->
    _ = update_field(InstanceId, #entry.ae_targets, Targets),
    ok.

?DOC("""
Max-merges a partial applied-frontier `#{Origin => Seq}` into the instance's
stored frontier (`#{Origin => max Seq}`). Called by the applier at the commit
barrier with the batch's per-origin maxima — a read-modify-write that is safe
because the applier is the single writer of a given instance's frontier. An
empty partial is a no-op.

That single-writer rule is load-bearing, not hygiene. The frontier is the
convergence oracle, and a per-origin maximum identifies an applied PREFIX only
while every merge comes from events this replica actually folded. The applier
guarantees that: `bondy_oplog_cell_apply:partition_contiguous/3` holds a remote
origin's events beyond its first contiguity gap, so the maxima it merges cannot
straddle a hole. A merge sourced from anywhere else — a peer's reported
frontier, say — carries no such guarantee, and raising the oracle past a hole
makes two replicas read IN SYNC over different data.

The other two writers are legitimate because each supplies the DATA alongside
the maxima: `finalize_catalogue_bootstrap/4` (catalogue install) and
`restore_frontier/2` (compaction checkpoint, on restart). Any fourth caller
needs the same property, or it reintroduces the over-claim.
""").
-spec merge_frontier(instance_id(), #{binary() => non_neg_integer()}) -> ok.

merge_frontier(_InstanceId, Partial) when Partial =:= #{} ->
    ok;
merge_frontier(InstanceId, Partial) when
    is_binary(InstanceId), is_map(Partial)
->
    case ets:lookup(?TABLE, InstanceId) of
        [#entry{frontier = Cur} = E] ->
            Merged = maps:merge_with(
                fun(_Origin, A, B) -> max(A, B) end, Cur, Partial
            ),
            true = ets:insert(?TABLE, E#entry{frontier = Merged}),
            ok;
        [] ->
            ok
    end.

?DOC("""
Publishes the per-instance flow-control handle used by the applier to
gate its `install_local_batch` dispatch. Set once by the instance's
`init/1`; both fields are read by the applier and updated by both
sides via the same atomic ref.
""").
-spec set_install_in_flight(
    instance_id(), atomics:atomics_ref(), pos_integer()
) -> ok.

set_install_in_flight(InstanceId, Ref, Cap) when
    is_binary(InstanceId), is_integer(Cap), Cap >= 1
->
    case ets:lookup(?TABLE, InstanceId) of
        [#entry{} = E] ->
            true = ets:insert(
                ?TABLE,
                E#entry{install_in_flight = Ref, max_install_in_flight = Cap}
            ),
            ok;
        [] ->
            ok
    end.

?DOC("""
Publishes the per-instance bootstrap lifecycle handle. Set once by
the instance's `init/1`; read by the applier at its own `init/1` to
gate the WAL drain.
""").
-spec set_lifecycle(
    instance_id(), bondy_oplog_bootstrap_lifecycle:handle()
) -> ok.

set_lifecycle(InstanceId, Handle) when is_binary(InstanceId) ->
    _ = update_field(InstanceId, #entry.lifecycle, Handle),
    ok.

?DOC("""
Publishes the per-instance remote-delivery generation counter (see the
`remote_gen` field note). Set once by the instance's `init/1`; bumped by
the instance's `integrate_peer_root` handler; read by the applier's
prepare fence.
""").
-spec set_remote_gen(instance_id(), atomics:atomics_ref()) -> ok.

set_remote_gen(InstanceId, Ref) when is_binary(InstanceId) ->
    _ = update_field(InstanceId, #entry.remote_gen, Ref),
    ok.

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init([]) ->
    process_flag(trap_exit, true),
    _Tab = ets:new(?TABLE, [
        named_table,
        set,
        public,
        {keypos, #entry.instance_id},
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    {ok, #state{}}.

handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
field(InstanceId, FieldPos) when is_binary(InstanceId) ->
    try
        ets:lookup_element(?TABLE, InstanceId, FieldPos)
    catch
        error:badarg -> undefined
    end.

%% @private
%% Wraps `ets:update_element/3` with badarg suppression so a missing
%% row (subtree torn down, instance never registered) is treated as a
%% benign no-op. Returns `true` on success and `false` when the row
%% does not exist; the caller normally discards both.
update_element_safe(Key, Updates) ->
    try
        ets:update_element(?TABLE, Key, Updates)
    catch
        error:badarg -> false
    end.

%% @private
update_field(InstanceId, FieldPos, Value) ->
    update_element_safe(InstanceId, [{FieldPos, Value}]).

%% @private
%% Allow the optional `wal_pid` / `applier_pid` / `sup_pid` keys to be
%% omitted by pre-existing callers — they default to `undefined`.
to_record(#{instance_id := Id} = M) ->
    #entry{
        instance_id = Id,
        instance_pid = maps:get(instance_pid, M),
        origin = maps:get(origin, M),
        mst = maps:get(mst, M),
        watermark = maps:get(watermark, M),
        snapshot = maps:get(snapshot, M),
        crdt_module = maps:get(crdt_module, M),
        fold_module = maps:get(fold_module, M, undefined),
        fold_opts = maps:get(fold_opts, M, #{}),
        live_size = maps:get(live_size, M),
        wal_pid = maps:get(wal_pid, M, undefined),
        applier_pid = maps:get(applier_pid, M, undefined),
        sup_pid = maps:get(sup_pid, M, undefined),
        overlay_tab = maps:get(overlay_tab, M, undefined),
        fast_path = maps:get(fast_path, M, undefined),
        ae_targets = maps:get(ae_targets, M, []),
        fused = maps:get(fused, M, false),
        mst_retention = maps:get(mst_retention, M, false)
    }.

%% @private
to_map(#entry{
    instance_id = Id,
    instance_pid = InstancePid,
    origin = O,
    mst = M,
    watermark = W,
    snapshot = S,
    crdt_module = C,
    fold_module = FM,
    fold_opts = FO,
    live_size = L,
    wal_pid = WalPid,
    applier_pid = ApplierPid,
    sup_pid = SupPid,
    overlay_tab = OverlayTab,
    fast_path = FastPath,
    ae_targets = AeTargets,
    fused = Fused,
    mst_retention = MstRetention
}) ->
    #{
        instance_id => Id,
        instance_pid => InstancePid,
        origin => O,
        mst => M,
        watermark => W,
        snapshot => S,
        crdt_module => C,
        fold_module => FM,
        fold_opts => FO,
        live_size => L,
        wal_pid => WalPid,
        applier_pid => ApplierPid,
        sup_pid => SupPid,
        overlay_tab => OverlayTab,
        fast_path => FastPath,
        ae_targets => AeTargets,
        fused => Fused,
        mst_retention => MstRetention
    }.
