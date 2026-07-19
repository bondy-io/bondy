%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_config).
-moduledoc """
The public configuration surface for the `bondy_oplog` layer.

This module is the single source of truth for `bondy_oplog`'s tunable
application-environment values: each key's **default lives here, once**, in its
accessor — so the same default can no longer drift between read sites (the way
`bootstrap_retry_base_ms` and friends previously carried a literal at every
call). The export list is, in effect, the layer's config schema.

Value tunables that operators change at runtime expose a `set_*/1` write-through
next to their accessor (e.g. `aae_load_adaptive/0` ↔ `set_aae_load_adaptive/1`).
Keeping the read, the write, and the default in one place is what makes the
default a single source of truth: a setter cannot restate — and so cannot drift
from — the accessor's default.

## Live reads, not a cached snapshot

Each accessor reads `application:get_env(bondy_oplog, Key, Default)` directly, and
each setter is the symmetric `application:set_env(bondy_oplog, Key, Value)`, so a
value set at boot (by the release/cuttlefish schema) **or** changed at runtime
(via a `set_*/1`, as tests and operators do) takes effect on the next read. This
is deliberately NOT the `app_config`/`persistent_term` snapshot pattern used by
`bondy_mst_config`: that caches the env at init, which would silently ignore a
post-boot write — exactly the override the test harness and operators rely on
here.

## What is intentionally NOT here

- **Pluggable-implementation hooks** — `gc_trigger`, `sync_dispatch`,
  `peer_source`. These select a *module/fun* and fall back to a layer-local
  default implementation (`default_dispatch/2` etc.); they are not value
  tunables and their fallback belongs next to the implementation it names.
- **Per-instance keys** — `{validator_crypto, InstanceId}`. Instance-scoped
  state, not a global tunable.
""".

-define(APP, bondy_oplog).

%% SCHEDULERS
-export([sync_scheduler_enabled/0]).
-export([sync_interval_ms/0]).
-export([gc_scheduler_enabled/0]).
-export([origin_retirement_enabled/0]).
-export([origin_retirement_interval_ms/0]).
-export([reclaim_enabled/0]).
-export([reclaim_interval_ms/0]).
-export([reclaim_batch_cells/0]).
-export([gc_interval_ms/0]).
-export([gc_max_concurrency/0]).

%% PACK STORE (DURABLE MST)
-export([pack_auto_seal_bytes/0]).
-export([pack_seal_mode/0]).

%% LIVE-SYNC THROTTLE
-export([live_sync_adaptive/0]).
-export([set_live_sync_adaptive/1]).
-export([live_sync_base_ms/0]).
-export([set_live_sync_base_ms/1]).
-export([live_sync_max_ms/0]).
-export([set_live_sync_max_ms/1]).

%% PEERS / BOOTSTRAP
-export([peer_timeout_ms/0]).
-export([bootstrap_peer_strategy/0]).
-export([set_bootstrap_peer_strategy/1]).
-export([max_inflight_bootstraps/0]).
-export([set_max_inflight_bootstraps/1]).
-export([bootstrap_retry_base_ms/0]).
-export([set_bootstrap_retry_base_ms/1]).
-export([bootstrap_retry_max_ms/0]).
-export([set_bootstrap_retry_max_ms/1]).
-export([bootstrap_retry_jitter/0]).
-export([set_bootstrap_retry_jitter/1]).

%% AAE / SYNC SESSION
-export([aae_fence_on_isolation/0]).
-export([sync_session_opts/0]).
-export([aae_max_concurrency/0]).
-export([set_aae_max_concurrency/1]).
-export([aae_max_pages_in_flight/0]).
-export([aae_pages_per_round/0]).
-export([aae_load_adaptive/0]).
-export([set_aae_load_adaptive/1]).
-export([aae_load_run_queue_threshold/0]).
-export([set_aae_load_run_queue_threshold/1]).

