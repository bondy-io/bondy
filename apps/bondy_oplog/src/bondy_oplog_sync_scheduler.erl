%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_sync_scheduler).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Default sync scheduler.

Periodic `gen_server` that, on each tick, asks
`bondy_oplog:list_instances/0` for the running instances and
— for each — invokes the configured peer source and dispatches a sync
session to each peer.

## Configuration

Read from app env at boot:

| Key                   | Default | Meaning |
|---|---|---|
| `sync_scheduler`      | `true`  | Enable / disable the scheduler. |
| `sync_interval_ms`    | `500`   | Time between ticks. |
| `peer_source`         | `bondy_oplog_peer_source_static` | Default behaviour module. |
| `peer_source_opts`    | `#{}`   | Default opts passed to `peers_for/2`. |
| `sync_dispatch`       | `undefined` | Optional `fun((InstanceId, [PeerId]) -> any())`; defaults to the lifecycle-aware dispatch below. |
| `sync_session_opts`   | `#{}`   | Opts (`transport`, `transport_opts`) threaded into every session the default dispatch starts. `#{}` ⇒ `bondy_oplog_transport_inline`; a clustered node sets the Partisan transport + AE channel here. |
| `bootstrap_peer_strategy` | `first` | One of `first \| random \| round_robin`. Selects which peer a `pre_bootstrap` instance bootstraps from. |
| `aae_max_concurrency` | `3`     | Node-wide cap on concurrent sync sessions (bootstrap + live). The primary "how many concurrent AAE syncs" lever. Also the divisor for `aae_pages_per_round`, so it governs speed/fairness, never the memory ceiling. |
| `max_inflight_bootstraps` | `4`     | Narrower sub-cap on parallel *bootstrap* sessions, within the node-wide cap. Dispatches above either cap are skipped (instance stays `pre_bootstrap` → retried next tick). |
| `bootstrap_retry_base_ms` | `500`   | Initial backoff after a failed bootstrap session. Doubles per consecutive failure up to `bootstrap_retry_max_ms`. |
| `bootstrap_retry_max_ms`  | `30000` | Upper bound on the exponential backoff window. |
| `bootstrap_retry_jitter`  | `true`  | Multiplies the computed wait by `uniform(0.5, 1.5)` to spread retries across instances. |
| `live_sync_adaptive`  | `true`  | Throttle live (post-bootstrap) syncs adaptively. `false` ⇒ every live instance syncs every peer every tick (historical). |
| `live_sync_base_ms`   | `sync_interval_ms` | Poll cadence for a live shard whose local root is actively moving. |
| `live_sync_max_ms`    | `5000` | Upper bound on the live-sync poll window once a shard goes quiescent. Instances that back the auth fence are exempt — they are never throttled. |

## Default dispatch — lifecycle-aware

For each tick, the default dispatch inspects the instance's bootstrap
lifecycle (`bondy_oplog_instance:lifecycle_state/1`) and routes
accordingly:

- **`pre_bootstrap`** — pick a single peer (via the configured
  `bootstrap_peer_strategy`, see below) and dispatch one bootstrap
  session via
  `bondy_oplog_sync_session:start_bootstrap_catalogue/3` (catalogue
  mode, `crdt_module = undefined`) or
  `bondy_oplog_sync_session:start_bootstrap/3` (single-CRDT mode).
  Single-peer to avoid duplicate snapshot transfers — bootstrap is
  expensive (full projection ship) and multi-peer would not improve
  correctness.
- **`live`** — fan out one async pull-direction sync session per peer
  via `bondy_oplog_sync_session:start/3`, gated by the adaptive
  live-sync throttle (see below).

## Bootstrap peer strategy

- **`first`** (default) — always pick `hd(Peers)`. Deterministic,
  cheap, brittle when that peer is overloaded or unreachable.
- **`random`** — uniform random pick. Best for thundering-herd
  avoidance when many `pre_bootstrap` instances start simultaneously.
- **`round_robin`** — per-instance index advanced on every dispatch
  decision (held in a small named ETS table). Even distribution
  across peers for a single instance that retries after failure.

The strategy is read per dispatch from app env; runtime changes via
`bondy_oplog_config:set_bootstrap_peer_strategy/1` take effect on the next tick.

## Node-wide AAE concurrency cap and fairness

AAE is background work, subordinate to the node's real job (routing). A
single node-wide cap, `aae_max_concurrency` (default `3`), bounds how many
sync sessions — bootstrap *or* live — run at once, so a bulk reconciliation
cannot saturate the node. It is the same number used as the divisor for the
per-round page batch (`bondy_oplog_config:aae_pages_per_round/0`), which is
what keeps the cap a knob on *speed and fairness* rather than on memory:
raise it and each session pulls a smaller batch, so the node-wide page peak
is unchanged while more shards make progress at once.

Every spawned session — bootstrap and live alike — is tracked and monitored
in a named ETS table keyed by session Pid, with the entry tagged by kind and
(for live) peer: `{Pid, InstanceId, bootstrap | live, Peer | undefined}`.
The total row count is the in-flight count the cap reads (fresh per
dispatch, so the cap holds across instances within a tick). Entries are
removed when the session process exits (monitored via `erlang:monitor/2`);
a bootstrap exit additionally drives the per-instance retry backoff, a live
exit is self-healing and carries no backoff. On a scheduler restart the
table is recreated empty — already-running sessions are then untracked,
correct because the scheduler did not spawn them in its current incarnation.

A live fan-out skips any peer it already has a session running against, so a
slow (bulk-syncing) shard never stacks duplicate sessions on the same peer.

**Fairness.** Each tick sorts the instances and rotates the list by a
monotonic tick counter before dispatching, so that when the cap is scarce
the instances that win the free slots rotate across ticks. This is what
makes a *low* cap safe: with `aae_max_concurrency = 1`, a fixed order would
let the first shard monopolise the only slot forever and starve the rest;
the rotation guarantees every shard is offered the slot in turn and can
eventually catch up.

**Bootstrap sub-cap.** Within the node-wide cap, `max_inflight_bootstraps`
(default `4`) further limits concurrent *bootstrap* sessions — for operators
who want the expensive snapshot ship throttled below the node-wide AAE
limit. A bootstrap dispatch needs headroom under both caps; crossing either
skips silently (instance stays `pre_bootstrap`, retried next tick).
Operators get visibility via the
`[bondy_oplog, sync_scheduler, bootstrap_capped]` telemetry event (which
carries both the bootstrap and node-wide current/cap), and the live cap via
`[bondy_oplog, sync_scheduler, live_capped]`.

**Fence exemption.** An instance that backs the auth freshness fence is
exempt from the cap (as it is from the live throttle): it must sync every
tick to keep the fence fresh, and starving it would refuse authentication.
Its memory stays bounded by the per-round page batch, and fence-backers are
few, so the bounded over-budget is an acceptable trade for auth availability.

## Load-reactive yield

The concurrency cap bounds AAE *in aggregate*; the load-reactive yield adds the
*temporal* dimension. Even three concurrent syncs add scheduler pressure, and
during a routing burst that pressure competes with the node's real job. When on
(opt-in via `aae_load_adaptive`; off by default), the scheduler samples a
node-load signal once per tick and, while the node is backlogged, **yields** —
skipping its throttleable dispatches for that tick — so background reconciliation
steps aside for routing.

The signal is a BEAM primitive, read directly (no dependency on `bondy_router`
or any higher layer): `erlang:statistics(run_queue) ÷ schedulers_online`, the
average count of ready processes queued per scheduler. It is EWMA-smoothed
across ticks (`load_decide/4`) so a momentary burst does not flap the yield, and
compared against `aae_load_run_queue_threshold` (default `2.0`). The decision is
computed once per tick (one sample for the whole tick, so every instance sees a
consistent verdict) and published to a small named ETS cell that the per-instance
dispatch reads.

The yield is **soft and fence-safe**:

- In-flight sessions are never aborted — only *new* dispatches are deferred. The
  deferred shards stay in their lifecycle and retry on the next quiet tick.
