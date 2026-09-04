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
  non-following `bondy_oplog_wal_reader` there. The WAL is just a byte
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
  WAL's committed-segment marker. This call returns once every
  in-flight install cast has been processed, so retention never
  drops a segment whose events the instance has not yet installed.
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
  (`merge_pages`, `integrate_peer_root`, `truncate_prefix`, `compact`,
  `load_snapshot`) are not event-stream operations and remain in the
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

For a *durable* MST backend the live MST holds the highest applied
event from the previous run; for a *volatile* (ETS) backend it is
empty after a subtree restart. In both cases the resume HLC is
`max(MST_last_key.hlc, snapshot_watermark.hlc)`, falling back to
`beginning` when both are unknown. `bondy_mst:put` is content-
addressable so the small overlap that `{hlc, _}` includes around the
resume frame is an idempotent no-op.

## Configuration

| Option              | Default | Meaning |
|---|---|---|
| `commit_every`      | `64`    | Apply this many events between `consumer.offset` flushes. |
| `poll_interval_ms`  | `5`     | Backstop sleep when `await_durable/3` returns sooner than expected. The hot path long-polls rather than sleeping; this only affects the rare error fallback. |
| `ae_targets`        | `[]`    | List of `{Namespace, Index, Shard}` tuples whose AE-freshness counters are bumped via `bondy_oplog_core_registry:bump_ae/4` after every successful commit. Empty list disables the wiring. |
| `publish_ns`        | `undefined` | Namespace under which post-apply events are published via `bondy_oplog_core:publish/4`. `undefined` disables publishing. Requires `publish_fun`. A multiplexing (`per_shard`) instance ignores both and resolves the namespace per event from the bucket's own ctx — see `publish_batch_dir/2`. |
| `publish_fun`       | `undefined` | `fun((bondy_oplog_event:t()) -> {Key, Op} \| skip)` invoked per verified event to derive the `(Key, Op)` pair forwarded to subscribers. `skip` suppresses publish for that event. Required when `publish_ns` is set. |

## Substrate read-side wiring

The applier optionally drives the read-side substrate. Both hooks are
opt-in and consumer-configured; defaults are no-ops so existing
instances are unaffected.

