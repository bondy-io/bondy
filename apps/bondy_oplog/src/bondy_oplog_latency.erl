%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_latency).

-behaviour(gen_server).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-instance **write→readable latency** telemetry: the wall-clock time
from a user write (`bondy_db:apply/4` and friends) until that value is
committed and readable in the projection — for whichever backend the
instance uses (leveled or the ETS memory topology).

## How it is measured

The whole write path is synchronous: `bondy_db:apply/4` appends to the
WAL and then blocks in `bondy_oplog:await_apply/1`, which returns only
once the applier has committed the cell to the projection (the
read-your-writes guarantee). So the elapsed time across that call *is*
the local write→readable latency. `bondy_db` samples it on the hot path
and feeds it here via `record/2` — two `monotonic_time` reads plus one
wait-free `bondy_metrics:histogram/1` observation per write. When
disabled (`enabled/0` is a `persistent_term` read, set once at boot),
the hot path pays only that one free read and captures nothing.

Scope is the **local origin node**: write→readable on the node that took
the write. Cross-node "readable on a replica" latency is intentionally
out of scope (monotonic clocks are not comparable across VMs).

## Storage and aggregation

Samples accumulate in a `bondy_metrics` histogram per instance
(`name = ?METRIC`, `label = #{instance_id => Id}`) — a wait-free,
fixed-bucket `counters` array. On a periodic tick this gen_server reads
each instance's cumulative snapshot, subtracts the previous tick
(`bondy_metrics:histogram_delta/2`), and emits one event per instance
that saw writes in the window:

```
[bondy_oplog, instance, write_latency]
measurements: #{count, mean_us, p50_us, p95_us, p99_us, max_us}
metadata:     #{instance_id, interval_ms}
```

Percentiles are nearest-rank estimates from the bucket bounds
(bounded relative error); `mean_us` is exact. Instances that took no
writes in the window emit nothing.

## Idle probe (opt-in)

An instance with no real traffic in a window reports nothing. When the
idle probe is on, each tick writes one benign reserved-cell op
(`bondy_db:probe_write/1`) to every such instance, so it still reports a
heartbeat latency on the next tick. The op is type-correct for the
instance's CRDT and overwrites a single reserved cell (bounded state) in
a bucket no user query targets. It is a **real, replicated** write — fine
for the occasional heartbeat of an idle instance, which is why it is
off by default. See `set_probe_enabled/1`.

## Configuration

```erlang
{bondy_mst, [
    {oplog_latency, #{
        enabled => true,             %% default: true (sampling is ~free)
        interval_ms => 10000,        %% default: 10s reporting window
        probe => #{enabled => false} %% default: idle probe off
    }}
]}.
```