%% INSTANCE HEAP MONITOR
-export([instance_gc_interval_ms/0]).
-export([instance_gc_heap_delta_bytes/0]).

%% OBSERVABILITY / MISC
-export([catalogue_cursor_ttl_ms/0]).
-export([metrics_interval_ms/0]).
-export([oplog_latency_opts/0]).
-export([latency_probe/0]).

%% =============================================================================
%% API — SCHEDULERS
%% =============================================================================

-doc "Whether the periodic AAE sync scheduler ticks (default `true`).".
-spec sync_scheduler_enabled() -> boolean().

sync_scheduler_enabled() ->
    application:get_env(?APP, sync_scheduler, true).

-doc "Sync scheduler tick interval in milliseconds (default `500`).".
-spec sync_interval_ms() -> non_neg_integer().

sync_interval_ms() ->
    application:get_env(?APP, sync_interval_ms, 500).

-doc "Whether the periodic compaction (GC) scheduler ticks (default `true`).".
-spec gc_scheduler_enabled() -> boolean().

gc_scheduler_enabled() ->
    application:get_env(?APP, gc_scheduler, true).

-doc """
Whether origin retirement auto-reacts to membership removals (default
`false`; the flip is a separate change from the capability).
""".
-spec origin_retirement_enabled() -> boolean().

origin_retirement_enabled() ->
    application:get_env(?APP, origin_retirement, false).

-doc """
Periodic origin-retirement pass interval in milliseconds (default
`600_000`). Membership events remain the primary trigger; the periodic pass
covers origin-epoch turnover WITHOUT a membership change — e.g. a K8s
StatefulSet pod that loses its volume and rejoins under the same name.
The pass is idempotent and fail-closed, so the tick is safe by construction.
""".
-spec origin_retirement_interval_ms() -> non_neg_integer().

origin_retirement_interval_ms() ->
    application:get_env(?APP, origin_retirement_interval_ms, 600_000).

-doc """
Whether the projection-cell reclamation scheduler ticks (default `false`).
The flip is a separate change from the capability
(`BONDY_DB_RECLAMATION_PLAN.md` Step 9).
""".
-spec reclaim_enabled() -> boolean().

reclaim_enabled() ->
    application:get_env(?APP, reclaim_enabled, false).

-doc """
Reclamation scheduler tick interval in milliseconds (default `60_000` —
deliberately much larger than `gc_interval_ms`'s 1000; reclamation is a
space concern, not a liveness one).
""".
-spec reclaim_interval_ms() -> non_neg_integer().

reclaim_interval_ms() ->
    application:get_env(?APP, reclaim_interval_ms, 60_000).

-doc """
Cells per bounded sweep call during a reclamation pass (default `500`).
The sweep runs inside the applier — the sole projection writer — so this is
the cap on how long a single pass batch can stall a concurrent write; the
pass loops batches to completion, letting writes interleave between them.
""".
-spec reclaim_batch_cells() -> pos_integer().

reclaim_batch_cells() ->
    application:get_env(?APP, reclaim_batch_cells, 500).

-doc "GC scheduler tick interval in milliseconds (default `1000`).".
-spec gc_interval_ms() -> non_neg_integer().

gc_interval_ms() ->
    application:get_env(?APP, gc_interval_ms, 1000).

-doc "Maximum concurrent compaction cycles in flight (default `4`).".
-spec gc_max_concurrency() -> pos_integer().

gc_max_concurrency() ->
    application:get_env(?APP, gc_max_concurrency, 4).

%% =============================================================================
%% API — PACK STORE (DURABLE MST)
%% =============================================================================

