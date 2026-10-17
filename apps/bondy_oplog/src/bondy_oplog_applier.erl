%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_applier).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-instance applier loop.

Sits between the per-instance WAL writer and the per-instance
`bondy_oplog_instance` gen_server. Responsibilities:

- On start, choose the resume position from the backend's durability
  (a static capability), never from the MST's live state. A durable
  backend resumes from the WAL's own committed consumer offset (see
  `start_pos_from_consumer_offset/1`); a volatile (ets/map) backend
  replays from `beginning` to rebuild its lost MST. Then open a
  non-following `bondy_log_reader` there. The WAL is just a byte
  log positioned by a cursor — it never depends on MST state.
- Drain the reader in batches. For each event in the batch the
  applier re-verifies the stored signature (defence-in-depth against
  WAL tampering) and then dispatches the surviving events to the
  instance via a one-way `gen_server:cast` so the instance installs
  them in the MST and evicts the matching overlay rows. The drain
  loop does not block on the install — the cast lands in the
  instance mailbox in FIFO order and is processed concurrently with
  the next batch's read+verify.
- At commit boundaries (every `commit_every` events or `end_of_log`)
  the applier issues a synchronous `drain_install_queue` call to the
  instance before persisting `consumer.offset` and advancing the
  WAL's committed-segment marker. The call returns `ok` once every
  in-flight install cast has been processed and the MST root holding
  them is durable; otherwise it exits and the offset stays where it was
  (`bondy_oplog_commit_barrier_test`). Only this boundary writes the
  offset; `terminate/2` does not.
- Acts as the verify gateway for peer-received events.
  `bondy_oplog_instance:append_remote/2` forwards each remote event
  here via `enqueue_remote/2`. The applier captures a read-only
  snapshot of the validator state at `init/1` and, on every
  `enqueue_remote` call, spawns a short-lived worker that re-verifies
  the signature, forwards verified events to the instance for
  origin-ban / backpressure / watermark filtering and the MST
  install, and replies to the caller. The applier's mailbox is
  freed immediately so WAL drain and concurrent remote events can
  interleave. This keeps the applier as the sole verify+dispatch
  origin for both local and remote events. Tree-level operations
  (`merge_pages`, `integrate_peer_root`, `truncate_prefix`, `compact`)
  are not event-stream operations and remain in the
  instance; the public façade drains the applier before invoking
  them.
- Owns the validator snapshot used for re-verification. Operators
  can rotate the snapshot at runtime via the
  `{refresh_validator, Reason}` cast (entry point is
  `bondy_oplog_instance:refresh_validator/1`); the cast calls
  `Mod:refresh/1` on the current snapshot and, on `{ok, NewState}`,
  installs `NewState` in the applier state. Workers spawned *before*
  the cast was processed continue to verify against the snapshot
  they captured — there is no mid-flight swap.

## Resume position

The applier resumes from the WAL's committed consumer offset on a
durable MST backend and from `beginning` on a volatile one; it never
reads the MST to choose. `resume_position/2` serves the fused drain of
an instance without an applier: it resumes at
`max(MST_last_key.hlc, snapshot_watermark.hlc)`, or `beginning` when
both are unknown. The frame holding that HLC is read again, so the
drain relies on a second install of an event leaving the tree as it was.

## Configuration

| Option              | Default | Meaning |
|---|---|---|
| `commit_every`      | `64`    | Apply this many events between `consumer.offset` flushes. |
| `poll_interval_ms`  | `5`     | Backstop sleep when `await_durable/3` returns sooner than expected. The hot path long-polls rather than sleeping; this only affects the rare error fallback. |
| `ae_targets`        | `[]`    | List of `{Namespace, Index, Shard}` tuples whose AE-freshness counters the instance's anti-entropy rounds bump (`bondy_oplog_sync_session`). The applier only adds a table that `register_table/4` joins to the instance and publishes the list to the registry. |
| `publish_ns`        | `undefined` | Namespace under which post-apply events are published via `bondy_oplog_core:publish/4`. `undefined` disables publishing. Requires `publish_fun`. A multiplexing (`per_shard`) instance ignores both and resolves the namespace per event from the bucket's own ctx — see `publish_batch_dir/2`. |
| `publish_fun`       | `undefined` | `fun((bondy_oplog_event:t()) -> {Key, Op} \| skip)` invoked per verified event to derive the `(Key, Op)` pair forwarded to subscribers. `skip` suppresses publish for that event. Required when `publish_ns` is set. |

## Substrate read-side wiring

The applier optionally drives the read-side substrate. Both hooks are
opt-in and consumer-configured; defaults are no-ops so existing
instances are unaffected.

- **Freshness** — a commit does not bump a shard's AE counter. Only an
  anti-entropy round confirms freshness: local writes say nothing about
  changes made on other nodes, and a cut-off node that keeps writing would
  otherwise pass the authentication fence
  (`proofs/tla/AuthFence_Refuse_CommitBumps.cfg` violates `FenceSafe`).
- **Subscriptions (`publish`)** — after `apply_batch/2` produces a
  non-empty verified set the applier walks the set in order and calls
  `publish_fun` per event. The applier passes `(Namespace, Key, Hlc,
  Op)` to `bondy_oplog_core:publish/4`. Delivery is best-effort
  (dispatcher walks subscribers; no round-trip; pattern matching runs
  in the applier process). Events for which `publish_fun` returns
  `skip` are not published. The applier's own mailbox is never
  blocked on delivery.

  **Timing — at-apply, not at-commit.** Publishing fires inside
  `apply_batch/2` (per verified event, in HLC-monotonic order). Batching
  publish into `commit_now/1` to mirror bump_ae was considered and
  rejected for the following reasons:

  - Latency: at-commit would batch up to `commit_every` events (default
    64) into one burst delivered at the commit barrier. At-apply
    publishes per event with no added queueing delay.
  - Commit-barrier cost: `commit_now/1` is already a synchronous
    barrier (it issues `drain_install_queue` against the instance
    gen_server). Folding an N-event publish pass into that barrier
    would extend it linearly in the batch size with ETS `select`s and
    `erlang:send/2`s.
  - Graceful-shutdown gap: at-commit would require an in-memory
    accumulator drained from `terminate/2`, which a crash never runs.
  - Crash semantics: at-least-once delivery is the contract on either
    side (a crash between apply and commit re-applies events on
    restart, producing duplicates regardless of timing). Subscribers
    must be idempotent or self-dedup — this is the contract.
  - Read consistency: readers via `bondy_oplog:read/3` see the new
    value as soon as the overlay/MST holds it (before commit), so
    at-apply publishes already align with what concurrent readers
    observe. Substrate-side reads through `bondy_oplog_core:read/3` depend
    on a separate projection-write path (out of scope here).

  Subscribers that need commit-coherent batching can coalesce
  consumer-side; the substrate's `commit_every` parameter is not the
  right knob for subscriber delivery cadence.

## Causal-stability invariants

Every reclamation feature is answerable to these; `ensure_remote_caught_up/1`
is where I1 is enforced.

**I1 (prepare-after-deliver).** Every operation on a cell `c` is prepared
against a state that reflects the effect of every event on `c` DELIVERED at
this replica before the prepare. "Delivered" means: locally originated and
WAL-drained (the drain writes the projection BEFORE the MST install, so local
events satisfy I1 by construction), or peer-merged by `integrate_peer_root`
(whose handler completion is the remote delivery point).

**I2 (containment stability).** The reclamation frontier `StableHlc`
(`bondy_oplog_instance:stability_point/1`) certifies, against every member's
durable frontier, this replica's included, that every member holds every
event this replica's tree holds with HLC < `StableHlc`.

