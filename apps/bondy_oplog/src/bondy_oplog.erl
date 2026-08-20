%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Public façade for the operation-log replication framework.

Each replicated value is an **instance**: an append-only operation log
keyed by `{HLC, Origin, Seq}`, stored in a Merkle Search Tree. Stable
prefixes of the log collapse into snapshots through a
consumer-defined `interpret_cog/2` function.

## Attribution

The Concurrent Operation Group (COG) abstraction, the operation-log
framing, and the equivocation-tolerance approach via hash-chaining
are taken from Preston McCrary's *Canteen* (UC Berkeley, 2022 —
EECS-2022-160). The MST substrate underneath comes from Auvolat &
Taïani (Inria/IRISA, SRDS 2019 — HAL-02303490). See the "Credits"
section of this library's README for full references.

## API surface

Lifecycle primitives are intentionally minimal: `start_instance/1,2`,
`stop_instance/1,2`, `list_instances/0`, `discover_instances/1`. The
library does not impose lifecycle policy — *when* and *how often* to
call these is the consumer's choice. Lazy loading, LRU eviction,
cold-tier offload, and per-tenant policies belong to the consumer.

Per-instance event operations pass through to
`bondy_oplog_instance`.

## Concurrency model — what to expect

- **Single-event `append/2,3` is lock-free for stateless
  validators.** The default `bondy_oplog_validator_trust` advertises
  `is_stateless/0 -> true`; the call builds the event, signs it, and
  hits the WAL gen_server directly from the caller's process,
  bypassing the instance gen_server. Stateful validators (e.g.
  `bondy_oplog_validator_crypto`) fall back to the gen_server path.
- **Reads are lock-free.** `get/2`, `fold_range/5`, `first_key/1`,
  `latest_key/1`, `size/1`, and `root_hash/1` go straight to the
  registry-published MST handle plus the overlay ETS table — no
  gen_server hop. Readers scale with cores.
- **The WAL gen_server is the sole write serialiser.** Multi-writer
  throughput on a single instance is bounded by the slower of the
  WAL `fsync_mode` rate and the WAL gen_server's serial processing
  rate. In `batched` mode that gen_server processes millions of
  events/s; in `per_write` mode it is bounded by the device fsync
  rate (~5 k events/s on commodity NVMe).
- For high-churn write paths prefer `fsync_mode => batched` plus
  `await_durable/3` over the default `per_write` (see
  `bondy_oplog_wal` moduledoc).
- `append_many/2` also takes the lock-free fast path when the
  validator is stateless — every event is signed in the caller
  process, the WAL writes one atomic frame, and every overlay
  row is staged in a single `ets:insert/2`. Remote-event delivery
  (`append_remote/2`) still routes through the applier+instance
  gen_server because the verify+conflict path is stateful.