-doc """
`incoming.pack` byte threshold at which the durable pack-store MST seals it
into a sealed pack (default `2_000_000`, 2 MiB).

The seal rewrites the whole `incoming.pack` in one datasync'd pass, and that
pass runs on the instance's apply pipeline — so its duration is a freeze of
local writes' visibility (read-after-write freshness lag), not of the write
calls themselves. The cost scales linearly with this threshold: the pack
store's own default (16 MiB) produces ~600ms+ freezes, large enough to push
freshness lag toward the auth fence `max_lag` (1s, `bondy_auth`) and cause
spurious `temporarily_unavailable` refusals. 2 MiB keeps each freeze to ~tens
of ms with no throughput or hot-read cost — reads serve from the projection +
cache, never the MST, so the resulting larger sealed-pack count does not touch
the read path (it only adds AAE/compaction/cold-boot work, which GC bounds).
""".
-spec pack_auto_seal_bytes() -> pos_integer().

pack_auto_seal_bytes() ->
    application:get_env(?APP, pack_auto_seal_bytes, 2_000_000).

-doc """
Seal driver for the durable pack-store MST instances (default `async`).

`async` rolls `incoming.pack` aside at the commit barrier and rewrites it into
a sealed pack in a monitored worker process, keeping the multi-hundred-ms
rewrite off the instance's apply pipeline. The seal is therefore no longer a
freeze of local writes' visibility (read-after-write freshness lag) — measured
~44% lower `mst_install` p99 and the 84–188ms (up to ~750ms under disk
contention) inline seal freezes removed entirely, with no throughput cost. It
does NOT change durable write throughput — the per-writer ceiling is bounded by
disk fsync bandwidth, independent of where the seal runs.

`sync` restores the historical inline seal (the store seals on `put` when the
threshold is crossed). Affects only durable (pack-store) instances; ephemeral
(ets/map) backends never seal.
""".
-spec pack_seal_mode() -> sync | async.

pack_seal_mode() ->
    case application:get_env(?APP, pack_seal_mode, async) of
        async -> async;
        sync -> sync;
        _ -> async
    end.

%% =============================================================================
%% API — LIVE-SYNC THROTTLE
%% =============================================================================

-doc "Whether a converged instance backs its live-sync cadence off (default `true`).".
-spec live_sync_adaptive() -> boolean().

live_sync_adaptive() ->
    application:get_env(?APP, live_sync_adaptive, true).

-doc "Sets `live_sync_adaptive/0` at runtime.".
-spec set_live_sync_adaptive(boolean()) -> ok.

set_live_sync_adaptive(B) when is_boolean(B) ->
    application:set_env(?APP, live_sync_adaptive, B).

-doc """
Base live-sync cadence in milliseconds: the cadence while the local root is
moving. Defaults to `sync_interval_ms/0` (the scheduler tick).
""".
-spec live_sync_base_ms() -> non_neg_integer().

live_sync_base_ms() ->
    application:get_env(?APP, live_sync_base_ms, sync_interval_ms()).

-doc "Sets `live_sync_base_ms/0` at runtime.".
-spec set_live_sync_base_ms(non_neg_integer()) -> ok.

set_live_sync_base_ms(Ms) when is_integer(Ms), Ms >= 0 ->
    application:set_env(?APP, live_sync_base_ms, Ms).

-doc "Maximum (backed-off) live-sync poll window in milliseconds (default `5000`).".
-spec live_sync_max_ms() -> non_neg_integer().

live_sync_max_ms() ->
    application:get_env(?APP, live_sync_max_ms, 5000).

-doc "Sets `live_sync_max_ms/0` at runtime.".
-spec set_live_sync_max_ms(non_neg_integer()) -> ok.

set_live_sync_max_ms(Ms) when is_integer(Ms), Ms >= 0 ->
    application:set_env(?APP, live_sync_max_ms, Ms).

%% =============================================================================
%% API — PEERS / BOOTSTRAP
%% =============================================================================

-doc "Peer liveness timeout in milliseconds (default `30000`).".
-spec peer_timeout_ms() -> non_neg_integer().

peer_timeout_ms() ->
    application:get_env(?APP, peer_timeout_ms, 30_000).