- It gates only the throttleable work: `pre_bootstrap` snapshot ships (the
  heaviest operation, and a `pre_bootstrap` instance serves no reads yet) and
  non-fence `live` syncs. Fence-backers bypass the yield exactly as they bypass
  the cap — their freshness bump must land within `auth_max_lag` or the read-side
  fence refuses authentication, so they sync every tick regardless of load.
- It cannot affect correctness, only convergence latency: deferring AAE while
  overloaded, then catching up once load drops, is the design intent. Because
  AAE is self-bounded by the cap, its own sessions rarely move the signal on
  multi-core hardware; the threshold is tripped by genuine routing/CPU load.

Telemetry: `[bondy_oplog, sync_scheduler, load_yield]` fires on each tick the
node yields (carrying the smoothed `run_queue_ratio`), and
`[bondy_oplog, sync_scheduler, bootstrap_load_deferred]` /
`[bondy_oplog, sync_scheduler, live_load_deferred]` on each deferred dispatch.

## Bootstrap retry backoff

After a session exits non-normally (the session process raised
`{bootstrap_failed, _}` or `{bootstrap_catalogue_failed, _}` from
`bondy_oplog_sync_session`), the scheduler records a per-instance
failure count and a next-retry timestamp. Subsequent ticks skip
that instance until the timestamp has passed. The wait is
`base * 2^(count-1)` capped at `bootstrap_retry_max_ms`. With
jitter enabled (default), the final wait is multiplied by a
uniform random factor in `[0.5, 1.5]` to spread retries across
instances that failed in the same window.

A successful session exit (reason `normal`) clears the backoff
entry; the next disruption starts fresh from `base`.

`[bondy_oplog, sync_scheduler, bootstrap_backoff_deferred]`
telemetry fires on every cap-skip with `wait_ms` and `fail_count`
measurements — useful as an alert signal when an instance keeps
failing to bootstrap.

A consumer can override the routing entirely by setting
`sync_dispatch` to a custom fun. Exceptions raised by a custom
dispatch are caught and logged. Custom dispatchers bypass the cap
and the backoff; consumers wanting either with a custom strategy
should call back into
`bondy_oplog_sync_scheduler:default_dispatch/2` after their
selection.

## Live-sync throttle

A `live` instance only re-syncs to discover divergence; once its data
has converged it has nothing to pull, yet the historical dispatch still
spawned a session against every peer on every tick. Across many shards
this is a constant, pointless load — the dominant steady-state cost of
running AAE.

The throttle (default on; disable with `live_sync_adaptive = false`)
makes the live-sync cadence adaptive per instance, using the instance's
in-memory MST root as a free change detector:

- While the local root is moving — a local write, data arriving via
  normal replication, or a prior sync catching up — the instance
  dispatches every tick (cadence `live_sync_base_ms`, default the tick
  interval). This is exactly the historical behaviour during activity.
- Once the root goes quiescent, the poll window doubles each round up to
  `live_sync_max_ms` (default `5s`). The instance still polls at the
  capped cadence so divergence is discovered within at most one window.
- The first such poll that pulls anything moves the local root, which
  resets the window to the base interval, so recovery is fast once it
  starts.

`bondy_db` apply is pull-only (no eager push), so the capped cadence is
also the steady-state cross-node convergence latency for a quiescent
shard — keep `live_sync_max_ms` below the convergence SLA you need. The
default `5s` trades a 10× churn cut for at most `5s` of convergence lag
on idle shards.

**Fence exemption.** An instance that carries AE freshness targets backs
the read-side authentication fence: its successful sync round re-bumps
those targets (`bondy_oplog_sync_session:maybe_record/4`), even when the
shard is converged, and the fence refuses authentication once a target
goes unconfirmed past `auth_max_lag`. Such an instance is **never**
throttled — backing it off would starve the bump and trip the fence on
inactivity. Only instances with no AE targets (for which the bump is a
no-op) are throttled. This keeps the throttle a pure performance change
with no effect on auth availability.

The throttle keys solely on the local root, so it never trades away
freshness for data this node already has; it only stretches the
*detection* latency for data it is missing, bounded by the cap. The
`pre_bootstrap` path is untouched — it has its own peer strategy and
failure backoff. Telemetry: `[bondy_oplog, sync_scheduler,
live_sync_poll]` on each backed-off poll (with `window_ms`) and
`[bondy_oplog, sync_scheduler, live_sync_skipped]` on each tick a
converged instance is skipped.

## Re-bootstrap on reclaimed peer pages

A live pull that fails with `{peer_pages_unavailable, _}` is terminal for
the page protocol: the peer explicitly no longer holds pages this replica
needs — its compaction or stable-cell reclamation ran ahead of our sync —
so retrying the pull can never succeed. The way forward is a catalogue
snapshot re-bootstrap (`bondy_oplog_sync_session:bootstrap_catalogue/3`
with a live caller), which ships the peer's *current* projection and then
op-replays on top.