""").

%% Lifecycle
-export([start_instance/1]).
-export([start_instance/2]).
-export([stop_instance/1]).
-export([stop_instance/2]).
-export([list_instances/0]).
-export([discover_instances/1]).
-export([discover_instances/2]).

%% Per-instance API (pass-through to bondy_oplog_instance)
-export([append/2]).
-export([append/3]).
-export([append_many/2]).
-export([append_remote/2]).
-export([await_apply/1]).
-export([await_apply/2]).
-export([await_drain/1]).
-export([open_drain_gate/1]).
-export([get/2]).
-export([root_hash/1]).
-export([fold_range/5]).
-export([range/3]).
-export([truncate_prefix/2]).
-export([size/1]).
-export([first_key/1]).
-export([latest_key/1]).
-export([origin/1]).
-export([info/1]).
-export([projection/1]).

%% Sync
-export([sync/2]).
-export([sync/3]).
-export([bootstrap/2]).
-export([bootstrap/3]).

%% GC / queries
-export([compact/1]).
-export([current_watermark/1]).
-export([compaction_checkpoint/1]).
-export([query/2]).
-export([query_stable/2]).
-export([retention_advice/1, retention_advice/2]).
-export([retention_decision/1]).

%% Topology fingerprint (AAE compatibility handshake)
-export([db_of/1]).
-export([set_topology_fingerprint/2]).
-export([topology_fingerprint/1]).

%% =============================================================================
%% TYPES
%% =============================================================================

-type retention_pressure() :: #{
    bytes_total := non_neg_integer(),
    max_total_wal_size := pos_integer(),
    bytes_ratio := float(),
    live_segments_count := non_neg_integer(),
    max_live_segments := pos_integer(),
    segments_ratio := float(),
    backpressure := term()
}.

-type retention_inputs() :: #{
    pressure := retention_pressure(),
    has_snapshot := boolean(),
    snapshot_watermark := bondy_oplog_event:event_key() | undefined,
    scrubber_alerts := [{non_neg_integer(), atom()}],
    bootstrap_consumers := non_neg_integer()
}.

-type retention_advice_action() :: compact | truncate_prefix | none.

-type retention_advice() :: #{
    recommended_action := retention_advice_action(),
    rationale := binary(),
    inputs := retention_inputs()
}.

-export_type([retention_pressure/0]).
-export_type([retention_inputs/0]).
-export_type([retention_advice/0]).
-export_type([retention_advice_action/0]).

%% =============================================================================
%% LIFECYCLE
%% =============================================================================

?DOC("""
Starts an instance with default options.
""").
-spec start_instance(instance_id()) -> {ok, pid()} | {error, term()}.

start_instance(InstanceId) when is_binary(InstanceId) ->
    start_instance(InstanceId, #{}).

?DOC("""
Starts an instance. Returns the pid of the per-instance supervisor.
Idempotent: re-starting a running instance returns its existing
supervisor pid.
""").
-spec start_instance(
    instance_id(),
    bondy_oplog_instance:opts()
) -> {ok, pid()} | {error, term()}.

start_instance(InstanceId, Opts) when
    is_binary(InstanceId), is_map(Opts)
->
    bondy_oplog_instance_dyn_sup:start_instance(InstanceId, Opts).

-spec stop_instance(instance_id()) -> ok | {error, not_found}.

stop_instance(InstanceId) ->
    stop_instance(InstanceId, #{}).

?DOC("""
Stops an instance. The `Opts` map is currently unused; a future
`destroy => true` option to also delete the instance's on-disk state
is reserved.
""").
-spec stop_instance(instance_id(), map()) -> ok | {error, not_found}.

stop_instance(InstanceId, _Opts) when is_binary(InstanceId) ->
    case bondy_oplog_instance_dyn_sup:stop_instance(InstanceId) of
        ok ->
            %% Drop node-shared registry rows for the now-gone instance.
            %% Best-effort: if a registry isn't running (e.g. tests
            %% bring up only part of the tree) we silently skip.
            _ =
                try
                    bondy_oplog_peer_state:forget_instance(InstanceId)
                catch
                    _:_ -> ok
                end,
            _ =
                try
                    bondy_oplog_quarantine:forget_instance(InstanceId)
                catch
                    _:_ -> ok
                end,
            ok;
        Other ->
            Other
    end.

?DOC("""
Lists currently-running instances on this node. Order unspecified.

Answered from the registry's key-only select, so it wakes no process and
takes no lock. This is called from periodic sweeps (the sync and GC
scheduler ticks, origin retirement) and from the Prometheus scrape, and
a supervision-tree walk is the wrong shape for all of them:
`supervisor:which_children/1` is a `gen_server:call` that serialises
against the process managing child starts and stops, and copies the whole
child list per call. Walking the tree to reach each instance cost one such
call per instance supervisor plus an `info/1` call per instance — 2N
round trips that made all N instances runnable at the same instant.