-doc "Bootstrap peer-selection strategy (default `first`).".
-spec bootstrap_peer_strategy() -> atom().

bootstrap_peer_strategy() ->
    application:get_env(?APP, bootstrap_peer_strategy, first).

-doc "Sets `bootstrap_peer_strategy/0` at runtime. Takes effect on the next tick.".
-spec set_bootstrap_peer_strategy(first | random | round_robin) -> ok.

set_bootstrap_peer_strategy(S) when
    S =:= first; S =:= random; S =:= round_robin
->
    application:set_env(?APP, bootstrap_peer_strategy, S).

-doc "Maximum concurrent bootstrap sessions in flight (default `4`).".
-spec max_inflight_bootstraps() -> pos_integer().

max_inflight_bootstraps() ->
    application:get_env(?APP, max_inflight_bootstraps, 4).

-doc """
Sets `max_inflight_bootstraps/0` at runtime; `0` quiesces new bootstrap
dispatch (in-flight sessions drain naturally).
""".
-spec set_max_inflight_bootstraps(non_neg_integer()) -> ok.

set_max_inflight_bootstraps(N) when is_integer(N), N >= 0 ->
    application:set_env(?APP, max_inflight_bootstraps, N).

-doc "Bootstrap retry backoff base in milliseconds (default `500`).".
-spec bootstrap_retry_base_ms() -> non_neg_integer().

bootstrap_retry_base_ms() ->
    application:get_env(?APP, bootstrap_retry_base_ms, 500).

-doc "Sets `bootstrap_retry_base_ms/0` at runtime.".
-spec set_bootstrap_retry_base_ms(non_neg_integer()) -> ok.

set_bootstrap_retry_base_ms(Ms) when is_integer(Ms), Ms >= 0 ->
    application:set_env(?APP, bootstrap_retry_base_ms, Ms).

-doc "Bootstrap retry backoff ceiling in milliseconds (default `30000`).".
-spec bootstrap_retry_max_ms() -> non_neg_integer().

bootstrap_retry_max_ms() ->
    application:get_env(?APP, bootstrap_retry_max_ms, 30000).

-doc "Sets `bootstrap_retry_max_ms/0` at runtime.".
-spec set_bootstrap_retry_max_ms(non_neg_integer()) -> ok.

set_bootstrap_retry_max_ms(Ms) when is_integer(Ms), Ms >= 0 ->
    application:set_env(?APP, bootstrap_retry_max_ms, Ms).

-doc "Whether bootstrap retry backoff is jittered (default `true`).".
-spec bootstrap_retry_jitter() -> boolean().

bootstrap_retry_jitter() ->
    application:get_env(?APP, bootstrap_retry_jitter, true).

-doc "Sets `bootstrap_retry_jitter/0` at runtime.".
-spec set_bootstrap_retry_jitter(boolean()) -> ok.

set_bootstrap_retry_jitter(B) when is_boolean(B) ->
    application:set_env(?APP, bootstrap_retry_jitter, B).

%% =============================================================================
%% API — AAE / SYNC SESSION
%% =============================================================================

-doc """
The AE-fence policy when this node is an isolated, non-solo minority
(`refuse | proceed | quorum`; default `refuse`).
""".
-spec aae_fence_on_isolation() -> atom().

aae_fence_on_isolation() ->
    application:get_env(?APP, aae_fence_on_isolation, refuse).

-doc "Extra options threaded into each sync session (default `#{}`).".
-spec sync_session_opts() -> map().

