%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_instance).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

%% Watchdog for an in-flight async compaction catch-up: if the applier
%% never casts `{catch_up_done, _}` back (crash mid-fold, dropped cast),
%% clear the pending record after this long so compaction can resume.
-define(CATCH_UP_TIMEOUT_MS, 30000).

%% The substrate's reserved primary-index id (matches `bondy_db`'s `?INDEX`
%% and `bondy_oplog_index_rebuild`'s `?INDEX`). A registry shard whose index
%% id is anything else is a secondary index.
-define(PRIMARY_INDEX, primary).

%% Bounded wait for a secondary-index writer flush during the compaction
%% flush barrier. Generous — a normal flush drains only a ~5 ms
%% coalesce buffer — so it only ever trips on a genuinely wedged/dead
%% writer, which then takes the rebuild backstop.
-define(IDX_FLUSH_TIMEOUT_MS, 5000).

%% Ephemeral fused-writer mode (fused-writer rollout, Step 3). When
%% `#state.fused` is set, the instance drains its own WAL and installs
%% inline (no applier, no install cast). These mirror the applier's drain
%% knobs; the ephemeral fused path reuses the applier's state-free drain
%% leaves (`collect_frames/2`, `resume_position/2`, `resolve_cell_apply_ctx/1`).
-define(FUSED_AWAIT_DURABLE_TIMEOUT_MS, 200).
%% Max apply batches the fused drain processes per `handle_info(fused_drain)`
%% before yielding back to the gen_server mailbox. The fused drain IS the
%% instance process, so an unbounded drain loop (to `eol`) under a continuous
%% write stream — which never reaches `eol` — would monopolise the process and
%% STARVE every `handle_call`/`handle_cast` (compact, `integrate_peer_root`,
%% `await_overlay_drained`, …). Yielding every N batches bounds control-plane
%% latency to ~N·apply_batch_max events while amortising the message-loop
%% overhead. 8 × 256 ≈ 2k events ≈ a few ms at steady state.
-define(FUSED_DRAIN_MAX_BATCHES, 8).
-define(FUSED_COMMIT_EVERY, 64).
-define(FUSED_APPLY_BATCH_MAX, 256).
-define(FUSED_RETRY_MS, 50).

%% Mem WAL in-flight-gap handling: how long to short-retry a `Seq` gap before
%% the drain treats it as unrecoverable. `1 ms` retry × `2000` ≈ 2 s. A real
%% in-flight insert fills in ~µs; the window is deliberately wide (six orders of
%% magnitude) so that a *live* writer merely descheduled between reserving and
%% inserting under load is NOT mistaken for a dead one — misjudging it would
%% drop an acknowledged local write. On exhaustion the instance stops for a
%% supervised restart + reopen recovery rather than skipping the Seq (a silent
%% drop). A future refinement could make the window scheduler-pressure-aware
%% (pause the count while the run queue is deep) instead of wall-clock.
-define(FUSED_GAP_RETRY_MS, 1).
-define(FUSED_MAX_GAP_RETRIES, 2000).

%% Retry budget for the burned-seq backfill (`fill_burned_seqs/4`): the
%% WAL rejection that caused the burn is usually transient backpressure,
%% so the fill retries with exponential backoff (100ms doubling, 5s cap)
%% before giving up and leaving the gap to the peers' rebootstrap repair.
-define(SEQ_FILL_MAX_RETRIES, 10).

%% Cap on the watermark door's fast-path region scan
%% (`entries_at_or_below/2`): the at-or-below-watermark region is
%% normally empty or a handful of just-merged events, so the capped
%% `bondy_mst:last_n/3` walk covers it in O(candidates); an
%% exactly-capped result falls back to the total full-tree filter.
-define(DOOR_SCAN_CAP, 1024).

%% TTL for peer-root pins (`pin_peer_root/2`). A sync session pins the
%% root it is pulling so the ETS page GC (`truncate_below_or_equal/4`)
%% does not sweep pulled-but-not-yet-merged pages out from under it; a
%% session that dies without its pin being consumed by
%% `integrate_peer_root` leaves the pin to expire here. Generous vs the
%% session's own timeouts — the cost of a stale pin is only a few
%% retained pages for this long.
-define(PEER_ROOT_PIN_TTL_MS, 120_000).

%% How long the instance's own aae-root must verify UNSERVABLE
%% (continuously) before the compaction path self-heals by rebuilding
%% the MST (`maybe_self_heal_unservable/2`). Far above any transient
%% truncate/GC race window (those clear within a round) and long enough
%% for the peer-side unservable-behind escalation to drain our surplus
%% first — see the domination gate.
-define(SELF_HEAL_UNSERVABLE_AFTER_MS, 60_000).

%% Minimum gap between durable (pack) page reclamations — see
%% `maybe_collect_durable/1`. A collection rewrites every sealed pack, so this
%% is deliberately coarse: the leak it drains is slow (durable namespaces are
%% low write-volume) and the rewrite is the most expensive thing the instance
%% can do. Override with `bondy_oplog.durable_gc_interval_ms`.
-define(DURABLE_GC_INTERVAL_MS, 3_600_000).

%% Async pack-store seal: how many times the instance re-runs a failed seal
%% job before giving up and stopping so the supervisor restart + reopen
%% recovery re-seals the frozen incoming pack from scratch. A persistent
%% failure here means the disk is unwritable — a bigger problem than a seal.
-define(MAX_SEAL_RETRIES, 3).

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
The per-instance Merkle Search Tree owner.

Exactly one process per running instance; one MST per instance; one
storage backend handle per instance.

## Responsibilities

- Own the MST handle (which itself owns the storage backend).
- Generate fresh `{HLC, Origin, Seq}` event keys on local appends.
- Sign local events through the configured validator.
- Install verified peer events into the MST. Signature verification
  for both locally appended events (WAL drain path) and peer-received
  events (`append_remote/2`) runs in the per-instance applier
  process; this gen_server is the install point but not the verify
  point.
- Expose the MST root hash, key-range reads, and prefix truncation
  hooks for compaction.
- Run compaction cycles: stability frontier → `interpret_cog` →
  snapshot → MST truncate → watermark advance.
- Own the page-level anti-entropy primitives (`merge_pages`,
  `integrate_peer_root`) and snapshot-load operations. These are not
  event-stream operations; the public façade drains the applier
  before invoking them so installs already in flight are visible.

## What this module is *not*

The library is **agnostic** to lifecycle policy. This module does not
do lazy loading, LRU eviction, cold-tier offload, or per-tenant
naming. Those are consumer concerns. The instance is started eagerly
via `bondy_oplog:start_instance/1,2`.

Anti-entropy and GC scheduling live in dedicated modules; they *use*
this one.

## Concurrency model

All operations currently round-trip the gen_server. Per-instance HLC
and Seq counters live in `atomics` cells inside the state record so
a future lock-free local-append path can move out of the gen_server
without protocol changes.
""").

%% An asynchronous compaction catch-up in flight (the cross-node
%% deadlock fix). Set when the `{compact}` handler hands the
%% remote-origin pairs to the applier via `catch_up_apply/3` and DEFERS
%% the truncate until the applier casts `{catch_up_done, Token}` back.
%% `remote_gen` is the value captured at step 1; if it has advanced by
%% step 2, a peer event slipped into the window and the truncate is
%% aborted (next tick recomputes). See `begin_async_catch_up/3`.
-record(pending_compaction, {
    frontier :: bondy_oplog_event:event_key(),
    remote_gen :: non_neg_integer(),
    token :: non_neg_integer(),
    started :: integer()
}).

%% Ephemeral fused-writer drain state (fused-writer rollout, Step 3).
%% Present only when `#state.fused`; the instance runs the WAL drain +
%% inline install itself (no applier). The `cell_apply_ctx` is built at
%% `init/1` (the core-registry entry exists before the instance starts);
%% the WAL `iter` is opened lazily in `handle_info(fused_init)` because
%% the WAL sibling publishes its pid only after this instance's init
%% returns. `consumer_offset` tracks the committed segment for WAL
%% retention; the ephemeral WAL needs no on-disk consumer.offset (a fresh
%% BEAM re-reads from `resume_position`). `idle_waiter` is a monitored
%% helper parked on the WAL durable position (the busy-spin-free wakeup,
%% identical to the applier's).
-record(fused_drain, {
    iter :: term() | undefined,
    cell_apply_ctx :: map() | undefined,
    %% Per-bucket apply-context source for the cell-apply mux, mirroring the
    %% applier's `cell_apply_source`. `{single, Ctx}` (one table per fused
    %% instance — today's default) routes every bucket to `Ctx`;
    %% `{dir, #{Bucket => Ctx}}` (a multiplexing per-shard fused instance)
    %% routes each bucket to its own table's ctx. Seeded at `maybe_init_fused/2`
    %% from `cell_apply_bucket`; extended at runtime via the instance's
    %% `register_table/4` / `unregister_table/2` calls. `cell_apply_ctx` above
    %% stays the founding ctx for the `cell_apply_ctx = undefined` guard clauses.
    cell_apply_source = {single, undefined} ::
        bondy_oplog_cell_apply:ctx_source(),
    consumer_offset :: term(),
    uncommitted = 0 :: non_neg_integer(),
    commit_every :: pos_integer(),
    apply_batch_max :: pos_integer(),
    idle_waiter = undefined :: undefined | reference(),
    %% Inline projection-replay cursor for the REMOTE path (Step 4). A
    %% fused instance has no applier, so it folds peer-merged events into
    %% the projection itself after `integrate_peer_root`. `undefined` →
    %% the next replay does a full fold; incremental thereafter. Mirrors
    %% the applier's `last_replayed_root` and is re-anchored on the
    %% post-truncate root by compaction (`finalize_catalogue_compaction`).
    last_replayed_root = undefined :: undefined | bondy_mst:hash(),
    %% AE-freshness shard keys bumped on every fused commit and after a
    %% remote replay, so secondary-index reads on those shards observe the
    %% fused writer's progress. Mirrors the applier's `ae_targets` (the
    %% applier bumps them in `commit_now`; the fused instance has no
    %% applier so it bumps them itself). Validated at `init/1`.
    ae_targets = [] :: list(),
    %% WAL storage backend for the drain READER (task #50, ephemeral ETS
    %% WAL). `disk` reads segment files via `bondy_oplog_wal_reader`; `mem`
    %% reads the in-memory `bondy_oplog_wal_mem` table via
    %% `bondy_oplog_wal_mem_reader`, dropping the durable-position visibility
    %% gate. Producer/await/commit are protocol-shared, so ONLY the reader
    %% is dispatched on this flag. Set once at `maybe_init_fused/2`.
    wal_backend = disk :: disk | mem,
    %% Consecutive times the mem drain stopped on an in-flight `Seq` gap (a
    %% concurrent lock-free `append_local` reserved a later Seq and inserted it
    %% first). A gap fills in microseconds, so we short-retry rather than park;
    %% this counter bounds that retry so a permanent gap (a writer killed in the
    %% ~50 ns window between reserving and inserting) is skipped instead of
    %% stalling the drain forever. Reset to 0 on any progress.
    gap_retries = 0 :: non_neg_integer()
}).

%% In-flight asynchronous pack-store seal (at most one — the in-flight=1 cap).
%% `pid`/`ref` are the monitored worker running `bondy_mst:run_seal_job/1`;
%% `token` is the self-contained seal job (kept for retries); `pack_id` is the
%% pack the worker is producing; `retries` counts failed attempts so far.
-record(seal, {
    pid :: pid(),
    ref :: reference(),
    token :: bondy_mst:seal_job(),
    pack_id :: pos_integer(),
    retries = 0 :: non_neg_integer()
}).

-record(state, {
    instance_id :: binary(),
    origin :: bondy_oplog_origin:t(),
    hlc :: bondy_oplog_hlc:t(),
    seq :: atomics:atomics_ref(),
    mst :: bondy_mst:t(),
    %% Per-root AAE-advertise servability cache: `{RootHash, Servable}`.
    %% `aae_root/1` (the responder's advertise path) refuses to advertise a
    %% dangling root — one whose pages are not all present, which would make
    %% a pulling peer fail with `peer_returned_empty_pages` — and instead
    %% advertises `undefined` so the peer pulls nothing from us and we heal
    %% via our own pull/replay. The check (`missing_set` on the live MST) is
    %% memoised per root hash so it re-walks (and re-logs) only when the
    %% root changes, never every sync round.
    aae_root_check :: undefined | {binary(), boolean()},
    %% Monotonic ms of the FIRST unservable aae-root verdict of the
    %% current unservable streak; reset the moment any root verifies
    %% servable. Persist across root changes: a tree whose missing
    %% pages sit in a shared subtree stays unservable through every new
    %% root, and the self-heal threshold must measure the streak, not
    %% the root. See `maybe_self_heal_unservable/2`.
    unservable_since = undefined :: undefined | integer(),
    %% Monotonic ms of the last durable (pack) page reclamation. See
    %% `maybe_collect_durable/1`.
    last_durable_gc = undefined :: undefined | integer(),
    backend :: backend(),
    validator_module :: module(),
    validator_state :: term(),
    %% Per-namespace fold strategy. The
    %% applier consumes WAL events and folds them into per-cell
    %% projection state via this module's callbacks. `undefined`
    %% means no fold is configured for the instance and the applier
    %% takes the legacy event-storage path. Stored as a resolved
    %% module name (shorthand atoms are validated and recorded
    %% verbatim — `mod_of/1` resolves at call time, so a config
    %% migration that changes a shorthand → module mapping is
    %% transparent on restart).
    fold_module :: module() | atom() | undefined,
    %% Opaque, fold-module-specific options. Passed to the fold
    %% module at applier-side initialisation (the behaviour callback
    %% `initial_value/0` is parameterless, so opts are consumed by
    %% the consumer wrapping the fold — see F8). Empty map by
    %% default.
    fold_opts :: map(),
    crdt_module :: module() | undefined,
    compaction_checkpoint :: module(),
    compaction_checkpoint_state :: term(),
    watermark :: undefined | bondy_oplog_event:event_key(),
    %% Cached `{Watermark, Checkpoint}` from the compaction checkpoint
    %% store so the registry can publish it without re-reading the
    %% store on every mutation. Refreshed on init, compact, and
    %% load_snapshot.
    cached_checkpoint :: undefined | {bondy_oplog_event:event_key(), term()},
    max_working_set :: pos_integer() | infinity,
    %% Cached size of the live MST (avoids a fold per append). Updated
    %% on every state-mutating handle_call.
    live_size :: non_neg_integer(),
    last_event_key :: undefined | bondy_oplog_event:event_key(),
    %% Cached per-instance WAL writer pid. Refreshed lazily from the
    %% registry on the first append after a `'DOWN'` from the previous
    %% writer (one_for_all restarts swap in a new pid).
    wal_pid :: undefined | pid(),
    %% Monitor reference for the cached `wal_pid`; cleared when the
    %% monitored process dies.
    wal_pid_monitor :: undefined | reference(),
    %% Per-instance overlay (`ordered_set`, public). Receives every
    %% successfully WAL-appended local event so callers reading back
    %% the key see the entry before the applier promotes it to the
    %% MST. Rows are `{Key, Value, Hlc, Origin}`; entries are evicted
    %% atomically with the MST insert via HLC-conditional
    %% `ets:select_delete/2`. Created in `init/1`, deleted in
    %% `terminate/2`; no heir.
    overlay :: undefined | ets:tid(),
    %% Overlay backpressure caps. `max_overlay_events` defaults to
    %% 10_000; `max_overlay_bytes` to 5 MB; `throttle_strategy`
    %% defaults to `drop` and is the only supported value
    %% (`block` reserved).
    max_overlay_events :: pos_integer(),
    max_overlay_bytes :: pos_integer(),
    overlay_throttle :: drop,
    %% Atomic mirrors of `ets:info(overlay, size)` and
    %% `ets:info(overlay, memory)`. Held as `atomics:atomics_ref()` so
    %% the lock-free `append_fast/2,3` path (caller-side) can update
    %% them without going through this gen_server. Slot 1: event
    %% count. Slot 2: byte estimate. Updated on insert
    %% (`stage_to_overlay/2`) and evict (`evict_overlay_batch/2`).
    %% With `decentralized_counters: true` on the overlay table, the
    %% equivalent `ets:info/2` calls aggregate across all schedulers
    %% and grow expensive under concurrent appenders — these atomic
    %% mirrors keep the admit check purely lock-free and constant-time.
    overlay_counters :: atomics:atomics_ref(),
    %% Highest local-origin `seq` already installed into the MST.
    %% Used by `install_local_batch/2` to skip the
    %% O(log N) `bondy_mst:get/2` safety probe for events whose seq is
    %% strictly greater than this value — for the local origin the seq
    %% atomic monotonically increases, so any event with a higher seq
    %% cannot already be in the tree. Resume-overlap events (seq ≤ max)
    %% still take the safe path that probes the tree.
    max_local_installed_seq :: non_neg_integer(),
    %% Callers blocked in `await_apply/1,2` while the overlay is
    %% non-empty. Each install path that may shrink the overlay
    %% (`install_local_batch` cast, `install_remote` call, and the
    %% applier's `check_drain_waiters` rejection hint) calls
    %% `maybe_signal_drain_waiters/1` which `gen_server:reply`-s every
    %% queued From the moment the overlay reaches 0.
    drain_waiters = [] :: [gen_server:from()],
    %% Demand-based applier→instance flow control. The applier
    %% increments slot 1 of `install_in_flight` before dispatching an
    %% `install_local_batch` cast; this handler decrements it after
    %% the cast is processed. When the post-decrement value is
    %% `max_install_in_flight - 1` (i.e. just freed a slot from a
    %% saturated counter), the instance sends a `drain_resume` cast
    %% to the applier so it can read the next WAL batch. Bounds the
    %% instance's mailbox at `cap × batch_size` events. Default `64`:
    %% the disambiguation sweep (2026-06-11) showed the applier stalls
    %% on the in-flight cap well before any other limiter — 16→64 is
    %% +47% single-shard (7,358→10,841) for both ephemeral and durable,
    %% saturating at ~64 (the residual floor is the per-hop cast
    %% round-trip latency itself). Worst-case backlog is
    %% `cap × apply_batch_max_events` = 64 × 256 ≈ 16k events; instance
    %% coalescing (`install_coalesce_max`) keeps the steady state far
    %% below that.
    install_in_flight :: atomics:atomics_ref() | undefined,
    max_install_in_flight :: pos_integer(),
    %% Remote-delivery generation shared with the applier's prepare
    %% fence (I1). Bumped at the END of every `integrate_peer_root`
    %% handler (the local delivery point of peer-merged events);
    %% published via `bondy_oplog_registry:set_remote_gen/2` at init.
    remote_gen_ref :: atomics:atomics_ref() | undefined,
    %% A4 — instance-side install coalescing. The
    %% `install_local_batch` cast handler drains up to this many *queued*
    %% install casts (including the one being handled) and merges their
    %% events into a single `bondy_mst:put_batch/2` + one publish + one
    %% overlay-evict. When the applier outruns the instance the mailbox
    %% accumulates casts, so this amortises the O(log n) spine rebuild
    %% over many casts' worth of events — the dominant per-event durable
    %% cost (A0b). `1` reproduces the pre-A4 one-put_batch-per-cast
    %% behaviour. Bounded by `max_install_in_flight` in practice (the
    %% applier cannot have more than that many casts in flight).
    install_coalesce_max :: pos_integer(),
    %% Bootstrap lifecycle (`bondy_oplog_bootstrap_lifecycle`). Opened
    %% at `init/1` and published via the registry so the applier can
    %% gate its WAL drain on the durable two-state machine
    %% (`pre_bootstrap | live`).
    lifecycle :: bondy_oplog_bootstrap_lifecycle:handle(),
    %% Set when a peer-merged (remote) event has entered the MST since the
    %% last catalogue compaction. ONLY remote events need the pre-truncate
    %% projection catch-up (`begin_async_catch_up/3`): local events are
    %% written to the projection by the applier's WAL-drain path before
    %% their MST install, so they are always already materialised. When this
    %% is `false` the catch-up is skipped entirely and the compaction
    %% commits the truncate inline. When `true` the truncate is deferred
    %% behind the applier's `catch_up_apply/3` fold (the cross-node deadlock
    %% fix). Set in the `integrate_peer_root` handler; cleared on a
    %% successful truncate in `finalize_catalogue_compaction/3`.
    remote_events_pending = false :: boolean(),
    %% "Does a projection materialise this instance's state?" — i.e. the
    %% applier is configured with a `cell_apply_target` (every `bondy_db`
    %% table). An IMMUTABLE property, set at THIS instance's `init/1` from
    %% the same opts the supervisor uses to start the applier
    %% (`Opts.applier.cell_apply_target`), so the compaction handler NEVER
    %% asks the applier. Asking it (a synchronous `cell_apply_target` call)
    %% deadlocks against the applier's own synchronous `drain_install_queue`
    %% call (`commit_now/1`) whenever a compaction overlaps a commit — and
    %% under batched / high-throughput load that overlap hits on the FIRST
    %% compaction, before any low-load warmup window (the freeze that broke
    %% multi-shard batched-fsync runs). See `resolve_has_projection/1`.
    has_projection = false :: boolean(),
    %% Peer roots pinned by in-flight sync sessions (root → pinned-at,
    %% monotonic ms). The ETS page GC keeps everything reachable from
    %% these roots so a multi-round pull's earlier pages survive the
    %% concurrent compaction cycles that run while later rounds are
    %% still fetching. See `pin_peer_root/2` / `?PEER_ROOT_PIN_TTL_MS`.
    pinned_peer_roots = #{} :: #{binary() => integer()},
    %% Monotonic counter bumped every time a peer-merged event enters the
    %% MST (`integrate_peer_root`). Captured at the start of an async
    %% compaction catch-up and re-checked at the truncate so a peer event
    %% arriving mid-catch-up aborts (and defers) the truncate rather than
    %% dropping an un-folded event. See `pending_compaction`.
    remote_gen = 0 :: non_neg_integer(),
    %% The in-flight async compaction catch-up, or `undefined`. While set,
    %% the `{compact}` handler skips (one catch-up per instance at a time).
    pending_compaction = undefined :: undefined | #pending_compaction{},
    %% Token source disambiguating a `{catch_up_done, _}` / compaction
    %% watchdog from a superseded cycle.
    compaction_token = 0 :: non_neg_integer(),
    %% Cached namespace of this instance's `bondy_db` table, used by the
    %% compaction flush barrier (`drive_secondary_indexes/1`) to locate the
    %% table's secondary-index writers via the registry. Resolved lazily on
    %% the first catalogue compaction by scanning the registry for the
    %% primary-shard entry carrying THIS `instance_id` (read-only ETS, so
    %% deadlock-free — never an applier call). `unresolved` until then; then
    %% the NS atom, or `none` when this instance has no `bondy_db` primary
    %% registry entry (a bare-oplog instance). Only catalogue
    %% (projection-backed) instances reach the resolver.
    secondary_index_ns = unresolved :: atom(),
    %% Ephemeral fused-writer flag. `true` only for ephemeral (ets
    %% projection) instances that opt into the single-process write
    %% path where the applier's `cell_apply` and this instance's MST
    %% install are fused — eliminating the applier↔instance install
    %% round-trip (H1) that caps single-shard ephemeral throughput.
    %% Set once at `init/1` from `Opts.fused`; published to the
    %% registry so the fused writer can read it. Nothing reads it for
    %% behaviour yet — the durable two-process pipeline is unaffected.
    %% The `fused ⇒ ephemeral` invariant is enforced at `open_table`.
    fused = false :: boolean(),
    %% MST retention policy for ephemeral catalogue (fused) instances
    %% (opt `mst_retention` — distinct from the WAL's segment-retention
    %% `retention` proplist): `#{max_age_ms => A, max_events => N}` (`0`
    %% disables a knob) or `undefined` (stability-driven compaction only —
    %% every durable instance). When set, `run_compaction` falls back to a LOCAL
    %% retention frontier whenever the peer-confirmed frontier yields
    %% nothing: the MST is bounded by policy, not by all-peer stability.
    %% Sound only for an ephemeral projection-backed instance — the
    %% projection holds all applied state and a peer that misses
    %% truncated history recovers via catalogue bootstrap (the
    %% `peer_pages_unavailable` / `frontier_gap` → rebootstrap path in
    %% `bondy_oplog_sync_scheduler`). Requires `fused` (⇒ ephemeral, per
    %% `bondy_db:assert_fused_requires_ephemeral/2`); enforced at
    %% `init/1` via `validate_retention/2`.
    retention ::
        #{
            max_age_ms := non_neg_integer(),
            max_events := non_neg_integer()
        }
        | undefined,
    %% Fused-writer drain state, or `undefined` for every non-fused
    %% (durable + non-fused ephemeral) instance. See `#fused_drain{}`.
    fused_drain = undefined :: undefined | #fused_drain{},
    %% tier_2 stamp-site context-regression guard — see
    %% `bondy_oplog_ctx_guard`. Only ever populated for a fused instance
    %% (a non-fused instance's applier holds its own copy); `undefined`
    %% for every non-fused instance.
    ctx_guard = bondy_oplog_ctx_guard:new() :: bondy_oplog_ctx_guard:guard(),
    %% Async pack-store seal driver. `drive_seal` is true only when the
    %% durable backend was opened with `seal_mode => async`; then the
    %% instance rolls the incoming pack at the commit barrier
    %% (`maybe_drive_seal/1`) and seals it in a monitored worker, keeping
    %% the multi-hundred-ms rewrite off the install/commit critical path.
    %% `seal` holds the single in-flight seal (the in-flight=1 backpressure
    %% cap), `undefined` when none is running. With `seal_mode => sync`
    %% (the default) `drive_seal` is false and the store auto-seals inline
    %% on `put` exactly as before — zero behavioural change.
    drive_seal = false :: boolean(),
    seal = undefined :: undefined | #seal{},
    %% Periodic heap-monitor state (see `bondy_oplog_heap_monitor`). A
    %% long-lived instance accumulates transient apply/AAE garbage that the
    %% BEAM does not return until a fullsweep; under a solo import (no peers)
    %% the AAE-driven hibernate never fires, so the heap climbs unbounded
    %% until the next major GC. The monitor periodically fullsweep-hibernates
    %% the instance once its heap has grown past a threshold over its post-GC
    %% baseline, capping the transient peak without touching the hot
    %% append/drain path. Driven from `handle_info(gc_tick, _)`.
    heap_monitor = bondy_oplog_heap_monitor:new() ::
        bondy_oplog_heap_monitor:t()
}).

-type backend() :: map | ets | module().

-type opts() :: #{
    backend => backend(),
    backend_options => map() | list(),
    storage_path => binary(),
    path_layout => bondy_oplog_path:layout(),
    hash_algorithm => sha256 | sha512,
    origin => bondy_oplog_origin:t(),
    hlc_seed => non_neg_integer(),
    seq_seed => non_neg_integer(),
    validator => module(),
    validator_opts => map(),
    %% Per-table CRDT, named by a `fold_module` label for backward
    %% compatibility. Resolves to its native `bondy_oplog_crdt` twin via
    %% `bondy_oplog_cell_kernel:default_crdt_for_fold/1`: a
    %% shorthand atom (`lww_register`, `g_counter`, `pn_counter`, `g_set`,
    %% `max_register`, `min_register`, `index_entry`), the fully-qualified
    %% `bondy_oplog_fold_*` form, or a native `bondy_oplog_crdt_*` module
    %% directly. A label with no twin is rejected (validated at instance
    %% start; a misconfigured value crashes init). Prefer `crdt_module`
    %% for new tables.
    fold_module => atom(),
    %% Opaque options passed through; shape is consumer-specific,
    %% defaults to `#{}`.
    fold_opts => map(),
    crdt_module => module(),
    compaction_checkpoint => module(),
    compaction_checkpoint_opts => map(),
    max_working_set => pos_integer() | infinity,
    %% Overlay backpressure caps. Either threshold triggers
    %% `{error, backpressure}` from `append/2,3` and `append_many/2`.
    max_overlay_events => pos_integer(),
    max_overlay_bytes => pos_integer(),
    %% Throttle strategy on overlay-cap breach. `drop` returns
    %% `{error, backpressure}` immediately; `block` is reserved for a
    %% follow-on PR and currently behaves like `drop`.
    overlay_throttle => drop,
    %% A4 — max number of queued `install_local_batch` casts the
    %% instance coalesces into one MST `put_batch` (default 16; `1`
    %% disables coalescing). See the `install_coalesce_max` state field.
    install_coalesce_max => pos_integer(),
    %% Per-instance applier tuning. See `bondy_oplog_applier:opts/0`.
    %% Recognised keys:
    %%   commit_every     :: pos_integer()   (default 64)
    %%   poll_interval_ms :: pos_integer()   (default 5)
    applier => #{
        commit_every => pos_integer(),
        poll_interval_ms => pos_integer()
    },
    %% Bootstrap lifecycle seed. `true` declares the instance as a
    %% genesis peer in a fresh cluster (no peer to bootstrap from); the
    %% lifecycle starts `live` and, if `storage_path` is set, the
    %% durable `lifecycle.live` flag file is written so the next
    %% restart sees `live` without needing the seed opt again. `false`
    %% (default for persistent instances) keeps the lifecycle in
    %% `pre_bootstrap` until `bondy_oplog_sync_session:bootstrap/3`
    %% completes against a live peer. Ephemeral instances (no
    %% `storage_path`) default to `live` regardless of `seed` —
    %% there is no persistent state to bootstrap from.
    seed => boolean()
}.

-export_type([opts/0]).
-export_type([backend/0]).

%% Lifecycle
-export([start_link/2]).
-export([child_spec/2]).
-export([stop/1]).

%% Public API (typically called via `bondy_oplog`)
-export([append/2]).
-export([append/3]).
-export([append_fast/3]).
-export([append_many/2]).
-export([append_many_fast/2]).
-export([append_remote/2]).
-export([await_apply/1]).
-export([await_apply/2]).
-export([get/2]).
-export([root_hash/1]).
-export([aae_root/1]).
-export([diagnose_root/1]).
-export([gc_aborts/0]).
-export([gc_aborts/1]).
-export([frontier/1]).
-export([fold_range/5]).
-export([range/3]).
-export([truncate_prefix/2]).
-export([size/1]).
-export([first_key/1]).
-export([latest_key/1]).
-export([mst_last/1]).
-export([origin/1]).
-export([info/1]).

%% Applier handshake — applier reads `{validator_module, validator_state}`
%% once at its `init/1` so it can re-verify signatures (S1) in its own
%% process before dispatching events to the instance.
-export([get_validator/1]).
-export([cell_directory/1]).
-export([replay_pairs/2]).

%% Operator-facing trigger that asks the applier to refresh its
%% validator snapshot by calling the optional
%% `bondy_oplog_validator:refresh/1` callback.
-export([refresh_validator/1, refresh_validator/2]).
-export([reap_origins/2]).
-export([cell_context/3]).
-export([sweep_stable_cells/3]).
-export([cell_apply_target/1]).
-export([rebuild_indexes_sync/1]).

%% Page-level API (sync protocol)
-export([get_pages/2]).
-export([merge_pages/2]).
-export([missing_set/2]).
-export([integrate_peer_root/2]).
-export([pin_peer_root/2]).

%% GC / compaction API
-export([current_watermark/1]).
-export([crdt_module/1]).
-export([compaction_checkpoint/1]).
-export([compact/2]).

%% Bootstrap
-export([load_snapshot/3]).
-export([mark_live/1]).
-export([lifecycle_state/1]).
-export([install_catalogue_batch/2]).
-export([rederive_projection/1]).
-export([finalize_catalogue_bootstrap/3]).
-export([finalize_catalogue_bootstrap/4]).
-export([finalize_catalogue_bootstrap/5]).
-export([persist_frontier/1]).
-export([reclamation_members/0]).
-export([reclaim_stable_cells/1]).
-export([stability_point/1]).
-export([register_table/4]).
-export([unregister_table/2]).
-export([open_drain_gate/1]).

%% Registry helpers
-export([whereis/1]).
-export([lookup_origin/1]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-ifdef(TEST).
%% Exposed for the stability-frontier equivalence test.
-export([compute_frontier_for/2]).
%% Exposed for the non-event-frontier outcome test (Step 3, reclamation).
-export([frontier_stability_point/1]).
%% Exposed for the catch-up remote-origin filter test.
-export([remote_pairs/2]).
%% Exposed for the pack-store seal-threshold default test.
-export([backend_opts/3]).
-endif.

%% =============================================================================
%% LIFECYCLE
%% =============================================================================

-spec start_link(instance_id(), opts()) ->
    {ok, pid()} | {error, term()}.

start_link(InstanceId, Opts) when
    is_binary(InstanceId), is_map(Opts)
->
    gen_server:start_link(?MODULE, {InstanceId, Opts}, []).

-spec child_spec(instance_id(), opts()) -> supervisor:child_spec().

child_spec(InstanceId, Opts) ->
    #{
        id => {?MODULE, InstanceId},
        start => {?MODULE, start_link, [InstanceId, Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

-spec stop(instance_id() | pid()) -> ok.

stop(Target) ->
    gen_server:stop(target(Target)).

%% =============================================================================
%% API
%% =============================================================================

-spec append(instance_id() | pid(), bondy_oplog_event:op()) ->
    bondy_oplog_event:event_key().

append(Target, Op) ->
    append(Target, Op, undefined).

-spec append(
    instance_id() | pid(),
    bondy_oplog_event:op(),
    bondy_oplog_event:meta()
) -> bondy_oplog_event:event_key().

append(Target, Op, Meta) ->
    gen_server:call(target(Target), {append, Op, Meta}, infinity).

?DOC("""
Lock-free single-event append for instances whose validator is
stateless (advertises `bondy_oplog_validator:is_stateless/0 -> true`).
Builds the event in the caller's process, calls the WAL gen_server
directly, and stages the overlay row inline — skipping the instance
gen_server hop entirely.

Returns the assigned `event_key()` on success, `{error, backpressure}`
or `{error, working_set_full}` if backpressure caps would be
breached, and `{error, wal_unavailable}` if the WAL is mid-restart.

Callers should not use this directly; route through
`bondy_oplog:append/2,3`, which checks fast-path eligibility from
the registry and falls back to the gen_server when ineligible.
""").
-spec append_fast(
    instance_id(),
    bondy_oplog_event:op(),
    bondy_oplog_event:meta()
) -> bondy_oplog_event:event_key() | {error, term()}.

append_fast(InstanceId, Op, Meta) when is_binary(InstanceId) ->
    case bondy_oplog_registry:fast_path(InstanceId) of
        undefined ->
            %% Fast path was disabled or torn down — fall back.
            append(InstanceId, Op, Meta);
        FastPath ->
            do_append_fast(InstanceId, FastPath, Op, Meta)
    end.

%% @private
do_append_fast(InstanceId, FastPath, Op, Meta) ->
    #{
        hlc := HLC,
        seq := SeqRef,
        overlay_counters := Ctrs,
        origin := Origin,
        validator_module := ValidatorMod,
        validator_state := ValidatorState,
        max_overlay_events := MaxEvents,
        max_overlay_bytes := MaxBytes,
        max_working_set := MaxWorkingSet
    } = FastPath,
    case fast_admit(InstanceId, Ctrs, MaxEvents, MaxBytes, MaxWorkingSet, 1) of
        ok ->
            %% Build the event in the caller's process. The HLC + seq
            %% atomics give us a unique, monotonic key without holding
            %% the instance gen_server.
            Hlc = bondy_oplog_hlc:now(HLC),
            Seq = atomics:add_get(SeqRef, 1, 1),
            Key = bondy_oplog_event:key(Hlc, Origin, Seq),
            Event0 = bondy_oplog_event:new(Key, Op, Meta),
            %% Stateless validator: discard the returned state — by
            %% contract it equals the cached one.
            {Event, _} = ValidatorMod:sign_event(Event0, ValidatorState),
            %% Resolve the overlay tid up-front. It can briefly be
            %% `undefined` after a one_for_all restart before the new
            %% instance's init/1 republishes it; in that window we fall
            %% back to the gen_server path which builds its own event.
            case bondy_oplog_registry:overlay_tab(InstanceId) of
                undefined ->
                    append(InstanceId, Op, Meta);
                Tab ->
                    %% Stage the overlay row BEFORE the WAL append. See
                    %% the matching comment in `do_append_local/3` —
                    %% the applier reads from the WAL the instant it
                    %% becomes durable, and an in-flight overlay insert
                    %% races with `evict_overlay_batch/2`.
                    case stage_overlay_rows(Tab, [overlay_row(Event, local)]) of
                        stale ->
                            append(InstanceId, Op, Meta);
                        ok ->
                            overlay_counters_add(Ctrs, [Event]),
                            case fast_wal_append_batch(InstanceId, [Event]) of
                                ok ->
                                    telemetry:execute(
                                        [bondy_oplog, instance, append],
                                        #{count => 1},
                                        #{instance_id => InstanceId}
                                    ),
                                    Key;
                                {error, _} = Err ->
                                    %% WAL rejected the batch — drop the
                                    %% staged row so no phantom write is
                                    %% observable, and return the seq so the
                                    %% origin's sequence stays gap-free.
                                    ok = unstage_overlay_rows(
                                        Tab, Ctrs, [Event]
                                    ),
                                    ok = release_seq_range(
                                        SeqRef, InstanceId, [Key]
                                    ),
                                    Err
                            end
                    end
            end;
        {error, _} = Err ->
            Err
    end.

?DOC("""
Lock-free batch append. Same eligibility as `append_fast/3`: the
instance's validator must advertise `is_stateless/0 -> true`. The
caller mints every event's `{HLC, Origin, Seq}` key, signs each
event in-process, ships the whole batch through the WAL as one
atomic frame, inserts every overlay row in a single `ets:insert/2`,
and bumps the overlay-counters atomics once.

The WAL's `append_batch/2` is all-or-nothing: either every event
becomes durable or the entire batch is rejected. The fast path
inherits that semantic — on `{error, _}` no overlay row is written
and the caller can retry. The rejected batch's seq range is returned
to the counter when it is still the topmost reservation
(`release_seq_range/3`), keeping each origin's sequence gap-free —
per-origin contiguity is what makes a max-Seq frontier readable as
an applied prefix and what the cell-apply contiguity detector
(`bondy_oplog_cell_apply`) measures. A range overtaken by a
concurrent reservation cannot be returned and is counted by the
`[bondy_oplog, instance, seq_burned]` telemetry event. HLCs are
never recycled.

Returns the assigned `event_key()` list in input order, or
`{error, backpressure | working_set_full | wal_unavailable | _}`.

Routed through automatically by `bondy_oplog:append_many/2` when
the registry exposes a fast-path bundle; the consumer-facing API
stays unchanged.
""").
-spec append_many_fast(
    instance_id(),
    [{bondy_oplog_event:op(), bondy_oplog_event:meta()}]
) -> [bondy_oplog_event:event_key()] | {error, term()}.

append_many_fast(_InstanceId, []) ->
    [];
append_many_fast(InstanceId, Items) when
    is_binary(InstanceId), is_list(Items)
->
    case bondy_oplog_registry:fast_path(InstanceId) of
        undefined ->
            %% Stateful validator or fast-path torn down — defer to
            %% the gen_server path which threads validator state
            %% through the batch.
            append_many(InstanceId, Items);
        FastPath ->
            do_append_many_fast(InstanceId, FastPath, Items)
    end.

%% @private
do_append_many_fast(InstanceId, FastPath, Items) ->
    #{
        hlc := HLC,
        seq := SeqRef,
        overlay_counters := Ctrs,
        origin := Origin,
        validator_module := ValidatorMod,
        validator_state := ValidatorState,
        max_overlay_events := MaxEvents,
        max_overlay_bytes := MaxBytes,
        max_working_set := MaxWorkingSet
    } = FastPath,
    Delta = length(Items),
    case
        fast_admit(InstanceId, Ctrs, MaxEvents, MaxBytes, MaxWorkingSet, Delta)
    of
        ok ->
            %% Stateless validator by fast-path contract: discard the
            %% returned validator state.
            {Events, Keys, _} = do_build_events(
                HLC, SeqRef, Origin, ValidatorMod, ValidatorState, Items
            ),
            %% Resolve the overlay tid up-front; the rare `undefined`
            %% window after a one_for_all restart routes through the
            %% gen_server which mints its own keys.
            case bondy_oplog_registry:overlay_tab(InstanceId) of
                undefined ->
                    append_many(InstanceId, Items);
                Tab ->
                    %% Stage overlay rows BEFORE the WAL append (see
                    %% the matching comment on `do_append_local/3`).
                    Rows = [overlay_row(E, local) || E <- Events],
                    case stage_overlay_rows(Tab, Rows) of
                        stale ->
                            append_many(InstanceId, Items);
                        ok ->
                            overlay_counters_add(Ctrs, Events),
                            case fast_wal_append_batch(InstanceId, Events) of
                                ok ->
                                    telemetry:execute(
                                        [bondy_oplog, instance, append],
                                        #{count => Delta},
                                        #{instance_id => InstanceId}
                                    ),
                                    Keys;
                                {error, _} = Err ->
                                    %% Roll back the staged rows and return the
                                    %% seq range so the origin's sequence stays
                                    %% gap-free.
                                    ok = unstage_overlay_rows(
                                        Tab, Ctrs, Events
                                    ),
                                    ok = release_seq_range(
                                        SeqRef, InstanceId, Keys
                                    ),
                                    Err
                            end
                    end
            end;
        {error, _} = Err ->
            Err
    end.

%% @private
%% Mints signed events for every item — the single minting core behind
%% both the lock-free caller-side paths and the gen_server's
%% `build_events/2`.
%%
%% - One HLC tick per item: the WAL's `do_append_batch/2` rejects
%%   a batch whose HLCs are not strictly increasing (so receivers
%%   can rely on per-batch monotonicity for cheap merge-by-HLC).
%%   Each `bondy_oplog_hlc:now/1` is a lock-free CAS that already
%%   guarantees strict monotonicity at the per-replica level.
%% - **One** `atomics:add_get/3` to reserve a contiguous seq range,
%%   then assign each event `Start+i`. N - 1 fewer atomic
%%   read-modify-writes on the shared seq atomics per batch — and,
%%   as importantly, no concurrent minter can land INSIDE the batch's
%%   range, which is what makes `release_seq_range/3` safe to call
%%   when the WAL rejects the batch.
%%
%% Threads the validator state and returns it; stateless validators
%% (the fast-path eligibility contract) return it unchanged and the
%% fast paths discard it.
do_build_events(HLC, SeqRef, Origin, Mod, VS0, Items) ->
    N = length(Items),
    EndSeq = atomics:add_get(SeqRef, 1, N),
    StartSeq = EndSeq - N + 1,
    do_build_events_at(HLC, StartSeq, Origin, Mod, VS0, Items).

%% @private
%% The minting fold behind `do_build_events/6` (which reserves its seq
%% range) and `build_fill_events/3` (which re-mints over an
%% already-burned range): one HLC tick per item, keys assigned
%% `StartSeq + i`, each event signed through the validator with the
%% state threaded forward.
do_build_events_at(HLC, StartSeq, Origin, Mod, VS0, Items) ->
    {EventsRev, KeysRev, _, VS} = lists:foldl(
        fun({Op, Meta}, {EvAcc, KAcc, Seq, VSAcc0}) ->
            Hlc = bondy_oplog_hlc:now(HLC),
            Key = bondy_oplog_event:key(Hlc, Origin, Seq),
            Event0 = bondy_oplog_event:new(Key, Op, Meta),
            {Event, VSAcc} = Mod:sign_event(Event0, VSAcc0),
            {[Event | EvAcc], [Key | KAcc], Seq + 1, VSAcc}
        end,
        {[], [], StartSeq, VS0},
        Items
    ),
    {lists:reverse(EventsRev), lists:reverse(KeysRev), VS}.

%% @private
%% Returns a rejected batch's seq range `[Start, End]` to the counter,
%% keeping the origin's sequence gap-free. Safe exactly when the range
%% is still the TOPMOST reservation (counter =:= End): the range was
%% reserved in one `atomics:add_get/3`, so no foreign seq can sit
%% inside it, and the CAS fails whenever a concurrent minter has
%% reserved on top — in which case the range cannot be returned. A
%% burned range would otherwise be a hole no replica can ever fill by
%% sync (the prefix hold would park every peer on it until a
%% rebootstrap), so the burn is counted via telemetry and the instance
%% is asked to BACKFILL it with signed `seq_fill` no-op events
%% (`fill_burned_seqs/4`): they occupy the burned seqs, fold to
%% nothing, and advance every replica's applied frontier past the gap.
release_seq_range(_SeqRef, _InstanceId, []) ->
    ok;
release_seq_range(SeqRef, InstanceId, [First | _] = Keys) ->
    Start = bondy_oplog_event:key_seq(First),
    End = bondy_oplog_event:key_seq(lists:last(Keys)),
    case atomics:compare_exchange(SeqRef, 1, End, Start - 1) of
        ok ->
            ok;
        _Overtaken ->
            telemetry:execute(
                [bondy_oplog, instance, seq_burned],
                #{count => End - Start + 1},
                #{instance_id => InstanceId}
            ),
            request_seq_fill(InstanceId, Start, End)
    end.

%% @private
%% Asks the instance gen_server to backfill a burned seq range. Runs on
%% whichever process detected the burn (a fast-path caller or the
%% instance itself); the cast serialises the fill through the instance,
%% which owns the HLC and validator state needed to mint. A missing
%% registry row (subtree restarting) drops the request — the burn stays
%% counted and the gap falls back to the peers' rebootstrap repair.
request_seq_fill(InstanceId, Start, End) ->
    case bondy_oplog_registry:instance_pid(InstanceId) of
        undefined ->
            ok;
        Pid ->
            gen_server:cast(Pid, {fill_burned_seqs, Start, End, 0})
    end.

%% @private
%% Lock-free analogue of `admit/2` for the fast path. The atomics
%% counters can be transiently over-read because reads and writes are
%% not serialised across slot 1/slot 2 — backpressure is best-effort.
fast_admit(InstanceId, Ctrs, MaxEvents, MaxBytes, MaxWorkingSet, Delta) ->
    Size = atomics:get(Ctrs, 1),
    Bytes = atomics:get(Ctrs, 2),
    case Size + Delta > MaxEvents of
        true ->
            emit_overlay_backpressure(
                InstanceId, events, Size, MaxEvents, Delta
            ),
            {error, backpressure};
        false ->
            case Bytes >= MaxBytes of
                true ->
                    emit_overlay_backpressure(
                        InstanceId, bytes, Bytes, MaxBytes, Delta
                    ),
                    {error, backpressure};
                false ->
                    fast_working_set_admit(
                        InstanceId, Size, MaxWorkingSet, Delta
                    )
            end
    end.

%% @private
fast_working_set_admit(_InstanceId, _Size, infinity, _Delta) ->
    ok;
fast_working_set_admit(InstanceId, OverlaySize, Cap, Delta) ->
    LiveSize =
        case bondy_oplog_registry:live_size(InstanceId) of
            undefined -> 0;
            N -> N
        end,
    Total = LiveSize + OverlaySize,
    case Total + Delta =< Cap of
        true ->
            ok;
        false ->
            telemetry:execute(
                [bondy_oplog, instance, backpressure],
                #{count => 1},
                #{
                    instance_id => InstanceId,
                    requested => Delta,
                    live_size => LiveSize,
                    overlay_size => OverlaySize,
                    cap => Cap
                }
            ),
            {error, working_set_full}
    end.

%% @private
%% Resolves the per-instance WAL pid and calls `append_batch/2`. The
%% pid can be `undefined` for a window during init or after a
%% one_for_all subtree restart; in either case return
%% `{error, wal_unavailable}` so the caller can fall back to the
%% instance gen_server path (which has `ensure_wal_pid/1` retry).
fast_wal_append_batch(InstanceId, Events) ->
    case bondy_oplog_registry:wal_handle(InstanceId) of
        #{backend := mem} = Handle ->
            %% Ephemeral mem WAL: append lock-free, caller-side — no
            %% `gen_server:call`. `badarg` means the table vanished (WAL died);
            %% treat it as unavailable so the caller drops the staged overlay
            %% row, exactly as a disk `{error, _}` would.
            try bondy_oplog_wal_mem:append_local(Handle, Events) of
                {ok, _Entries} -> ok;
                {error, _} = Err -> Err
            catch
                error:badarg -> {error, wal_unavailable}
            end;
        _ ->
            fast_wal_append_batch_disk(InstanceId, Events)
    end.

%% @private
fast_wal_append_batch_disk(InstanceId, Events) ->
    case bondy_oplog_registry:wal_pid(InstanceId) of
        undefined ->
            {error, wal_unavailable};
        WalPid ->
            wal_append_batch(WalPid, Events)
    end.

%% @private
%% One disk-WAL batch append with the writer-death exits normalised to
%% `{error, wal_unavailable}` — shared by the caller-side fast path
%% (registry-resolved pid) and the gen_server's `do_append_local/3`
%% (cached, monitored pid).
wal_append_batch(WalPid, Events) ->
    try bondy_oplog_wal:append_batch(WalPid, Events) of
        {ok, _Entries} -> ok;
        {error, _} = Err -> Err
    catch
        exit:{noproc, _} -> {error, wal_unavailable};
        exit:noproc -> {error, wal_unavailable};
        exit:{normal, _} -> {error, wal_unavailable};
        exit:{shutdown, _} -> {error, wal_unavailable}
    end.

?DOC("""
Appends a batch of operations atomically (all-or-nothing within the
instance). Returns the assigned keys in input order.
""").
-spec append_many(
    instance_id() | pid(),
    [{bondy_oplog_event:op(), bondy_oplog_event:meta()}]
) -> [bondy_oplog_event:event_key()].

append_many(_Target, []) ->
    [];
append_many(Target, OpsAndMetas) when is_list(OpsAndMetas) ->
    gen_server:call(target(Target), {append_many, OpsAndMetas}, infinity).

?DOC("""
Inserts an event received from a peer. Idempotent. Validation runs in
the caller's process: an Origin matching the instance's local Origin
raises `error/1` without disturbing the instance gen_server. The
configured validator's `verify_event/2` runs in the per-instance
applier process, which then forwards the verified event to the
instance for origin-ban / backpressure / watermark filtering and the
MST install. The applier is therefore the sole verify+dispatch origin
for both locally appended and peer-received events.

An accepted fresh event is DELIVERED, not merely installed: on a
fused instance the projection reflects it when this call returns; on
an applier-backed instance the applier replay is cast and the I1
prepare fence bumped, so a projection read behind the applier barrier
observes it — no AE round required. The watermark filter drops an
at-or-below-watermark event only when the applied VV witnesses it as
already folded here (or the instance has no projection); a
never-applied event below the watermark is accepted and delivered
like any other (the live-event watermark door).

**Pass an `instance_id()` (binary)** for hot-path callers. The binary
form resolves origin and applier pid via lock-free registry reads
before issuing the verify call. The `pid()` form is supported for
test/internal convenience only: it pays two extra `gen_server:call`
round trips (origin lookup, then instance-id reverse lookup) before
the verify call begins.
""").
-spec append_remote(instance_id() | pid(), bondy_oplog_event:t()) ->
    ok | {error, term()}.

append_remote(Target, Event) ->
    Key = bondy_oplog_event:key(Event),
    PeerOrigin = bondy_oplog_event:key_origin(Key),

    %% Observation only -- see `bondy_oplog_clock_skew`. The event is routed
    %% and applied unchanged whatever this reports: clamping the merge would
    %% negate `peer_next_gt_peer` in `proofs/isabelle/Hlc.thy` and with it
    %% hypothesis H3, and rejecting the event against a LOCAL wall clock is
    %% not a decision every replica makes identically, so it would diverge.
    %% This is the single ingress for remote events, so one seat covers both
    %% the fused and applier routes.
    ok = report_clock_skew(Key, PeerOrigin),

    case lookup_origin(Target) of
        {ok, PeerOrigin} ->
            error({remote_event_with_local_origin, PeerOrigin});
        _ ->
            case resolve_remote_route(Target) of
                {fused, InstancePid} ->
                    %% Fused (no applier): the instance verifies and
                    %% installs the remote event itself (Step 4). It still
                    %% offloads the verify to a spawned worker (the
                    %% bondy_mst_crdt model — serialise writes, keep verify
                    %% concurrent) so the drain is not blocked on it.
                    gen_server:call(
                        InstancePid, {enqueue_remote, Event}, infinity
                    );
                {applier, ApplierPid} ->
                    bondy_oplog_applier:enqueue_remote(ApplierPid, Event);
                {error, _} = Err ->
                    Err
            end
    end.

%% @private
%% Resolves where a remote event for `Target` (instance id or pid) is
%% verified+installed: a fused instance does it itself (no applier process);
%% every other instance routes to its applier's `enqueue_remote`.
resolve_remote_route(Target) ->
    case to_instance_id(Target) of
        {ok, Id} ->
            case bondy_oplog_registry:fused(Id) of
                true ->
                    case bondy_oplog_registry:instance_pid(Id) of
                        undefined -> {error, instance_unavailable};
                        Pid when is_pid(Pid) -> {fused, Pid}
                    end;
                _ ->
                    case bondy_oplog_registry:applier_pid(Id) of
                        undefined -> {error, applier_unavailable};
                        Pid when is_pid(Pid) -> {applier, Pid}
                    end
            end;
        {error, _} = Err ->
            Err
    end.

%% @private
to_instance_id(Id) when is_binary(Id) ->
    {ok, Id};
to_instance_id(Pid) when is_pid(Pid) ->
    case lookup_instance_id(Pid) of
        undefined -> {error, applier_unavailable};
        Id -> {ok, Id}
    end.

%% @private
%% Forwards a verified remote event to the fused instance for install
%% (origin-ban / backpressure / watermark / equivocation), from the verify
%% worker spawned in the `{enqueue_remote, Event}` clause. Mirrors
%% `bondy_oplog_applier:forward_remote/2`; the install reply is what the
%% caller sees. A `noproc` race during subtree restart is surfaced so the
%% sync session can retry instead of treating the event as accepted.
fused_forward_remote(InstancePid, Event) ->
    try gen_server:call(InstancePid, {install_remote, Event}, infinity) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> {error, instance_unavailable};
        exit:noproc -> {error, instance_unavailable};
        exit:{normal, _} -> {error, instance_unavailable};
        exit:{shutdown, _} -> {error, instance_unavailable}
    end.

%% @private
%% Resolves the applier pid for a `Target` (instance id or instance
%% pid). The applier is published in the registry by its own
%% `init/1`; during a subtree mid-restart it can briefly be absent,
%% in which case callers see `{error, applier_unavailable}` and can
%% retry.
applier_pid_for(InstanceId) when is_binary(InstanceId) ->
    case bondy_oplog_registry:applier_pid(InstanceId) of
        undefined -> {error, applier_unavailable};
        Pid when is_pid(Pid) -> {ok, Pid}
    end;
applier_pid_for(Pid) when is_pid(Pid) ->
    case lookup_instance_id(Pid) of
        undefined -> {error, applier_unavailable};
        Id -> applier_pid_for(Id)
    end.

%% @private
%% Resolves the FUSED INSTANCE's own pid for `Target` (instance id or
%% pid) — the counterpart to `applier_pid_for/1` for cell-admin ops that
%% fall back to running in-process on a fused instance (which has no
%% separate applier). `{error, applier_unavailable}` for a non-fused
%% instance too, so callers can treat it exactly like the applier-missing
%% case (there is genuinely nowhere else to run the op).
fused_instance_pid_for(InstanceId) when is_binary(InstanceId) ->
    case bondy_oplog_registry:fused(InstanceId) of
        true ->
            case bondy_oplog_registry:instance_pid(InstanceId) of
                undefined -> {error, applier_unavailable};
                Pid when is_pid(Pid) -> {ok, Pid}
            end;
        %% `false` for a genuinely non-fused instance; `undefined` for an
        %% instance id the registry has never seen (no row to read `fused`
        %% from) — both mean "nowhere to run this in-process".
        _ ->
            {error, applier_unavailable}
    end;
fused_instance_pid_for(Pid) when is_pid(Pid) ->
    case lookup_instance_id(Pid) of
        undefined -> {error, applier_unavailable};
        Id -> fused_instance_pid_for(Id)
    end.

?DOC("""
Blocks until the per-instance applier has promoted every overlay row
into the MST, or until `Timeout` ms have elapsed.

After the write path returns from `append/2`, the event is durable
in the WAL and visible in the overlay but not yet in the MST. The
per-instance applier drains the WAL and dispatches `install_local_batch`
casts to the instance; each cast installs the events in the MST and
evicts the matching overlay rows.

Operations that read the MST directly (`root_hash/1`, `compact/2`,
`sync/2`) see the post-applier state only — callers that need
read-after-write consistency on the MST itself should call this
function as a synchronisation point.

Returns `ok` once the overlay is empty, or `{error, timeout}` on
expiry. A missing overlay (subtree mid-restart) returns `ok`.
""").
-spec await_apply(instance_id() | pid()) -> ok | {error, timeout}.

await_apply(Target) ->
    await_apply(Target, 5000).

-spec await_apply(instance_id() | pid(), timeout()) -> ok | {error, timeout}.

await_apply(Target, Timeout) when
    is_binary(Target) orelse is_pid(Target)
->
    %% Event-driven barrier: resolve the instance pid and issue a
    %% `await_overlay_drained` gen_server:call. If the overlay is
    %% non-empty the instance queues the caller in `drain_waiters`
    %% and replies the moment its install handlers shrink the overlay
    %% to 0. Replaces the prior 5 ms-poll loop, which floored every
    %% wait at the timer resolution regardless of how fast the
    %% applier actually drained.
    case resolve_instance_pid(Target) of
        undefined ->
            %% No registered instance — nothing to drain. Mirrors the
            %% old polling behaviour for pid lookups that miss.
            ok;
        Pid ->
            call_await_overlay_drained(Pid, Timeout)
    end.

%% @private
resolve_instance_pid(Pid) when is_pid(Pid) ->
    Pid;
resolve_instance_pid(InstanceId) when is_binary(InstanceId) ->
    bondy_oplog_registry:instance_pid(InstanceId).

%% @private
call_await_overlay_drained(Pid, Timeout) ->
    try gen_server:call(Pid, await_overlay_drained, Timeout) of
        ok -> ok
    catch
        exit:{timeout, _} -> {error, timeout};
        %% Subtree restart: treat as drained — the new instance starts
        %% with an empty overlay so the prior overlay contents (if any)
        %% are no longer observable.
        exit:{noproc, _} -> ok;
        exit:noproc -> ok;
        exit:{normal, _} -> ok;
        exit:{shutdown, _} -> ok
    end.

%% @private
%% Best-effort reverse lookup from gen_server pid to instance_id. Used
%% by `applier_pid_for/1` when the caller targets the instance by pid.
%% Returns `undefined` when the pid is not registered.
lookup_instance_id(Pid) when is_pid(Pid) ->
    try gen_server:call(Pid, instance_id, 1000) of
        Id when is_binary(Id) -> Id;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

-spec get(instance_id() | pid(), bondy_oplog_event:event_key()) ->
    {ok, bondy_oplog_event:t()} | not_found.

get(Target, Key) when is_binary(Target) ->
    %% Overlay-first, then MST. One registry lookup pulls both
    %% handles — the old two-`lookup_element` pattern serialised on
    %% the same per-key slot lock and dominated the cost of cold
    %% reads. The overlay holds events that landed in the WAL but
    %% have not yet been promoted by the applier; reading the overlay
    %% before the MST handle closes the race where the applier
    %% publishes a new handle and then evicts the overlay row (MST
    %% publish strictly precedes overlay evict).
    case bondy_oplog_registry:read_overlay_and_mst(Target) of
        undefined ->
            error({noproc, {?MODULE, Target}});
        {Tab, MST} ->
            case overlay_lookup_tab(Tab, Key) of
                {ok, _} = Hit ->
                    Hit;
                not_found ->
                    case bondy_mst:get(MST, Key) of
                        undefined -> not_found;
                        Value -> {ok, event_from_value(Key, Value)}
                    end
            end
    end;
get(Target, Key) ->
    gen_server:call(target(Target), {get, Key}).

-spec root_hash(instance_id() | pid()) -> binary() | undefined.

root_hash(Target) ->
    %% Always route through the instance gen_server so the advertised root reads
    %% the SAME live `#state.mst` snapshot that `get_pages/2` and the
    %% `{missing_set, _}` handler serve from. Reading the registry-published
    %% handle here instead let AAE advertise a root whose pages the live MST had
    %% already compacted/advanced past — the peer then requested pages
    %% `get_pages/2` could not return (`peer_returned_empty_pages`), looping the
    %% sync forever. One consistent snapshot for root + pages.
    gen_server:call(target(Target), root_hash).

-doc """
The root hash to ADVERTISE over anti-entropy, or `undefined`.

Like `root_hash/1` but applies the AAE integrity guard: returns the
current root only when it is fully servable (every page reachable from it
is present in the store). A dangling root — one whose pages are not all
present — is NOT advertised; this returns `undefined` instead, so a
pulling peer requests nothing from us (its `missing_set(undefined)` is
empty) and cannot fail with `peer_returned_empty_pages`. The node then
heals its own root via its periodic pull / WAL replay rather than
poisoning a healthy peer with a root it cannot serve. The servability
check is memoised per root hash, so it costs one `missing_set` walk only
when the root changes.
""".
-spec aae_root(instance_id() | pid()) -> binary() | undefined.

aae_root(Target) ->
    gen_server:call(target(Target), aae_root).

-doc """
Diagnostic for a (possibly dangling) root.

Returns a map describing the current root and, for the pages reported missing
by `missing_set/2`, a count per class — because the class is what names the
faulting layer:

- `tombstoned` — still readable in the store, so the walk's miss did not come
  from the store: a read-path/masking fault.
- `absent` — deleted outright while a live root references them: a store-layer
  fault.
- `live` — present and unmarked: a transient miss, observed before a
  concurrent insert became visible.
- `unknown` — the backend implements no `page_state/2` and cannot classify.

Intended for operators diagnosing a dangling shard; read-only.
""".
-spec diagnose_root(instance_id() | pid()) -> map().

diagnose_root(Target) ->
    gen_server:call(target(Target), diagnose_root).

-doc """
Retained MST garbage-collection abort reports for this node, newest first —
optionally filtered to one instance.

The GC abort is the own-root page-loss tripwire (see `bondy_mst:gc/2`): when
the current root is unservable the sweep refuses to run, because the mark walk
skips missing pages and would amplify a small hole into subtree loss. Each
abort retains the missing page hashes AND their state re-probed after a short
delay, classified as `deleted` (a page a live root references is gone — a
store-layer fault), `tombstoned` (present but freed, so the walk's miss came
from elsewhere), or `transient` (readable on re-probe, nothing lost).

Reports live in the node, not only in the log, so an occurrence stays
diagnosable long after the platform's log buffer has rolled — which is exactly
what cost us the evidence on Fly s25. Query after any
`bondy_mst_gc_aborted_total` increment:

```erlang
bondy_oplog_instance:gc_aborts().
bondy_oplog_instance:gc_aborts(<<"registry/4">>).
```
""".
-spec gc_aborts() -> [map()].

gc_aborts() ->
    bondy_mst:gc_aborts().

-spec gc_aborts(instance_id()) -> [map()].

gc_aborts(InstanceId) when is_binary(InstanceId) ->
    %% The store's name IS the instance id for every tree this module opens.
    [R || #{name := N} = R <- bondy_mst:gc_aborts(), N =:= InstanceId].

-doc """
The instance's applied-frontier version vector `#{Origin => max Seq}` — the
compaction-invariant convergence oracle. Two nodes with equal frontiers have
applied the same op-set (causal delivery ⇒ a per-origin max Seq identifies the
applied prefix). Read lock-free from the registry.
""".
-spec frontier(instance_id()) -> #{binary() => non_neg_integer()}.

frontier(InstanceId) when is_binary(InstanceId) ->
    bondy_oplog_registry:frontier(InstanceId).

-spec fold_range(
    instance_id() | pid(),
    From :: bondy_oplog_event:event_key(),
    To :: bondy_oplog_event:event_key(),
    fun((bondy_oplog_event:t(), Acc) -> Acc),
    Acc
) -> Acc when Acc :: term().

fold_range(Target, From, To, Fun, Acc0) when is_function(Fun, 2) ->
    %% Routed through the gen_server so the MST snapshot and the
    %% overlay scan are captured in the same callback — `publish/1`
    %% (registry write) and `evict_overlay_batch/2` are sibling steps
    %% of `install_local_batch`, but they are visible to a lock-free
    %% reader at two independent moments. Under whole-suite load that
    %% race was dropping events from `fold_range/5`. Sync hop cost is
    %% acceptable for the rare admin / test use of range scans.
    gen_server:call(target(Target), {fold_range, From, To, Fun, Acc0}).

-spec range(
    instance_id() | pid(),
    From :: bondy_oplog_event:event_key(),
    To :: bondy_oplog_event:event_key()
) -> [bondy_oplog_event:t()].

range(Target, From, To) ->
    lists:reverse(
        fold_range(Target, From, To, fun(E, Acc) -> [E | Acc] end, [])
    ).

-spec truncate_prefix(instance_id() | pid(), bondy_oplog_event:event_key()) ->
    non_neg_integer().

truncate_prefix(Target, Watermark) ->
    gen_server:call(target(Target), {truncate_prefix, Watermark}, infinity).

-spec size(instance_id() | pid()) -> non_neg_integer().

size(Target) ->
    %% Total events visible to the instance = `live_size` (events
    %% promoted to the MST) + overlay row count. The two are
    %% maintained in lockstep by `install_local_batch` (live_size +=
    %% N, overlay -= N), but those updates are *not* observable to a
    %% lock-free reader as a single atom. Routing through the
    %% gen_server is the simplest way to read them in the same
    %% callback — no `install_local_batch` cast can run while we are
    %% the handler — so we always return a consistent snapshot.
    %% Sync hop cost is acceptable for the stats / admin use of
    %% `size/1`; hot-path callers stay on `get/2` and `append/2,3`.
    gen_server:call(target(Target), instance_size).

-spec first_key(instance_id() | pid()) ->
    {ok, bondy_oplog_event:event_key()} | empty.

first_key(Target) ->
    %% Same MST-snapshot / overlay-scan atomicity story as
    %% `fold_range/5` — route through the gen_server so the two
    %% sources are read in a single handler.
    gen_server:call(target(Target), first_key).

-spec latest_key(instance_id() | pid()) ->
    {ok, bondy_oplog_event:event_key()} | empty.

latest_key(Target) ->
    %% Same atomicity story as `first_key/1`.
    gen_server:call(target(Target), latest_key).

-doc """
The MST's last `{Key, Value}` (durable replay frontier), or `undefined` for an
empty MST. Read inside the instance process because the durable pack store's
sealed-pack file descriptors are raw and process-bound — the applier calls this
at init to compute its `resume_position/2` instead of folding the shared MST
handle in its own process (which raises `not_on_controlling_process`).
""".
-spec mst_last(instance_id() | pid()) ->
    undefined | {bondy_oplog_event:event_key(), term()}.

mst_last(Target) ->
    gen_server:call(target(Target), mst_last).

?DOC("""
Returns the configured Origin for `Target`.

**Pass an `instance_id()` (binary)** for hot-path callers — this form
reads the value directly from the registry without messaging. The
`pid()` form is a test/internal convenience that issues a synchronous
`gen_server:call` to the instance.
""").
-spec origin(instance_id() | pid()) -> bondy_oplog_origin:t().

origin(Target) ->
    case lookup_origin(Target) of
        {ok, Origin} -> Origin;
        not_found -> error({noproc, Target})
    end.

?DOC("""
Returns a diagnostic summary of an instance's state. Cheap;
appropriate for status pages and operational tools.
""").
-spec info(instance_id() | pid()) -> map().

info(Target) ->
    gen_server:call(target(Target), info).

?DOC("""
Returns the validator module and a snapshot of the validator state
for the per-instance applier. The applier uses this to re-verify
event signatures (S1) in its own process before dispatching events
to the instance for install. `verify_event/2` is read-only on the
validator state, so the snapshot remains valid for the lifetime of
the applier.
""").
-spec get_validator(pid()) -> {module(), term()}.

get_validator(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, get_validator, infinity).

?DOC("""
Folds the instance's MST for the durable applier's cold-replay and returns the
`{Key, Value}` pairs to re-apply, together with the current root.

This runs **inside the instance gen_server** on purpose: the instance owns the
MST page store, and a sealed pack is read through a raw file descriptor that is
bound to the process that opened it. The applier (a different process) must not
fold the MST itself — `prim_file:pread/3` on the instance's fd from the applier
fails with `not_on_controlling_process`. The applier therefore delegates the
fold here and applies the returned pairs to its projection.

Returns `{ok, no_change}` when the MST root has not moved since `LastRoot`, or
`{ok, {CurrentRoot, Pairs}}` otherwise (a full fold when `LastRoot` is
`undefined`, an incremental diff otherwise — see
`bondy_oplog_applier:diff_pairs/3`).
""").
-spec replay_pairs(pid(), bondy_mst:hash() | undefined) ->
    {ok, no_change} | {ok, {bondy_mst:hash(), [{term(), term()}]}}.

replay_pairs(Pid, LastRoot) when is_pid(Pid) ->
    gen_server:call(Pid, {replay_pairs, LastRoot}, infinity).

?DOC("""
Returns the distinct `{Bucket, Key}` cell keys named by this instance's MST.

The fallback cell directory for a projection adapter that cannot enumerate
its own keyspace, folded HERE because this process owns the MST store: a
sealed pack is read through a raw file descriptor bound to whichever process
opened it, so a caller that folds it itself gets
`not_on_controlling_process`. Same delegation as `replay_pairs/2`, and for
the same reason.

Callers go through `bondy_oplog_cell_utils:mst_cell_directory/1`, which
folds in place when it is already running in this process.
""").
-spec cell_directory(pid()) -> {ok, [{term(), term()}]}.

cell_directory(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, cell_directory, infinity).

?DOC("""
Asks the per-instance applier to refresh its validator snapshot by
calling `bondy_oplog_validator:refresh/1` on the current snapshot.

Returns `ok` once the refresh request has been *delivered* to the
applier (fire-and-forget cast). The actual outcome — snapshot
swapped, validator returned `{error, _}`, validator raised, or
`refresh/1` not exported — is logged by the applier and surfaced
via the `[bondy_oplog, applier, validator_refresh]` telemetry event.

Returns `{error, applier_unavailable}` if the subtree is mid-restart
and the applier hasn't published its pid yet — operators / tests
should retry.

Equivalent to `refresh_validator(Target, validator_refresh)`.
""").
-spec refresh_validator(instance_id() | pid()) ->
    ok | {error, applier_unavailable}.

refresh_validator(Target) ->
    refresh_validator(Target, validator_refresh).

?DOC("""
As `refresh_validator/1` but tags the refresh request with an
operator-supplied `Reason` term. The reason is logged by the applier
and emitted on the `[bondy_oplog, applier, validator_refresh]`
telemetry event so operators can correlate the refresh with whatever
upstream change triggered it (config push, key rotation, etc.).
""").
-spec refresh_validator(instance_id() | pid(), term()) ->
    ok | {error, applier_unavailable}.

refresh_validator(Target, Reason) ->
    case applier_pid_for(Target) of
        {ok, ApplierPid} ->
            bondy_oplog_applier:refresh_validator(ApplierPid, Reason);
        {error, _} = Err ->
            %% No separate applier — a fused instance has none by design.
            %% Fall back to the instance's own equivalent handler.
            case fused_instance_pid_for(Target) of
                {ok, InstancePid} ->
                    gen_server:cast(InstancePid, {refresh_validator, Reason}),
                    ok;
                {error, _} ->
                    Err
            end
    end.

?DOC("""
Reap the per-cell causal-context entries of permanently-retired origins
from this shard's projection (the dead-origin GC). A tier_2
CRDT carries one version-vector entry per origin that ever wrote a cell;
a decommissioned node leaves those entries behind forever — the one cost
that grows with cluster *churn*. This drops only the value-preserving
(causal-history-only) entries of the supplied `RetiredOrigins`, so the
projection's value is unchanged.

The library cannot know which origins are retired (membership is delegated
to the consumer, as with `bondy_oplog_peer_source` and
`bondy_oplog_origin_bans`); the operator supplies `RetiredOrigins` and
owns the obligation that they are permanently gone and causally stable
cluster-wide. The local value-preserving gate means even a premature call
cannot lose live data — it just reaps fewer entries and reports them. The
pass is idempotent. A no-op (`supported => false`) for a legacy fold /
tier_0 shard.

A reap rewrites the projection checkpoint, not the MST, so it is undone by
a subsequent **live re-bootstrap** (which re-folds the full MST) and skips
**fully-compacted** cells — re-run it after a re-bootstrap. Both are
bounded-by-churn, not convergence bugs; see
`bondy_oplog_applier:reap_origins_sync/2` for the full durability note.

Returns `{ok, Report}` (see `bondy_oplog_applier:reap_report/0`) or
`{error, applier_unavailable}` during a subtree restart.
""").
-spec reap_origins(instance_id() | pid(), [term()]) ->
    {ok, bondy_oplog_applier:reap_report()} | {error, term()}.

reap_origins(Target, RetiredOrigins) when is_list(RetiredOrigins) ->
    case applier_pid_for(Target) of
        {ok, ApplierPid} ->
            bondy_oplog_applier:reap_origins_sync(ApplierPid, RetiredOrigins);
        {error, _} = Err ->
            %% No separate applier — a fused instance has none by design.
            %% Fall back to the instance's own equivalent handler.
            case fused_instance_pid_for(Target) of
                {ok, InstancePid} ->
                    gen_server:call(
                        InstancePid, {reap_origins, RetiredOrigins}, infinity
                    );
                {error, _} ->
                    Err
            end
    end.

-doc """
The tier_2 stamp-site read of a cell's current causal context, for a
**fused** instance (which has no separate applier process to hold
`bondy_oplog_applier:cell_context/3`'s equivalent). `bondy_db:cell_context/3`
calls this directly (via `InstancePid`) when
`bondy_oplog_registry:applier_pid/1` is `undefined` and the instance is
fused. `{error, no_cell_apply_target}` for an unbootstrapped or non-fused
instance.
""".
-spec cell_context(InstancePid :: pid(), Bucket :: term(), Key :: term()) ->
    {ok, term()} | {error, term()}.

cell_context(InstancePid, Bucket, Key) when is_pid(InstancePid) ->
    gen_server:call(InstancePid, {cell_context, Bucket, Key}, infinity).

-doc """
The causally-stable CRDT cell reclamation sweep, for a **fused** instance
(which has no separate applier process to hold
`bondy_oplog_applier:sweep_stable_cells/3`'s equivalent). `reclaim_stable_
cells/1` calls this directly when the instance is fused. `{error,
no_projection}` for an unbootstrapped or non-fused instance.
""".
-spec sweep_stable_cells(
    InstancePid :: pid(), StableHlc :: integer(), Opts :: map()
) ->
    {ok, map(), done | {resume, term()}} | {error, term()}.

sweep_stable_cells(InstancePid, StableHlc, Opts) when
    is_pid(InstancePid), is_integer(StableHlc), is_map(Opts)
->
    gen_server:call(
        InstancePid, {sweep_stable_cells, StableHlc, Opts}, infinity
    ).

-doc """
The FUSED instance's resolved `cell_apply_target` shard key, for a fused
instance (which has no separate applier process to hold
`bondy_oplog_applier:cell_apply_target/1`'s equivalent). Mirrors that
function exactly, including its founding-ctx-only scope (the FOUNDING
table's shard key on a multiplexed shard, not every registered table's).
`undefined` if no projection target was configured, or the instance is not
fused.
""".
-spec cell_apply_target(InstancePid :: pid()) -> {ok, term()} | undefined.

cell_apply_target(InstancePid) when is_pid(InstancePid) ->
    gen_server:call(InstancePid, cell_apply_target, infinity).

-doc """
Full secondary-index rebuild on a **fused** instance (which has no
separate applier process to hold
`bondy_oplog_applier:rebuild_indexes_sync/1`'s equivalent). Synchronous —
the rebuild barrier. A no-op when the instance has no `cell_apply_target`
or is not fused.
""".
-spec rebuild_indexes_sync(InstancePid :: pid()) -> ok.

rebuild_indexes_sync(InstancePid) when is_pid(InstancePid) ->
    gen_server:call(InstancePid, rebuild_indexes, infinity).

%% =============================================================================
%% PAGE-LEVEL API (sync protocol)
%% =============================================================================

?DOC("""
Returns the subset of `Hashes` that this instance has, as a map of
`hash => page`. Hashes the instance does not have are silently absent
from the returned map.

Used by the sync protocol on the *responder* side: a peer asks for a
set of pages, this instance returns whichever it has.
""").
-spec get_pages(instance_id() | pid(), [bondy_mst:hash()]) ->
    #{bondy_mst:hash() => bondy_mst_page:t()}.

get_pages(Target, Hashes) when is_list(Hashes) ->
    %% Always route through the instance gen_server. Page reads hit the
    %% durable pack store's raw (process-bound) file descriptors, which only
    %% the instance process may use — a direct read from the AAE responder
    %% process raises `not_on_controlling_process`. The handler folds in the
    %% instance process (see `do_handle_call({get_pages, _}, ...)`).
    gen_server:call(target(Target), {get_pages, Hashes}).

?DOC("""
Inserts a batch of pages received from a peer. Each page is verified
by re-hashing on insert; a hash mismatch (peer using a different
hash algorithm or malformed page) raises an error.

Used by the sync protocol on the *initiator* side after pulling pages
from a peer.
""").
-spec merge_pages(
    instance_id() | pid(),
    #{bondy_mst:hash() => bondy_mst_page:t()} | [bondy_mst_page:t()]
) -> ok.

merge_pages(Target, Pages) when is_map(Pages) ->
    merge_pages(Target, maps:values(Pages));
merge_pages(Target, Pages) when is_list(Pages) ->
    gen_server:call(target(Target), {merge_pages, Pages}, infinity).

?DOC("""
Returns the set of page hashes reachable from `Root` that this
instance does not have locally. Used by the sync protocol's initiator
to compute what to request from the peer.
""").
-spec missing_set(instance_id() | pid(), bondy_mst:hash()) ->
    [bondy_mst:hash()].

missing_set(Target, Root) when is_binary(Root) ->
    %% Always route through the instance gen_server. Walking the store from
    %% Root to compute missing pages reads the durable pack store's raw
    %% (process-bound) fds — a direct read from the sync-session (initiator)
    %% process raises `not_on_controlling_process`. The handler walks in the
    %% instance process (see `do_handle_call({missing_set, _}, ...)`).
    gen_server:call(target(Target), {missing_set, Root}).

?DOC("""
Integrates a peer's tree (identified by `PeerRoot`) into the local
MST. Pre-condition: every page reachable from `PeerRoot` must already
be present in the local store (caller's responsibility — typically
ensured by `missing_set/2` returning `[]` after page loading). The
handler RE-VERIFIES that pre-condition atomically with the merge (both
run in this gen_server, serialized with the compaction cycles whose
page GC can sweep pulled-but-unmerged pages) and answers
`{error, {peer_pages_missing, N}}` instead of merging partially — a
missing subtree would otherwise be silently treated as empty by
`bondy_mst:merge/3`, losing every event under it while the session
records the round as complete (observed live: ~100-270 silent partial
merges per sustained-load suite run before this guard). The caller
re-pulls and retries.

After this call, all events that were in the peer's tree are visible
to local queries, and the local root is the merged root of both trees.
""").
-spec integrate_peer_root(instance_id() | pid(), bondy_mst:hash()) ->
    ok | {error, {peer_pages_missing, non_neg_integer()}}.

integrate_peer_root(Target, PeerRoot) when is_binary(PeerRoot) ->
    gen_server:call(
        target(Target),
        {integrate_peer_root, PeerRoot},
        infinity
    ).

?DOC("""
Pins `Root` (a peer root an in-flight sync session is pulling pages
for) against this instance's ETS page GC. Pulled pages are unreachable
from the LOCAL current root until `integrate_peer_root/2` merges them,
so without a pin every concurrent compaction cycle's mark-and-sweep
collects them — a multi-round pull would lose its earlier rounds'
pages while later rounds are still fetching. The pin is consumed by a
successful `integrate_peer_root/2` of the same root and expires after
`?PEER_ROOT_PIN_TTL_MS` otherwise (a crashed session must not retain
pages forever).
""").
-spec pin_peer_root(instance_id() | pid(), bondy_mst:hash()) -> ok.

pin_peer_root(Target, Root) when is_binary(Root) ->
    gen_server:call(target(Target), {pin_peer_root, Root}).

%% =============================================================================
%% GC / COMPACTION API
%% =============================================================================

?DOC("""
Returns the current compaction watermark — the highest event key that
has been folded into the snapshot. Events with keys ≤ watermark are
no longer in the MST.
""").
-spec current_watermark(instance_id() | pid()) ->
    undefined | bondy_oplog_event:event_key().

current_watermark(Target) when is_binary(Target) ->
    case ets_member(Target) of
        true -> bondy_oplog_registry:watermark(Target);
        false -> error({noproc, {?MODULE, Target}})
    end;
current_watermark(Target) ->
    gen_server:call(target(Target), current_watermark).

-spec crdt_module(instance_id() | pid()) -> module() | undefined.

crdt_module(Target) when is_binary(Target) ->
    case ets_member(Target) of
        true -> bondy_oplog_registry:crdt_module(Target);
        false -> error({noproc, {?MODULE, Target}})
    end;
crdt_module(Target) ->
    gen_server:call(target(Target), crdt_module).

?DOC("""
Returns `{ok, Watermark, Checkpoint}` for the latest persisted
compaction checkpoint, or `not_found` if no compaction has run yet.
""").
-spec compaction_checkpoint(instance_id() | pid()) ->
    {ok, bondy_oplog_event:event_key(), term()} | not_found.

compaction_checkpoint(Target) when is_binary(Target) ->
    case bondy_oplog_registry:lookup(Target) of
        not_found -> error({noproc, {?MODULE, Target}});
        {ok, #{snapshot := undefined}} -> not_found;
        {ok, #{snapshot := {W, S}}} -> {ok, W, S}
    end;
compaction_checkpoint(Target) ->
    gen_server:call(target(Target), get_compaction_checkpoint).

?DOC("""
Runs one compaction cycle inside the instance gen_server.

`PeerRoots` is the list of root hashes confirmed at peers (from
`bondy_oplog_peer_state`). The instance:

1. Computes the stability frontier — the largest event key K such
   that every event with key ≤ K is reachable from every peer's root.
2. Extracts events in `(currentWatermark, frontier]`.
3. Calls the configured CRDT module's `interpret_cog/2` on top of
   the previous snapshot's state.
4. Persists the new snapshot at `frontier`.
5. Truncates the MST up to and including `frontier`.
6. Updates the watermark.

Returns `{ok, no_change}` if no advance is possible (no peers,
empty intersection, frontier ≤ current watermark); otherwise
`{ok, {compacted, NewWatermark, EventCount}}`.
""").
-spec compact(instance_id() | pid(), [bondy_mst:hash()]) ->
    {ok, no_change}
    | {ok, {compacted, bondy_oplog_event:event_key(), non_neg_integer()}}
    | {error, term()}.

compact(Target, PeerRoots) when is_list(PeerRoots) ->
    gen_server:call(target(Target), {compact, PeerRoots}, infinity).

?DOC("""
Bootstraps an instance by installing a peer's snapshot at `Watermark`.
Used by `bondy_oplog_sync_session:bootstrap/3` when a fresh
or far-behind replica joins a long-running cluster.

NOTE: not transactional with respect to a VM crash between
`put_checkpoint` and the MST truncate. On the next start, events ≤ the
persisted watermark are filtered out at sync/append time, so the
transient overlap is self-correcting.

Atomic:

1. Persists the snapshot via the configured snapshot store.
2. Truncates the local MST up to and including `Watermark` (events ≤
   watermark are now in the snapshot, redundant in the live tree).
3. Advances the local watermark.
4. Updates the HLC to dominate `Watermark` so subsequent local
   appends sort above it.

Refuses to install a snapshot whose watermark is `=<` the current
watermark — going backwards would break monotonicity. Returns
`{ok, NewWatermark}` on success, `{error, watermark_not_advancing}`
otherwise.
""").
-spec load_snapshot(
    instance_id() | pid(),
    bondy_oplog_event:event_key(),
    term()
) -> {ok, bondy_oplog_event:event_key()} | {error, term()}.

load_snapshot(Target, Watermark, Snapshot) ->
    gen_server:call(
        target(Target),
        {load_snapshot, Watermark, Snapshot},
        infinity
    ).

?DOC("""
Flips the instance bootstrap lifecycle to `live` (durably). Called by
`bondy_oplog_sync_session:bootstrap/3` after `load_snapshot/3` has
installed the peer snapshot and the watermark has been advanced.

Idempotent. Order matters: `mark_live/1` MUST be the **last** step in
the bootstrap completion sequence — the durable flag file is the
crash-recovery marker that "everything before me succeeded".
""").
-spec mark_live(instance_id() | pid()) -> ok.

mark_live(InstanceId) when is_binary(InstanceId) ->
    case bondy_oplog_registry:lifecycle(InstanceId) of
        undefined ->
            %% Instance not yet published; nothing to flip. This is a
            %% race between `mark_live/1` and the instance's `init/1`.
            %% Callers driving bootstrap are expected to talk to a
            %% running instance — log and return ok so the call is a
            %% no-op rather than crash the caller.
            ?LOG_WARNING(#{
                description =>
                    "mark_live/1 called for an instance that has no "
                    "registry entry; treating as no-op",
                instance_id => InstanceId
            }),
            ok;
        Handle ->
            ok = bondy_oplog_bootstrap_lifecycle:mark_live(Handle),
            ok = nudge_applier(InstanceId)
    end;
mark_live(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, mark_live, infinity).

%% @private
%% Wake the applier immediately after a lifecycle transition so we
%% don't have to wait for the next 1s backstop tick. The applier
%% absorbs unsolicited `drain_resume` casts; the worst case if the
%% applier isn't running yet is the cast lands in a queue that gets
%% dropped on supervisor restart.
nudge_applier(InstanceId) ->
    case bondy_oplog_registry:applier_pid(InstanceId) of
        undefined ->
            ok;
        Pid when is_pid(Pid) ->
            ok = bondy_oplog_applier:notify_drain_resume(Pid),
            ok
    end.

?DOC("""
Returns the current bootstrap lifecycle state of an instance.
`pre_bootstrap` while the instance is waiting for a successful
`bondy_oplog_sync_session:bootstrap/3`; `live` once it can serve
fold-driven reads. `undefined` when the instance is not registered.
""").
-spec lifecycle_state(instance_id() | pid()) ->
    bondy_oplog_bootstrap_lifecycle:state() | undefined.

lifecycle_state(InstanceId) when is_binary(InstanceId) ->
    case bondy_oplog_registry:lifecycle(InstanceId) of
        undefined -> undefined;
        Handle -> bondy_oplog_bootstrap_lifecycle:state(Handle)
    end;
lifecycle_state(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, lifecycle_state, infinity).

?DOC("""
Installs a batch of catalogue-snapshot cells into the instance's
projection. Each cell is a `{Bucket, Key, Frame}` triple where `Frame`
is the V2 cell frame produced by the peer's projection adapter.

`Mode` is `replace` (fresh bootstrap) or `merge` (recovering
bootstrap). See `bondy_oplog_applier:install_catalogue_batch/2` for
the per-mode semantics. The arity-2 form is equivalent to
`install_catalogue_batch(Inst, {replace, Cells})`.

Returns `{ok, #{installed := _, skipped := _, merged := _,
replaced_no_merge := _}}`.

Called by `bondy_oplog_sync_session:bootstrap_catalogue/3` between
`get_catalogue_snapshot_init` and `finalize_catalogue_bootstrap/3`.
""").
-spec install_catalogue_batch(
    instance_id() | pid(),
    [bondy_oplog_transport:cell()]
    | {replace | merge, [bondy_oplog_transport:cell()]}
) ->
    {ok, #{
        installed := non_neg_integer(),
        skipped := non_neg_integer(),
        merged := non_neg_integer(),
        replaced_no_merge := non_neg_integer()
    }}
    | {error, term()}.

install_catalogue_batch(InstanceId, Cells) when
    is_binary(InstanceId), is_list(Cells)
->
    install_catalogue_batch(InstanceId, {replace, Cells});
install_catalogue_batch(InstanceId, {replace, Cells}) when
    is_binary(InstanceId)
->
    %% `replace` is the only supported mode; `merge` was removed.
    %% Guard fails fast on a stray `{merge, _}` here rather than letting it
    %% reach the applier (which would function_clause).
    case bondy_oplog_registry:fused(InstanceId) of
        true ->
            %% A fused instance has no applier to install into: the install
            %% runs in the instance gen_server itself, through the same
            %% shared body (`bondy_oplog_applier:install_catalogue_cells/3`)
            %% over this instance's own `#fused_drain{}` cell-apply source.
            %% Load-bearing for retention-bounded (`mst_retention`)
            %% instances: their truncated history makes catalogue bootstrap
            %% the ONLY complete recovery path for a joining or lagging
            %% peer — page-sync alone covers just the retention window.
            case ?MODULE:whereis(InstanceId) of
                undefined ->
                    {error, instance_not_running};
                Pid ->
                    gen_server:call(
                        Pid, {install_catalogue_batch, Cells}, infinity
                    )
            end;
        _ ->
            case bondy_oplog_registry:applier_pid(InstanceId) of
                undefined ->
                    {error, instance_not_running};
                ApplierPid ->
                    bondy_oplog_applier:install_catalogue_batch(
                        ApplierPid, {replace, Cells}
                    )
            end
    end;
install_catalogue_batch(Pid, ModeAndCells) when is_pid(Pid) ->
    case bondy_oplog_registry:instance_id_by_sup_pid(Pid) of
        {ok, InstanceId} ->
            install_catalogue_batch(InstanceId, ModeAndCells);
        not_found ->
            {error, instance_not_found}
    end.

-doc """
The fused counterpart of
`bondy_oplog_applier:rederive_projection_sync/1`: re-applies every
retained MST event through the instance's own cell-apply source,
restoring cells that a `replace`-mode catalogue install clobbered on a
live re-bootstrap. Idempotent — re-delivered ops a cell already holds
are rejected by the kernel's causal metadata. Fused instances only; an
applier-backed instance takes the applier path in
`bondy_oplog_sync_session`.
""".
-spec rederive_projection(instance_id()) -> ok | {error, any()}.

rederive_projection(InstanceId) when is_binary(InstanceId) ->
    case ?MODULE:whereis(InstanceId) of
        undefined ->
            {error, instance_not_running};
        Pid ->
            gen_server:call(Pid, rederive_projection, infinity)
    end.

?DOC("""
Adds a table to a shard instance shared by several tables (the one-log-per-shard
multiplexer). `Bucket` is the table's entity-type tag, `Target` its
`{Namespace, primary, Shard}` core-registry triple, and `TableOpts` the
cell-apply opts (`fold_module`, `secondary_indexes`). After this call the
instance routes events carrying `Bucket` to `Target`'s projection. The founding
table is registered when the instance starts (via `cell_apply_bucket`); this
adds siblings at runtime. Dispatches to the fused instance gen_server or the
applier depending on the instance's drain topology, so callers need not know it.
""").
-spec register_table(
    InstanceId :: instance_id(),
    Bucket :: binary(),
    Target :: {atom(), atom(), non_neg_integer()},
    TableOpts :: map()
) -> ok | {error, term()}.

register_table(InstanceId, Bucket, Target, TableOpts) when
    is_binary(InstanceId) andalso is_binary(Bucket) andalso is_map(TableOpts)
->
    case bondy_oplog_registry:fused(InstanceId) of
        true ->
            case ?MODULE:whereis(InstanceId) of
                undefined ->
                    {error, instance_not_running};
                Pid ->
                    gen_server:call(
                        Pid,
                        {register_table, Bucket, Target, TableOpts},
                        infinity
                    )
            end;
        _ ->
            case bondy_oplog_registry:applier_pid(InstanceId) of
                undefined ->
                    {error, instance_not_running};
                ApplierPid ->
                    bondy_oplog_applier:register_table(
                        ApplierPid, Bucket, Target, TableOpts
                    )
            end
    end.

?DOC("""
Removes a table previously added with `register_table/4` from a shared shard
instance. Events carrying `Bucket` are then dropped (logged) until the bucket is
re-registered. Dispatches to the fused instance gen_server or the applier
depending on the instance's drain topology.
""").
-spec unregister_table(InstanceId :: instance_id(), Bucket :: binary()) ->
    ok | {error, term()}.

unregister_table(InstanceId, Bucket) when
    is_binary(InstanceId) andalso is_binary(Bucket)
->
    case bondy_oplog_registry:fused(InstanceId) of
        true ->
            case ?MODULE:whereis(InstanceId) of
                undefined ->
                    {error, instance_not_running};
                Pid ->
                    gen_server:call(Pid, {unregister_table, Bucket}, infinity)
            end;
        _ ->
            case bondy_oplog_registry:applier_pid(InstanceId) of
                undefined ->
                    {error, instance_not_running};
                ApplierPid ->
                    bondy_oplog_applier:unregister_table(ApplierPid, Bucket)
            end
    end.

?DOC("""
Releases an instance founded with the WAL drain GATED (`drain_gated => true`):
flips its per-boot drain gate `open` and kicks the deferred replay. The
provisioning orchestrator calls this once per collapsed per-shard instance,
after every table sharing the shard has registered its cell-apply bucket, so the
shared WAL is replayed with a complete routing directory and no cell is skipped.
Idempotent; a no-op on an ungated or fused (ephemeral) instance. Returns
`{error, instance_not_running}` if the applier has not published its pid yet.
""").
-spec open_drain_gate(InstanceId :: instance_id()) ->
    ok | {error, term()}.

open_drain_gate(InstanceId) when is_binary(InstanceId) ->
    case bondy_oplog_registry:fused(InstanceId) of
        true ->
            %% Fused (ephemeral, memory-topology) instances are never gated —
            %% their WAL is in-memory and empty on boot, so there is no replay
            %% race to gate.
            ok;
        _ ->
            case bondy_oplog_registry:applier_pid(InstanceId) of
                undefined ->
                    {error, instance_not_running};
                ApplierPid ->
                    bondy_oplog_applier:open_drain_gate(ApplierPid)
            end
    end.

?DOC("""
Finalises a catalogue-snapshot bootstrap session.

For a fresh-bootstrap caller (`WasLive = false`) this marks the
instance `live` durably. For a recovering caller (`WasLive = true`)
the instance is already live and no lifecycle change is needed.

`Watermark` is the peer's high-water HLC at session start, captured
into the per-shard high-water atomic so future replicas reading from
this peer see at least that watermark. (In v1 this is informational —
high-water is advanced cell-by-cell during `install_catalogue_batch/2`
already; this call is the last-write barrier.)
""").
-spec finalize_catalogue_bootstrap(
    instance_id() | pid(),
    Watermark :: non_neg_integer(),
    WasLive :: boolean()
) -> ok.

finalize_catalogue_bootstrap(InstanceIdOrPid, Watermark, WasLive) ->
    %% No peer frontier to adopt (legacy 3-arity / direct callers); the empty
    %% map is a no-op merge, preserving the historical behaviour exactly.
    finalize_catalogue_bootstrap(InstanceIdOrPid, Watermark, #{}, WasLive).

-doc """
As `finalize_catalogue_bootstrap/3`, additionally adopting the peer's
applied-frontier version vector `PeerFrontier` (`#{Origin => Seq}`).

The catalogue install writes the peer's projection cells but cannot reconstruct
the per-origin `{Origin, Seq}` the frontier is built from (the cells carry only
HLC + value). Without adopting the peer's frontier, a fully bootstrapped replica
holds all the data yet reports DIVERGED forever against the convergence oracle.
The merge is a max-merge — idempotent, and safe to combine with anything the
normal apply path has already recorded. An empty map is a no-op.
""".
-spec finalize_catalogue_bootstrap(
    instance_id() | pid(),
    Watermark :: non_neg_integer(),
    PeerFrontier :: #{binary() => non_neg_integer()},
    WasLive :: boolean()
) -> ok.

finalize_catalogue_bootstrap(InstanceIdOrPid, Watermark, PeerFrontier, WasLive) ->
    finalize_catalogue_bootstrap(
        InstanceIdOrPid, Watermark, PeerFrontier, 0, WasLive
    ).

-doc """
As `finalize_catalogue_bootstrap/4`, additionally absorbing `MaxInstalledHlc`
— the maximum cell HLC the install loop decoded — into the local clock (A3).

The catalogue install writes peer cells carrying remote HLCs straight into the
projection without touching the clock, and the AAE round that follows absorbs
from `bondy_mst:last/1` — `undefined` exactly when the peer has compacted,
which is the case bootstrap exists to serve. Without this absorb a
bootstrapped replica can mint events BELOW a stability point computed from the
very cells it installed, silently invalidating causal-stability reclamation
(`BONDY_DB_RECLAMATION_PROOF.md` §7.1). The absorb happens inside the
instance, before `mark_live` flips it into service. `0` means "nothing
installed" and is a no-op. Over-absorption is safe: the clock only ever
advances.
""".
-spec finalize_catalogue_bootstrap(
    instance_id() | pid(),
    Watermark :: non_neg_integer(),
    PeerFrontier :: #{binary() => non_neg_integer()},
    MaxInstalledHlc :: non_neg_integer(),
    WasLive :: boolean()
) -> ok.

finalize_catalogue_bootstrap(
    InstanceId, Watermark, PeerFrontier, MaxInstalledHlc, WasLive
) when
    is_binary(InstanceId),
    is_integer(Watermark),
    Watermark >= 0,
    is_map(PeerFrontier),
    is_integer(MaxInstalledHlc),
    MaxInstalledHlc >= 0,
    is_boolean(WasLive)
->
    ok = maybe_advance_high_water(InstanceId, Watermark),
    ok = bondy_oplog_registry:merge_frontier(InstanceId, PeerFrontier),
    %% Make the adopted frontier DURABLE now, not just at the next clean stop.
    %% The peer's frontier includes its COMPACTED-prefix maxima, which live in
    %% neither this replica's MST (the peer compacted them away before
    %% page-sync, so they never transfer) nor a WAL-tail replay (the bootstrap
    %% installed a projection snapshot, not events through the WAL). They exist
    %% only in the in-memory registry until `terminate/2` persists them — so an
    %% UNCLEAN restart (kill/crash, no `terminate`) would lose exactly those
    %% maxima and the convergence oracle would report DIVERGED forever despite
    %% holding all the data. Persisting into the checkpoint here closes that gap
    %% so `restore_frontier/2` recovers them on any restart.
    %% The same round-trip absorbs `MaxInstalledHlc` into the clock (A3).
    ok = persist_frontier(InstanceId, MaxInstalledHlc),
    case WasLive of
        true ->
            ok;
        false ->
            ok = mark_live(InstanceId)
    end;
finalize_catalogue_bootstrap(
    Pid, Watermark, PeerFrontier, MaxInstalledHlc, WasLive
) when
    is_pid(Pid)
->
    case bondy_oplog_registry:instance_id_by_sup_pid(Pid) of
        {ok, InstanceId} ->
            finalize_catalogue_bootstrap(
                InstanceId, Watermark, PeerFrontier, MaxInstalledHlc, WasLive
            );
        not_found ->
            ok
    end.

?DOC("""
Durably persists this instance's current applied-frontier version vector into the
compaction checkpoint (the same `{projection_managed, frontier, _}` payload
`terminate/2` writes on a clean stop).

The applied-frontier is otherwise made durable only at `terminate/2` and at
compaction. A catalogue bootstrap ADOPTS the peer's frontier into the in-memory
registry, and that frontier includes the peer's compacted-prefix maxima — which
this replica can reconstruct from no local durable source. Calling this right
after the adoption makes those maxima survive an unclean restart. A no-op on an
ephemeral backend (no checkpoint).
""").
-spec persist_frontier(instance_id() | pid()) -> ok.

persist_frontier(Target) ->
    gen_server:call(target(Target), persist_frontier, infinity).

%% @private
%% As `persist_frontier/1`, absorbing `AbsorbHlc` into the local clock first —
%% see `finalize_catalogue_bootstrap/5` (A3). `0` skips the absorb.
persist_frontier(Target, AbsorbHlc) when
    is_integer(AbsorbHlc), AbsorbHlc >= 0
->
    gen_server:call(target(Target), {persist_frontier, AbsorbHlc}, infinity).

%% @private — advance the per-shard high-water atomic for the
%% applier's `cell_apply_target`. No-op if the instance is not
%% catalogue-mode.
maybe_advance_high_water(_InstanceId, 0) ->
    ok;
maybe_advance_high_water(InstanceId, Watermark) ->
    case bondy_oplog_registry:applier_pid(InstanceId) of
        undefined ->
            ok;
        ApplierPid ->
            case bondy_oplog_applier:cell_apply_target(ApplierPid) of
                undefined ->
                    ok;
                {ok, {NS, Index, Shard}} ->
                    case bondy_oplog_core_registry:lookup(NS, Index, Shard) of
                        not_found ->
                            ok;
                        {ok, Entry} ->
                            Ref = bondy_oplog_core_registry:entry_high_water_ref(
                                Entry
                            ),
                            ok = bondy_oplog_high_water:advance(Ref, Watermark)
                    end
            end
    end.

%% =============================================================================
%% REGISTRY
%% =============================================================================

?DOC("""
Returns the pid of an instance owner gen_server, or `undefined` if no
such instance is currently running.
""").
-spec whereis(instance_id()) -> pid() | undefined.

whereis(InstanceId) when is_binary(InstanceId) ->
    case bondy_oplog_registry:instance_pid(InstanceId) of
        undefined ->
            undefined;
        Pid ->
            case is_process_alive(Pid) of
                true -> Pid;
                false -> undefined
            end
    end.

%% Binary-id callers go through the lock-free registry path; pid
%% callers pay a `gen_server:call` because the registry is keyed by
%% instance_id and a pid→id reverse lookup would cost an ETS
%% `select`. Pid callers are tests/internals only — see
%% `append_remote/2` and `origin/1` docstrings.
-spec lookup_origin(instance_id() | pid()) ->
    {ok, bondy_oplog_origin:t()} | not_found.

lookup_origin(Pid) when is_pid(Pid) ->
    {ok, gen_server:call(Pid, origin, 5000)};
lookup_origin(InstanceId) when is_binary(InstanceId) ->
    case bondy_oplog_registry:origin(InstanceId) of
        undefined -> not_found;
        Origin -> {ok, Origin}
    end.

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init({InstanceId, Opts}) ->
    process_flag(trap_exit, true),
    %% Off-heap inbox: incoming messages land in their own heap
    %% fragments instead of the process heap, so minor GC does not
    %% scan them and the process heap stays small even when many
    %% callers pile up appends. Without this flag the writer cliff
    %% at >=16 concurrent appenders shows up as throughput regression
    %% — the gen_server's heap fragmenting under mailbox depth
    %% triggers frequent full-sweep GCs that stall every caller.
    process_flag(message_queue_data, off_heap),
    Origin = maps:get(origin, Opts, bondy_oplog_origin:default()),
    case bondy_oplog_origin:validate(Origin) of
        ok -> ok;
        {error, R0} -> error({invalid_origin, R0})
    end,
    HLC = bondy_oplog_hlc:new(maps:get(hlc_seed, Opts, 0)),
    SeqRef = atomics:new(1, [{signed, false}]),
    ok = atomics:put(SeqRef, 1, maps:get(seq_seed, Opts, 0)),
    ValidatorMod = maps:get(
        validator, Opts, bondy_oplog_validator_trust
    ),
    {ok, ValidatorState} =
        ValidatorMod:init(InstanceId, maps:get(validator_opts, Opts, #{})),
    {FoldMod, FoldOpts} = resolve_fold_config(InstanceId, Opts),
    Backend = maps:get(backend, Opts, ets),
    CrdtModForWarn = maps:get(crdt_module, Opts, undefined),
    case Backend =:= map andalso CrdtModForWarn =/= undefined of
        true ->
            ?LOG_WARNING(#{
                description =>
                    "instance configured with map_store backend and a "
                    "crdt_module: each lock-free read copies the entire "
                    "map from the registry to the caller. Suitable for "
                    "tests only; use ets or a stateful custom backend "
                    "in production",
                instance_id => InstanceId
            });
        false ->
            ok
    end,
    MST = open_mst(InstanceId, Backend, Opts),
    %% Compaction checkpoint + watermark recovery.
    %% Default backend resolution: prefer the file backend when the
    %% instance has any durable storage configured (`storage_path` or
    %% an explicit `compaction_checkpoint_opts.path`); otherwise fall
    %% back to ETS for ephemeral instances. A caller passing
    %% `compaction_checkpoint` explicitly always wins.
    CkptOpts0 = maps:get(compaction_checkpoint_opts, Opts, #{}),
    {CkptMod, CkptOpts} = resolve_checkpoint_backend(
        InstanceId, Opts, CkptOpts0
    ),
    {ok, CkptState} = CkptMod:init(InstanceId, CkptOpts),
    %% Single read covers both: the checkpoint envelope carries the
    %% watermark, so calling current_watermark/1 first is redundant
    %% and (on a durable backend) a wasted disk read.
    {Watermark, CachedCheckpoint} =
        case CkptMod:get_checkpoint(CkptState) of
            {ok, W0, S0} ->
                {W0, {W0, S0}};
            not_found ->
                {undefined, undefined};
            {error, CkptErr} ->
                error({compaction_checkpoint_corrupted, InstanceId, CkptErr})
        end,
    CrdtMod = maps:get(crdt_module, Opts, undefined),
    %% Seed HLC from the highest persisted event key, so a restart with
    %% a durable backend doesn't issue keys below the previous high
    %% water mark. Sources, in order of precedence:
    %%   1. The MST's max event key (live events past the watermark).
    %%   2. The compaction checkpoint's watermark.
    %% Fresh instances (ETS backend, no checkpoint) leave the HLC at 0.
    LiveSize = compute_live_size(MST),
    LastMSTKey =
        case bondy_mst:last(MST) of
            undefined -> undefined;
            {K0, _V0} -> K0
        end,
    case LastMSTKey of
        undefined when Watermark =/= undefined ->
            _ = bondy_oplog_hlc:update(
                HLC, bondy_oplog_event:key_hlc(Watermark)
            );
        undefined ->
            ok;
        K ->
            _ = bondy_oplog_hlc:update(HLC, bondy_oplog_event:key_hlc(K))
    end,
    %% Seed Seq similarly: if the MST has local-origin events, advance
    %% the Seq counter to dominate the highest seen.
    MaxLocalInstalledSeq =
        case max_local_seq(MST, Origin) of
            undefined ->
                0;
            MaxSeq ->
                ok = atomics:put(SeqRef, 1, MaxSeq),
                MaxSeq
        end,
    %% Per-instance overlay (`ordered_set`, public, owned by this
    %% gen_server). Rows are `{Key, Value, Hlc, Origin}`.
    %% `ordered_set` so range reads (`fold_range/5`, `first_key/1`,
    %% `latest_key/1`) can streaming-merge it with the MST in key
    %% order. `public` so the applier-driven eviction can run via
    %% `ets:select_delete/2` from any process. No heir — the table
    %% dies with this process; a one_for_all subtree restart creates
    %% a fresh one.
    %% Whether a projection materialises this instance's state — i.e. the
    %% applier is configured with a `cell_apply_target` (every `bondy_db`
    %% table). Derived at init from the SAME opts the supervisor uses to
    %% start the applier (`bondy_oplog_instance_sup:applier_opts/2`), so the
    %% instance NEVER asks the applier for it. That call (a synchronous
    %% `cell_apply_target` from the compaction handler) deadlocks against
    %% the applier's own synchronous `drain_install_queue` call
    %% (`commit_now/1`) — the cross-node deadlock — and under batched /
    %% high-throughput load it hits on the FIRST compaction, before any
    %% low-load warmup window. The applier FAILS to start if its
    %% `cell_apply_target` is not registered, so a live instance with the
    %% opt set always has a resolved projection (configured ⟹ resolved).
    HasProjection =
        maps:get(
            cell_apply_target, maps:get(applier, Opts, #{}), undefined
        ) =/= undefined,
    Overlay = ets:new(bondy_oplog_overlay, [
        ordered_set,
        public,
        {keypos, ?OVERLAY_KEY_POS},
        {read_concurrency, true},
        {write_concurrency, true},
        {decentralized_counters, true}
    ]),
    State = #state{
        instance_id = InstanceId,
        origin = Origin,
        hlc = HLC,
        seq = SeqRef,
        mst = MST,
        backend = Backend,
        validator_module = ValidatorMod,
        validator_state = ValidatorState,
        fold_module = FoldMod,
        fold_opts = FoldOpts,
        crdt_module = CrdtMod,
        compaction_checkpoint = CkptMod,
        compaction_checkpoint_state = CkptState,
        watermark = Watermark,
        cached_checkpoint = CachedCheckpoint,
        max_working_set = maps:get(max_working_set, Opts, infinity),
        live_size = LiveSize,
        last_event_key = LastMSTKey,
        wal_pid = undefined,
        wal_pid_monitor = undefined,
        overlay = Overlay,
        max_overlay_events = maps:get(max_overlay_events, Opts, 10_000),
        max_overlay_bytes = maps:get(max_overlay_bytes, Opts, 5 * 1024 * 1024),
        overlay_throttle = maps:get(overlay_throttle, Opts, drop),
        overlay_counters = atomics:new(2, [{signed, false}]),
        max_local_installed_seq = MaxLocalInstalledSeq,
        install_in_flight = atomics:new(1, [{signed, false}]),
        max_install_in_flight = maps:get(max_install_in_flight, Opts, 64),
        remote_gen_ref = atomics:new(1, [{signed, false}]),
        install_coalesce_max = validate_coalesce_max(
            maps:get(install_coalesce_max, Opts, 16)
        ),
        lifecycle = bondy_oplog_bootstrap_lifecycle:open(InstanceId, Opts),
        has_projection = HasProjection,
        %% Ephemeral fused-writer opt-in. The `fused ⇒ ephemeral`
        %% invariant is enforced upstream at `bondy_db:open_table`
        %% where the projection backend is authoritatively known;
        %% the instance only records and republishes the flag.
        fused = maps:get(fused, Opts, false),
        %% NOTE the opt is `mst_retention`, NOT `retention` — the latter
        %% is the WAL's segment-retention proplist, forwarded verbatim to
        %% `bondy_oplog_wal` (see `bondy_oplog_wal_manifest:new/3`).
        retention = validate_retention(
            maps:get(mst_retention, Opts, undefined),
            maps:get(fused, Opts, false)
        ),
        %% Drive the asynchronous seal iff the backend ADVERTISES the
        %% `async_seal` capability and was opened in `seal_mode => async`.
        %% Gating on the capability (not a hardcoded backend module) keeps the
        %% instance backend-agnostic: a future sealing backend just advertises
        %% `async_seal => true`. Memory backends advertise `false` → no-op.
        drive_seal = drive_seal_enabled(MST, Opts)
    },
    ok = publish(State),
    %% Publish the overlay tid via a dedicated setter so a stale tid
    %% from a previous instance (left behind in a registry row that
    %% outlived a one_for_all restart) is overwritten. Symmetric with
    %% `set_wal_pid/2` / `set_applier_pid/2`.
    ok = bondy_oplog_registry:set_overlay_tab(InstanceId, Overlay),
    %% Publish the substrate read-side AE targets. Top-level instance opt;
    %% immutable for the instance's lifetime. Validation is deferred to
    %% startup: a malformed list crashes init before any peer can interact.
    AeTargets = validate_ae_targets(maps:get(ae_targets, Opts, [])),
    ok = bondy_oplog_registry:set_ae_targets(InstanceId, AeTargets),
    %% Restore the applied-frontier convergence oracle (`#{Origin => max Seq}`)
    %% from THREE durable sources, each max-merged (idempotent, monotone) into
    %% the registry holder published above:
    %%   1. the compaction checkpoint — the COMPACTED prefix's maxima (events
    %%      truncated from the WAL and the MST, recoverable nowhere else);
    %%   2. the live MST's `cell_apply` keys — the uncompacted, already-applied
    %%      events (compaction watermark → durable root). A clean restart resumes
    %%      at the tail, so these never replay and must be folded out directly;
    %%   3. the applier's WAL-tail replay (events past the durable root), which
    %%      tops up on the normal apply path after init.
    %% No recompute fold over the projection and no `warming` state — that was
    %% the cold-boot meltdown. The MST fold is O(live MST), bounded by compaction.
    %% The registry row exists (published above), which `merge_frontier/2`
    %% requires.
    ok = restore_frontier(InstanceId, CachedCheckpoint),
    ok = bondy_oplog_registry:merge_frontier(
        InstanceId, frontier_from_mst(MST)
    ),
    %% Publish the lock-free `append_fast` bundle iff the validator
    %% advertises `is_stateless/0 -> true`. The bundle lets callers
    %% build an event, hit the WAL gen_server directly, and stage
    %% to the overlay without routing through this gen_server.
    ok = bondy_oplog_registry:set_fast_path(
        InstanceId, build_fast_path(State)
    ),
    %% Publish the flow-control handle. The applier reads this once
    %% at its own `init/1` (or lazily on first drain) and gates its
    %% `install_local_batch` dispatch on the cap. The instance owns
    %% the atomic — applier just shares the ref.
    ok = bondy_oplog_registry:set_install_in_flight(
        InstanceId,
        State#state.install_in_flight,
        State#state.max_install_in_flight
    ),
    %% Publish the remote-delivery generation counter backing the
    %% applier's prepare fence (I1) — see the `integrate_peer_root`
    %% handler for the bump site and the applier's `{cell_context, _, _}`
    %% handler for the invariant it enforces. The instance owns the
    %% atomic; the applier shares the ref.
    ok = bondy_oplog_registry:set_remote_gen(
        InstanceId, State#state.remote_gen_ref
    ),
    %% Publish the bootstrap lifecycle handle. The applier reads this
    %% in its own `init/1` and gates the WAL drain on it. The handle is
    %% set once and never replaced — the atomic mirror inside it is
    %% flipped in place when the instance transitions to `live`.
    ok = bondy_oplog_registry:set_lifecycle(
        InstanceId, State#state.lifecycle
    ),
    State1 = maybe_init_fused(State, Opts),
    HeapMonitor = bondy_oplog_heap_monitor:arm(State1#state.heap_monitor),
    {ok, State1#state{heap_monitor = HeapMonitor}}.

%% @private
%% Ephemeral fused-writer setup (fused-writer rollout, Step 3). For a
%% fused instance, build the cell-apply ctx now (the bondy_oplog_core_registry
%% entry is registered before this instance starts) and schedule the
%% deferred WAL-reader open (`handle_info(fused_init)`) — the WAL sibling
%% publishes its pid only after this init returns. No-op for every
%% non-fused (durable + non-fused ephemeral) instance.
maybe_init_fused(#state{fused = false} = State, _Opts) ->
    State;
maybe_init_fused(#state{fused = true} = State, Opts) ->
    ApplierOpts = maps:get(applier, Opts, #{}),
    {ok, CellCtx} = bondy_oplog_applier:resolve_cell_apply_ctx(ApplierOpts),
    FD = #fused_drain{
        iter = undefined,
        cell_apply_ctx = CellCtx,
        %% Rebuild the full per-bucket directory from the registry (every
        %% primary entry sharing this instance's id), so a collapsed per-shard
        %% fused instance restores routing for EVERY table on the shard after a
        %% restart — not just the founding one whose opts the supervisor
        %% replays. A single-table fused instance keeps the keyless
        %% `{single, CellCtx}` source. Mirrors the applier's self-healing init.
        cell_apply_source = bondy_oplog_applier:build_cell_apply_source(
            State#state.instance_id, CellCtx, ApplierOpts
        ),
        consumer_offset = bondy_oplog_wal_state:new_consumer_offset(),
        commit_every = maps:get(commit_every, ApplierOpts, ?FUSED_COMMIT_EVERY),
        apply_batch_max = maps:get(
            apply_batch_max_events, ApplierOpts, ?FUSED_APPLY_BATCH_MAX
        ),
        idle_waiter = undefined,
        %% Already validated at `init/1` (`validate_ae_targets/1`, which
        %% runs before this); the fused commit + remote replay bump them.
        ae_targets = maps:get(ae_targets, Opts, []),
        %% Reached here only for fused instances; the supervisor has already
        %% gated `mem` on `fused`. Anything other than `mem` is the disk WAL.
        wal_backend =
            case maps:get(wal_backend, Opts, disk) of
                mem -> mem;
                _ -> disk
            end
    },
    self() ! fused_init,
    State#state{fused_drain = FD}.

%% @private
%% Returns a fast-path bundle map when the configured validator is
%% stateless (the `is_stateless/0` optional callback returns `true`),
%% or `undefined` otherwise. The bundle is consumed by
%% `bondy_oplog_instance:append_fast/2,3`.
build_fast_path(#state{validator_module = ValidatorMod} = State) ->
    case validator_is_stateless(ValidatorMod) of
        true ->
            #{
                hlc => State#state.hlc,
                seq => State#state.seq,
                overlay_counters => State#state.overlay_counters,
                origin => State#state.origin,
                validator_module => ValidatorMod,
                validator_state => State#state.validator_state,
                max_overlay_events => State#state.max_overlay_events,
                max_overlay_bytes => State#state.max_overlay_bytes,
                max_working_set => State#state.max_working_set,
                overlay_throttle => State#state.overlay_throttle
            };
        false ->
            undefined
    end.

%% @private
validator_is_stateless(Mod) ->
    erlang:function_exported(Mod, is_stateless, 0) andalso
        Mod:is_stateless().

%% @private
%% Validate `ae_targets :: [{atom(), atom(), non_neg_integer()}]` at
%% startup so a typo in the supervisor child-spec surfaces as an init
%% crash rather than a silent freshness regression at the first AE
%% round. Returns the (unchanged) list on success and raises on the
%% first malformed entry; `init/1` is wrapped by the supervisor so the
%% error reaches the caller cleanly.
validate_ae_targets(Targets) when is_list(Targets) ->
    lists:foreach(fun assert_ae_target/1, Targets),
    Targets;
validate_ae_targets(Other) ->
    error({invalid_ae_targets, Other}).

assert_ae_target({NS, Index, Shard}) when
    is_atom(NS),
    is_atom(Index),
    is_integer(Shard),
    Shard >= 0
->
    ok;
assert_ae_target(Bad) ->
    error({invalid_ae_target, Bad}).

handle_call(Req, From, State0) ->
    Result = do_handle_call(Req, From, State0),
    ok = maybe_publish(State0, Result),
    maybe_hibernate_after(Req, Result).

%% @private
%% Hibernate after the heap-heavy anti-entropy handlers. They build large
%% transient terms — the `missing_set` hash set, the `get_pages` page map, the
%% `merge`/`replay_pairs` working set — on this long-lived process, and the heap
%% does not shrink back on its own, so across AAE rounds it accumulates (a major
%% driver of BEAM memory on a cluster doing nothing but periodic AAE). Hibernate
%% forces a fullsweep GC and minimises the process after the reply, returning the
%% heap to its live size; the wake cost on the next message is negligible at
%% AAE's tick rate. Non-AAE replies (the hot write/read path) are untouched.
maybe_hibernate_after(Req, {reply, Reply, State}) ->
    case heap_heavy_aae(Req) of
        true -> {reply, Reply, State, hibernate};
        false -> {reply, Reply, State}
    end;
maybe_hibernate_after(_Req, Result) ->
    Result.

%% @private
%% Buckets "missing" page hashes by their ACTUAL state in the store, which is
%% what names the layer at fault:
%%
%%   - `tombstoned` — the row is intact but `free/3` marked it. The bytes are
%%     still readable, so a walk that called the page missing did not learn
%%     that from the store: a read-path/masking fault.
%%   - `absent`     — the row is gone. Something DELETED a page a live root
%%     references: a store-layer fault.
%%   - `live`       — present and unmarked; the miss was transient, observed
%%     before a concurrent insert became visible.
%%   - `unknown`    — the backend cannot say.
%%
%% Every backend answers through the optional `page_state/2` callback; the two
%% that back production shards (`bondy_mst_ets_store`, `bondy_mst_pack_store`)
%% both implement it, and anything that does not is reported honestly as
%% `unknown` rather than guessed at.
%%
%% Do NOT reintroduce a store-type test here that defaults some backend to
%% `absent`. That was the original shape — a pack-store-only probe with an
%% `{[], Hashes}` fallthrough — and because the ephemeral ETS store `free/3`
%% tombstones rather than deleting, it reported every missing page on a
%% `registry/*` shard as `absent`, making the field that is supposed to
%% identify the faulting layer a mere restatement of `missing`.
classify_missing_pages(MST, Hashes) ->
    Store = bondy_mst:store(MST),
    lists:foldl(
        fun(H, Acc) ->
            Class = classify_page(Store, H),
            maps:update_with(Class, fun(L) -> [H | L] end, [H], Acc)
        end,
        #{},
        Hashes
    ).

%% @private
%% Classify on the TAG only: the epoch a backend carries in `{tombstoned, _}`
%% is a monotonic time on ETS and `undefined` on pack.
classify_page(Store, Hash) ->
    case bondy_mst_store:page_state(Store, Hash) of
        live -> live;
        {tombstoned, _} -> tombstoned;
        absent -> absent;
        unknown -> unknown
    end.

%% @private
heap_heavy_aae({get_pages, _}) -> true;
heap_heavy_aae({missing_set, _}) -> true;
heap_heavy_aae({replay_pairs, _}) -> true;
heap_heavy_aae(cell_directory) -> true;
heap_heavy_aae({merge_pages, _}) -> true;
heap_heavy_aae({integrate_peer_root, _}) -> true;
heap_heavy_aae(root_hash) -> true;
heap_heavy_aae(aae_root) -> true;
heap_heavy_aae(mst_last) -> true;
heap_heavy_aae(_) -> false.

%% @private
%% Publishes the registry row when the handle_call clause changed any
%% field exposed to lock-free readers. We compare only the
%% *published* subset (see `published_fingerprint/1`) because state
%% fields that no reader sees — e.g. the in-process overlay counters
%% maintained by `stage_to_overlay/2` and `evict_overlay_batch/2` —
%% would otherwise force a registry write on every append. Under
%% mixed read/write load that turned a 4 k/s writer into a
%% bottleneck on the registry row's per-key lock bucket and dragged
%% writer throughput by ~7×.
maybe_publish(State0, {reply, _, State1}) ->
    maybe_publish_diff(State0, State1);
maybe_publish(State0, {noreply, State1}) ->
    maybe_publish_diff(State0, State1);
maybe_publish(_State0, _Result) ->
    ok.

maybe_publish_diff(State0, State1) ->
    case published_fingerprint(State0) =:= published_fingerprint(State1) of
        true -> ok;
        false -> publish(State1)
    end.

%% @private
%% Tuple of the fields that `publish/1` writes to the registry. Used
%% by `maybe_publish/2` to skip the ETS write when nothing visible to
%% lock-free readers has changed. `instance_id` and `origin` are
%% immutable post-init so they are not included.
published_fingerprint(#state{} = S) ->
    {
        S#state.mst,
        S#state.watermark,
        S#state.cached_checkpoint,
        S#state.crdt_module,
        S#state.fold_module,
        S#state.fold_opts,
        S#state.live_size
    }.

%% @private
do_handle_call({append, Op, Meta}, _From, State0) ->
    %% Pressure check → WAL append (fsync) → overlay insert → reply.
    %% The reply happens inline as soon as the WAL is durable and
    %% the overlay row exists; the applier drains the WAL and casts
    %% `install_local_batch` back to this gen_server, which promotes
    %% the event to the MST and evicts the overlay row.
    case admit(State0, 1) of
        ok ->
            case ensure_wal_pid(State0) of
                {ok, WalPid, State1} ->
                    case do_append_local(State1, WalPid, [{Op, Meta}]) of
                        {ok, [Key], State2} ->
                            {reply, Key, State2};
                        {error, wal_unavailable} ->
                            {reply, {error, wal_unavailable},
                                invalidate_wal_pid(State1)};
                        {error, _} = Err ->
                            {reply, Err, State1}
                    end;
                {error, _} = Err ->
                    {reply, Err, State0}
            end;
        {error, _} = Err ->
            {reply, Err, State0}
    end;
do_handle_call({append_many, Items}, _From, State0) ->
    case admit(State0, length(Items)) of
        ok ->
            case ensure_wal_pid(State0) of
                {ok, WalPid, State1} ->
                    case do_append_local(State1, WalPid, Items) of
                        {ok, Keys, State2} ->
                            {reply, Keys, State2};
                        {error, wal_unavailable} ->
                            {reply, {error, wal_unavailable},
                                invalidate_wal_pid(State1)};
                        {error, _} = Err ->
                            {reply, Err, State1}
                    end;
                {error, _} = Err ->
                    {reply, Err, State0}
            end;
        {error, _} = Err ->
            {reply, Err, State0}
    end;
do_handle_call(get_validator, _From, State) ->
    {reply, {State#state.validator_module, State#state.validator_state}, State};
do_handle_call(
    {register_table, _Bucket, _Target, _TableOpts},
    _From,
    #state{fused_drain = undefined} = State
) ->
    %% Only a fused instance routes table registration here; the applier path
    %% handles non-fused instances. Surface an explicit error if mis-routed.
    {reply, {error, not_fused}, State};
do_handle_call(
    {register_table, Bucket, Target, TableOpts}, _From, State
) ->
    FD0 = State#state.fused_drain,
    Opts = TableOpts#{cell_apply_target => Target},
    case bondy_oplog_applier:resolve_cell_apply_ctx(Opts) of
        {ok, Ctx} ->
            Source = bondy_oplog_mux:put(
                FD0#fused_drain.cell_apply_source, Bucket, Ctx
            ),
            AeTargets = lists:usort([Target | FD0#fused_drain.ae_targets]),
            %% Mirror the applier: publish the unioned AE-freshness targets to
            %% the instance registry so the AE heartbeat / isolated bump
            %% (`bondy_oplog_sync_session:do_bump_ae_targets/2`) freshens this
            %% sibling table's shard too.
            ok = bondy_oplog_registry:set_ae_targets(
                State#state.instance_id, AeTargets
            ),
            FD = FD0#fused_drain{
                cell_apply_source = Source, ae_targets = AeTargets
            },
            {reply, ok, State#state{fused_drain = FD}};
        {error, _} = Err ->
            {reply, Err, State}
    end;
do_handle_call(
    {unregister_table, _Bucket}, _From, #state{fused_drain = undefined} = State
) ->
    {reply, {error, not_fused}, State};
do_handle_call({unregister_table, Bucket}, _From, State) ->
    FD0 = State#state.fused_drain,
    Source = bondy_oplog_mux:remove(
        FD0#fused_drain.cell_apply_source, Bucket
    ),
    FD = FD0#fused_drain{cell_apply_source = Source},
    {reply, ok, State#state{fused_drain = FD}};
do_handle_call(
    cell_directory, _From, #state{mst = undefined} = State
) ->
    {reply, {ok, []}, State};
do_handle_call(
    cell_directory, _From, #state{mst = MST} = State
) ->
    %% Fold runs in THIS (the MST-owning) process; see `cell_directory/1`.
    {reply, {ok, bondy_oplog_cell_utils:distinct_cell_keys(MST)}, State};
do_handle_call(
    {replay_pairs, _LastRoot}, _From, #state{mst = undefined} = State
) ->
    {reply, {ok, no_change}, State};
do_handle_call(
    {replay_pairs, LastRoot}, _From, #state{mst = MST, instance_id = Id} = State
) ->
    %% Fold runs in THIS (the MST-owning) process; see `replay_pairs/2`.
    CurrentRoot = bondy_mst:root(MST),
    Reply =
        case CurrentRoot of
            LastRoot ->
                {ok, no_change};
            _ ->
                Pairs = bondy_oplog_applier:diff_pairs(MST, LastRoot, Id),
                {ok, {CurrentRoot, Pairs}}
        end,
    {reply, Reply, State};
do_handle_call(drain_install_queue, _From, State0) ->
    %% Synchronisation barrier for the applier's commit boundary.
    %% Calls jump past casts in the mailbox order, so by the time
    %% this call is processed, every prior `install_local_batch`
    %% cast has been handled. The reply itself carries no payload.
    %%
    %% This is also the MST root durability barrier. Every install_local_batch
    %% merged its events into the MST and staged the new root in memory
    %% (`bondy_mst_pack_writer:set_root/2` only rewrites the manifest lazily);
    %% by flushing here we advance the on-disk root in lockstep with the WAL
    %% `consumer.offset` commit_now/1 is about to write. That bounds crash
    %% replay to one commit window — without it the on-disk root lags the
    %% debounce, `resume_position/2` reads a stale root and replays the whole
    %% WAL, and the compaction watermark never advances so the WAL never
    %% truncates. No-op for ephemeral (ets/map) backends.
    %%
    %% With `seal_mode => async` this is also where the instance rolls the
    %% incoming pack aside and spawns the seal worker — the durable root is
    %% now flushed, so the rolled pages are durable before the seal commits.
    State = maybe_drive_seal(flush_mst_root(State0)),
    {reply, ok, State};
do_handle_call(await_overlay_drained, From, State) ->
    %% Event-driven `await_apply/1,2`. Reply inline when the overlay
    %% is already empty; otherwise queue the caller and let
    %% `maybe_signal_drain_waiters/1` reply when an install handler
    %% next observes overlay_size == 0. The call has already jumped
    %% past pending `install_local_batch` casts (gen_server mailbox
    %% order), so the visible overlay size here reflects every event
    %% the applier has already dispatched to this instance.
    case overlay_size_tab(State#state.overlay) of
        0 ->
            {reply, ok, State};
        _ ->
            Waiters = State#state.drain_waiters,
            {noreply, State#state{drain_waiters = [From | Waiters]}}
    end;
do_handle_call(
    {enqueue_remote, Event},
    From,
    #state{validator_module = Mod, validator_state = VS, instance_id = Id} =
        State
) ->
    %% Fused-mode remote entry (Step 4): the analog of the applier's
    %% `{enqueue_remote, Event}` handler, run in the instance because a
    %% fused instance has no applier. Spawn-and-reply: free the instance
    %% mailbox immediately so the WAL drain (`handle_info(fused_drain, _)`)
    %% and other remote events interleave. The worker captures the
    %% read-only validator snapshot + this instance's pid + the caller's
    %% `From`, verifies, forwards verified events back to THIS instance for
    %% origin-ban / backpressure / watermark / install (the existing
    %% `{install_remote, Event}` clause), and replies on the instance's
    %% behalf. The outer try/catch guarantees the `infinity` caller never
    %% hangs.
    InstancePid = self(),
    _ = spawn(fun() ->
        try
            Reply =
                case Mod:verify_event(Event, VS) of
                    ok ->
                        fused_forward_remote(InstancePid, Event);
                    {error, Reason} = VerifyErr ->
                        ?LOG_WARNING(#{
                            description =>
                                "bondy_oplog_instance fused verify worker "
                                "rejected a remote event",
                            instance_id => Id,
                            reason => Reason
                        }),
                        VerifyErr
                end,
            gen_server:reply(From, Reply)
        catch
            C:R:S ->
                ?LOG_WARNING(#{
                    description =>
                        "bondy_oplog_instance fused verify worker raised "
                        "before delivering a reply; the remote event has "
                        "been rejected",
                    instance_id => Id,
                    class => C,
                    reason => R,
                    stacktrace => S
                }),
                try
                    gen_server:reply(From, {error, {verify_crashed, R}})
                catch
                    _:_ -> ok
                end
        end
    end),
    {noreply, State};
do_handle_call({install_remote, Event}, _From, State0) ->
    %% Sole install path for peer-received events. Signature
    %% verification ran in the applier process (see
    %% `bondy_oplog_applier:enqueue_remote/2`), or — for a fused instance —
    %% in this instance's own verify worker (the `{enqueue_remote, Event}`
    %% clause above), before this call, so
    %% we trust the event and run the remaining accept/reject checks:
    %% origin-ban, backpressure, watermark filter, and the
    %% `bondy_mst:get` three-way (undefined/match/equivocation).
    Origin = bondy_oplog_event:key_origin(bondy_oplog_event:key(Event)),
    case bondy_oplog_origin_bans:is_banned(Origin) of
        true ->
            telemetry:execute(
                [bondy_oplog, instance, append_remote, banned],
                #{count => 1},
                #{instance_id => State0#state.instance_id, origin => Origin}
            ),
            {reply, {error, banned_origin}, State0};
        false ->
            %% Backpressure applies to remote events too — a
            %% misbehaving peer must not be able to drive our working
            %% set arbitrarily high. Idempotent re-receives slip past
            %% this check and are treated as no-ops downstream.
            case backpressure_admit(State0, 1) of
                {error, _} = BPErr ->
                    {reply, BPErr, State0};
                ok ->
                    case do_append_remote(State0, Event) of
                        {ok, State} ->
                            {reply, ok, State};
                        {error, _} = Error ->
                            {reply, Error, State0}
                    end
            end
    end;
do_handle_call({get, Key}, _From, #state{mst = MST, overlay = Overlay} = State) ->
    %% pid-targeted path: same overlay-first → MST order as the
    %% lock-free `get/2`.
    Reply =
        case overlay_lookup_tab(Overlay, Key) of
            {ok, _} = Hit ->
                Hit;
            not_found ->
                case bondy_mst:get(MST, Key) of
                    undefined -> not_found;
                    Value -> {ok, event_from_value(Key, Value)}
                end
        end,
    {reply, Reply, State};
do_handle_call(root_hash, _From, #state{mst = MST} = State) ->
    {reply, bondy_mst:root(MST), State};
do_handle_call(aae_root, _From, #state{mst = MST} = State) ->
    %% AAE-advertise guard: only advertise a root we can fully serve.
    case bondy_mst:root(MST) of
        undefined ->
            %% Empty is trivially servable (nothing to serve).
            {reply, undefined, State#state{unservable_since = undefined}};
        Root ->
            case State#state.aae_root_check of
                {Root, true} ->
                    {reply, Root, State};
                {Root, false} ->
                    {reply, undefined, State};
                _ ->
                    %% Root changed (or first check): re-evaluate once.
                    Servable = [] =:= bondy_mst:missing_set(MST, Root),
                    Servable orelse
                        ?LOG_WARNING(#{
                            description =>
                                "Refusing to advertise a dangling MST root "
                                "over anti-entropy; advertising empty so peers "
                                "do not pull unservable pages. Transient "
                                "(truncate/GC race) heals next round; a "
                                "PERSISTENT streak triggers the compaction-"
                                "path self-heal (mst_rebuilt).",
                            instance_id => State#state.instance_id,
                            root => Root
                        }),
                    Since =
                        case Servable of
                            true ->
                                undefined;
                            false when
                                State#state.unservable_since =/=
                                    undefined
                            ->
                                State#state.unservable_since;
                            false ->
                                erlang:monotonic_time(millisecond)
                        end,
                    State1 = State#state{
                        aae_root_check = {Root, Servable},
                        unservable_since = Since
                    },
                    Reply =
                        case Servable of
                            true -> Root;
                            false -> undefined
                        end,
                    {reply, Reply, State1}
            end
    end;
do_handle_call(diagnose_root, _From, #state{mst = MST} = State) ->
    Reply =
        case bondy_mst:root(MST) of
            undefined ->
                #{root => undefined, servable => true};
            Root ->
                Missing = bondy_mst:missing_set(MST, Root),
                Classified = classify_missing_pages(MST, Missing),
                Get = fun(K) -> maps:get(K, Classified, []) end,
                #{
                    root => Root,
                    servable => Missing =:= [],
                    missing => length(Missing),
                    %% readable in the store, yet the walk called them
                    %% missing — a read-side/masking fault
                    tombstoned => length(Get(tombstoned)),
                    sample_tombstoned => lists:sublist(Get(tombstoned), 3),
                    %% deleted while a live root still references them —
                    %% a store-layer fault
                    absent => length(Get(absent)),
                    sample_absent => lists:sublist(Get(absent), 3),
                    %% present and unmarked: a transient miss
                    live => length(Get(live)),
                    %% the backend cannot classify (no `page_state/2`)
                    unknown => length(Get(unknown))
                }
        end,
    {reply, Reply, State};
do_handle_call(
    {fold_range, From, To, Fun, Acc0},
    _From,
    #state{mst = MST, overlay = Overlay} = State
) ->
    %% Streaming merge with strict ascending key order; overlay wins
    %% on conflict. The overlay queue is materialised once
    %% (`ets:select` on `ordered_set` yields key-ordered rows) and
    %% drained as the MST fold walks.
    OverlayQueue = overlay_range_tab(Overlay, From, To),
    Result = fold_range_merged(MST, From, To, OverlayQueue, Fun, Acc0),
    {reply, Result, State};
do_handle_call({truncate_prefix, Watermark}, _From, #state{mst = MST0} = State) ->
    %% Operator-driven prefix removal: structurally drop every key
    %% `=< Watermark` via `bondy_mst:truncate/2` (an O(log N) left-spine
    %% rewrite), counting the removed events first for `live_size`
    %% bookkeeping.
    %%
    %% Also advances `state.watermark` so the receive-side filter in
    %% `do_append_remote/2` rejects re-shipped peer events with
    %% HLC ≤ Watermark (already applied here — the live door only
    %% accepts at-or-below-watermark events the applied VV does NOT
    %% witness). Without this, peers that have not yet seen the
    %% truncate would keep re-shipping the events we just dropped,
    %% defeating the purpose of the call. No snapshot is written at the new
    %% watermark — operator-driven truncate is documented as lossy for
    %% bootstrap consumers (see `bondy_oplog:truncate_prefix/2`). The
    %% watermark advance is monotone: a Watermark lower than the
    %% current `state.watermark` is ignored so compaction-set values
    %% are never regressed.
    Removed = count_in_open_range(MST0, undefined, Watermark),
    MST1 = bondy_mst:truncate(MST0, Watermark),
    NewWatermark = advance_watermark(State#state.watermark, Watermark),
    _ = bondy_oplog_hlc:update(
        State#state.hlc, bondy_oplog_event:key_hlc(Watermark)
    ),
    {reply, Removed, State#state{
        mst = MST1,
        live_size = max(0, State#state.live_size - Removed),
        watermark = NewWatermark
    }};
do_handle_call(instance_size, _From, State) ->
    %% `live_size` + overlay row count, read in the same handler so
    %% no `install_local_batch` cast can interleave between the two —
    %% see `size/1`. Slot 1 of `overlay_counters` is shared with
    %% `append_fast/2,3`, so it can transiently grow during this read
    %% (a concurrent caller appending) but cannot shrink (only this
    %% gen_server's `evict_overlay_batch/2` decrements it). The
    %% returned value is therefore monotone over the read window.
    Total =
        State#state.live_size +
            atomics:get(State#state.overlay_counters, 1),
    {reply, Total, State};
do_handle_call(origin, _From, State) ->
    {reply, State#state.origin, State};
do_handle_call(first_key, _From, #state{mst = MST, overlay = Overlay} = State) ->
    Reply = merge_first_key_tab(Overlay, MST),
    {reply, Reply, State};
do_handle_call(mst_last, _From, #state{mst = undefined} = State) ->
    {reply, undefined, State};
do_handle_call(mst_last, _From, #state{mst = MST} = State) ->
    %% Runs in the instance process, which owns the pack store's raw fds, so the
    %% sealed-pack `pread` behind `bondy_mst:last/1` is on its controlling
    %% process. The applier consumes this for `resume_position/2`.
    {reply, bondy_mst:last(MST), State};
do_handle_call(latest_key, _From, #state{mst = MST, overlay = Overlay} = State) ->
    Reply = merge_latest_key_tab(Overlay, MST),
    {reply, Reply, State};
do_handle_call(instance_id, _From, State) ->
    {reply, State#state.instance_id, State};
do_handle_call(info, _From, State) ->
    Info = #{
        instance_id => State#state.instance_id,
        origin => State#state.origin,
        backend => State#state.backend,
        validator => State#state.validator_module,
        fold_module => State#state.fold_module,
        fold_opts => State#state.fold_opts,
        last_event_key => State#state.last_event_key
    },
    {reply, Info, State};
do_handle_call({get_pages, Hashes}, _From, #state{mst = MST} = State) ->
    Store = bondy_mst:store(MST),
    Pages = lists:foldl(
        fun(Hash, Acc) ->
            case bondy_mst_store:get(Store, Hash) of
                undefined -> Acc;
                Page -> Acc#{Hash => Page}
            end
        end,
        #{},
        Hashes
    ),
    {reply, Pages, State};
do_handle_call({merge_pages, Pages}, _From, #state{mst = MST0} = State) ->
    %% Page collection during anti-entropy. We only insert pages into
    %% the underlying store — the local root is *not* changed here, so
    %% no event becomes visible to readers and live_size is unaffected.
    %% The actual merge (root advance) is deferred to integrate_peer_root,
    %% which runs once the sync session has loaded every required page.
    %% This matches the bondy_mst_crdt anti-entropy pattern: the local
    %% tree is only mutated when the merge is fully prepared.
    MST = lists:foldl(
        fun(Page, Acc0) ->
            {_Hash, Acc1} = bondy_mst:put_page(Acc0, Page),
            Acc1
        end,
        MST0,
        Pages
    ),
    {reply, ok, State#state{mst = MST}};
do_handle_call({missing_set, Root}, _From, #state{mst = MST} = State) ->
    {reply, bondy_mst:missing_set(MST, Root), State};
do_handle_call(
    {integrate_peer_root, PeerRoot},
    _From,
    #state{mst = MST0} = State000
) ->
    %% ATOMIC pre-condition re-check: the session verified
    %% `missing_set == []` one call earlier, but this instance's own
    %% compaction (its ETS page GC sweeps everything unreachable from
    %% the CURRENT root — which pulled-but-unmerged peer pages are) can
    %% interleave between that check and this handler. Re-checking HERE
    %% is race-free — the GC only runs in this process — and a missing
    %% page must fail the call: `bondy_mst:merge/3` silently treats an
    %% unresolvable subtree as empty, which loses every event under it
    %% while the session records the round as complete.
    case bondy_mst:missing_set(MST0, PeerRoot) of
        [] ->
            do_integrate_peer_root(PeerRoot, State000);
        Missing ->
            {reply, {error, {peer_pages_missing, length(Missing)}}, State000}
    end;
do_handle_call({pin_peer_root, Root}, _From, State) when is_binary(Root) ->
    Now = erlang:monotonic_time(millisecond),
    Pins = maps:filter(
        fun(_, T) -> Now - T =< ?PEER_ROOT_PIN_TTL_MS end,
        State#state.pinned_peer_roots
    ),
    {reply, ok, State#state{pinned_peer_roots = Pins#{Root => Now}}};
do_handle_call(current_watermark, _From, State) ->
    {reply, State#state.watermark, State};
do_handle_call(crdt_module, _From, State) ->
    {reply, State#state.crdt_module, State};
do_handle_call(get_compaction_checkpoint, _From, State) ->
    Reply = (State#state.compaction_checkpoint):get_checkpoint(
        State#state.compaction_checkpoint_state
    ),
    {reply, Reply, State};
do_handle_call(
    {compact, _PeerRoots},
    _From,
    #state{
        pending_compaction = P
    } = State
) when P =/= undefined ->
    %% A two-step compaction catch-up is already in flight (awaiting the
    %% applier's `{catch_up_done, _}`). Skip this tick — compaction is
    %% idempotent and the next tick retries once the in-flight one
    %% commits or aborts.
    {reply, {ok, no_change}, State};
do_handle_call({compact, PeerRoots}, _From, State) ->
    do_compact_sync(State, PeerRoots);
do_handle_call({load_snapshot, NewWatermark, Snapshot}, _From, State) ->
    do_load_snapshot(State, NewWatermark, Snapshot);
do_handle_call(
    mark_live,
    _From,
    #state{lifecycle = LC, instance_id = Id} = State
) ->
    ok = bondy_oplog_bootstrap_lifecycle:mark_live(LC),
    ok = nudge_applier(Id),
    {reply, ok, State};
do_handle_call(lifecycle_state, _From, #state{lifecycle = LC} = State) ->
    {reply, bondy_oplog_bootstrap_lifecycle:state(LC), State};
do_handle_call(persist_frontier, _From, State) ->
    %% Reuse the exact `terminate/2` persist path (same checkpoint payload and
    %% watermark), just driven on demand — used after a catalogue bootstrap so
    %% the adopted frontier is durable before any restart. No-op on ephemeral.
    _ = maybe_persist_frontier(
        State#state.instance_id,
        State#state.backend,
        State#state.watermark,
        State#state.compaction_checkpoint,
        State#state.compaction_checkpoint_state
    ),
    {reply, ok, State};
do_handle_call(reclamation_stability_point, _From, State) ->
    {reply, reclamation_stability_point(State), State};
do_handle_call({persist_frontier, AbsorbHlc}, From, State) when
    is_integer(AbsorbHlc), AbsorbHlc >= 0
->
    %% A3 — absorb the maximum installed cell HLC into the local clock BEFORE
    %% the frontier is persisted and the instance can be marked live. The
    %% catalogue install wrote peer cells carrying remote HLCs straight into
    %% the projection; the clock must dominate them or this replica can mint
    %% events below a stability point computed from those very cells. The
    %% AAE-path absorb cannot rescue this case: it reads `bondy_mst:last/1`,
    %% which is `undefined` exactly when the peer has compacted. Over-
    %% absorption is safe — `update/2` only ever advances the clock.
    _ =
        AbsorbHlc > 0 andalso
            bondy_oplog_hlc:update(State#state.hlc, AbsorbHlc),
    do_handle_call(persist_frontier, From, State);
do_handle_call(
    {cell_context, _Bucket, _Key},
    _From,
    #state{fused_drain = undefined} = State
) ->
    %% Not a fused instance (or not yet bootstrapped) — no per-cell
    %% resolution source of its own; the caller (`bondy_db:cell_context/3`)
    %% only reaches here when no applier was found either.
    {reply, {error, no_cell_apply_target}, State};
do_handle_call(
    {cell_context, Bucket, Key},
    _From,
    #state{
        instance_id = Id,
        fused_drain = #fused_drain{
            cell_apply_source = Source, cell_apply_ctx = Founding
        },
        ctx_guard = Guard
    } = State
) ->
    %% Mirrors `bondy_oplog_applier`'s `{cell_context, Bucket, Key}` handler
    %% exactly, reading via THIS instance's own in-process state (a fused
    %% instance has no separate applier to delegate to). I1
    %% (prepare-after-deliver — see `bondy_oplog_applier:
    %% ensure_remote_caught_up/1` for the invariant and theorem) holds
    %% here WITHOUT a fence: `integrate_peer_root` folds peer events
    %% into the projection inline in this same process, so any context
    %% read serialised after it necessarily sees them. See that clause's
    %% doc for the read/decode rationale and the single-applier-scope /
    %% read-then-append race note — identical here, single-instance-scope.
    case resolve_cell_ctx(Source, Bucket, Founding) of
        undefined ->
            {reply, {error, no_cell_apply_target}, State};
        #{
            adapter := Adapter,
            handle := Handle,
            kernel := Kernel,
            crdt_module := CrdtMod
        } = CellCtx ->
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
            {Reply, Guard1} = bondy_oplog_ctx_guard:stamp(
                Id, Guard, Bucket, Key, Context
            ),
            {reply, Reply, State#state{ctx_guard = Guard1}}
    end;
do_handle_call(
    {reap_origins, _Retired},
    _From,
    #state{fused_drain = undefined} = State
) ->
    {reply, {error, no_cell_apply_target}, State};
do_handle_call(
    {reap_origins, Retired},
    _From,
    #state{
        instance_id = Id,
        fused_drain = #fused_drain{cell_apply_source = Source},
        ctx_guard = Guard
    } = State
) ->
    %% Mirrors `bondy_oplog_applier`'s `{reap_origins, Retired}` handler —
    %% delegates to the shared `bondy_oplog_cell_utils`, which this instance
    %% runs in-process (no separate applier to delegate to).
    {Reply, Guard1} = bondy_oplog_cell_utils:reap(Id, Guard, Source, Retired),
    {reply, Reply, State#state{ctx_guard = Guard1}};
do_handle_call(
    {sweep_stable_cells, _StableHlc, _Opts},
    _From,
    #state{fused_drain = undefined} = State
) ->
    {reply, {error, no_projection}, State};
do_handle_call(
    {sweep_stable_cells, StableHlc, Opts},
    _From,
    #state{
        instance_id = Id,
        ctx_guard = Guard,
        fused_drain = #fused_drain{
            cell_apply_source = Source, cell_apply_ctx = Ctx
        }
    } = State
) ->
    %% Mirrors `bondy_oplog_applier`'s `{sweep_stable_cells, _, _}` handler —
    %% delegates to the shared `bondy_oplog_cell_utils`, which this
    %% instance runs in-process (no separate applier to delegate to). No
    %% remote-generation fence is needed here, unlike the applier's
    %% handler: a fused instance folds remote events into the projection
    %% INLINE at `integrate_peer_root`, in this same process, so this
    %% call is serialized after every delivery it must observe (I1 holds
    %% by construction — see `bondy_oplog_applier:ensure_remote_caught_up/1`).
    {Reply, Guard1} = bondy_oplog_cell_utils:sweep(
        Id, Guard, Ctx, Source, StableHlc, Opts
    ),
    {reply, Reply, State#state{ctx_guard = Guard1}};
do_handle_call(
    rederive_projection,
    _From,
    #state{fused_drain = undefined} = State
) ->
    {reply, {error, no_cell_apply_target}, State};
do_handle_call(
    rederive_projection,
    _From,
    #state{
        instance_id = Id,
        mst = MST,
        fused_drain = #fused_drain{cell_apply_source = Source}
    } = State
) ->
    %% Mirrors `bondy_oplog_applier`'s `rederive_projection` handler — the
    %% full re-apply of every retained MST event, restoring a cell that a
    %% `replace`-mode catalogue install clobbered on a live re-bootstrap
    %% (the peer's higher-HLC cell can omit ops the peer had not applied
    %% when its snapshot was cut). Re-delivering an op a cell already
    %% holds is idempotent (the kernel's per-origin causal metadata
    %% rejects it); a missing op integrates — the op-based replacement
    %% for CvRDT `merge_states`, same as the applier path. Runs in the
    %% gen_server, serialized with the fused drain, and the MST fold is
    %% already in-process (no separate applier to delegate to).
    Pairs =
        case MST of
            undefined -> [];
            _ -> bondy_mst:to_list(MST)
        end,
    %% Deliberately the non-holding mux: this is a one-shot full fold
    %% with no replay cursor to re-present a held event — a hold here
    %% would leave the projection missing it with nothing to retry.
    Count = bondy_oplog_cell_apply:apply_cell_pairs_mux(
        Source, Id, Pairs, bondy_oplog_registry:origin(Id)
    ),
    telemetry:execute(
        [bondy_oplog, instance, rederive_projection],
        #{cells_applied => Count, pairs => length(Pairs)},
        #{instance_id => Id}
    ),
    {reply, ok, State};
do_handle_call(
    {install_catalogue_batch, _Cells},
    _From,
    #state{fused_drain = undefined} = State
) ->
    %% Not a fused instance (or not yet initialized) — the id-level API
    %% only routes here for fused instances, so this is a raced/misplaced
    %% call.
    {reply, {error, no_cell_apply_target}, State};
do_handle_call(
    {install_catalogue_batch, Cells},
    _From,
    #state{
        instance_id = Id,
        fused_drain = #fused_drain{cell_apply_source = Source}
    } = State
) ->
    %% Mirrors `bondy_oplog_applier`'s `{install_catalogue_batch, _}`
    %% handler — delegates to the shared applier-state-free body over THIS
    %% instance's own cell-apply source (a fused instance has no separate
    %% applier to delegate to). Runs in the gen_server, serialized with
    %% the fused drain, so an install never interleaves with an apply.
    Reply = bondy_oplog_applier:install_catalogue_cells(Id, Source, Cells),
    {reply, Reply, State};
do_handle_call(
    cell_apply_target,
    _From,
    #state{fused_drain = undefined} = State
) ->
    {reply, undefined, State};
do_handle_call(
    cell_apply_target,
    _From,
    #state{fused_drain = #fused_drain{cell_apply_ctx = Ctx}} = State
) ->
    %% Mirrors `bondy_oplog_applier`'s `cell_apply_target` handler exactly
    %% (same founding-ctx-only scope), reading via this instance's own
    %% `#fused_drain{}` (a fused instance has no separate applier to
    %% delegate to).
    Reply =
        case Ctx of
            #{shard_key := ShardKey} -> {ok, ShardKey};
            _ -> undefined
        end,
    {reply, Reply, State};
do_handle_call(
    rebuild_indexes,
    _From,
    #state{fused_drain = undefined} = State
) ->
    {reply, ok, State};
do_handle_call(
    rebuild_indexes,
    _From,
    #state{
        instance_id = Id,
        fused_drain = #fused_drain{cell_apply_ctx = Ctx}
    } = State
) when Ctx =/= undefined ->
    %% Mirrors `bondy_oplog_applier`'s `rebuild_indexes` handler exactly
    %% (same founding-ctx-only scope), delegating to the shared
    %% `bondy_oplog_cell_utils` (a fused instance has no separate
    %% applier to delegate to).
    case bondy_oplog_cell_apply:sec_idx(Ctx) of
        {_NS, []} ->
            ok;
        SecIdx ->
            bondy_oplog_cell_utils:reindex(Id, Ctx, SecIdx)
    end,
    {reply, ok, State};
do_handle_call(rebuild_indexes, _From, State) ->
    {reply, ok, State};
do_handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast({install_local_batch, Events}, State0) ->
    %% Sole dispatch path for local-event MST installs. The applier
    %% verifies signatures in its own process and casts the surviving
    %% events here. We fold `install_event` over them in WAL order,
    %% publish once at the end (one ETS write per batch), then
    %% HLC-conditionally evict the matching overlay rows. MST publish
    %% strictly precedes overlay evict so a reader missing the
    %% overlay row finds the entry in the MST instead.
    %%
    %% A4 — instance-side install coalescing. When the applier outruns
    %% the instance, several `install_local_batch` casts queue in the
    %% mailbox while we are mid-`put_batch`. We drain the queued ones
    %% (up to `install_coalesce_max`) and merge every cast's events into
    %% a SINGLE `put_batch` + publish + overlay-evict, amortising the
    %% O(log n) spine rebuild — the dominant per-event durable cost
    %% (A0b) — over many casts' worth of events.
    %%
    %% The drain matches only `install_local_batch` casts and preserves
    %% their FIFO (= WAL = HLC) order. It may skip past queued peer
    %% `install_remote` / `drain_install_queue` / `await_overlay_drained`
    %% *calls*; this is convergence-safe: local and peer events have
    %% disjoint MST keys (different origin) and disjoint per-origin
    %% watermarks, so a reordered local-ahead-of-peer install yields the
    %% same final MST (merge is commutative/idempotent); overlay evict is
    %% per-event HLC-conditional (order-independent); and the local
    %% applier blocks on `drain_install_queue`, so no install cast is
    %% ever queued behind that barrier (the barrier cannot be skipped).
    {EventsRev, NCasts} = drain_install_casts(
        [Events], 1, State0#state.install_coalesce_max
    ),
    AllEvents = lists:append(lists:reverse(EventsRev)),
    State1 = install_local_batch(State0, AllEvents),
    ok = publish(State1),
    State2 = evict_overlay_batch(State1, AllEvents),
    State3 = maybe_signal_drain_waiters(State2),
    ok = release_install_slots(State3, NCasts),
    {noreply, State3};
handle_cast(check_drain_waiters, State) ->
    %% Sent by the applier after `evict_rejected_overlay/2` evicts
    %% events for which no `install_local_batch` cast will be issued
    %% (the verify step rejected the whole batch). Without this hint a
    %% caller blocked in `await_overlay_drained` would wait until the
    %% next install batch shrank the overlay, even though the overlay
    %% is already empty.
    {noreply, maybe_signal_drain_waiters(State)};
handle_cast(
    {catch_up_done, Token},
    #state{
        pending_compaction = #pending_compaction{
            token = Token,
            frontier = Frontier,
            remote_gen = StartGen,
            started = Started
        }
    } = State
) when State#state.remote_gen =:= StartGen ->
    %% Step 2 of the async catalogue catch-up. The applier confirmed the
    %% remote pairs are folded into the projection AND no peer event entered
    %% the MST during the catch-up window (`remote_gen` unchanged), so it is
    %% safe to drop the stable prefix. Truncate + re-anchor + publish.
    {_Reply, State1} = finalize_catalogue_compaction(State, Started, Frontier),
    ok = publish(State1),
    {noreply, State1};
handle_cast(
    {catch_up_done, Token},
    #state{pending_compaction = #pending_compaction{token = Token}} = State
) ->
    %% A peer event landed during the catch-up window (`remote_gen`
    %% advanced past the value captured at step 1). The applier folded the
    %% (now possibly-stale) pairs idempotently, but truncating at this
    %% frontier could drop the NEW remote event un-folded — so ABORT, leave
    %% `remote_events_pending` set, and let the next compaction tick
    %% recompute the frontier + catch-up against the fresh state.
    {noreply, State#state{pending_compaction = undefined}};
handle_cast({catch_up_done, _Token}, State) ->
    %% Stale/superseded `{catch_up_done, _}` (no matching pending
    %% compaction — already committed, aborted, or timed out). Ignore.
    {noreply, State};
handle_cast(
    {refresh_validator, Reason},
    #state{
        instance_id = Id,
        validator_module = Mod,
        validator_state = VS
    } = State
) ->
    %% Mirrors `bondy_oplog_applier`'s `{refresh_validator, Reason}` cast —
    %% delegates to the shared `bondy_oplog_validator_refresh`, which this
    %% instance runs against its own validator fields (no separate applier
    %% to delegate to).
    NewVS = bondy_oplog_validator_refresh:refresh(Id, Reason, Mod, VS),
    {noreply, State#state{validator_state = NewVS}};
handle_cast({fill_burned_seqs, Start, End, Attempt}, State) ->
    %% Requested by `release_seq_range/3` when a rejected batch's seq
    %% range was overtaken and could not be returned to the counter.
    {noreply, fill_burned_seqs(State, Start, End, Attempt)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(
    {'DOWN', Ref, process, _Pid, _Reason},
    #state{wal_pid_monitor = Ref} = State
) ->
    %% Cached WAL pid has gone down (one_for_all restart); drop the
    %% cache so the next append re-resolves the new pid via the
    %% registry.
    {noreply, State#state{wal_pid = undefined, wal_pid_monitor = undefined}};
handle_info(fused_init, State) ->
    %% Deferred fused-drain WAL-reader open (Step 3). Retries until the
    %% WAL sibling has published its pid.
    {noreply, fused_open_reader(State)};
handle_info(fused_drain, State) ->
    %% A fused-drain wakeup (init kick, more-loop continuation, or an
    %% idle-waiter DOWN). Drain the WAL into the projection + MST inline.
    %% `run_fused_drain/1` returns `{stop, Reason, State}` when it hits an
    %% unrecoverable mem-WAL gap (see `fused_park_or_retry/1`).
    case run_fused_drain(State) of
        {stop, Reason, State1} -> {stop, Reason, State1};
        State1 -> {noreply, State1}
    end;
handle_info(gc_tick, #state{heap_monitor = HM0} = State) ->
    %% Periodic heap monitor (see `bondy_oplog_heap_monitor`). It re-arms the
    %% tick and fullsweep-hibernates the instance iff its heap has grown past
    %% the configured delta over the post-GC baseline — returning transient
    %% apply/AAE garbage (most visibly a solo import with no AAE-driven
    %% hibernate to reclaim it) before the heap climbs unbounded, while a
    %% large live MST is never GC-thrashed. Zero cost to the hot append/drain
    %% path; the reclaim is driven entirely from here.
    case bondy_oplog_heap_monitor:handle_tick(HM0) of
        {hibernate, HM} ->
            {noreply, State#state{heap_monitor = HM}, hibernate};
        {ok, HM} ->
            {noreply, State#state{heap_monitor = HM}}
    end;
handle_info(
    {'DOWN', MRef, process, _Pid, _Reason},
    #state{fused_drain = #fused_drain{idle_waiter = MRef} = FD} = State
) ->
    %% The parked fused idle waiter signalled: the WAL durable position
    %% advanced past our read offset (new frame) or the await timed out.
    %% Either way, re-drain (a spurious wakeup simply re-arms).
    self() ! fused_drain,
    {noreply, State#state{
        fused_drain = FD#fused_drain{idle_waiter = undefined}
    }};
handle_info(
    {compaction_catch_up_timeout, Token},
    #state{pending_compaction = #pending_compaction{token = Token}} = State
) ->
    %% The applier never cast `{catch_up_done, _}` for this catch-up (crash
    %% mid-fold, or a dropped cast). Clear the pending record so compaction
    %% can resume; `remote_events_pending` stays true so the next tick
    %% retries. No truncate ran, so nothing un-folded was dropped.
    ?LOG_WARNING(#{
        description =>
            "bondy_oplog_instance compaction catch-up timed out; "
            "deferring truncate to the next compaction tick",
        instance_id => State#state.instance_id,
        token => Token
    }),
    {noreply, State#state{pending_compaction = undefined}};
handle_info({compaction_catch_up_timeout, _Token}, State) ->
    %% Stale watchdog — the catch-up already committed, aborted, or was
    %% superseded. Ignore.
    {noreply, State};
handle_info({fill_burned_seqs, Start, End, Attempt}, State) ->
    %% Backoff retry scheduled by `fill_burned_seqs/4` after a WAL
    %% rejection of the fill batch itself.
    {noreply, fill_burned_seqs(State, Start, End, Attempt)};
handle_info(
    {seal_done, PackId, ok},
    #state{seal = #seal{ref = Ref, pack_id = PackId}} = State
) ->
    %% The seal worker finished writing pack-<PackId>. Flush its (normal)
    %% DOWN, then commit + mount the sealed view.
    _ = erlang:demonitor(Ref, [flush]),
    case complete_seal_now(State, PackId) of
        {ok, State1} ->
            {noreply, State1};
        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "Async pack-store seal commit failed; stopping for "
                    "restart + reopen recovery",
                instance_id => State#state.instance_id,
                pack_id => PackId,
                reason => Reason
            }),
            {stop, {seal_complete_failed, PackId, Reason}, State#state{
                seal = undefined
            }}
    end;
handle_info(
    {seal_done, PackId, {error, Reason}},
    #state{seal = #seal{ref = Ref, pack_id = PackId}} = State
) ->
    _ = erlang:demonitor(Ref, [flush]),
    retry_or_fail_seal(State, PackId, Reason);
handle_info({seal_done, _PackId, _Result}, State) ->
    %% Stale/duplicate completion (already handled, retried, or superseded).
    {noreply, State};
handle_info(
    {'DOWN', Ref, process, _Pid, Reason},
    #state{seal = #seal{ref = Ref, pack_id = PackId}} = State
) ->
    %% Seal worker crashed before reporting (a normal exit is flushed by the
    %% `seal_done` handler's demonitor, so reaching here is a genuine fault).
    retry_or_fail_seal(State, PackId, {worker_down, Reason});
handle_info(_Info, State) ->
    {noreply, State}.

%% =============================================================================
%% EPHEMERAL FUSED WRITER (fused-writer rollout, Step 3)
%% =============================================================================
%% A fused instance owns BOTH single-writer resources (MST + projection) in
%% this one process, eliminating the applier↔instance install round-trip
%% (H1) that caps single-shard ephemeral throughput. It drains its own WAL,
%% verifies, writes the projection via `bondy_oplog_cell_apply`, and installs
%% into the MST inline (no cast). The drain reuses the applier's STATE-FREE
%% leaves (`collect_frames/2`, `resume_position/2`, `resolve_cell_apply_ctx/1`)
%% so the durable applier hot loop stays byte-identical. Verify/serving stay
%% concurrent (idle waiter offloaded; reads lock-free off the registry).
%%
%% Scope of this step: the LOCAL drain path (the H1 removal). Cross-node
%% remote convergence (peer-merge → projection replay) + AE-target freshness
%% bumping are wired in Step 4; until then a fused instance is single-node.
%% Started ONLY when `#state.fused` (the supervisor omits the applier then).

%% @private
%% Deferred WAL-reader open: the WAL sibling publishes its pid only after
%% this instance's `init/1` returns, so resolving it is retried.
fused_open_reader(#state{fused_drain = undefined} = State) ->
    State;
fused_open_reader(#state{fused_drain = FD} = State0) ->
    case ensure_wal_pid(State0) of
        {ok, WalPid, State1} ->
            %% In the instance process (owns the store's fds), so reading the
            %% MST's last key here is safe; `resume_position/2` now takes the
            %% already-read last `{Key, Value}` rather than the MST handle.
            MstLast =
                case State1#state.mst of
                    undefined -> undefined;
                    MST -> bondy_mst:last(MST)
                end,
            StartPos = bondy_oplog_applier:resume_position(
                MstLast, State1#state.watermark
            ),
            ReaderMod = fused_reader_mod(FD#fused_drain.wal_backend),
            %% `chunk` caps the mem reader's per-`next` events at the apply
            %% batch max so a mem batch matches the disk path's batch size
            %% (disk ignores the opt). Oversized batches inflate the
            %% install-latency that bounds the bounded-writer→await pipeline.
            ReaderOpts = [
                {follow, false}, {chunk, FD#fused_drain.apply_batch_max}
            ],
            case ReaderMod:open(WalPid, StartPos, ReaderOpts) of
                {ok, Iter} ->
                    self() ! fused_drain,
                    State1#state{
                        fused_drain = FD#fused_drain{iter = Iter}
                    };
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        description =>
                            "bondy_oplog_instance fused drain could not open "
                            "the WAL reader; retrying",
                        instance_id => State1#state.instance_id,
                        reason => Reason
                    }),
                    _ = erlang:send_after(?FUSED_RETRY_MS, self(), fused_init),
                    State1
            end;
        {error, _} ->
            %% WAL sibling not up yet (`{error, wal_unavailable}`) — retry
            %% shortly. Keep the original state; the error is NOT a state.
            _ = erlang:send_after(?FUSED_RETRY_MS, self(), fused_init),
            State0
    end.

%% @private
%% Drain wakeup handler — mirrors the applier's `handle_info(drain)`:
%% cancel any parked idle waiter, drain to end-of-log, then re-park a
%% waiter on the WAL durable position (fires the instant a new frame
%% lands; near-zero idle CPU).
run_fused_drain(#state{fused_drain = undefined} = State) ->
    State;
run_fused_drain(#state{fused_drain = #fused_drain{iter = undefined}} = State) ->
    %% Reader not open yet (init race) — `fused_init` will arm the drain.
    State;
run_fused_drain(State0) ->
    State1 = fused_cancel_idle_waiter(State0),
    case fused_drain_loop(State1, ?FUSED_DRAIN_MAX_BATCHES) of
        {ok, State2} -> fused_park_or_retry(State2);
        %% Budget exhausted with work still pending: `fused_drain` was already
        %% re-queued, so do NOT park an idle waiter (that would double-drive
        %% the drain). The instance now services the rest of its mailbox.
        {yield, State2} -> State2;
        {error, State2} -> fused_arm_idle_waiter(State2)
    end.

%% @private
%% Caught up: decide whether the drain stopped at the genuine end of the log
%% (park on the WAL durable position — near-zero idle CPU) or at an in-flight
%% mem-WAL `Seq` gap (a concurrent lock-free append reserved a later Seq and
%% inserted it first). A gap fills in microseconds, so short-retry rather than
%% park. After `?FUSED_MAX_GAP_RETRIES` the gap is treated as unrecoverable and
%% the instance STOPS for a supervised restart + reopen recovery. It does NOT
%% skip the Seq: skipping would advance the reader cursor past a reservation
%% whose write, if the reserving process was merely slow (not dead), lands
%% behind the cursor and is never installed — a silent drop of an acknowledged,
%% local-origin write that anti-entropy cannot recover (this node is the
%% origin). Stopping surfaces the fault loudly and lets the one_for_all subtree
%% re-open cleanly. Returns `State` to continue draining, or
%% `{stop, Reason, State}` to terminate. The disk backend has no gaps (its
%% producer inserts serially), so it always parks.
fused_park_or_retry(#state{fused_drain = FD} = State) ->
    case fused_mem_gap(FD) of
        no_gap ->
            fused_arm_idle_waiter(
                State#state{fused_drain = FD#fused_drain{gap_retries = 0}}
            );
        {gap, _Cursor} when
            FD#fused_drain.gap_retries < ?FUSED_MAX_GAP_RETRIES
        ->
            _ = erlang:send_after(?FUSED_GAP_RETRY_MS, self(), fused_drain),
            State#state{
                fused_drain = FD#fused_drain{
                    gap_retries = FD#fused_drain.gap_retries + 1
                }
            };
        {gap, Cursor} ->
            GapSeq = Cursor + 1,
            ?LOG_ERROR(#{
                description =>
                    "fused mem WAL Seq gap did not fill within the retry "
                    "window; stopping for supervised restart + reopen recovery "
                    "rather than skipping it (skipping would silently drop an "
                    "acknowledged local write). Investigate scheduler "
                    "starvation or a writer that died mid-append.",
                instance_id => State#state.instance_id,
                gap_seq => GapSeq
            }),
            {stop, {mem_wal_gap, GapSeq}, State}
    end.

%% @private
%% A mem drain has an in-flight gap when its reader cursor lags the WAL head
%% (`reserved`) yet the contiguous read returned nothing — i.e. `cursor+1` is
%% reserved but not yet inserted. Returns `{gap, Cursor}` or `no_gap`. Always
%% `no_gap` for the disk backend / an unopened reader.
fused_mem_gap(#fused_drain{wal_backend = mem, iter = Iter}) when
    Iter =/= undefined
->
    {_Seg, Cursor} = bondy_oplog_wal_mem_reader:position(Iter),
    case bondy_oplog_wal_mem_reader:reserved(Iter) > Cursor of
        true -> {gap, Cursor};
        false -> no_gap
    end;
fused_mem_gap(_FD) ->
    no_gap.

%% @private
fused_drain_loop(State, Budget) ->
    case fused_lifecycle_live(State) of
        false ->
            %% Pre-bootstrap: do not touch the projection yet. Re-armed on
            %% the next durable frame (the lifecycle flips in place to live).
            {ok, State};
        true ->
            fused_drain_step(State, Budget)
    end.

%% @private
fused_lifecycle_live(#state{lifecycle = undefined}) ->
    true;
fused_lifecycle_live(#state{lifecycle = H}) ->
    bondy_oplog_bootstrap_lifecycle:is_live(H).

%% @private
fused_drain_step(#state{fused_drain = FD} = State0, Budget) ->
    #fused_drain{iter = Iter, apply_batch_max = Max} = FD,
    case fused_collect_frames(FD#fused_drain.wal_backend, Iter, Max) of
        {frames, Batch, {NextSeg, NextOff}, NewIter, More} ->
            State1 = fused_apply_batch(State0, Batch),
            {LastHlc, Count} = fused_batch_summary(Batch),
            %% Progress made → clear the in-flight-gap retry counter.
            FD1 = (State1#state.fused_drain)#fused_drain{
                iter = NewIter, gap_retries = 0
            },
            FD2 = fused_bump_offset(FD1, NextSeg, NextOff, LastHlc, Count),
            State2 = State1#state{fused_drain = FD2},
            case More of
                more when Budget =< 1 ->
                    %% Budget spent but the WAL still has frames. Re-queue the
                    %% drain and yield so the instance services its mailbox
                    %% (control-plane calls) before the next chunk.
                    self() ! fused_drain,
                    {yield, fused_maybe_commit(State2)};
                more ->
                    fused_drain_loop(fused_maybe_commit(State2), Budget - 1);
                eol ->
                    {ok, fused_commit_now(State2)}
            end;
        {empty, _Iter} ->
            {ok, fused_commit_now(State0)};
        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "bondy_oplog_instance fused drain reader error; "
                    "re-arming and retrying on the next durable frame",
                instance_id => State0#state.instance_id,
                reason => Reason
            }),
            {error, State0}
    end.

%% @private
%% The fused apply step: verify → cell_apply (projection) → install into
%% the MST inline → publish → evict overlay. This is the applier's
%% `apply_batch` with the `install_local_batch` CAST replaced by the
%% instance's OWN inline install (the H1 collapse). Projection write
%% precedes the MST install (the `await_apply` contract: by the time the
%% overlay is empty, the projection has observed the events).
fused_apply_batch(#state{fused_drain = FD, instance_id = Id} = State0, Batch) ->
    VerifyT0 = erlang:monotonic_time(microsecond),
    {Verified, Rejected} = fused_verify_batch(State0, Batch, [], []),
    NVer = length(Verified),
    NRej = length(Rejected),
    %% Reuse the applier's `batch_verify` event (the fused path has no applier,
    %% so this lights up the existing bench/observability stage for fused too).
    telemetry:execute(
        [bondy_oplog, applier, batch_verify],
        #{
            duration_us => erlang:monotonic_time(microsecond) - VerifyT0,
            count => length(Batch)
        },
        #{instance_id => Id}
    ),
    State1 =
        case Rejected of
            [] ->
                State0;
            _ ->
                maybe_signal_drain_waiters(
                    evict_overlay_batch(State0, Rejected)
                )
        end,
    State2 =
        case Verified of
            [] ->
                State1;
            _ ->
                {CellEvents, _Other} = fused_partition_cells(Verified),
                ok = bondy_oplog_cell_apply:apply_cell_batch_mux(
                    FD#fused_drain.cell_apply_source, Id, CellEvents
                ),
                StateA = install_local_batch(State1, Verified),
                PublishT0 = erlang:monotonic_time(microsecond),
                ok = publish(StateA),
                telemetry:execute(
                    [bondy_oplog, applier, batch_publish],
                    #{
                        duration_us =>
                            erlang:monotonic_time(microsecond) - PublishT0,
                        count => NVer
                    },
                    #{instance_id => Id}
                ),
                StateB = evict_overlay_batch(StateA, Verified),
                maybe_signal_drain_waiters(StateB)
        end,
    %% Emit the SAME canonical end-to-end throughput event the applier emits
    %% (`bondy_oplog_applier:apply_batch/2`): "events the writer has fully
    %% processed end-to-end", once per batch. Fused mode has no applier, so
    %% the instance emits it itself — keeping benches and production
    %% monitoring (which key on `[bondy_oplog, applier, applied]`) uniform
    %% across the fused and non-fused write paths.
    telemetry:execute(
        [bondy_oplog, applier, applied],
        #{count => NVer, rejected => NRej},
        #{instance_id => Id}
    ),
    State2.

%% @private
fused_verify_batch(_State, [], VAcc, RAcc) ->
    {lists:reverse(VAcc), lists:reverse(RAcc)};
fused_verify_batch(
    #state{validator_module = Mod, validator_state = VS} = State,
    [Event | Rest],
    VAcc,
    RAcc
) ->
    case Mod:verify_event(Event, VS) of
        ok ->
            fused_verify_batch(State, Rest, [Event | VAcc], RAcc);
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "bondy_oplog_instance fused drain rejected an event at "
                    "verify; dropping it from the batch",
                instance_id => State#state.instance_id,
                reason => Reason
            }),
            fused_verify_batch(State, Rest, VAcc, [Event | RAcc])
    end.

%% @private
fused_partition_cells(Events) ->
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
fused_batch_summary(Batch) ->
    LastEvent = lists:last(Batch),
    LastHlc = bondy_oplog_event:key_hlc(bondy_oplog_event:key(LastEvent)),
    {LastHlc, length(Batch)}.

%% @private
%% Mem WAL: positions are dense `Seq`s, not byte offsets, so the disk-centric
%% `bondy_oplog_wal_state` consumer-offset (which guards `Off >= header bytes`
%% and persists to disk) does not apply. There is nothing to resume from on a
%% fresh BEAM (re-sync from peers), so we only track the uncommitted count for
%% the AE-freshness commit cadence.
fused_bump_offset(
    #fused_drain{wal_backend = mem, uncommitted = U} = FD,
    _Seg,
    _Off,
    _LastHlc,
    Count
) ->
    FD#fused_drain{uncommitted = U + Count};
fused_bump_offset(
    #fused_drain{consumer_offset = CO0, uncommitted = U} = FD,
    Seg,
    Off,
    LastHlc,
    Count
) ->
    CO1 = bondy_oplog_wal_state:with_position(CO0, Seg, Off),
    CO2 = bondy_oplog_wal_state:with_hlc(CO1, LastHlc),
    Old = bondy_oplog_wal_state:commit_count(CO2),
    CO3 = bondy_oplog_wal_state:with_commit_count(CO2, Old + 1),
    FD#fused_drain{consumer_offset = CO3, uncommitted = U + Count}.

%% @private
fused_maybe_commit(
    #state{fused_drain = #fused_drain{uncommitted = U, commit_every = N}} =
        State
) when U >= N ->
    fused_commit_now(State);
fused_maybe_commit(State) ->
    State.

%% @private
%% No `drain_install_queue` barrier (the install already ran inline in
%% THIS process before the commit — there is no cross-process cast to
%% wait on). Advances only the committed-segment marker for WAL retention;
%% the ephemeral WAL needs no on-disk consumer.offset (a fresh BEAM
%% re-reads from `resume_position`).
fused_commit_now(
    #state{fused_drain = #fused_drain{uncommitted = 0}} = State
) ->
    State;
fused_commit_now(
    #state{fused_drain = #fused_drain{wal_backend = mem} = FD} = State0
) ->
    %% Mem WAL has no on-disk consumer offset. GC the WAL up to the reader
    %% cursor (everything read + installed before the cursor advanced) so the
    %% ETS table — and the `ets:next` reader walk — stay bounded; then mirror
    %% the applier's AE-freshness bump and clear the uncommitted count.
    ok = fused_mem_gc(State0, FD),
    ok = fused_bump_ae_targets(FD#fused_drain.ae_targets),
    State0#state{fused_drain = FD#fused_drain{uncommitted = 0}};
fused_commit_now(#state{fused_drain = FD} = State0) ->
    case ensure_wal_pid(State0) of
        {ok, WalPid, State1} ->
            Seg = bondy_oplog_wal_state:committed_segment(
                FD#fused_drain.consumer_offset
            ),
            _ =
                try
                    bondy_oplog_wal:set_committed_segment(WalPid, Seg)
                catch
                    _:_ -> ok
                end,
            %% AE-freshness: mirror the applier's `commit_now` so
            %% secondary-index reads on the target shards see the fused
            %% writer's committed progress (Step 4).
            ok = fused_bump_ae_targets(FD#fused_drain.ae_targets),
            State1#state{fused_drain = FD#fused_drain{uncommitted = 0}};
        {error, _} ->
            %% WAL mid-restart — keep `uncommitted` and retry the
            %% retention bump at the next commit boundary.
            State0
    end.

%% @private
%% Park a monitored helper on the WAL durable position; its `DOWN` is the
%% drain wakeup (busy-spin-free, identical to the applier's idle waiter).
fused_arm_idle_waiter(
    #state{fused_drain = #fused_drain{idle_waiter = Ref}} = State
) when is_reference(Ref) ->
    State;
fused_arm_idle_waiter(#state{fused_drain = FD} = State0) ->
    case ensure_wal_pid(State0) of
        {ok, WalPid, State1} ->
            {Seg, Off} = fused_reader_position(
                FD#fused_drain.wal_backend, FD#fused_drain.iter
            ),
            %% `await_durable` is protocol-shared between the disk and mem WAL
            %% gen_servers — the mem WAL interprets `{?MEM_SEG, Off+1}` as
            %% "reserved >= Off+1" — so this wrapper call routes to either.
            {_Pid, MRef} = spawn_monitor(fun() ->
                _ = bondy_oplog_wal:await_durable(
                    WalPid, {Seg, Off + 1}, ?FUSED_AWAIT_DURABLE_TIMEOUT_MS
                )
            end),
            State1#state{fused_drain = FD#fused_drain{idle_waiter = MRef}};
        {error, _} ->
            %% WAL mid-restart — cannot park a waiter now. The one_for_all
            %% subtree restart re-runs init and re-kicks `fused_init`.
            State0
    end.

%% @private
fused_cancel_idle_waiter(
    #state{fused_drain = #fused_drain{idle_waiter = undefined}} = State
) ->
    State;
fused_cancel_idle_waiter(
    #state{fused_drain = #fused_drain{idle_waiter = MRef} = FD} = State
) ->
    _ = erlang:demonitor(MRef, [flush]),
    State#state{fused_drain = FD#fused_drain{idle_waiter = undefined}};
fused_cancel_idle_waiter(State) ->
    State.

%% @private
%% WAL READER dispatch (task #50, ephemeral ETS WAL). Only the reader differs
%% between the disk and in-memory WAL backends; the producer + `await_durable`
%% + `set_committed_segment` protocol is shared. These three helpers are the
%% whole dispatch surface — `bondy_oplog_wal`, `bondy_oplog_wal_reader` and
%% `bondy_oplog_applier` are untouched.
fused_reader_mod(mem) -> bondy_oplog_wal_mem_reader;
fused_reader_mod(disk) -> bondy_oplog_wal_reader.

%% @private
fused_reader_position(mem, Iter) ->
    bondy_oplog_wal_mem_reader:position(Iter);
fused_reader_position(disk, Iter) ->
    bondy_oplog_wal_reader:position(Iter).

%% @private
%% Disk reuses the applier's state-free `collect_frames/2` verbatim. Mem uses a
%% structurally-identical aggregator over `bondy_oplog_wal_mem_reader:next/1`
%% (same `{frames, Batch, Pos, NewIter, more|eol} | {empty,_} | {error,_}`
%% shape), so `fused_drain_step/1` is backend-agnostic.
fused_collect_frames(disk, Iter, Max) ->
    bondy_oplog_applier:collect_frames(Iter, Max);
fused_collect_frames(mem, Iter, Max) ->
    fused_mem_collect_frames(Iter, Max, [], 0, undefined).

%% @private
%% The badarg catch covers the shutdown race: the mem-WAL ETS queue is
%% owned by the WAL process, which the supervisor may stop before this
%% instance while a drain message is still queued — routine now that
%% async writers (`bondy_db:apply_async/4`) can leave undrained work at
%% teardown. A vanished queue reads as end-of-log; the instance is about
%% to terminate anyway.
fused_mem_collect_frames(Iter0, Max, AccRev, N, LastPos) ->
    try bondy_oplog_wal_mem_reader:next(Iter0) of
        {ok, Batch, _Hlcs, NextPos, NewIter} ->
            N1 = N + length(Batch),
            AccRev1 = [Batch | AccRev],
            case N1 >= Max of
                true ->
                    {frames, lists:append(lists:reverse(AccRev1)), NextPos,
                        NewIter, more};
                false ->
                    fused_mem_collect_frames(NewIter, Max, AccRev1, N1, NextPos)
            end;
        end_of_log when AccRev == [] ->
            {empty, Iter0};
        end_of_log ->
            {frames, lists:append(lists:reverse(AccRev)), LastPos, Iter0, eol};
        {error, Reason} ->
            {error, Reason}
    catch
        error:badarg when AccRev == [] ->
            {empty, Iter0};
        error:badarg ->
            {frames, lists:append(lists:reverse(AccRev)), LastPos, Iter0, eol}
    end.

%% @private
%% Best-effort GC of the mem WAL up to the drain's reader cursor (the last Seq
%% read + installed). A cast — never blocks the commit. No-op for the disk
%% backend or before the reader is open.
fused_mem_gc(_State, #fused_drain{iter = undefined}) ->
    ok;
fused_mem_gc(#state{instance_id = Id}, #fused_drain{iter = Iter}) ->
    {_Seg, Seq} = bondy_oplog_wal_mem_reader:position(Iter),
    case bondy_oplog_registry:wal_pid(Id) of
        undefined -> ok;
        WalPid -> bondy_oplog_wal_mem:set_committed_seq(WalPid, Seq)
    end.

%% @private
%% The REMOTE-path analog of `bondy_oplog_applier:do_replay_cell_events/1`,
%% run INLINE in the fused instance after a peer merge
%% (`integrate_peer_root`). A fused instance has no applier, so it folds the
%% peer-merged events into the projection itself: diff the live MST from the
%% replay cursor and apply the resulting cell pairs. The cursor advances so
%% the next replay stays incremental; compaction re-anchors it on the
%% post-truncate root (`finalize_catalogue_compaction`). Uses the in-process
%% `State#state.mst` directly (the merged tree), not the registry, so it is
%% correct before `maybe_publish/2` runs. Local events caught in the diff
%% were already folded by the WAL drain; re-folding them is idempotent (the
%% CRDT contract), exactly as in the applier.
fused_replay_cell_events(#state{fused_drain = undefined} = State) ->
    State;
fused_replay_cell_events(
    #state{fused_drain = #fused_drain{cell_apply_ctx = undefined}} = State
) ->
    State;
fused_replay_cell_events(
    #state{mst = MST, instance_id = Id, origin = Origin, fused_drain = FD} =
        State
) ->
    LastRoot = FD#fused_drain.last_replayed_root,
    CurrentRoot = bondy_mst:root(MST),
    case CurrentRoot of
        LastRoot ->
            State;
        _ ->
            Pairs = bondy_oplog_applier:diff_pairs(MST, LastRoot, Id),
            {_Count, Held} = bondy_oplog_cell_apply:apply_cell_pairs_mux(
                FD#fused_drain.cell_apply_source,
                Id,
                Pairs,
                Origin,
                #{hold => true}
            ),
            %% Reads of a peer-authored value just became answerable — bump
            %% the AE-freshness shards so a secondary-index read does not
            %% refuse as stale.
            ok = fused_bump_ae_targets(FD#fused_drain.ae_targets),
            %% Prefix-closure hold: keep the cursor when events were held
            %% so the next replay re-presents them (idempotent re-fold);
            %% see `bondy_oplog_cell_apply:apply_cell_pairs_mux/5`.
            case Held of
                0 ->
                    State#state{
                        fused_drain =
                            FD#fused_drain{last_replayed_root = CurrentRoot}
                    };
                _ ->
                    State
            end
    end.

%% @private
%% The `integrate_peer_root` body, entered only after the handler's
%% atomic missing-set pre-check. Merges the peer root, runs the
%% watermark door, replays (fused) or schedules the applier replay
%% (non-fused), consumes the session's peer-root pin, and returns the
%% gen_server reply tuple.
do_integrate_peer_root(PeerRoot, #state{mst = MST0} = State00) ->
    {HasProjection, State} = resolve_has_projection(State00),
    MST1 = bondy_mst:merge(MST0, MST0, PeerRoot),
    %% Watermark filter — THE WATERMARK DOOR: if our compaction has
    %% advanced past some of the events in PeerRoot's tree, re-truncate
    %% to drop them. The door's premise — "at or below the watermark ⇒
    %% already folded here" — is FALSE for a peer event this replica
    %% never saw: the peer-confirmed frontier and in-flight events race
    %% by design under concurrent writes, so a just-minted peer event
    %% can arrive after the watermark passed its key. Discarding it
    %% unapplied is silent, permanent, per-replica data loss — the
    %% completed round's `confirm_root` (a page-holding claim) lets the
    %% origin compact the event away, and the applied VV max-merges
    %% past the hole on the next same-origin apply (the VV is a max,
    %% not a prefix witness), so no oracle ever flags it. Proven live
    %% at defaults by the compaction cluster suite's forensics.
    %% `watermark_door/3` therefore NEVER truncates a never-applied
    %% event: fused instances fold it into the projection inline first;
    %% applier-backed instances hold it below the watermark for the
    %% applier's replay (this function sets `remote_events_pending`
    %% below, and every later truncation site is behind the async
    %% catch-up gate).
    MST2 = watermark_door(HasProjection, State, MST1),
    %% HLC update: events received via merge may carry HLCs higher than
    %% our local clock. Advance the HLC to dominate the merged tree's
    %% max key so subsequent local appends sort after every received
    %% event — and stay above any future watermark.
    case bondy_mst:last(MST2) of
        undefined ->
            ok;
        {LastKey, _V} ->
            _ = bondy_oplog_hlc:update(
                State#state.hlc, bondy_oplog_event:key_hlc(LastKey)
            )
    end,
    %% Re-seed `max_local_installed_seq` from the merged tree. A sync
    %% can echo our own local events back to us (peer pulled them
    %% from us earlier, then we pull our originated pages back in via
    %% `pull_until_complete` → `integrate_peer_root`). When the
    %% applier later dispatches those same WAL entries to
    %% `install_local_batch`, the `is_fast_install` predicate uses
    %% this watermark to decide between the fast install (blindly
    %% bumps `live_size`) and the slow safe install (checks the MST
    %% first). Without this refresh, the fast path double-bumps
    %% `live_size` for the echoed event — visible to `size/1` as an
    %% off-by-N overcount.
    MaxLocalSeq =
        case max_local_seq(MST2, State#state.origin) of
            undefined -> State#state.max_local_installed_seq;
            S -> erlang:max(S, State#state.max_local_installed_seq)
        end,
    State1 = State#state{
        mst = MST2,
        live_size = compute_live_size(MST2),
        max_local_installed_seq = MaxLocalSeq,
        %% The session's pin on this root is consumed by the successful
        %% merge — the pages are now reachable from OUR root, so the GC
        %% protects them without it.
        pinned_peer_roots = maps:remove(
            PeerRoot, State#state.pinned_peer_roots
        )
    },
    %% Sync produced new events in the local MST; the cell_apply projection
    %% must re-fold so peer-authored events become visible to
    %% `bondy_db:read/3`.
    {reply, ok, deliver_remote(State1)}.

%% @private
%% The remote DELIVERY POINT, shared by `do_integrate_peer_root/2`
%% (page sync) and `append_remote_install/3` (live single events) —
%% the only two paths by which remote-origin events enter an
%% instance's MST post-live (catalogue bootstrap installs cells
%% pre-live, before any context is served; the compaction catch-up
%% re-folds events already counted here). Called strictly AFTER the
%% MST root advance (program order within the calling handler).
%%
%% Always bumps `remote_gen` so an async catch-up already in flight
%% (or one that captured the pre-delivery state) detects the new
%% events at its truncate guard and defers rather than truncating
%% them un-folded. Then:
%%
%% - Fused (no applier): fold the new events into the projection
%%   INLINE, in this process. The projection is current on return, so
%%   there is nothing for a later compaction to catch up —
%%   `remote_events_pending` stays false. The async catch-up
%%   (`begin_async_catch_up/3`) exists only to break the
%%   cross-process instance↔applier deadlock, which a single process
%%   does not have. Reads see the values as soon as the calling
%%   handler returns (the advanced MST is auto-published by
%%   `maybe_publish/2`).
%% - Durable / non-fused: ask the applier to re-fold the projection
%%   (a best-effort cast; the next sync tick re-arms it if the
%%   applier was busy). No-op when the instance was started without a
%%   `cell_apply_target` (the applier's `cell_apply_ctx` is
%%   `undefined` and the cast falls through). Mark the remote events
%%   pending so the next catalogue compaction folds them before
%%   truncating.
%%
%%   I1 (prepare-after-deliver): the shared remote-delivery
%%   generation bump makes this the fence's delivery point — the
%%   applier's prepare fence (`{cell_context, _, _}`) compares this
%%   generation against the one it last replayed to, so a context
%%   read ordered after the calling handler's completion either finds
%%   the generation advanced (and replays before serving) or the cast
%%   below already folded the events. A context read that races AHEAD
%%   of this bump is, by definition, prepared before these events
%%   were delivered — I1 holds vacuously for it. Both MST entry paths
%%   route here, so this single bump site is exhaustive.
deliver_remote(#state{} = State0) ->
    State = State0#state{remote_gen = State0#state.remote_gen + 1},
    case State#state.fused of
        true ->
            fused_replay_cell_events(State);
        false ->
            _ =
                State#state.remote_gen_ref =/= undefined andalso
                    atomics:add(State#state.remote_gen_ref, 1, 1),
            case bondy_oplog_registry:applier_pid(State#state.instance_id) of
                undefined ->
                    ok;
                ApplierPid when is_pid(ApplierPid) ->
                    bondy_oplog_applier:replay_cell_events(ApplierPid)
            end,
            State#state{remote_events_pending = true}
    end.

%% @private
%% THE WATERMARK DOOR (see `do_integrate_peer_root/2` for the full
%% rationale). Truncates the merged tree at or below the watermark
%% WITHOUT ever dropping a never-applied event:
%%
%% - No watermark, or no never-applied events at or below it → plain
%%   truncate (the pre-existing behaviour; already-applied events at or
%%   below the watermark are compacted history re-introduced by the
%%   merge, and dropping them is the door's whole point).
%% - Fused with a projection → fold the never-applied events into the
%%   projection inline (`apply_cell_pairs_mux`, exactly the primitive
%%   `fused_replay_cell_events/1` uses — same process, same sources),
%%   re-check against the now-advanced VV, then truncate. Fold-before-
%%   drop: the event's op survives in the projection, the VV witnesses
%%   it honestly, and the MST stays bounded.
%% - Applier-backed (the applier is the projection's single writer, so
%%   this process must not fold cells) or fold failed → HOLD: truncate
%%   only the prefix strictly below the smallest never-applied key. The
%%   held events stay in the tree for the applier's replay (the
%%   integrate handler sets `remote_events_pending`, and every later
%%   truncation site — compaction commit and watermark catch-up — is
%%   behind the async catch-up gate, which folds before truncating).
%%   The next door pass re-evaluates the held prefix against the VV and
%%   truncates once applied.
%%
%% Instances WITHOUT a projection have no applied-VV witness (their
%% checkpoint fold at compaction defines "applied"), so the door keeps
%% its legacy full truncate there — the production `bondy_db` tables
%% are all projection-backed.
watermark_door(_HasProjection, #state{watermark = undefined}, MST) ->
    MST;
watermark_door(false, #state{watermark = W, backend = Backend} = State, MST) ->
    truncate_below_or_equal(MST, W, Backend, pinned_roots(State));
watermark_door(
    true,
    #state{instance_id = Id, watermark = W, backend = Backend} = State,
    MST
) ->
    Pinned = pinned_roots(State),
    case never_applied_at_or_below(Id, MST, W) of
        [] ->
            truncate_below_or_equal(MST, W, Backend, Pinned);
        Doored ->
            ok = door_fold(State, Doored),
            case never_applied_at_or_below(Id, MST, W) of
                [] ->
                    ok = door_report(Id, folded, Doored),
                    truncate_below_or_equal(MST, W, Backend, Pinned);
                Held ->
                    ok = door_report(Id, held, Held),
                    MinHeld = lists:min([K || {K, _} <- Held]),
                    case bondy_mst:last_n(MST, MinHeld, 1) of
                        [{K, _V}] ->
                            truncate_below_or_equal(MST, K, Backend, Pinned);
                        [] ->
                            MST
                    end
            end
    end.

%% @private
%% `{Key, Value}` entries at or below `W` whose `{Origin, Seq}` exceeds
%% the local applied VV — events the door must not drop. The region at
%% or below the watermark is normally EMPTY (the watermark is this
%% instance's own truncation point), so the scan visits only what the
%% merge just re-introduced plus any held prefix: O(candidates), not
%% O(tree).
never_applied_at_or_below(Id, MST, W) ->
    VV = applied_vv(Id),
    [
        {K, V}
     || {K, V} <- entries_at_or_below(MST, W),
        bondy_oplog_event:key_seq(K) >
            maps:get(bondy_oplog_event:key_origin(K), VV, 0)
    ].

%% @private
%% THE UNSERVABLE-OWN-ROOT SELF-HEAL (the broken-node half of the
%% dangling-root recovery; the peer half is the sync scheduler's
%% `root_unservable_behind` escalation). A fused instance whose own
%% root has lost pages (found live on Fly s16: 2 pages absent from the
%% ephemeral ETS store) can never serve a complete page round again, so
%% NOTHING on the shard ever earns a peer-confirmed truncation license:
%% the MST grows forever and the shard is an AE blackout even for new
%% writes. The events are already lost as replication currency (the
%% tree cannot serve them) — but the PROJECTION is intact, the applied
%% VV witnesses everything, and catalogue bootstrap serves both. So the
%% honest recovery is to REBUILD: drop the unservable tree, advance the
%% watermark past the dropped range, keep projection + frontier, and
%% let AE resume on the fresh (servable) tree.
%%
%% Gates, in order:
%% - fused + projection only (the s16 class; a durable instance heals
%%   its store via reboot/WAL replay);
%% - the unservable streak must exceed ?SELF_HEAL_UNSERVABLE_AFTER_MS
%%   (transient truncate/GC-race unservability clears within a round);
%% - re-verified against the CURRENT root right here (the streak
%%   timestamp alone could be stale);
%% - every recency-live peer's recorded frontier (peer_state, captured
%%   by our own successful rounds) must DOMINATE our applied VV — i.e.
%%   our surplus has already drained to the peers (normally via their
%%   unservable-behind catalogue bootstraps), so dropping our events
%%   strands nobody. Vacuous with no live peers: solo, there is no one
%%   to serve; and a later-returning peer recovers via the frontier-gap
%%   → catalogue-bootstrap chain against our intact projection.
maybe_self_heal_unservable(
    #state{
        fused = true,
        unservable_since = Since,
        mst = MST,
        instance_id = Id,
        backend = Backend
    } = State,
    true
) when Since =/= undefined ->
    Now = erlang:monotonic_time(millisecond),
    Root = bondy_mst:root(MST),
    StillUnservable =
        Root =/= undefined andalso
            [] =/= bondy_mst:missing_set(MST, Root),
    Threshold = application:get_env(
        bondy_oplog,
        unservable_self_heal_after_ms,
        ?SELF_HEAL_UNSERVABLE_AFTER_MS
    ),
    case
        Now - Since > Threshold andalso
            StillUnservable andalso live_peers_dominate(Id)
    of
        false ->
            case StillUnservable of
                true -> State;
                false -> State#state{unservable_since = undefined}
            end;
        true ->
            {LastKey, _} = bondy_mst:last(MST),
            Dropped = State#state.live_size,
            MST1 = truncate_below_or_equal(
                MST, LastKey, Backend, pinned_roots(State)
            ),
            _ = bondy_oplog_hlc:update(
                State#state.hlc, bondy_oplog_event:key_hlc(LastKey)
            ),
            telemetry:execute(
                [bondy_oplog, instance, mst_rebuilt],
                #{count => 1, dropped => Dropped},
                #{instance_id => Id, reason => unservable_root}
            ),
            ?LOG_NOTICE(#{
                description =>
                    "Rebuilt an unservable MST (own root with lost "
                    "pages): dropped the tree, advanced the watermark "
                    "past it and kept the projection + applied "
                    "frontier. Every recency-live peer's frontier "
                    "dominates ours, so no peer is stranded; AE "
                    "resumes on the fresh tree.",
                instance_id => Id,
                dropped_events => Dropped,
                unservable_for_ms => Now - Since
            }),
            State#state{
                mst = MST1,
                watermark = advance_watermark(State#state.watermark, LastKey),
                live_size = compute_live_size(MST1),
                remote_gen = State#state.remote_gen + 1,
                aae_root_check = undefined,
                unservable_since = undefined,
                fused_drain = fused_reanchor_cursor(
                    State#state.fused_drain, bondy_mst:root(MST1)
                )
            }
    end;
maybe_self_heal_unservable(State, _HasProjection) ->
    State.

%% @private
%% True when every recency-live peer we have completed a round against
%% has a recorded applied frontier that covers ours per-origin. A peer
%% with NO recorded frontier (never supplied one) blocks the heal —
%% unknown is not coverage.
live_peers_dominate(Id) ->
    OurVV = applied_vv(Id),
    lists:all(
        fun
            (#{frontier := F}) when is_map(F) -> dominates(F, OurVV);
            (_) -> false
        end,
        bondy_oplog_peer_state:get_instance_peer_states(Id)
    ).

%% @private
dominates(PeerVV, OurVV) ->
    maps:fold(
        fun
            (_Origin, _Seq, false) -> false;
            (Origin, Seq, true) -> maps:get(Origin, PeerVV, 0) >= Seq
        end,
        true,
        OurVV
    ).

%% @private
%% The applied-frontier version vector — the witness both watermark
%% doors (`watermark_door/3` and `append_remote_below_watermark/3`)
%% judge "never applied here" against. `#{}` when the registry has no
%% frontier yet (nothing applied).
applied_vv(Id) ->
    case bondy_oplog_registry:frontier(Id) of
        M when is_map(M) -> M;
        _ -> #{}
    end.

%% @private
%% The tree's `{Key, Value}` entries with `Key =< W`. Fast path: walk
%% down from the key's successor with `bondy_mst:last_n/3` ("last N
%% strictly below the bound"), capped; an exactly-capped result means
%% the region may be larger than the cap, so fall back to the total
%% full-tree filter.
entries_at_or_below(MST, W) ->
    case bondy_oplog_event:is_key(W) of
        true ->
            Bound = bondy_oplog_event:key(
                bondy_oplog_event:key_hlc(W),
                bondy_oplog_event:key_origin(W),
                bondy_oplog_event:key_seq(W) + 1
            ),
            case bondy_mst:last_n(MST, Bound, ?DOOR_SCAN_CAP) of
                Entries when length(Entries) < ?DOOR_SCAN_CAP ->
                    Entries;
                _ ->
                    full_scan_at_or_below(MST, W)
            end;
        false ->
            full_scan_at_or_below(MST, W)
    end.

%% @private
full_scan_at_or_below(MST, W) ->
    bondy_mst:fold(
        MST,
        fun
            ({K, V}, Acc) when K =< W -> [{K, V} | Acc];
            (_, Acc) -> Acc
        end,
        []
    ).

%% @private
%% Fold never-applied doored pairs into the projection — fused
%% instances only (the fused instance owns its cell-apply sources; an
%% applier-backed instance must leave the fold to the applier, its
%% projection's single writer). Best-effort: the caller re-checks the
%% VV afterwards, so a partial or failed fold degrades to the HOLD
%% path, never to a drop.
door_fold(
    #state{
        instance_id = Id,
        origin = Origin,
        fused = true,
        fused_drain = #fused_drain{cell_apply_ctx = Ctx, cell_apply_source = S}
    },
    Pairs
) when Ctx =/= undefined ->
    %% The holding mux is safe here: a pair the hold excludes stays
    %% never-applied below the watermark, so the caller's VV re-check
    %% keeps it doored — exactly this function's stated degrade path —
    %% and the fused replay re-presents it once the gap fills.
    _ =
        try
            bondy_oplog_cell_apply:apply_cell_pairs_mux(
                S, Id, Pairs, Origin, #{hold => true}
            )
        catch
            _:_ -> ok
        end,
    ok;
door_fold(#state{}, _Pairs) ->
    ok.

%% @private
door_report(Id, Action, Pairs) ->
    Sample = [
        #{
            origin => bondy_oplog_event:key_origin(K),
            seq => bondy_oplog_event:key_seq(K),
            hlc => bondy_oplog_event:key_hlc(K)
        }
     || {K, _} <- lists:sublist(Pairs, 10)
    ],
    telemetry:execute(
        [bondy_oplog, instance, integrate_doored],
        #{count => length(Pairs)},
        #{instance_id => Id, action => Action, doored => Sample}
    ),
    ?LOG_INFO(#{
        description =>
            "Watermark door: integrate merged never-applied peer "
            "events at or below the local watermark; folded them into "
            "the projection (fused) or held them for the applier's "
            "replay instead of discarding them",
        instance_id => Id,
        action => Action,
        count => length(Pairs),
        doored => Sample
    }),
    ok.

%% @private
%% Bumps the AE-freshness atomic for every shard in the fused drain's
%% `ae_targets` with a shared `monotonic_time(millisecond)` so a batch of
%% shards observes the same "now". Mirrors
%% `bondy_oplog_applier:bump_ae_targets/1`: the applier bumps on its
%% `commit_now`; the fused instance has no applier, so it bumps on its own
%% commit and after a remote replay. `[]` (the common case) is a no-op.
fused_bump_ae_targets([]) ->
    ok;
fused_bump_ae_targets(Targets) ->
    Now = erlang:monotonic_time(millisecond),
    _ = bondy_oplog_core_registry:bump_ae_targets(Targets, Now),
    ok.

terminate(_Reason, #state{
    instance_id = InstanceId,
    mst = MST,
    backend = Backend,
    watermark = Watermark,
    compaction_checkpoint = CkptMod,
    compaction_checkpoint_state = CkptState,
    overlay = Overlay,
    seal = Seal
}) ->
    %% Kill any in-flight seal worker BEFORE closing the MST. The frozen
    %% incoming-sealing file stays on disk and the reopen recovery re-seals
    %% it; killing the worker first guarantees it is not still writing
    %% pack-<id> when the next instance's recovery opens the same dir.
    ok = stop_seal_worker(Seal),
    %% Persist the applied-frontier convergence oracle into the checkpoint on a
    %% clean stop so the next start restores the compacted-prefix maxima (the
    %% suffix replays from the WAL tail). Durable backends only — an ephemeral
    %% instance has no checkpoint and rebuilds the frontier from the apply path.
    %% Best-effort and BEFORE `close/1`: a failure just falls back to a
    %% WAL-replay-only frontier next boot.
    _ = maybe_persist_frontier(
        InstanceId, Backend, Watermark, CkptMod, CkptState
    ),
    %% Leave the registry row in place so that on a one_for_all subtree
    %% restart the dyn_sup mapping (`sup_pid`) survives. The row's
    %% `instance_pid` field will be stale until the new instance
    %% gen_server's init runs and republishes; lock-free read paths
    %% use `is_process_alive/1` to detect that case.
    _ =
        try
            CkptMod:close(CkptState)
        catch
            _:_ -> ok
        end,
    %% CLOSE (not destroy) a durable MST: `terminate` runs on EVERY stop —
    %% node shutdown, supervisor `one_for_all` subtree restart — none of which
    %% mean "delete this data". For a pack-store backend `destroy/1` does
    %% `file:del_dir_r/1`, which would wipe the durable tree on every restart
    %% and force a full WAL replay (resume falls back to `beginning` because
    %% `bondy_mst:last/1` returns `undefined`), and the WAL would never
    %% truncate. `close/1` flushes the root + fds and PRESERVES the tree so the
    %% next `init/1` restores it. Ephemeral backends (`ets`/`map`) keep
    %% `destroy/1`: it frees the table explicitly and there is no on-disk state
    %% to lose. Deleting a durable table's data belongs on an explicit drop
    %% path, not here. Unknown backends fail safe to `close` (never delete).
    _ =
        try
            case Backend of
                ets -> bondy_mst:destroy(MST);
                map -> bondy_mst:destroy(MST);
                _ -> bondy_mst:close(MST)
            end
        catch
            _:_ -> ok
        end,
    %% Drop the overlay — it dies with the instance, no heir, no
    %% survival across subtree restart. The applier reads the tid
    %% from the registry, and the registry row's `overlay_tab`
    %% becomes stale here until the next `init/1` republishes a
    %% fresh one. Applier-side reads tolerate `undefined`.
    _ =
        try
            ets:delete(Overlay)
        catch
            _:_ -> ok
        end,
    ok.

%% @private
%% Telemetry rather than `alarm_handler:set_alarm/1`: a peer with a bad clock
%% trips this on EVERY event it sends, and a per-event `gen_event:notify/2`
%% is the flood this exists to report. A counter is wait-free; an alerting
%% rule or a periodic sweep owns the alarm lifecycle.
report_clock_skew(Key, PeerOrigin) ->
    case bondy_oplog_clock_skew:check(bondy_oplog_event:key_hlc(Key)) of
        ok ->
            ok;
        {ahead, Millis} ->
            telemetry:execute(
                [bondy_oplog, instance, peer_clock_ahead],
                #{count => 1, milliseconds => Millis},
                #{origin => PeerOrigin}
            )
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Restore the applied-frontier convergence oracle from the compaction
%% checkpoint payload into the registry holder (a max-merge). The payload carries
%% the version vector of the COMPACTED prefix — the events truncated from the
%% WAL, which the applier's WAL-tail replay can no longer observe. A plain
%% `projection_managed` marker or a bare-CRDT checkpoint carries no frontier
%% (`_Other` clause): the holder stays empty and WAL replay alone reconstructs
%% it. An origin whose events were ALL compacted away would then be momentarily
%% under-counted — conservative (the oracle reads "behind", never a false IN
%% SYNC) and self-healing at the next checkpoint write, which persists the full
%% frontier.
%% Goes through `merge_frontier/2` deliberately, like every other frontier
%% writer: that is where the retired-origin ceiling lives, and it is what
%% makes a frontier reap survive a restart. A reap is not stored as a
%% deletion — the checkpoint still carries the reaped origin's maximum — so
%% writing `#entry.frontier` directly here would resurrect every reaped
%% entry on every boot.
restore_frontier(_InstanceId, undefined) ->
    ok;
restore_frontier(
    InstanceId, {_W, {projection_managed, frontier, FrontierVV}}
) when
    is_map(FrontierVV)
->
    bondy_oplog_registry:merge_frontier(InstanceId, FrontierVV);
restore_frontier(_InstanceId, _Other) ->
    ok.

%% @private
%% Persist the live applied-frontier version vector into the compaction
%% checkpoint as `{projection_managed, frontier, FrontierVV}` so the next start
%% restores the compacted-prefix maxima (see `restore_frontier/2`). Durable
%% backends only — an ephemeral instance has no checkpoint. The registry read is
%% wrapped in `try`: at node shutdown the core registry may already be gone,
%% and a miss just falls back to a WAL-replay-only frontier next boot.
maybe_persist_frontier(InstanceId, Backend, Watermark, CkptMod, CkptState) ->
    _ =
        is_durable_backend(Backend) andalso
            try
                FrontierVV = bondy_oplog_registry:frontier(InstanceId),
                CkptMod:put_checkpoint(
                    CkptState,
                    Watermark,
                    {projection_managed, frontier, FrontierVV}
                )
            catch
                _:_ -> ok
            end,
    ok.

%% @private
is_durable_backend(ets) -> false;
is_durable_backend(map) -> false;
is_durable_backend(_) -> true.

%% @private
%% Builds a signed event for each `{Op, Meta}` item, hands the resulting
%% list to the per-instance WAL as a single atomic batch frame, then
%% inserts the events into the per-instance overlay so the caller's
%% next read sees them. The MST is **not** mutated here — the per-
%% instance applier drains the WAL, re-verifies each event's
%% signature, and casts `install_local_batch` back to this gen_server
%% which performs the actual MST install and overlay eviction. The
%% overlay row closes the read-your-writes gap until the applier
%% catches up; the row is evicted via HLC-conditional
%% `ets:select_delete/2` once the install lands.
do_append_local(#state{} = State0, WalPid, Items) ->
    {Events, Keys, State1} = build_events(State0, Items),
    %% Stage overlay rows BEFORE the WAL append. The applier reads
    %% from the WAL the instant `append_batch/2` durably commits;
    %% if we staged after, the applier could send
    %% `install_local_batch` before the overlay row exists — its
    %% `evict_overlay_batch/2` would then run as a no-op, and a
    %% later overlay insert would leave an orphan row whose count
    %% inflates `size/1`. Staging first guarantees the row is
    %% visible the moment the WAL entry is.
    State2 = stage_to_overlay(State1, Events),
    case wal_append_batch(WalPid, Events) of
        ok ->
            telemetry:execute(
                [bondy_oplog, instance, append],
                #{count => length(Events)},
                #{instance_id => State2#state.instance_id}
            ),
            {ok, Keys, State2};
        {error, _} = E ->
            %% WAL rejected the batch — roll back the overlay rows so
            %% they cannot be served as a phantom write, and return
            %% the seq range so the origin's sequence stays gap-free.
            ok = unstage_overlay(State2, Events),
            ok = release_seq_range(
                State2#state.seq, State2#state.instance_id, Keys
            ),
            E
    end.

%% @private
%% Undo the effect of `stage_to_overlay/2` for a batch whose WAL
%% append did not succeed.
unstage_overlay(#state{overlay = undefined}, _Events) ->
    ok;
unstage_overlay(#state{overlay = Tab, overlay_counters = Ctrs}, Events) ->
    unstage_overlay_rows(Tab, Ctrs, Events).

%% @private
%% Stages overlay rows on a registry-published tid, reporting `stale` when
%% that tid no longer names a live table.
%%
%% `bondy_oplog_registry:overlay_tab/1` can hand back a dead tid, not just
%% `undefined`: the overlay table dies with its instance gen_server (it has no
%% heir) and the registry row keeps the old value until the next instance
%% `init/1` republishes a fresh one. A caller-side append landing in that
%% window would otherwise crash with `badarg` instead of routing through the
%% gen_server the way the `undefined` case already does.
%%
%% Staleness has to be discovered by attempting the write — probing with
%% `ets:info/2` first would only move the race, since the owner can die
%% between the probe and the insert. This is safe to retry because staging is
%% the first side effect of an append: on a dead table nothing was written,
%% no counters have moved, and no WAL frame exists yet.
%%
%% Only `badarg` is caught. A `badmatch` on the insert result would mean a
%% live table refused the write, which is an invariant violation and must stay
%% loud.
stage_overlay_rows(Tab, Rows) ->
    try
        true = ets:insert(Tab, Rows),
        ok
    catch
        error:badarg ->
            stale
    end.

%% @private
%% Deletes every staged overlay row by key and decrements the shared
%% counters by the same amount they were bumped — keeping the counters
%% and the table in lockstep. Shared by the gen_server rollback above
%% and the caller-side fast paths.
unstage_overlay_rows(Tab, Ctrs, Events) ->
    lists:foreach(
        fun(E) -> ets:delete(Tab, bondy_oplog_event:key(E)) end,
        Events
    ),
    overlay_counters_sub(Ctrs, length(Events)),
    ok.

%% @private
%% Inserts every event in the batch into the per-instance overlay as
%% one atomic `ets:insert/2` call and bumps the in-state size +
%% byte-estimate counters used by `overlay_admit/2`. Origin is `local`
%% for events that went through the WAL; a future eager-push receiver
%% will insert with `eager_pushed` so the applier's eviction protocol
%% can distinguish the two.
stage_to_overlay(
    #state{overlay = Overlay, overlay_counters = Ctrs} = State, Events
) ->
    Rows = [overlay_row(E, local) || E <- Events],
    true = ets:insert(Overlay, Rows),
    overlay_counters_add(Ctrs, Events),
    State.

%% @private
%% Adds the count + byte delta of `Events` into the shared
%% `overlay_counters` atomics. Called from this gen_server and from
%% the `append_fast/2,3` caller-side path.
overlay_counters_add(Ctrs, Events) ->
    {DeltaCount, DeltaBytes} = overlay_delta(Events),
    ok = atomics:add(Ctrs, 1, DeltaCount),
    ok = atomics:add(Ctrs, 2, DeltaBytes),
    ok.

%% @private
overlay_counters_get(Ctrs) ->
    {atomics:get(Ctrs, 1), atomics:get(Ctrs, 2)}.

%% @private
%% Counts events and sums their approximate on-heap size via
%% `erlang:external_size/1` — faster than `term_to_binary` because it
%% does not allocate. The result is used purely for backpressure
%% accounting; exactness is not required.
overlay_delta(Events) ->
    lists:foldl(
        fun(E, {Count, Bytes}) ->
            {Count + 1, Bytes + erlang:external_size(E)}
        end,
        {0, 0},
        Events
    ).

%% @private
overlay_row(Event, Origin) ->
    Key = bondy_oplog_event:key(Event),
    {
        Key,
        value_from_event(Event),
        bondy_oplog_event:key_hlc(Key),
        Origin
    }.

%% @private
%% Allocates a fresh `{HLC, Origin, Seq}` for each item, signs the
%% event via the configured validator, and threads the validator state
%% forward. Returns `{Events, Keys, NewState}`. Thin state wrapper over
%% `do_build_events/6` — the same minting core (and the same
%% single-range seq reservation, which is what makes the WAL-failure
%% rollback in `do_append_local/3` safe) as the fast paths.
build_events(State0, Items) ->
    {Events, Keys, VS} = do_build_events(
        State0#state.hlc,
        State0#state.seq,
        State0#state.origin,
        State0#state.validator_module,
        State0#state.validator_state,
        Items
    ),
    {Events, Keys, State0#state{validator_state = VS}}.

%% @private
%% Backfills a burned seq range `[Start, End]` with signed `seq_fill`
%% no-op events: fresh HLC ticks (HLCs are never recycled), the burned
%% seqs themselves (their only occupants — the rejected batch that
%% reserved them never became durable), signed through the validator
%% like any event. The fills ride the normal WAL → applier → MST path,
%% so they replicate and advance the applied frontier on every replica
%% (`bondy_oplog_cell_apply` counts `seq_fill` in `origin_seqs/2` and
%% skips it in every fold), closing the gap the peers' prefix hold
%% would otherwise park on until a rebootstrap. No overlay row is
%% staged — a fill has no readable value.
%%
%% A rejected fill append retries with exponential backoff (the
%% rejection is usually the same transient backpressure that caused
%% the burn); after `?SEQ_FILL_MAX_RETRIES` the gap is left to the
%% rebootstrap repair chain, already counted by `seq_burned`.
fill_burned_seqs(State0, Start, End, Attempt) ->
    Items = [{seq_fill, undefined} || _ <- lists:seq(Start, End)],
    {Events, _Keys, State} = build_fill_events(State0, Start, Items),
    case fast_wal_append_batch(State#state.instance_id, Events) of
        ok ->
            telemetry:execute(
                [bondy_oplog, instance, seq_filled],
                #{count => End - Start + 1},
                #{instance_id => State#state.instance_id}
            ),
            State;
        {error, _Reason} when Attempt < ?SEQ_FILL_MAX_RETRIES ->
            _ = erlang:send_after(
                min(100 bsl Attempt, 5000),
                self(),
                {fill_burned_seqs, Start, End, Attempt + 1}
            ),
            State;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "Burned-seq backfill gave up after retries; the "
                    "range stays a permanent per-origin gap — peers "
                    "hold at it and repair via catalogue rebootstrap.",
                instance_id => State#state.instance_id,
                seq_range => {Start, End},
                reason => Reason
            }),
            State
    end.

%% @private
%% Mints signed `seq_fill` events over an explicit seq range — no
%% reservation, the range was already reserved (and then burned) by the
%% rejected batch. Thin state wrapper over `do_build_events_at/6`,
%% exactly as `build_events/2` wraps `do_build_events/6`.
build_fill_events(State0, StartSeq, Items) ->
    {Events, Keys, VS} = do_build_events_at(
        State0#state.hlc,
        StartSeq,
        State0#state.origin,
        State0#state.validator_module,
        State0#state.validator_state,
        Items
    ),
    {Events, Keys, State0#state{validator_state = VS}}.

%% @private
%% Sole MST-install path for local-origin events. Driven by the
%% `install_local_batch` cast from the per-instance applier. The
%% applier has already re-verified every event's signature in its
%% own process before dispatching, so this fold trusts the input.
%%
%% The batch is split by `max_local_installed_seq`:
%%
%% 1. **Fast suffix** — events with local origin and `Seq` strictly
%%    greater than the cached max. The seq atomic is monotonic per
%%    origin so these keys cannot yet be in the tree. We collect
%%    them into a list of `{Key, Value}` pairs and install them via
%%    `bondy_mst:put_batch/2`, which builds a small in-process MST
%%    from the batch and merges it into the live tree in a single
%%    traversal — one spine rebuild for the whole batch instead of
%%    one per event.
%% 2. **Slow prefix** — events whose seq has already been observed
%%    (resume-overlap) or that carry a non-local origin. These fall
%%    back to the per-event safety path that probes the tree with
%%    `bondy_mst:get` and either re-applies idempotently, ignores a
%%    matching value, or records an equivocation.
%%
%% Within a single WAL frame the local-origin seqs are contiguous and
%% strictly increasing (one batch from one writer), so the partition
%% is a single `lists:splitwith/2`. The merger configured on the live
%% tree is never invoked from the fast suffix because every key is
%% guaranteed new — the only callers of put_batch here are batches
%% that the seq filter has already promised contain no collisions.
-spec install_local_batch(#state{}, [bondy_oplog_event:t()]) -> #state{}.

install_local_batch(State, []) ->
    State;
install_local_batch(#state{} = State0, Events) ->
    Origin = State0#state.origin,
    MaxSeq = State0#state.max_local_installed_seq,
    {Slow, Fast} =
        lists:splitwith(
            fun(E) -> not is_fast_install(E, Origin, MaxSeq) end,
            Events
        ),
    State1 = install_slow_events(State0, Slow),
    install_fast_events(State1, Fast).

%% @private
is_fast_install(Event, Origin, MaxSeq) ->
    Key = bondy_oplog_event:key(Event),
    bondy_oplog_event:key_origin(Key) =:= Origin andalso
        bondy_oplog_event:key_seq(Key) > MaxSeq.

%% @private
%% MST root durability barrier, invoked at the applier's commit boundary
%% (`drain_install_queue`). Each install_local_batch merged its events into the
%% MST and staged the new root in RAM via `bondy_mst:put_batch/2`'s single
%% `set_root`; this forces that staged root durable so `resume_position/2`
%% bounds crash replay to one commit window. It rides the existing per-commit
%% barrier — it does NOT touch the per-batch merge fast path and never enters
%% the per-put path. No-op for ephemeral (ets/map) backends.
flush_mst_root(#state{mst = undefined} = State) ->
    State;
flush_mst_root(#state{mst = MST0, instance_id = Id} = State) ->
    case bondy_mst:flush(MST0) of
        {ok, MST1} ->
            State#state{mst = MST1};
        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "Failed to flush durable MST root at commit barrier",
                instance_id => Id,
                reason => Reason
            }),
            %% Leave the staged root in place; the next commit barrier retries.
            State
    end.

%% @private
%% Like `flush_mst_root/1` but surfaces the error instead of swallowing it.
%% Compaction uses this so it can REFUSE to advance the durable checkpoint
%% watermark when the (truncated) MST root could not be made durable —
%% otherwise the durable checkpoint outruns the durable root and a crash in
%% between resumes past events on reboot (`resume_position/2`), corrupting
%% the shard. Returns `{ok, State}` (mst handle advanced) or `{error, _}`.
flush_mst_root_checked(#state{mst = undefined} = State) ->
    {ok, State};
flush_mst_root_checked(#state{mst = MST0} = State) ->
    case bondy_mst:flush(MST0) of
        {ok, MST1} ->
            {ok, State#state{mst = MST1}};
        {error, _} = Error ->
            Error
    end.

%% @private
%% Drives the asynchronous pack-store seal at the commit barrier. A no-op
%% when `drive_seal` is false (sync mode / ephemeral backend) or while a seal
%% is already in flight: in the latter case the backend would `{defer}` and
%% incoming.pack keeps growing, but the seal self-regulates — the first
%% commit barrier after `complete_seal/2` rolls the pages accumulated during
%% the seal, so incoming is bounded by (write-rate × seal-duration) rather
%% than growing unboundedly. A rolled job is sealed in a monitored worker so
%% the multi-hundred-ms rewrite never blocks the install/commit loop.
maybe_drive_seal(#state{drive_seal = false} = State) ->
    State;
maybe_drive_seal(#state{seal = Seal} = State) when Seal =/= undefined ->
    State;
maybe_drive_seal(#state{mst = MST0} = State) ->
    case bondy_mst:maybe_roll_for_seal(MST0) of
        {rolled, Token, MST1} ->
            start_seal_worker(State#state{mst = MST1}, Token, 0);
        {defer, MST1} ->
            State#state{mst = MST1};
        {noop, MST1} ->
            State#state{mst = MST1}
    end.

%% @private
%% Spawns a monitored worker to run the self-contained seal job off the
%% instance process. The worker tags its completion with the pack id (unique
%% while in flight) then exits; a crash before it reports surfaces as the
%% monitor `DOWN`. Monitored (not linked) so a worker fault degrades to a
%% retry rather than taking the instance down — but the worker IS killed in
%% `terminate/2` so a stopping instance never leaves an orphan writer racing
%% the reopen recovery.
start_seal_worker(#state{} = State, Token, Retries) ->
    PackId = bondy_mst:seal_job_pack_id(Token),
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Result = bondy_mst:run_seal_job(Token),
        Self ! {seal_done, PackId, Result}
    end),
    State#state{
        seal = #seal{
            pid = Pid,
            ref = Ref,
            token = Token,
            pack_id = PackId,
            retries = Retries
        }
    }.

%% @private
%% Finalises a completed seal: commits the manifest + mounts the new sealed
%% view (`bondy_mst:complete_seal/2`), then clears the in-flight slot.
complete_seal_now(#state{mst = MST0} = State, PackId) ->
    case bondy_mst:complete_seal(MST0, PackId) of
        {ok, MST1} ->
            {ok, State#state{mst = MST1, seal = undefined}};
        {error, _} = Error ->
            Error
    end.

%% @private
%% A seal attempt failed (worker error result or crash). Re-run the
%% self-contained job up to `?MAX_SEAL_RETRIES` — the first retry after a
%% killed-worker leftover cleans its own `.tmp` via the seal pipeline's
%% error path, so a transient fault clears within a couple of attempts. On
%% exhaustion stop the instance so the supervisor restart + reopen recovery
%% re-seals the frozen incoming pack from scratch.
retry_or_fail_seal(
    #state{instance_id = Id, seal = #seal{token = Token, retries = Retries}} =
        State,
    PackId,
    Reason
) when Retries < ?MAX_SEAL_RETRIES ->
    ?LOG_WARNING(#{
        description => "Async pack-store seal attempt failed; retrying",
        instance_id => Id,
        pack_id => PackId,
        attempt => Retries + 1,
        reason => Reason
    }),
    {noreply, start_seal_worker(State, Token, Retries + 1)};
retry_or_fail_seal(#state{instance_id = Id} = State, PackId, Reason) ->
    ?LOG_ERROR(#{
        description =>
            "Async pack-store seal failed after retries; stopping for "
            "restart + reopen recovery",
        instance_id => Id,
        pack_id => PackId,
        reason => Reason
    }),
    {stop, {seal_failed, PackId, Reason}, State#state{seal = undefined}}.

%% @private
%% Kills a (possibly already dead) in-flight seal worker and flushes its
%% monitor. Used at `terminate/2` so a stopping instance leaves no orphan
%% writer for the reopen recovery to race.
stop_seal_worker(undefined) ->
    ok;
stop_seal_worker(#seal{pid = Pid, ref = Ref}) ->
    _ = erlang:demonitor(Ref, [flush]),
    _ = exit(Pid, kill),
    ok.

%% @private
install_slow_events(State, []) ->
    State;
install_slow_events(State0, [Event | Rest]) ->
    Key = bondy_oplog_event:key(Event),
    NewValue = value_from_event(Event),
    State1 = install_local_safe(State0, Event, Key, NewValue),
    install_slow_events(State1, Rest).

%% @private
%% Bulk-install a list of known-new local-origin events. Builds a
%% `{Key, Value}` list, drives `bondy_mst:put_batch/2`, then updates
%% the cached aggregates (`max_local_installed_seq`, `last_event_key`,
%% `live_size`) and bumps the HLC once for the maximum HLC seen.
%% Emits a single batch-level telemetry event with `count => N`.
install_fast_events(State, []) ->
    State;
install_fast_events(#state{} = State0, Events) ->
    {Pairs, MaxSeq, MaxKey, MaxHlc, Count} = scan_fast_events(Events, State0),
    InstallT0 = erlang:monotonic_time(microsecond),
    MST1 = bondy_mst:put_batch(State0#state.mst, Pairs),
    InstallUs = erlang:monotonic_time(microsecond) - InstallT0,
    _ = bondy_oplog_hlc:update(State0#state.hlc, MaxHlc),
    %% Mirror the HLC update for the local-Seq atomic. Rebuilding the
    %% MST from the WAL on restart (init seeds SeqRef from
    %% `max_local_seq/2`, which returns `undefined` for an empty MST)
    %% would otherwise leave SeqRef at 0 while WAL-replayed events
    %% carry seqs 1..N. A concurrent `append_fast/3` mid-replay would
    %% then allocate a colliding seq and the resulting event would
    %% clobber a pre-restart event at the same `{HLC, Origin, Seq}`
    %% key. CAS-loop because concurrent local appenders can race here.
    ok = maybe_bump_seq_atomic(State0#state.seq, MaxSeq),
    telemetry:execute(
        [bondy_oplog, instance, apply_event, ok],
        #{count => Count},
        #{instance_id => State0#state.instance_id, new => true}
    ),
    %% Per-batch wall-time of the MST install — the single
    %% `bondy_mst:put_batch/2` spine rebuild that writes into the
    %% pluggable store. For the pack-store backend this is the durable
    %% MST page churn, and it runs in THIS (instance) process, off the
    %% applier's critical path: the applier's `batch_install_cast` only
    %% times the async cast, so without this event the pack-store cost is
    %% invisible. `count` lets handlers derive per-event install cost and
    %% the mean batch size (`count / calls`).
    telemetry:execute(
        [bondy_oplog, instance, mst_install],
        #{duration_us => InstallUs, count => Count},
        #{instance_id => State0#state.instance_id}
    ),
    State0#state{
        mst = MST1,
        max_local_installed_seq = MaxSeq,
        last_event_key = greater_key(State0#state.last_event_key, MaxKey),
        live_size = State0#state.live_size + Count
    }.

%% @private
%% Lift `SeqRef` to at least `Target`. No-op when the atomic is
%% already at or above `Target`. Concurrent appenders that allocate a
%% higher seq mid-call land naturally on the no-op branch on retry.
maybe_bump_seq_atomic(_SeqRef, 0) ->
    ok;
maybe_bump_seq_atomic(SeqRef, Target) ->
    Cur = atomics:get(SeqRef, 1),
    case Target =< Cur of
        true ->
            ok;
        false ->
            case atomics:compare_exchange(SeqRef, 1, Cur, Target) of
                ok ->
                    ok;
                _Observed ->
                    maybe_bump_seq_atomic(SeqRef, Target)
            end
    end.

%% @private
%% Single pass over the fast-suffix events: builds the `{Key, Value}`
%% list (in batch order), tracks the maximum seq / key / HLC, and
%% counts the events. `lists:foldl/3` accumulates the pair list in
%% reverse, so the result is flipped before return — preserving the
%% per-event path's observable ordering for any telemetry handlers
%% downstream.
scan_fast_events(Events, #state{max_local_installed_seq = StartSeq}) ->
    {PairsRev, MaxSeq, MaxKey, MaxHlc, Count} =
        lists:foldl(
            fun(Event, {PairsAcc, SeqAcc, KeyAcc, HlcAcc, N}) ->
                Key = bondy_oplog_event:key(Event),
                Value = value_from_event(Event),
                Seq = bondy_oplog_event:key_seq(Key),
                Hlc = bondy_oplog_event:key_hlc(Key),
                {
                    [{Key, Value} | PairsAcc],
                    erlang:max(SeqAcc, Seq),
                    greater_key(KeyAcc, Key),
                    erlang:max(HlcAcc, Hlc),
                    N + 1
                }
            end,
            {[], StartSeq, undefined, 0, 0},
            Events
        ),
    {lists:reverse(PairsRev), MaxSeq, MaxKey, MaxHlc, Count}.

%% @private
%% Returns the greater of two event keys, treating `undefined` as
%% absent. Distinct from `max_key/2` further down (which uses the
%% `{ok, _} | empty` envelope expected by readers).
greater_key(undefined, K) -> K;
greater_key(K, undefined) -> K;
greater_key(A, B) when A > B -> A;
greater_key(_A, B) -> B.

%% @private
%% Safety path used for resume-overlap and any non-local seq event.
%% Probes the MST so an existing entry is detected as either an
%% idempotent re-apply (same value) or an equivocation (different
%% value at the same key).
install_local_safe(State, Event, Key, NewValue) ->
    case bondy_mst:get(State#state.mst, Key) of
        undefined ->
            install_event(State, Key, NewValue, apply_event, true);
        NewValue ->
            install_event(State, Key, NewValue, apply_event, false);
        ExistingValue ->
            record_equivocation(State, Key, ExistingValue, Event),
            State
    end.

%% @private
%% Evicts every overlay row for a freshly-installed batch via N
%% O(log N) `ets:delete/2` point deletes — the overlay is an
%% `ordered_set` so a deletion keyed by the row's primary key uses
%% the index. The earlier approach built an N-way OR guard for a
%% single `ets:select_delete/2`, but the resulting match spec did not
%% pin the key in the head and so triggered a full table scan; on a
%% 10k-row overlay with batches of 100 events that pattern cost
%% ~1M comparisons per call. Point deletes drop that to ~1.3k.
%%
%% No HLC guard is needed: an event key `{Hlc, Origin, Seq}` is
%% globally unique by construction (HLC and Seq are atomics; Origin
%% is per-instance), so an overlay row at that key corresponds to
%% exactly this event and no other.
-spec evict_overlay_batch(#state{}, [bondy_oplog_event:t()]) -> #state{}.

evict_overlay_batch(#state{overlay = undefined} = State, _Events) ->
    State;
evict_overlay_batch(State, []) ->
    State;
evict_overlay_batch(
    #state{overlay = Tab, overlay_counters = Ctrs} = State, Events
) ->
    Count =
        try
            lists:foreach(
                fun(E) ->
                    ets:delete(Tab, bondy_oplog_event:key(E))
                end,
                Events
            ),
            length(Events)
        catch
            error:badarg -> 0
        end,
    overlay_counters_sub(Ctrs, Count),
    State.

%% @private
%% Removes `Deleted` events from the overlay counters atomics. The
%% byte delta is computed proportionally to the surviving fraction —
%% same approximation the prior in-state version used. We snapshot
%% both slots together, compute the new pair, and write each slot
%% individually with `atomics:put/3`; a concurrent `append_fast/3`
%% that races between the two writes can transiently underestimate
%% byte usage by one increment, which is acceptable (backpressure
%% accounting is best-effort, not exact).
overlay_counters_sub(_Ctrs, 0) ->
    ok;
overlay_counters_sub(Ctrs, Deleted) ->
    OldCount = atomics:get(Ctrs, 1),
    OldBytes = atomics:get(Ctrs, 2),
    NewCount = max(0, OldCount - Deleted),
    NewBytes =
        case OldCount of
            0 -> 0;
            _ -> OldBytes * NewCount div OldCount
        end,
    ok = atomics:put(Ctrs, 1, NewCount),
    ok = atomics:put(Ctrs, 2, NewBytes),
    ok.

%% @private
%% Returns `{ok, WalPid, State1}` with `State1` carrying a monitored
%% cached pid so subsequent appends skip the registry lookup. If the
%% registry does not yet have a `wal_pid` (subtree mid-restart), the
%% cache is left empty and the caller surfaces `{error, wal_unavailable}`.
ensure_wal_pid(#state{wal_pid = Pid} = State) when is_pid(Pid) ->
    {ok, Pid, State};
ensure_wal_pid(#state{instance_id = Id} = State) ->
    case bondy_oplog_registry:wal_pid(Id) of
        undefined ->
            {error, wal_unavailable};
        Pid when is_pid(Pid) ->
            Ref = erlang:monitor(process, Pid),
            {ok, Pid, State#state{wal_pid = Pid, wal_pid_monitor = Ref}}
    end.

%% @private
%% Drops the cached WAL pid + its monitor. Used after a synchronous
%% append surfaces `noproc` so the next append rolls forward to the
%% new writer once the supervisor brings it up.
invalidate_wal_pid(#state{wal_pid_monitor = undefined} = State) ->
    State#state{wal_pid = undefined};
invalidate_wal_pid(#state{wal_pid_monitor = Ref} = State) ->
    _ = erlang:demonitor(Ref, [flush]),
    State#state{wal_pid = undefined, wal_pid_monitor = undefined}.

%% @private
%% Install path for peer-received events. The applier has already
%% re-verified the signature in its own process before forwarding
%% here, so this function trusts the input and runs the remaining
%% accept/reject logic:
%%
%% - At-or-below-watermark door (`append_remote_below_watermark/3`) —
%%   the live-event twin of `watermark_door/3`. An at-or-below-
%%   watermark key is usually compacted history we already folded
%%   (idempotent drop), but it may also be a NEVER-applied event whose
%%   key the locally-advancing watermark passed while it was in
%%   flight. Those are accepted — installed and delivered like any
%%   other remote event — instead of dropped; the applied VV is the
%%   witness, exactly as at the integrate door.
%% - `bondy_mst:get` three-way (`append_remote_install/3`):
%%   - `undefined`: fresh insert + remote delivery
%%     (`deliver_remote/1` — fold inline when fused, fence + replay
%%     cast when applier-backed).
%%   - bit-identical existing value: idempotent re-receive, no-op (a
%%     prior insert already delivered it).
%%   - different existing value: equivocation; record proof in the
%%     quarantine table, leave the MST unchanged, return
%%     `{error, equivocation_detected}`. Keeping the gen_server alive
%%     on bad input avoids a crash-loop on poisoned peer traffic.
do_append_remote(#state{} = State, Event) ->
    Key = bondy_oplog_event:key(Event),
    _ = bondy_oplog_hlc:update(
        State#state.hlc, bondy_oplog_event:key_hlc(Key)
    ),
    case below_or_equal_watermark(Key, State#state.watermark) of
        true ->
            append_remote_below_watermark(State, Key, Event);
        false ->
            append_remote_install(State, Key, Event)
    end.

%% @private
%% THE LIVE-EVENT WATERMARK DOOR (see `watermark_door/3` for the page-
%% sync twin and the full rationale). "At or below the watermark ⇒
%% already folded here" is FALSE for a peer event this replica never
%% saw, so the filter must not drop on key order alone:
%%
%% - Projection-backed instance + the applied VV does NOT witness the
%%   event (`Seq > VV[Origin]`) → never applied here: install and
%%   deliver it like any above-watermark event. The MST briefly holds
%%   an at-or-below-watermark key; that is safe on both projection
%%   classes — fused folds it inline in `deliver_remote/1` before this
%%   handler returns (so a later compaction truncates it as applied
%%   history), and an applier-backed instance's truncation sites are
%%   all behind the async catch-up gate, which folds before
%%   truncating (`deliver_remote/1` sets `remote_events_pending` and
%%   bumps `remote_gen`, so an in-flight catch-up defers too).
%% - Applied, or no projection (no VV witness — `resolve_has_projection/1`)
%%   → the legacy idempotent drop.
append_remote_below_watermark(State0, Key, Event) ->
    {HasProjection, State} = resolve_has_projection(State0),
    VV = applied_vv(State#state.instance_id),
    NeverApplied =
        bondy_oplog_event:key_seq(Key) >
            maps:get(bondy_oplog_event:key_origin(Key), VV, 0),
    case HasProjection andalso NeverApplied of
        true ->
            telemetry:execute(
                [bondy_oplog, instance, append_remote, doored],
                #{count => 1},
                #{
                    instance_id => State#state.instance_id,
                    origin => bondy_oplog_event:key_origin(Key),
                    seq => bondy_oplog_event:key_seq(Key)
                }
            ),
            ?LOG_INFO(#{
                description =>
                    "Live-event watermark door: accepted a never-applied "
                    "remote event at or below the local watermark instead "
                    "of discarding it",
                instance_id => State#state.instance_id,
                origin => bondy_oplog_event:key_origin(Key),
                seq => bondy_oplog_event:key_seq(Key)
            }),
            append_remote_install(State, Key, Event);
        false ->
            telemetry:execute(
                [bondy_oplog, instance, append_remote, filtered],
                #{count => 1},
                #{
                    instance_id => State#state.instance_id,
                    reason => below_watermark
                }
            ),
            {ok, State}
    end.

%% @private
%% The `bondy_mst:get` three-way accept path shared by the normal
%% (above-watermark) install and the live-event watermark door. A
%% fresh insert is a remote DELIVERY — `deliver_remote/1` folds it
%% into the projection (fused) or fences + casts the applier replay,
%% so a projection read ordered after this handler's reply observes
%% the event. The idempotent re-receive skips delivery: the insert
%% that first put the value in the MST already delivered it.
append_remote_install(#state{mst = MST0} = State, Key, Event) ->
    NewValue = value_from_event(Event),
    case bondy_mst:get(MST0, Key) of
        undefined ->
            State1 = install_event(
                State, Key, NewValue, append_remote, true
            ),
            {ok, deliver_remote(State1)};
        NewValue ->
            %% Idempotent re-receive (bit-identical).
            {ok, install_event(State, Key, NewValue, append_remote, false)};
        ExistingValue ->
            record_equivocation(State, Key, ExistingValue, Event),
            {error, equivocation_detected}
    end.

%% @private
%% Shared insert path for `install_local_batch` (local-origin events
%% dispatched by the applier after S1 re-verify) and `do_append_remote`
%% (peer-received events). Mutates the MST, refreshes `last_event_key`
%% and `live_size`, advances the HLC, and emits a
%% `[bondy_oplog, instance, Source, ok]` telemetry event so callers
%% can tell the two paths apart in dashboards.
install_event(#state{} = State, Key, Value, Source, IsNew) ->
    MST1 = bondy_mst:put(State#state.mst, Key, Value),
    LastKey =
        case State#state.last_event_key of
            undefined -> Key;
            Prev when Key > Prev -> Key;
            Prev -> Prev
        end,
    _ = bondy_oplog_hlc:update(
        State#state.hlc, bondy_oplog_event:key_hlc(Key)
    ),
    %% If the installed event's origin is **ours**, bump the SeqRef
    %% atomic so a concurrent local `append_fast/3` can't allocate a
    %% colliding seq. This handles two paths:
    %%   1. Slow batch (`install_local_safe`): WAL-replayed local-
    %%      origin events that the fast batcher skipped (resume-
    %%      overlap probe).
    %%   2. Peer loopback (`do_append_remote`): a peer ships back our
    %%      own events via sync — `Origin == self`. Without this bump,
    %%      a subsequent local append after crash recovery could
    %%      allocate a seq that already lives in the MST (installed by
    %%      the peer-shipped copy).
    %% The fast batch path bumps once at end-of-batch in
    %% `install_fast_events/2` (cheaper) and does **not** go through
    %% `install_event/5`, so the per-event bump here doesn't duplicate.
    case bondy_oplog_event:key_origin(Key) of
        Origin when Origin =:= State#state.origin ->
            ok = maybe_bump_seq_atomic(
                State#state.seq, bondy_oplog_event:key_seq(Key)
            );
        _Other ->
            ok
    end,
    SizeDelta =
        case IsNew of
            true -> 1;
            false -> 0
        end,
    telemetry:execute(
        [bondy_oplog, instance, Source, ok],
        #{count => 1},
        #{instance_id => State#state.instance_id, new => IsNew}
    ),
    State#state{
        mst = MST1,
        last_event_key = LastKey,
        live_size = State#state.live_size + SizeDelta
    }.

%% @private
record_equivocation(#state{} = State, Key, ExistingValue, IncomingEvent) ->
    ExistingEvent = event_from_value(Key, ExistingValue),
    Proof = (State#state.validator_module):detect_equivocation(
        ExistingEvent, IncomingEvent
    ),
    bondy_oplog_quarantine:record(
        State#state.instance_id,
        Key,
        ExistingEvent,
        IncomingEvent,
        Proof
    ),
    telemetry:execute(
        [bondy_oplog, instance, append_remote, equivocation],
        #{count => 1},
        #{
            instance_id => State#state.instance_id,
            origin => bondy_oplog_event:key_origin(Key)
        }
    ),
    ok.

%% @private
below_or_equal_watermark(_Key, undefined) ->
    false;
below_or_equal_watermark(Key, Watermark) ->
    Key =< Watermark.

%% @private
%% Returns the number of items currently in the MST. Linear in tree
%% size; used after merge/integrate where the size delta is unknown.
compute_live_size(MST) ->
    bondy_mst:fold(MST, fun(_, Acc) -> Acc + 1 end, 0).

%% @private
%% MST value shape: a 4-tuple of `{Op, Meta, PrevHash, Signature}`.
value_from_event(Event) ->
    {
        bondy_oplog_event:op(Event),
        bondy_oplog_event:meta(Event),
        bondy_oplog_event:prev_hash(Event),
        bondy_oplog_event:signature(Event)
    }.

%% @private
event_from_value(Key, {Op, Meta, PrevHash, Signature}) ->
    bondy_oplog_event:new(Key, Op, Meta, PrevHash, Signature).

%% @private
%% Returns the maximum `Seq` field among events whose origin matches
%% `LocalOrigin`. `undefined` if no such events exist. Used at init to
%% seed the per-origin Seq counter from persisted state.
max_local_seq(MST, LocalOrigin) ->
    bondy_mst:fold(
        MST,
        fun({K, _V}, Acc) ->
            case bondy_oplog_event:key_origin(K) of
                LocalOrigin ->
                    Seq = bondy_oplog_event:key_seq(K),
                    case Acc of
                        undefined -> Seq;
                        N when Seq > N -> Seq;
                        N -> N
                    end;
                _ ->
                    Acc
            end
        end,
        undefined
    ).

%% @private
%% Reconstruct the applied-frontier version vector `#{Origin => max Seq}` from
%% the live MST's `cell_apply` event keys at init. The MST holds the uncompacted,
%% already-applied events (between the compaction watermark and the durable
%% root); a clean restart resumes PAST them, so the apply path never refires for
%% them and the frontier must be folded out of the MST directly. Counts the SAME
%% events the apply path counts (`{cell_apply, ...}` ops only — see
%% `bondy_oplog_cell_apply:batch_frontier/1`), so a restart-reconstructed
%% frontier equals the incrementally-maintained one. O(live MST) — bounded by
%% compaction, the same cost class as `compute_live_size/1` / `max_local_seq/2`,
%% NOT the projection. Composed at init with the checkpoint frontier (the
%% compacted prefix) and the WAL-tail replay (events past the durable root).
frontier_from_mst(MST) ->
    bondy_mst:fold(
        MST,
        fun
            ({K, {{cell_apply, _B, _CK, _FE}, _Meta, _Prev, _Sig}}, Acc) ->
                Origin = bondy_oplog_event:key_origin(K),
                Seq = bondy_oplog_event:key_seq(K),
                case Acc of
                    #{Origin := Cur} when Cur >= Seq -> Acc;
                    _ -> Acc#{Origin => Seq}
                end;
            ({_K, _V}, Acc) ->
                Acc
        end,
        #{}
    ).

%% @private
%% Combined admission test: overlay pressure first, then the MST
%% working-set cap. Both checks are O(1) — overlay numbers come
%% from `ets:info/2`, working-set from cached `live_size`. The order
%% does not affect correctness because either failure is decisive;
%% overlay-first surfaces the more specific `backpressure` error
%% name when both would fire.
admit(State, Delta) ->
    case overlay_admit(State, Delta) of
        ok -> backpressure_admit(State, Delta);
        Err -> Err
    end.

%% @private
%% Pressure-check before the WAL append. Returns
%% `{error, backpressure}` when either cap is breached. `drop` is the
%% only supported strategy; `block` is reserved.
%%
%% Reads both slots of the shared `overlay_counters` atomics — slot
%% 1 the event count, slot 2 the byte estimate. Both are maintained
%% by `stage_to_overlay/2` and `evict_overlay_batch/2`, and by
%% lock-free `append_fast/2,3` callers. Pre-history this read pair
%% `ets:info/2` on the overlay table for size and memory; under
%% heavy concurrent appends those calls aggregated decentralised
%% counters across every scheduler and dominated the gen_server's
%% per-call cost.
overlay_admit(
    #state{
        instance_id = Id,
        overlay_counters = Ctrs,
        max_overlay_events = MaxEvents,
        max_overlay_bytes = MaxBytes
    },
    Delta
) ->
    {Size, Bytes} = overlay_counters_get(Ctrs),
    case Size + Delta > MaxEvents of
        true ->
            emit_overlay_backpressure(Id, events, Size, MaxEvents, Delta),
            {error, backpressure};
        false ->
            case Bytes >= MaxBytes of
                true ->
                    emit_overlay_backpressure(
                        Id, bytes, Bytes, MaxBytes, Delta
                    ),
                    {error, backpressure};
                false ->
                    ok
            end
    end.

%% @private
emit_overlay_backpressure(Id, Dimension, Current, Cap, Delta) ->
    telemetry:execute(
        [bondy_oplog, instance, overlay, backpressure_drop],
        #{count => 1},
        #{
            instance_id => Id,
            dimension => Dimension,
            current => Current,
            cap => Cap,
            requested => Delta
        }
    ).

%% @private
%% Backpressure admission test. Returns `ok` if the instance can
%% absorb `Delta` more events under its `max_working_set` cap, or
%% `{error, working_set_full}` otherwise. `infinity` disables the
%% cap.
%%
%% The cap is on **total events visible to readers** = MST live_size
%% + overlay rows (matching `size/1`), because events arriving via
%% `append`/`append_many` enter the overlay before the applier
%% promotes them to the MST. Counting only `live_size` would let the
%% caller burst arbitrarily many writes into the overlay before the
%% cap fires.
backpressure_admit(#state{max_working_set = infinity}, _Delta) ->
    ok;
backpressure_admit(
    #state{
        max_working_set = Cap,
        live_size = Size,
        overlay_counters = Ctrs
    } = State,
    Delta
) ->
    OverlaySize = atomics:get(Ctrs, 1),
    Total = Size + OverlaySize,
    case Total + Delta =< Cap of
        true ->
            ok;
        false ->
            telemetry:execute(
                [bondy_oplog, instance, backpressure],
                #{count => 1},
                #{
                    instance_id => State#state.instance_id,
                    requested => Delta,
                    live_size => Size,
                    overlay_size => OverlaySize,
                    cap => Cap
                }
            ),
            {error, working_set_full}
    end.

%% @private
%% Monotone watermark advance: returns whichever of the two values is
%% higher, treating `undefined` as the bottom. Used by both compaction
%% (via direct assignment, which is safe by construction — compaction
%% rejects frontiers ≤ current watermark) and operator-driven
%% `truncate_prefix`, where the caller's value could in principle be
%% lower than a previously installed compaction watermark.
advance_watermark(undefined, New) -> New;
advance_watermark(Cur, New) when New > Cur -> New;
advance_watermark(Cur, _New) -> Cur.

%% @private
%% Drops every key in MST that is `=< Watermark`, keeping the suffix of
%% keys `> Watermark`. Used both by explicit truncation and post-merge
%% re-truncation.
%%
%% Delegates to `bondy_mst:truncate/2` — a structural prefix-truncate
%% that walks only the tree's left spine, rewriting `O(log N)` pages
%% instead of issuing one `O(log N)` `delete/2` per stale key. This is
%% what lets compaction keep the live MST bounded under sustained write
%% saturation: the truncation cost is decoupled from the prefix size, so
%% a single cycle removes the whole stable prefix in time independent of
%% how many events accumulated. (The old per-key delete loop was
%% `O(P·log N)` and ran inside the gen_server, so at saturation the
%% truncation could not keep pace with the write rate and the MST grew
%% without bound — `mst_install` degraded and throughput collapsed.)
%%
%% The result is byte-identical to the equivalent delete sequence (the
%% MST is history-independent), so the root hash that peers sync against
%% is unchanged.
%%
%% Truncation only UNLINKS the dropped subtrees — `bondy_mst:truncate/2`
%% frees the O(log N) spine pages it rewrites, but the dropped subtrees'
%% interior pages are merely left unreachable, awaiting the store's
%% garbage collector. Nothing else ever runs that collector, so on the
%% ephemeral (ETS) backend every truncation leaked its whole dropped
%% prefix into the page table: registry shards whose event count read 0
%% still pinned hundreds of MB of orphaned pages (the residual RAM
%% plateau after the fleet OOM's scheduler fix). The mark-and-sweep
%% `bondy_mst:gc/1` (current root protected) reclaims them here, at the
%% only moments bulk garbage is created. Steady-state cost is small: the
%% post-truncate live tree is the mark set and the swept table holds
%% little beyond it once GC runs every cycle. NOT run for the pack
%% (durable) backend, where list-mode GC is a sealed-pack rewrite with
%% its own lifecycle — durable pack reclamation is a separate concern
%% (disk, not RAM).
truncate_below_or_equal(MST, Watermark, ets, KeepRoots) ->
    %% `KeepRoots` (the session-pinned peer roots, see `pin_peer_root/2`)
    %% protects pulled-but-not-yet-merged sync pages from the sweep —
    %% they are unreachable from OUR current root until
    %% `integrate_peer_root/2` merges them, and without the pin every
    %% compaction cycle during a multi-round pull collected the earlier
    %% rounds' pages (observed as silent partial merges — see
    %% `do_integrate_peer_root/2`). `bondy_mst:gc/2` adds the current
    %% root itself.
    bondy_mst:gc(bondy_mst:truncate(MST, Watermark), KeepRoots);
truncate_below_or_equal(MST, Watermark, _Backend, _KeepRoots) ->
    bondy_mst:truncate(MST, Watermark).

%% @private
%% Durable (pack) page reclamation.
%%
%% `truncate_below_or_equal/4` collects only on the ETS backend; on the pack
%% backend truncation merely unlinks the dropped subtrees, so every durable
%% compaction left its prefix in the sealed packs and NOTHING ever reclaimed
%% it — the disk-side twin of the ETS page leak, slow-burning but unbounded.
%%
%% Runs on the compaction tick (the one periodic in-process hook, alongside
%% `maybe_self_heal_unservable/2`) rather than per truncation, because a pack
%% collection is a full sealed-pack REWRITE: `should_compact/3` coalesces
%% whenever there is more than one sealed pack, so invoking it per cycle would
%% rewrite the entire sealed set every cycle. Gated on:
%%
%%   - the store actually being a pack store (ETS collects inline already);
%%   - no seal in flight — a collection rewrites the very packs a seal is
%%     producing;
%%   - at most one collection per `durable_gc_interval_ms` (default 1 hour).
%%
%% It must run HERE, in the instance process: the pack store declares
%% `process_bound_reads => true` because its sealed-pack fds are owned by this
%% process, and the collection reads every sealed record to rewrite it.
%%
%% Liveness is `bondy_mst:gc/2`'s: it marks from the current root plus the
%% session-pinned peer roots, and refuses to sweep at all while the current
%% root is unservable.
maybe_collect_durable(#state{mst = undefined} = State) ->
    State;
maybe_collect_durable(#state{mst = MST} = State) ->
    case pack_backend(MST) of
        undefined ->
            State;
        Backend ->
            Now = erlang:monotonic_time(millisecond),
            Interval = application:get_env(
                bondy_oplog, durable_gc_interval_ms, ?DURABLE_GC_INTERVAL_MS
            ),
            case State#state.last_durable_gc of
                undefined ->
                    %% ARM the clock, do not collect. A shard that has been
                    %% running for months reopens with many sealed packs, and
                    %% `should_compact/3` coalesces whenever there is more than
                    %% one — so firing on the first tick after boot would stall
                    %% the instance on a full sealed-pack rewrite exactly when
                    %% it is trying to come up.
                    State#state{last_durable_gc = Now};
                Last when Now - Last < Interval ->
                    State;
                _ ->
                    case bondy_mst_pack_store:seal_in_flight(Backend) of
                        true ->
                            %% Leave the clock alone so the next tick retries
                            %% rather than waiting out another whole interval.
                            State;
                        false ->
                            MST1 = bondy_mst:gc(MST, pinned_roots(State)),
                            State#state{mst = MST1, last_durable_gc = Now}
                    end
            end
    end.

%% @private
%% The pack store's backend state, or `undefined` for any other store. Keyed
%% off the store record rather than `#state.backend` so it cannot drift from
%% how that field happens to be populated.
pack_backend(MST) ->
    case bondy_mst:store(MST) of
        {bondy_mst_store, bondy_mst_pack_store, Backend, _} -> Backend;
        _ -> undefined
    end.

%% @private
%% The live (non-expired) session-pinned peer roots — the extra
%% KeepRoots for `truncate_below_or_equal/4`'s page GC.
pinned_roots(#state{pinned_peer_roots = Pins}) when map_size(Pins) =:= 0 ->
    [];
pinned_roots(#state{pinned_peer_roots = Pins}) ->
    Now = erlang:monotonic_time(millisecond),
    [R || R := T <- Pins, Now - T =< ?PEER_ROOT_PIN_TTL_MS].

%% @private
%% Runs a full compaction cycle synchronously, in the instance
%% gen_server. The frontier is now O(diff) (read-only `diff_to_list` + an
%% O(log N) `get/3` false-positive filter — see `compute_frontier_for/2`),
%% so the cycle is cheap enough to run inline rather than off-process.
%% Running in the gen_server is what makes the durable (pack-store)
%% backend work: the MST is read by the process that OWNS its sealed-pack
%% fds, so `prim_file:pread` no longer raises `not_on_controlling_process`.
%% The truncate + projection flush + checkpoint always ran here; only the
%% frontier moved in.
%%
%% Compaction is serial with every other gen_server message (appends,
%% reads, `load_snapshot`) EXCEPT the catalogue catch-up, which when a
%% remote event is pending hands the projection fold to the applier and
%% defers the truncate to a later `{catch_up_done, _}` cast (one such
%% catch-up per instance at a time, tracked in `pending_compaction`). That
%% deferral is what keeps the instance from blocking on the applier inside
%% the compaction handler — the cross-node deadlock. Every other path
%% (no projection, bare CRDT, or a projection with nothing remote to fold)
%% still commits inline with no applier interaction.
do_compact_sync(
    #state{crdt_module = undefined, fold_module = undefined} = State,
    _PeerRoots
) ->
    {reply, {error, no_crdt_module}, State};
do_compact_sync(#state{} = State0, PeerRoots) ->
    Started = erlang:monotonic_time(),
    %% Resolve (and memoise) projection-presence BEFORE the compaction body
    %% so the body makes no per-cycle `gen_server:call` to the applier (the
    %% instance↔applier deadlock — see the `has_projection` state field).
    {HasProjection, StateR} = resolve_has_projection(State0),
    %% Unservable-own-root self-heal runs on the compaction tick — the
    %% one periodic in-process hook — BEFORE the frontier computation
    %% (a rebuilt tree simply compacts as `no_change`).
    State = maybe_collect_durable(
        maybe_self_heal_unservable(StateR, HasProjection)
    ),
    Result = run_compaction(
        State#state.instance_id,
        State#state.mst,
        State#state.watermark,
        PeerRoots,
        State#state.compaction_checkpoint,
        State#state.compaction_checkpoint_state,
        State#state.cached_checkpoint,
        State#state.crdt_module,
        HasProjection,
        retention_ctx(State, HasProjection)
    ),
    case Result of
        {ok, {catalogue_compacted, Frontier}} when
            State#state.remote_events_pending
        ->
            %% Remote events may lag the projection — fold them via the
            %% applier (async) BEFORE truncating. Step 1 here; step 2 is
            %% `handle_cast({catch_up_done, _})`.
            begin_async_catch_up(State, Started, Frontier);
        _ ->
            {Reply, State1} = commit_compaction(State, Started, Result),
            ok = publish(State1),
            {reply, Reply, State1}
    end.

%% @private
run_compaction(
    InstanceId,
    MST,
    Watermark0,
    PeerRoots,
    CkptMod,
    CkptState,
    CachedCheckpoint,
    CrdtMod,
    HasProjection,
    Retention
) ->
    try
        case compute_frontier_for(MST, PeerRoots) of
            undefined ->
                retention_or_catchup(
                    InstanceId, MST, Watermark0, HasProjection, Retention
                );
            Frontier when
                Watermark0 =/= undefined,
                Frontier =< Watermark0
            ->
                retention_or_catchup(
                    InstanceId, MST, Watermark0, HasProjection, Retention
                );
            Frontier ->
                %% Path is chosen by whether a PROJECTION materialises the
                %% state — NOT by whether `crdt_module` is set. A
                %% projection-backed instance (every `bondy_db` table:
                %% the applier's cell kernel maintains each cell via
                %% `interpret_cog` on write) takes the catalogue path even
                %% though it also has a `crdt_module`.
                %% `HasProjection` is the memoised value (see
                %% `resolve_has_projection/1`) — NOT a per-cycle applier call.
                case HasProjection of
                    true ->
                        %% Catalogue (projection-backed): the projection IS
                        %% the durable checkpoint, so compaction only bounds
                        %% the MST — NO per-cycle `interpret_cog` re-fold of
                        %% the stable range (that O(range) per-event CRDT
                        %% work is what made sustained-write compaction fall
                        %% behind → unbounded MST → throughput collapse).
                        %% The truncate (and a synchronous flush of any
                        %% not-yet-replayed remote events first) runs in
                        %% `commit_compaction`. `EventCount` is derived there
                        %% from the live-size delta (O(remaining)), so this
                        %% does not fold the whole tree to count.
                        {ok, {catalogue_compacted, Frontier}};
                    false when CrdtMod =/= undefined ->
                        %% Bare CRDT instance with no projection: it owns its
                        %% own single-CRDT checkpoint, so fold the newly
                        %% stable range into it via `interpret_cog`.
                        Events = events_in_open_range(
                            MST, Watermark0, Frontier
                        ),
                        BaseCheckpoint =
                            case CachedCheckpoint of
                                undefined ->
                                    case CkptMod:get_checkpoint(CkptState) of
                                        {ok, _W, S} -> S;
                                        not_found -> CrdtMod:init()
                                    end;
                                {_, S0} ->
                                    S0
                            end,
                        NewCheckpoint = CrdtMod:interpret_cog(
                            Events, BaseCheckpoint
                        ),
                        ok = CkptMod:put_checkpoint(
                            CkptState, Frontier, NewCheckpoint
                        ),
                        {ok,
                            {compacted, Frontier, NewCheckpoint,
                                length(Events)}};
                    false ->
                        %% No projection and no CRDT module — nothing holds
                        %% the state, so truncating would lose it. Defer.
                        {ok, no_change}
                end
        end
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR(#{
                description => "compaction raised",
                instance_id => InstanceId,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            {error, {compaction_failed, Class, Reason}}
    end.

%% @private
%% Catch-up truncation. Reached when the peer-confirmed stability frontier did
%% NOT advance past the existing durable watermark (it is `undefined`, or
%% `=< Watermark0`). The MST may still hold entries `=< Watermark0` even
%% though those entries are, by the watermark invariant, already materialised
%% in the durable projection. This happens when a node page-syncs a peer's
%% full (un-compacted) MST and then adopts that peer's watermark via a
%% snapshot: it ends up with `watermark = X` but an MST still carrying
%% `=< X`, permanently DIVERGED from a peer that already compacted its MST to
%% `X` (the peer advertises an empty/compacted root, so this node's
%% peer-confirmed frontier never advances and it never truncates — and it
%% burns CPU re-pulling + failing to converge). Truncating the MST to the
%% EXISTING watermark (no watermark advance) brings it in line. Safe: the
%% watermark guarantees everything `=< X` is durable in the projection.
%%
%% Projection-backed only. A bare-CRDT / no-state instance is left untouched
%% (its checkpoint already holds `=< X`, and the ephemeral registry-style
%% instances do not hit this cross-node divergence).
maybe_watermark_catchup(_MST, undefined, _HasProjection) ->
    {ok, no_change};
maybe_watermark_catchup(MST, Watermark0, true) ->
    case mst_has_entries_at_or_below(MST, Watermark0) of
        true -> {ok, {catalogue_compacted, Watermark0}};
        false -> {ok, no_change}
    end;
maybe_watermark_catchup(_MST, _Watermark0, _HasProjection) ->
    {ok, no_change}.

%% @private
%% True iff the MST's smallest key is `=< Watermark`, i.e. the MST still
%% holds at least one entry the watermark says is already compacted. Event
%% keys use the MST's default term-order comparator, so `=<` matches the
%% ordering `truncate_below_or_equal/2` applies.
mst_has_entries_at_or_below(MST, Watermark) ->
    case bondy_mst:first(MST) of
        undefined -> false;
        {Key, _Value} -> Key =< Watermark
    end.

%% =============================================================================
%% RECLAMATION — causal-stability projection-cell GC
%% =============================================================================

-doc """
The membership set for causal-stability reclamation: the full known Partisan
membership minus this node. The ONLY member source reclamation may use.

Deliberately NOT `bondy_oplog_peer_source:peers_for/2` — that returns a random
sample (default 3), and a sample confirms a frontier the unsampled members
never saw. `partisan_peer_service:members/0` returns the full known membership
INCLUDING currently-unreachable peers (membership changes only by a deliberate
join/leave, never by connectivity), which is what makes a partitioned member
hold stability down instead of vanishing (`BONDY_DB_RECLAMATION_PROOF.md` A4).

Returns `error` — never `[]` — when the membership service is unavailable.
The two MUST NOT be conflated: `[]` means *solo*, which licenses maximal
reclamation, while `error` must propagate as "no stability, reclaim nothing".
Conflating them would let a node that merely cannot see its membership service
reclaim as though nothing could contradict it.
""".
-spec reclamation_members() -> {ok, [node()]} | error.

reclamation_members() ->
    %% The whole call sequence is protected: a dead or hung peer service EXITS
    %% the `gen_server` call rather than returning an error tuple, and that
    %% exit must become `error`, not a crash inside a GC worker (where
    %% `run_trigger/2` would swallow it into a warning with no signal).
    try
        {ok, Members} = partisan_peer_service:members(),
        true = is_list(Members),
        {ok, Members -- [partisan:node()]}
    catch
        _:_ ->
            error
    end.

-doc """
The causal-stability point for projection-cell reclamation: an HLC `h` such
that no event with HLC `< h` can ever be delivered again (POLog Definition
5.1 — the Theorem in `BONDY_DB_RECLAMATION_PROOF.md`).

The chain runs inside the instance because it owns the MST: membership
(`reclamation_members/0`) → strict all-member confirmation
(`bondy_oplog_peer_state:confirmed_peer_states/2`) → frontier over the
confirmed roots (`compute_frontier_for/2`) → the frontier key's HLC.

**Solo** (`members =:= []`) short-circuits to a fresh local tick: with no
member that could contradict this node, every event it holds is stable, and —
because the clock dominates every held event's HLC (locally minted events by
construction, remote deliveries by absorption, bootstrap installs by the
finalize absorb) — a fresh tick strictly exceeds them all. The tick also
covers the two holes an MST-derived point has: an ex-cluster node whose MST
has compacted empty, and the tail tombstone a strict `<` bound would
otherwise never license.

Every negative outcome names its reason, and callers MUST reclaim nothing on
any `{error, _}`:

- `{error, membership_unavailable}` — the membership service cannot be read.
  NOT the same as solo; conflating them would license maximal reclamation on
  a node that merely cannot see its membership service.
- `{error, idle}` — this replica's MST holds no events (fully compacted or
  never written): no frontier can exist and there is nothing whose
  stability needs certifying. The steady state of a converged quiescent
  shard in a cluster — NOT operator-actionable, and reported distinctly so
  the actionable reasons below stay meaningful.
- `{error, {unconfirmed, Peers}}` — members with no confirmed root; a silent
  member holds stability down instead of vanishing (A4).
- `{error, no_frontier}` — no local key is confirmed by every member.
- `{error, non_event_frontier}` — the frontier key is not an event key.
""".
-spec stability_point(instance_id() | pid()) ->
    {ok, bondy_oplog_hlc:hlc()} | {error, term()}.

stability_point(Target) ->
    gen_server:call(target(Target), reclamation_stability_point, infinity).

-doc """
Computes the stability point and, when one exists, runs the applier's
projection-cell sweep at it (`bondy_oplog_applier:sweep_stable_cells/2`).
Any `{error, _}` from `stability_point/1` reclaims nothing and is returned
verbatim, so the caller (a GC trigger, an operator) can see WHY stability is
not advancing.

Runs in the CALLER's process — one call into the instance (the stability
point), one into the applier (the sweep) — deliberately not a single
instance handler: the instance must never block on the applier.
""".
-spec reclaim_stable_cells(instance_id()) ->
    {ok, Stats :: map()} | {error, term()}.

reclaim_stable_cells(InstanceId) when is_binary(InstanceId) ->
    case stability_point(InstanceId) of
        {ok, StableHlc} ->
            case applier_pid_for(InstanceId) of
                {ok, Pid} ->
                    %% Bounded batches to completion: each applier call
                    %% scans at most `reclaim_batch_cells`, so concurrent
                    %% writes interleave between batches instead of
                    %% stalling for the whole pass. Success observability
                    %% is the sweep's own `[bondy_oplog, applier,
                    %% cells_swept]` event per batch, carrying the stats
                    %% and the derived `stable_hlc`.
                    reclaim_batches(
                        fun bondy_oplog_applier:sweep_stable_cells/3,
                        Pid,
                        StableHlc,
                        bondy_oplog_config:reclaim_batch_cells(),
                        undefined,
                        #{
                            scanned => 0,
                            discarded => 0,
                            rewritten => 0,
                            skipped => 0
                        }
                    );
                {error, _} ->
                    %% No separate applier — a fused instance has none by
                    %% design. Fall back to the instance's own equivalent
                    %% handler.
                    case fused_instance_pid_for(InstanceId) of
                        {ok, InstancePid} ->
                            reclaim_batches(
                                fun ?MODULE:sweep_stable_cells/3,
                                InstancePid,
                                StableHlc,
                                bondy_oplog_config:reclaim_batch_cells(),
                                undefined,
                                #{
                                    scanned => 0,
                                    discarded => 0,
                                    rewritten => 0,
                                    skipped => 0
                                }
                            );
                        {error, _} ->
                            reclamation_stalled(InstanceId, no_applier)
                    end
            end;
        {error, Reason} ->
            reclamation_stalled(InstanceId, Reason)
    end.

%% @private
reclaim_batches(SweepFun, Pid, StableHlc, Max, Cursor, Acc) ->
    case SweepFun(Pid, StableHlc, #{max_cells => Max, cursor => Cursor}) of
        {ok, Stats, done} ->
            {ok, merge_sweep_stats(Acc, Stats)};
        {ok, Stats, {resume, Next}} ->
            reclaim_batches(
                SweepFun,
                Pid,
                StableHlc,
                Max,
                Next,
                merge_sweep_stats(Acc, Stats)
            );
        {error, _} = E ->
            E
    end.

%% @private
merge_sweep_stats(A, B) ->
    maps:merge_with(fun(_, X, Y) -> X + Y end, A, B).

%% @private
%% Reclamation fails silently in both directions, so every negative outcome
%% emits `[bondy_oplog, reclamation, stalled]` — the difference between "GC
%% is working" and "GC has been stalled for a week on a decommissioned node
%% nobody retired". Telemetry only here (this runs on every reclamation
%% attempt); the rate-limited LOG naming the missing members is the
%% scheduler's job (`bondy_oplog_gc_scheduler`), which sees the same outcome
%% from its trigger.
reclamation_stalled(InstanceId, Reason) ->
    {Label, Missing} =
        case Reason of
            {unconfirmed, Peers} -> {unconfirmed, Peers};
            Other -> {Other, []}
        end,
    telemetry:execute(
        [bondy_oplog, reclamation, stalled],
        #{count => 1},
        #{
            instance_id => InstanceId,
            reason => Label,
            missing_members => Missing
        }
    ),
    {error, Reason}.

%% @private
%% The single point of truth for classifying a `reclamation_members/0`
%% result into `solo | {clustered, Members} | error`, consumed by
%% `reclamation_stability_point/1` (CRDT-cell reclamation's solo
%% shortcut). MST/WAL compaction no longer needs a solo shortcut: the
%% retention policy (`retention_frontier/3`) bounds ephemeral catalogue
%% instances by local policy regardless of membership, which covers solo
%% trivially. `reclamation_members/0`'s own contract (never conflate `[]`
%% with `error`) is preserved verbatim: `error` in ⇒ `error` out, never
%% `solo`.
-spec membership_class({ok, [node()]} | error) ->
    solo | {clustered, [node()]} | error.

membership_class({ok, []}) -> solo;
membership_class({ok, [_ | _] = Members}) -> {clustered, Members};
membership_class(error) -> error.

%% @private
%% See `stability_point/1`. Membership is read FIRST: the solo carve-out
%% needs only the clock, and an instance with no MST yet must still answer.
reclamation_stability_point(State) ->
    case membership_class(reclamation_members()) of
        error ->
            {error, membership_unavailable};
        solo ->
            %% Solo: a fresh tick strictly exceeds every event this node
            %% holds — see `stability_point/1`.
            {ok, bondy_oplog_hlc:now(State#state.hlc)};
        {clustered, Members} ->
            case local_mst_empty(State) of
                true ->
                    %% Clustered but this replica's tree is empty (fully
                    %% compacted, or never written): a frontier over local
                    %% keys cannot exist by construction, and there is
                    %% nothing whose stability needs certifying. Reported
                    %% as `idle` — distinct from `unconfirmed`/
                    %% `no_frontier`, which name actionable conditions —
                    %% and it clears itself on the next local event.
                    {error, idle};
                false ->
                    confirmed_stability_point(State, Members)
            end
    end.

%% @private
local_mst_empty(#state{mst = undefined}) ->
    true;
local_mst_empty(#state{mst = MST}) ->
    bondy_mst:root(MST) =:= undefined.

%% @private
confirmed_stability_point(#state{mst = undefined}, _Members) ->
    {error, no_frontier};
confirmed_stability_point(#state{instance_id = Id, mst = MST}, Members) ->
    case bondy_oplog_peer_state:confirmed_peer_states(Id, Members) of
        {unconfirmed, Missing} ->
            {error, {unconfirmed, Missing}};
        {ok, States} ->
            Roots = [maps:get(root_hash, S) || S <- States],
            frontier_stability_point(compute_frontier_for(MST, Roots))
    end.

%% @private
%% Frontier key → stability point. Guarded with `is_key/1`: a non-event-keyed
%% frontier must yield a named error, not a raise inside a GC worker — where
%% `bondy_oplog_gc_scheduler:run_trigger/2` would swallow it into a warning.
frontier_stability_point(undefined) ->
    {error, no_frontier};
frontier_stability_point(Key) ->
    case bondy_oplog_event:is_key(Key) of
        true -> {ok, bondy_oplog_event:key_hlc(Key)};
        false -> {error, non_event_frontier}
    end.

%% @private
%% The stability frontier: the largest local key K such that every local
%% key `=< K` is present (with the same value) in EVERY peer's confirmed
%% root.
%%
%% O(diff) and read-only. For each peer root it takes the read-only
%% structural diff of the live MST against that root (`diff_to_list/2` no
%% longer mutates the store — see `bondy_mst`), then walks the diff in key
%% order to the FIRST genuinely-divergent key. The structural diff is a
%% superset (a key that rides along in a changed leaf but is in fact
%% present-and-equal in the peer is a false-positive), so each candidate
%% is confirmed with an O(log N) `bondy_mst:get/3` against the peer root.
%% The global first hole is the smallest such key across peers; the
%% frontier is its predecessor in the local tree (`last_n/3`). With no
%% holes the whole local tree is confirmed and the frontier is the local
%% max key.
%%
%% This early-stops at the first divergence instead of folding every peer
%% into a full key set. It is equivalent to the previous O(N) set
%% longest-common-prefix: the instance MST uses the default term-order
%% comparator, and event keys (dots) carry a fixed value per key, so
%% presence and value agree.
compute_frontier_for(_MST, []) ->
    undefined;
compute_frontier_for(MST, PeerRoots) ->
    case [R || R <- PeerRoots, is_binary(R)] of
        [] ->
            undefined;
        [_ | _] = Roots ->
            case global_first_hole(MST, Roots) of
                no_hole ->
                    %% Every local key is confirmed by every peer.
                    case bondy_mst:last(MST) of
                        {K, _V} -> K;
                        undefined -> undefined
                    end;
                Hole ->
                    %% Largest local key strictly below the first hole.
                    case bondy_mst:last_n(MST, Hole, 1) of
                        [{K, _V}] -> K;
                        [] -> undefined
                    end
            end
    end.

%% @private
%% Validates the `retention` instance opt. Retention-bounded truncation is
%% sound only for an ephemeral projection-backed instance — the projection
%% materializes all applied state, so truncating the MST loses nothing
%% locally, and a peer that misses truncated history recovers via
%% catalogue bootstrap. `fused ⇒ ephemeral` is enforced upstream
%% (`bondy_db:assert_fused_requires_ephemeral/2`), so requiring `fused`
%% here transitively requires ephemeral without this module needing the
%% projection backend.
validate_retention(undefined, _Fused) ->
    undefined;
validate_retention(#{} = Policy, true) ->
    MaxAge = maps:get(max_age_ms, Policy, 0),
    MaxEvents = maps:get(max_events, Policy, 0),
    (is_integer(MaxAge) andalso MaxAge >= 0 andalso
        is_integer(MaxEvents) andalso MaxEvents >= 0) orelse
        error({badarg, {retention, Policy}}),
    case {MaxAge, MaxEvents} of
        {0, 0} -> undefined;
        _ -> #{max_age_ms => MaxAge, max_events => MaxEvents}
    end;
validate_retention(Policy, false) ->
    error({badarg, {mst_retention_requires_fused, Policy}}).

%% @private
%% The per-cycle retention context handed to `run_compaction/10`, or
%% `undefined` when retention does not apply this cycle. Snapshots
%% `live_size` and the wall clock at call time so the compaction body
%% stays free of clock/state reads. Wall time, NOT `bondy_oplog_hlc:peek/1`:
%% the HLC atomic only advances when events are generated, so on a quiet
%% instance `peek` is frozen at the last write and nothing would ever age
%% out. Event-key HLC physicals are epoch-ms (the same clock domain), so
%% wall-ms compares directly; an HLC that ran ahead of the wall (peer
%% absorption) only makes events look newer — the safe direction. Only a
%% fused instance WITH a projection is eligible: `fused` alone does not
%% imply a projection exists (a bare fused CRDT instance with no
%% `cell_apply_target` is constructible below `bondy_db`), and without one
%% the projection-holds-the-state safety argument does not hold.
retention_ctx(
    #state{retention = #{} = Policy, fused = true} = State, true
) ->
    Policy#{
        live_size => State#state.live_size,
        now_ms => erlang:system_time(millisecond)
    };
retention_ctx(#state{}, _HasProjection) ->
    undefined.

%% @private
%% The no-peer-confirmed-frontier fallback chain: retention first (when
%% configured and triggered), then the watermark catch-up. Both are
%% reached exclusively when the peer-confirmed path yielded nothing past
%% the watermark — a confirmed frontier is always preferred (every peer
%% already holds that prefix, so truncating it costs nobody a bootstrap).
retention_or_catchup(InstanceId, MST, Watermark0, HasProjection, Retention) ->
    case retention_frontier(MST, Watermark0, Retention) of
        undefined ->
            maybe_watermark_catchup(MST, Watermark0, HasProjection);
        {Kind, Frontier} ->
            telemetry:execute(
                [bondy_oplog, compaction, retention],
                #{count => 1},
                #{instance_id => InstanceId, kind => Kind}
            ),
            {ok, {catalogue_compacted, Frontier}}
    end.

%% @private
%% The LOCAL retention frontier for an ephemeral catalogue instance, or
%% `undefined` when the policy is absent or not yet breached.
%%
%% - `max_events` breach (checked first — one integer compare): frontier =
%%   the MST's own max key, i.e. truncate the whole applied tree. Peers
%%   within one AE round are unaffected (they hold their own copies);
%%   laggards take the rebootstrap path.
%% - `max_age_ms` breach: frontier = the largest REAL key strictly below
%%   the age cutoff. Event keys are `#bondy_oplog_event_key{hlc, origin,
%%   seq}` records ordered by HLC first, so a synthetic bound
%%   `key(CutoffHlc, <<>>, 0)` sorts at-or-before every real key with
%%   HLC >= cutoff, and `bondy_mst:last_n(MST, Bound, 1)` returns exactly
%%   the newest key older than the cutoff (the same bound technique
%%   `compute_frontier_for/2` uses for the first hole).
%%
%% Every returned frontier is a REAL key from the tree (the commit path
%% calls `bondy_oplog_event:key_hlc/1` on it) and strictly above
%% `Watermark0` (at-or-below means the tree holds only already-compacted
%% keys — that is `maybe_watermark_catchup/3`'s case, not ours).
retention_frontier(_MST, _Watermark0, undefined) ->
    undefined;
retention_frontier(MST, Watermark0, #{} = Ctx) ->
    #{
        max_age_ms := MaxAge,
        max_events := MaxEvents,
        live_size := LiveSize,
        now_ms := NowMs
    } = Ctx,
    SizeBreached = MaxEvents > 0 andalso LiveSize > MaxEvents,
    case SizeBreached of
        true ->
            case bondy_mst:last(MST) of
                {K, _V} -> above_watermark(size, K, Watermark0);
                undefined -> undefined
            end;
        false ->
            retention_age_frontier(MST, Watermark0, MaxAge, NowMs)
    end.

%% @private
retention_age_frontier(_MST, _Watermark0, 0, _NowMs) ->
    undefined;
retention_age_frontier(MST, Watermark0, MaxAge, NowMs) ->
    CutoffPhys = NowMs - MaxAge,
    case CutoffPhys > 0 andalso bondy_mst:first(MST) of
        {OldestKey, _V} ->
            {OldestPhys, _} = bondy_oplog_hlc:decode(
                bondy_oplog_event:key_hlc(OldestKey)
            ),
            case OldestPhys < CutoffPhys of
                true ->
                    Bound = bondy_oplog_event:key(
                        bondy_oplog_hlc:encode(CutoffPhys, 0), <<>>, 0
                    ),
                    case bondy_mst:last_n(MST, Bound, 1) of
                        [{K, _}] -> above_watermark(age, K, Watermark0);
                        [] -> undefined
                    end;
                false ->
                    undefined
            end;
        _ ->
            %% Empty tree, or the cutoff predates the epoch (a clock that
            %% has barely started) — nothing to age out.
            undefined
    end.

%% @private
above_watermark(_Kind, K, Watermark) when
    Watermark =/= undefined, K =< Watermark
->
    undefined;
above_watermark(Kind, K, _Watermark) ->
    {Kind, K}.

%% @private
%% Smallest local key absent-or-different in some peer root, or `no_hole`
%% when the local tree is fully confirmed by every peer.
global_first_hole(MST, Roots) ->
    lists:foldl(
        fun(R, Acc) ->
            case peer_first_hole(MST, R) of
                no_hole -> Acc;
                H -> min_hole(H, Acc)
            end
        end,
        no_hole,
        Roots
    ).

%% @private
%% Term-order min; the instance MST's default comparator is `<`.
min_hole(H, no_hole) -> H;
min_hole(H, Acc) when H < Acc -> H;
min_hole(_H, Acc) -> Acc.

%% @private
%% First (smallest) local key genuinely divergent from peer root `R`,
%% walking the read-only structural diff (ascending key order) and
%% skipping present-and-equal false-positives. `no_hole` when local is a
%% subset of the peer (diff empty or all false-positives).
peer_first_hole(MST, R) ->
    try
        first_genuine_hole(MST, R, bondy_mst:diff_to_list(MST, R))
    catch
        _:_ ->
            %% The recorded peer root references pages this store has
            %% already reclaimed (post-truncation page GC on the
            %% ephemeral backend). We cannot certify what that peer
            %% holds, so certify nothing: a hole at the first local key
            %% defers compaction for this peer until its root refreshes
            %% on the next sync round (seconds). Never raises out of the
            %% synchronous compaction handler.
            case bondy_mst:first(MST) of
                {K, _V} -> K;
                undefined -> no_hole
            end
    end.

%% @private
first_genuine_hole(_MST, _R, []) ->
    no_hole;
first_genuine_hole(MST, R, [{K, V} | Rest]) ->
    case bondy_mst:get(MST, K, R) of
        V ->
            %% Structural false-positive: present and equal in the peer.
            first_genuine_hole(MST, R, Rest);
        _ ->
            %% Absent (`undefined`) or a different value: a genuine hole.
            K
    end.

%% @private
%% Returns the memoised projection-presence, resolving it ONCE from the
%% applier and caching the first DEFINITIVE answer. Caching only a
%% `true | false` (never the transient `unknown` from an applier that has
%% not registered yet) keeps a momentary startup race from pinning a wrong
%% `false`. Once cached, no `gen_server:call` to the applier is ever made
%% again — which is what keeps the synchronous compaction handler free of
%% the instance↔applier deadlock (see the `has_projection` state field).
resolve_has_projection(#state{has_projection = HP} = State) ->
    {HP, State}.

%% @private
%% Keeps only the pairs whose event key originated at a DIFFERENT replica.
%% Local-origin events are already materialised in the projection (the
%% applier writes them before their MST install), so the async catch-up
%% (`begin_async_catch_up/3`) folds only the remote ones.
remote_pairs(Pairs, Origin) ->
    [
        P
     || {K, _V} = P <- Pairs,
        not bondy_oplog_event:is_key(K) orelse
            bondy_oplog_event:key_origin(K) =/= Origin
    ].

%% @private
%% Re-anchors the applier's replay cursor (`last_replayed_root`) on the
%% post-truncate root so the next catch-up diff stays incremental. No-op
%% when there is no applier (a bare instance without a projection).
advance_projection_watermark(InstanceId, NewRoot) ->
    case bondy_oplog_registry:applier_pid(InstanceId) of
        undefined ->
            ok;
        ApplierPid ->
            bondy_oplog_applier:advance_replayed_root(ApplierPid, NewRoot)
    end.

%% @private
%% Counts events in the open range (Watermark0, Frontier] over the
%% captured MST without materialising the event records. Used by the
%% catalogue truncate-only path for `live_size` bookkeeping (the
%% monolithic path counts via `length(events_in_open_range/3)` because
%% it already builds the list for `interpret_cog`).
count_in_open_range(MST, undefined, Frontier) ->
    bondy_mst:fold(
        MST,
        fun
            ({K, _V}, N) when K =< Frontier -> N + 1;
            (_, N) -> N
        end,
        0
    );
count_in_open_range(MST, W0, Frontier) ->
    bondy_mst:fold(
        MST,
        fun
            ({K, _V}, N) when K > W0, K =< Frontier -> N + 1;
            (_, N) -> N
        end,
        0
    ).

%% @private
%% Commits the compaction result atomically inside the gen_server, and
%% returns `{Reply, NewState}` to the synchronous `compact` handler.
%% Truncation uses the *current* state.mst.
commit_compaction(State, Started, {ok, no_change}) ->
    emit_compaction_telemetry(State, Started, undefined, 0),
    {{ok, no_change}, State};
commit_compaction(
    State,
    Started,
    {ok, {catalogue_compacted, Frontier}}
) ->
    %% Reached only when there is nothing remote to fold first — either
    %% `remote_events_pending = false`, or the async catch-up
    %% (`begin_async_catch_up/3`) already folded the at-risk remote pairs
    %% via the applier and we are now in step 2. The pre-truncate projection
    %% fold (the cross-node-deadlock-prone synchronous catch-up that used to
    %% live here) has moved OUT to the two-step `begin_async_catch_up/3` /
    %% `handle_cast({catch_up_done, _})`. So this only bounds the MST.
    finalize_catalogue_compaction(State, Started, Frontier);
commit_compaction(
    State,
    Started,
    {ok, {compacted, Frontier, NewCheckpoint, EventCount}}
) ->
    MST1 = truncate_below_or_equal(
        State#state.mst, Frontier, State#state.backend, pinned_roots(State)
    ),
    %% Persist the truncated root so the durable MST root tracks the
    %% checkpoint (which `do_compact_sync/2` already wrote). For this
    %% bare-CRDT path the checkpoint carries the full materialised state, so
    %% a best-effort flush is sufficient — but keeping the durable root in
    %% step avoids the durable checkpoint outrunning the durable root (see
    %% `finalize_catalogue_compaction/3` for the projection-backed path).
    StateF = flush_mst_root(State#state{mst = MST1}),
    _ = bondy_oplog_hlc:update(
        StateF#state.hlc, bondy_oplog_event:key_hlc(Frontier)
    ),
    State1 = StateF#state{
        watermark = Frontier,
        cached_checkpoint = {Frontier, NewCheckpoint},
        live_size = max(0, StateF#state.live_size - EventCount)
    },
    emit_compaction_telemetry(StateF, Started, Frontier, EventCount),
    {{ok, {compacted, Frontier, EventCount}}, State1};
commit_compaction(State, _Started, {error, _} = Error) ->
    {Error, State}.

%% @private
%% Step 1 of the async catalogue catch-up (the cross-node deadlock fix).
%% Extracts the remote-origin events in the about-to-be-truncated range
%% `(watermark, frontier]` straight from the MST — the instance owns its
%% sealed-pack fds, so this read is safe here and ONLY here — then hands
%% them to the applier via `catch_up_apply/3` (a CAST) and DEFERS the
%% truncate to `handle_cast({catch_up_done, _})`. The instance never blocks
%% on the applier, so the applier's own synchronous `drain_install_queue`
%% call (`commit_now/1`) can no longer wedge it (the deadlock).
%%
%% Local events in the range are already in the projection (the applier
%% writes them before their MST install), so only remote ones need folding
%% — `remote_pairs/2` keeps just those. An empty remote set (the common
%% case: the async `replay_cell_events` path already folded them) skips the
%% round-trip and finalizes inline.
begin_async_catch_up(State, Started, Frontier) ->
    RemotePairs = remote_pairs(
        pairs_in_open_range(State#state.mst, State#state.watermark, Frontier),
        State#state.origin
    ),
    case RemotePairs of
        [] ->
            {Reply, State1} = finalize_catalogue_compaction(
                State, Started, Frontier
            ),
            ok = publish(State1),
            {reply, Reply, State1};
        _ ->
            case bondy_oplog_registry:applier_pid(State#state.instance_id) of
                undefined ->
                    %% No applier to fold the remote pairs — defer; the next
                    %% tick retries once the applier is back.
                    {reply, {ok, no_change}, State};
                ApplierPid ->
                    Token = State#state.compaction_token + 1,
                    ok = bondy_oplog_applier:catch_up_apply(
                        ApplierPid, RemotePairs, Token
                    ),
                    Pending = #pending_compaction{
                        frontier = Frontier,
                        remote_gen = State#state.remote_gen,
                        token = Token,
                        started = Started
                    },
                    %% Watchdog: a lost `{catch_up_done, _}` (applier crash
                    %% mid-fold) would otherwise wedge compaction for this
                    %% instance. On timeout we clear the pending record and
                    %% retry next tick (no truncate happened → nothing lost).
                    _ = erlang:send_after(
                        ?CATCH_UP_TIMEOUT_MS,
                        self(),
                        {compaction_catch_up_timeout, Token}
                    ),
                    {reply, {ok, compaction_pending}, State#state{
                        pending_compaction = Pending,
                        compaction_token = Token
                    }}
            end
    end.

%% @private
%% The MST-bounding tail of a catalogue compaction: persist the watermark
%% checkpoint, truncate the stable prefix, re-anchor the applier's replay
%% cursor (a CAST — never blocks on the applier), recompute `live_size`,
%% and clear the catch-up bookkeeping. Reached once the projection is known
%% current up to `Frontier` (nothing remote to fold, or the async catch-up
%% already folded it). Makes NO synchronous applier call, so it is
%% deadlock-free.
%%
%% The checkpoint envelope records the watermark; its state slot carries the
%% `{projection_managed, frontier, FrontierVV}` payload — "the materialised
%% state is the projection" plus the applied-frontier convergence oracle — which
%% on restart seeds the frontier holder but is never fed to `interpret_cog` (the
%% projection is the authoritative read source).
%% Verified by
%% `bondy_oplog_catalogue_compaction_test:crdt_kernel_compaction_matches_from_scratch`.
finalize_catalogue_compaction(State0, Started, Frontier) ->
    %% Index flush barrier. Drive the secondary indexes durably to
    %% >= Frontier BEFORE the MST tail is truncated. Every index op for an
    %% event <= Frontier has already been DISPATCHED to the secondary writers
    %% (local events at apply time; remote events by the async catch-up that
    %% runs before this finalize). Those ops live in the writers' buffers,
    %% independent of the MST — but a crash AFTER the truncate and BEFORE a
    %% writer flushes would lose them (their source events are gone from the
    %% MST). So flush every target index writer here first: the durable index
    %% then holds everything <= Frontier (= the new snapshot watermark) by
    %% construction, keeping cold-start a trust + bounded tail-replay, never
    %% an O(table) re-derive.
    %%
    %% Deadlock-free: this is an instance->writer call and the writer's flush
    %% never calls back into the instance or applier (one-directional edge —
    %% contrast the instance<->applier cycle that forced the async catch-up).
    %% A wedged/dead writer is caught and its shard marked for rebuild (the
    %% rebuild backstop) so truncation still proceeds.
    %%
    %% NOTE: this covers the common case where the ops were dispatched. The
    %% saturation/drop case (index ops never dispatched) still relies on the
    %% writer-crash/drop `needs_rebuild` + background rebuild from the
    %% (un-truncated) projection; re-deriving the dropped window here needs
    %% the applier and therefore the async path.
    State = drive_secondary_indexes(State0),
    {MST1, TruncateUs} = tc(fun() ->
        truncate_below_or_equal(
            State#state.mst,
            Frontier,
            State#state.backend,
            pinned_roots(State)
        )
    end),
    %% Persist the truncated MST root BEFORE advancing the durable
    %% checkpoint. The reboot resume position is
    %% `max(durable_root_last.hlc, durable_checkpoint.hlc)`
    %% (`bondy_oplog_applier:resume_position/2`), so the durable checkpoint
    %% must never outrun the durable root — otherwise a crash between the
    %% checkpoint write and the next commit-barrier flush resumes PAST
    %% events on reboot, corrupting the shard. Flushing here (pages-then-
    %% root, enforced inside the writer) keeps the two in lockstep. A flush
    %% failure ABORTS the compaction: we leave the original (un-truncated)
    %% state untouched and retry next cycle rather than advance the
    %% checkpoint past a non-durable root.
    {FlushRes, FlushUs} = tc(fun() ->
        flush_mst_root_checked(State#state{mst = MST1})
    end),
    case FlushRes of
        {ok, StateF} ->
            finalize_catalogue_compaction_commit(
                StateF, State, Started, Frontier, TruncateUs, FlushUs
            );
        {error, Reason} ->
            %% Discard the truncation entirely and retry next cycle.
            %%
            %% DO NOT "fix" this to carry `MST1` forward on the belief that the
            %% pre-truncate root is now dangling. It is not, and the reasoning
            %% is worth spelling out because it is easy to get backwards:
            %%
            %%   - This branch is reachable ONLY on the pack backend.
            %%     `bondy_mst_ets_store:flush/1` returns `{ok, _}`
            %%     unconditionally, so an ephemeral instance never lands here.
            %%   - On the pack backend `truncate_below_or_equal/4` takes the
            %%     non-`ets` clause, which truncates WITHOUT collecting. So
            %%     nothing was reclaimed.
            %%   - `bondy_mst:truncate/2` does `free/3` the spine pages it
            %%     rewrote, but `bondy_mst_pack_store:free/3` only adds the
            %%     hash to the `free_set`, and that set is explicitly NOT a
            %%     read mask (see `get/2` there — masking reads was removed
            %%     precisely because it reported live pages as dangling).
            %%
            %% So `State0`'s root is still fully readable and reverting to it
            %% is sound. Carrying the truncated tree forward instead would be
            %% the actual bug: it drops events the durable checkpoint does not
            %% cover, on the one path where we already know durability failed.
            ?LOG_ERROR(#{
                description =>
                    "Aborting compaction: durable MST root flush failed; "
                    "checkpoint NOT advanced to avoid outrunning the root",
                instance_id => State#state.instance_id,
                frontier => Frontier,
                reason => Reason
            }),
            {{error, {compaction_flush_failed, Reason}}, State0}
    end.

%% @private
%% Tail of `finalize_catalogue_compaction/3`, reached once the truncated
%% root is durable. `StateF` carries the flushed MST handle; `State` is the
%% pre-truncate state (for the live-size delta and telemetry baseline).
finalize_catalogue_compaction_commit(
    StateF, State, Started, Frontier, TruncateUs, FlushUs
) ->
    MST1 = StateF#state.mst,
    %% Persist the applied-frontier convergence oracle alongside the checkpoint.
    %% REQUIRED here: this truncates the WAL below `Frontier` (the compaction
    %% watermark), so an origin whose events are all below it could no longer be
    %% reconstructed from a WAL-tail replay — its maxima must ride in the
    %% checkpoint. `Frontier` is the event-key watermark; `FrontierVV` is the
    %% per-origin version vector, read lock-free from the registry holder.
    FrontierVV = bondy_oplog_registry:frontier(StateF#state.instance_id),
    Checkpoint = {projection_managed, frontier, FrontierVV},
    {ok, CkptUs} = tc(fun() ->
        (StateF#state.compaction_checkpoint):put_checkpoint(
            StateF#state.compaction_checkpoint_state,
            Frontier,
            Checkpoint
        )
    end),
    NewRoot = bondy_mst:root(MST1),
    %% Re-anchor the projection replay cursor on the post-truncate (live)
    %% root so the next replay diff stays incremental (the pre-truncate
    %% root's pages are freed by the truncate, so a stale cursor would force
    %% a full `to_list/1` fold every cycle). Non-fused: a cast to the
    %% applier. Fused: no applier — the cursor lives in `#fused_drain{}` and
    %% is re-anchored in `State1` below (`fused_reanchor_cursor/2`).
    {ok, WatermarkUs} = tc(fun() ->
        case StateF#state.fused of
            true ->
                ok;
            false ->
                advance_projection_watermark(StateF#state.instance_id, NewRoot)
        end
    end),
    %% Derive the removed-event count from the live-size delta over the
    %% *truncated* tree (O(remaining)) rather than folding the whole
    %% pre-truncate tree (O(N)); bounded when compaction keeps up.
    {LiveSize1, LiveSizeUs} = tc(fun() -> compute_live_size(MST1) end),
    EventCount = max(0, State#state.live_size - LiveSize1),
    maybe_trace_compaction(
        StateF#state.instance_id,
        Started,
        EventCount,
        LiveSize1,
        #{
            checkpoint_us => CkptUs,
            truncate_us => TruncateUs,
            flush_us => FlushUs,
            watermark_us => WatermarkUs,
            live_size_us => LiveSizeUs
        }
    ),
    _ = bondy_oplog_hlc:update(
        StateF#state.hlc, bondy_oplog_event:key_hlc(Frontier)
    ),
    State1 = StateF#state{
        mst = MST1,
        watermark = Frontier,
        cached_checkpoint = {Frontier, Checkpoint},
        live_size = LiveSize1,
        remote_events_pending = false,
        pending_compaction = undefined,
        fused_drain = fused_reanchor_cursor(StateF#state.fused_drain, NewRoot)
    },
    emit_compaction_telemetry(StateF, Started, Frontier, EventCount),
    {{ok, {compacted, Frontier, EventCount}}, State1}.

%% @private
%% Re-anchors the fused replay cursor on the post-truncate root. No-op for a
%% non-fused instance (`fused_drain = undefined`).
fused_reanchor_cursor(undefined, _NewRoot) ->
    undefined;
fused_reanchor_cursor(#fused_drain{} = FD, NewRoot) ->
    FD#fused_drain{last_replayed_root = NewRoot}.

%% @private
%% Compaction flush barrier. flush_sync every **durable** secondary-
%% index writer of this instance's `bondy_db` table so dispatched index ops are
%% durable before the MST tail is truncated. Returns State with the NS memoised
%% (see `resolve_secondary_index_ns/1`). A no-op for an instance with no
%% projection or no `bondy_db` registry entry (a bare-oplog instance). A table
%% with only EPHEMERAL (ETS) indexes does the cheap per-compaction filter in
%% `flush_secondary_index_writers/1` and issues NO flush round-trips: an
%% ephemeral index needs no flush (a crash drops the in-RAM MST and index
%% together; it reconverges from peers).
drive_secondary_indexes(#state{has_projection = false} = State) ->
    State;
drive_secondary_indexes(State0) ->
    case resolve_secondary_index_ns(State0) of
        {none, State} ->
            State;
        {NS, State} ->
            ok = flush_secondary_index_writers(NS),
            State
    end.

%% @private
%% Resolve (once, then cache) the `bondy_db` namespace whose primary shard
%% carries THIS `instance_id`. The NS is STABLE from instance start — the
%% primary registry entry is registered before the instance is started
%% (`bondy_db:provision_shard/11`), so by the time any compaction runs it is
%% present — hence safe to cache. `none` (also stable, also cached) means no
%% primary entry matches: a bare-oplog instance, never a `bondy_db` table.
%%
%% We DELIBERATELY do NOT also cache "has durable index shards" here. Index
%% shards register AFTER the primary (and this instance) come up, so a
%% compaction racing that window would otherwise latch a permanent "nothing to
%% flush" and silently stop protecting the index. Whether there is durable work
%% is therefore re-evaluated cheaply on every compaction in
%% `flush_secondary_index_writers/1` (one `shards_for/1` select + filter), which
%% self-heals the instant the index shards appear. Deadlock-free (read-only ETS;
%% never an applier call).
resolve_secondary_index_ns(#state{secondary_index_ns = unresolved} = State) ->
    NS = lookup_ns_for_instance(State#state.instance_id),
    {NS, State#state{secondary_index_ns = NS}};
resolve_secondary_index_ns(#state{secondary_index_ns = NS} = State) ->
    {NS, State}.

%% @private
%% Scan the registry for the namespace whose primary shard carries
%% `InstanceId`. Only primary-shard entries record an `instance_id`
%% (secondaries leave it `undefined`), so a match uniquely identifies the
%% owning table. `none` when no entry matches (a bare-oplog instance).
lookup_ns_for_instance(InstanceId) ->
    find_ns(bondy_oplog_core_registry:namespaces(), InstanceId).

%% @private
find_ns([], _InstanceId) ->
    none;
find_ns([NS | Rest], InstanceId) ->
    Owns = lists:any(
        fun(E) ->
            bondy_oplog_core_registry:entry_instance_id(E) =:= InstanceId
        end,
        bondy_oplog_core_registry:shards_for(NS)
    ),
    case Owns of
        true -> NS;
        false -> find_ns(Rest, InstanceId)
    end.

%% @private
%% A secondary-index shard whose projection is durable (anything other than
%% the in-RAM ETS adapter — the only ephemeral projection, in this app).
%% Primaries and ETS-backed indexes return `false`: a primary has nothing to
%% flush here, and an ETS index has no durability to protect.
is_durable_index_shard(E) ->
    case bondy_oplog_core_registry:entry_key(E) of
        {_NS, ?PRIMARY_INDEX, _Shard} ->
            false;
        {_NS, _IndexName, _Shard} ->
            bondy_oplog_core_registry:entry_projection_adapter(E) =/=
                bondy_oplog_projection_ets
    end.

%% @private
%% flush_sync every DURABLE secondary-index writer registered under `NS`. A
%% writer that cannot flush in `?IDX_FLUSH_TIMEOUT_MS` (dead/wedged) is skipped
%% and its shard marked for rebuild (the rebuild backstop) so truncation still
%% proceeds and the shard is recovered in the background from the
%% (un-truncated) projection.
flush_secondary_index_writers(NS) ->
    lists:foreach(
        fun(E) ->
            case is_durable_index_shard(E) of
                true -> flush_or_backstop(E);
                false -> ok
            end
        end,
        bondy_oplog_core_registry:shards_for(NS)
    ).

%% @private
flush_or_backstop(Entry) ->
    case bondy_oplog_core_registry:entry_writer_pid(Entry) of
        Pid when is_pid(Pid) ->
            try
                ok = bondy_oplog_secondary_writer:flush_sync(
                    Pid, ?IDX_FLUSH_TIMEOUT_MS
                )
            catch
                Class:Reason ->
                    ?LOG_WARNING(#{
                        description =>
                            "bondy_oplog_instance compaction flush barrier "
                            "could not flush a secondary-index writer; "
                            "marking the shard for rebuild and proceeding "
                            "with the truncate.",
                        entry_key => bondy_oplog_core_registry:entry_key(Entry),
                        class => Class,
                        reason => Reason
                    }),
                    backstop_index_rebuild(Entry)
            end;
        _ ->
            %% No live writer (restarting): its buffered ops are gone with
            %% it, so mark for rebuild rather than silently dropping them.
            backstop_index_rebuild(Entry)
    end.

%% @private
backstop_index_rebuild(Entry) ->
    bondy_oplog_core_registry:index_mark_rebuild(Entry),
    {NS, IndexName, _Shard} = bondy_oplog_core_registry:entry_key(Entry),
    bondy_oplog_index_rebuild:request(NS, IndexName).

%% @private
%% The raw `{Key, Value}` MST pairs whose key falls in the
%% about-to-be-truncated range `(W0, Frontier]` (`undefined` W0 = from the
%% start). Mirrors `events_in_open_range/3` but yields the
%% projection-apply pairs (no `event_from_value/2` wrapping) that the
%% applier's `apply_cell_pairs/4` consumes. Folds the (bounded) live tree;
%% it reaches sealed pages, so it must run in the instance that owns their
%% fds — never off-process.
pairs_in_open_range(MST, undefined, Frontier) ->
    lists:reverse(
        bondy_mst:fold(
            MST,
            fun
                ({K, _V} = P, Acc) when K =< Frontier -> [P | Acc];
                (_, Acc) -> Acc
            end,
            []
        )
    );
pairs_in_open_range(MST, W0, Frontier) ->
    lists:reverse(
        bondy_mst:fold(
            MST,
            fun
                ({K, _V} = P, Acc) when K > W0, K =< Frontier -> [P | Acc];
                (_, Acc) -> Acc
            end,
            []
        )
    ).

%% @private
%% Times `Fun`, returning `{Result, Microseconds}`. Diagnostic helper for
%% the per-cycle compaction sub-stage trace.
tc(Fun) ->
    T0 = erlang:monotonic_time(),
    R = Fun(),
    {R,
        erlang:convert_time_unit(
            erlang:monotonic_time() - T0, native, microsecond
        )}.

%% @private
%% Gated per-cycle compaction sub-stage trace. Prints the wall-time split
%% (frontier derived as total − measured sub-stages) directly to the node's
%% stdout so a Fly bench run captures which sub-step dominates the
%% synchronous cycle, without bench-side telemetry plumbing. Off unless the
%% `COMPACTION_TRACE` env var is set (the diagnostic recipe sets it).
maybe_trace_compaction(InstanceId, Started, EventCount, LiveSize, Stages) ->
    case os:getenv("COMPACTION_TRACE") of
        false ->
            ok;
        _ ->
            TotalUs = erlang:convert_time_unit(
                erlang:monotonic_time() - Started, native, microsecond
            ),
            #{
                checkpoint_us := CkptUs,
                truncate_us := TruncateUs,
                watermark_us := WatermarkUs,
                live_size_us := LiveSizeUs
            } = Stages,
            FrontierUs = max(
                0, TotalUs - CkptUs - TruncateUs - WatermarkUs - LiveSizeUs
            ),
            io:format(
                "[compaction-trace ~s] removed=~p live=~p total=~pus "
                "frontier=~pus ckpt=~pus truncate=~pus watermark=~pus "
                "live_size=~pus~n",
                [
                    InstanceId,
                    EventCount,
                    LiveSize,
                    TotalUs,
                    FrontierUs,
                    CkptUs,
                    TruncateUs,
                    WatermarkUs,
                    LiveSizeUs
                ]
            )
    end.

%% @private
emit_compaction_telemetry(State, Started, Frontier, EventCount) ->
    Duration = erlang:monotonic_time() - Started,
    telemetry:execute(
        [bondy_oplog, compaction, ok],
        #{
            duration => Duration,
            duration_us => erlang:convert_time_unit(
                Duration, native, microsecond
            ),
            event_count => EventCount
        },
        #{instance_id => State#state.instance_id, frontier => Frontier}
    ).

%% @private
%% Bootstrap: install a peer-supplied snapshot at the given watermark.
%% See `load_snapshot/3` for the contract.
%%
%% Compaction is fully synchronous in this gen_server, so a `load_snapshot`
%% call can never interleave with a compaction cycle — they serialise
%% naturally as separate messages.
do_load_snapshot(State, NewWatermark, Snapshot) ->
    case State#state.watermark of
        undefined ->
            apply_loaded_snapshot(State, NewWatermark, Snapshot);
        Current when NewWatermark > Current ->
            apply_loaded_snapshot(State, NewWatermark, Snapshot);
        _ ->
            {reply, {error, watermark_not_advancing}, State}
    end.

%% @private
apply_loaded_snapshot(State, NewWatermark, Snapshot) ->
    ok = (State#state.compaction_checkpoint):put_checkpoint(
        State#state.compaction_checkpoint_state, NewWatermark, Snapshot
    ),
    %% Drop any live events that the new checkpoint already covers.
    MST1 = truncate_below_or_equal(
        State#state.mst,
        NewWatermark,
        State#state.backend,
        pinned_roots(State)
    ),
    LiveSize1 = compute_live_size(MST1),
    %% Advance HLC to keep future local appends above the watermark.
    _ = bondy_oplog_hlc:update(
        State#state.hlc, bondy_oplog_event:key_hlc(NewWatermark)
    ),
    State1 = State#state{
        mst = MST1,
        watermark = NewWatermark,
        cached_checkpoint = {NewWatermark, Snapshot},
        live_size = LiveSize1
    },
    {reply, {ok, NewWatermark}, State1}.

%% @private
%% Returns events in the half-open range (Watermark0, Frontier], in
%% key order. If Watermark0 is `undefined`, the range starts at
%% min_key (inclusive of all events ≤ Frontier).
events_in_open_range(MST, undefined, Frontier) ->
    lists:reverse(
        bondy_mst:fold(
            MST,
            fun
                ({K, V}, Acc) when K =< Frontier ->
                    [event_from_value(K, V) | Acc];
                (_, Acc) ->
                    Acc
            end,
            []
        )
    );
events_in_open_range(MST, W0, Frontier) ->
    lists:reverse(
        bondy_mst:fold(
            MST,
            fun
                ({K, V}, Acc) when K > W0, K =< Frontier ->
                    [event_from_value(K, V) | Acc];
                (_, Acc) ->
                    Acc
            end,
            []
        )
    ).

%% @private
%% Builds the underlying MST struct.
open_mst(InstanceId, Backend, Opts) ->
    StoreMod = backend_module(Backend),
    StoreOpts = backend_opts(Backend, InstanceId, Opts),
    HashAlgo = maps:get(hash_algorithm, Opts, sha256),
    bondy_mst:new(#{
        store => StoreMod,
        store_opts => StoreOpts,
        hash_algorithm => HashAlgo,
        merger => fun merge_page_value/3
    }).

%% @private
%% Default MST page-merge collision resolver.
%%
%% Event keys are globally unique by construction (`{HLC, Origin, Seq}`),
%% so the only legitimate caller is an idempotent peer re-receive, where
%% the two values must be equal. A divergent merge for the same key is a
%% system-invariant violation and is surfaced loudly rather than silently
%% absorbed. CRDT-valued tables converge via their configured `fold_module`,
%% not through this hook.
merge_page_value(_Key, V, V) ->
    V;
merge_page_value(Key, V1, V2) ->
    ?LOG_ERROR(#{
        description =>
            "MST merger invoked with divergent values; "
            "system invariant violated",
        key => Key,
        v1 => V1,
        v2 => V2
    }),
    erlang:error({divergent_value, Key, V1, V2}).

%% @private
backend_module(map) -> bondy_mst_map_store;
backend_module(ets) -> bondy_mst_ets_store;
backend_module(Mod) when is_atom(Mod) -> Mod.

%% @private
backend_opts(ets, InstanceId, Opts) ->
    Defaults = #{name => InstanceId},
    maps:merge(Defaults, maps:get(backend_options, Opts, #{}));
backend_opts(bondy_mst_pack_store, InstanceId, Opts) ->
    %% The pack-store backend wants `dir` (instance directory) and
    %% `instance_id` in its open opts. Mirror the ETS pattern: derive
    %% the per-instance dir from `storage_path` via the same path
    %% strategy that other persistent backends use, then inject the
    %% required keys as defaults that `backend_options` may override.
    Base = maps:get(backend_options, Opts, #{}),
    %% Default the seal threshold low enough that `seal_incoming` rewrites
    %% `incoming.pack` in short (~tens of ms) passes rather than one ~600ms+
    %% datasync that freezes the apply pipeline and spikes read-after-write
    %% freshness lag toward the auth fence `max_lag`. Reads are unaffected
    %% (they serve from the projection + cache, not the MST). A caller's
    %% explicit `backend_options.auto_seal_bytes` always wins (Base merges last).
    Defaults0 = #{
        instance_id => InstanceId,
        auto_seal_bytes => bondy_oplog_config:pack_auto_seal_bytes(),
        %% Seal off the apply critical path by default (see
        %% `bondy_oplog_config:pack_seal_mode/0`). `drive_seal_enabled/2`
        %% MUST resolve the SAME effective mode, or an async store whose put
        %% never seals would grow `incoming.pack` unbounded with nobody
        %% driving the roll — hence both default through the same config.
        seal_mode => bondy_oplog_config:pack_seal_mode()
    },
    Defaults =
        case maps:find(storage_path, Opts) of
            {ok, BaseDir} ->
                Path = bondy_oplog_path:instance_dir(
                    InstanceId, BaseDir, Opts
                ),
                Defaults0#{dir => unicode:characters_to_binary(Path)};
            error ->
                Defaults0
        end,
    maps:merge(Defaults, Base);
backend_opts(_, InstanceId, Opts) ->
    Base = maps:get(backend_options, Opts, #{}),
    case maps:find(storage_path, Opts) of
        {ok, BaseDir} ->
            Path = bondy_oplog_path:instance_dir(InstanceId, BaseDir, Opts),
            Base#{storage_path => unicode:characters_to_binary(Path)};
        error ->
            Base
    end.

%% @private
%% True iff the instance should drive the asynchronous seal off the commit
%% barrier (`maybe_drive_seal/1`) rather than letting the store seal inline on
%% `put`. Two conditions, both required:
%%   1. the backend advertises the `async_seal` capability (a roll/run/complete
%%      seal flow exists) — checked via `bondy_mst:capabilities/1`, so no
%%      backend MODULE name is hardcoded here and a new sealing backend works
%%      unchanged. Memory backends advertise `async_seal => false`.
%%   2. it was opened in `seal_mode => async`.
%% The `seal_mode` default MUST match `backend_opts/3`'s injected default
%% (`bondy_oplog_config:pack_seal_mode/0`) so the store-open mode and the drive
%% decision never disagree.
drive_seal_enabled(MST, Opts) ->
    maps:get(async_seal, bondy_mst:capabilities(MST), false) andalso
        seal_mode_async(Opts).

%% @private
seal_mode_async(Opts) ->
    BackendOptions = maps:get(backend_options, Opts, #{}),
    Default = bondy_oplog_config:pack_seal_mode(),
    is_map(BackendOptions) andalso
        maps:get(seal_mode, BackendOptions, Default) =:= async.

%% @private
%% Resolve the compaction-checkpoint backend module + opts.
%%
%% Precedence:
%%   1. Explicit `compaction_checkpoint` in Opts wins; checkpoint opts
%%      are passed through unchanged.
%%   2. Otherwise, if a `path` is set in `compaction_checkpoint_opts`
%%      OR `storage_path` is set on the instance, default to the file
%%      backend, deriving `path` from `storage_path` (via the configured
%%      `path_layout`) when not explicit.
%%   3. Otherwise default to the in-memory ETS backend (ephemeral).
%%
%% Path derivation when deriving from `storage_path`: the path layout
%% returns the per-instance dir (terminates in `<InstanceId>`); the
%% file backend then appends `<InstanceId>` again.
%% Pass the parent (the shard dir) so the final file lands at
%% `<storage_path>/<shard>/<InstanceId>/checkpoint.etf` alongside the
%% other per-instance artefacts (WAL, MST, projection).
resolve_checkpoint_backend(InstanceId, Opts, CkptOpts) ->
    case maps:find(compaction_checkpoint, Opts) of
        {ok, Mod} ->
            {Mod, CkptOpts};
        error ->
            case maps:is_key(path, CkptOpts) of
                true ->
                    {bondy_oplog_compaction_checkpoint_file, CkptOpts};
                false ->
                    case maps:find(storage_path, Opts) of
                        {ok, BaseDir} ->
                            InstanceDir = bondy_oplog_path:instance_dir(
                                InstanceId, BaseDir, Opts
                            ),
                            ShardDir = filename:dirname(InstanceDir),
                            {
                                bondy_oplog_compaction_checkpoint_file,
                                CkptOpts#{
                                    path => unicode:characters_to_binary(
                                        ShardDir
                                    )
                                }
                            };
                        error ->
                            {
                                bondy_oplog_compaction_checkpoint_ets,
                                CkptOpts
                            }
                    end
            end
    end.

%% @private
%% Publishes the current state's read-relevant fields to the registry.
%% Called after every state-mutating handle_call so that lock-free
%% read paths see fresh data without round-tripping the gen_server.
publish(#state{} = State) ->
    bondy_oplog_registry:publish(#{
        instance_id => State#state.instance_id,
        instance_pid => self(),
        origin => State#state.origin,
        mst => State#state.mst,
        watermark => State#state.watermark,
        snapshot => State#state.cached_checkpoint,
        crdt_module => State#state.crdt_module,
        fold_module => State#state.fold_module,
        fold_opts => State#state.fold_opts,
        live_size => State#state.live_size,
        fused => State#state.fused,
        mst_retention => State#state.retention =/= undefined
    }).

%% @private
ets_member(InstanceId) ->
    bondy_oplog_registry:instance_pid(InstanceId) =/= undefined.

%% @private
%% Shape: `{Key, Value, Hlc, Origin}` per ?OVERLAY_KEY_POS macros.
%% Tolerates `Tab = undefined` (subtree mid-restart) — `ets:lookup`
%% on `undefined` raises `badarg`, which we treat as a clean miss
%% and let the caller fall through to the MST.
overlay_lookup_tab(Tab, Key) ->
    try ets:lookup(Tab, Key) of
        [{Key, Value, _Hlc, _Origin}] -> {ok, event_from_value(Key, Value)};
        [] -> not_found
    catch
        %% Tolerates a torn-down table during one_for_all restart.
        error:badarg -> not_found
    end.

%% @private
%% Returns overlay rows in `[From, To]` as a sorted list of
%% `{Key, Event}` tuples. `ets:select/2` on `ordered_set` yields rows
%% in key order, so the result list is already sorted. Returns `[]`
%% when the overlay tid is missing (subtree mid-restart).
overlay_range_tab(undefined, _From, _To) ->
    [];
overlay_range_tab(Tab, From, To) ->
    MatchSpec = [
        {
            {'$1', '$2', '_', '_'},
            [
                {'>=', '$1', {const, From}},
                {'=<', '$1', {const, To}}
            ],
            [{{'$1', '$2'}}]
        }
    ],
    try ets:select(Tab, MatchSpec) of
        Rows -> [{K, event_from_value(K, V)} || {K, V} <- Rows]
    catch
        error:badarg -> []
    end.

%% @private
%% Streaming merge of an MST fold with a pre-sorted overlay queue.
%% Returns the user accumulator after every entry in `[From, To]`
%% from both sources has been yielded in strict ascending key order.
%% Overlay wins on tied keys.
fold_range_merged(MST, From, To, OverlayQueue, Fun, Acc0) ->
    {Leftover, Acc1} = bondy_mst:fold(
        MST,
        fun({K, V}, {Queue, A}) ->
            case K >= From andalso K =< To of
                false -> {Queue, A};
                true -> merge_step(Queue, K, V, Fun, A)
            end
        end,
        {OverlayQueue, Acc0}
    ),
    drain_overlay_queue(Leftover, Fun, Acc1).

%% @private
merge_step([{OK, OEvent} | Rest], MstK, _MstV, Fun, Acc) when OK < MstK ->
    %% Overlay key strictly precedes MST key: yield overlay, recurse
    %% so we keep emitting overlay rows below the current MST entry.
    merge_step(Rest, MstK, _MstV, Fun, Fun(OEvent, Acc));
merge_step([{MstK, OEvent} | Rest], MstK, _MstV, Fun, Acc) ->
    %% Tied keys: overlay-wins; do not also emit the MST value.
    {Rest, Fun(OEvent, Acc)};
merge_step(Queue, MstK, MstV, Fun, Acc) ->
    %% Overlay queue empty, or its head is greater than MstK: emit
    %% MST entry.
    {Queue, Fun(event_from_value(MstK, MstV), Acc)}.

%% @private
drain_overlay_queue([], _Fun, Acc) ->
    Acc;
drain_overlay_queue([{_K, Event} | Rest], Fun, Acc) ->
    drain_overlay_queue(Rest, Fun, Fun(Event, Acc)).

%% @private
%% Min over (overlay.first, MST.first). Either can be empty.
merge_first_key_tab(Tab, MST) ->
    OverlayFirst = overlay_first_key_tab(Tab),
    MstFirst =
        case bondy_mst:first(MST) of
            undefined -> undefined;
            {K, _V} -> K
        end,
    min_key(OverlayFirst, MstFirst).

%% @private
%% Max over (overlay.last, MST.last). Either can be empty.
merge_latest_key_tab(Tab, MST) ->
    OverlayLast = overlay_last_key_tab(Tab),
    MstLast =
        case bondy_mst:last(MST) of
            undefined -> undefined;
            {K, _V} -> K
        end,
    max_key(OverlayLast, MstLast).

%% @private
overlay_first_key_tab(undefined) ->
    undefined;
overlay_first_key_tab(Tab) ->
    try ets:first(Tab) of
        '$end_of_table' -> undefined;
        K -> K
    catch
        error:badarg -> undefined
    end.

%% @private
overlay_last_key_tab(undefined) ->
    undefined;
overlay_last_key_tab(Tab) ->
    try ets:last(Tab) of
        '$end_of_table' -> undefined;
        K -> K
    catch
        error:badarg -> undefined
    end.

%% @private
%% Decrement the applier→instance in-flight counter after an
%% `install_local_batch` cast has been fully processed. If we just
%% freed the saturated slot (post-decrement value equals `cap - 1`),
%% wake the applier so it can resume reading the WAL. Cheaper than a
%% timer-based poll on the applier side; the cast is a noop if the
%% applier is already draining.
release_install_slot(#state{
    install_in_flight = undefined
}) ->
    ok;
release_install_slot(#state{
    instance_id = InstanceId,
    install_in_flight = Ref,
    max_install_in_flight = Cap
}) ->
    %% atomics is unsigned so add_get with -1 wraps if we underflow.
    %% Use sub_get for a signed-safe decrement.
    Now = atomics:sub_get(Ref, 1, 1),
    case Now =:= Cap - 1 of
        true ->
            %% Just below the cap; the applier was (or may have been)
            %% gated. Resume it.
            case bondy_oplog_registry:applier_pid(InstanceId) of
                undefined ->
                    ok;
                ApplierPid ->
                    bondy_oplog_applier:notify_drain_resume(ApplierPid)
            end;
        false ->
            ok
    end,
    ok.

%% @private
%% A4 — release N install slots after a coalesced batch (one per
%% coalesced cast). Calling `release_install_slot/1` N times decrements
%% the atomic N times; because the value descends monotonically through
%% the calls, exactly one of them observes the `Cap - 1` crossing and
%% wakes the applier — so coalescing N casts still resumes a gated
%% applier exactly once, without bespoke threshold arithmetic.
release_install_slots(_State, 0) ->
    ok;
release_install_slots(State, N) when N > 0 ->
    ok = release_install_slot(State),
    release_install_slots(State, N - 1).

%% @private
%% A4 — drain queued `install_local_batch` casts into `Acc` (a list of
%% per-cast event lists, most-recent first) without blocking. Stops at
%% `Max` casts (counting the one already being handled) or when the
%% mailbox holds no more install casts. Selective receive returns
%% mailbox-FIFO order, so prepending preserves WAL order once reversed.
drain_install_casts(Acc, N, Max) when N >= Max ->
    {Acc, N};
drain_install_casts(Acc, N, Max) ->
    receive
        {'$gen_cast', {install_local_batch, Events}} ->
            drain_install_casts([Events | Acc], N + 1, Max)
    after 0 ->
        {Acc, N}
    end.

%% @private
%% A4 — validate the coalescing cap. A malformed value crashes `init/1`
%% loudly (same convention as the other startup-validated opts) rather
%% than silently degrading to a default.
validate_coalesce_max(N) when is_integer(N), N >= 1 ->
    N;
validate_coalesce_max(Bad) ->
    error({invalid_opt, install_coalesce_max, Bad}).

%% @private
%% Replies `ok` to every caller queued in `drain_waiters` once the
%% overlay has reached size 0. Idempotent — re-running with an empty
%% waiter list or a non-empty overlay is a no-op. Called from every
%% handler that can shrink the overlay (`install_local_batch`,
%% `check_drain_waiters`).
maybe_signal_drain_waiters(#state{drain_waiters = []} = State) ->
    State;
maybe_signal_drain_waiters(
    #state{drain_waiters = Waiters, overlay = Tab} = State
) ->
    case overlay_size_tab(Tab) of
        0 ->
            lists:foreach(fun(From) -> gen_server:reply(From, ok) end, Waiters),
            State#state{drain_waiters = []};
        _ ->
            State
    end.

%% @private
overlay_size_tab(undefined) ->
    0;
overlay_size_tab(Tab) ->
    try ets:info(Tab, size) of
        N when is_integer(N) -> N;
        _ -> 0
    catch
        error:badarg -> 0
    end.

%% @private
min_key(undefined, undefined) -> empty;
min_key(undefined, K) -> {ok, K};
min_key(K, undefined) -> {ok, K};
min_key(A, B) when A =< B -> {ok, A};
min_key(_, B) -> {ok, B}.

%% @private
max_key(undefined, undefined) -> empty;
max_key(undefined, K) -> {ok, K};
max_key(K, undefined) -> {ok, K};
max_key(A, B) when A >= B -> {ok, A};
max_key(_, B) -> {ok, B}.

%% @private
target(Pid) when is_pid(Pid) ->
    Pid;
target(InstanceId) when is_binary(InstanceId) ->
    case ?MODULE:whereis(InstanceId) of
        undefined -> error({noproc, {?MODULE, InstanceId}});
        Pid -> Pid
    end;
target(Other) ->
    error({invalid_target, Other}).

%% @private
%% The ctx for a cell's bucket: its own registered table ctx when the bucket
%% is in the multiplex directory, else the founding ctx (for unregistered
%% buckets such as the reserved latency-probe bucket). `undefined` only when
%% the instance is unbootstrapped. Mirrors
%% `bondy_oplog_applier:resolve_cell_ctx/3` exactly (not exported there, so
%% duplicated rather than cross-module-private-called).
resolve_cell_ctx(Source, Bucket, Founding) ->
    case bondy_oplog_mux:resolve(Source, Bucket) of
        undefined -> Founding;
        Ctx -> Ctx
    end.

%% @private
%% Resolves and validates the `fold_module` / `fold_opts` instance
%% opts. `undefined` means "no fold configured" — the legacy event-
%% storage path remains in effect. Invalid configurations crash
%% init/1 with a structured error.
resolve_fold_config(InstanceId, Opts) ->
    case maps:get(fold_module, Opts, undefined) of
        undefined ->
            FoldOpts0 = maps:get(fold_opts, Opts, #{}),
            ok = assert_fold_opts(FoldOpts0),
            {undefined, FoldOpts0};
        Strategy ->
            %% The per-instance projection runs the native CRDT twin of the
            %% `fold_module` label. A label is valid iff it resolves to a
            %% twin; an unknown label has none.
            case bondy_oplog_cell_kernel:default_crdt_for_fold(Strategy) of
                undefined ->
                    erlang:error(
                        {invalid_fold_module, InstanceId, {unknown, Strategy}}
                    );
                _CrdtMod ->
                    FoldOpts = maps:get(fold_opts, Opts, #{}),
                    ok = assert_fold_opts(FoldOpts),
                    {Strategy, FoldOpts}
            end
    end.

%% @private
assert_fold_opts(M) when is_map(M) -> ok;
assert_fold_opts(Other) -> erlang:error({invalid_fold_opts, Other}).