A row exists from instance start until its `terminate/2`, so the set is
the same one the tree reports, minus instances that have started but not
yet registered. Sweeps pick those up on their next pass; boot-time
enumeration uses `discover_instances/1,2` instead.
""").
-spec list_instances() -> [instance_id()].

list_instances() ->
    bondy_oplog_registry:list().

?DOC("""
Discovers instances on disk under `BaseDir`, using the sharded path
layout (the library default). Suitable for boot-time enumeration.
""").
-spec discover_instances(BaseDir :: binary()) -> [instance_id()].

discover_instances(BaseDir) ->
    discover_instances(BaseDir, sharded).

-spec discover_instances(
    BaseDir :: binary(), Layout :: bondy_oplog_path:layout()
) -> [instance_id()].

discover_instances(BaseDir, Layout) when
    is_binary(BaseDir), is_atom(Layout)
->
    bondy_oplog_path:discover(BaseDir, Layout).

%% =============================================================================
%% PER-INSTANCE API
%% =============================================================================

-spec append(instance_id(), bondy_oplog_event:op()) ->
    bondy_oplog_event:event_key().

append(InstanceId, Op) ->
    bondy_oplog_instance:append_fast(InstanceId, Op, undefined).

-spec append(
    instance_id(),
    bondy_oplog_event:op(),
    bondy_oplog_event:meta()
) -> bondy_oplog_event:event_key().

append(InstanceId, Op, Meta) ->
    bondy_oplog_instance:append_fast(InstanceId, Op, Meta).

-spec append_many(
    instance_id(),
    [{bondy_oplog_event:op(), bondy_oplog_event:meta()}]
) -> [bondy_oplog_event:event_key()].

append_many(InstanceId, Items) ->
    bondy_oplog_instance:append_many_fast(InstanceId, Items).

-spec append_remote(instance_id(), bondy_oplog_event:t()) ->
    ok | {error, term()}.

append_remote(InstanceId, Event) ->
    bondy_oplog_instance:append_remote(InstanceId, Event).

-spec await_apply(instance_id()) -> ok | {error, timeout}.

await_apply(InstanceId) ->
    bondy_oplog_instance:await_apply(InstanceId).

-spec await_apply(instance_id(), timeout()) -> ok | {error, timeout}.

await_apply(InstanceId, Timeout) ->
    bondy_oplog_instance:await_apply(InstanceId, Timeout).

-spec await_drain(instance_id()) -> ok | {error, term()}.

-doc """
Block until the instance's applier has drained its WAL to end-of-log (the
cold-start rebuild barrier — see `bondy_oplog_applier:await_drain/1`). Resolves
the applier pid from the registry; `{error, no_applier}` if it is not yet
published.
""".

await_drain(InstanceId) ->
    case bondy_oplog_registry:applier_pid(InstanceId) of
        Pid when is_pid(Pid) ->
            bondy_oplog_applier:await_drain(Pid);
        _ ->
            {error, no_applier}
    end.

-spec open_drain_gate(instance_id()) -> ok | {error, term()}.

-doc """
Release an instance founded with the WAL drain GATED (`drain_gated => true`),
kicking its deferred replay. The provisioning orchestrator calls this once per
collapsed per-shard instance after every table sharing the shard has registered
its cell-apply bucket, so the shared WAL is replayed with a complete routing
directory and no cell is skipped. Idempotent; a no-op on an ungated or fused
instance. See `bondy_oplog_instance:open_drain_gate/1`.
""".

open_drain_gate(InstanceId) when is_binary(InstanceId) ->
    bondy_oplog_instance:open_drain_gate(InstanceId).

-spec get(instance_id(), bondy_oplog_event:event_key()) ->
    {ok, bondy_oplog_event:t()} | not_found.

get(InstanceId, Key) ->
    bondy_oplog_instance:get(InstanceId, Key).

-spec root_hash(instance_id()) -> binary() | undefined.

root_hash(InstanceId) ->
    %% Drain the applier so the returned root reflects every event
    %% the caller has already `append/2`-ed. Callers comparing roots
    %% across nodes after a write expect read-your-writes semantics.
    _ = bondy_oplog_instance:await_apply(InstanceId),
    bondy_oplog_instance:root_hash(InstanceId).

-spec fold_range(
    instance_id(),
    From :: bondy_oplog_event:event_key(),
    To :: bondy_oplog_event:event_key(),
    fun((bondy_oplog_event:t(), Acc) -> Acc),
    Acc
) -> Acc when Acc :: term().

fold_range(InstanceId, From, To, Fun, Acc0) ->
    bondy_oplog_instance:fold_range(InstanceId, From, To, Fun, Acc0).

-spec range(
    instance_id(),
    From :: bondy_oplog_event:event_key(),
    To :: bondy_oplog_event:event_key()
) -> [bondy_oplog_event:t()].

range(InstanceId, From, To) ->
    bondy_oplog_instance:range(InstanceId, From, To).

?DOC("""
Operator-driven removal of every event with key `=< Watermark` from
the live MST.

Advances `current_watermark/1` to `Watermark` (monotonically — a value
lower than the current watermark is ignored), so peer events arriving
later with HLC `=< Watermark` are rejected by the receive-side filter
instead of being re-installed. Without this, a peer that has not yet
seen the truncate would keep re-shipping the events we just dropped.