- **Freshness (`bump_ae`)** — after every successful commit
  (`commit_now/1` flushed `consumer.offset` and advanced the WAL
  committed-segment marker) the applier walks `ae_targets` and bumps
  each shard's AE atomic counter with a single shared
  `monotonic_time(millisecond)` so a batch of shards observes the same
  "now". Missing registry entries are tolerated and surfaced via a
  `not_found` counter in telemetry; they typically indicate a
  registration race during startup. The AE-side bump path for long-quiet
  shards is a separate concern handled outside this module.
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
    accumulator drained from `terminate/2`. The shutdown path already
    writes `consumer.offset` independently, so a partial drain failure
    would silently lose subscriber notifications without a way for
    crash recovery to recover them (the offset advanced).
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
""").

-record(state, {
    instance_id :: instance_id(),
    instance_pid :: pid(),
    wal_pid :: pid(),
    wal_dir :: file:filename_all(),
    iter :: bondy_oplog_wal_reader:t() | undefined,
    consumer_offset :: bondy_oplog_wal_state:consumer_offset(),
    %% Number of events applied since the last `commit/1`. Used to
    %% batch consumer.offset writes — flushed at `commit_every` or
    %% when the reader returns `end_of_log`.
    uncommitted :: non_neg_integer(),
    commit_every :: pos_integer(),
    %% A2 — coalesce consecutive WAL frames into one applier batch until
    %% at least this many events have accumulated (soft cap; a frame is
    %% never split). `1` = the pre-A2 one-frame-per-apply behaviour. See
    %% `?DEFAULT_APPLY_BATCH_MAX_EVENTS`.
    apply_batch_max_events :: pos_integer(),
    %% Milliseconds between polling ticks when the reader returns
    %% `end_of_log`. Constant for now; the writer publishes an atomics
    %% durable position so a future revision could long-poll instead.
    poll_interval_ms :: pos_integer(),
    %% Validator module + snapshot of validator state for signature
    %% re-verification (S1) in the applier process. Fetched once from
    %% the instance at `init/1`. `verify_event/2` is read-only on
    %% state (the only state mutation happens in `sign_event/2` which
    %% the instance owns), so the snapshot remains valid for the
    %% lifetime of the applier.
    validator_module :: module(),
    validator_state :: term(),
    %% Per-instance fold projection. Read once from the registry at
    %% `init/1`; `undefined` when no fold is configured for the
    %% instance, in which case the fold path is a strict no-op.
    %%
    %% Scope: single-cell-per-instance. The fold's event vocabulary is
    %% the `op` field of each WAL event (see `bondy_oplog_event:op/1`)
    %% by convention. Remote events bypass the WAL drain path and are
    %% NOT folded via this path — the `replay_cell_events` cast handles
    %% peer-authored events instead.
    fold_module :: module() | undefined,
    fold_state :: term(),
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
    %% matches `{cell_apply, Bucket, Key, FoldEvent}` bypass the
    %% per-instance fold and instead do a read-modify-write against the
    %% projection adapter registered for the configured
    %% `(NS, Index, Shard)` triple in `bondy_oplog_core_registry`. The
    %% cell's fold module (taken from the registry entry, which can
    %% differ from the per-instance `fold_module`) drives the
    %% decode/apply/encode cycle. `undefined` disables the path —
    %% existing instances are unaffected.
    cell_apply_ctx :: cell_apply_ctx() | undefined,
    %% Per-bucket apply-context source for the cell-apply mux. `{single, Ctx}`
    %% (one table per instance — today's default) routes every bucket to `Ctx`;
    %% `{dir, #{Bucket => Ctx}}` (a multiplexing per-shard instance) routes each
    %% bucket to its own table's ctx. Seeded at init from `cell_apply_bucket` and
    %% extended at runtime via `register_table/4` / `unregister_table/2`.
    %% `cell_apply_ctx` above stays the founding ctx for the guard clauses and
    %% the single-table read-side handle_calls.
    cell_apply_source = {single, undefined} :: ctx_source(),
    %% tier_2 stamp-site context-regression guard. Per locally stamped
    %% cell `{Bucket, Key}`, the highest causal context this applier has
    %% handed out on the tier_2 write path (`{cell_context, _, _}`). A
    %% correct substrate only ever advances a cell's context (the
    %% projection DVV grows monotonically), so a context that regressed
    %% between two successive local stamps of the same cell means durable
    %% state for that cell was lost or corrupted in process — the
    %% precondition that keeps a same-origin write from re-minting a used
    %% dot has been violated. The stamp refuses such a write
    %% (`{error, {context_regression, _, _}}`) and telemeters, turning a
    %% SILENT permanent fork into a loud, recoverable failure. Only the
    %% tier_2 stamp populates this (tier_0/tier_1 carry no context), so
    %% it is empty for every non-tier_2 instance. It is an in-process
    %% guard: it resets on restart (by design — the durable projection is
    %% the cross-restart reference, see `bondy_db_tier2_durability_test`)
    %% and is cleared on a catalogue install (the projection it tracks is
    %% replaced wholesale). See `bondy_oplog_ctx_guard` (shared with the
    %% fused instance path) for the coarse-clear bound.
    ctx_guard = bondy_oplog_ctx_guard:new() :: bondy_oplog_ctx_guard:guard(),
    %% Demand-based flow control toward the instance gen_server. The
    %% applier increments slot 1 of `install_in_flight` before each
    %% `gen_server:cast({install_local_batch, …})`; the instance
    %% decrements it after handling the cast. When the value would
    %% reach `max_install_in_flight`, the applier defers reading the
    %% next WAL batch and waits for the instance to send a
    %% `drain_resume` cast. Bounds the instance's mailbox; without
    %% it, sustained write throughput overruns the install path and
    %% builds an unbounded backlog (observable as an 8 GB+ RES set
    %% under stress, and ultimately a `gen_server:call` timeout on
    %% `drain_install_queue` during commit).
    %%
    %% NOTE (A2): the cap bounds the *number* of in-flight casts, not
    %% their size. Each `install_local_batch` cast now carries up to
    %% `apply_batch_max_events` events (the coalescing soft cap), so the
    %% worst-case instance-side backlog is
    %% `max_install_in_flight * apply_batch_max_events` events
    %% (default 16 * 256 = 4096). Raising BOTH knobs together multiplies
    %% the backlog — keep their product in mind to avoid reintroducing
    %% the OOM above.
    install_in_flight :: atomics:atomics_ref() | undefined,
    max_install_in_flight :: pos_integer() | undefined,
    %% Set when the applier deferred a drain because the cap was
    %% reached. The next `drain_resume` cast (or, defensively, the
    %% backstop poll timer) re-arms `self() ! drain`.
    drain_deferred = false :: boolean(),
    %% Drain-stall detection. `drain_max_pos` is the highest consumer
    %% position ever COMMITTED (`{Segment, FrameOffset}` — segment ids are
    %% never reused, so lexicographic order is total); only a commit BEYOND
    %% it counts as progress, so a drain that keeps re-reading old ground
    %% cannot masquerade as healthy. `drain_progress_at` is when progress
    %% (or a caught-up idle) was last observed; actively processing frames
    %% for longer than `drain_stall_alarm_ms` without it raises the
    %% `{bondy_oplog_drain_stalled, InstanceId}` alarm (cleared on the next
    %% progress). `0` disables the detector.
    drain_progress_at :: integer() | undefined,
    drain_max_pos :: {non_neg_integer(), non_neg_integer()} | undefined,
    drain_stalled = false :: boolean(),
    drain_stall_alarm_ms = 60000 :: non_neg_integer(),
    %% Root hash of the MST snapshot whose `cell_apply` events have
    %% already been folded into the projection. `do_replay_cell_events/1`
    %% diffs the live MST against this root via `bondy_mst:diff_to_list/2`
    %% and only re-applies the new entries — so the cost of a replay is
    %% O(events since last sync), not O(events in MST). `undefined`
    %% triggers a one-time full fold (cold start / restart, since the
    %% MST may hold peer-authored events whose `cell_apply` has never
    %% been replayed on this node). Advanced exclusively from
    %% `do_replay_cell_events/1` after the diff fold completes — *not*
    %% from `commit_now/1`, because a peer `integrate_peer_root` can
    %% interleave with the WAL drain and land remote pages under the
    %% post-barrier root, and those remote events have not been folded
    %% into the projection until the replay path runs. Advancing the
    %% watermark from `commit_now/1` regresses convergence (Jepsen
    %% OR-set: 27/226 lost adds).
    last_replayed_root = undefined :: undefined | bondy_mst:hash(),
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
    %% `drain_loop/1` is then a single `atomics:get/2`. `undefined`
    %% means the entry hasn't published one yet (race with the
    %% instance's `init/1`) and is treated as `live` for backward
    %% compatibility — the instance's publish is idempotent and will
    %% catch up by the next backstop tick.
    lifecycle :: bondy_oplog_bootstrap_lifecycle:handle() | undefined,
    %% Monitor reference of the parked idle-wait helper process (see
    %% `arm_idle_waiter/1`). `undefined` when the applier is actively
    %% draining or about to. The helper blocks on the WAL's
    %% `await_durable/3`; its monitor `DOWN` wakes the applier to
    %% re-drain. Event-driven replacement for the historical busy poll.
    idle_waiter = undefined :: undefined | reference(),
    %% Callers parked on `await_drain/1` (the cold-start rebuild barrier),
    %% replied `ok` the next time the WAL drain reaches end-of-log. Empty in
    %% steady state.
    drain_waiters = [] :: [gen_server:from()],
    %% Per-boot WAL-drain gate, distinct from the durable bootstrap
    %% `lifecycle`. A collapsed per-shard instance (`shared_shards`) is founded
    %% by the FIRST table opened on its shard, but its single WAL holds cells
    %% for EVERY table sharing the shard. If the applier drained at init —
    %% before the sibling tables register their cell-apply buckets — those
    %% siblings' cells would resolve to no ctx and be skipped (lost: the MST
    %% install is unconditional, so resume advances past them). `gated` defers
    %% the drain until the provisioning orchestrator (the catalogue) has
    %% registered every table on the shard and releases it via
    %% `open_drain_gate/1`. Unlike `lifecycle`, this gate is NOT durable: it
    %% re-engages on every boot, because the registration race recurs on every
    %% boot. Defaults to `open` so single-table (`per_table_shard`) instances
    %% and tests are byte-identical to the pre-gate path.
    drain_gate = open :: open | gated,
    %% Boot WAL-replay logging state machine (opt-in via `log_boot_replay`).
    %% Emits exactly ONE log when this instance's WAL replay begins and ONE
    %% when the first drain reaches end-of-log (boot catch-up complete) — a
    %% per-WAL boot progress marker, not a per-batch trace. `disabled` (the
    %% default) is a no-op; only the durable `main` shards opt in (set by the
    %% catalogue), so tests and ephemeral instances stay quiet.
    %%   disabled            — logging off.
    %%   armed               — opted in, replay not started.
    %%   {running, T0, N}    — replay started at `T0` (monotonic µs), `N`
    %%                         events applied so far.
    %%   done                — end-of-log logged; steady-state drains are silent.
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
-type ctx_source() :: bondy_oplog_cell_apply:ctx_source().
-type index_descriptor() :: bondy_oplog_cell_apply:index_descriptor().

-type opts() :: #{
    instance_id := instance_id(),
    wal_dir := file:filename_all(),
    commit_every => pos_integer(),
    %% A2 — coarser applier batching (soft event-count cap per applier
    %% batch). Default `?DEFAULT_APPLY_BATCH_MAX_EVENTS`. `1` disables the
    %% coalescing (pre-A2 behaviour).
    apply_batch_max_events => pos_integer(),
    %% A3 — OldValue frame-cache. When `true`, the applier keeps a
    %% private, write-through cache of the last durable cell frame per
    %% `{Bucket, Key}`, so `compute_one_cell/11`'s OldValue read can
    %% skip the projection `get/3` (the dominant per-event cost on the
    %% durable stack) on a hit. Default `false` (behaviour byte-identical
    %% to pre-A3). `oldstate_cache_max` bounds the entry count; when
    %% exceeded the cache is cleared (coarse evict — it is rebuildable
    %% from the projection, so a clear only costs re-warm misses).
    oldstate_cache => boolean(),
    oldstate_cache_max => pos_integer(),
    poll_interval_ms => pos_integer(),
    %% Substrate read-side wiring: shards bumped after each commit.
    ae_targets => [shard_key()],
    %% Substrate subscription wiring: namespace for post-apply publish.
    publish_ns => atom(),
    publish_fun => publish_fun(),
    %% Per-cell projection write wiring. Setting this requires the shard
    %% to be already registered in `bondy_oplog_core_registry`. Resolved
    %% eagerly at init/1.
    cell_apply_target => shard_key(),
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

%% Report returned by `reap_origins_sync/2` — see `bondy_oplog_cell_utils`
%% (shared with the fused instance path) for the field meanings.
-type reap_report() :: bondy_oplog_cell_utils:reap_report().

-export_type([reap_report/0]).

-export([start_link/1]).
-export([child_spec/1]).
-export([stop/1]).
-export([enqueue_remote/2]).
-export([refresh_validator/2]).
-export([projection/1]).
-export([notify_drain_resume/1]).
-export([replay_cell_events/1]).
-export([replay_cell_events_sync/1]).
-export([last_replayed_root/1]).
-export([advance_replayed_root/2]).
-export([rederive_projection_sync/1]).
-export([rebuild_indexes/1]).
-export([rebuild_indexes_sync/1]).
-export([await_drain/1]).
-export([reap_origins_sync/2]).
-export([barrier/1]).
-export([cell_apply_target/1]).
-export([sweep_stable_cells/2]).
-export([sweep_stable_cells/3]).
-export([install_catalogue_batch/2]).
-export([install_catalogue_cells/3]).
%% Exposed for unit testing the bootstrap-announcement conditions without an
%% applier, a projection or a dispatcher.
-export([bootstrap_publish_decision/3]).
-export([cell_context/3]).
%% State-free drain leaves reused verbatim by the ephemeral fused-writer
%% mode in `bondy_oplog_instance` (fused-writer rollout, Steps 3-4). Exposed
%% so the fused instance runs an identical drain + remote replay without
%% this gen_server. Exporting them does not change applier behaviour
%% (additive only): `diff_pairs/3` is the state-free MST-diff that
%% `do_replay_cell_events/1` already uses; the fused remote path
%% (`integrate_peer_root` inline replay) calls it directly.
-export([resolve_cell_apply_ctx/1]).
-export([build_cell_apply_source/3]).
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
-export([diff_pairs/3]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-define(DEFAULT_COMMIT_EVERY, 64).
%% A2 — coarser applier batching. The drain loop coalesces consecutive
%% WAL frames into a single applier batch until the accumulated event
%% count reaches this threshold (or the reader hits `end_of_log`), so the
%% two co-dominant per-batch storage costs — the pack-store spine rebuild
%% (`install_local_batch` → `bondy_mst:put_batch/2`) and the leveled
%% projection `put_batch` — amortise over many more events. It is a soft
%% cap: a frame is never split, so a batch may exceed it by at most the
%% last frame's size. Set to `1` to reproduce the pre-A2
%% one-frame-per-apply behaviour exactly. Engages only when a WAL backlog
%% already exists — when caught up only one frame is available before
%% `end_of_log`, so steady-state apply latency is unchanged.
-define(DEFAULT_APPLY_BATCH_MAX_EVENTS, 256).
%% A3 — default OldValue frame-cache entry cap. Bounds memory; when
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
Re-fold the entire MST through the cell_apply path. Intended to be
called by the instance after a `merge_pages` / `integrate_peer_root`
cycle — without this, peer-received events sit in the local MST but
never reach the per-cell projection, and `bondy_db:read/3` returns
only events authored on the local node.

Idempotent for the CRDT folds that ship with the library (LWW
register, OR-set, map_of_fields, ttl_presence): replaying an
absorbed event either no-ops (same dot already in OR-set live or
tombstones; same `{set, V, H}` already applied) or yields the same
terminal state (later-HLC LWW). `strict_register` rejects duplicates
with `{error, ...}` from `apply_event/3` but `apply_one_cell` already
catches and logs.

A no-op when the instance was started without a `cell_apply_target`
— pure-substrate consumers are not affected.
""".
replay_cell_events(ApplierPid) when is_pid(ApplierPid) ->
    gen_server:cast(ApplierPid, replay_cell_events).

-spec replay_cell_events_sync(pid()) -> ok.

-doc """
Synchronous variant of `replay_cell_events/1`. Blocks the caller
until the diff fold has been applied to the projection, so a read
issued immediately after this returns observes the peer-merged events
the corresponding sync session installed. Otherwise identical to the
cast (idempotent, no-op when `cell_apply_target` is not configured).
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
Advances `last_replayed_root` to `NewRoot` WITHOUT applying any pairs.

Called by the instance's compaction commit right after it truncates the
MST: the projection is current up to the truncation point (the instance
truncates nothing the applied VV does not witness), so the post-truncate
root is a fully-replayed root. Re-anchoring the cursor on it keeps the
next replay diff INCREMENTAL — the pre-truncate root's pages are freed by the
truncate, so without this the next `diff_to_list/2` raises and falls back
to a full `to_list/1` of the whole tree on every compaction cycle (an
O(N)-per-cycle synchronous fold that starves the applier under sustained
writes). Idempotent.
""".
advance_replayed_root(ApplierPid, NewRoot) when is_pid(ApplierPid) ->
    %% MUST be a cast, NOT a call. The instance issues this from inside its
    %% compaction commit handler, and the applier issues a synchronous
    %% `drain_install_queue` call back to the instance on every commit
    %% boundary (`commit_now/1`). A synchronous call here would let the two
    %% gen_servers wait on each other with `infinity` timeouts whenever a
    %% compaction overlaps a commit — a hard deadlock that freezes the whole
    %% pipeline under sustained writes (instance stops installing, applier
    %% stops applying, the MST stops being bounded). Re-anchoring is a
    %% non-critical perf hint (`replay_diff_pairs/2` safely falls back to a
    %% full `to_list/1` over the now-bounded tree if it is momentarily stale),
    %% so fire-and-forget is correct.
    gen_server:cast(ApplierPid, {advance_replayed_root, NewRoot}).