sync_session_opts() ->
    application:get_env(?APP, sync_session_opts, #{}).

-doc """
Maximum number of AAE sync sessions allowed to run concurrently on this node
(default `3`).

AAE is background work subordinate to routing — this cap keeps it from
saturating the node. It governs *speed and fairness*, never the memory ceiling:
the per-round page batch is `aae_max_pages_in_flight/0 ÷` this value
(`aae_pages_per_round/0`), so raising concurrency shrinks each session's batch
and the node-wide page budget stays fixed. More concurrency therefore means
more peers/shards make progress at once (no shard starves behind a single
serial sync), at the cost of each session running slower — NOT more RAM. `1`
serialises AAE (simplest, but a busy node may never schedule some shards); `3`
is a sane fairness default.
""".
-spec aae_max_concurrency() -> pos_integer().

aae_max_concurrency() ->
    max(1, application:get_env(?APP, aae_max_concurrency, 3)).

-doc "Sets `aae_max_concurrency/0` at runtime. Takes effect on the next tick.".
-spec set_aae_max_concurrency(pos_integer()) -> ok.

set_aae_max_concurrency(N) when is_integer(N), N >= 1 ->
    application:set_env(?APP, aae_max_concurrency, N).

-doc """
Node-wide budget, in MST pages, for AAE reconciliation in flight at any instant
(default `2048`).

This is the lever that bounds AAE's peak memory. A sync session pulls missing
pages from its peer in rounds; historically it pulled the *entire* missing set
in one round, so a bulk initial sync loaded a whole shard tree at once (× every
shard syncing concurrently — the 16× blow-up). The budget caps how many pages
any one round materialises: each of the `aae_max_concurrency/0` sessions fetches
at most `aae_pages_per_round/0` pages per round, so total in-flight pages stay
≈ this budget regardless of concurrency or dataset size. A larger budget syncs
faster but raises the peak; a smaller budget is gentler on RAM and slower.
""".
-spec aae_max_pages_in_flight() -> pos_integer().

aae_max_pages_in_flight() ->
    max(1, application:get_env(?APP, aae_max_pages_in_flight, 2048)).

-doc """
The per-round page batch a single AAE session may pull, derived as
`aae_max_pages_in_flight/0 ÷ aae_max_concurrency/0` (at least `1`).

This is the value the sync session uses to bound `get_pages`. Dividing the
node-wide budget by the concurrency is what makes the memory ceiling
independent of how many sessions run: 1 session pulls big batches; 3 sessions
each pull a third — same node-wide peak, three-way fairness, each a bit slower.
""".
-spec aae_pages_per_round() -> pos_integer().

aae_pages_per_round() ->
    max(1, aae_max_pages_in_flight() div aae_max_concurrency()).

-doc """
Whether AAE yields its throttleable dispatches while the node is busy (default
`false` — opt-in).

The node-wide concurrency cap (`aae_max_concurrency/0`) bounds AAE in aggregate;
this lever adds the *temporal* dimension — even within the cap, a routing load
spike transiently defers AAE so background reconciliation never steals scheduler
time from the node's real job. It is a soft, per-tick yield read from a smoothed
node-load signal (`aae_load_run_queue_threshold/0`): in-flight sessions are never
aborted and the deferred shards retry on the next quiet tick. Instances that back
the authentication freshness fence are exempt (as they are from the cap), so the
yield never affects auth availability.

Off by default because the load signal is environment-sensitive and the cap plus
the live throttle already keep AAE subordinate to routing; enable it where a
node's routing latency is sensitive to AAE scheduler pressure under load.
""".
-spec aae_load_adaptive() -> boolean().

aae_load_adaptive() ->
    application:get_env(?APP, aae_load_adaptive, false).

-doc "Sets `aae_load_adaptive/0` at runtime.".
-spec set_aae_load_adaptive(boolean()) -> ok.

set_aae_load_adaptive(B) when is_boolean(B) ->
    application:set_env(?APP, aae_load_adaptive, B).

-doc """
Run-queue length per online scheduler — EWMA-smoothed — at or above which AAE
yields its throttleable dispatches for a tick (default `2.0`).

The signal is `erlang:statistics(run_queue) ÷ schedulers_online`: the average
number of *ready* processes waiting behind the one running on each scheduler. A
healthy node hovers near `0`–`1`; a sustained value of `2`+ means work is
queuing faster than the schedulers drain it — the node is backlogged and AAE
should step aside. Smoothing (a fixed EWMA over the scheduler ticks) gives the
threshold hysteresis so a momentary burst does not flap the yield. Lower yields
AAE sooner (more protective of routing latency, slower convergence under load);
higher lets AAE keep working closer to saturation. Only consulted when
`aae_load_adaptive/0` is on.
""".
-spec aae_load_run_queue_threshold() -> float().

aae_load_run_queue_threshold() ->
    case application:get_env(?APP, aae_load_run_queue_threshold, 2.0) of
        N when is_float(N) -> N;
        N when is_integer(N) -> float(N);
        _ -> 2.0
    end.

-doc """
Sets `aae_load_run_queue_threshold/0` at runtime. Accepts an integer or float;
stored as a float.
""".
-spec set_aae_load_run_queue_threshold(number()) -> ok.

set_aae_load_run_queue_threshold(N) when is_number(N), N >= 0 ->
    application:set_env(?APP, aae_load_run_queue_threshold, float(N)).

%% =============================================================================
%% API — INSTANCE HEAP MONITOR
%% =============================================================================

-doc """
Interval in milliseconds at which each `bondy_oplog_instance` checks its own
heap and fullsweep-hibernates if it has grown past
`instance_gc_heap_delta_bytes/0` (default `2000`).

The monitor reclaims the transient apply/AAE garbage a long-lived instance
process retains until the next major GC — most visibly during a solo import
(no peers), where the AAE-driven hibernate never fires and the heap would
otherwise climb unbounded. `0` disables the monitor.
""".
-spec instance_gc_interval_ms() -> non_neg_integer().

instance_gc_interval_ms() ->
    application:get_env(?APP, instance_gc_interval_ms, 2000).

-doc """
Heap-growth threshold, in bytes, above an instance's post-GC baseline at which
the periodic monitor fullsweep-hibernates it (default `16_777_216`, 16 MiB).

Keying on *growth over the live baseline* — not absolute heap size — is what
keeps an instance with a large live MST from being GC-thrashed: the monitor
fires once per ~this-many bytes of accumulated garbage, capping the transient
per-instance peak at roughly `live + this`, then settles. Lower trades a touch
more fullsweep work for a tighter memory ceiling.
""".
-spec instance_gc_heap_delta_bytes() -> pos_integer().

instance_gc_heap_delta_bytes() ->
    max(1, application:get_env(?APP, instance_gc_heap_delta_bytes, 16_777_216)).

%% =============================================================================
%% API — OBSERVABILITY / MISC
%% =============================================================================

-doc "Catalogue-snapshot cursor TTL in milliseconds (default `60000`).".
-spec catalogue_cursor_ttl_ms() -> non_neg_integer().

catalogue_cursor_ttl_ms() ->
    application:get_env(?APP, catalogue_cursor_ttl_ms, 60_000).

-doc """
Core-metrics reporting interval in milliseconds (default `1000`), read from the
`interval_ms` field of the `metrics` map env value when present.
""".
-spec metrics_interval_ms() -> non_neg_integer().

metrics_interval_ms() ->
    case application:get_env(?APP, metrics) of
        {ok, M} when is_map(M) -> maps:get(interval_ms, M, 1000);
        _ -> 1000
    end.

-doc "Write→readable latency-sampling options map (default `#{}`).".
-spec oplog_latency_opts() -> map().

oplog_latency_opts() ->
    case application:get_env(?APP, oplog_latency) of
        {ok, M} when is_map(M) -> M;
        _ -> #{}
    end.

-doc "The latency-probe config, or `undefined` when probing is disabled.".
-spec latency_probe() -> term().

latency_probe() ->
    application:get_env(?APP, latency_probe, undefined).