**No snapshot is written.** Events between the previous snapshot's
watermark and the new truncate watermark are *unrecoverable* by a
bootstrapping peer — that peer would receive the older snapshot and
then be rejected for every event in the gap. Use this only when the
operator has out-of-band evidence that the dropped events are safe to
lose cluster-wide. For coordinated retention with a snapshot, use
`compact/1` instead.

Returns the number of MST rows removed.
""").
-spec truncate_prefix(instance_id(), bondy_oplog_event:event_key()) ->
    non_neg_integer().

truncate_prefix(InstanceId, Watermark) ->
    %% Drain the local applier so truncation operates on the up-to-date
    %% MST. Without this, overlay-pending events whose keys are
    %% `=< Watermark` are invisible to the MST-level fold and survive
    %% the truncate — they are then installed by the applier *after*
    %% truncate_prefix has returned, leaving the caller with rows the
    %% truncate was meant to drop.
    _ = bondy_oplog_instance:await_apply(InstanceId),
    bondy_oplog_instance:truncate_prefix(InstanceId, Watermark).

-spec size(instance_id()) -> non_neg_integer().

size(InstanceId) ->
    bondy_oplog_instance:size(InstanceId).

-spec first_key(instance_id()) ->
    {ok, bondy_oplog_event:event_key()} | empty.

first_key(InstanceId) ->
    bondy_oplog_instance:first_key(InstanceId).

-spec latest_key(instance_id()) ->
    {ok, bondy_oplog_event:event_key()} | empty.

latest_key(InstanceId) ->
    bondy_oplog_instance:latest_key(InstanceId).

-spec origin(instance_id()) -> bondy_oplog_origin:t().

origin(InstanceId) ->
    bondy_oplog_instance:origin(InstanceId).

-spec info(instance_id()) -> map().

info(InstanceId) ->
    bondy_oplog_instance:info(InstanceId).

?DOC("""
Returns the current per-instance fold projection.

Drains the applier first so the returned projection reflects every
event the caller has already `append/2`-ed (read-your-writes).

Returns:
- `{ok, State}` — the current fold projection.
- `{error, no_fold_configured}` — the instance was started without
  `fold_module` set.
- `{error, instance_unavailable}` — applier pid not yet published
  (subtree restart in progress) or already gone.

**Scope:** single-cell-per-instance. Per-cell projections and
remote-event folding are not yet implemented.
""").
-spec projection(instance_id()) ->
    {ok, term()}
    | {error, no_fold_configured}
    | {error, instance_unavailable}.

projection(InstanceId) when is_binary(InstanceId) ->
    case bondy_oplog_instance:await_apply(InstanceId) of
        ok ->
            case bondy_oplog_registry:applier_pid(InstanceId) of
                undefined ->
                    {error, instance_unavailable};
                Pid when is_pid(Pid) ->
                    try
                        bondy_oplog_applier:projection(Pid)
                    catch
                        exit:{noproc, _} -> {error, instance_unavailable};
                        exit:noproc -> {error, instance_unavailable};
                        exit:{normal, _} -> {error, instance_unavailable};
                        exit:{shutdown, _} -> {error, instance_unavailable}
                    end
            end;
        {error, _} ->
            {error, instance_unavailable}
    end.

-doc """
The `bondy_db` DB name an oplog instance belongs to, derived from its id
(`<<"main/6">>` -> `main`). Returns `undefined` when the DB segment is not a
known atom.
""".
-spec db_of(instance_id()) -> atom() | undefined.

db_of(InstanceId) when is_binary(InstanceId) ->
    [Db | _] = binary:split(InstanceId, <<"/">>),
    try
        binary_to_existing_atom(Db, utf8)
    catch
        error:badarg -> undefined
    end.

-doc """
Record this node's frozen keying-topology fingerprint for `Db` (computed
by `bondy_db_manifest:fingerprint/1`). Exchanged during anti-entropy so two
nodes refuse to sync when they key data differently. Stored in
`persistent_term` (written once at provision, read on the sync path).
""".
-spec set_topology_fingerprint(Db :: atom(), Fingerprint :: binary()) -> ok.

set_topology_fingerprint(Db, Fingerprint) when
    is_atom(Db) andalso is_binary(Fingerprint)
->
    persistent_term:put({?MODULE, topology_fingerprint, Db}, Fingerprint).

-doc """
This node's keying-topology fingerprint for `Db`, or `undefined` if none
was recorded (e.g. an ephemeral in-memory DB with no manifest).
""".
-spec topology_fingerprint(Db :: atom() | undefined) -> binary() | undefined.

topology_fingerprint(undefined) ->
    undefined;
topology_fingerprint(Db) when is_atom(Db) ->
    persistent_term:get({?MODULE, topology_fingerprint, Db}, undefined).

%% =============================================================================
%% SYNC
%% =============================================================================

?DOC("""
Synchronously pulls events from `Peer` into `InstanceId`.