-spec rederive_projection_sync(pid()) -> ok.

-doc """
Re-derive the whole projection from the current MST by resetting the
replay watermark and re-folding every cell's event group
(`interpret_cog`). Unlike `replay_cell_events_sync/1` (a diff fold from
the last replayed root), this re-applies the COMPLETE local+peer event
set, so a cell whose materialised state was overwritten out-of-band — a
`replace`-mode catalogue install that clobbered a per-Origin-accumulating
CRDT (counter, grow-set) on a live re-bootstrap — is restored to the
converged value. The op-based replacement for the removed CvRDT `merge_states`. Idempotent
and a no-op when `cell_apply_target` is not configured.
""".
rederive_projection_sync(ApplierPid) when is_pid(ApplierPid) ->
    gen_server:call(ApplierPid, rederive_projection, infinity).

-spec rebuild_indexes(pid()) -> ok.

-doc """
Force a full secondary-index rebuild from this primary shard: re-derives
the index from each live cell's CURRENT projection value, re-dispatching a
`put` for every live term of every cell to the secondary writers. The
dispatch **bypasses the writer back-pressure cap** so the rebuild can load
the full working set in one pass even when the cap was exceeded. Combined
with the rebuild orchestrator first clearing the stale index shard, this
restores the index exactly. Unlike replaying the MST's events, reading the
converged value is correct for context-carrying (tier_2) CRDTs (see
`do_rebuild_indexes/1`). A no-op when the instance has no
`cell_apply_target`.
""".
rebuild_indexes(ApplierPid) when is_pid(ApplierPid) ->
    gen_server:cast(ApplierPid, rebuild_indexes).

-spec rebuild_indexes_sync(pid()) -> ok.

-doc "Synchronous variant of `rebuild_indexes/1` (the rebuild barrier).".
rebuild_indexes_sync(ApplierPid) when is_pid(ApplierPid) ->
    gen_server:call(ApplierPid, rebuild_indexes, infinity).

-spec await_drain(pid()) -> ok.

-doc """
Block until the applier has drained its WAL to end-of-log — the cold-start
rebuild barrier. Queues the caller and triggers a drain; replies `ok` the moment
the drain next reaches end-of-log, so a `rebuild_indexes_sync/1` (or a freshen on
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

- A **live re-bootstrap** re-folds the full MST onto the projection
  (`bondy_oplog_sync_session:finish_bootstrap/4` → `rederive_projection`)
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

-spec projection(pid()) ->
    {ok, term()} | {error, no_fold_configured}.

-doc """
Returns the current fold projection for the applier's instance.

`{error, no_fold_configured}` when the instance was started without a
`fold_module` opt (the legacy event-storage path is in effect).

The reply observes the freshest fold state visible to the applier
*after* the call is processed — synchronous `gen_server:call/2`
contract. Events appended after the call returns are not reflected.
Callers that need read-your-writes semantics across a recent append
should call `bondy_oplog:await_apply/1` first.
""".
projection(ApplierPid) when is_pid(ApplierPid) ->
    gen_server:call(ApplierPid, get_projection, infinity).

-spec cell_apply_target(pid()) -> {ok, shard_key()} | undefined.

-doc """
Returns the applier's resolved `cell_apply_target` shard key, or
`undefined` if no projection target was configured. Used by the
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
-spec sweep_stable_cells(pid(), bondy_oplog_hlc:hlc()) ->
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
    bondy_oplog_hlc:hlc(),
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

`{error, no_cell_apply_target}` if the applier wasn't configured with a
`cell_apply_target`.
""".
cell_context(ApplierPid, Bucket, Key) when is_pid(ApplierPid) ->
    gen_server:call(ApplierPid, {cell_context, Bucket, Key}, infinity).

-type install_mode() :: replace.

-spec install_catalogue_batch(
    pid(),
    [bondy_oplog_transport:cell()]
    | {install_mode(), [bondy_oplog_transport:cell()]}
) ->
    {ok, #{
        installed := non_neg_integer(),
        skipped := non_neg_integer(),
        merged := non_neg_integer(),
        replaced_no_merge := non_neg_integer()
    }}
    | {error, term()}.

-doc """
Installs a batch of catalogue-snapshot cells into the applier's
projection shard. Each cell is `{Bucket, Key, Frame}` where `Frame` is
a V2 cell frame as produced by the peer's projection adapter.

Only **`replace`** mode exists (CvRDT `merge_states` is not supported):
for each cell, if the existing local HLC is `>=` the incoming HLC the cell
is skipped (per-cell HLC guard against bootstrap-vs-live interleave);
otherwise the frame is written through unchanged. A snapshot bootstrap is
only run by a fresh (`pre_bootstrap`) replica with an empty local
projection, so skip-if-older is a no-op; a live replica converges via
op-based anti-entropy instead (`bondy_oplog_sync_session`), which is
lossless.

Invalidates the read cache and advances the per-shard high-water HLC
atomic after each successful write.

Returns `{ok, #{installed := N, skipped := M, merged := 0,
replaced_no_merge := 0}}` (the `merged`/`replaced_no_merge` keys are
retained for return-shape stability and are always `0`).