The scheduler is the consumer of that terminal error. When a live
session's exit reason carries `{peer_pages_unavailable, _}`, the
instance is flagged for re-bootstrap
(`[bondy_oplog, sync_scheduler, rebootstrap_scheduled]` telemetry fires)
and, from the next tick, its live dispatch is replaced by a bootstrap
dispatch routed through the regular bootstrap gates (load yield, retry
backoff, both concurrency caps). The peer that reported the
unavailability is offered first to the peer strategy — it certifiably
holds a snapshot covering the reclaimed pages — but any member does:
reclamation only ever discards what EVERY member confirmed holding.
While the re-bootstrap session is in flight no live syncs are dispatched
for the instance (they would fail with the same reason and waste cap
slots); a failed re-bootstrap re-enters via the normal live path — the
next unavailable pull re-flags it, and the bootstrap backoff paces the
retries.
""").

-record(state, {
    enabled :: boolean(),
    interval_ms :: non_neg_integer(),
    peer_source :: module(),
    peer_source_opts :: map(),
    dispatch :: undefined | fun((instance_id(), [peer_id()]) -> any()),
    tick_ref :: undefined | reference(),
    %% Monotonic tick counter. Each tick rotates the (sorted) instance
    %% list by this value so that, when the node-wide AAE concurrency cap
    %% is scarce, the instances that win the free slots rotate across
    %% ticks — no shard starves behind another. See `run_tick/1`.
    tick_seq = 0 :: non_neg_integer(),
    %% EWMA of the node-load signal (run-queue length per scheduler),
    %% updated once per tick and carried here for smoothing continuity.
    %% The derived per-tick yield decision is published to `?LOAD_TAB`
    %% for the per-instance dispatch to read. See `run_tick/1`,
    %% `update_load/1`, `load_decide/4`.
    load_ewma = 0.0 :: float()
}).

%% Lifecycle
-export([start_link/0]).
-export([start_link/1]).
-export([child_spec/1]).

%% Control
-export([trigger/0]).
-export([set_dispatch/1]).
-export([set_peer_source/2]).
-export([set_interval_ms/1]).
-export([info/0]).
-export([inflight_for/1]).
-export([default_dispatch/2]).

-define(RR_TAB, bondy_oplog_sync_scheduler_rr).
-define(INFLIGHT_TAB, bondy_oplog_sync_scheduler_inflight).
-define(BACKOFF_TAB, bondy_oplog_sync_scheduler_backoff).
-define(LIVE_BACKOFF_TAB, bondy_oplog_sync_scheduler_live_backoff).
-define(LOAD_TAB, bondy_oplog_sync_scheduler_load).
-define(REBOOTSTRAP_TAB, bondy_oplog_sync_scheduler_rebootstrap).
-define(GAP_STRIKE_TAB, bondy_oplog_sync_scheduler_gap_strikes).
%% A `frontier_gap` only schedules a rebootstrap on the SECOND consecutive
%% strike for the same (instance, peer) within this window; a successful
%% round clears the count. The gap verdict's deterministic core — the
%% peer's installed-consistency barrier on `get_frontier`, the
%% complete-round gate, and the initiator's local settle — eliminates the
%% SYSTEMATIC false positives (install lag, replay lag, capped rounds).
%% The short-lived gaps this debounce used to ride out under sustained
%% write load were the observable window of the WATERMARK DOOR —
%% `integrate_peer_root` discarding a just-pulled never-applied peer
%% event at or below the local watermark — which is now CLOSED
%% (`watermark_door/3` in `bondy_oplog_instance`: fused instances fold
%% such events into the projection before truncating; applier-backed
%% instances hold them for the applier's replay). With the door closed
%% a gap verdict is deterministic evidence of compacted-past-me
%% history — but not yet of a STANDING gap: the door itself mints a
%% legitimate single-strike transient. When a peer door-FOLDS an
%% in-flight event, its applied VV advances past what its truncated
%% MST can serve, and a third replica whose complete round lands in
%% that window records a deficit it can only cover via the ORIGIN one
%% round later (the origin cannot compact the event away — the
%% peer-confirmed frontier needs the lagging replica's roots to
%% contain it; observed live in the compaction cluster suite, ~63ms
%% window). That transient heals on the next round and must NOT
%% trigger the remedy, because the remedy is not free: a catalogue
%% re-bootstrap streams the peer's whole projection and re-derives the
%% local one. A standing gap cannot heal by syncing and strikes again
%% on the very next round, so detection is delayed by one round, never
%% lost.
-define(GAP_STRIKE_WINDOW_MS, 120_000).
%% Consecutive `root_unservable_behind` strikes (same window as above)
%% before the permanent-unservable escalation fires. Higher than the gap
%% path's two because transient unservability is an EXPECTED benign state
%% (the responder guard's original truncate/GC race window) and rounds
%% against an unservable peer are cheap refusals — three in a row inside
%% the window separates the permanent form cleanly.
-define(UNSERVABLE_STRIKES, 3).
%% EWMA smoothing factor for the node-load signal: the weight given to the
%% newest per-tick sample. 0.3 keeps ~3 ticks of history, enough hysteresis
%% that a single-tick burst does not flip the yield while still reacting
%% within a second at the default tick interval.
-define(LOAD_ALPHA, 0.3).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-ifdef(TEST).
%% Exposed for deterministic unit testing of the live-sync backoff
%% state machine, decoupled from the clock and instance root reads.
-export([live_decide/5]).
%% Exposed for deterministic unit testing of the fair-rotation that
%% spreads scarce node-wide concurrency slots across instances per tick.
-export([rotate/2]).
%% Exposed for deterministic unit testing of the load-reactive yield
%% decision (EWMA + threshold), decoupled from the VM load probe.
-export([load_decide/4]).
-endif.

%% =============================================================================
%% LIFECYCLE
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    start_link(#{}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

-spec child_spec(map()) -> supervisor:child_spec().

child_spec(Opts) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

%% =============================================================================
%% CONTROL
%% =============================================================================

?DOC("""
Forces a tick now. Useful for tests and operational triggers.
""").
-spec trigger() -> ok.

trigger() ->
    gen_server:cast(?MODULE, tick).

?DOC("""
Replaces the dispatch callback. Pass `undefined` to disable dispatch
(ticks still run; nothing is invoked). Useful for runtime
reconfiguration and tests.
""").
-spec set_dispatch(undefined | fun((instance_id(), [peer_id()]) -> any())) ->
    ok.

set_dispatch(Fun) when is_function(Fun, 2); Fun =:= undefined ->
    gen_server:call(?MODULE, {set_dispatch, Fun}).

?DOC("""
Replaces the peer source module and options at runtime.
""").
-spec set_peer_source(module(), map()) -> ok.

set_peer_source(Mod, Opts) when is_atom(Mod), is_map(Opts) ->
    gen_server:call(?MODULE, {set_peer_source, Mod, Opts}).

?DOC("""
Sets the periodic-tick interval (in milliseconds) at runtime. `0`
disables periodic ticks entirely; explicit `trigger/0` still works.
The currently-scheduled timer is cancelled and a new one armed with
the new interval (if non-zero).