A successful pull merges the peer's tree into ours; a converse pull
(initiated by the peer) is needed to bring the peer up to date. This
is the single-direction primitive; consumers that want full
convergence call sync in both directions or rely on the default
schedulers running on both replicas.

Returns `{ok, FinalRoot}` on success.
""").
-spec sync(instance_id(), peer_id()) ->
    {ok, bondy_mst:hash() | undefined} | {error, term()}.

sync(InstanceId, Peer) ->
    sync(InstanceId, Peer, #{}).

-spec sync(
    instance_id(),
    peer_id(),
    bondy_oplog_sync_session:opts()
) -> {ok, bondy_mst:hash() | undefined} | {error, term()}.

sync(InstanceId, Peer, Opts) ->
    %% Drain the local applier so sync operates on the up-to-date MST
    %% instead of stale state with overlay-pending events. Production
    %% callers who do many appends followed by sync would otherwise
    %% sync against an MST that doesn't yet contain those appends.
    _ = bondy_oplog_instance:await_apply(InstanceId),
    bondy_oplog_sync_session:run(InstanceId, Peer, Opts).

?DOC("""
Bootstraps `InstanceId` from `Peer` — fetches the peer's snapshot,
installs it locally, then runs a regular sync for events past the
watermark. Suitable for fresh or far-behind replicas joining a
long-running cluster.

Falls back to plain `sync/2,3` semantics if the peer reports no
snapshot.
""").
-spec bootstrap(instance_id(), peer_id()) ->
    {ok, bondy_mst:hash() | undefined} | {error, term()}.

bootstrap(InstanceId, Peer) ->
    bootstrap(InstanceId, Peer, #{}).

-spec bootstrap(
    instance_id(),
    peer_id(),
    bondy_oplog_sync_session:opts()
) -> {ok, bondy_mst:hash() | undefined} | {error, term()}.

bootstrap(InstanceId, Peer, Opts) ->
    %% Drain the local applier so bootstrap operates on the
    %% up-to-date MST (same rationale as `sync/3`).
    _ = bondy_oplog_instance:await_apply(InstanceId),
    bondy_oplog_sync_session:bootstrap(InstanceId, Peer, Opts).

%% =============================================================================
%% GC / QUERIES
%% =============================================================================

?DOC("""
Runs one compaction cycle on `InstanceId`. See
`bondy_oplog_compaction:compact/1`.
""").
-spec compact(instance_id()) ->
    {ok, no_change}
    | {ok, {compacted, bondy_oplog_event:event_key(), non_neg_integer()}}
    | {error, term()}.

compact(InstanceId) ->
    %% No `await_apply` overlay-drain barrier here (unlike `truncate_prefix/2`,
    %% which truncates at a CALLER-supplied watermark that may sit above
    %% overlay-pending events). Compaction derives its frontier from
    %% peer-synced roots (`compute_frontier_for/2`), and a peer can only have
    %% synced events this node has already INSTALLED + PUBLISHED — so the
    %% frontier is always `=< the installed watermark`, strictly below the
    %% overlay-pending window. A non-empty overlay therefore cannot affect what
    %% is truncated. The barrier was not just redundant but harmful: under
    %% sustained writes the overlay never reaches 0, so the 5s `await_apply`
    %% timed out every cycle and compaction effectively never ran — most
    %% visibly for a fused instance (it IS the drain), leaving the MST to grow
    %% unbounded and `mst_install` latency to climb.
    bondy_oplog_compaction:compact(InstanceId).

-spec current_watermark(instance_id()) ->
    undefined | bondy_oplog_event:event_key().

current_watermark(InstanceId) ->
    bondy_oplog_instance:current_watermark(InstanceId).

-spec compaction_checkpoint(instance_id()) ->
    {ok, bondy_oplog_event:event_key(), term()} | not_found.

compaction_checkpoint(InstanceId) ->
    bondy_oplog_instance:compaction_checkpoint(InstanceId).

?DOC("""
Hot query: snapshot + live events. See
`bondy_oplog_query:query/2`.
""").
-spec query(instance_id(), Query :: term()) -> term().

query(InstanceId, Query) ->
    %% Hot query reads the MST (and snapshot). Drain so overlay-
    %% pending events are included.
    _ = bondy_oplog_instance:await_apply(InstanceId),
    bondy_oplog_query:query(InstanceId, Query).

?DOC("""
Stable query: snapshot only. See
`bondy_oplog_query:query_stable/2`.
""").
-spec query_stable(instance_id(), Query :: term()) -> term().

query_stable(InstanceId, Query) ->
    %% query_stable reads the snapshot store only (no live MST), but
    %% the underlying compaction/load_snapshot operations must have
    %% drained the applier first. We drain defensively here so a
    %% stale read between an append and the next compaction doesn't
    %% surprise callers.
    _ = bondy_oplog_instance:await_apply(InstanceId),
    bondy_oplog_query:query_stable(InstanceId, Query).

%% =============================================================================
%% RETENTION ADVICE
%% =============================================================================

%% Threshold under which both pressure ratios must fall to be considered
%% "low" (no retention action recommended). Chosen so that an instance
%% with comfortable headroom on either dimension is left alone.
-define(LOW_PRESSURE_THRESHOLD, 0.5).

?DOC("""
Surfaces a recommended retention action for `InstanceId` based on
current state: write/segment pressure ratios, snapshot existence,
outstanding scrubber alerts, and the number of in-flight bootstrap
consumers the caller is aware of.