Returns `{error, no_cell_apply_target}` if the applier was not started
with a `cell_apply_target`.
""".
install_catalogue_batch(ApplierPid, Cells) when
    is_pid(ApplierPid), is_list(Cells)
->
    install_catalogue_batch(ApplierPid, {replace, Cells});
install_catalogue_batch(ApplierPid, {replace, Cells}) when
    is_pid(ApplierPid),
    is_list(Cells)
->
    gen_server:call(
        ApplierPid, {install_catalogue_batch, Cells}, infinity
    ).

-doc """
The catalogue-batch install body, shared with the FUSED instance (which
has no separate applier process and runs the install in its own
gen_server, passing its `#fused_drain{}` `cell_apply_source` as `Source`).
Applier-state-free by construction: everything the install needs rides in
`Source`'s per-table ctxs. Same semantics as the applier's own
`{install_catalogue_batch, _}` handler — replace-mode, bucket-demuxed,
per-cell HLC-guarded via the projection adapter's `head/3` fast path.
""".
-spec install_catalogue_cells(
    InstanceId :: instance_id(),
    Source :: term(),
    Cells :: [bondy_oplog_transport:cell()]
) -> {ok, map()}.

install_catalogue_cells(InstanceId, Source, Cells) when is_list(Cells) ->
    do_install_catalogue_batch(InstanceId, Source, Cells).

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
    AeTargets = maps:get(ae_targets, Opts, []),
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
    DrainGate =
        case maps:get(drain_gated, Opts, false) of
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
            %% Choose the resume position from the backend's DURABILITY (a
            %% static capability), never from the MST's live state:
            %%
            %%  - durable backend (the pack store): the MST + projection
            %%    survive a restart, so resume from the WAL's own committed
            %%    consumer offset. This is robust to a stale/absent MST root —
            %%    the failure that, under the old MST-derived resume, regressed
            %%    to `beginning` and re-read the whole WAL every drain (the
            %%    livelock). Any uncommitted tail is re-applied idempotently
            %%    via the MST's HLC dedup (at-least-once).
            %%  - volatile backend (ets/map): the MST does NOT survive a
            %%    restart, so the committed offset would skip past data the
            %%    fresh MST lacks — replay from `beginning` to rebuild it.
            %%
            %% Either way the WAL is just a byte log positioned by a cursor; it
            %% never depends on MST state. `bondy_mst:capabilities/1` reads the
            %% store record (pure), so it is safe off the instance process.
            StartPos =
                case maps:get(durable, bondy_mst:capabilities(MST), false) of
                    true -> start_pos_from_consumer_offset(CO);
                    false -> beginning
                end,
            case open_drain_reader(WalP, StartPos) of
                {ok, Iter} ->
                    {ValidatorMod, ValidatorState} =
                        bondy_oplog_instance:get_validator(InstP),
                    {FoldMod, FoldState0} = init_fold(InstanceId),
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
                    State = #state{
                        instance_id = InstanceId,
                        instance_pid = InstP,
                        %% Anchor the replay cursor to the MST root we are
                        %% starting from. On a durable instance the projection
                        %% already reflects this root (the applier writes the
                        %% projection BEFORE installing to the MST, so the
                        %% projection is >= the MST for local events), so the
                        %% boot cold-replay must NOT re-fold the whole tree —
                        %% that is redundant work (and, on a large table, a slow,
                        %% memory-heavy full fold). A later peer merge advances
                        %% the root and replays only the diff. `root/1` reads the
                        %% in-memory root, so it is safe off the instance process.
                        last_replayed_root = bondy_mst:root(MST),
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
                        fold_module = FoldMod,
                        fold_state = FoldState0,
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
                    ok = bondy_oplog_registry:set_applier_pid(
                        InstanceId, self()
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
                            self() ! drain,
                            %% Cold-replay catch-up: a durable MST can hold
                            %% peer-authored events from a previous run whose
                            %% `replay_cell_events` never ran (process died
                            %% between `integrate_peer_root/2` and the cast).
                            %% The WAL drain only handles events past
                            %% `resume_position/2`, so without this the
                            %% projection stays stale until the next sync tick.
                            case CellCtx of
                                undefined -> ok;
                                _ -> gen_server:cast(self(), replay_cell_events)
                            end;
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
%% Resolve the optional `cell_apply_target` into a `cell_apply_ctx`
%% map of the projection adapter, handle, and fold module from the
%% shard's registry entry. `not_found` is a hard error so a typo'd
%% triple surfaces at startup instead of silently disabling the path.
resolve_cell_apply_ctx(Opts) ->
    case maps:get(cell_apply_target, Opts, undefined) of
        undefined ->
            {ok, undefined};
        {NS, Index, Shard} = Key ->
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
                        %% The table's event namespace (`undefined` unless it
                        %% opted in via `publish => true`). The replay path in
                        %% `bondy_oplog_cell_apply:apply_cell_pairs/4` gates
                        %% merge-event emission on it, and a multiplexing
                        %% instance's LOCAL publish resolves it per bucket
                        %% (`publish_batch_dir/2`). Read from the registry
                        %% ENTRY (the restart-surviving source) so a
                        %% restart-rebuilt ctx keeps emitting; falls back to
                        %% the opts for a raw, non-`bondy_db` registration.
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
                        %% A3 — applier-private OldValue frame-cache (or
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
            end
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
%% Build the cell-apply source at init. A `per_shard` (collapsed) instance —
%% flagged by a `cell_apply_bucket` in its opts — rebuilds its full per-bucket
%% directory from the durable registry (every primary entry whose `instance_id`
%% matches), so a `one_for_all` subtree restart restores routing for EVERY table
%% on the shard, not just the founding one whose opts the supervisor replays. On
%% a fresh start only the founding entry is registered, so the directory is
%% `{Bucket => CellCtx}` exactly as before; on a restart the siblings' entries
%% are present too and the directory is whole again. A single-table
%% (`per_table_shard`) instance keeps the keyless `{single, CellCtx}` source.
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
                        {ok, Ctx} when Ctx =/= undefined ->
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
    %% behalf of the applier. The outer try/catch wraps the entire
    %% worker body — including `gen_server:reply/2` — so the caller
    %% can never hang on its `infinity` call: any exception (verify
    %% raised, forward raised, even reply raised) is logged and a
    %% best-effort fallback reply is attempted via `catch`.
    _ = spawn(fun() ->
        try
            Reply =
                case Mod:verify_event(Event, VS) of
                    ok ->
                        forward_remote(InstP, Event);
                    {error, Reason} = VerifyErr ->
                        ok = log_verify_failure(Id, Event, Reason),
                        VerifyErr
                end,
            gen_server:reply(From, Reply)
        catch
            C:R:S ->
                ?LOG_WARNING(#{
                    description =>
                        "bondy_oplog_applier verify worker raised before "
                        "delivering a reply; the remote event has been "
                        "rejected",
                    instance_id => Id,
                    class => C,
                    reason => R,
                    stacktrace => S
                }),
                %% Best-effort fallback. `gen_server:reply/2` is
                %% documented as never failing on a dead caller, but
                %% the wrapping `catch` swallows any pathological
                %% exception so the worker always exits cleanly.
                try
                    gen_server:reply(From, {error, {verify_crashed, R}})
                catch
                    _:_ -> ok
                end
        end
    end),
    {noreply, State};
handle_call(
    get_projection,
    _From,
    #state{fold_module = undefined} = State
) ->
    {reply, {error, no_fold_configured}, State};
handle_call(
    get_projection,
    _From,
    #state{fold_state = FS} = State
) ->
    {reply, {ok, FS}, State};
handle_call(
    {sweep_stable_cells, _StableHlc, _Opts},
    _From,
    #state{cell_apply_ctx = undefined} = State
) ->
    {reply, {error, no_projection}, State};
handle_call(
    {sweep_stable_cells, StableHlc, Opts},
    _From,
    #state{} = StateIn
) ->
    %% I1 (prepare-after-deliver) applies to the sweep as it does to the
    %% tier_2 PREPARE: the sweep judges "the state at StableHlc", so the
    %% projection must reflect every event delivered to this replica —
    %% including remote events integrated into the MST whose replay cast
    %% is still in flight (a different sender, unordered against this
    %% call) — before any cell is discarded or reduced. See the theorem
    %% at `ensure_remote_caught_up/1`. Steady-state cost: one atomic read.
    %%
    %% A FAILED catch-up does not abort the sweep (same policy as the
    %% `cell_context` fence): the fence stays armed for the next call,
    %% and proceeding is promptness-not-soundness — a delivered event the
    %% sweep missed replays later onto whatever the sweep left (a reduced
    %% frame absorbs it as a new entry; a discarded cell is re-created by
    %% the replay), so both directions converge.
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
    #state{cell_apply_ctx = undefined} = State
) ->
    {reply, undefined, State};
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
    {install_catalogue_batch, _Cells},
    _From,
    #state{cell_apply_ctx = undefined} = State
) ->
    {reply, {error, no_cell_apply_target}, State};
handle_call(
    {install_catalogue_batch, Cells},
    _From,
    #state{
        cell_apply_source = Source,
        instance_id = Id
    } = State
) ->
    Result = do_install_catalogue_batch(Id, Source, Cells),
    %% A catalogue install replaces/merges the projection wholesale, so
    %% the tier_2 stamp-site high-water it tracks no longer reflects
    %% the live projection — drop it. The next stamp per cell re-seeds
    %% from the installed value; a regression straddling an install is not
    %% a regression (the install is an authorised wholesale replacement).
    {reply, Result, State#state{ctx_guard = bondy_oplog_ctx_guard:new()}};
handle_call(replay_cell_events, _From, State) ->
    %% Synchronous variant of the `replay_cell_events` cast. Runs the
    %% same diff fold and replies `ok` once the projection has caught
    %% up. Callers that need read-your-peers-write semantics use this
    %% instead of the cast.
    {reply, ok, do_replay_cell_events(State)};
handle_call(last_replayed_root, _From, State) ->
    {reply, State#state.last_replayed_root, State};
handle_call(rederive_projection, _From, State) ->
    %% Full projection re-derive: reset the replay watermark so the diff
    %% fold re-applies EVERY event (not just those past the last replayed
    %% root), re-folding each cell's complete group. Restores a cell that a
    %% `replace`-mode catalogue install clobbered on a live re-bootstrap.
    %% The single-applier scope makes the reset + fold atomic w.r.t. other
    %% reads.
    {reply, ok,
        do_replay_cell_events(State#state{last_replayed_root = undefined})};
handle_call(rebuild_indexes, _From, State) ->
    %% Full secondary-index rebuild: re-derive every live term from each
    %% cell's current projection value with the back-pressure cap bypassed,
    %% re-dispatching to the secondary writers.
    {reply, ok, do_rebuild_indexes(State)};
handle_call(await_drain, From, State) ->
    %% Cold-start rebuild barrier: queue the caller and ensure a drain runs.
    %% The waiter is replied `ok` once the drain reaches end-of-log (the
    %% `{ok, _}` branch of `handle_info(drain, _)`, via `reply_drain_waiters/1`),
    %% so a subsequent rebuild/freshen observes a fully-replayed MST.
    self() ! drain,
    {noreply, State#state{drain_waiters = [From | State#state.drain_waiters]}};
handle_call(
    {reap_origins, _Retired},
    _From,
    #state{cell_apply_ctx = undefined} = State
) ->
    {reply, {error, no_cell_apply_target}, State};
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
    %% I1 (prepare-after-deliver): this read is a tier_2 op's PREPARE —
    %% it must not be served from a projection lagging events already
    %% delivered to this replica, or the minted context under-
    %% approximates its causal past (lost causality — the fatal
    %% direction). Local events are covered by construction (the WAL
    %% drain writes the projection before the MST install); remote
    %% events need this fence. Steady-state cost: one atomic read. See
    %% `ensure_remote_caught_up/1` for the invariant, the theorem it
    %% underwrites, and the mechanism.
    #state{cell_apply_source = Source, cell_apply_ctx = Founding} =
        State = ensure_remote_caught_up(StateIn),
    %% Resolve the ctx for THIS cell's bucket from the multiplex directory —
    %% NOT the founding `cell_apply_ctx`. On a collapsed (one-log-per-shard)
    %% instance many tables share one applier, each with its own CRDT, so the
    %% kernel that decodes the cell's projection state MUST match the cell's
    %% own table (e.g. an `ew_flag` membership cell on an instance founded by
    %% an `lww_register` table). A `{single, Ctx}` source returns `Ctx` for any
    %% bucket; a registered table bucket resolves to its own ctx. A bucket with
    %% NO registered table — the instance-level latency probe's reserved
    %% `$probe` bucket — falls back to the founding ctx (any kernel is correct
    %% for a probe write). An unbootstrapped instance (founding `undefined`)
    %% has no target.
    case resolve_cell_ctx(Source, Bucket, Founding) of
        undefined ->
            {reply, {error, no_cell_apply_target}, State};
        #{
            adapter := Adapter,
            handle := Handle,
            kernel := Kernel,
            crdt_module := CrdtMod
        } = CellCtx ->
            %% Single-applier-per-cell read of the cell's current context. The
            %% caller (`bondy_db:apply_with_context/4`) then appends with this
            %% context as `meta`. The read and the append are SEPARATE calls —
            %% not one locked critical section — so two concurrent same-origin
            %% writes to the same cell can read the same pre-write context and
            %% stamp it twice (a pre-existing property of the tier_2
            %% context-stamp design; the sequential `await/1` barrier gives
            %% read-your-writes for the common serial case). Single-applier
            %% scope still guarantees a consistent snapshot for THIS read.
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
            {reply, Reply, State1}
    end;
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

%% @private
%% The ctx for a cell's bucket: its own registered table ctx when the bucket is
%% in the multiplex directory, else the founding ctx (for unregistered buckets
%% such as the reserved latency-probe bucket). `undefined` only when the
%% instance is unbootstrapped.
resolve_cell_ctx(Source, Bucket, Founding) ->
    case bondy_oplog_mux:resolve(Source, Bucket) of
        undefined -> Founding;
        Ctx -> Ctx
    end.

handle_cast({advance_replayed_root, NewRoot}, State) ->
    %% Re-anchor the replay cursor on the post-truncate root without
    %% applying anything. Cast (not call) to avoid an instance↔applier
    %% deadlock — see `advance_replayed_root/2`.
    {noreply, State#state{last_replayed_root = NewRoot}};
handle_cast({refresh_validator, Reason}, State) ->
    {noreply, do_refresh_validator(Reason, State)};
handle_cast(replay_cell_events, State) ->
    {noreply, do_replay_cell_events(State)};
handle_cast(rebuild_indexes, State) ->
    {noreply, do_rebuild_indexes(State)};
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
    #state{drain_gate = gated, cell_apply_ctx = CellCtx} = State
) ->
    %% Provisioning is complete: every table sharing this per-shard instance
    %% has registered its cell-apply bucket, so the WAL can be replayed with a
    %% whole `cell_apply_source` and no cell is skipped. Kick the drain (and the
    %% cold-replay catch-up that init deferred — see `do_init_2/9`).
    self() ! drain,
    case CellCtx of
        undefined -> ok;
        _ -> gen_server:cast(self(), replay_cell_events)
    end,
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
            %% Caught up. Park an async waiter on the WAL's durable
            %% position instead of re-sending `drain` immediately (a
            %% busy spin: the next-to-read byte is already durable in
            %% `per_write` mode, so an inline `await_durable/3` returns
            %% at once) or blocking the gen_server here (which would
            %% stall the `replay_cell_events` cast and other messages
            %% that cross-node sync depends on). The waiter fires the
            %% instant a new frame becomes durable — immediate apply
            %% latency, near-zero idle CPU, responsive mailbox.
            %%
            %% Reaching end-of-log is also the signal any `await_drain/1`
            %% callers (the cold-start rebuild barrier) wait on, so reply to
            %% them here before parking.
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
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{
    iter = Iter,
    consumer_offset = CO,
    wal_dir = Dir,
    uncommitted = N
}) ->
    case N > 0 of
        true -> _ = bondy_oplog_wal_state:write_consumer_offset(Dir, CO);
        false -> ok
    end,
    case Iter of
        undefined -> ok;
        _ -> bondy_oplog_wal_reader:close(Iter)
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
%% Resolves the per-instance projection module from the registry and seeds
%% the initial projection state. The instance `fold_module` label resolves
%% to its native CRDT twin, so `#state.fold_module` holds a
%% `bondy_oplog_crdt` module and the projection path runs the op-based
%% step. Returns `{undefined, undefined}` when no module is configured —
%% callers check `fold_module` and skip the path.
init_fold(InstanceId) ->
    case bondy_oplog_registry:fold_module(InstanceId) of
        undefined ->
            {undefined, undefined};
        Strategy ->
            {crdt, Mod} = bondy_oplog_cell_kernel:from_modules(
                Strategy, undefined
            ),
            {Mod, Mod:init()}
    end.

%% @private
%% Resume from `max(last_MST_key.hlc, watermark.hlc)`. The reader's
%% `{hlc, T}` start finds the first frame whose first event HLC is
%% `>= T`, so the frame that contained our resume HLC is re-read and
%% its events are re-applied — that is safe because `bondy_mst:put`
%% is content-addressable and verify+install are idempotent.
%%
%% Falls back to `beginning` when both inputs are absent (fresh
%% instance with empty MST and no compaction history) or when the
%% MST handle is missing.
resume_position(MstLast, Watermark) ->
    case resume_hlc(MstLast, Watermark) of
        undefined -> beginning;
        HLC -> {hlc, HLC}
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
    case bondy_oplog_wal_state:read_consumer_offset(WalDir) of
        {ok, CO} -> CO;
        {error, _} -> bondy_oplog_wal_state:new_consumer_offset()
    end.

%% @private
%% The WAL-drain resume position, derived from the durable consumer offset
%% (the WAL-owned cursor) — deliberately NOT from MST state. A consumer offset
%% that has never committed (`commit_count = 0`, the fresh-instance sentinel)
%% resumes from `beginning` — the earliest LIVE segment, which also tolerates a
%% compacted/truncated prefix. A committed offset resumes exactly where the
%% last durable commit left off; any uncommitted tail (bounded by
%% `commit_every`) is re-read and re-applied idempotently via the MST's HLC
%% dedup — the standard at-least-once log-consumer contract. Keeping resume off
%% the MST is what makes the drain's correctness independent of the MST root's
%% durability schedule (e.g. async seal).
start_pos_from_consumer_offset(CO) ->
    case bondy_oplog_wal_state:commit_count(CO) of
        0 ->
            beginning;
        _ ->
            {offset, bondy_oplog_wal_state:committed_segment(CO),
                bondy_oplog_wal_state:committed_frame_offset(CO)}
    end.

%% @private
%% The committed `{Segment, FrameOffset}` of a consumer offset, or
%% `undefined` when nothing was ever committed.
consumer_offset_pos(CO) ->
    case bondy_oplog_wal_state:commit_count(CO) of
        0 ->
            undefined;
        _ ->
            {
                bondy_oplog_wal_state:committed_segment(CO),
                bondy_oplog_wal_state:committed_frame_offset(CO)
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
            %% `Info` goes in `details`, NOT as the description: its keys are
            %% what `bondy_alarm_catalogue` declares as this alarm's
            %% `detail_keys`, checked by
            %% `bondy_alarm_catalogue_test:declared_detail_keys_are_delivered`.
            %% `alarm_handler:set_alarm/1` passes the 3-tuple through unchanged
            %% (sasl-4.4 `alarm_handler.erl:103`), so `bondy_oplog` keeps its
            %% OTP-only call and gains no dependency on `bondy_router`.
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
    case bondy_oplog_wal_reader:open(WalP, StartPos, [{follow, false}]) of
        {error, {invalid_start, _}} when StartPos =/= beginning ->
            bondy_oplog_wal_reader:open(WalP, beginning, [{follow, false}]);
        Result ->
            Result
    end.

%% @private
%% Drains the reader until it returns `end_of_log` or `{error, _}`.
%% On every batch it applies the events and bumps the in-memory
%% consumer offset; consumer.offset and `set_committed_segment` are
%% persisted at `commit_every` events or on `end_of_log`.
%%
%% Before each next-batch read the loop checks the demand-based
%% in-flight counter against `max_install_in_flight`. When the cap is
%% reached the loop returns `{paused, State}` and `handle_info(drain,
%% _)` marks `drain_deferred = true`; the loop is rearmed by the
%% instance's `drain_resume` cast.
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
%% Bootstrap lifecycle gate. Returns `true` when the instance is `live`
%% (the applier may drain), `false` when the instance is still
%% `pre_bootstrap` (the applier must NOT touch the per-cell projection).
%% Treats a missing handle as `live` — the registry publish can race
%% with the applier's `init/1` after a one_for_all subtree restart, and
%% the WAL is the durable buffer either way; backwards-compatibility
%% for callers that haven't migrated to the lifecycle yet is the same
%% fail-open path.
lifecycle_live(#state{lifecycle = undefined}) ->
    true;
lifecycle_live(#state{lifecycle = H}) ->
    bondy_oplog_bootstrap_lifecycle:is_live(H).

drain_loop_step(
    #state{iter = Iter, apply_batch_max_events = Max} = State0
) ->
    %% A2 — coalesce several WAL frames into one applier batch so the
    %% pack-store spine rebuild and the leveled `put_batch` amortise over
    %% many events. `collect_frames/2` reads frames until the event count
    %% reaches `Max` (`more`) or the reader drains (`eol`); when caught up
    %% it returns a single frame and is behaviourally identical to the
    %% pre-A2 path.
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
%% A2 — coalesce consecutive WAL frames into a single applier batch.
%% Reads frames via the reader's `next/1` until the accumulated event
%% count reaches `Max` (a soft cap — a frame is never split, so the batch
%% may exceed `Max` by at most the last frame's size) or the reader
%% signals `end_of_log`. Applying many frames as one batch amortises the
%% two co-dominant per-batch storage costs (the pack-store spine rebuild
%% and the leveled projection `put_batch`) over many more events.
%%
%% When the WAL is caught up — the steady state — only one frame is
%% available before `end_of_log`, so this collapses to exactly the old
%% one-frame-per-apply behaviour: coalescing engages only when a backlog
%% already exists, which is precisely when throughput matters and when a
%% little extra per-event apply latency is irrelevant. `Max = 1`
%% reproduces the pre-A2 behaviour verbatim (the first frame already
%% satisfies `N >= 1`).
%%
%% A reader error mid-collect discards the (not-yet-applied) accumulated
%% frames and surfaces the error: their offset was never bumped, so they
%% are re-read from the last committed position after the supervisor
%% restart — at-least-once, identical to the pre-A2 stop-and-reconcile
%% behaviour.
%%
%% Returns:
%%   `{frames, Batch, {Seg, Off}, NewIter, more | eol}` — ≥1 frame read;
%%       `more` = `Max` reached and the reader has more; `eol` = drained.
%%   `{empty, Iter}` — `end_of_log` with nothing read.
%%   `{error, Reason}` — reader error.
collect_frames(Iter, Max) ->
    collect_frames(Iter, Max, [], 0, undefined).

collect_frames(Iter0, Max, AccRev, N, LastPos) ->
    case bondy_oplog_wal_reader:next(Iter0) of
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
%% Re-verify each event's stored signature (defence-in-depth against
%% WAL tampering) and dispatch the survivors to the instance via a
%% one-way `gen_server:cast`. The instance installs the events in
%% the MST and evicts the matching overlay rows in FIFO order; the
%% applier does not wait. Events that fail verification are dropped
%% from the batch: their telemetry is emitted here and their overlay
%% rows are evicted directly from the applier process so a reader
%% does not perpetually observe a row whose event the system has
%% rejected. Subsequent applier passes do not retry rejected events
%% (replay-from-beginning would just re-fire the same failure).
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
            ok = evict_rejected_overlay(Id, Rejected),
            %% No `install_local_batch` cast will be issued for these
            %% events, but the overlay just shrank — hint the instance
            %% so any caller blocked in `await_apply/1,2` can be
            %% signalled instead of waiting for the next install batch.
            gen_server:cast(InstancePid, check_drain_waiters)
    end,
    VerifiedCount = length(Verified),
    State1 =
        case Verified of
            [] ->
                State;
            _ ->
                %% Order matters for `await_apply/1,2`'s contract:
                %% applier-side projection writes (fold, cell_apply,
                %% publish) run BEFORE the `install_local_batch` cast
                %% is dispatched to the instance. The instance's
                %% handler is the place that signals
                %% `drain_waiters` — by enqueuing the cast last we
                %% guarantee that, by the time a caller's
                %% `await_apply` sees the overlay empty, the
                %% projection adapter, fold state, and `publish_fun`
                %% have all observed the events. The earlier ordering
                %% (cast first, then process in the applier) was a
                %% concurrency micro-optimisation: it overlapped the
                %% applier's projection write with the instance's MST
                %% install. The pipeline still overlaps across
                %% batches (the applier's NEXT batch starts while the
                %% instance is processing this batch's cast), so the
                %% reorder only costs the within-batch overlap, which
                %% is dominated by the projection write anyway.
                {CellEvents, FoldEvents} = partition_by_op(Verified),

                FoldT0 = erlang:monotonic_time(microsecond),
                S1 = apply_fold_batch(State, FoldEvents),
                telemetry:execute(
                    [bondy_oplog, applier, batch_fold],
                    #{
                        duration_us => erlang:monotonic_time(microsecond) -
                            FoldT0,
                        count => length(FoldEvents)
                    },
                    #{instance_id => Id}
                ),

                CellT0 = erlang:monotonic_time(microsecond),
                ok = bondy_oplog_cell_apply:apply_cell_batch_mux(
                    S1#state.cell_apply_source,
                    S1#state.instance_id,
                    CellEvents
                ),
                telemetry:execute(
                    [bondy_oplog, applier, batch_cell_apply],
                    #{
                        duration_us => erlang:monotonic_time(microsecond) -
                            CellT0,
                        count => length(CellEvents)
                    },
                    #{instance_id => Id}
                ),

                PublishT0 = erlang:monotonic_time(microsecond),
                ok = publish_batch(S1, Verified),
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
                S1
        end,
    %% One telemetry event per applier batch, regardless of which
    %% sub-path the events take (fold, cell_apply, publish). This is
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
%% Partitions a verified batch into `{CellApplyEvents, FoldEvents}`.
%% `CellApplyEvents` are events whose op matches
%% `{cell_apply, Bucket, Key, FoldEvent}`; these bypass the per-instance
%% fold and instead drive a projection read-modify-write through
%% `bondy_oplog_cell_apply:apply_cell_batch/3`. Everything else goes
%% through the existing
%% per-instance fold path.
partition_by_op(Events) ->
    lists:partition(
        fun(E) ->
            case bondy_oplog_event:op(E) of
                {cell_apply, _, _, _} -> true;
                _ -> false
            end
        end,
        Events
    ).

%% @private
%% Folds the verified events into the per-instance projection state.
%% No-op when no fold module is configured. Wraps the fold in a
%% try/catch so a misbehaving fold module cannot wedge the applier —
%% an exception is logged and the state is preserved unchanged
%% (the applier continues to drain the WAL but the projection
%% deviates from the WAL; F9 will track recovery semantics).
apply_fold_batch(#state{fold_module = undefined} = State, _Verified) ->
    State;
apply_fold_batch(State, []) ->
    State;
apply_fold_batch(
    #state{
        fold_module = Mod,
        fold_state = FS0,
        instance_id = Id
    } = State,
    Verified
) ->
    try
        FS1 = lists:foldl(
            fun(Event, Acc) ->
                bondy_oplog_crdt_commutative:apply_op(
                    Mod,
                    Acc,
                    bondy_oplog_event:op(Event),
                    bondy_oplog_event:key(Event)
                )
            end,
            FS0,
            Verified
        ),
        State#state{fold_state = FS1}
    catch
        C:R:S ->
            ?LOG_ERROR(#{
                description =>
                    "bondy_oplog_applier fold raised; the projection "
                    "is now inconsistent with the WAL until the next "
                    "successful batch. Subtree continues to drain.",
                instance_id => Id,
                fold_module => Mod,
                class => C,
                reason => R,
                stacktrace => S
            }),
            State
    end.

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

%% NOTE (cell-event replay): re-applies the cell events that landed in
%% the MST since the last replay. Called from the instance after a sync
%% session merges peer events. Without this, remote events sit in the
%% MST but never reach the projection — reads would only see events
%% authored locally.
%%
%% The walk is incremental: the MST diff prunes subtrees whose root
%% hash is shared between the current MST and the last replayed root,
%% so the cost is O(events since last sync) rather than O(events in
%% MST). A cold start (no last replayed root) does one full fold so any
%% peer-authored events present in the MST at boot time are observed;
%% subsequent replays use the diff.

%% @private
%% Full secondary-index rebuild.
%%
%% Re-materialises every secondary index from the CURRENT projection value
%% of each live cell. It does NOT replay the cell's historical events.
%%
%% Why read the projection instead of re-folding the MST: the live
%% projection is already the converged value (the live drain folded it
%% forward; any peer events were folded in by `do_replay_cell_events/1`).
%% Re-applying a cell's historical events on top of that advanced state is
%% only idempotent for a context-free (tier_0) CRDT. A context-carrying
%% (tier_2) CRDT re-mints each replayed event's dot and, because the
%% advanced cell holds newer dots the historical event never observed, the
%% per-event intermediate states transiently re-introduce superseded dots
%% as spurious MV-leaf siblings. The PRIMARY projection reconverges (a
%% complete causal suffix re-collapses them — see `commit_now/1`), but the
%% index captures a per-event term-diff and would latch one of those
%% divergent intermediates. Reading the single converged projection value
%% sidesteps the hazard and is correct for tier_0 too — and is cheaper:
%% one read + one term-diff per distinct cell, vs one kernel re-apply per
%% event.
%%
%% Cell directory: read from the PROJECTION, not the MST. The MST is a
%% truncatable recent-events structure — compaction drops events `<=` the
%% watermark (`bondy_oplog_instance:truncate_below_or_equal/2`), and a
%% no-checkpoint crash loses its in-memory tail — so its cell set is
%% generally INCOMPLETE relative to the durable projection. Deriving the
%% directory from `distinct_cell_keys(MST)` would silently miss every
%% already-compacted (or crash-lost) cell, leaving a half-built index that
%% is nonetheless marked trusted. The projection is the durable, complete
%% materialised state, so for a durable table the rebuild enumerates the
%% primary's own cells there (`Adapter:cell_keys(Handle, Scope)`, the
%% topology-chosen `cell_keys_scope()`) and reads each value from it. The
%% MST walk remains the fallback for an adapter that cannot enumerate (the
%% ephemeral ETS projection — see `primary_cell_directory/4`).
do_rebuild_indexes(#state{cell_apply_ctx = undefined} = State) ->
    State;
do_rebuild_indexes(#state{cell_apply_ctx = Ctx, instance_id = Id} = State) ->
    case bondy_oplog_cell_apply:sec_idx(Ctx) of
        {_NS, []} ->
            %% No secondary indexes on this primary — nothing to rebuild.
            State;
        SecIdx ->
            bondy_oplog_cell_utils:reindex(Id, Ctx, SecIdx),
            State
    end.

do_replay_cell_events(State0) ->
    {_, State} = do_replay_cell_events_r(State0),
    State.

%% @private
%% THE PREPARE FENCE — the enforcement point of invariant I1, on which
%% the soundness of the whole causal-stabilization story rests. Stated
%% for the record (this is the normative statement; every reclamation
%% feature is answerable to it):
%%
%%   I1 (prepare-after-deliver). Every operation on a cell `c` is
%%   prepared against a state that reflects the effect of every event
%%   on `c` DELIVERED at this replica before the prepare. "Delivered"
%%   means: locally originated and WAL-drained (the drain writes the
%%   projection BEFORE the MST install, so local events satisfy I1 by
%%   construction), or peer-merged by `integrate_peer_root` (whose
%%   handler completion is the remote delivery point).
%%
%%   I2 (containment stability). The reclamation frontier `StableHlc`
%%   (`bondy_oplog_instance:stability_point/1`) certifies, by per-key
%%   containment proofs against every confirmed peer root, that every
%%   replica holds every event with HLC =< `StableHlc`.
%%
%%   Theorem (causal stability without causal broadcast). Given I1 and
%%   I2, any event generated anywhere after `StableHlc` was certified
%%   carries a causal context dominating every dot with HLC =<
%%   `StableHlc` on its cell. Hence any state transformation derived
%%   solely from events at or below the frontier — a `stabilize/2`
%%   `discard`, a `{keep, Reduced}` metadata reduction, an
%%   order-independent accumulator fold — is invisible to every event
%%   that can still arrive. Proof sketch: by I2 the generating replica
%%   held (and by I1 had applied, before preparing) every such event
%%   for the cell; the prepared context is `context_of/1` over that
%%   state, which contains their dots. This recovers TCSB-grade causal
%%   stability (Baquero, Almeida & Shoker, arXiv:1710.04469 §7.2) in an
%%   anti-entropy architecture with no causal broadcast layer.
%%
%% Without this fence I1 fails on applier-backed instances for REMOTE
%% events: `integrate_peer_root` advances the MST and casts
%% `replay_cell_events`, but that cast and a client's `cell_context`
%% call come from different senders, so the context read can be served
%% from a projection lagging the replica's own delivered set — minting
%% an op whose context under-approximates its causal past (the fatal
%% direction: lost causality; contrast the read-and-stamp
%% non-atomicity noted at the `{cell_context, _, _}` handler, which
%% errs only toward FALSE concurrency — extra siblings the CRDT
%% resolves — and is therefore acceptable).
%%
%% Mechanism: one shared atomics generation, bumped by the instance at
%% each `integrate_peer_root` completion (the delivery point; see the
%% bump-site note there for why that site is exhaustive). A context
%% read compares it against the generation this projection last
%% replayed to: equal in the steady state (one atomic read, no
%% instance round-trip), and on a gap it runs the same idempotent
%% `replay_pairs`-anchored catch-up the cast handler runs, advancing
%% the recorded generation ONLY on success — a failed catch-up must
%% keep the fence armed. The generation is sampled BEFORE the replay:
%% a bump landing mid-replay may or may not be covered by the root the
%% replay read, so it must re-arm the fence (conservative, never
%% unsound).
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
do_replay_cell_events_r(#state{cell_apply_ctx = undefined} = State) ->
    {ok, State};
do_replay_cell_events_r(
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
            %% Prefix-closure hold: a diff with held events must keep the
            %% replay cursor — re-diffing from the old root re-presents
            %% them (idempotent re-fold) until the gap fills or a
            %% rebootstrap re-anchors the cursor.
            case Held of
                0 -> {ok, State#state{last_replayed_root = CurrentRoot}};
                _ -> {ok, State}
            end
    catch
        exit:Reason ->
            %% Instance unavailable (e.g. mid-restart) — leave the replay root
            %% unchanged; the next replay trigger retries.
            {{error, Reason}, State}
    end.

%% @private
%% Returns the `[{Key, Value}]` list to re-apply. Falls back to a full
%% `to_list/1` if the diff raises — for example, if `LastRoot`'s pages
%% have been partially GC'd between two replays. The applier never
%% silently misses events: a failed diff costs one extra full fold.
diff_pairs(MST, undefined, _Id) ->
    bondy_mst:to_list(MST);
diff_pairs(MST, LastRoot, Id) ->
    try
        bondy_mst:diff_to_list(MST, LastRoot)
    catch
        C:R:S ->
            ?LOG_WARNING(#{
                description =>
                    "bondy_mst:diff_to_list raised; falling back to "
                    "full MST scan for this replay",
                instance_id => Id,
                last_root => LastRoot,
                class => C,
                reason => R,
                stacktrace => S
            }),
            bondy_mst:to_list(MST)
    end.

%% @private
%% Installs a catalogue-snapshot batch of `[{Bucket, Key, Frame}]`
%% triples into the projection.
%%
%% The install is `replace`-only (CvRDT `merge_states` is not supported).
%% Skip-if-older guards a stale bootstrap write from clobbering a newer
%% locally-applied event. A fresh (`pre_bootstrap`) replica's projection is
%% empty so skip-if-older never skips; a live re-bootstrap may install a
%% higher-HLC peer cell over a local one, which the post-bootstrap op-replay
%% restores (`bondy_oplog_sync_session`).
do_install_catalogue_batch(Id, Source, Cells) ->
    %% A peer snapshot bundles cells from EVERY table on the shard, each
    %% tagged with its entity-type `Bucket`. Demultiplex by bucket (the same
    %% primitive the hot apply path uses) and install each group through its
    %% own table's ctx — so a multiplexed per-shard instance routes each
    %% table's cells to its own projection, not the founding table's. On a
    %% single-table instance (`{single, Ctx}`) every bucket resolves to the
    %% one ctx, so this is identical to the pre-multiplex behaviour.
    Groups = bondy_oplog_mux:group_by(
        Cells, fun({Bucket, _Key, _Frame}) -> {ok, Bucket} end
    ),
    Counts = lists:foldl(
        fun({Bucket, BucketCells}, Acc) ->
            case bondy_oplog_mux:resolve(Source, Bucket) of
                undefined ->
                    %% No table registered for this bucket on the instance
                    %% (a snapshot cell for a table not open here): skip it
                    %% rather than misroute it to the founding projection.
                    bump_n(skipped, length(BucketCells), Acc);
                Ctx ->
                    install_catalogue_group(
                        Id, Ctx, Bucket, BucketCells, Acc
                    )
            end
        end,
        #{
            installed => 0,
            skipped => 0,
            merged => 0,
            replaced_no_merge => 0,
            max_hlc => 0
        },
        Groups
    ),
    {ok, Counts}.

%% @private
%% Install one bucket's cells through its table's ctx, accumulating into the
%% shared counts, then clear that ctx's old-state cache and notify reactors.
install_catalogue_group(Id, Ctx, Bucket, Cells, Acc0) ->
    #{
        adapter := Adapter,
        handle := Handle,
        cache_adapter := CacheAdapter,
        cache_handle := CacheHandle,
        high_water_ref := HighWaterRef
    } = Ctx,
    Acc1 = lists:foldl(
        fun(Cell, Acc) ->
            install_one_cell(
                Id,
                Adapter,
                Handle,
                CacheAdapter,
                CacheHandle,
                HighWaterRef,
                Cell,
                Acc
            )
        end,
        Acc0,
        Cells
    ),
    %% A3 — the install path (`install_cell_unchecked/9`) writes the
    %% projection WITHOUT write-through (it installs a frame directly,
    %% with no fold result to cache). A catalogue bootstrap can run on a
    %% LIVE instance (a live re-bootstrap), so any installed key may
    %% already be warm in the OldValue cache with its pre-install frame —
    %% a stale hit would then fold the next live event against the wrong
    %% OldState (a convergence break). Clearing this table's cache here
    %% closes it. The single-threaded applier guarantees this clear
    %% completes before any later drain reads. Cheap: a rare bulk recovery
    %% op, and the cache is rebuildable from the projection.
    bondy_oplog_cell_apply:oldstate_cache_clear(
        maps:get(oldstate_cache, Ctx, undefined)
    ),
    %% Honour the table's `publish => true` declaration on THIS write path
    %% too. `install_cell_unchecked/9` writes frames directly and emits no
    %% per-cell merge event, so without this a table whose reactor DERIVES
    %% state from the projection (rather than merely invalidating on change)
    %% is never told its projection exists. One event per bucket per batch,
    %% not one per cell: a snapshot install is a wholesale replace, not N
    %% merges, and modelling it as N merges would both cost O(cells) sends
    %% and hand reactors an `Old` of `undefined` for every key — which a
    %% differ like `bondy_aae_reactor:react_user/3` would read as "every
    %% user's credentials just changed".
    %%
    %% Only when this batch actually installed something: a batch that
    %% skipped every cell on the HLC guard changed nothing to rebuild from.
    ok = maybe_publish_bootstrap(Ctx, Bucket, Acc0, Acc1),
    Acc1.

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
`publish_ns`), or when this group installed nothing: a batch that skipped
every cell on the per-cell HLC guard replaced no projection and leaves
subscribers nothing to rebuild from.
""".
-spec bootstrap_publish_decision(
    Ctx :: map(), Acc0 :: map(), Acc1 :: map()
) -> {publish, atom()} | skip.