`enabled => false` makes `record/2` a no-op on the hot path and
suppresses the emit; existing histograms simply stop accumulating.
`interval_ms => 0` (or `disabled`) keeps the server up but suppresses
the periodic emit (samples still accumulate; force one with
`snapshot_now/0`).
""").

-define(SERVER, ?MODULE).
-define(METRIC, bondy_oplog_write_readable_latency_us).
-define(PT_ENABLED, {?MODULE, enabled}).
-define(EVENT, [bondy_oplog, instance, write_latency]).

-record(state, {
    enabled :: boolean(),
    %% Idle probe: when true, instances that saw no writes in a window get
    %% one synthetic reserved-cell write so they still report a heartbeat
    %% latency. Opt-in (default false) — it is a real replicated write.
    probe_enabled :: boolean(),
    interval_ms :: non_neg_integer(),
    tick_ref :: undefined | reference(),
    last_tick_ts :: integer(),
    %% Per-instance previous cumulative snapshot for delta reporting.
    snapshot :: #{binary() => bondy_metrics:histogram()}
}).

-export([child_spec/0, child_spec/1]).
-export([start_link/0, start_link/1]).
-export([record/2]).
-export([enabled/0]).
-export([metric_name/0]).
-export([info/0]).
-export([snapshot_now/0]).
-export([set_enabled/1]).
-export([set_probe_enabled/1]).

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
    child_spec(#{}).

child_spec(Opts) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    start_link(#{}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

?DOC("""
Record one write→readable sample (microseconds) for an instance.
Best-effort and wait-free: a single `bondy_metrics:histogram/1`
observation. Never raises on the caller (telemetry must not crash the
write path). Callers gate on `enabled/0` first so a disabled probe pays
no `monotonic_time` reads.
""").
-spec record(binary(), integer()) -> ok.

record(InstanceId, LatencyUs) when
    is_binary(InstanceId), is_integer(LatencyUs)
->
    try
        _ = bondy_metrics:histogram(#{
            name => ?METRIC,
            label => #{instance_id => InstanceId},
            value => LatencyUs
        }),
        ok
    catch
        _:_ -> ok
    end;
record(_, _) ->
    ok.

?DOC("""
Whether write→readable sampling is enabled. A `persistent_term` read
(free): set once at boot and only on an explicit `set_enabled/1`.
Callers on the hot path gate on this before timing a write.
""").
-spec enabled() -> boolean().

enabled() ->
    persistent_term:get(?PT_ENABLED, false).

?DOC("""
The `bondy_metrics` histogram name under which per-instance samples are
stored (label `#{instance_id => Id}`). Exposed for exposition/tests.
""").
-spec metric_name() -> atom().

metric_name() ->
    ?METRIC.

?DOC("""
Current configuration and the instances seen in the last snapshot.
""").
-spec info() -> map().

info() ->
    gen_server:call(?SERVER, info).

?DOC("""
Force an immediate latency emit for every instance that saw writes
since the last tick. Test/operator affordance.
""").
-spec snapshot_now() -> ok.

snapshot_now() ->
    gen_server:call(?SERVER, snapshot_now).

?DOC("""
Enable or disable sampling at runtime. Disabling makes `record/2` a
no-op on the hot path and cancels the periodic emit; accumulated
histograms are left in place.
""").
-spec set_enabled(boolean()) -> ok.

set_enabled(Enabled) when is_boolean(Enabled) ->
    gen_server:call(?SERVER, {set_enabled, Enabled}).

?DOC("""
Enable or disable the **idle probe** at runtime. When on, the periodic
tick writes one benign reserved-cell op (`bondy_db:probe_write/1`) to
each instance that saw no writes in the window, so idle instances still
report a heartbeat latency. Opt-in — it is a real replicated write.
Requires sampling (`set_enabled(true)`) to be on to record anything.
""").
-spec set_probe_enabled(boolean()) -> ok.

set_probe_enabled(Enabled) when is_boolean(Enabled) ->
    gen_server:call(?SERVER, {set_probe_enabled, Enabled}).

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    {Enabled, IntervalMs, ProbeEnabled} = resolve_config(Opts),
    ok = persistent_term:put(?PT_ENABLED, Enabled),
    State = #state{
        enabled = Enabled,
        probe_enabled = ProbeEnabled,
        interval_ms = IntervalMs,
        last_tick_ts = erlang:monotonic_time(millisecond),
        snapshot = #{}
    },
    {ok, schedule_tick(State)}.

handle_call(info, _From, State) ->
    Reply = #{
        enabled => State#state.enabled,
        probe_enabled => State#state.probe_enabled,
        interval_ms => State#state.interval_ms,
        metric => ?METRIC,
        instances => lists:sort(maps:keys(State#state.snapshot))
    },
    {reply, Reply, State};
handle_call({set_probe_enabled, P}, _From, State) ->
    {reply, ok, State#state{probe_enabled = P}};
handle_call(snapshot_now, _From, State) ->
    {reply, ok, run_tick(State)};
handle_call({set_enabled, Enabled}, _From, State0) ->
    ok = persistent_term:put(?PT_ENABLED, Enabled),
    State1 = cancel_pending_tick(State0),
    {reply, ok, schedule_tick(State1#state{enabled = Enabled})};
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    {noreply, schedule_tick(run_tick(State))};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    %% Close the hot-path gate so in-flight writers stop sampling into a
    %% histogram whose owner (bondy_metrics) may also be going down.
    _ = persistent_term:put(?PT_ENABLED, false),
    ok.

code_change(_, State, _) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

resolve_config(Opts) ->
    Cfg =
        case maps:size(Opts) > 0 of
            true ->
                Opts;
            false ->
                bondy_oplog_config:oplog_latency_opts()
        end,
    Enabled = maps:get(enabled, Cfg, true),
    IntervalMs =
        case maps:get(interval_ms, Cfg, 10000) of
            disabled -> 0;
            N when is_integer(N), N >= 0 -> N;
            _ -> 10000
        end,
    ProbeEnabled =
        case maps:get(probe, Cfg, #{}) of
            #{enabled := P} when is_boolean(P) -> P;
            _ -> false
        end,
    {Enabled, IntervalMs, ProbeEnabled}.

schedule_tick(#state{enabled = false} = State) ->
    State#state{tick_ref = undefined};
schedule_tick(#state{interval_ms = Ms} = State) when Ms > 0 ->
    Ref = erlang:send_after(Ms, self(), tick),
    State#state{tick_ref = Ref};
schedule_tick(#state{} = State) ->
    State#state{tick_ref = undefined}.

cancel_pending_tick(#state{tick_ref = undefined} = State) ->
    State;
cancel_pending_tick(#state{tick_ref = Ref} = State) ->
    _ = erlang:cancel_timer(Ref, [{async, true}, {info, false}]),
    receive
        tick -> ok
    after 0 -> ok
    end,
    State#state{tick_ref = undefined}.

run_tick(#state{snapshot = Prev, last_tick_ts = Tick0} = State) ->
    Now = erlang:monotonic_time(millisecond),
    Window = max(Now - Tick0, 1),
    %% Live instances (the set the histogram labels are reconciled against:
    %% emit for ones that wrote, prune ones that are gone, probe idle ones).
    Live = maps:from_keys(bondy_oplog_registry:list(), true),
    %% Every label registered under the metric is an instance that has
    %% taken at least one write (real or probe) since boot.
    Labels = bondy_metrics:with_name(?METRIC),
    {Snapshot1, Emitted} = lists:foldl(
        fun({Label, _C}, Acc) ->
            process_label(Label, Window, Prev, Live, Acc)
        end,
        {#{}, #{}},
        Labels
    ),
    maybe_probe(
        State#state.enabled andalso State#state.probe_enabled, Live, Emitted
    ),
    State#state{snapshot = Snapshot1, last_tick_ts = Now}.

%% Fold one histogram label: emit its window delta if it wrote, prune it if
%% its instance is gone, otherwise just carry the snapshot. Accumulates the
%% set of instances that emitted (so idle ones can be probed).
process_label(
    #{instance_id := Id} = Label, Window, Prev, Live, {Snap, Emitted}
) ->
    case maps:is_key(Id, Live) of
        false ->
            %% Instance is gone — drop its histogram so it doesn't leak.
            _ = bondy_metrics:delete(#{name => ?METRIC, label => Label}),
            {Snap, Emitted};
        true ->
            case
                bondy_metrics:histogram_snapshot(#{
                    name => ?METRIC, label => Label
                })
            of
                {ok, Cur} ->
                    Prior = maps:get(Id, Prev, empty_snapshot()),
                    Delta = bondy_metrics:histogram_delta(Cur, Prior),
                    case maps:get(count, Delta) of
                        0 ->
                            {Snap#{Id => Cur}, Emitted};
                        _ ->
                            emit(Id, Window, Delta),
                            {Snap#{Id => Cur}, Emitted#{Id => true}}
                    end;
                _ ->
                    {Snap, Emitted}
            end
    end;
process_label(_OtherLabel, _Window, _Prev, _Live, Acc) ->
    %% A label without instance_id is not ours; ignore.
    Acc.

emit(Id, Window, Delta) ->
    #{
        count := Count,
        mean := Mean,
        p50 := P50,
        p95 := P95,
        p99 := P99,
        max := Max
    } = bondy_metrics:histogram_stats(Delta),
    telemetry:execute(
        ?EVENT,
        #{
            count => Count,
            mean_us => Mean,
            p50_us => P50,
            p95_us => P95,
            p99_us => P99,
            max_us => Max
        },
        #{instance_id => Id, interval_ms => Window}
    ).

%% Idle probe: instances that did NOT emit this window get one synthetic
%% reserved-cell write so they report a heartbeat next window. Spawned (not
%% inline) so a probe's synchronous await never blocks the emitter.
maybe_probe(false, _Live, _Emitted) ->
    ok;
maybe_probe(true, Live, Emitted) ->
    Idle = [Id || Id <- maps:keys(Live), not maps:is_key(Id, Emitted)],
    lists:foreach(fun spawn_probe/1, Idle).

spawn_probe(InstanceId) ->
    _ = spawn(fun() -> run_probe(InstanceId) end),
    ok.

run_probe(InstanceId) ->
    case probe_mfa() of
        undefined ->
            ok;
        {Mod, Fun} ->
            T0 = erlang:monotonic_time(microsecond),
            try Mod:Fun(InstanceId) of
                ok ->
                    record(InstanceId, erlang:monotonic_time(microsecond) - T0);
                _ ->
                    ok
            catch
                _:_ -> ok
            end
    end.

%% @private
%% The synthetic idle-probe write is supplied by the consumer layer
%% (`bondy_db`), which registers itself at start via
%% `application:set_env(bondy_oplog, latency_probe, {bondy_db, probe_write})`.
%% Defaults to `undefined` (probing disabled), so `bondy_oplog` carries no
%% upward dependency on `bondy_db`.
probe_mfa() ->
    bondy_oplog_config:latency_probe().

empty_snapshot() ->
    #{count => 0, sum => 0, buckets => []}.