**Theorem (causal stability without causal broadcast).** Given I1 and I2, any
event generated anywhere after `StableHlc` was certified carries a causal
context dominating every dot with HLC =< `StableHlc` on its cell. Hence any
state transformation derived solely from events at or below the frontier — a
`stabilize/2` `discard`, a `{keep, Reduced}` metadata reduction, an
order-independent accumulator fold — is invisible to every event that can
still arrive. Proof sketch: by I2 the generating replica held (and by I1 had
applied, before preparing) every such event for the cell; the prepared context
is `context_of/1` over that state, which contains their dots. This recovers
TCSB-grade causal stability (Baquero, Almeida & Shoker, arXiv:1710.04469
§7.2) in an anti-entropy architecture with no causal broadcast layer.
""").

-record(state, {
    instance_id :: instance_id(),
    instance_pid :: pid(),
    %% Remote-event verify workers by pid, each with the caller it replies
    %% to; `handle_info({'DOWN', ...})` replies for one that raised.
    verify_workers = #{} :: #{pid() => gen_server:from()},
    wal_pid :: pid(),
    wal_dir :: file:filename_all(),
    iter :: bondy_log_reader:t() | undefined,
    consumer_offset :: bondy_log_state:consumer_offset(),
    %% Number of events applied since the last `commit/1`. Used to
    %% batch consumer.offset writes — flushed at `commit_every` or
    %% when the reader returns `end_of_log`.
    uncommitted :: non_neg_integer(),
    commit_every :: pos_integer(),
    %% Coalesce consecutive WAL frames into one applier batch until at
    %% least this many events have accumulated; a soft cap, since a frame
    %% is never split. See `collect_frames/2` and
    %% `?DEFAULT_APPLY_BATCH_MAX_EVENTS`.
    apply_batch_max_events :: pos_integer(),
    %% Milliseconds between polling ticks when the reader returns
    %% `end_of_log`. Constant for now; the writer publishes an atomics
    %% durable position so a future revision could long-poll instead.
    poll_interval_ms :: pos_integer(),
    %% Validator module + snapshot of validator state for signature
    %% re-verification in the applier process. Fetched once from
    %% the instance at `init/1`. `verify_event/2` is read-only on
    %% state (the only state mutation happens in `sign_event/2` which
    %% the instance owns), so the snapshot remains valid for the
    %% lifetime of the applier.
    validator_module :: module(),
    validator_state :: term(),
    %% Substrate read-side wiring. Shards bumped via
    %% `bondy_oplog_core_registry:bump_ae/4` after each successful
    %% commit. Empty list disables the wiring.
    ae_targets = [] :: [shard_key()],
    %% Substrate subscription wiring. When both `publish_ns` and
    %% `publish_fun` are set, every verified event in an applied batch
    %% is forwarded to `bondy_oplog_core:publish/4` at apply time.
    %% See moduledoc "Substrate read-side wiring" for the rationale
    %% behind the at-apply timing.
    publish_ns :: atom() | undefined,
    publish_fun :: publish_fun() | undefined,
    %% Per-cell projection write wiring. When set, events whose op
    %% matches `{cell_apply, Bucket, Key, FoldEvent}` do a read-modify-write
    %% against the projection adapter registered for the configured
    %% `(NS, Index, Shard)` triple in `bondy_oplog_core_registry`. The
    %% cell's CRDT, taken from that registry entry, drives the
    %% decode/apply/encode cycle. `undefined` disables the path —
    %% existing instances are unaffected.
    cell_apply_ctx :: cell_apply_ctx(),
    %% Per-bucket apply-context source for the cell-apply mux. `{single, Ctx}`
    %% (one table per instance — today's default) routes every bucket to `Ctx`;
    %% `{dir, #{Bucket => Ctx}}` (a multiplexing per-shard instance) routes each
    %% bucket to its own table's ctx. Seeded at init from `cell_apply_bucket` and
    %% extended at runtime via `register_table/4` / `unregister_table/2`.
    %% `cell_apply_ctx` above stays the founding ctx for the single-table
    %% read-side handle_calls.
    cell_apply_source :: ctx_source(),
    %% tier_2 stamp-site context-regression guard: per locally stamped cell
    %% `{Bucket, Key}`, the highest causal context this applier has handed out
    %% on the tier_2 write path (`{cell_context, _, _}`). A cell's context only
    %% ever advances, so a regression between two local stamps means durable
    %% state was lost, and a same-origin write could re-mint a used dot; the
    %% stamp refuses it (`{error, {context_regression, _, _}}`) and telemeters.
    %% In-process only: it resets on restart (`bondy_db_tier2_durability_test`
    %% pins the durable projection as the reference) and on a catalogue install.
    ctx_guard = bondy_oplog_ctx_guard:new() :: bondy_oplog_ctx_guard:guard(),
    %% Demand-based flow control toward the instance gen_server. The applier
    %% increments slot 1 of `install_in_flight` before each
    %% `gen_server:cast({install_local_batch, …})`; the instance decrements it
    %% after handling the cast. When the value would reach
    %% `max_install_in_flight` the applier defers the next WAL read until the
    %% instance sends `drain_resume`. The cap bounds the NUMBER of in-flight
    %% casts, each carrying up to `apply_batch_max_events` events, so the
    %% worst-case instance-side backlog is the product of the two knobs.
    install_in_flight :: atomics:atomics_ref() | undefined,
    max_install_in_flight :: pos_integer() | undefined,
    %% Set when the applier deferred a drain because the cap was
    %% reached. The next `drain_resume` cast (or, defensively, the
    %% backstop poll timer) re-arms `self() ! drain`.
    drain_deferred = false :: boolean(),
    %% Drain-stall detection. `drain_max_pos` is the highest consumer position
    %% ever COMMITTED (`{Segment, FrameOffset}`; segment ids are never reused,
    %% so lexicographic order is total); only a commit beyond it counts as
    %% progress, so a drain that keeps re-reading old ground cannot masquerade
    %% as healthy. `drain_progress_at` is when progress (or a caught-up idle)
    %% was last observed; actively processing frames for longer than
    %% `drain_stall_alarm_ms` without it raises the
    %% `{bondy_oplog_drain_stalled, InstanceId}` alarm. `0` disables it.
    drain_progress_at :: integer() | undefined,
    drain_max_pos :: {non_neg_integer(), non_neg_integer()} | undefined,
    drain_stalled = false :: boolean(),
    drain_stall_alarm_ms = 60000 :: non_neg_integer(),
    %% Root hash of the MST snapshot whose `cell_apply` events have already
    %% been folded into the projection. `do_replay_cell_events/1` diffs the
    %% live MST against it (`bondy_mst:diff_to_list/2`) and re-applies only
    %% the new entries; `undefined` triggers a full fold. `init/1` sets it from
    %% `bondy_oplog_instance:replay_anchor/1`, which answers `undefined` when
    %% the live MST holds a cell event the restored frontier does not claim.
    %% Advanced only from `do_replay_cell_events/1`, never from `commit_now/1`,
    %% as `integrate_peer_root` can land unfolded remote pages under the root.
    last_replayed_root = undefined :: undefined | bondy_mst:hash(),
    %% A tree event may not have reached a fold yet, and only a diff from
    %% `last_replayed_root` presents it: the boot anchor found one unclaimed,
    %% or the last replay held one. A replay that holds nothing clears it.
    owed = false :: boolean(),
    %% The prepare fence's shared remote-delivery generation ref
    %% (`bondy_oplog_registry:remote_gen/1`), resolved lazily on first
    %% use (`undefined` until the instance's `init/1` has published it —
    %% before which nothing can have been integrated), and the
    %% generation this applier's projection is known to be caught up to.
    %% See `ensure_remote_caught_up/1` (I1).
    remote_gen_ref = undefined :: undefined | atomics:atomics_ref(),
    replayed_remote_gen = 0 :: non_neg_integer(),
    %% Bootstrap lifecycle handle (`bondy_oplog_bootstrap_lifecycle`).
    %% Cached once at `init/1` from the registry; the gate check in
    %% `drain_loop/1` is then a single `atomics:get/2`. `undefined` means the
    %% entry has not published one yet (race with the instance's `init/1`)
    %% and is treated as `live`; the instance's publish is idempotent and
    %% catches up by the next backstop tick.
    lifecycle :: bondy_oplog_bootstrap_lifecycle:handle() | undefined,
    %% Monitor reference of the parked idle-wait helper process (see
    %% `arm_idle_waiter/1`). `undefined` when the applier is actively
    %% draining or about to. The helper blocks on the WAL's
    %% `await_durable/3`; its monitor `DOWN` wakes the applier to
    %% re-drain.
    idle_waiter = undefined :: undefined | reference(),
    %% Callers parked on `await_drain/1` (the cold-start rebuild barrier),
    %% replied `ok` the next time the WAL drain reaches end-of-log. Empty in
    %% steady state.
    drain_waiters = [] :: [gen_server:from()],
    %% Per-boot WAL-drain gate, distinct from the durable bootstrap `lifecycle`.
    %% A collapsed per-shard instance (`shared_shards`) is founded by the first
    %% table opened on its shard, but its single WAL holds cells for every table
    %% sharing the shard; a drain before the siblings register their buckets
    %% would skip their cells for good (the MST install is unconditional).
    %% `gated` defers the drain until the catalogue has registered every table
    %% and releases it via `open_drain_gate/1`. Not durable: it re-engages on
    %% every boot, not on an applier restart within one. Defaults to `open`.
    drain_gate = open :: open | gated,
    %% The staged catalogue install (`install_catalogue_batch/3`).
    install_stage :: install_stage(),
    %% Boot WAL-replay logging state machine (opt-in via `log_boot_replay`).
    %% Emits ONE log when this instance's WAL replay begins and ONE when the
    %% first drain reaches end-of-log; a per-WAL boot progress marker, not a
    %% per-batch trace. `disabled` (the default) is a no-op; only the durable
    %% `main` shards opt in, so tests and ephemeral instances stay quiet.
    %% `armed`: opted in, replay not started. `{running, T0, N}`: replay
    %% started at `T0` (monotonic µs), `N` events applied so far. `done`:
    %% end-of-log logged; steady-state drains are silent.
    boot_replay = disabled ::
        disabled | armed | {running, integer(), non_neg_integer()} | done
}).

-type shard_key() :: {atom(), atom(), non_neg_integer()}.
-type publish_fun() :: fun(
    (bondy_oplog_event:t()) -> {Key :: term(), Op :: term()} | skip
).
%% The projection-write engine's per-shard context and secondary-index
%% descriptor were factored out into `bondy_oplog_cell_apply' (the shared
%% cell-apply module). The applier keeps these as aliases so its own
%% opts() and state record fields still resolve against the single
%% source of truth.
-type cell_apply_ctx() :: bondy_oplog_cell_apply:cell_apply_ctx().
-type install_stage() :: #{
    spool := file:filename_all(),
    token := reference() | undefined,
    buckets := [binary()],
    frontier := #{binary() => non_neg_integer()}
}.
-type stage_counts() :: #{
    installed := non_neg_integer(),
    pruned := non_neg_integer(),
    skipped := non_neg_integer(),
    unclaimable := [binary()],
    max_hlc := non_neg_integer()
}.
-type ctx_source() :: bondy_oplog_cell_apply:ctx_source().
-type index_descriptor() :: bondy_oplog_cell_apply:index_descriptor().

-type opts() :: #{
    instance_id := instance_id(),
    wal_dir := file:filename_all(),
    commit_every => pos_integer(),
    %% Coarser applier batching (soft event-count cap per applier
    %% batch). Default `?DEFAULT_APPLY_BATCH_MAX_EVENTS`. `1` disables the
    %% coalescing.
    apply_batch_max_events => pos_integer(),
    %% OldValue frame-cache. When `true`, the applier keeps a
    %% private, write-through cache of the last durable cell frame per
    %% `{Bucket, Key}`, so the per-event compute's OldValue read can
    %% skip the projection `get/3` (the dominant per-event cost on the
    %% durable stack) on a hit. Default `false`. `oldstate_cache_max`
    %% bounds the entry count; when exceeded the cache is cleared (coarse
    %% evict: it is rebuildable from the projection, so a clear only costs
    %% re-warm misses).
    oldstate_cache => boolean(),
    oldstate_cache_max => pos_integer(),
    poll_interval_ms => pos_integer(),
    %% The shards the instance's anti-entropy rounds keep fresh.
    ae_targets => [shard_key()],
    %% Substrate subscription wiring: namespace for post-apply publish.
    publish_ns => atom(),
    publish_fun => publish_fun(),
    %% Per-cell projection write wiring. The shard must already be
    %% registered in `bondy_oplog_core_registry`. Resolved eagerly at init/1.
    cell_apply_target := shard_key(),
    %% Secondary-index descriptors for this primary table. Passed
    %% through into the `cell_apply_ctx`; only meaningful alongside
    %% `cell_apply_target`.
    secondary_indexes => [index_descriptor()],
    %% Found this instance with the WAL drain GATED: the applier does not
    %% drain (nor cold-replay) at init; it waits for `open_drain_gate/1`.
    %% Set by the provisioning orchestrator for a collapsed per-shard
    %% (`shared_shards`) instance so its shared WAL is not replayed until
    %% every sibling table on the shard has registered its cell-apply bucket.
    %% Default `false`. See the `drain_gate` state field.
    drain_gated => boolean(),
    %% Emit a single boot log when this instance's WAL replay starts and a
    %% single log when the first drain reaches end-of-log. Default `false`.
    %% Set by the catalogue for the durable `main` shards. See `boot_replay`.
    log_boot_replay => boolean()
}.

-export_type([opts/0]).
-export_type([install_stage/0]).
-export_type([stage_counts/0]).

%% Report returned by `reap_origins_sync/2` — see `bondy_oplog_cell_utils`
%% (shared with the fused instance path) for the field meanings.
-type reap_report() :: bondy_oplog_cell_utils:reap_report().

-export_type([reap_report/0]).

-export([start_link/1]).
-export([child_spec/1]).
-export([stop/1]).
-export([enqueue_remote/2]).
-export([refresh_validator/2]).
-export([notify_drain_resume/1]).
-export([replay_cell_events/1]).
-export([replay_cell_events_sync/1]).
-export([last_replayed_root/1]).
-export([advance_replayed_root/2]).
-export([rederive_projection_sync/2]).
-export([rebuild_indexes_sync/2]).
-export([await_drain/1]).
-export([reap_origins_sync/2]).
-export([barrier/1]).
-export([cell_apply_target/1]).
-export([sweep_stable_cells/2]).
-export([sweep_stable_cells/3]).
-export([begin_stage/3]).
-export([install_catalogue_batch/3]).
-export([new_install_stage/1]).
-export([open_stage/3]).
-export([stage_cells/3]).
-export([commit_stage/4]).
-export([drop_stage/2]).
%% Exposed for unit testing the bootstrap-announcement conditions without an
%% applier, a projection or a dispatcher.
-export([bootstrap_publish_decision/3]).
-export([cell_context/3]).
%% State-free drain leaves reused verbatim by the ephemeral fused-writer
%% mode in `bondy_oplog_instance`, so the fused instance runs an identical
%% drain + remote replay without this gen_server.
-export([resolve_cell_apply_ctx/1]).
-export([build_cell_apply_source/3]).
-export([resolve_cell_ctx/3]).
-export([register_table/4]).
-export([unregister_table/2]).
-export([open_drain_gate/1]).
-export([resume_position/2]).

-ifdef(TEST).
%% Exposed for deterministic unit testing of the drain-stall detector,
%% decoupled from the clock (the /2 forms take `Now`) and from a running
%% applier (`stall_test_state/1` builds a minimal state).
-export([check_drain_stall/2]).
-export([note_drain_progress/2]).
-export([note_drain_idle/2]).
-export([stall_test_state/1]).
-export([stall_test_fields/1]).
-endif.
-export([collect_frames/2]).
-export([diff_pairs/2]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-define(DEFAULT_COMMIT_EVERY, 64).

%% Cells a snapshot install reads per page while deleting the local cells the
%% snapshot lacks.
-define(PRUNE_PAGE, 256).
%% Coarser applier batching. The drain loop coalesces consecutive WAL frames
%% into a single applier batch until the accumulated event count reaches this
%% threshold (or the reader hits `end_of_log`), so the two co-dominant
%% per-batch storage costs, the pack-store spine rebuild and the leveled
%% projection `put_batch`, amortise over many more events. A soft cap: a frame
%% is never split, so a batch may exceed it by the last frame's size. `1`
%% restores one-frame-per-apply. Engages only under a WAL backlog; when
%% caught up only one frame is available before `end_of_log`.
-define(DEFAULT_APPLY_BATCH_MAX_EVENTS, 256).
%% Default OldValue frame-cache entry cap. Bounds memory; when
%% exceeded the cache is cleared (it is rebuildable from the projection).
-define(DEFAULT_OLDSTATE_CACHE_MAX, 100_000).
%% The applier long-polls the WAL via `await_durable/3` on
%% `end_of_log` rather than sleeping between ticks, so this only
%% bounds the wake-up cadence when the WAL is idle. A small interval
%% keeps responsiveness if `await_durable/3` ever returns sooner than
%% expected or a future revision drops the long-poll path.
-define(DEFAULT_POLL_INTERVAL_MS, 5).
%% Soft inner timeout for the `await_durable/3` long-poll. Bounded so
%% supervisor shutdown messages and any future control-plane signals
%% are processed in a timely fashion.
-define(AWAIT_DURABLE_TIMEOUT_MS, 200).
%% Default per-secondary-shard in-flight cap. A batch that would push the
%% writer's unflushed-op backlog past this is dropped and the shard
%% scheduled for rebuild. Must exceed a shard's live-entry working set;
%% overridable per index via the spec's `max_inflight`. Large by design —
%% back-pressure is a safety valve for a pathologically hot shard, not a
%% steady-state throttle.

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(opts()) -> {ok, pid()} | {error, term()}.

start_link(#{instance_id := _, wal_dir := _} = Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec child_spec(opts()) -> supervisor:child_spec().

child_spec(#{instance_id := InstanceId} = Opts) ->
    #{
        id => {?MODULE, InstanceId},
        start => {?MODULE, start_link, [Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

-spec stop(pid()) -> ok.

stop(Pid) when is_pid(Pid) ->
    try gen_server:stop(Pid, normal, 5000) of
        ok -> ok
    catch
        exit:noproc -> ok;
        exit:{noproc, _} -> ok
    end.

-spec enqueue_remote(pid(), bondy_oplog_event:t()) ->
    ok | {error, term()}.

%% Verify gateway for peer-received events. The call returns once a
%% per-event worker has finished verifying the signature, forwarded
%% the event to the instance, and received its accept/reject reply —
%% so callers continue to see `equivocation_detected`, `banned_origin`,
%% and other accept/reject modes synchronously. While the worker runs,
%% the applier's own mailbox is free, so WAL drain and other remote
%% events interleave without head-of-line blocking.
enqueue_remote(ApplierPid, Event) when is_pid(ApplierPid) ->
    gen_server:call(ApplierPid, {enqueue_remote, Event}, infinity).

-spec refresh_validator(pid(), term()) -> ok.

%% Asks the applier to refresh its in-process validator snapshot by
%% calling `Mod:refresh/1` on the current snapshot. The cast is
%% fire-and-forget; the applier logs success/failure and emits
%% telemetry. Validators that do not export `refresh/1` are a no-op
%% (debug log).
%%
%% Operators normally call `bondy_oplog_instance:refresh_validator/1`,
%% which resolves the applier pid for them.
refresh_validator(ApplierPid, Reason) when is_pid(ApplierPid) ->
    gen_server:cast(ApplierPid, {refresh_validator, Reason}).

-spec notify_drain_resume(pid()) -> ok.

-doc """
Called by the instance after it processes an `install_local_batch`
cast and the in-flight counter drops below the cap. Lets the applier
resume reading the WAL if it had deferred its drain. Idempotent:
extra resumes during normal operation are absorbed by the
`drain_deferred` flag.
""".
notify_drain_resume(ApplierPid) when is_pid(ApplierPid) ->
    gen_server:cast(ApplierPid, drain_resume).

-spec replay_cell_events(pid()) -> ok.

-doc """
Folds the MST events the projection lacks through the cell_apply path: the
diff since the last replayed root, or the whole tree when there is none. The
instance calls it after a `merge_pages` / `integrate_peer_root` cycle, so that
peer-received events reach the per-cell projection.

Delivery is causal (`bondy_oplog_cell_apply:apply_cell_pairs_mux/5`), and an
event the applied frontier already claims is skipped, so repeating a replay
folds nothing twice.
""".
replay_cell_events(ApplierPid) when is_pid(ApplierPid) ->
    gen_server:cast(ApplierPid, replay_cell_events).

-spec replay_cell_events_sync(pid()) -> ok.

-doc """
Synchronous variant of `replay_cell_events/1`. Blocks the caller
until the diff fold has been applied to the projection, so a read
issued immediately after this returns observes the peer-merged events
the corresponding sync session installed. Otherwise identical to the
cast (idempotent).
""".
replay_cell_events_sync(ApplierPid) when is_pid(ApplierPid) ->
    gen_server:call(ApplierPid, replay_cell_events, infinity).

-spec last_replayed_root(pid()) -> bondy_mst:hash() | undefined.

-doc """
The root the projection has been replayed up to — the replay cursor
`do_replay_cell_events/1` diffs the instance's current root against. A
diagnostic read (tests); nothing in the pipeline calls it.
""".
last_replayed_root(ApplierPid) when is_pid(ApplierPid) ->
    gen_server:call(ApplierPid, last_replayed_root, infinity).

-spec advance_replayed_root(pid(), bondy_mst:hash() | undefined) -> ok.

-doc """
Moves `last_replayed_root` to `NewRoot` WITHOUT applying any pairs.

Called by the instance's compaction commit right after it truncates the
MST. Re-anchoring keeps the next replay diff INCREMENTAL: the pre-truncate
root's pages are freed by the truncate, so without it every compaction cycle
would cost a full `to_list/1` fold.

`NewRoot` is a replayed root only when every event under it reached a fold:
the instance casts each delivery's replay before this, so the replays have
run, and only a hold, or a boot anchor that found an unclaimed event, can
leave one unfolded (`owed`). Then the cursor becomes `undefined` instead, and
the next replay folds the whole tree
(`proofs/tla/ReplayReanchor.tla`; `bondy_oplog_catalogue_compaction_test:
held_event_folds_after_compaction/0` and
`owed_refold_survives_compaction_before_gate/0`).
""".
advance_replayed_root(ApplierPid, NewRoot) when is_pid(ApplierPid) ->
    %% MUST be a cast, NOT a call. The instance issues this from inside its
    %% compaction commit handler, and the applier issues a synchronous
    %% `drain_install_queue` call back to the instance on every commit
    %% boundary (`commit_now/1`), so a call here would deadlock the two
    %% gen_servers whenever a compaction overlaps a commit. Re-anchoring is a
    %% perf hint: `diff_pairs/2` falls back to a full `to_list/1` over the
    %% now-bounded tree if the anchor is momentarily stale.
    gen_server:cast(ApplierPid, {advance_replayed_root, NewRoot}).

-spec rederive_projection_sync(pid(), reference()) ->
    {ok, stage_counts()} | {error, term()}.

-doc """
The applier side of `bondy_oplog_instance:rederive_projection/2`: installs what
`Token` staged and sets the applied frontier (`commit_stage/4`), resets the
replay cursor and folds the MST through the
holding fold, which folds only the events the frontier does not claim and
reports the full replay (`bondy_oplog_instance:refolded/1`). A failed install
still re-folds, over the cells it wrote, and is the reply. The install, the
frontier and the fold run in this process, as the WAL drain does, so no apply
claims between them.
""".
rederive_projection_sync(ApplierPid, Token) when is_pid(ApplierPid) ->
    gen_server:call(ApplierPid, {rederive_projection, Token}, infinity).

%% @private
%% Sets instance `Id`'s applied frontier after the install whose reply is
%% `Installed`: to `PeerFrontier` (the source's pre-stream frontier) when every
%% cell the source shipped landed, else `#{}`
%% (`bondy_oplog_registry:replace_frontier/2`); the re-fold that follows folds
%% the unclaimed events onto the installed cells (`proofs/tla/JoinInstall.tla`,
%% `Rederive`). A cell carries no origin or seq, so the rule is all-or-nothing;
%% adopting regardless over-claims (`unconditional_adoption_unsound`).
adopt_frontier(Id, {ok, #{unclaimable := []}}, PeerFrontier) ->
    bondy_oplog_registry:replace_frontier(Id, PeerFrontier);
adopt_frontier(Id, _Installed, _PeerFrontier) ->
    bondy_oplog_registry:replace_frontier(Id, #{}).

-spec rebuild_indexes_sync(pid(), {atom(), atom(), non_neg_integer()}) ->
    ok | {error, {table_not_served, term()}}.

-doc """
Re-derives the secondary indexes of the table whose primary shard is `Key`
from each live cell's CURRENT projection value, re-dispatching a `put` for
every live term to the secondary writers
(`bondy_oplog_cell_utils:reindex_table/3`). The dispatch **bypasses the writer
back-pressure cap** so the rebuild can load the full working set in one pass
even when the cap was exceeded. Combined with the rebuild orchestrator first
clearing the stale index shard, this restores the index exactly.
""".
rebuild_indexes_sync(ApplierPid, Key) when is_pid(ApplierPid) ->
    gen_server:call(ApplierPid, {rebuild_indexes, Key}, infinity).

-spec await_drain(pid()) -> ok.

-doc """
Block until the applier has drained its WAL to end-of-log — the cold-start
rebuild barrier. Queues the caller and triggers a drain; replies `ok` the moment
the drain next reaches end-of-log, so a `rebuild_indexes_sync/2` (or a freshen on
the trust path) issued afterwards observes a fully-replayed MST/projection rather
than racing the not-yet-applied tail.
""".
await_drain(ApplierPid) when is_pid(ApplierPid) ->
    gen_server:call(ApplierPid, await_drain, infinity).

-spec reap_origins_sync(pid(), [term()]) ->
    {ok, reap_report()} | {error, term()}.

-doc """
Reap the per-cell causal-context entries of permanently-retired origins
across this shard's projection. Walks every cell named in the MST, asks
the cell kernel to drop the value-preserving (causal-history-only) entries
of `RetiredOrigins`, and re-persists only the cells that changed.
Co-evicts the reaped origins from the tier_2 stamp-site context-regression
guard (`#state.ctx_guard`) so the legitimate context shrink is not
mistaken for a regression.