bootstrap_publish_decision(Ctx, Acc0, Acc1) ->
    case maps:get(publish_ns, Ctx, undefined) of
        undefined ->
            skip;
        NS ->
            Before = maps:get(installed, Acc0, 0),
            After = maps:get(installed, Acc1, 0),
            case After > Before of
                true -> {publish, NS};
                false -> skip
            end
    end.

%% @private
install_one_cell(
    Id,
    Adapter,
    Handle,
    CacheAdapter,
    CacheHandle,
    HighWaterRef,
    {Bucket, Key, Frame},
    Acc
) ->
    try bondy_oplog_cell_frame:decode_full(Frame) of
        {IncomingHlc, _IncomingStateBytes, _IncomingValueBytes} ->
            Existing = read_existing_for_install(
                Adapter, Handle, Bucket, Key
            ),
            %% A3 — track the maximum decoded cell HLC across the batch. The
            %% sync session folds it across batches and the instance absorbs
            %% it into the local clock at finalize
            %% (`finalize_catalogue_bootstrap/5`); without that absorb a
            %% bootstrapped replica's clock sits BELOW the cells it just
            %% installed and it can mint events under a stability point
            %% computed from them (BONDY_DB_RECLAMATION_PROOF.md §7.1).
            Acc1 = Acc#{
                max_hlc => max(maps:get(max_hlc, Acc, 0), IncomingHlc)
            },
            handle_cell(
                Id,
                Adapter,
                Handle,
                CacheAdapter,
                CacheHandle,
                HighWaterRef,
                Bucket,
                Key,
                Frame,
                IncomingHlc,
                Existing,
                Acc1
            )
    catch
        C:R:St ->
            ?LOG_WARNING(#{
                description =>
                    "install_catalogue_batch: cell skipped due to "
                    "decode error",
                instance_id => Id,
                bucket => Bucket,
                cell_key => Key,
                class => C,
                reason => R,
                stacktrace => St
            }),
            bump(skipped, Acc)
    end.