The advice is **advisory only** — no state is changed. Returns
`{ok, retention_advice()}` with the recommended action
(`compact | truncate_prefix | none`), a human-readable rationale, and
the full set of inputs the decision was made from, so an operator can
audit the call.

Returns `{error, instance_not_running}` if `InstanceId` has no
running WAL.

The `bootstrap_consumers` count is operator-supplied: the library
does not track active bootstrap sessions as durable state, so the
caller is expected to plumb in any cluster-level information about
peers that are currently mid-bootstrap and would be orphaned by a
`truncate_prefix/2`.

Decision tree:

1. Scrubber alert outstanding ⇒ `none` (investigate the alert before
   changing retention).
2. Both pressure ratios under 50 % ⇒ `none` (ample headroom).
3. Otherwise:
   - bootstrap consumers > 0:
     - snapshot exists ⇒ `compact` (non-lossy; bootstrap consumers
       are unaffected because compaction preserves the snapshot
       watermark in the manifest).
     - no snapshot ⇒ `none` (truncate would orphan bootstrap; no
       snapshot to compact against — wait or take a snapshot first).
   - no bootstrap consumers:
     - snapshot exists ⇒ `compact` (non-lossy; preserves history up
       to the watermark).
     - no snapshot ⇒ `truncate_prefix` (no compaction lever
       available; operator picks a watermark).
""").
-spec retention_advice(instance_id()) ->
    {ok, retention_advice()} | {error, instance_not_running}.

retention_advice(InstanceId) ->
    retention_advice(InstanceId, #{}).

?DOC("""
As `retention_advice/1` but accepts a map of caller-supplied inputs:

- `bootstrap_consumers :: non_neg_integer()` (default `0`) — number
  of peers currently mid-bootstrap from this instance. Drives the
  bootstrap-aware branch of the decision tree.