Runs synchronously in the applier's single-cell scope, so it is atomic
w.r.t. concurrent cell writes. Idempotent — a second pass with the same
origins reaps nothing. A no-op (`supported => false`) when the shard's
kernel is not a context-carrying tier_2 CRDT (legacy fold or tier_0),
leaving the projection byte-identical.

The library cannot know which origins are retired (membership is delegated
to the consumer); the operator supplies `RetiredOrigins` and owns the
obligation that they are permanently gone and causally stable cluster-wide
(see `bondy_oplog_crdt_mv_register` *Convergence preconditions*). The
value-preserving gate means even a premature call cannot lose live data —
it just reaps fewer entries.

**Durability of a reap (both bounded-by-churn, not convergence bugs — the
cell's value always converges).** A reap rewrites the projection
checkpoint, not the MST: the retired origin's events still sit in the
cell's MST group until compaction truncates them below the stability
frontier. So:

- A **live re-bootstrap** re-folds the MST events its adopted frontier does
  not claim onto the projection (`rederive_projection_sync/2`)
  and re-introduces the reaped causal-history-only entry. Re-run the reap
  after a re-bootstrap to reclaim it.
- A **fully-compacted cell** (its events already truncated from the MST,
  value only in the checkpoint) is not visited by the
  `distinct_cell_keys/1` MST walk, so its retired-origin entry is not
  reaped — the same enumeration limitation as the secondary-index rebuild.
  The entry is harmless (value-preserving) and bounded by the
  retired-origin count.
""".
reap_origins_sync(ApplierPid, RetiredOrigins) when
    is_pid(ApplierPid), is_list(RetiredOrigins)
->
    gen_server:call(ApplierPid, {reap_origins, RetiredOrigins}, infinity).

-spec cell_apply_target(pid()) -> {ok, shard_key()}.

-doc """
Returns the applier's resolved `cell_apply_target` shard key. Used by the
catalogue-snapshot bootstrap path to discover where to read the
projection's cells from.
""".
cell_apply_target(ApplierPid) when is_pid(ApplierPid) ->
    gen_server:call(ApplierPid, cell_apply_target, infinity).

-doc """
A synchronous settle barrier: returns once the applier has served every
message enqueued before this call — in particular the
`replay_cell_events` cast an `integrate_peer_root` issued earlier — AND
has caught its projection up to the instance's remote-delivery
generation (the I1 fence, `ensure_remote_caught_up/1`), which also
covers a lost best-effort replay cast. After this returns, the
projection (and the applied-frontier VV its replay advances) reflects
every remote event delivered to the instance before the call. Used by
the sync session's frontier-gap check to rule out replay lag before
declaring a deficit genuine.
""".
-spec barrier(pid()) -> ok.

barrier(ApplierPid) when is_pid(ApplierPid) ->
    gen_server:call(ApplierPid, barrier, infinity).

-doc """
Reclaims projection cells that are no longer semantically meaningful once
`StableHlc` is causally stable.

Walks the shard's primary cells and asks the fold's `stabilize/2` what remains
of each. `discard` removes the cell physically — via `Adapter:delete/3`, which
on the leveled backend emits real `remove` ObjectSpecs that LSM compaction can
reclaim, unlike a tombstone written as an ordinary value.

`{keep, State}` — causal-stabilization reduction (e.g. a struct field's stable
per-origin sub-op runs folded into synthetic ops) — is persisted as a
value-preserving frame rewrite (same Hlc, same value column, smaller state
bytes; the same out-of-band rewrite `reap_origins` performs) and counted as
`rewritten`. It rides the same overlay fence as `discard`.

Runs **inside the applier process**, deliberately. The applier is the only
writer to the projection, so a sweep executed here is serialised against
applies and cannot interleave a delete with a concurrent write to the same
cell. It is a bounded, explicitly-driven pass rather than a background loop —
the caller decides when, and pays the latency.

`StableHlc` MUST come from a confirmed all-peer frontier
(`bondy_oplog_peer_state:confirmed_peer_states/2`), and MUST be strictly
greater than the HLC of any cell it licenses discarding. Deriving it from
anything weaker — the recency-filtered peer read, or the compaction watermark —
reclaims cells a lagging peer can still contradict, which resurrects deleted
data silently and permanently.

Returns a summary. A cell whose projection value cannot be read is skipped and
counted, never treated as reclaimable: absence of evidence is not evidence of
staleness.
""".
-spec sweep_stable_cells(pid(), bondy_connect_hlc:hlc()) ->
    {ok, #{
        scanned := non_neg_integer(),
        discarded := non_neg_integer(),
        rewritten := non_neg_integer(),
        skipped := non_neg_integer()
    }}
    | {error, term()}.

sweep_stable_cells(ApplierPid, StableHlc) ->
    %% Unbounded: with no budget the bounded form always completes.
    case sweep_stable_cells(ApplierPid, StableHlc, #{}) of
        {ok, Stats, done} -> {ok, Stats};
        {error, _} = E -> E
    end.

-doc """
As `sweep_stable_cells/2`, bounded and resumable.

`max_cells` caps the cells *scanned* in this call (default `infinity`). The
sweep runs inside the applier — the sole projection writer — so an unbounded
pass over a large shard stalls every write to it for the duration; the bound
is the latency mechanism. `{resume, Cursor}` names where the pass stopped;
pass it back as `cursor` to continue. Members (registered tables) already
swept are skipped WITHOUT re-enumerating their directories; only the member
the cursor points into is enumerated again.

A cursor is only meaningful against the same `StableHlc` epoch or a later
one — stability is monotone, so resuming batches under a newer (higher)
point is safe; it can only license more.

A cell left behind by a bound is simply "left in place and retried on a
later pass" — the same semantics as a fence-skipped cell, so partial passes
need no new invariant.
""".
-spec sweep_stable_cells(
    pid(),
    bondy_connect_hlc:hlc(),
    Opts :: #{
        max_cells => pos_integer() | infinity,
        cursor => undefined | term()
    }
) ->
    {ok,
        #{
            scanned := non_neg_integer(),
            discarded := non_neg_integer(),
            rewritten := non_neg_integer(),
            skipped := non_neg_integer()
        },
        done | {resume, Cursor :: term()}}
    | {error, term()}.

sweep_stable_cells(ApplierPid, StableHlc, Opts) when
    is_pid(ApplierPid), is_integer(StableHlc), is_map(Opts)
->
    gen_server:call(
        ApplierPid, {sweep_stable_cells, StableHlc, Opts}, infinity
    ).

-doc """
Registers (or replaces) a table on a multiplexing per-shard applier: routes the
given `Bucket` to a cell-apply context resolved from `Target` (its
`{NS, primary, Shard}` registry triple) plus `TableOpts` (`publish_ns`,
`secondary_indexes`). The applier must have been started with `cell_apply_bucket`
(i.e. in `{dir, _}` mode). Also adds `Target` to the applier's AE-freshness
targets so an idle sibling shard still certifies fresh.
""".
-spec register_table(
    ApplierPid :: pid(),
    Bucket :: binary(),
    Target :: shard_key(),
    TableOpts :: map()
) -> ok | {error, term()}.

register_table(ApplierPid, Bucket, Target, TableOpts) when
    is_pid(ApplierPid), is_binary(Bucket), is_map(TableOpts)
->
    gen_server:call(
        ApplierPid, {register_table, Bucket, Target, TableOpts}, infinity
    ).

-doc """
Removes a table's bucket from a multiplexing applier's cell-apply directory (the
per-table step of `bondy_db:close_table/1` for a shared shard instance). A no-op
when the bucket was not registered.
""".
-spec unregister_table(ApplierPid :: pid(), Bucket :: binary()) -> ok.

unregister_table(ApplierPid, Bucket) when
    is_pid(ApplierPid), is_binary(Bucket)
->
    gen_server:call(ApplierPid, {unregister_table, Bucket}, infinity).

-doc """
Releases an applier founded with `drain_gated => true`: flips its per-boot drain
gate `open` and kicks the deferred WAL drain (and the cold-replay catch-up). The
provisioning orchestrator calls this — exactly once per per-shard instance —
after every table sharing the shard has registered its cell-apply bucket, so the
shared WAL is replayed with a complete `cell_apply_source` and no cell is
skipped. Idempotent and asynchronous; a no-op on an ungated applier.
""".
-spec open_drain_gate(ApplierPid :: pid()) -> ok.

open_drain_gate(ApplierPid) when is_pid(ApplierPid) ->
    gen_server:cast(ApplierPid, open_drain_gate).

-spec cell_context(pid(), term(), term()) ->
    {ok, term()} | {error, term()}.

-doc """
Read the cell's current causal context (`bondy_oplog_crdt:context_of/1`)
for `(Bucket, Key)` in the applier's single-cell scope. Used by
`bondy_db:apply/4` on the tier_2 write path to stamp the context the new
write observed into the event `meta` before WAL append. Returns
`{ok, undefined}` when the cell's CRDT does not carry a context
(tier_0/tier_1).
""".
cell_context(ApplierPid, Bucket, Key) when is_pid(ApplierPid) ->
    gen_server:call(ApplierPid, {cell_context, Bucket, Key}, infinity).

-spec begin_stage(pid(), [binary()], #{binary() => non_neg_integer()}) ->
    {ok, reference()} | {error, term()}.

-doc """
Opens a catalogue install of a snapshot of `Buckets` on the applier's
projection shard (`open_stage/3`): the returned token names it in
`install_catalogue_batch/3` and `rederive_projection_sync/2`.
""".
begin_stage(ApplierPid, Buckets, PeerFrontier) when
    is_pid(ApplierPid), is_list(Buckets)
->
    gen_server:call(ApplierPid, {begin_stage, Buckets, PeerFrontier}, infinity).

-spec install_catalogue_batch(
    pid(), reference(), [bondy_oplog_transport:cell()]
) -> ok | {error, term()}.

-doc """
Stages a batch of catalogue-snapshot cells for the install `Token` names
(`stage_cells/3`).
""".
install_catalogue_batch(ApplierPid, Token, Cells) when
    is_pid(ApplierPid), is_list(Cells)
->
    gen_server:call(
        ApplierPid, {install_catalogue_batch, Token, Cells}, infinity
    ).

-doc """
An install stage that holds no install, over the spool of the instance whose
WAL lives in `WalDir`; `open_stage/3` deletes what an earlier process staged
there.
""".
-spec new_install_stage(WalDir :: file:filename_all()) -> install_stage().

new_install_stage(WalDir) ->
    #{
        spool => filename:join(WalDir, "catalogue_install.spool"),
        token => undefined,
        buckets => [],
        frontier => #{}
    }.

-doc """
Opens a catalogue install of a snapshot of `Buckets`, the buckets its source
scanned, discarding whatever an earlier one staged. `PeerFrontier` is the
frontier its source reported before the stream, which `commit_stage/4` adopts. The token it returns names
the install; opening another one, or restarting the
process that holds the stage, makes every later call with this token fail
with `{error, install_superseded}`, so a session only ever installs what it
staged itself (`bondy_oplog_bootstrap_rederive_test`, the superseded-install
cases).
""".
-spec open_stage(
    [binary()], #{binary() => non_neg_integer()}, install_stage()
) ->
    {{ok, reference()} | {error, term()}, install_stage()}.

open_stage(Buckets, PeerFrontier, #{spool := Spool} = Stage) when
    is_list(Buckets), is_map(PeerFrontier)
->
    case delete_spool(Spool) of
        ok ->
            Token = make_ref(),
            {{ok, Token}, Stage#{
                token => Token, buckets => Buckets, frontier => PeerFrontier
            }};
        {error, _} = Error ->
            {Error, Stage#{token => undefined}}
    end.

-doc """
Appends `Cells` to the install `Token` names. The projection is untouched until
`commit_stage/4` installs every staged batch, which the folding process
re-folds over in the same call: a fold onto an installed cell before its
re-fold would lift its context over an event the re-fold must still fold,
which the kernel would then skip as covered
(`bondy_oplog_bootstrap_rederive_test`, the install-window cases;
`proofs/tla/JoinInstall_Truncation_CompactMembers.cfg` holds,
`..._CompactMembers_Replace.cfg` violates `SettledSound`). A spool write
that fails returns `{error, {install_spool, Reason}}`.
""".
-spec stage_cells(reference(), [bondy_oplog_transport:cell()], install_stage()) ->
    ok | {error, term()}.

stage_cells(Token, Cells, #{token := Token, spool := Spool}) when
    is_reference(Token), is_list(Cells)
->
    Bin = term_to_binary(Cells),
    maybe
        ok ?= filelib:ensure_dir(Spool),
        ok ?=
            file:write_file(
                Spool, [<<(byte_size(Bin)):32>>, Bin], [append, raw]
            )
    else
        {error, Reason} -> {error, {install_spool, Reason}}
    end;
stage_cells(_Token, _Cells, _Stage) ->
    {error, install_superseded}.

-doc """
Ends the install `Token` names by writing every batch it staged, in staging
order, setting the applied frontier (`adopt_frontier/3`), and emptying the
stage. The caller re-folds unless the reply is `{error, install_superseded}`,
which writes nothing.

Every cell whose bucket routes here REPLACES the local cell, whatever its HLC: a
re-bootstrap starts from the peer's state, and the local events the peer lacks
are folded back by the re-fold. Keeping a local cell instead would let the
adopted peer frontier claim events that cell never folded
(`proofs/tla/LiveRebootstrapRefold_SkipIfOlder_TrailFail.cfg`). Each write
invalidates the read cache and advances the per-shard high-water HLC atomic.

The snapshot installs whole: a local cell of one of the stage's buckets that
the source's scan did not ship is deleted, as the model's `InstallCell` installs
an absent source cell (`proofs/tla/JoinInstall.tla`;
`bondy_oplog_bootstrap_rederive_test`, `cell_the_snapshot_lacks_is_pruned`,
`empty_source_table_prunes_every_cell`). A bucket outside the stage, one the
source has no table for, keeps its cells
(`table_the_source_lacks_keeps_its_cells`). Each delete invalidates the read
cache; a read of the local cells that fails ends the install with
`{error, {projection_read_failed, Reason}}`.

`{ok, Counts}` counts what the install did; `pruned` counts the deletes.
`skipped` counts the cells that did not land; `unclaimable` names their
buckets, one with no table registered here or a frame that would not decode.
The caller adopts the peer's applied frontier only when it is empty: a cell carries no origin and no seq, so "did everything
the peer shipped land" is the only question an install can answer about the
frontier. `max_hlc` is the highest cell HLC installed. A write that fails ends
the install with `{error, {projection_write_failed, Reason}}`, dropping the
batches after it, so the session adopts no frontier
(`LiveRebootstrapRefold_Proposed_WriteFailCounted.cfg` in `proofs/tla/`;
`bondy_oplog_bootstrap_rederive_test`, `failed_install_write_adopts_nothing`).
""".
-spec commit_stage(
    reference(), instance_id(), Source :: term(), install_stage()
) ->
    {{ok, stage_counts()} | {error, term()}, install_stage()}.

commit_stage(
    Token,
    Id,
    Source,
    #{token := Token, spool := Spool, buckets := Buckets} = Stage
) when
    is_reference(Token)
->
    Reply = install_staged(Id, Source, Buckets, Spool),
    ok = delete_spool(Spool),
    ok = adopt_frontier(Id, Reply, maps:get(frontier, Stage)),
    {Reply, Stage#{token => undefined}};
commit_stage(_Token, _Id, _Source, Stage) ->
    {{error, install_superseded}, Stage}.

-doc """
Ends the install `Token` names by dropping what it staged, writing nothing; the
cells and the claims are as the install found them
(`proofs/tla/JoinInstall.tla`, `Abort`).
""".
-spec drop_stage(reference(), install_stage()) ->
    {ok | {error, install_superseded}, install_stage()}.

drop_stage(Token, #{token := Token, spool := Spool} = Stage) when
    is_reference(Token)
->
    ok = delete_spool(Spool),
    {ok, Stage#{token => undefined}};
drop_stage(_Token, Stage) ->
    {{error, install_superseded}, Stage}.

%% @private
install_staged(Id, Source, Buckets, Spool) ->
    maybe
        {ok, Acc} ?= install_spool(Id, Source, Spool),
        {ok, Counts} ?= prune_tails(Id, Source, Buckets, Acc),
        {ok, maps:without([last, idx], Counts)}
    end.

%% @private
install_spool(Id, Source, Spool) ->
    case file:open(Spool, [read, raw, binary, read_ahead]) of
        {ok, Fd} ->
            try
                install_records(Id, Source, Fd, acc0())
            after
                ok = file:close(Fd)
            end;
        {error, enoent} ->
            {ok, acc0()};
        {error, Reason} ->
            {error, {install_spool, Reason}}
    end.

%% @private
delete_spool(Spool) ->
    case file:delete(Spool) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Reason} -> {error, {install_spool, Reason}}
    end.

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init(#{instance_id := InstanceId, wal_dir := WalDir} = Opts) ->
    process_flag(trap_exit, true),
    %% Off-heap inbox — the applier consumes batches from the WAL on
    %% one side and posts `install_local_batch` casts back to the
    %% instance on the other; either side may bunch under load. Off-
    %% heap messages keep the applier's own heap small.
    process_flag(message_queue_data, off_heap),
    CommitEvery = maps:get(commit_every, Opts, ?DEFAULT_COMMIT_EVERY),
    PollMs = maps:get(poll_interval_ms, Opts, ?DEFAULT_POLL_INTERVAL_MS),
    case validate_substrate_opts(Opts) of
        ok ->
            do_init(InstanceId, WalDir, CommitEvery, PollMs, Opts);
        {error, _} = Err ->
            {stop, Err}
    end.

do_init(InstanceId, WalDir, CommitEvery, PollMs, Opts) ->
    AeTargets = bondy_oplog_core_registry:instance_ae_targets(
        InstanceId, maps:get(ae_targets, Opts, [])
    ),
    PublishNs = maps:get(publish_ns, Opts, undefined),
    PublishFun = maps:get(publish_fun, Opts, undefined),
    case resolve_cell_apply_ctx(Opts) of
        {ok, CellCtx} ->
            do_init_2(
                InstanceId,
                WalDir,
                CommitEvery,
                PollMs,
                Opts,
                AeTargets,
                PublishNs,
                PublishFun,
                CellCtx
            );
        {error, _} = Err ->
            {stop, Err}
    end.

do_init_2(
    InstanceId,
    WalDir,
    CommitEvery,
    PollMs,
    Opts,
    AeTargets,
    PublishNs,
    PublishFun,
    CellCtx
) ->
    ApplyBatchMax = maps:get(
        apply_batch_max_events, Opts, ?DEFAULT_APPLY_BATCH_MAX_EVENTS
    ),
    %% Before the gate read: see `bondy_oplog_instance:open_drain_gate/1`.
    ok = bondy_oplog_registry:set_applier_pid(InstanceId, self()),
    DrainGate =
        case
            maps:get(drain_gated, Opts, false) andalso
                not bondy_oplog_instance_keeper:drain_released(InstanceId)
        of
            true -> gated;
            false -> open
        end,
    BootReplay =
        case maps:get(log_boot_replay, Opts, false) of
            true -> armed;
            false -> disabled
        end,
    case resolve_siblings(InstanceId) of
        {ok, InstP, WalP, MST, _Watermark} ->
            CO = read_consumer_offset(WalDir),
            Stage = new_install_stage(WalDir),
            %% Choose the resume position from the backend's durability (a
            %% static capability), never from the MST's live state. A durable
            %% backend (the pack store) keeps the MST + projection across a
            %% restart, so resume from the WAL's committed consumer offset;
            %% any uncommitted tail re-applies idempotently via the MST's HLC
            %% dedup. A volatile backend (ets/map) loses the MST, so the
            %% committed offset would skip data the fresh MST lacks: replay
            %% from `beginning`. `bondy_mst:capabilities/1` is a pure read.
            StartPos =
                case maps:get(durable, bondy_mst:capabilities(MST), false) of
                    true -> start_pos_from_consumer_offset(CO);
                    false -> beginning
                end,
            case open_drain_reader(WalP, StartPos) of
                {ok, Iter} ->
                    {ValidatorMod, ValidatorState} =
                        bondy_oplog_instance:get_validator(InstP),
                    %% Snapshot the demand-based flow-control handle
                    %% published by the instance's `init/1`. `undefined`
                    %% means the entry hasn't caught up yet — the
                    %% applier treats that as "no cap" and falls back
                    %% to the previous unbounded behaviour until the
                    %% next drain pass picks the ref up.
                    InFlightRef =
                        bondy_oplog_registry:install_in_flight(InstanceId),
                    InFlightCap =
                        bondy_oplog_registry:max_install_in_flight(InstanceId),
                    Lifecycle =
                        bondy_oplog_registry:lifecycle(InstanceId),
                    {ReplayRoot, ReplayOwed} =
                        bondy_oplog_instance:replay_anchor(InstP),
                    State = #state{
                        instance_id = InstanceId,
                        instance_pid = InstP,
                        last_replayed_root = ReplayRoot,
                        owed = ReplayOwed,
                        wal_pid = WalP,
                        wal_dir = WalDir,
                        iter = Iter,
                        consumer_offset = CO,
                        uncommitted = 0,
                        commit_every = CommitEvery,
                        apply_batch_max_events = ApplyBatchMax,
                        poll_interval_ms = PollMs,
                        validator_module = ValidatorMod,
                        validator_state = ValidatorState,
                        ae_targets = AeTargets,
                        publish_ns = PublishNs,
                        publish_fun = PublishFun,
                        cell_apply_ctx = CellCtx,
                        cell_apply_source = build_cell_apply_source(
                            InstanceId, CellCtx, Opts
                        ),
                        install_in_flight = InFlightRef,
                        max_install_in_flight = InFlightCap,
                        lifecycle = Lifecycle,
                        drain_gate = DrainGate,
                        install_stage = Stage,
                        boot_replay = BootReplay,
                        drain_progress_at = erlang:monotonic_time(millisecond),
                        %% Seed the progress watermark from the resumed
                        %% offset: on restart, re-reading up to a position
                        %% we had already committed is NOT progress.
                        drain_max_pos = consumer_offset_pos(CO),
                        drain_stall_alarm_ms = application:get_env(
                            bondy_oplog, drain_stall_alarm_ms, 60000
                        )
                    },
                    ok = bondy_oplog_registry:set_tables_registered(
                        InstanceId, DrainGate =:= open
                    ),
                    %% A predecessor that crashed while stalled leaves its
                    %% alarm behind; this incarnation owns the id now
                    %% (re-raised by the detector if the stall persists).
                    alarm_handler:clear_alarm(
                        {bondy_oplog_drain_stalled, InstanceId}
                    ),
                    %% When the drain is gated (a collapsed per-shard instance
                    %% whose sibling tables have not all registered yet), defer
                    %% BOTH the WAL drain and the cold-replay catch-up until the
                    %% orchestrator calls `open_drain_gate/1`. The applier_pid is
                    %% published above regardless, so the release — and any
                    %% sibling `register_table/4` — can reach this process while
                    %% it waits.
                    case DrainGate of
                        open ->
                            start_folding();
                        gated ->
                            ok
                    end,
                    {ok, State};
                {error, Reason} ->
                    {stop, {reader_open_failed, Reason}}
            end;
        {error, _} = Err ->
            {stop, Err}
    end.

%% @private
%% Queues the boot replay, then the WAL drain. The replay folds the MST events
%% the frontier does not claim: peer events whose replay never ran, and own
%% events whose projection write a crash lost, which the drain over a durable
%% MST does not re-read: it resumes at the committed consumer offset. It runs
%% first because a drained write's dot would cover such an own event and the
%% kernel would then skip it (`write_after_lost_fold_keeps_the_add` in
%% `bondy_oplog_bootstrap_rederive_test`).
start_folding() ->
    ok = gen_server:cast(self(), replay_cell_events),
    self() ! drain,
    ok.

%% @private
%% Resolve `cell_apply_target` into a `cell_apply_ctx`
%% map of the projection adapter, handle, and fold module from the
%% shard's registry entry. `not_found` is a hard error so a typo'd
%% triple surfaces at startup instead of silently disabling the path.
resolve_cell_apply_ctx(
    #{cell_apply_target := {NS, Index, Shard} = Key} = Opts
) ->
    case bondy_oplog_core_registry:lookup(NS, Index, Shard) of
        {ok, Entry} ->
            FoldMod = bondy_oplog_core_registry:entry_fold_module(
                Entry
            ),
            CrdtMod = bondy_oplog_core_registry:entry_crdt_module(
                Entry
            ),
            CausalTier =
                bondy_oplog_core_registry:entry_causal_tier(Entry),
            {ok, #{
                shard_key => Key,
                %% The table's event namespace (`undefined` unless it opted in
                %% via `publish => true`). The replay path in
                %% `bondy_oplog_cell_apply:apply_cell_pairs/4` gates
                %% merge-event emission on it, and a multiplexing instance's
                %% LOCAL publish resolves it per bucket (`publish_batch_dir/2`).
                %% Read from the registry ENTRY (the restart-surviving source)
                %% so a restart-rebuilt ctx keeps emitting; falls back to the
                %% opts for a raw, non-`bondy_db` registration.
                publish_ns => entry_or_opt(
                    bondy_oplog_core_registry:entry_publish_ns(Entry),
                    publish_ns,
                    Opts,
                    undefined
                ),
                adapter =>
                    bondy_oplog_core_registry:entry_projection_adapter(
                        Entry
                    ),
                handle =>
                    bondy_oplog_core_registry:entry_projection_handle(
                        Entry
                    ),
                fold_module => FoldMod,
                crdt_module => CrdtMod,
                %% Per-table construction config for `CrdtMod`
                %% (`#{}` default) — the kernel's opts-aware
                %% `init/2` cold-start path (see
                %% `bondy_oplog_cell_kernel:init/2`).
                crdt_opts =>
                    bondy_oplog_core_registry:entry_crdt_opts(Entry),
                %% The CRDT's declared causal tier (default tier_0).
                %% Recorded here; the tier_2 context-stamp gates on
                %% `causal_tier := tier_2`.
                causal_tier => CausalTier,
                %% The cell projection kernel: `{crdt, Mod}` when a
                %% `crdt_module` is configured, else `{fold, Mod}`
                %% (the legacy path). Selected once, here.
                kernel =>
                    bondy_oplog_cell_kernel:from_modules(
                        FoldMod, CrdtMod
                    ),
                cache_adapter =>
                    bondy_oplog_core_registry:entry_cache_adapter(
                        Entry
                    ),
                cache_handle =>
                    bondy_oplog_core_registry:entry_cache_handle(Entry),
                high_water_ref =>
                    bondy_oplog_core_registry:entry_high_water_ref(
                        Entry
                    ),
                version_ref =>
                    bondy_oplog_core_registry:entry_version_ref(Entry),
                index_intents =>
                    bondy_oplog_projection_adapter:is_durable(
                        bondy_oplog_core_registry:entry_projection_adapter(
                            Entry
                        )
                    ),
                %% Read from the registry ENTRY so a restart-rebuilt ctx
                %% keeps indexing; `undefined` (a raw registration that
                %% did not stamp it) falls back to the opts. `[]` in the
                %% entry means "no indexes" and is authoritative.
                secondary_indexes =>
                    entry_or_opt(
                        bondy_oplog_core_registry:entry_secondary_indexes(
                            Entry
                        ),
                        secondary_indexes,
                        Opts,
                        []
                    ),
                %% The rebuild's primary-cell enumeration scope
                %% (`bondy_oplog_projection_adapter:cell_keys_scope()`),
                %% stamped by `bondy_db` from the topology. `undefined`
                %% for an instance started outside `bondy_db` — the
                %% rebuild then falls back to the MST walk.
                primary_cell_scope =>
                    bondy_oplog_core_registry:entry_primary_cell_scope(
                        Entry
                    ),
                %% Applier-private OldValue frame-cache (or
                %% `undefined` when disabled). Created here in the
                %% applier's init/1, so the ETS table is owned by
                %% the applier process and dies with it (the cache
                %% is rebuildable from the projection).
                oldstate_cache =>
                    bondy_oplog_cell_apply:oldstate_cache_new(
                        maps:get(oldstate_cache, Opts, false),
                        maps:get(
                            oldstate_cache_max,
                            Opts,
                            ?DEFAULT_OLDSTATE_CACHE_MAX
                        )
                    )
            }};
        not_found ->
            {error, {cell_apply_target_not_registered, Key}}
    end.

%% @private
%% Prefer a value carried on the registry entry (the durable source of truth);
%% fall back to the applier opts when the entry left it `undefined` (a raw,
%% non-`bondy_db` registration that did not stamp it).
entry_or_opt(undefined, OptKey, Opts, Default) ->
    maps:get(OptKey, Opts, Default);
entry_or_opt(EntryVal, _OptKey, _Opts, _Default) ->
    EntryVal.

%% @private
%% Build the cell-apply source at init. A `per_shard` (collapsed) instance,
%% flagged by a `cell_apply_bucket` in its opts, rebuilds its full per-bucket
%% directory from the durable registry (every primary entry whose
%% `instance_id` matches), so a `one_for_all` subtree restart restores routing
%% for every table on the shard, not just the founding one whose opts the
%% supervisor replays. A single-table (`per_table_shard`) instance keeps the
%% keyless `{single, CellCtx}` source.
build_cell_apply_source(InstanceId, CellCtx, Opts) ->
    case maps:get(cell_apply_bucket, Opts, undefined) of
        Bucket when is_binary(Bucket) ->
            rebuild_dir_source(InstanceId, CellCtx, Bucket, Opts);
        _ ->
            bondy_oplog_cell_apply:build_source(CellCtx, Opts)
    end.

%% @private
%% Seed the directory with the founding `(Bucket, CellCtx)` already resolved in
%% `init/1` (reusing it avoids a second `oldstate_cache` ETS), then resolve every
%% OTHER primary entry of the instance from the registry and add its bucket. A
%% sibling whose ctx cannot be resolved (mid-teardown) is skipped — the next
%% `register_table/4` or restart re-adds it.
rebuild_dir_source(InstanceId, CellCtx, FoundingBucket, Opts) ->
    Entries = bondy_oplog_core_registry:primary_entries_for_instance(
        InstanceId
    ),
    lists:foldl(
        fun(Entry, Acc) ->
            case bondy_oplog_core_registry:entry_cell_apply_bucket(Entry) of
                undefined ->
                    Acc;
                FoundingBucket ->
                    Acc;
                Bucket ->
                    Key = bondy_oplog_core_registry:entry_key(Entry),
                    case
                        resolve_cell_apply_ctx(Opts#{cell_apply_target => Key})
                    of
                        {ok, Ctx} ->
                            bondy_oplog_mux:put(Acc, Bucket, Ctx);
                        _ ->
                            Acc
                    end
            end
        end,
        bondy_oplog_mux:dir([{FoundingBucket, CellCtx}]),
        Entries
    ).

handle_call(
    {enqueue_remote, Event},
    From,
    #state{
        validator_module = Mod,
        validator_state = VS,
        instance_pid = InstP,
        instance_id = Id
    } = State
) ->
    %% Spawn-and-reply: free the applier mailbox immediately so the WAL
    %% drain (`handle_info(drain, _)`) and other `enqueue_remote` calls
    %% can interleave. The worker captures the read-only validator
    %% snapshot + the instance pid + the caller's `From` tag, performs
    %% the verify, forwards verified events to the instance for
    %% origin-ban / backpressure / watermark / install, and replies on
    %% behalf of the applier.
    {Pid, _Mon} = spawn_monitor(fun() ->
        Reply =
            case Mod:verify_event(Event, VS) of
                ok ->
                    forward_remote(InstP, Event);
                {error, Reason} = VerifyErr ->
                    ok = log_verify_failure(Id, Event, Reason),
                    VerifyErr
            end,
        gen_server:reply(From, Reply)
    end),
    Workers = State#state.verify_workers,
    {noreply, State#state{verify_workers = Workers#{Pid => From}}};
handle_call(
    {sweep_stable_cells, StableHlc, Opts},
    _From,
    #state{} = StateIn
) ->
    %% I1 (prepare-after-deliver) applies to the sweep as it does to the
    %% tier_2 PREPARE: the sweep judges "the state at StableHlc", so the
    %% projection must reflect every event delivered to this replica,
    %% including remote events whose replay cast is still in flight, before
    %% any cell is discarded or reduced (`ensure_remote_caught_up/1`). A
    %% FAILED catch-up does not abort the sweep: the fence stays armed for
    %% the next call, and a delivered event the sweep missed replays later
    %% onto whatever the sweep left, so both directions converge.
    #state{
        cell_apply_ctx = Ctx,
        cell_apply_source = Source,
        instance_id = Id,
        ctx_guard = Guard
    } = State = ensure_remote_caught_up(StateIn),
    %% The guard is read from the POST-catch-up state: catching up applies
    %% events, and an event stamps the guard.
    {Reply, Guard1} = bondy_oplog_cell_utils:sweep(
        Id, Guard, Ctx, Source, StableHlc, Opts
    ),
    {reply, Reply, State#state{ctx_guard = Guard1}};
handle_call(barrier, _From, StateIn) ->
    %% Queue-ordering alone settles every earlier cast; the I1 fence on
    %% top also covers a LOST best-effort replay cast (gen gap → replay
    %% now). One atomic read when nothing is pending.
    {reply, ok, ensure_remote_caught_up(StateIn)};
handle_call(
    cell_apply_target,
    _From,
    #state{cell_apply_ctx = #{shard_key := Key}} = State
) ->
    {reply, {ok, Key}, State};
handle_call({register_table, Bucket, Target, TableOpts}, _From, State) ->
    case resolve_cell_apply_ctx(TableOpts#{cell_apply_target => Target}) of
        {ok, Ctx} ->
            Source = bondy_oplog_mux:put(
                State#state.cell_apply_source, Bucket, Ctx
            ),
            AeTargets = lists:usort([Target | State#state.ae_targets]),
            %% Publish the unioned AE-freshness targets to the instance
            %% registry too: `bondy_oplog_sync_session:do_bump_ae_targets/2`
            %% reads them from there (not this state), so without this a
            %% sibling table's shard would never be freshened by the AE
            %% heartbeat / isolated bump and its reads would refuse as stale.
            ok = bondy_oplog_registry:set_ae_targets(
                State#state.instance_id, AeTargets
            ),
            %% The directory just gained a bucket, so a replay can now route
            %% this bucket's cells. Cheap when there is nothing to do: the
            %% cursor is already at the current root and the replay returns
            %% `no_change`.
            ok = gen_server:cast(self(), replay_cell_events),
            {reply, ok, State#state{
                cell_apply_source = Source, ae_targets = AeTargets
            }};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({unregister_table, Bucket}, _From, State) ->
    Source = bondy_oplog_mux:remove(
        State#state.cell_apply_source, Bucket
    ),
    {reply, ok, State#state{cell_apply_source = Source}};
handle_call(
    {begin_stage, Buckets, PeerFrontier},
    _From,
    #state{install_stage = Stage0} = State
) ->
    {Reply, Stage} = open_stage(Buckets, PeerFrontier, Stage0),
    {reply, Reply, State#state{install_stage = Stage}};
handle_call(
    {install_catalogue_batch, Token, Cells},
    _From,
    #state{install_stage = Stage} = State
) ->
    {reply, stage_cells(Token, Cells, Stage), State};
handle_call(replay_cell_events, _From, State) ->
    %% Synchronous variant of the `replay_cell_events` cast. Runs the
    %% same diff fold and replies `ok` once the projection has caught
    %% up. Callers that need read-your-peers-write semantics use this
    %% instead of the cast.
    {reply, ok, do_replay_cell_events(State)};
handle_call(last_replayed_root, _From, State) ->
    {reply, State#state.last_replayed_root, State};
handle_call(
    {abort_install, Token}, _From, #state{install_stage = Stage0} = State
) ->
    {Reply, Stage} = drop_stage(Token, Stage0),
    {reply, Reply, State#state{install_stage = Stage}};
handle_call(
    {rederive_projection, Token},
    _From,
    #state{
        instance_id = Id, cell_apply_source = Source, install_stage = Stage0
    } = State0
) ->
    case commit_stage(Token, Id, Source, Stage0) of
        {{error, install_superseded} = Superseded, _} ->
            {reply, Superseded, State0};
        {Installed, Stage} ->
            %% The install replaced cells wholesale, which the tier_2
            %% stamp-site high-water does not reflect; a regression straddling
            %% it is not one.
            {Replayed, State} = do_replay_cell_events_r(
                State0#state{
                    install_stage = Stage,
                    last_replayed_root = undefined,
                    ctx_guard = bondy_oplog_ctx_guard:new()
                }
            ),
            {reply, rederive_result(Installed, Replayed), State}
    end;
handle_call({rebuild_indexes, Key}, _From, State) ->
    #state{cell_apply_source = Source, instance_id = Id} = State,
    {reply, bondy_oplog_cell_utils:reindex_table(Id, Source, Key), State};
handle_call(await_drain, From, State) ->
    %% Cold-start rebuild barrier: queue the caller and ensure a drain runs.
    %% The waiter is replied `ok` once the drain reaches end-of-log (the
    %% `{ok, _}` branch of `handle_info(drain, _)`, via `reply_drain_waiters/1`),
    %% so a subsequent rebuild/freshen observes a fully-replayed MST.
    self() ! drain,
    {noreply, State#state{drain_waiters = [From | State#state.drain_waiters]}};
handle_call({reap_origins, Retired}, _From, State) ->
    %% Dead-origin VV reaping: drop the value-preserving causal-context
    %% entries of retired origins from every cell, and co-evict them from
    %% the stamp-site context-regression guard. Delegates to
    %% `bondy_oplog_cell_utils`, shared with the fused instance path.
    {Reply, Guard1} = bondy_oplog_cell_utils:reap(
        State#state.instance_id,
        State#state.ctx_guard,
        State#state.cell_apply_source,
        Retired
    ),
    {reply, Reply, State#state{ctx_guard = Guard1}};
handle_call(
    {cell_context, Bucket, Key},
    _From,
    #state{} = StateIn
) ->
    %% I1 (prepare-after-deliver): this read is a tier_2 op's PREPARE and
    %% must not be served from a projection lagging events already delivered
    %% to this replica, or the minted context under-approximates its causal
    %% past (lost causality, the fatal direction). The WAL drain writes the
    %% projection before the MST install, so local events are covered; remote
    %% events need this fence (`ensure_remote_caught_up/1`). Steady-state
    %% cost: one atomic read.
    #state{cell_apply_source = Source, cell_apply_ctx = Founding} =
        State = ensure_remote_caught_up(StateIn),
    %% Resolve the ctx for THIS cell's bucket from the multiplex directory,
    %% NOT the founding `cell_apply_ctx`. On a collapsed instance many tables
    %% share one applier, each with its own CRDT, so the kernel that decodes
    %% the cell's projection state MUST match the cell's own table. A
    %% `{single, Ctx}` source returns `Ctx` for any bucket; a registered table
    %% bucket resolves to its own ctx; a bucket with no registered table (the
    %% latency probe's reserved `$probe` bucket) falls back to the founding
    %% ctx, since any kernel is correct for a probe write.
    #{
        adapter := Adapter,
        handle := Handle,
        kernel := Kernel,
        crdt_module := CrdtMod
    } = CellCtx = resolve_cell_ctx(Source, Bucket, Founding),
    %% Single-applier-per-cell read of the cell's current context. The caller
    %% (`bondy_db:apply_with_context/4`) then appends with this context as
    %% `meta`. The read and the append are SEPARATE calls, not one locked
    %% critical section, so two concurrent same-origin writes to the same cell
    %% can read the same pre-write context and stamp it twice; the sequential
    %% `await/1` barrier gives read-your-writes for the serial case.
    %% Single-applier scope still gives a consistent snapshot for THIS read.
    State0 =
        case Adapter:get(Handle, Bucket, Key) of
            not_found ->
                bondy_oplog_cell_kernel:init(
                    Kernel, maps:get(crdt_opts, CellCtx, #{})
                );
            {ok, Frame} ->
                {_PrevHlc, StateBytes, _ValueBytes} =
                    bondy_oplog_cell_frame:decode_full(Frame),
                bondy_oplog_cell_kernel:decode_state(Kernel, StateBytes)
        end,
    Context =
        case
            CrdtMod =/= undefined andalso
                erlang:function_exported(CrdtMod, context_of, 1)
        of
            true -> CrdtMod:context_of(State0);
            false -> undefined
        end,
    {Reply, State1} = stamp_ctx_guard(State, Bucket, Key, Context),
    {reply, Reply, State1};
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

%% @private
%% The ctx for a cell's bucket: its own registered table ctx when the bucket is
%% in the multiplex directory, else the founding ctx (for unregistered buckets
%% such as the reserved latency-probe bucket).
resolve_cell_ctx(Source, Bucket, Founding) ->
    case bondy_oplog_mux:resolve(Source, Bucket) of
        undefined -> Founding;
        Ctx -> Ctx
    end.

handle_cast(
    {advance_replayed_root, NewRoot},
    #state{owed = false} = State
) ->
    {noreply, State#state{last_replayed_root = NewRoot}};
handle_cast({advance_replayed_root, _NewRoot}, State) ->
    {noreply, State#state{last_replayed_root = undefined}};
handle_cast({refresh_validator, Reason}, State) ->
    {noreply, do_refresh_validator(Reason, State)};
handle_cast(replay_cell_events, State) ->
    {noreply, do_replay_cell_events(State)};
handle_cast(drain_resume, #state{drain_deferred = false} = State) ->
    %% Already draining (or about to); the next `self() ! drain` will
    %% pick up the freed slot anyway. Drop the redundant signal.
    {noreply, State};
handle_cast(drain_resume, #state{drain_deferred = true} = State) ->
    %% Capacity has freed up; resume the drain loop immediately.
    self() ! drain,
    {noreply, State#state{drain_deferred = false}};
handle_cast(open_drain_gate, #state{drain_gate = open} = State) ->
    %% Already released (or never gated). Idempotent — releasing twice, or a
    %% release racing an instance restart, is a no-op.
    {noreply, State};
handle_cast(
    open_drain_gate,
    #state{drain_gate = gated} = State
) ->
    %% Every table sharing this instance has registered its bucket, so the WAL
    %% replays with a whole `cell_apply_source`. A release racing `init/1` may
    %% have had its `true` overwritten by that init's `false`.
    ok = bondy_oplog_registry:set_tables_registered(
        State#state.instance_id, true
    ),
    ok = start_folding(),
    {noreply, State#state{drain_gate = open}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(drain, #state{drain_gate = gated} = State) ->
    %% Boot drain gate engaged: the orchestrator has not yet released this
    %% per-shard instance's drain (sibling tables may still be registering
    %% their cell-apply buckets). Swallow drain ticks — including any stray
    %% `drain_resume`/`drain_backstop` re-sends — without draining or arming a
    %% backstop. `open_drain_gate/1` re-sends `drain` when it flips the gate.
    {noreply, State};
handle_info(drain, State0) ->
    %% A fresh drain supersedes any parked idle waiter — cancel it so
    %% waiter helpers don't accumulate across drains.
    State1 = boot_replay_start(cancel_idle_waiter(State0)),
    case drain_loop(State1) of
        {ok, State2} ->
            %% Reaching end-of-log is the boot WAL-replay completion signal.
            State2b = boot_replay_end(State2),
            %% Caught up. Park an async waiter on the WAL's durable position
            %% instead of re-sending `drain` at once (a busy spin: the
            %% next-to-read byte is already durable in `per_write` mode) or
            %% blocking the gen_server here (which would stall the
            %% `replay_cell_events` cast that cross-node sync depends on). The
            %% waiter fires the instant a new frame becomes durable.
            %% End-of-log is also what `await_drain/1` callers (the cold-start
            %% rebuild barrier) wait on, so reply to them before parking.
            {noreply, arm_idle_waiter(reply_drain_waiters(State2b))};
        {paused, State2} ->
            %% Hit the demand cap. Stay parked — the instance will
            %% send `drain_resume` once it processes a batch. The
            %% backstop timer is a defensive belt-and-braces in case
            %% the signal is ever lost (e.g. instance restart between
            %% increment and decrement); it costs ~one wake per
            %% second when fully gated and nothing when not.
            _ = erlang:send_after(1_000, self(), drain_backstop),
            {noreply, State2#state{drain_deferred = true}};
        {stop, Reason, State2} ->
            {stop, Reason, State2}
    end;
handle_info(
    {'DOWN', MRef, process, _Pid, _Reason},
    #state{idle_waiter = MRef} = State
) ->
    %% Our parked idle waiter finished: the WAL's durable position
    %% advanced past our read offset, the await timed out, or the WAL
    %% errored. In every case the right response is to re-drain (if
    %% nothing new is there we simply re-arm). Using the monitor `DOWN`
    %% as the wakeup keeps the helper a pure side-effect-free blocker
    %% (it sends no message of its own), so a crashed helper can never
    %% wedge the applier.
    self() ! drain,
    {noreply, State#state{idle_waiter = undefined}};
handle_info(drain_backstop, #state{drain_deferred = true} = State) ->
    %% Defensive re-arm in case `drain_resume` was missed. If the cap
    %% is still saturated, `drain_loop` returns `{paused, _}` again
    %% and another backstop is scheduled.
    self() ! drain,
    {noreply, State#state{drain_deferred = false}};
handle_info(drain_backstop, State) ->
    %% Backstop fired while we were already draining — ignore.
    {noreply, State};
handle_info(
    {'DOWN', _Ref, process, Pid, Reason},
    #state{verify_workers = Workers} = State
) when is_map_key(Pid, Workers) ->
    %% A worker that raised is reported by the runtime; its caller gets the
    %% reply from here, so the `infinity` call behind it never hangs.
    {From, Workers1} = maps:take(Pid, Workers),
    Reason =:= normal orelse
        gen_server:reply(From, {error, {verify_crashed, Reason}}),
    {noreply, State#state{verify_workers = Workers1}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{iter = Iter}) ->
    case Iter of
        undefined -> ok;
        _ -> bondy_log_reader:close(Iter)
    end,
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Looks up the three pids and the MST/watermark snapshot the applier
%% needs from the per-instance registry row. Returns a structured
%% error pointing at the first missing field so operators can diagnose
%% supervisor-start-order or registry-publish races.
resolve_siblings(InstanceId) ->
    InstancePid = bondy_oplog_registry:instance_pid(InstanceId),
    WalPid = bondy_oplog_registry:wal_pid(InstanceId),
    MST = bondy_oplog_registry:mst(InstanceId),
    Watermark = bondy_oplog_registry:watermark(InstanceId),
    case missing_sibling(InstancePid, WalPid, MST) of
        none ->
            {ok, InstancePid, WalPid, MST, Watermark};
        Field ->
            {missing_sibling, #{
                instance_id => InstanceId,
                missing => Field,
                instance_pid => InstancePid,
                wal_pid => WalPid,
                mst_present => MST =/= undefined
            }}
    end.

%% @private
missing_sibling(undefined, _, _) -> instance_pid;
missing_sibling(_, undefined, _) -> wal_pid;
missing_sibling(_, _, undefined) -> mst;
missing_sibling(_, _, _) -> none.

%% @private
%% Resume from `max(last_MST_key.hlc, watermark.hlc)`. The reader's `{hlc, T}`
%% start finds the first frame whose first event HLC is `>= T`, so the frame
%% that contained the resume HLC is re-read and its events re-applied; that is
%% safe because `bondy_mst:put` is content-addressable and verify+install are
%% idempotent. Falls back to `beginning` when both inputs are absent (fresh
%% instance with empty MST and no compaction history) or when the MST handle
%% is missing.
resume_position(MstLast, Watermark) ->
    case resume_hlc(MstLast, Watermark) of
        undefined -> beginning;
        HLC -> {key, HLC}
    end.

%% @private
%% `MstLast` is the MST's last `{Key, Value}` (or `undefined`) ALREADY READ in
%% the process that owns the store. The durable pack store's sealed-pack file
%% descriptors are raw and hence process-bound, so `bondy_mst:last/1` must run in
%% the INSTANCE process (`bondy_oplog_instance:mst_last/1`) — calling it on the
%% shared handle from the applier process crashes with `not_on_controlling_process`.
resume_hlc(MstLast, Watermark) ->
    MstHlc = mst_last_hlc(MstLast),
    WmHlc = watermark_hlc(Watermark),
    case {MstHlc, WmHlc} of
        {undefined, undefined} -> undefined;
        {undefined, H} -> H;
        {H, undefined} -> H;
        {A, B} when A >= B -> A;
        {_, B} -> B
    end.

%% @private
mst_last_hlc(undefined) ->
    undefined;
mst_last_hlc({Key, _Value}) ->
    bondy_oplog_event:key_hlc(Key).

%% @private
watermark_hlc(undefined) ->
    undefined;
watermark_hlc(Key) ->
    bondy_oplog_event:key_hlc(Key).

%% @private
%% Demand-based dispatch gate. Returns `true` while the in-flight
%% counter is below the cap (or the instance hasn't published a cap
%% yet, in which case the legacy unbounded behaviour applies).
install_dispatch_allowed(#state{
    install_in_flight = undefined
}) ->
    true;
install_dispatch_allowed(#state{
    max_install_in_flight = undefined
}) ->
    true;
install_dispatch_allowed(#state{
    install_in_flight = Ref,
    max_install_in_flight = Cap
}) ->
    atomics:get(Ref, 1) < Cap.

%% @private
%% Increment the in-flight counter just before dispatching a
%% `install_local_batch` cast to the instance. Idempotent for the
%% `undefined` fallback so callers don't have to branch.
reserve_install_slot(#state{install_in_flight = undefined}) ->
    ok;
reserve_install_slot(#state{install_in_flight = Ref}) ->
    _ = atomics:add(Ref, 1, 1),
    ok.

%% @private
%% Reads the on-disk `consumer.offset`. This is BOTH the seed for the
%% in-memory commit accumulator AND the source of the drain's resume
%% position (`start_pos_from_consumer_offset/1`) — the WAL owns the cursor
%% for its own consumer. A missing file yields the fresh sentinel
%% (`commit_count = 0`), which resumes from `beginning`.
read_consumer_offset(WalDir) ->
    case bondy_log_state:read_consumer_offset(WalDir) of
        {ok, CO} -> CO;
        {error, _} -> bondy_log_state:new_consumer_offset()
    end.

%% @private
%% The WAL-drain resume position, derived from the durable consumer offset
%% (the WAL-owned cursor), deliberately NOT from MST state. A consumer offset
%% that has never committed (`commit_count = 0`) resumes from `beginning`, the
%% earliest LIVE segment, which also tolerates a truncated prefix. A committed
%% offset resumes where the last durable commit left off; the uncommitted tail
%% (bounded by `commit_every`) re-applies idempotently via the MST's HLC dedup.
%% This keeps the drain independent of the MST root's durability schedule.
start_pos_from_consumer_offset(CO) ->
    case bondy_log_state:commit_count(CO) of
        0 ->
            beginning;
        _ ->
            {offset, bondy_log_state:committed_segment(CO),
                bondy_log_state:committed_frame_offset(CO)}
    end.

%% @private
%% The committed `{Segment, FrameOffset}` of a consumer offset, or
%% `undefined` when nothing was ever committed.
consumer_offset_pos(CO) ->
    case bondy_log_state:commit_count(CO) of
        0 ->
            undefined;
        _ ->
            {
                bondy_log_state:committed_segment(CO),
                bondy_log_state:committed_frame_offset(CO)
            }
    end.

%% @private
%% A commit persisted: it counts as progress only when it lands BEYOND the
%% highest position ever committed — a re-read of already-covered ground
%% (the failure shape of a mispositioned resume) commits equal-or-lower
%% positions and must not reset the stall clock. Progress clears a raised
%% alarm.
note_drain_progress(State) ->
    note_drain_progress(erlang:monotonic_time(millisecond), State).

note_drain_progress(Now, #state{consumer_offset = CO} = State) ->
    Pos = consumer_offset_pos(CO),
    Max = State#state.drain_max_pos,
    case Pos =/= undefined andalso (Max == undefined orelse Pos > Max) of
        true ->
            clear_drain_stall(State#state{
                drain_max_pos = Pos,
                drain_progress_at = Now
            });
        false ->
            State
    end.

%% @private
%% Caught up with the log (nothing to read): reset the stall clock — an
%% idle consumer is healthy regardless of how long it stays idle.
note_drain_idle(State) ->
    note_drain_idle(erlang:monotonic_time(millisecond), State).

note_drain_idle(Now, State) ->
    clear_drain_stall(State#state{drain_progress_at = Now}).

%% @private
check_drain_stall(State) ->
    check_drain_stall(erlang:monotonic_time(millisecond), State).

check_drain_stall(_Now, #state{drain_stall_alarm_ms = 0} = State) ->
    State;
check_drain_stall(_Now, #state{drain_stalled = true} = State) ->
    State;
check_drain_stall(Now, #state{drain_progress_at = At} = State) ->
    Stalled =
        is_integer(At) andalso Now - At > State#state.drain_stall_alarm_ms,
    case Stalled of
        false ->
            State;
        true ->
            Info = #{
                instance_id => State#state.instance_id,
                stalled_for_ms => Now - At,
                committed_position => State#state.drain_max_pos
            },
            Desc =
                <<
                    "WAL drain is processing frames without committing any "
                    "new position - the log consumer is stalled. Applied "
                    "state on this node is falling behind its own WAL even "
                    "if anti-entropy reports the node converged."
                >>,
            ?LOG_WARNING(Info#{description => Desc}),
            %% `Info` goes in `details`, NOT the description: its keys are this
            %% alarm's declared `detail_keys`. The 3-tuple is how an app
            %% outside `bondy_router` reaches those fields. See
            %% `bondy_alarm_handler:set_alarm/2`.
            alarm_handler:set_alarm(
                {
                    {bondy_oplog_drain_stalled, State#state.instance_id},
                    Desc,
                    #{details => Info}
                }
            ),
            State#state{drain_stalled = true}
    end.

%% @private
clear_drain_stall(#state{drain_stalled = true} = State) ->
    alarm_handler:clear_alarm(
        {bondy_oplog_drain_stalled, State#state.instance_id}
    ),
    State#state{drain_stalled = false};
clear_drain_stall(State) ->
    State.

-ifdef(TEST).
%% Build a minimal applier state carrying only what the stall detector
%% reads; every other field stays at its record default.
stall_test_state(Map) when is_map(Map) ->
    #state{
        instance_id = maps:get(instance_id, Map, <<"stall-test">>),
        consumer_offset = maps:get(consumer_offset, Map, undefined),
        drain_progress_at = maps:get(drain_progress_at, Map, 0),
        drain_max_pos = maps:get(drain_max_pos, Map, undefined),
        drain_stalled = maps:get(drain_stalled, Map, false),
        drain_stall_alarm_ms = maps:get(drain_stall_alarm_ms, Map, 60000)
    }.

%% The detector-owned fields of a state, for assertions.
stall_test_fields(#state{} = S) ->
    #{
        drain_progress_at => S#state.drain_progress_at,
        drain_max_pos => S#state.drain_max_pos,
        drain_stalled => S#state.drain_stalled
    }.
-endif.

%% @private
%% Open the drain reader at the resume position, falling back to the earliest
%% live segment when the committed segment has been compacted away beneath the
%% consumer. Truncation runs strictly behind the committed offset, so this
%% should not arise in practice, but `beginning` is always a safe floor and
%% avoids a fail-stop restart loop on a stale offset.
open_drain_reader(WalP, StartPos) ->
    case bondy_log_reader:open(WalP, StartPos, [{follow, false}]) of
        {error, {invalid_start, _}} when StartPos =/= beginning ->
            bondy_log_reader:open(WalP, beginning, [{follow, false}]);
        Result ->
            Result
    end.

%% @private
%% Drains the reader until it returns `end_of_log` or `{error, _}`. On every
%% batch it applies the events and bumps the in-memory consumer offset;
%% consumer.offset and `set_committed_segment` are persisted at `commit_every`
%% events or on `end_of_log`. Before each next-batch read the loop checks the
%% demand-based in-flight counter against `max_install_in_flight`; at the cap
%% it returns `{paused, State}`, `handle_info(drain, _)` marks
%% `drain_deferred = true`, and the instance's `drain_resume` cast rearms it.
drain_loop(#state{} = State0) ->
    case lifecycle_live(State0) of
        false ->
            {paused, State0};
        true ->
            case install_dispatch_allowed(State0) of
                false ->
                    {paused, State0};
                true ->
                    drain_loop_step(State0)
            end
    end.

%% @private
%% Bootstrap lifecycle gate. Returns `true` when the instance is `live` (the
%% applier may drain), `false` when the instance is still `pre_bootstrap` (the
%% applier must NOT touch the per-cell projection). Treats a missing handle as
%% `live`: the registry publish can race with the applier's `init/1` after a
%% one_for_all subtree restart, and the WAL is the durable buffer either way.
lifecycle_live(#state{lifecycle = undefined}) ->
    true;
lifecycle_live(#state{lifecycle = H}) ->
    bondy_oplog_bootstrap_lifecycle:is_live(H).

drain_loop_step(
    #state{iter = Iter, apply_batch_max_events = Max} = State0
) ->
    %% `collect_frames/2` reads frames until the event count reaches `Max`
    %% (`more`) or the reader drains (`eol`).
    case collect_frames(Iter, Max) of
        {frames, Batch, {NextSeg, NextOff}, NewIter, More} ->
            %% Actively processing frames: if no commit has advanced past
            %% the progress watermark for the stall window, raise the
            %% alarm — this is the shape of a drain grinding over old
            %% ground (or wedged downstream) while the node otherwise
            %% looks converged.
            StateS = check_drain_stall(State0),
            StateA = apply_batch(StateS, Batch),
            {LastHlc, Count} = batch_summary(Batch),
            State1 = boot_replay_accrue(
                bump_offset(
                    StateA#state{iter = NewIter},
                    NextSeg,
                    NextOff,
                    LastHlc,
                    Count
                ),
                Count
            ),
            case More of
                more ->
                    State2 = maybe_commit(State1),
                    drain_loop(State2);
                eol ->
                    {ok, commit_now(State1)}
            end;
        {empty, _Iter} ->
            %% Caught up — an idle log is never a stall.
            {ok, commit_now(note_drain_idle(State0))};
        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "bondy_oplog_applier reader returned an error; "
                    "stopping so the supervisor can restart the subtree "
                    "and recovery can reconcile the on-disk state",
                instance_id => State0#state.instance_id,
                reason => Reason
            }),
            {stop, {reader_error, Reason}, State0}
    end.

%% @private
%% Coalesce consecutive WAL frames into a single applier batch: read via the
%% reader's `next/1` until the accumulated event count reaches `Max` or the
%% reader signals `end_of_log`. `Max` is a soft cap: a frame is never split.
%% A reader error mid-collect discards the accumulated frames and surfaces the
%% error; their offset was never bumped, so they are re-read after the restart.
%% Returns `{frames, Batch, {Seg, Off}, NewIter, more | eol}`, `{empty, Iter}`
%% on `end_of_log` with nothing read, or `{error, Reason}`.
collect_frames(Iter, Max) ->
    collect_frames(Iter, Max, [], 0, undefined).

collect_frames(Iter0, Max, AccRev, N, LastPos) ->
    case bondy_log_reader:next(Iter0) of
        {ok, Batch, _Hlcs, NextPos, NewIter} ->
            N1 = N + length(Batch),
            AccRev1 = [Batch | AccRev],
            case N1 >= Max of
                true ->
                    {frames, lists:append(lists:reverse(AccRev1)), NextPos,
                        NewIter, more};
                false ->
                    collect_frames(NewIter, Max, AccRev1, N1, NextPos)
            end;
        end_of_log when AccRev == [] ->
            {empty, Iter0};
        end_of_log ->
            {frames, lists:append(lists:reverse(AccRev)), LastPos, Iter0, eol};
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
%% Re-verify each event's stored signature (defence-in-depth against WAL
%% tampering) and dispatch the survivors to the instance via a one-way
%% `gen_server:cast`; the instance installs them in the MST and evicts the
%% matching overlay rows in FIFO order. Events that fail verification are
%% dropped from the batch: their telemetry is emitted here and the instance
%% evicts their overlay rows (`evict_rejected` cast), releasing the rows' share
%% of the admission counters and answering their appenders. No retry.
apply_batch(
    #state{instance_id = Id, instance_pid = InstancePid} = State, Batch
) ->
    %% Per-stage timing. Five stages emit `duration_us` + `count`
    %% under `[bondy_oplog, applier, batch_<stage>]` so the bench
    %% harness can compute µs/event-spent-in-this-stage and isolate
    %% which sub-path dominates the per-shard throughput floor. The
    %% per-call overhead is ~500ns × 5 stages = ~2.5µs per batch,
    %% well under the <2% threshold for batches with ≥1 event of
    %% real work (pack-store puts are 100-1000µs each).
    BatchSize = length(Batch),
    VerifyT0 = erlang:monotonic_time(microsecond),
    {Verified, Rejected} = verify_batch(State, Batch, [], []),
    telemetry:execute(
        [bondy_oplog, applier, batch_verify],
        #{
            duration_us => erlang:monotonic_time(microsecond) - VerifyT0,
            count => BatchSize
        },
        #{instance_id => Id}
    ),
    RejectedCount = length(Rejected),
    case Rejected of
        [] ->
            ok;
        _ ->
            %% No `install_local_batch` cast will be issued for these
            %% events; the instance evicts their rows instead.
            gen_server:cast(
                InstancePid,
                {evict_rejected, [bondy_oplog_event:key(E) || E <- Rejected]}
            )
    end,
    VerifiedCount = length(Verified),
    State1 =
        case Verified of
            [] ->
                State;
            _ ->
                %% Order matters for `await_apply/1,2`'s contract: applier-side
                %% projection writes (cell_apply, publish) run BEFORE the
                %% `install_local_batch` cast is dispatched to the instance,
                %% whose handler is what signals `drain_waiters`. Enqueuing the
                %% cast last guarantees that, by the time a caller's
                %% `await_apply` sees the overlay empty, the projection adapter
                %% and `publish_fun` have observed the events. The pipeline
                %% still overlaps across batches.
                CellT0 = erlang:monotonic_time(microsecond),
                %% The WHOLE verified batch, not just its cell ops: the mux
                %% groups on `event_bucket/1` (which skips non-cell ops) but
                %% claims the frontier over every seq-bearing event, and a
                %% `seq_fill` backfill is seq-bearing.
                ok = bondy_oplog_cell_apply:apply_cell_batch_mux(
                    State#state.cell_apply_source,
                    State#state.instance_id,
                    Verified
                ),
                telemetry:execute(
                    [bondy_oplog, applier, batch_cell_apply],
                    #{
                        duration_us => erlang:monotonic_time(microsecond) -
                            CellT0,
                        count => cell_op_count(Verified)
                    },
                    #{instance_id => Id}
                ),

                PublishT0 = erlang:monotonic_time(microsecond),
                ok = publish_batch(State, Verified),
                telemetry:execute(
                    [bondy_oplog, applier, batch_publish],
                    #{
                        duration_us => erlang:monotonic_time(microsecond) -
                            PublishT0,
                        count => VerifiedCount
                    },
                    #{instance_id => Id}
                ),

                %% Demand-based dispatch: bump the shared atomic
                %% BEFORE casting. The instance decrements after it
                %% handles the cast, and `drain_loop/1` checks this
                %% counter on its next iteration. The cap is checked
                %% by the loop, not here — `apply_batch/2` always
                %% dispatches the batch it just verified, because
                %% the verification already happened. The next
                %% iteration's check is what gates further reads.
                InstallT0 = erlang:monotonic_time(microsecond),
                ok = reserve_install_slot(State),
                gen_server:cast(
                    InstancePid,
                    {install_local_batch, Verified}
                ),
                telemetry:execute(
                    [bondy_oplog, applier, batch_install_cast],
                    #{
                        duration_us => erlang:monotonic_time(microsecond) -
                            InstallT0,
                        count => VerifiedCount
                    },
                    #{instance_id => Id}
                ),
                State
        end,
    %% One telemetry event per applier batch, regardless of which
    %% sub-path the events take (cell_apply, publish). This is
    %% the single source of truth for "events the applier has fully
    %% processed end-to-end" — the path-specific
    %% `[bondy_oplog, applier, published]` event only fires for the
    %% `publish_fun`/db_core mirror path.
    telemetry:execute(
        [bondy_oplog, applier, applied],
        #{count => VerifiedCount, rejected => RejectedCount},
        #{instance_id => Id}
    ),
    State1.

%% @private
cell_op_count(Events) ->
    length([
        E
     || E <- Events, {cell_apply, _, _, _} <- [bondy_oplog_event:op(E)]
    ]).

%% @private
%% tier_2 stamp-site context-regression guard — delegates to the
%% shared `bondy_oplog_ctx_guard`, so the applier and a fused instance
%% (which has no separate applier process to hold this state) enforce the
%% identical check from one place. tier_0/tier_1 carry no context
%% (`undefined`) and bypass it. See `bondy_oplog_crdt_mv_register` /
%% `bondy_oplog_crdt_aw_map` "Convergence preconditions".
stamp_ctx_guard(
    #state{instance_id = Id, ctx_guard = Guard} = State, Bucket, Key, Context
) ->
    {Reply, Guard1} = bondy_oplog_ctx_guard:stamp(
        Id, Guard, Bucket, Key, Context
    ),
    {Reply, State#state{ctx_guard = Guard1}}.

%% @private
%% Re-applies the cell events that landed in the MST since the last replay.
%% Called from the instance after a sync session merges peer events; without
%% it remote events sit in the MST but never reach the projection. The walk is
%% incremental: the MST diff prunes subtrees whose root hash is shared between
%% the current MST and the last replayed root, so the cost is O(events since
%% last sync). A cold start (no last replayed root) does one full fold.

do_replay_cell_events(State0) ->
    {_, State} = do_replay_cell_events_r(State0),
    State.

%% @private
%% THE PREPARE FENCE: the enforcement point of invariant I1 (moduledoc,
%% "Causal-stability invariants"). `integrate_peer_root` advances the MST and
%% casts `replay_cell_events` from a different sender than a client's
%% `cell_context` call, so without the fence a context read could lag the
%% replica's delivered set. One shared atomics generation, bumped by the
%% instance per `integrate_peer_root`, is compared against the generation last
%% replayed to; on a gap the catch-up runs and advances it only on success.
ensure_remote_caught_up(State0) ->
    State = resolve_remote_gen_ref(State0),
    case State#state.remote_gen_ref of
        undefined ->
            %% Not yet published by the instance's `init/1` — before
            %% which no `integrate_peer_root` can have run, so there is
            %% nothing to catch up to.
            State;
        Ref ->
            Gen = atomics:get(Ref, 1),
            case Gen > State#state.replayed_remote_gen of
                true ->
                    case do_replay_cell_events_r(State) of
                        {ok, State1} ->
                            State1#state{replayed_remote_gen = Gen};
                        {{error, _}, State1} ->
                            State1
                    end;
                false ->
                    State
            end
    end.

%% @private
resolve_remote_gen_ref(#state{remote_gen_ref = undefined} = State) ->
    State#state{
        remote_gen_ref = bondy_oplog_registry:remote_gen(
            State#state.instance_id
        )
    };
resolve_remote_gen_ref(State) ->
    State.

%% @private
%% As `do_replay_cell_events/1` but reporting whether the projection is
%% now provably caught up (`{ok, _}`) or the replay could not run
%% (`{error, _}` — instance unavailable). The prepare fence needs the
%% distinction: it must only advance its recorded generation on `ok`,
%% or a failed replay would silently unfence subsequent context reads.
do_replay_cell_events_r(
    #state{instance_pid = InstP, last_replayed_root = LastRoot} = State0
) ->
    case replay_diff(State0) of
        {ok, State} when LastRoot =:= undefined ->
            {bondy_oplog_instance:refolded(InstP), State};
        Result ->
            Result
    end.

%% @private
replay_diff(
    #state{
        cell_apply_source = Source,
        instance_id = Id,
        instance_pid = InstP,
        last_replayed_root = LastRoot
    } = State
) ->
    %% Delegate the MST fold to the instance process — it owns the pack-store
    %% file descriptors, which are raw and process-bound. Folding the MST in
    %% the applier process would read a sealed pack off the instance's fd and
    %% crash with `not_on_controlling_process`. The applier only applies the
    %% returned pairs to its projection (see `bondy_oplog_instance:replay_pairs/2`).
    try bondy_oplog_instance:replay_pairs(InstP, LastRoot) of
        {ok, no_change} ->
            telemetry:execute(
                [bondy_oplog, applier, replay_cell_events],
                #{cells_applied => 0, pairs => 0},
                #{
                    instance_id => Id,
                    outcome => no_change,
                    incremental => LastRoot =/= undefined
                }
            ),
            {ok, State};
        {ok, {CurrentRoot, Pairs}} ->
            {Count, Held} = bondy_oplog_cell_apply:apply_cell_pairs_mux(
                Source,
                Id,
                Pairs,
                bondy_oplog_registry:origin(Id),
                #{hold => true}
            ),
            ?LOG_DEBUG(#{
                description => "replay_cell_events done",
                instance_id => Id,
                cells_applied => Count,
                events_held => Held,
                incremental => LastRoot =/= undefined
            }),
            telemetry:execute(
                [bondy_oplog, applier, replay_cell_events],
                #{cells_applied => Count, pairs => length(Pairs)},
                #{
                    instance_id => Id,
                    outcome => applied,
                    incremental => LastRoot =/= undefined
                }
            ),
            %% Causal hold: a diff with held events keeps the cursor
            %% and sets `owed`, so a later diff, or a full fold once
            %% compaction drops the cursor, presents them again.
            case Held of
                0 ->
                    {ok, State#state{
                        last_replayed_root = CurrentRoot, owed = false
                    }};
                _ ->
                    {ok, State#state{owed = true}}
            end
    catch
        exit:Reason ->
            %% Instance unavailable (e.g. mid-restart) — leave the replay root
            %% unchanged; the next replay trigger retries.
            {{error, Reason}, State}
    end.

%% @private
%% Returns the `[{Key, Value}]` list to re-apply. A page of `LastRoot` lost
%% to GC since the previous replay reads as empty (`bondy_mst:diff_to_list/2`),
%% which only widens the diff: the applier never silently misses events.
diff_pairs(MST, undefined) ->
    bondy_mst:to_list(MST);
diff_pairs(MST, LastRoot) ->
    bondy_mst:diff_to_list(MST, LastRoot).

%% @private
%% A peer snapshot bundles cells from EVERY table on the shard, each tagged with
%% its entity-type `Bucket`; each group installs through its own table's ctx, so
%% a multiplexed per-shard instance routes each table's cells to its own
%% projection, not the founding table's.
group_cells(Cells) ->
    bondy_oplog_mux:group_by(
        Cells, fun({Bucket, _Key, _Frame}) -> {ok, Bucket} end
    ).

%% @private
%% `last` holds, per bucket, the greatest key the stream has reached, above
%% which `prune/4` next deletes.
acc0() ->
    #{
        installed => 0,
        pruned => 0,
        skipped => 0,
        unclaimable => [],
        max_hlc => 0,
        last => #{},
        idx => #{}
    }.

%% @private
install_groups(_Id, _Source, [], Acc) ->
    {ok, Acc};
install_groups(Id, Source, [{Bucket, Cells} | Rest], Acc0) ->
    case bondy_oplog_mux:resolve(Source, Bucket) of
        undefined ->
            %% No table registered for this bucket on the instance
            %% (a snapshot cell for a table not open here): skip it
            %% rather than misroute it to the founding projection.
            Acc = bump_n(skipped, length(Cells), unclaimable(Bucket, Acc0)),
            install_groups(Id, Source, Rest, Acc);
        Ctx ->
            maybe
                {ok, Acc} ?=
                    install_catalogue_group(Id, Ctx, Bucket, Cells, Acc0),
                install_groups(Id, Source, Rest, Acc)
            end
    end.

%% @private
install_records(Id, Source, Fd, Acc0) ->
    case file:read(Fd, 4) of
        eof ->
            {ok, Acc0};
        {ok, <<Size:32>>} ->
            maybe
                {ok, <<Bin:Size/binary>>} ?= file:read(Fd, Size),
                {ok, Acc} ?=
                    install_groups(
                        Id, Source, group_cells(binary_to_term(Bin)), Acc0
                    ),
                install_records(Id, Source, Fd, Acc)
            else
                {error, _} = Error -> Error;
                Short -> {error, {install_spool, {truncated, Short}}}
            end;
        {error, Reason} ->
            {error, {install_spool, Reason}};
        Short ->
            {error, {install_spool, {truncated, Short}}}
    end.

%% @private
rederive_result({ok, _} = Installed, ok) ->
    Installed;
rederive_result({ok, _}, Replayed) ->
    Replayed;
rederive_result({error, _} = Error, _Replayed) ->
    Error.

%% @private
%% Install one bucket's cells through its table's ctx, accumulating into the
%% shared counts, then settle their index ops, clear that ctx's old-state cache
%% and notify reactors. All three run after a failed write too: the cells
%% before it were replaced.
install_catalogue_group(Id, Ctx, Bucket, Cells, Acc0) ->
    maybe
        ok ?= bondy_oplog_cell_apply:begin_install(Ctx),
        {Acc1, Status} = install_cells(Id, Ctx, Cells, Acc0),
        settle_group(Ctx, Bucket, Acc0, Acc1, Status)
    end.

%% @private
settle_group(Ctx, Bucket, Acc0, #{idx := IdxAcc} = Acc, Status) ->
    Settled = bondy_oplog_cell_apply:settle_install(Ctx, IdxAcc, Status),
    Acc1 = Acc#{idx := #{}},
    %% The install path (`install_cell/6`) writes the projection WITHOUT
    %% write-through: it installs a frame directly, with no fold result to
    %% cache. A catalogue bootstrap can run on a LIVE instance, so an
    %% installed key may already be warm in the OldValue cache with its
    %% pre-install frame, and a stale hit would fold the next live event
    %% against the wrong OldState. Clearing this table's cache here closes
    %% that; the single-threaded applier completes the clear before any
    %% later drain reads, and the cache is rebuildable from the projection.
    bondy_oplog_cell_apply:oldstate_cache_clear(
        maps:get(oldstate_cache, Ctx, undefined)
    ),
    %% Honour the table's `publish => true` declaration on THIS write path
    %% too: `install_cell/6` writes frames directly and emits no per-cell
    %% merge event, so without this a table whose reactor DERIVES state from
    %% the projection is never told its projection exists. One event per
    %% bucket per batch, not one per cell: a snapshot install is a wholesale
    %% replace, and N merges would hand reactors an `Old` of `undefined` for
    %% every key, which a differ would read as "everything changed". Only when
    %% this batch actually installed something.
    ok = maybe_publish_bootstrap(Ctx, Bucket, Acc0, Acc1),
    case Settled of
        ok -> {ok, Acc1};
        {error, _} = Error -> Error
    end.

%% @private
install_cells(_Id, _Ctx, [], Acc) ->
    {Acc, ok};
install_cells(Id, Ctx, [Cell | Rest], Acc0) ->
    case install_one_cell(Id, Ctx, Cell, Acc0) of
        {ok, Acc} -> install_cells(Id, Ctx, Rest, Acc);
        {error, _} = Error -> {Acc0, Error}
    end.

%% @private
%% Fires the bootstrap notification when `Acc1` installed more cells than
%% `Acc0` had. Idempotent for subscribers by contract — a streamed snapshot
%% arrives in many batches, so a table may be notified several times per
%% bootstrap and every handler must tolerate that.
maybe_publish_bootstrap(Ctx, Bucket, Acc0, Acc1) ->
    case bootstrap_publish_decision(Ctx, Acc0, Acc1) of
        {publish, NS} -> bondy_oplog_core:publish_bootstrap(NS, Bucket);
        skip -> ok
    end.

-doc """
Whether an install group should announce itself, and under which namespace.

Split out from the side-effect so the two conditions can be unit-tested
without an applier, a projection or a dispatcher — the same reason
`bondy_aae_reactor:apply_reaction/4` is exposed.

`skip` when the table did not opt in (`publish => true` unset, so no
`publish_ns`), or when this group neither installed nor pruned a cell: a batch
none of whose cells decoded changed no projection and leaves subscribers
nothing to rebuild from.
""".
-spec bootstrap_publish_decision(
    Ctx :: map(), Acc0 :: map(), Acc1 :: map()
) -> {publish, atom()} | skip.

bootstrap_publish_decision(Ctx, Acc0, Acc1) ->
    case maps:get(publish_ns, Ctx, undefined) of
        undefined ->
            skip;
        NS ->
            case changed(Acc1) > changed(Acc0) of
                true -> {publish, NS};
                false -> skip
            end
    end.

%% @private
changed(Acc) ->
    maps:get(installed, Acc, 0) + maps:get(pruned, Acc, 0).

%% @private
install_one_cell(Id, Ctx, {Bucket, Key, Frame}, Acc0) ->
    maybe
        {ok, Acc} ?= prune(Id, Ctx, Bucket, Key, Acc0),
        install_decoded(Id, Ctx, {Bucket, Key, Frame}, Acc)
    end.

%% @private
install_decoded(Id, Ctx, {Bucket, Key, Frame}, Acc) ->
    case decode_cell_hlc(Id, Bucket, Key, Frame) of
        {ok, Hlc} ->
            maybe
                {ok, Ops} ?= install_cell(Id, Ctx, Bucket, Key, Frame, Hlc),
                %% The instance absorbs the batch maximum into its clock at
                %% finalize, or it could mint below a stability point computed
                %% from these cells (BONDY_DB_RECLAMATION_PROOF.md §7.1).
                {ok,
                    bump(
                        installed,
                        add_index_ops(Ops, Acc#{
                            max_hlc => max(maps:get(max_hlc, Acc, 0), Hlc)
                        })
                    )}
            end;
        error ->
            {ok, bump(skipped, unclaimable(Bucket, Acc))}
    end.

%% @private
decode_cell_hlc(Id, Bucket, Key, Frame) ->
    case bondy_oplog_cell_frame:hlc(Frame) of
        {ok, Hlc} ->
            {ok, Hlc};
        error ->
            ?LOG_WARNING(#{
                description =>
                    "catalogue install: cell skipped, its frame does not "
                    "decode",
                instance_id => Id,
                bucket => Bucket,
                cell_key => Key
            }),
            error
    end.

%% @private
%% Record that a cell of this bucket did not land for a reason no local
%% value covers. An ordset because a bucket group can contribute more than
%% once (one entry per undecodable cell) and the caller reports the set.
unclaimable(Bucket, Acc) ->
    maps:update_with(
        unclaimable, fun(S) -> ordsets:add_element(Bucket, S) end, Acc
    ).

%% @private
bump(Key, Acc) ->
    maps:update_with(Key, fun(X) -> X + 1 end, Acc).

%% @private
bump_n(Key, N, Acc) ->
    maps:update_with(Key, fun(X) -> X + N end, Acc).

%% @private
add_index_ops(Ops, #{idx := IdxAcc} = Acc) ->
    Acc#{idx := bondy_oplog_cell_apply:merge_idx_ops(IdxAcc, Ops)}.

%% @private
install_cell(Id, Ctx, Bucket, Key, Frame, Hlc) ->
    #{high_water_ref := HighWaterRef} = Ctx,
    {Intents, Ops} = bondy_oplog_cell_apply:install_index(
        Id, Ctx, Bucket, Key, Frame
    ),
    maybe
        ok ?=
            write_cell(Ctx, Bucket, Key, [{Bucket, Key, Frame} | Intents], []),
        bondy_oplog_cell_apply:advance_high_water(HighWaterRef, Hlc),
        {ok, Ops}
    end.

%% @private
%% Deletes the local cells of `Bucket` between the greatest key the stream has
%% reached and `High`, exclusive; the stream ships each bucket in ascending key
%% order (`bondy_oplog_catalogue_snapshot:next/2`).
prune(Id, Ctx, Bucket, High, #{last := Last} = Acc0) ->
    Low =
        case Last of
            #{Bucket := Key} -> <<Key/binary, 0>>;
            #{} -> <<>>
        end,
    maybe
        {ok, Acc} ?= prune_range(Id, Ctx, Bucket, Low, High, Acc0),
        {ok, reached(Bucket, High, Acc)}
    end.

%% @private
reached(_Bucket, infinity, Acc) ->
    Acc;
reached(Bucket, Key, #{last := Last} = Acc) ->
    case Last of
        #{Bucket := Reached} when Reached >= Key -> Acc;
        #{} -> Acc#{last => Last#{Bucket => Key}}
    end.

%% @private
prune_range(Id, Ctx, Bucket, Low, High, Acc0) ->
    #{adapter := Adapter, handle := Handle} = Ctx,
    case Adapter:range(Handle, Bucket, Low, High, #{limit => ?PRUNE_PAGE}) of
        {ok, []} ->
            {ok, Acc0};
        {ok, Rows} ->
            maybe
                {ok, Acc} ?= delete_cells(Id, Ctx, Bucket, Rows, Acc0),
                {Last, _} = lists:last(Rows),
                prune_range(
                    Id,
                    Ctx,
                    Bucket,
                    <<Last/binary, 0>>,
                    High,
                    bump_n(pruned, length(Rows), Acc)
                )
            end;
        {error, Reason} ->
            {error, {projection_read_failed, Reason}}
    end.

%% @private
delete_cells(_Id, _Ctx, _Bucket, [], Acc) ->
    {ok, Acc};
delete_cells(Id, Ctx, Bucket, [{Key, _Frame} | Rest], Acc0) ->
    maybe
        {ok, Acc} ?= delete_cell(Id, Ctx, Bucket, Key, Acc0),
        delete_cells(Id, Ctx, Bucket, Rest, Acc)
    end.

%% @private
%% The intent goes in the same write as the delete, so a crash keeps both or
%% neither.
delete_cell(Id, Ctx, Bucket, Key, Acc) ->
    {Intents, Ops} = bondy_oplog_cell_apply:install_index(
        Id, Ctx, Bucket, Key, none
    ),
    maybe
        ok ?= write_cell(Ctx, Bucket, Key, Intents, [{Bucket, Key}]),
        {ok, add_index_ops(Ops, Acc)}
    end.

%% @private
%% An install's one write for cell `{Bucket, Key}`, with its intent. A Bookie
%% that died exits the call; that ends the group as a failed write, which
%% `bondy_oplog_cell_apply:settle_install/3` answers by marking the indexes.
write_cell(Ctx, Bucket, Key, Puts, Deletes) ->
    #{
        adapter := Adapter,
        handle := Handle,
        cache_adapter := CacheAdapter,
        cache_handle := CacheHandle
    } = Ctx,
    Result =
        try
            bondy_oplog_projection_adapter:write_batch(
                Adapter, Handle, Puts, Deletes
            )
        catch
            exit:Exit -> {error, Exit}
        end,
    case Result of
        ok ->
            bondy_oplog_cell_apply:invalidate_cache(
                CacheAdapter, CacheHandle, Bucket, Key
            );
        {error, Reason} ->
            ?LOG_WARNING(#{
                description => "catalogue install: projection write failed",
                bucket => Bucket,
                cell_key => Key,
                reason => Reason
            }),
            {error, {projection_write_failed, Reason}}
    end.

%% @private
%% A bucket of the snapshot that routes here loses every local cell above the
%% last key shipped for it, all of them when none was.
prune_tails(_Id, _Source, [], Acc) ->
    {ok, Acc};
prune_tails(Id, Source, [Bucket | Rest], Acc0) ->
    case bondy_oplog_mux:resolve(Source, Bucket) of
        undefined ->
            prune_tails(Id, Source, Rest, Acc0);
        Ctx ->
            {Acc1, Status} =
                case prune(Id, Ctx, Bucket, infinity, Acc0) of
                    {ok, Acc} -> {Acc, ok};
                    {error, _} = Error -> {Acc0, Error}
                end,
            maybe
                {ok, Acc2} ?= settle_group(Ctx, Bucket, Acc0, Acc1, Status),
                prune_tails(Id, Source, Rest, Acc2)
            end
    end.

%% @private
%% Folds the batch in order, partitioning into verified events and
%% rejected ones. Verified order is preserved (the cast handler
%% relies on HLC-monotonic order within a batch).
verify_batch(_State, [], VAcc, RAcc) ->
    {lists:reverse(VAcc), lists:reverse(RAcc)};
verify_batch(#state{} = State, [Event | Rest], VAcc, RAcc) ->
    case verify_event(State, Event) of
        ok ->
            verify_batch(State, Rest, [Event | VAcc], RAcc);
        {error, Reason} ->
            ok = log_verify_failure(State#state.instance_id, Event, Reason),
            verify_batch(State, Rest, VAcc, [Event | RAcc])
    end.

%% @private
verify_event(#state{validator_module = Mod, validator_state = VS}, Event) ->
    Mod:verify_event(Event, VS).

%% @private
%% Refreshes the applier's snapshot of the validator state by calling
%% the optional `Mod:refresh/1` callback. The new snapshot is only
%% installed on `{ok, NewState}`; on any other return value (or on a
%% raise) the old snapshot is preserved so a misbehaving validator
%% cannot wedge the applier. In-flight `enqueue_remote` workers
%% captured the old snapshot before this cast was processed and
%% continue to use it — there is no mid-flight swap.
do_refresh_validator(
    Reason,
    #state{
        instance_id = Id,
        validator_module = Mod,
        validator_state = VS
    } = State
) ->
    NewVS = bondy_oplog_validator_refresh:refresh(Id, Reason, Mod, VS),
    State#state{validator_state = NewVS}.

%% @private
%% Forwards a verified remote event to the instance for install. The
%% instance still owns origin-ban / backpressure / watermark filtering
%% and the equivocation check, so its reply is what the caller sees.
%% A `noproc` race during subtree restart is surfaced as
%% `{error, instance_unavailable}` so the caller (a sync session) can
%% retry instead of treating the event as accepted.
forward_remote(InstancePid, Event) ->
    try gen_server:call(InstancePid, {install_remote, Event}, infinity) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> {error, instance_unavailable};
        exit:noproc -> {error, instance_unavailable};
        exit:{normal, _} -> {error, instance_unavailable};
        exit:{shutdown, _} -> {error, instance_unavailable}
    end.

%% @private
log_verify_failure(Id, Event, Reason) when is_binary(Id) ->
    Key = bondy_oplog_event:key(Event),
    ?LOG_WARNING(#{
        description =>
            "bondy_oplog_applier dropped an event whose stored "
            "signature does not verify; the event has been skipped "
            "to keep the subtree alive",
        instance_id => Id,
        key => Key,
        reason => Reason
    }),
    telemetry:execute(
        [bondy_oplog, applier, verify_failed],
        #{count => 1},
        #{instance_id => Id}
    ),
    ok.

%% @private
batch_summary(Batch) ->
    LastEvent = lists:last(Batch),
    LastHlc = bondy_oplog_event:key_hlc(
        bondy_oplog_event:key(LastEvent)
    ),
    {LastHlc, length(Batch)}.

%% @private
%% Boot WAL-replay logging (opt-in via `log_boot_replay`; see the `boot_replay`
%% state field). `boot_replay_start/1` logs once on the first drain after init
%% (ungated) or gate release (gated); `boot_replay_end/1` logs once the first
%% drain reaches end-of-log; `boot_replay_accrue/2` tallies the events replayed
%% in between. All three are no-ops once `done` (steady-state drains are silent)
%% and when logging was never armed.
boot_replay_start(#state{boot_replay = armed, instance_id = Id} = State) ->
    ?LOG_NOTICE(#{
        description => "bondy_db boot: replaying WAL",
        instance_id => Id
    }),
    State#state{boot_replay = {running, erlang:monotonic_time(microsecond), 0}};
boot_replay_start(State) ->
    State.

%% @private
boot_replay_accrue(#state{boot_replay = {running, T0, N}} = State, Count) ->
    State#state{boot_replay = {running, T0, N + Count}};
boot_replay_accrue(State, _Count) ->
    State.

%% @private
boot_replay_end(
    #state{boot_replay = {running, T0, N}, instance_id = Id} = State
) ->
    DurationMs = (erlang:monotonic_time(microsecond) - T0) div 1000,
    ?LOG_NOTICE(#{
        description => "bondy_db boot: WAL replay complete",
        instance_id => Id,
        events => N,
        duration_ms => DurationMs
    }),
    State#state{boot_replay = done};
boot_replay_end(State) ->
    State.

%% @private
bump_offset(
    #state{consumer_offset = CO0, uncommitted = U} = State,
    Seg,
    Off,
    LastHlc,
    Count
) ->
    CO1 = bondy_log_state:with_position(CO0, Seg, Off),
    CO2 = bondy_log_state:with_key(CO1, LastHlc),
    Old = bondy_log_state:commit_count(CO2),
    CO3 = bondy_log_state:with_commit_count(CO2, Old + 1),
    State#state{consumer_offset = CO3, uncommitted = U + Count}.

%% @private
maybe_commit(#state{uncommitted = U, commit_every = N} = State) when
    U >= N
->
    commit_now(State);
maybe_commit(State) ->
    State.

%% @private
commit_now(#state{uncommitted = 0} = State) ->
    State;
commit_now(
    #state{
        instance_id = InstanceId,
        instance_pid = InstancePid,
        wal_dir = Dir,
        wal_pid = WalPid,
        consumer_offset = CO
    } = State
) ->
    ok = drain_install_queue(InstancePid),
    case bondy_log_state:write_consumer_offset(Dir, CO) of
        ok ->
            Seg = bondy_log_state:committed_segment(CO),
            ok = notify_committed_segment(InstanceId, WalPid, Seg),
            note_drain_progress(State#state{uncommitted = 0});
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "bondy_oplog_applier could not persist consumer.offset; "
                    "retrying on the next commit boundary",
                instance_id => InstanceId,
                reason => Reason
            }),
            State
    end.

%% @private
%% Exits when the instance is gone or its root flush failed; either way the
%% `one_for_all` subtree is restarting and nothing may be committed.
drain_install_queue(InstancePid) ->
    gen_server:call(InstancePid, drain_install_queue, infinity).

%% @private
%% Tells the WAL writer to advance its committed-segment marker so the
%% retention sweep can drop fully-applied segments. A narrow `noproc`
%% catch covers the benign supervisor-shutdown race where the WAL has
%% already exited; any other error is logged so it doesn't get
%% swallowed silently.
notify_committed_segment(InstanceId, WalPid, Seg) ->
    try bondy_oplog_wal:set_committed_segment(WalPid, Seg) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "bondy_oplog_wal refused a set_committed_segment "
                    "request; retention sweep may lag until the next "
                    "commit boundary",
                instance_id => InstanceId,
                segment => Seg,
                reason => Reason
            }),
            ok
    catch
        exit:{noproc, _} -> ok;
        exit:noproc -> ok
    end.

%% @private
%% Park an async waiter on the WAL's durable position: a monitored helper
%% blocks in `bondy_oplog_wal:await_durable/3` until the durable position
%% passes the reader's offset or `?AWAIT_DURABLE_TIMEOUT_MS` elapses; its
%% `DOWN` wakes the applier. A helper rather than an inline call because
%% `await_durable/3` is a blocking `gen_server:call` that would make the
%% applier deaf to `replay_cell_events`. `{Seg, Off + 1}`, not `{Seg, Off}`:
%% the next-to-read byte is already durable when caught up, so it would spin.
arm_idle_waiter(#state{idle_waiter = Ref} = State) when is_reference(Ref) ->
    %% Already parked — don't spawn a second helper.
    State;
arm_idle_waiter(#state{iter = Iter, wal_pid = WalPid} = State) ->
    {Seg, Off} = bondy_log_reader:position(Iter),
    {_Pid, MRef} = spawn_monitor(fun() ->
        _ = bondy_oplog_wal:await_durable(
            WalPid, {Seg, Off + 1}, ?AWAIT_DURABLE_TIMEOUT_MS
        )
    end),
    State#state{idle_waiter = MRef}.

%% @private
%% Reply `ok` to every caller parked on `await_drain/1`. Called from the drain's
%% end-of-log branch, so a cold-start rebuild barrier unblocks the instant the
%% WAL is fully replayed.
reply_drain_waiters(#state{drain_waiters = []} = State) ->
    State;
reply_drain_waiters(#state{drain_waiters = Ws} = State) ->
    _ = [gen_server:reply(W, ok) || W <- Ws],
    State#state{drain_waiters = []}.

%% @private
%% Drop a parked idle waiter (if any). The orphaned helper is harmless:
%% it is blocked in `await_durable/3` and self-terminates within
%% `?AWAIT_DURABLE_TIMEOUT_MS`; `demonitor(_, [flush])` discards its
%% now-irrelevant `DOWN` so the next `handle_info({'DOWN', ...})` clause
%% won't match a stale reference.
cancel_idle_waiter(#state{idle_waiter = undefined} = State) ->
    State;
cancel_idle_waiter(#state{idle_waiter = MRef} = State) ->
    _ = erlang:demonitor(MRef, [flush]),
    State#state{idle_waiter = undefined}.

%% @private
%% Validate the substrate-wiring opts at init/1. Both hooks are opt-in;
%% the validation rejects partial configurations early so a typo in the
%% supervisor child-spec surfaces as a startup failure instead of a
%% silent no-op at the first publish call.
validate_substrate_opts(Opts) ->
    maybe
        ok ?= validate_ae_targets(maps:get(ae_targets, Opts, [])),
        ok ?= validate_publish_opts(Opts),
        ok ?= validate_cell_apply_target(Opts),
        ok ?= validate_apply_batch_max_events(Opts),
        validate_oldstate_cache_opts(Opts)
    else
        {error, _} = Error ->
            Error
    end.

%% @private
%% The coalescing threshold must be a positive integer (`1` = disabled).
validate_apply_batch_max_events(Opts) ->
    case
        maps:get(apply_batch_max_events, Opts, ?DEFAULT_APPLY_BATCH_MAX_EVENTS)
    of
        N when is_integer(N), N >= 1 ->
            ok;
        Bad ->
            {error, {invalid_opt, apply_batch_max_events, Bad}}
    end.

%% @private
%% `oldstate_cache` is a boolean flag (default false);
%% `oldstate_cache_max` is a positive integer entry cap.
validate_oldstate_cache_opts(Opts) ->
    case maps:get(oldstate_cache, Opts, false) of
        B when is_boolean(B) ->
            case
                maps:get(oldstate_cache_max, Opts, ?DEFAULT_OLDSTATE_CACHE_MAX)
            of
                M when is_integer(M), M >= 1 ->
                    ok;
                BadM ->
                    {error, {invalid_opt, oldstate_cache_max, BadM}}
            end;
        BadB ->
            {error, {invalid_opt, oldstate_cache, BadB}}
    end.

validate_cell_apply_target(Opts) ->
    case maps:get(cell_apply_target, Opts, undefined) of
        {NS, Index, Shard} when
            is_atom(NS),
            is_atom(Index),
            is_integer(Shard),
            Shard >= 0
        ->
            ok;
        Bad ->
            {error, {invalid_cell_apply_target, Bad}}
    end.

validate_ae_targets([]) ->
    ok;
validate_ae_targets([{NS, Index, Shard} | Rest]) when
    is_atom(NS),
    is_atom(Index),
    is_integer(Shard),
    Shard >= 0
->
    validate_ae_targets(Rest);
validate_ae_targets([Bad | _]) ->
    {error, {invalid_ae_target, Bad}};
validate_ae_targets(Bad) ->
    {error, {invalid_ae_targets, Bad}}.

validate_publish_opts(Opts) ->
    NS = maps:get(publish_ns, Opts, undefined),
    Fun = maps:get(publish_fun, Opts, undefined),
    case {NS, Fun} of
        {undefined, undefined} -> ok;
        {Atom, F} when is_atom(Atom), is_function(F, 1) -> ok;
        _ -> {error, {invalid_publish_opts, NS, Fun}}
    end.

%% @private
%% Walks `Verified` in HLC-monotonic order and publishes each event via
%% `bondy_oplog_core:publish/4`. A `publish_fun` returning `skip` suppresses
%% delivery; a raise is logged and treated as `skip` so a misbehaving
%% derivation cannot wedge the applier. A MULTIPLEXING (`per_shard`) instance
%% resolves the namespace PER EVENT from the bucket's own cell-apply ctx
%% (`publish_batch_dir/2`), since the instance-level `publish_ns` is the
%% founding table's (`bondy_db_publish_list_test`'s shared-instance cases).
publish_batch(#state{cell_apply_source = {dir, _}} = State, Verified) ->
    publish_batch_dir(State, Verified);
publish_batch(#state{publish_ns = undefined}, _Verified) ->
    ok;
publish_batch(#state{publish_fun = undefined}, _Verified) ->
    ok;
publish_batch(
    #state{
        instance_id = Id,
        publish_ns = NS,
        publish_fun = Fun
    },
    Verified
) ->
    {Count, Skipped} = lists:foldl(
        fun(Event, {C, S}) ->
            case derive_publish(Fun, Event) of
                skip ->
                    {C, S + 1};
                {Key, Op} ->
                    Hlc = bondy_oplog_event:key_hlc(
                        bondy_oplog_event:key(Event)
                    ),
                    ok = bondy_oplog_core:publish(NS, Key, Hlc, Op),
                    {C + 1, S}
            end
        end,
        {0, 0},
        Verified
    ),
    telemetry:execute(
        [bondy_oplog, applier, published],
        #{count => Count, skipped => Skipped},
        #{instance_id => Id, namespace => NS}
    ),
    ok.

%% @private
%% The multiplexing-instance publish path: each `cell_apply` event is
%% published under ITS bucket's registered namespace, taken from the
%% per-bucket ctx (`resolve_cell_apply_ctx/1` seats `publish_ns` there from
%% the registry entry, i.e. from the table's own `publish => true`). A
%% bucket whose table did not opt in — or is mid-teardown and absent from
%% the directory — is skipped, as is any non-`cell_apply` event (a dir-mode
%% instance applies nothing else on the local path).
publish_batch_dir(
    #state{instance_id = Id, cell_apply_source = Source}, Verified
) ->
    {Count, Skipped} = lists:foldl(
        fun(Event, {C, S}) ->
            case bondy_oplog_event:op(Event) of
                {cell_apply, Bucket, Key, FoldOp} ->
                    case bucket_publish_ns(Source, Bucket) of
                        undefined ->
                            {C, S + 1};
                        NS ->
                            Hlc = bondy_oplog_event:key_hlc(
                                bondy_oplog_event:key(Event)
                            ),
                            ok = bondy_oplog_core:publish(
                                NS, Key, Hlc, FoldOp
                            ),
                            {C + 1, S}
                    end;
                _ ->
                    {C, S + 1}
            end
        end,
        {0, 0},
        Verified
    ),
    telemetry:execute(
        [bondy_oplog, applier, published],
        #{count => Count, skipped => Skipped},
        #{instance_id => Id, namespace => shared}
    ),
    ok.

%% @private
bucket_publish_ns(Source, Bucket) ->
    case bondy_oplog_mux:resolve(Source, Bucket) of
        #{publish_ns := NS} -> NS;
        _ -> undefined
    end.

derive_publish(Fun, Event) ->
    case Fun(Event) of
        skip -> skip;
        {K, Op} -> {K, Op}
    end.