%% @private
%% Returns one of:
%%   not_found
%% | {ok, ExistingHlc, ExistingStateBytes | undefined}
%%
%% Only the HLC is needed for the skip-if-older check, so we use the
%% adapter's optional `head/3` callback when available and avoid pulling
%% the full V2 frame off the journal.
read_existing_for_install(Adapter, Handle, Bucket, Key) ->
    case adapter_head_hlc(Adapter, Handle, Bucket, Key) of
        not_found ->
            not_found;
        {ok, ExistingHlc} ->
            {ok, ExistingHlc, undefined}
    end.

%% @private
%% HLC-only read against the projection adapter. Uses the optional
%% `head/3` callback when the adapter exports it; otherwise falls
%% back to `get/3 + decode_full/1`.
adapter_head_hlc(Adapter, Handle, Bucket, Key) ->
    case erlang:function_exported(Adapter, head, 3) of
        true ->
            case Adapter:head(Handle, Bucket, Key) of
                not_found ->
                    not_found;
                {ok, HeadBytes} ->
                    {Hlc, _ValueBytes} =
                        bondy_oplog_cell_frame:decode_head(HeadBytes),
                    {ok, Hlc}
            end;
        false ->
            case Adapter:get(Handle, Bucket, Key) of
                not_found ->
                    not_found;
                {ok, Frame} ->
                    {Hlc, _StateBytes, _ValueBytes} =
                        bondy_oplog_cell_frame:decode_full(Frame),
                    {ok, Hlc}
            end
    end.