Useful for operator tuning and for tests that need to suppress
periodic firing while asserting on explicit triggers.
""").
-spec set_interval_ms(non_neg_integer()) -> ok.

set_interval_ms(Ms) when is_integer(Ms), Ms >= 0 ->
    gen_server:call(?MODULE, {set_interval_ms, Ms}).

?DOC("""
Returns the scheduler's current configuration. Cheap.
""").
-spec info() -> map().

info() ->
    gen_server:call(?MODULE, info).

?DOC("""
Diagnostic aid: the in-flight sync sessions currently dispatched for
`InstanceId` (bootstrap or live, against any peer), each with its age
in milliseconds since dispatch. Reads the in-flight table directly, no
gen_server round trip. An entry whose age is large relative to normal
round-trip expectations indicates a session that is not completing —
useful to distinguish "never dispatched" from "dispatched but stuck"
when diagnosing a convergence stall.
""").
-spec inflight_for(instance_id()) ->
    [
        {
            pid(),
            bootstrap | live,
            peer_id() | undefined,
            AgeMs :: non_neg_integer()
        }
    ].

inflight_for(InstanceId) ->
    _ = ensure_table(?INFLIGHT_TAB),
    Now = now_ms(),
    Pattern = {'$1', InstanceId, '$2', '$3', '$4'},
    Rows = ets:select(?INFLIGHT_TAB, [{Pattern, [], [['$1', '$2', '$3', '$4']]}]),
    [
        {Pid, Kind, Peer, Now - StartedAt}
     || [Pid, Kind, Peer, StartedAt] <- Rows
    ].

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    _ = ensure_table(?RR_TAB),
    _ = ensure_table(?INFLIGHT_TAB),
    _ = ensure_table(?BACKOFF_TAB),
    _ = ensure_table(?LIVE_BACKOFF_TAB),
    _ = ensure_table(?LOAD_TAB),
    _ = ensure_table(?REBOOTSTRAP_TAB),
    _ = ensure_table(?GAP_STRIKE_TAB),
    Dispatch =
        case maps:find(dispatch, Opts) of
            {ok, V} ->
                V;
            error ->
                case application:get_env(bondy_oplog, sync_dispatch) of
                    {ok, EnvFun} -> EnvFun;
                    undefined -> fun default_dispatch/2
                end
        end,
    State = #state{
        enabled = maps:get(
            enabled, Opts, bondy_oplog_config:sync_scheduler_enabled()
        ),
        interval_ms = maps:get(
            interval_ms, Opts, bondy_oplog_config:sync_interval_ms()
        ),
        peer_source = maps:get(
            peer_source,
            Opts,
            application:get_env(
                bondy_oplog,
                peer_source,
                bondy_oplog_peer_source_static
            )
        ),
        peer_source_opts = maps:get(
            peer_source_opts,
            Opts,
            application:get_env(
                bondy_oplog, peer_source_opts, #{}
            )
        ),
        dispatch = Dispatch,
        tick_seq = 0,
        load_ewma = 0.0
    },
    {ok, schedule_tick(State)}.

handle_call(info, _From, State) ->
    Reply = #{
        enabled => State#state.enabled,
        interval_ms => State#state.interval_ms,
        peer_source => State#state.peer_source,
        peer_source_opts => State#state.peer_source_opts,
        dispatch_set => State#state.dispatch =/= undefined,
        bootstrap_peer_strategy => bondy_oplog_config:bootstrap_peer_strategy(),
        max_inflight_bootstraps => bondy_oplog_config:max_inflight_bootstraps(),
        aae_max_concurrency => bondy_oplog_config:aae_max_concurrency(),
        aae_load_adaptive => bondy_oplog_config:aae_load_adaptive(),
        aae_load_run_queue_threshold =>
            bondy_oplog_config:aae_load_run_queue_threshold(),
        current_load => current_load(),
        load_yielding => load_yielding(),
        current_inflight_total => inflight_count(),
        current_inflight_bootstraps => inflight_bootstrap_count(),
        bootstrap_retry_base_ms => bondy_oplog_config:bootstrap_retry_base_ms(),
        bootstrap_retry_max_ms => bondy_oplog_config:bootstrap_retry_max_ms(),
        bootstrap_retry_jitter => bondy_oplog_config:bootstrap_retry_jitter(),
        live_sync_adaptive => live_adaptive_enabled(),
        live_sync_base_ms => live_sync_base_ms(),
        live_sync_max_ms => live_sync_max_ms()
    },
    {reply, Reply, State};
handle_call({set_dispatch, Fun}, _From, State) ->
    {reply, ok, State#state{dispatch = Fun}};
handle_call({set_peer_source, Mod, Opts}, _From, State) ->
    {reply, ok, State#state{peer_source = Mod, peer_source_opts = Opts}};
handle_call({set_interval_ms, Ms}, _From, State0) ->
    State1 = cancel_pending_tick(State0),
    State2 = schedule_tick(State1#state{interval_ms = Ms}),
    {reply, ok, State2};
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(tick, State) ->
    {noreply, run_tick(State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    {noreply, schedule_tick(run_tick(State))};
handle_info({'DOWN', _MonRef, process, Pid, Reason}, State) ->
    case ets:lookup(?INFLIGHT_TAB, Pid) of
        [{Pid, InstanceId, Kind, Peer, _StartedAt}] ->
            ets:delete(?INFLIGHT_TAB, Pid),
            %% Bootstrap failures drive the per-instance retry backoff; live
            %% sync failures are self-healing (the next tick re-dispatches
            %% under the same throttle/cap), so they carry no backoff state.
            %% EXCEPT the terminal one: `peer_pages_unavailable` means the
            %% peer reclaimed pages we still need — no retry can succeed, so
            %% the instance is flagged for a snapshot re-bootstrap instead.
            Kind =:= bootstrap andalso update_backoff(InstanceId, Reason),
            Kind =:= live andalso
                maybe_flag_rebootstrap(InstanceId, Peer, Reason),
            telemetry:execute(
                [bondy_oplog, sync_scheduler, Kind, ended],
                #{remaining => inflight_count()},
                #{
                    instance_id => InstanceId,
                    pid => Pid,
                    kind => Kind,
                    reason => Reason
                }
            );
        [] ->
            %% DOWN from something we didn't track — ignore.
            ok
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
run_tick(#state{enabled = false} = State) ->
    State;
run_tick(#state{tick_seq = Seq, load_ewma = Prev} = State) ->
    %% Sample the node-load signal ONCE per tick and publish the derived
    %% yield decision before dispatching, so every instance this tick sees a
    %% consistent verdict (a single sample for the whole tick). The smoothed
    %% value is carried in state for EWMA continuity. See `update_load/1`.
    NewEwma = update_load(Prev),
    %% Sort for a deterministic order, then rotate by the tick counter so
    %% that across successive ticks every instance gets first crack at the
    %% scarce node-wide AAE concurrency slots. Without this, a fixed
    %% iteration order would let the head instances monopolise the cap and
    %% starve the tail (the failure the user flagged for low caps).
    Instances = rotate(lists:sort(safe_list_instances()), Seq),
    lists:foreach(
        fun(InstanceId) -> dispatch_for(InstanceId, State) end,
        Instances
    ),
    telemetry:execute(
        [bondy_oplog, scheduler, sync, tick],
        #{instances => length(Instances)},
        #{}
    ),
    State#state{tick_seq = Seq + 1, load_ewma = NewEwma}.

%% @private
%% Left-rotates `L` by `N rem length(L)` positions. `rotate(L, 0) =:= L`.
rotate([], _N) ->
    [];
rotate(L, N) ->
    K = N rem length(L),
    {Head, Tail} = lists:split(K, L),
    Tail ++ Head.

%% @private
%% Samples the node-load signal, folds it into the EWMA, derives the per-tick
%% yield decision and publishes `{state, Ewma, Yield}` to `?LOAD_TAB` for the
%% per-instance dispatch (`load_yielding/0`) and `info/0` to read. Returns the
%% new EWMA so `run_tick/1` can carry it for the next sample. When the gate is
%% disabled the signal decays toward 0 and the decision is always `false`.
update_load(Prev) ->
    Enabled = bondy_oplog_config:aae_load_adaptive(),
    Sample =
        case Enabled of
            true -> node_run_queue_ratio();
            false -> 0.0
        end,
    Threshold = bondy_oplog_config:aae_load_run_queue_threshold(),
    {Ewma, Yield} = load_decide(Enabled, Sample, Prev, Threshold),
    publish_load(Ewma, Yield),
    Yield andalso
        telemetry:execute(
            [bondy_oplog, sync_scheduler, load_yield],
            #{run_queue_ratio => Ewma, sample => Sample},
            #{threshold => Threshold}
        ),
    Ewma.

%% @private
%% The pure yield decision, factored out of the VM probe and the clock so it
%% is deterministically unit-testable. Folds `Sample` into the EWMA and yields
%% when enabled and the smoothed load is at or above `Threshold`. A disabled
%% gate never yields regardless of load.
load_decide(Enabled, Sample, Prev, Threshold) ->
    Ewma = ?LOAD_ALPHA * Sample + (1.0 - ?LOAD_ALPHA) * Prev,
    Yield = Enabled andalso Ewma >= Threshold,
    {Ewma, Yield}.

%% @private
%% The node-load signal: the total normal run-queue length divided by the
%% number of online schedulers — the average count of ready processes queued
%% per scheduler. A pure BEAM primitive (no dependency on any higher layer),
%% cheap to read. Normal schedulers only, so disk-bound dirty work (which
%% yielding AAE would not relieve) does not move it.
node_run_queue_ratio() ->
    RunQueue = erlang:statistics(run_queue),
    Schedulers = erlang:system_info(schedulers_online),
    RunQueue / max(1, Schedulers).

%% @private
publish_load(Ewma, Yield) ->
    _ = ensure_table(?LOAD_TAB),
    ets:insert(?LOAD_TAB, {state, Ewma, Yield}),
    ok.

%% @private
%% Whether the current tick's published decision is to yield. Read by the
%% per-instance dispatch. Fails open (no yield) before the cell exists or if
%% the scheduler has not ticked — AAE is never blocked by missing load info.
load_yielding() ->
    case ets:info(?LOAD_TAB) of
        undefined ->
            false;
        _ ->
            case ets:lookup(?LOAD_TAB, state) of
                [{state, _Ewma, Yield}] -> Yield;
                [] -> false
            end
    end.

%% @private
%% The last published smoothed load value, for `info/0`. `0.0` before the
%% first tick.
current_load() ->
    case ets:info(?LOAD_TAB) of
        undefined ->
            0.0;
        _ ->
            case ets:lookup(?LOAD_TAB, state) of
                [{state, Ewma, _Yield}] -> Ewma;
                [] -> 0.0
            end
    end.

%% @private
%% Idempotently creates one of the scheduler's named work tables (all share
%% the same `set, public, read+write-concurrency` shape). Tolerates a race on
%% first creation (`badarg`). The named tables are `?RR_TAB`, `?INFLIGHT_TAB`,
%% `?BACKOFF_TAB`, `?LIVE_BACKOFF_TAB`, `?LOAD_TAB`, `?REBOOTSTRAP_TAB`.
ensure_table(Name) ->
    case ets:info(Name) of
        undefined ->
            try
                ets:new(Name, [
                    named_table,
                    set,
                    public,
                    {read_concurrency, true},
                    {write_concurrency, true}
                ])
            catch
                error:badarg -> Name
            end;
        _ ->
            Name
    end.

%% @private
dispatch_for(InstanceId, #state{} = State) ->
    Peers = (State#state.peer_source):peers_for(
        InstanceId, State#state.peer_source_opts
    ),
    case State#state.dispatch of
        undefined ->
            ok;
        Fun when is_function(Fun, 2) ->
            try
                Fun(InstanceId, Peers)
            catch
                K:V:S ->
                    ?LOG_WARNING(#{
                        description => "sync dispatch raised",
                        instance => InstanceId,
                        class => K,
                        reason => V,
                        stacktrace => S
                    }),
                    ok
            end
    end.

%% @private
%% `list_instances/0` calls `info/1` on each running worker — if a
%% worker is mid-restart that call may briefly fail. Soft-fail to an
%% empty list rather than crash the scheduler.
safe_list_instances() ->
    try
        bondy_oplog:list_instances()
    catch
        _:_ -> []
    end.

%% @private
%% Cancels the in-flight `tick` timer (if any) and flushes any pending
%% `tick` message that may already be in the gen_server's mailbox.
%% Used by `set_interval_ms/1` so the new interval starts cleanly
%% without a leftover tick at the old cadence.
cancel_pending_tick(#state{tick_ref = undefined} = State) ->
    State;
cancel_pending_tick(#state{tick_ref = Ref} = State) ->
    _ = erlang:cancel_timer(Ref, [{async, false}, {info, false}]),
    receive
        tick -> ok
    after 0 -> ok
    end,
    State#state{tick_ref = undefined}.

%% @private
schedule_tick(#state{enabled = false} = State) ->
    State#state{tick_ref = undefined};
schedule_tick(#state{interval_ms = 0} = State) ->
    State#state{tick_ref = undefined};
schedule_tick(#state{interval_ms = Ms} = State) ->
    Ref = erlang:send_after(Ms, self(), tick),
    State#state{tick_ref = Ref}.

%% @private
%% Lifecycle-aware dispatch. Pre_bootstrap instances dispatch a single
%% bootstrap session against a peer chosen by the configured
%% `bootstrap_peer_strategy` (see module doc); live instances fan out
%% per-peer pull-direction sync sessions. Errors from the spawn are
%% absorbed by the session process and reported via peer_state / logs;
%% the scheduler does not wait for completion.
default_dispatch(InstanceId, []) ->
    %% Empty peer list this round. `maybe_bump_ae_isolated/1` certifies a
    %% genuine single-node deployment unconditionally (no peer to lag), and
    %% otherwise applies the `db.aae.fence.on_isolation` policy: `refuse`
    %% leaves freshness to decay (the fence refuses); `proceed`/`quorum` may
    %% certify so the node keeps authenticating.
    bondy_oplog_sync_session:maybe_bump_ae_isolated(InstanceId);
default_dispatch(InstanceId, Peers) ->
    case bondy_oplog_instance:lifecycle_state(InstanceId) of
        pre_bootstrap ->
            maybe_dispatch_bootstrap(InstanceId, Peers);
        live ->
            maybe_dispatch_live(InstanceId, Peers);
        undefined ->
            %% Instance is starting up or unknown — no-op for this
            %% tick; the next tick will see the lifecycle once
            %% `init/1` publishes the handle.
            ok
    end.

%% @private
%% Two gates before dispatch:
%%   1. Per-instance backoff (set on previous session failure).
%%   2. Global in-flight cap.
%% Backoff is checked first because an instance in backoff should
%% not count against the cap — other instances still get a slot.
%% Returns `dispatched | skipped` so the re-bootstrap path can tell
%% whether its pending flag was consumed this tick.
maybe_dispatch_bootstrap(InstanceId, Peers) ->
    %% Load gate first (cheapest, node-global): the snapshot ship is the
    %% heaviest AAE operation and a `pre_bootstrap` instance serves no reads
    %% yet, so deferring it for a busy tick costs nothing but convergence
    %% latency. No fence exemption applies — a bootstrapping instance cannot
    %% back the fence (it has no data to bump).
    case load_yielding() of
        true ->
            telemetry:execute(
                [bondy_oplog, sync_scheduler, bootstrap_load_deferred],
                #{run_queue_ratio => current_load()},
                #{instance_id => InstanceId}
            ),
            skipped;
        false ->
            maybe_dispatch_bootstrap_backoff_check(InstanceId, Peers)
    end.

%% @private
maybe_dispatch_bootstrap_backoff_check(InstanceId, Peers) ->
    case backoff_remaining(InstanceId) of
        {Wait, FailCount} when Wait > 0 ->
            telemetry:execute(
                [bondy_oplog, sync_scheduler, bootstrap_backoff_deferred],
                #{wait_ms => Wait, fail_count => FailCount},
                #{instance_id => InstanceId}
            ),
            skipped;
        {_, _} ->
            maybe_dispatch_bootstrap_cap_check(InstanceId, Peers)
    end.

%% @private
%% Two caps gate a bootstrap dispatch, both must have headroom:
%%   1. The node-wide AAE cap (`aae_max_concurrency`) over ALL in-flight
%%      sync sessions (bootstrap + live) — the single operator-facing limit
%%      on "how many concurrent AAE syncs".
%%   2. The narrower bootstrap-only sub-cap (`max_inflight_bootstraps`), for
%%      operators who want to throttle the expensive snapshot ship below the
%%      node-wide cap.
%% Crossing either skips silently; the instance stays `pre_bootstrap` and the
%% next tick retries (advancing the round-robin peer counter as before).
maybe_dispatch_bootstrap_cap_check(InstanceId, Peers) ->
    BootCap = bondy_oplog_config:max_inflight_bootstraps(),
    NodeCap = bondy_oplog_config:aae_max_concurrency(),
    BootCount = inflight_bootstrap_count(),
    Total = inflight_count(),
    case BootCount >= BootCap orelse Total >= NodeCap of
        true ->
            telemetry:execute(
                [bondy_oplog, sync_scheduler, bootstrap_capped],
                #{
                    current => BootCount,
                    cap => BootCap,
                    node_current => Total,
                    node_cap => NodeCap
                },
                #{instance_id => InstanceId}
            ),
            skipped;
        false ->
            Strategy = bondy_oplog_config:bootstrap_peer_strategy(),
            Peer = pick_bootstrap_peer(Strategy, InstanceId, Peers),
            dispatch_bootstrap(InstanceId, Peer, Strategy),
            dispatched
    end.

%% @private
dispatch_bootstrap(InstanceId, Peer, Strategy) ->
    Mode =
        case bondy_oplog_instance:crdt_module(InstanceId) of
            undefined -> catalogue;
            _ -> single_crdt
        end,
    telemetry:execute(
        [bondy_oplog, sync_scheduler, dispatch_bootstrap],
        #{count => 1},
        #{
            instance_id => InstanceId,
            peer => Peer,
            mode => Mode,
            strategy => Strategy
        }
    ),
    SessionOpts = session_opts(),
    {ok, Pid} =
        case Mode of
            catalogue ->
                bondy_oplog_sync_session:start_bootstrap_catalogue(
                    InstanceId, Peer, SessionOpts
                );
            single_crdt ->
                bondy_oplog_sync_session:start_bootstrap(
                    InstanceId, Peer, SessionOpts
                )
        end,
    track_inflight(Pid, InstanceId),
    ok.

%% @private
%% Inserts the spawned session pid into the in-flight table and
%% monitors it so DOWN messages reach the scheduler gen_server's
%% mailbox. Safe to call from outside the gen_server (e.g. tests):
%% in that case the monitor is owned by the caller and the DOWN goes
%% to the caller's mailbox instead. Production calls happen inside
%% the gen_server's `run_tick/1` so the DOWN reaches the scheduler.
track_inflight(Pid, InstanceId) ->
    _ = ensure_table(?INFLIGHT_TAB),
    _ = erlang:monitor(process, Pid),
    ets:insert(
        ?INFLIGHT_TAB, {Pid, InstanceId, bootstrap, undefined, now_ms()}
    ),
    telemetry:execute(
        [bondy_oplog, sync_scheduler, bootstrap, started],
        #{current => inflight_bootstrap_count()},
        #{instance_id => InstanceId, pid => Pid}
    ),
    ok.

%% @private
%% Strategy-driven peer selection for pre_bootstrap dispatch. The
%% round-robin counter is held in a small named ETS table created in
%% `init/1`; on a cold call (e.g. unit-testing the function in
%% isolation) the table is created lazily.
pick_bootstrap_peer(first, _InstanceId, [P | _]) ->
    P;
pick_bootstrap_peer(random, _InstanceId, Peers) ->
    lists:nth(rand:uniform(length(Peers)), Peers);
pick_bootstrap_peer(round_robin, InstanceId, Peers) ->
    _ = ensure_table(?RR_TAB),
    N = length(Peers),
    %% update_counter creates the entry on first hit. Returns the new
    %% value, so first call yields 1 → nth(1, Peers).
    Idx = ets:update_counter(
        ?RR_TAB, InstanceId, {2, 1}, {InstanceId, 0}
    ),
    lists:nth(((Idx - 1) rem N) + 1, Peers);
pick_bootstrap_peer(_UnknownStrategy, _InstanceId, [P | _]) ->
    P.

%% @private
%% Total in-flight sync sessions (bootstrap + live) — the quantity the
%% node-wide AAE concurrency cap governs.
inflight_count() ->
    case ets:info(?INFLIGHT_TAB, size) of
        undefined -> 0;
        N -> N
    end.

%% @private
%% True once the total in-flight session count has reached the node-wide
%% AAE concurrency cap (`aae_max_concurrency`). Read fresh per dispatch so
%% the cap holds across instances within a single (sequential) tick.
at_node_cap() ->
    inflight_count() >= bondy_oplog_config:aae_max_concurrency().

%% @private
%% In-flight count restricted to bootstrap sessions, for the narrower
%% `max_inflight_bootstraps` sub-cap and `info/0` reporting.
inflight_bootstrap_count() ->
    select_inflight_count({'_', '_', bootstrap, '_', '_'}).

%% @private
%% Whether a live session is already running for this exact (instance,
%% peer) pair — the per-peer dedup on the live fan-out.
pair_inflight(InstanceId, Peer) ->
    select_inflight_count({'_', InstanceId, live, Peer, '_'}) > 0.

%% @private
%% Counts in-flight entries matching `Pattern` via a match spec (never
%% `tab2list/1` + `filter`). Soft-fails to 0 before the table exists.
select_inflight_count(Pattern) ->
    case ets:info(?INFLIGHT_TAB, size) of
        undefined -> 0;
        _ -> ets:select_count(?INFLIGHT_TAB, [{Pattern, [], [true]}])
    end.

%% @private
%% On a successful (normal) session exit, clear the entry — the next
%% disruption starts fresh from `base`. On any other exit reason,
%% bump the per-instance failure count and write a new next-retry
%% timestamp. Called from `handle_info({'DOWN', ...})`.
update_backoff(InstanceId, normal) ->
    _ = ensure_table(?BACKOFF_TAB),
    ets:delete(?BACKOFF_TAB, InstanceId),
    ok;
update_backoff(InstanceId, _Reason) ->
    _ = ensure_table(?BACKOFF_TAB),
    Count =
        case ets:lookup(?BACKOFF_TAB, InstanceId) of
            [{InstanceId, _NextMs, N}] -> N + 1;
            [] -> 1
        end,
    Wait = backoff_wait_ms(Count),
    NextMs = now_ms() + Wait,
    ets:insert(?BACKOFF_TAB, {InstanceId, NextMs, Count}),
    telemetry:execute(
        [bondy_oplog, sync_scheduler, bootstrap_retry_scheduled],
        #{wait_ms => Wait, fail_count => Count},
        #{instance_id => InstanceId}
    ),
    ok.

%% @private
%% Returns the wait in ms for failure-count N. Exponential with
%% optional uniform jitter in [0.5, 1.5].
backoff_wait_ms(N) when N >= 1 ->
    Base = bondy_oplog_config:bootstrap_retry_base_ms(),
    Max = bondy_oplog_config:bootstrap_retry_max_ms(),
    %% 2^31 caps the exponent to avoid overflow on adversarial N.
    Exp = min(N - 1, 30),
    Raw = min(Base bsl Exp, Max),
    case bondy_oplog_config:bootstrap_retry_jitter() of
        true ->
            %% uniform float in [0.5, 1.5].
            Factor = 0.5 + rand:uniform(),
            trunc(Raw * Factor);
        false ->
            Raw
    end.

%% @private
now_ms() ->
    erlang:monotonic_time(millisecond).

%% @private
%% Returns 0 if the instance is not under backoff (or the timer has
%% already expired); otherwise the milliseconds until it can retry
%% plus the current fail count.
backoff_remaining(InstanceId) ->
    _ = ensure_table(?BACKOFF_TAB),
    case ets:lookup(?BACKOFF_TAB, InstanceId) of
        [] ->
            {0, 0};
        [{InstanceId, NextMs, Count}] ->
            Remaining = NextMs - now_ms(),
            case Remaining > 0 of
                true -> {Remaining, Count};
                false -> {0, Count}
            end
    end.

%% @private
%% Adaptive live-sync throttle. A converged shard re-syncs only to
%% discover peer-side divergence; once its local root stops moving,
%% polling every peer every tick is pure churn. We dispatch on every
%% tick while the local root is changing (active local write, normal
%% replication, or catch-up pulling data in), and otherwise back the
%% poll cadence off geometrically up to `live_sync_max_ms`. Any local
%% root change — including data pulled in by a prior sync — resets the
%% window to the base interval, so missed replication heals within at
%% most one cap-length window and active divergence stays tick-fast.
%% Bootstrap is unaffected (different lifecycle, its own backoff).
%%
%% The re-bootstrap check comes first — BEFORE the fence exemption: a
%% fence-backing instance whose peer reclaimed pages would otherwise
%% redispatch a doomed live pull every tick. While a re-bootstrap session
%% is in flight nothing else is dispatched for the instance.
maybe_dispatch_live(InstanceId, Peers) ->
    case rebootstrap_state(InstanceId) of
        inflight ->
            ok;
        {pending, Peer} ->
            maybe_dispatch_rebootstrap(InstanceId, Peer, Peers);
        none ->
            do_maybe_dispatch_live(InstanceId, Peers)
    end.

%% @private
do_maybe_dispatch_live(InstanceId, Peers) ->
    case backs_fence(InstanceId) of
        true ->
            %% This instance backs the auth freshness fence — its successful
            %% sync round re-bumps the fence's AE targets
            %% (`bondy_oplog_sync_session:maybe_record/4`), including for a
            %% converged shard, and the fence refuses authentication once a
            %% target goes unconfirmed past `auth_max_lag`. Such an instance
            %% MUST sync every tick; backing it off — or starving it behind
            %% the node-wide cap — would trip the fence on inactivity.
            %% Dispatch exempt from BOTH the throttle and the cap. Its RAM is
            %% still bounded by the per-round page batch (`aae_pages_per_round`),
            %% and fence-backers are few, so the bounded over-budget is
            %% acceptable to keep authentication available.
            dispatch_live_sync(InstanceId, Peers, _Capped = false);
        false ->
            %% Non-fence live shard: gate on node load first (it carries no
            %% fence freshness, so deferring it under load is safe), then the
            %% adaptive throttle. The load check precedes `live_should_dispatch/1`
            %% so a yield tick does not consume the throttle's change-detection
            %% window — the next quiet tick still sees any root movement.
            case load_yielding() of
                true ->
                    telemetry:execute(
                        [bondy_oplog, sync_scheduler, live_load_deferred],
                        #{run_queue_ratio => current_load()},
                        #{instance_id => InstanceId}
                    ),
                    ok;
                false ->
                    ShouldDispatch =
                        not live_adaptive_enabled() orelse
                            live_should_dispatch(InstanceId),
                    case ShouldDispatch of
                        true ->
                            dispatch_live_sync(
                                InstanceId, Peers, _Capped = true
                            );
                        false ->
                            ok
                    end
            end
    end.

%% @private
%% An instance "backs the fence" when it carries AE freshness targets
%% (set once at init via `bondy_oplog_registry:set_ae_targets/2`): a
%% successful AE round freshens those targets, and the read-side auth
%% fence depends on that bump landing within `auth_max_lag`. Throttling
%% such an instance would starve the bump and trip the fence, so it is
%% never throttled. An instance with no targets cannot affect the fence
%% (the bump is a strict no-op there), so throttling it is safe. On any
%% lookup error we fail safe — treat it as fence-backing (do not
%% throttle).
backs_fence(InstanceId) ->
    case catch bondy_oplog_registry:ae_targets(InstanceId) of
        L when is_list(L) -> L =/= [];
        _ -> true
    end.

%% @private
%% Flags a live instance for snapshot re-bootstrap when its sync session
%% died on the terminal `peer_pages_unavailable` reason (the peer reclaimed
%% pages we still need — see the module doc). Any other exit reason is the
%% self-healing kind and leaves no state. Called from
%% `handle_info({'DOWN', ...})` for `live` sessions only.
maybe_flag_rebootstrap(
    InstanceId, Peer, {sync_failed, {peer_pages_unavailable, _}}
) ->
    _ = ensure_table(?REBOOTSTRAP_TAB),
    ets:insert(?REBOOTSTRAP_TAB, {InstanceId, Peer}),
    telemetry:execute(
        [bondy_oplog, sync_scheduler, rebootstrap_scheduled],
        #{count => 1},
        #{instance_id => InstanceId, peer => Peer}
    ),
    ?LOG_WARNING(#{
        description =>
            "Peer can no longer serve pages this replica needs (it "
            "reclaimed them); scheduling a snapshot re-bootstrap.",
        instance => InstanceId,
        peer => Peer
    }),
    ok;
maybe_flag_rebootstrap(
    InstanceId, Peer, {sync_failed, {frontier_gap, Origins}}
) ->
    %% The instance completed a full round yet is still behind the peer's
    %% applied frontier: the missing events were compacted away at the
    %% peer — by `mst_retention` policy, or by the durable
    %% recency-filtered frontier advancing past this replica while it was
    %% silent past `peer_timeout_ms` — and can never arrive by page-sync.
    %% Same remedy as `peer_pages_unavailable` — a catalogue re-bootstrap
    %% supplies both the data (projection stream) and the frontier
    %% (finalize adoption). This is ALSO the organic join-time trigger (a
    %% fresh replica's first sync against a truncating cluster lands
    %% here) and the stale-peer rejoin path (the recovery half of the
    %% recency filter's liveness trade).
    %%
    %% TWO-STRIKE debounce — see `?GAP_STRIKE_WINDOW_MS` for the full
    %% rationale (deterministic core + residual rare transient on fused
    %% catalogue instances under churn). (If per-origin frontier
    %% RETIREMENT is ever introduced — VVs never shrink today — retired
    %% origins must also be excluded from the deficit, or every reap
    %% becomes a permanent false gap.)
    _ = ensure_table(?GAP_STRIKE_TAB),
    Now = erlang:monotonic_time(millisecond),
    Key = {InstanceId, Peer},
    Repeat =
        case ets:lookup(?GAP_STRIKE_TAB, Key) of
            [{Key, T0}] when Now - T0 =< ?GAP_STRIKE_WINDOW_MS -> true;
            _ -> false
        end,
    case Repeat of
        false ->
            true = ets:insert(?GAP_STRIKE_TAB, {Key, Now}),
            ok;
        true ->
            true = ets:delete(?GAP_STRIKE_TAB, Key),
            %% The remedy applies UNIFORMLY — applier-backed durable,
            %% retention-fused, and fused-at-defaults alike. The old
            %% fused-without-retention carve-out (standing-gap WARNING
            %% instead of the remedy) guarded against a corruption class
            %% that predated the watermark door: with never-applied
            %% events silently discarded at integrate, a peer snapshot
            %% could genuinely lack ops this replica had folded and then
            %% compacted, and the post-install rederive could not restore
            %% them. Post-door that argument closed: a live fused
            %% re-bootstrap is sound because (a) the install runs in the
            %% instance gen_server itself — atomic w.r.t. the fused
            %% drain, no mid-install interleaving; (b) every op the
            %% replace-mode install can clobber is either peer-confirmed
            %% (a fused peer folds at integrate BEFORE its root is
            %% confirmable, so the op is IN the snapshot) or still
            %% retained in the local MST (peer-confirmed compaction
            %% cannot have truncated it), where the post-bootstrap
            %% rederive (`bondy_oplog_instance:rederive_projection/1`)
            %% restores it; and (c) `finalize_catalogue_bootstrap` does
            %% not truncate the MST, so unshared local-origin events
            %% survive for peers to pull. Under `mst_retention` the
            %% retained-window limit on (b) is the documented residual
            %% trade of that policy.
            _ = ensure_table(?REBOOTSTRAP_TAB),
            ets:insert(?REBOOTSTRAP_TAB, {InstanceId, Peer}),
            telemetry:execute(
                [bondy_oplog, sync_scheduler, rebootstrap_scheduled],
                #{count => 1},
                #{
                    instance_id => InstanceId,
                    peer => Peer,
                    reason => frontier_gap
                }
            ),
            ?LOG_INFO(#{
                description =>
                    "Peer's applied frontier is ahead of ours "
                    "after a complete sync round, twice in a row "
                    "(it compacted history we never received); "
                    "scheduling a catalogue re-bootstrap.",
                instance => InstanceId,
                peer => Peer,
                origins_behind => Origins
            }),
            ok
    end;
maybe_flag_rebootstrap(
    InstanceId, Peer, {sync_failed, {root_unservable_behind, Origins}}
) ->
    %% The peer's responder refuses to serve its root (dangling pages)
    %% AND its applied frontier is strictly ahead of ours — the session
    %% established both (see `maybe_unservable_behind/3`). Transient
    %% unservability (the truncate/GC race the responder guard was built
    %% for) clears within a round, so require ?UNSERVABLE_STRIKES
    %% CONSECUTIVE strikes inside the gap-strike window before treating
    %% it as the permanent form (own-root pages lost — Fly s16) and
    %% escalating to the same catalogue re-bootstrap the frontier-gap
    %% path uses: the peer's snapshot producer reads its PROJECTION,
    %% which stays complete and servable when its MST is not. Without
    %% this clause the pair deadlocks: every round errors, no round
    %% completes, the gap verdict never fires, and the peer's surplus
    %% stays unreachable forever.
    _ = ensure_table(?GAP_STRIKE_TAB),
    Now = erlang:monotonic_time(millisecond),
    Key = {unservable, InstanceId, Peer},
    Count =
        case ets:lookup(?GAP_STRIKE_TAB, Key) of
            [{Key, N, T0}] when Now - T0 =< ?GAP_STRIKE_WINDOW_MS -> N + 1;
            _ -> 1
        end,
    case Count >= ?UNSERVABLE_STRIKES of
        false ->
            true = ets:insert(?GAP_STRIKE_TAB, {Key, Count, Now}),
            ok;
        true ->
            true = ets:delete(?GAP_STRIKE_TAB, Key),
            _ = ensure_table(?REBOOTSTRAP_TAB),
            ets:insert(?REBOOTSTRAP_TAB, {InstanceId, Peer}),
            telemetry:execute(
                [bondy_oplog, sync_scheduler, rebootstrap_scheduled],
                #{count => 1},
                #{
                    instance_id => InstanceId,
                    peer => Peer,
                    reason => root_unservable
                }
            ),
            ?LOG_WARNING(#{
                description =>
                    "Peer cannot serve its MST root (dangling pages) "
                    "while its applied frontier is ahead of ours, "
                    "persistently; scheduling a catalogue re-bootstrap "
                    "to recover its surplus from its projection.",
                instance => InstanceId,
                peer => Peer,
                origins_behind => Origins
            }),
            ok
    end;
maybe_flag_rebootstrap(InstanceId, Peer, normal) ->
    %% A successful round proves there is no standing gap against this
    %% peer — clear any single strike so an unrelated transient later
    %% starts a fresh count. Same for unservable strikes: a round that
    %% completed means the peer's root served fine.
    _ = ensure_table(?GAP_STRIKE_TAB),
    _ = ets:delete(?GAP_STRIKE_TAB, {InstanceId, Peer}),
    _ = ets:delete(?GAP_STRIKE_TAB, {unservable, InstanceId, Peer}),
    ok;
maybe_flag_rebootstrap(_InstanceId, _Peer, _Reason) ->
    ok.

%% @private
%% The re-bootstrap disposition for a live instance this tick:
%%   - `inflight`         — a bootstrap session for it is already running;
%%                          dispatch nothing (live pulls would fail with the
%%                          same terminal reason and waste cap slots).
%%   - `{pending, Peer}`  — flagged by a prior `peer_pages_unavailable`
%%                          exit; dispatch a re-bootstrap instead of live
%%                          syncs. `Peer` is the one that reported the
%%                          unavailability.
%%   - `none`             — the normal live path.
rebootstrap_state(InstanceId) ->
    _ = ensure_table(?REBOOTSTRAP_TAB),
    case select_inflight_count({'_', InstanceId, bootstrap, '_', '_'}) > 0 of
        true ->
            inflight;
        false ->
            case ets:lookup(?REBOOTSTRAP_TAB, InstanceId) of
                [{InstanceId, Peer}] -> {pending, Peer};
                [] -> none
            end
    end.

%% @private
%% Dispatches the re-bootstrap through the SAME gate chain as a
%% `pre_bootstrap` dispatch (load yield → retry backoff → both caps), so a
%% re-bootstrapping live instance competes for slots and paces retries
%% exactly like any other bootstrap. The flagging peer is offered first —
%% having reclaimed the pages, it certifiably holds a covering snapshot —
%% but any member's snapshot covers them (reclamation requires all-member
%% confirmation), so the rest of the peer list stays as fallback for the
%% configured strategy. The pending flag is consumed only when a session
%% actually dispatches; a gated tick retries.
maybe_dispatch_rebootstrap(InstanceId, Peer, Peers) ->
    Candidates =
        case lists:member(Peer, Peers) of
            true -> [Peer | lists:delete(Peer, Peers)];
            false -> Peers
        end,
    case maybe_dispatch_bootstrap(InstanceId, Candidates) of
        dispatched ->
            true = ets:delete(?REBOOTSTRAP_TAB, InstanceId),
            ok;
        skipped ->
            ok
    end.

%% @private
%% Decides whether this tick dispatches a live sync for the instance and
%% records the decision in `?LIVE_BACKOFF_TAB`:
%%     {InstanceId, LastRoot, NextDueMs, WindowMs}
%%   - First sight, or the local root changed since last sight → dispatch
%%     now and reset the window to the base interval (activity).
%%   - Root unchanged and the window has not elapsed → skip.
%%   - Root unchanged and the window has elapsed → dispatch a poll (to
%%     detect peer-side divergence) and grow the window (×2, capped).
live_should_dispatch(InstanceId) ->
    _ = ensure_table(?LIVE_BACKOFF_TAB),
    live_decide(
        InstanceId,
        current_root(InstanceId),
        now_ms(),
        live_sync_base_ms(),
        live_sync_max_ms()
    ).

%% @private
%% The live-sync backoff state machine, factored out of clock and
%% root-reading so it is deterministically unit-testable. Reads/writes
%% `?LIVE_BACKOFF_TAB` keyed by instance:
%%     {InstanceId, LastRoot, NextDueMs, WindowMs}
live_decide(InstanceId, Root, Now, Base, Max) ->
    case ets:lookup(?LIVE_BACKOFF_TAB, InstanceId) of
        [] ->
            ets:insert(
                ?LIVE_BACKOFF_TAB, {InstanceId, Root, Now + Base, Base}
            ),
            true;
        [{InstanceId, LastRoot, _Due, _Window}] when Root =/= LastRoot ->
            %% Activity → reset to the fast cadence.
            ets:insert(
                ?LIVE_BACKOFF_TAB, {InstanceId, Root, Now + Base, Base}
            ),
            true;
        [{InstanceId, _Root, Due, Window}] when Now >= Due ->
            %% Quiescent, poll window elapsed → poll + grow the window.
            NextWindow = min(Window * 2, max(Base, Max)),
            ets:insert(
                ?LIVE_BACKOFF_TAB,
                {InstanceId, Root, Now + NextWindow, NextWindow}
            ),
            telemetry:execute(
                [bondy_oplog, sync_scheduler, live_sync_poll],
                #{window_ms => NextWindow},
                #{instance_id => InstanceId}
            ),
            true;
        [{InstanceId, _Root, _Due, _Window}] ->
            %% Quiescent, within window → skip (the churn we are cutting).
            telemetry:execute(
                [bondy_oplog, sync_scheduler, live_sync_skipped],
                #{count => 1},
                #{instance_id => InstanceId}
            ),
            false
    end.

%% @private
%% The instance's in-memory MST root, used purely as a change detector
%% for the throttle. Soft-fails to `undefined` (treated as "no change"
%% against a prior `undefined`) if the instance is mid-restart.
current_root(InstanceId) ->
    try
        bondy_oplog_instance:root_hash(InstanceId)
    catch
        _:_ -> undefined
    end.

%% @private
live_adaptive_enabled() ->
    bondy_oplog_config:live_sync_adaptive().

%% @private
%% Base poll interval; defaults to the tick interval so an active shard
%% syncs every tick exactly as before.
live_sync_base_ms() ->
    bondy_oplog_config:live_sync_base_ms().

%% @private
live_sync_max_ms() ->
    bondy_oplog_config:live_sync_max_ms().

%% @private
%% Fans out a live pull-direction sync, one session per peer. Each peer is
%% gated independently:
%%   - A live session already in flight for this exact (instance, peer) is
%%     skipped, so a slow (bulk-syncing) shard never stacks duplicate
%%     sessions on the same peer.
%%   - When `Capped` (non-fence-backers), a peer is skipped once the
%%     node-wide AAE concurrency cap (`aae_max_concurrency`) is reached;
%%     the throttle/rotation re-offers it on a later tick. This is the cap
%%     that bounds bulk-sync RAM: at most `aae_max_concurrency` live
%%     page-pulls run at once, each bounded to `aae_pages_per_round`
%%     (= node page budget ÷ this cap), so the node-wide peak ≈ the budget
%%     regardless of shard count.
%% Spawned sessions are tracked + monitored so they count against the cap
%% and are cleaned up on exit (see `handle_info({'DOWN', ...})`).
dispatch_live_sync(InstanceId, Peers, Capped) ->
    SessionOpts = session_opts(),
    lists:foreach(
        fun(Peer) ->
            maybe_start_live(InstanceId, Peer, SessionOpts, Capped)
        end,
        Peers
    ).

%% @private
maybe_start_live(InstanceId, Peer, SessionOpts, Capped) ->
    case pair_inflight(InstanceId, Peer) of
        true ->
            ok;
        false ->
            case Capped andalso at_node_cap() of
                true ->
                    telemetry:execute(
                        [bondy_oplog, sync_scheduler, live_capped],
                        #{
                            current => inflight_count(),
                            cap => bondy_oplog_config:aae_max_concurrency()
                        },
                        #{instance_id => InstanceId, peer => Peer}
                    ),
                    ok;
                false ->
                    {ok, Pid} = bondy_oplog_sync_session:start(
                        InstanceId, Peer, SessionOpts
                    ),
                    track_live(Pid, InstanceId, Peer)
            end
    end.

%% @private
%% Inserts a spawned live session into the in-flight table and monitors it,
%% so it counts against the node-wide cap and is cleaned up on exit. As with
%% `track_inflight/2`, when called from outside the gen_server (tests) the
%% monitor and its DOWN are owned by the caller.
track_live(Pid, InstanceId, Peer) ->
    _ = ensure_table(?INFLIGHT_TAB),
    _ = erlang:monitor(process, Pid),
    ets:insert(?INFLIGHT_TAB, {Pid, InstanceId, live, Peer, now_ms()}),
    telemetry:execute(
        [bondy_oplog, sync_scheduler, live, started],
        #{current => inflight_count()},
        #{instance_id => InstanceId, peer => Peer, pid => Pid}
    ),
    ok.

%% @private
%% Session opts threaded into every dispatched bootstrap / live-sync
%% session, read from app env each tick so a runtime change is picked up
%% on the next round. The default `#{}` keeps the historical behaviour:
%% the session falls back to `bondy_oplog_transport_inline`. A clustered
%% deployment sets `#{transport => bondy_oplog_transport_partisan,
%% transport_opts => #{channel => ...}}` here (see `bondy_app`).
session_opts() ->
    bondy_oplog_config:sync_session_opts().