""").
-spec retention_advice(instance_id(), map()) ->
    {ok, retention_advice()} | {error, instance_not_running}.

retention_advice(InstanceId, Opts) when
    is_binary(InstanceId), is_map(Opts)
->
    BootstrapConsumers = maps:get(bootstrap_consumers, Opts, 0),
    case bondy_oplog_registry:wal_pid(InstanceId) of
        undefined ->
            {error, instance_not_running};
        WalPid when is_pid(WalPid) ->
            WalInfo = bondy_oplog_wal:info(WalPid),
            Snapshot = ?MODULE:compaction_checkpoint(InstanceId),
            Inputs = build_inputs(WalInfo, Snapshot, BootstrapConsumers),
            {ok, retention_decision(Inputs)}
    end.

?DOC("""
Pure decision function — given a fully-populated `retention_inputs()`
map, returns the recommended action and rationale. Exposed primarily
for unit testing and for callers that have already gathered the
inputs by other means.
""").
-spec retention_decision(retention_inputs()) -> retention_advice().

retention_decision(#{scrubber_alerts := [_ | _] = Alerts} = Inputs) ->
    Rationale = list_to_binary(
        io_lib:format(
            "scrubber alert outstanding on ~p segment(s); resolve via "
            "re-derivation or magic-rescan before changing retention",
            [length(Alerts)]
        )
    ),
    advice(none, Rationale, Inputs);
retention_decision(#{pressure := P} = Inputs) ->
    BytesR = maps:get(bytes_ratio, P),
    SegsR = maps:get(segments_ratio, P),
    case max(BytesR, SegsR) < ?LOW_PRESSURE_THRESHOLD of
        true ->
            advice(
                none,
                <<"retention pressure is low; no action recommended">>,
                Inputs
            );
        false ->
            HasSnapshot = maps:get(has_snapshot, Inputs),
            Bootstrap = maps:get(bootstrap_consumers, Inputs),
            non_low_pressure_decision(HasSnapshot, Bootstrap, Inputs)
    end.

%% @private
non_low_pressure_decision(true, Bootstrap, Inputs) when Bootstrap > 0 ->
    advice(
        compact,
        <<
            "bootstrap consumers active; compact preserves the snapshot "
            "watermark and will not orphan them"
        >>,
        Inputs
    );
non_low_pressure_decision(false, Bootstrap, Inputs) when Bootstrap > 0 ->
    advice(
        none,
        <<
            "bootstrap consumers active but no snapshot exists; "
            "truncate_prefix would orphan them and compact has nothing "
            "to fold — wait for bootstrap to finish or take a snapshot "
            "first"
        >>,
        Inputs
    );
non_low_pressure_decision(true, _Bootstrap, Inputs) ->
    advice(
        compact,
        <<
            "snapshot exists; compact reclaims space without loss of "
            "history visible to peers"
        >>,
        Inputs
    );
non_low_pressure_decision(false, _Bootstrap, Inputs) ->
    advice(
        truncate_prefix,
        <<
            "no snapshot available; truncate_prefix at an "
            "operator-chosen watermark is the only retention lever"
        >>,
        Inputs
    ).

%% @private
advice(Action, Rationale, Inputs) ->
    #{
        recommended_action => Action,
        rationale => Rationale,
        inputs => Inputs
    }.

%% @private
build_inputs(WalInfo, Snapshot, BootstrapConsumers) ->
    BytesTotal = maps:get(bytes_total, WalInfo),
    MaxTotal = maps:get(max_total_wal_size, WalInfo),
    LiveSegs = maps:get(live_segments_count, WalInfo),
    MaxSegs = maps:get(max_live_segments, WalInfo),
    Backpressure = maps:get(backpressure, WalInfo, ok),
    ScrubberAlerts = maps:get(scrubber_alerts, WalInfo, []),
    Pressure = #{
        bytes_total => BytesTotal,
        max_total_wal_size => MaxTotal,
        bytes_ratio => safe_ratio(BytesTotal, MaxTotal),
        live_segments_count => LiveSegs,
        max_live_segments => MaxSegs,
        segments_ratio => safe_ratio(LiveSegs, MaxSegs),
        backpressure => Backpressure
    },
    {HasSnapshot, Watermark} = snapshot_summary(Snapshot),
    #{
        pressure => Pressure,
        has_snapshot => HasSnapshot,
        snapshot_watermark => Watermark,
        scrubber_alerts => ScrubberAlerts,
        bootstrap_consumers => BootstrapConsumers
    }.

%% @private
safe_ratio(_, Max) when Max =< 0 -> 0.0;
safe_ratio(N, Max) -> N / Max.

%% @private
snapshot_summary(not_found) ->
    {false, undefined};
snapshot_summary({ok, Key, _Value}) ->
    {true, Key}.