%% @private
handle_cell(
    _Id,
    Adapter,
    Handle,
    CacheAdapter,
    CacheHandle,
    HighWaterRef,
    Bucket,
    Key,
    Frame,
    IncomingHlc,
    not_found,
    Acc
) ->
    %% No local cell — install verbatim.
    install_cell_unchecked(
        Adapter,
        Handle,
        CacheAdapter,
        CacheHandle,
        HighWaterRef,
        Bucket,
        Key,
        Frame,
        IncomingHlc
    ),
    bump(installed, Acc);
handle_cell(
    Id,
    Adapter,
    Handle,
    CacheAdapter,
    CacheHandle,
    HighWaterRef,
    Bucket,
    Key,
    Frame,
    IncomingHlc,
    {ok, ExistingHlc, _ExistingStateBytes},
    Acc
) ->
    case IncomingHlc > ExistingHlc of
        true ->
            install_cell_unchecked(
                Adapter,
                Handle,
                CacheAdapter,
                CacheHandle,
                HighWaterRef,
                Bucket,
                Key,
                Frame,
                IncomingHlc
            ),
            bump(installed, Acc);
        false ->
            telemetry:execute(
                [bondy_oplog, applier, catalogue_bootstrap, cell_skipped],
                #{count => 1},
                #{
                    instance_id => Id,
                    bucket => Bucket,
                    cell_key => Key,
                    incoming_hlc => IncomingHlc,
                    existing_hlc => ExistingHlc
                }
            ),
            bump(skipped, Acc)
    end.

%% @private
bump(Key, Acc) ->
    maps:update_with(Key, fun(X) -> X + 1 end, Acc).

%% @private
bump_n(Key, N, Acc) ->
    maps:update_with(Key, fun(X) -> X + N end, Acc).

%% @private
install_cell_unchecked(
    Adapter,
    Handle,
    CacheAdapter,
    CacheHandle,
    HighWaterRef,
    Bucket,
    Key,
    Frame,
    Hlc
) ->
    case Adapter:put_batch(Handle, [{Bucket, Key, Frame}]) of
        ok ->
            bondy_oplog_cell_apply:invalidate_cache(
                CacheAdapter, CacheHandle, Bucket, Key
            ),
            bondy_oplog_cell_apply:advance_high_water(HighWaterRef, Hlc),
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "install_catalogue_batch: projection write failed",
                bucket => Bucket,
                cell_key => Key,
                reason => Reason
            }),
            ok
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
%% Removes overlay rows for events the applier refused to install.
%% Uses the registry to find the overlay tid and an `ets:select_delete/2`
%% with an HLC-conditional guard so a concurrent retry of the same key
%% with a higher HLC is preserved.
evict_rejected_overlay(InstanceId, Events) ->
    case bondy_oplog_registry:overlay_tab(InstanceId) of
        undefined ->
            ok;
        Tab ->
            lists:foreach(
                fun(Event) ->
                    Key = bondy_oplog_event:key(Event),
                    Hlc = bondy_oplog_event:key_hlc(Key),
                    _ =
                        try
                            ets:select_delete(Tab, [
                                {
                                    {Key, '_', '$1', '_'},
                                    [{'=<', '$1', Hlc}],
                                    [true]
                                }
                            ])
                        catch
                            error:badarg -> 0
                        end
                end,
                Events
            ),
            ok
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
    CO1 = bondy_oplog_wal_state:with_position(CO0, Seg, Off),
    CO2 = bondy_oplog_wal_state:with_hlc(CO1, LastHlc),
    Old = bondy_oplog_wal_state:commit_count(CO2),
    CO3 = bondy_oplog_wal_state:with_commit_count(CO2, Old + 1),
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
    %% Drain barrier: block until the instance has processed every
    %% `install_local_batch` cast we issued before this commit. The
    %% FIFO mailbox ordering of casts and the synchronous call
    %% together guarantee that, when the call returns, all events
    %% whose keys we're about to commit have been installed in the
    %% MST. Without this barrier, `notify_committed_segment` could
    %% drop a WAL segment whose events the instance has not yet
    %% applied — a hard durability hole on a co-crash.
    ok = drain_install_queue(InstancePid),
    %% NOTE: `last_replayed_root` is NOT advanced here even though
    %% `drain_install_queue/1` proves every local install has been
    %% applied to the MST. Reason: a peer sync's
    %% `integrate_peer_root/2` can interleave with the WAL drain and
    %% land remote pages in the MST under the same root that this
    %% barrier returns. Those remote events flow through the
    %% `replay_cell_events` cast — not through
    %% `bondy_oplog_cell_apply:apply_cell_batch/3` —
    %% so the projection has *not* seen them yet. Advancing the
    %% watermark to the live root here would mark them as already
    %% replayed, and `do_replay_cell_events/1` would short-circuit
    %% before folding them. Empirically (Jepsen OR-set,
    %% random-partition-halves): doing so produces 27/226 lost adds.
    %% Leaving the watermark anchored at its previous value keeps the
    %% next `do_replay_cell_events/1` honest — it sees a diff that
    %% includes both the locally-installed events and any
    %% interleaving peer events. Local events are re-folded
    %% idempotently (CRDT contract); the cost is one extra RMW per
    %% local event per sync tick, dominated by the sync round-trip
    %% itself.
    case bondy_oplog_wal_state:write_consumer_offset(Dir, CO) of
        ok ->
            Seg = bondy_oplog_wal_state:committed_segment(CO),
            ok = notify_committed_segment(InstanceId, WalPid, Seg),
            ok = bump_ae_targets(State),
            note_drain_progress(State#state{uncommitted = 0});
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "bondy_oplog_applier could not persist consumer.offset; "
                    "retrying on the next commit boundary",
                instance_id => InstanceId,
                reason => Reason
            }),
            %% Keep uncommitted > 0 so the next commit boundary retries.
            State
    end.

%% @private
%% Synchronous barrier — `gen_server:call` jumps the instance mailbox
%% to the back of the queue, so every prior cast (the `install_local_batch`
%% messages from this drain pass) has been fully handled by the time
%% this call returns. A `noproc` race during subtree shutdown is
%% treated as a "no events to wait on" and tolerated.
drain_install_queue(InstancePid) ->
    try gen_server:call(InstancePid, drain_install_queue, infinity) of
        ok -> ok
    catch
        exit:{noproc, _} -> ok;
        exit:noproc -> ok;
        exit:{normal, _} -> ok;
        exit:{shutdown, _} -> ok
    end.

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
%% Park an async waiter on the WAL's durable position. Spawns a
%% monitored helper that blocks in `bondy_oplog_wal:await_durable/3`
%% until the durable position advances *strictly past* the reader's
%% current offset (i.e. a new frame becomes durable) or
%% `?AWAIT_DURABLE_TIMEOUT_MS` elapses, then exits. The helper's
%% monitor `DOWN` is the applier's wakeup signal (see
%% `handle_info({'DOWN', ...})`).
%%
%% Why a helper rather than calling `await_durable/3` inline:
%% `await_durable/3` is a blocking `gen_server:call`. Calling it from
%% the applier's own `handle_info(drain)` would make the applier
%% unresponsive to every other message — notably the
%% `replay_cell_events` cast that cross-node sync uses to fold synced
%% events into the projection — for the duration of the wait. The
%% helper isolates the block; the applier returns immediately and its
%% mailbox keeps flowing.
%%
%% Why `{Seg, Off + 1}` and not `{Seg, Off}`: the reader's current
%% position is the next-to-read byte, which is already durable whenever
%% we are caught up (always so in `per_write` mode, where head ≡
%% durable). Awaiting `{Seg, Off}` is satisfied instantly and the
%% helper would exit immediately, spinning. `{Seg, Off + 1}` waits for
%% genuinely new data. A segment rollover satisfies it too, since
%% `{Seg, Off + 1} =< {Seg + 1, _}`.
arm_idle_waiter(#state{idle_waiter = Ref} = State) when is_reference(Ref) ->
    %% Already parked — don't spawn a second helper.
    State;
arm_idle_waiter(#state{iter = Iter, wal_pid = WalPid} = State) ->
    {Seg, Off} = bondy_oplog_wal_reader:position(Iter),
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
%% A2 coalescing threshold must be a positive integer (`1` = disabled).
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
%% A3 — `oldstate_cache` is a boolean flag (default false);
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
        undefined ->
            ok;
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
%% delivery for that event; a raise is logged and treated as `skip` so
%% a misbehaving derivation cannot wedge the applier. Best-effort
%% delivery; the dispatcher walks subscribers in this process.
%%
%% A MULTIPLEXING (`per_shard`) instance resolves the namespace PER EVENT
%% from the bucket's own cell-apply ctx (`publish_batch_dir/2`): the
%% instance-level `publish_ns` is the FOUNDING table's, and publishing every
%% sibling's local writes under the founder's namespace both misroutes them
%% and leaves a `publish => true` sibling's subscribers deaf to local
%% writes — which is exactly how the merge path already resolves it
%% (`bondy_oplog_cell_apply` reads the ctx). Pinned by
%% `bondy_db_publish_list_test`'s shared-instance cases.
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
            case derive_publish(Fun, Event, Id) of
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

derive_publish(Fun, Event, InstanceId) ->
    try Fun(Event) of
        skip ->
            skip;
        {K, Op} ->
            {K, Op};
        Bad ->
            log_publish_fun_bad_return(InstanceId, Event, Bad),
            skip
    catch
        C:R:S ->
            log_publish_fun_raised(InstanceId, Event, C, R, S),
            skip
    end.

log_publish_fun_bad_return(InstanceId, Event, Bad) ->
    ?LOG_WARNING(#{
        description =>
            "bondy_oplog_applier publish_fun returned an unexpected "
            "shape; event will not be published",
        instance_id => InstanceId,
        key => bondy_oplog_event:key(Event),
        return => Bad
    }).

log_publish_fun_raised(InstanceId, Event, C, R, S) ->
    ?LOG_WARNING(#{
        description =>
            "bondy_oplog_applier publish_fun raised; event will not "
            "be published",
        instance_id => InstanceId,
        key => bondy_oplog_event:key(Event),
        class => C,
        reason => R,
        stacktrace => S
    }).

%% @private
%% Bump the AE atomic counter for every shard in `ae_targets` with a
%% shared `monotonic_time(millisecond)` so the batch observes the same
%% "now". `not_found` is treated as benign (the registry entry may be
%% torn down concurrently during shutdown) and counted in telemetry.
%% Delegates the per-shard write to
%% `bondy_oplog_core_registry:bump_ae_targets/2` so the applier-side and
%% AE-side wirings share one primitive.
bump_ae_targets(#state{ae_targets = []}) ->
    ok;
bump_ae_targets(#state{instance_id = Id, ae_targets = Targets}) ->
    Now = erlang:monotonic_time(millisecond),
    {Bumped, NotFound} =
        bondy_oplog_core_registry:bump_ae_targets(Targets, Now),
    telemetry:execute(
        [bondy_oplog, applier, ae_bumped],
        #{count => Bumped, not_found => NotFound},
        #{instance_id => Id, now_ms => Now}
    ),
    ok.
