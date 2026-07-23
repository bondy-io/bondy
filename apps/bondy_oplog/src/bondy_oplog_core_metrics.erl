%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_core_metrics).

-behaviour(gen_server).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-namespace gauge emitter for the `bondy_oplog_core` substrate.

Subscribes to the substrate's one-shot events (`[bondy_oplog_core, read]`,
`[bondy_oplog_core, range]`) and accumulates per-namespace counters through
`bondy_metrics` (atomics-backed, wait-free). On a periodic tick the
gen_server reads the running totals, computes deltas against the
previous tick, and emits a single `[bondy_oplog_core, metrics, refresh]`
event per known namespace with the following gauges:

```
measurements: #{
    cache_hit_rate,                %% [0.0, 1.0]; `undefined` when no reads in window
    read_rps,                      %% reads/second over the last interval
    range_rps,                     %% ranges/second over the last interval
    subscriber_count,              %% live subscriptions for the NS at tick time
    current_freshness_lag_max_ms   %% max(Now - last_ae_at) over the NS's shards
}
metadata: #{namespace, interval_ms}
```

## Counter storage

`bondy_metrics` owns the atomics. This module just records observations
through the public counter API:

| Metric name                         | Label             |
|---|---|
| `bondy_oplog_core_reads_total`          | `#{namespace}`    |
| `bondy_oplog_core_ranges_total`         | `#{namespace}`    |
| `bondy_oplog_core_cache_hits_total`     | `#{namespace}`    |
| `bondy_oplog_core_cache_misses_total`   | `#{namespace}`    |

No ETS write contention on the hot path: each event is a single
`counters:add/3` against the namespace's atomics array.

## Configuration

```erlang
{bondy_mst, [
    {metrics, #{interval_ms => 1000}}    %% default: 1000ms
]}.
```

`interval_ms => disabled` (or `0`) keeps the gen_server running and the
telemetry handlers attached — the counters keep accumulating so a
consumer reading via `bondy_metrics:value/1` always sees the running
totals — but suppresses the periodic gauge emit.

## Restart semantics

The atomics arrays are owned by `bondy_metrics`. A restart of *this*
module re-attaches the telemetry handlers and resets the in-process
last-tick snapshot; the underlying counter totals are preserved across
the restart. A restart of `bondy_metrics` wipes the counters.
""").

-define(SERVER, ?MODULE).
-define(HANDLER_ID, ?MODULE).

-define(M_READS, bondy_oplog_core_reads_total).
-define(M_RANGES, bondy_oplog_core_ranges_total).
-define(M_CACHE_HITS, bondy_oplog_core_cache_hits_total).
-define(M_CACHE_MISSES, bondy_oplog_core_cache_misses_total).

-record(state, {
    enabled :: boolean(),
    interval_ms :: non_neg_integer(),
    tick_ref :: undefined | reference(),
    %% Monotonic-ms timestamp of the previous tick. Used as the default
    %% baseline for any namespace first seen on this tick so the very
    %% first window is bounded by "time since last tick" rather than
    %% clamping to 1ms.
    last_tick_ts :: integer(),
    %% Snapshot of {Reads, Ranges, Hits, Misses, MonoMs} at last tick.
    snapshot :: #{
        atom() => {
            non_neg_integer(),
            non_neg_integer(),
            non_neg_integer(),
            non_neg_integer(),
            integer()
        }
    }
}).

-export([child_spec/0, child_spec/1]).
-export([start_link/0, start_link/1]).
-export([info/0]).
-export([snapshot_now/0]).
-export([set_enabled/1]).

%% Telemetry handler callback.
-export([handle_event/4]).

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
Current configuration and the namespaces tracked in the last snapshot.
""").
-spec info() -> map().

info() ->
    gen_server:call(?SERVER, info).

?DOC("""
Force an immediate gauge emit for every known namespace; otherwise the
tick fires every `interval_ms`. Useful in tests and for manual probes.
""").
-spec snapshot_now() -> ok.

snapshot_now() ->
    gen_server:call(?SERVER, snapshot_now).

?DOC("""
Enable or disable the periodic gauge emit at runtime. Disabling cancels
any pending tick; enabling re-arms the timer. Counter accumulation is
unaffected — callers can still observe totals via `bondy_metrics:value/1`
or force an emit with `snapshot_now/0`.

Operator and test affordance; not part of any consumer API.
""").
-spec set_enabled(boolean()) -> ok.

set_enabled(Enabled) when is_boolean(Enabled) ->
    gen_server:call(?SERVER, {set_enabled, Enabled}).

%% =============================================================================
%% Telemetry handler
%% =============================================================================

handle_event([bondy_oplog_core, read], #{hit := Hit}, #{namespace := NS}, _Cfg) ->
    Label = #{namespace => NS},
    ok = bondy_metrics:counter(#{name => ?M_READS, label => Label}),
    case Hit of
        true ->
            bondy_metrics:counter(#{name => ?M_CACHE_HITS, label => Label});
        false ->
            bondy_metrics:counter(#{name => ?M_CACHE_MISSES, label => Label})
    end,
    ok;
handle_event([bondy_oplog_core, range], _Meas, #{namespace := NS}, _Cfg) ->
    ok = bondy_metrics:counter(#{
        name => ?M_RANGES,
        label => #{namespace => NS}
    });
handle_event(_Event, _Meas, _Meta, _Cfg) ->
    ok.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    %% Declare our exposition families where we define and populate them,
    %% so an exporter above us renders them without this app having to
    %% reach up (single source of truth for the family names lives here).
    ok = bondy_metrics:declare(#{
        name => ?M_READS, help => <<"Substrate point reads, by namespace.">>
    }),
    ok = bondy_metrics:declare(#{
        name => ?M_RANGES, help => <<"Substrate range reads, by namespace.">>
    }),
    ok = bondy_metrics:declare(#{
        name => ?M_CACHE_HITS,
        help => <<"Substrate point-read cache hits, by namespace.">>
    }),
    ok = bondy_metrics:declare(#{
        name => ?M_CACHE_MISSES,
        help => <<"Substrate point-read cache misses, by namespace.">>
    }),
    {Enabled, IntervalMs} =
        case resolve_interval(Opts) of
            disabled -> {false, 0};
            N when is_integer(N), N > 0 -> {true, N};
            _ -> {false, 0}
        end,
    ok = telemetry:attach_many(
        ?HANDLER_ID,
        [[bondy_oplog_core, read], [bondy_oplog_core, range]],
        fun ?MODULE:handle_event/4,
        undefined
    ),
    State = #state{
        enabled = Enabled,
        interval_ms = IntervalMs,
        last_tick_ts = erlang:monotonic_time(millisecond),
        snapshot = #{}
    },
    {ok, schedule_tick(State)}.

handle_call(info, _From, State) ->
    Reply = #{
        enabled => State#state.enabled,
        interval_ms => State#state.interval_ms,
        namespaces => lists:sort(maps:keys(State#state.snapshot))
    },
    {reply, Reply, State};
handle_call(snapshot_now, _From, State) ->
    {reply, ok, run_tick(State)};
handle_call({set_enabled, Enabled}, _From, State0) ->
    State1 = cancel_pending_tick(State0),
    State2 = State1#state{enabled = Enabled},
    {reply, ok, schedule_tick(State2)};
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    {noreply, schedule_tick(run_tick(State))};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    _ = telemetry:detach(?HANDLER_ID),
    ok.

code_change(_, State, _) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

resolve_interval(Opts) ->
    case maps:find(interval_ms, Opts) of
        {ok, V} ->
            V;
        error ->
            bondy_oplog_config:metrics_interval_ms()
    end.

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
    %% Flush any tick message already in the mailbox so we don't fire
    %% right after disabling.
    receive
        tick -> ok
    after 0 -> ok
    end,
    State#state{tick_ref = undefined}.

run_tick(#state{} = State0) ->
    Now = erlang:monotonic_time(millisecond),
    %% Union of: namespaces with any counter activity AND namespaces
    %% registered with the substrate. The latter ensures we still emit
    %% freshness-lag gauges for idle namespaces.
    NSs = lists:usort(
        counter_namespaces() ++ safe_namespaces()
    ),
    Snapshot1 = lists:foldl(
        fun(NS, Acc) -> emit_namespace_gauges(NS, Now, State0, Acc) end,
        #{},
        NSs
    ),
    State0#state{snapshot = Snapshot1, last_tick_ts = Now}.

emit_namespace_gauges(
    NS,
    Now,
    #state{snapshot = Prev, last_tick_ts = Tick0},
    Acc
) ->
    Label = #{namespace => NS},
    Reads = counter_value(?M_READS, Label),
    Ranges = counter_value(?M_RANGES, Label),
    Hits = counter_value(?M_CACHE_HITS, Label),
    Misses = counter_value(?M_CACHE_MISSES, Label),
    {PrevReads, PrevRanges, PrevHits, PrevMisses, PrevTs} =
        maps:get(NS, Prev, {0, 0, 0, 0, Tick0}),
    DeltaReads = Reads - PrevReads,
    DeltaRanges = Ranges - PrevRanges,
    DeltaHits = Hits - PrevHits,
    DeltaMisses = Misses - PrevMisses,
    %% Use the actual elapsed window since the last snapshot — robust
    %% against scheduler jitter or skipped ticks. `max(_, 1)` keeps the
    %% division well-defined on the (rare) zero-elapsed case.
    Window = max(Now - PrevTs, 1),
    CacheHitRate =
        case DeltaHits + DeltaMisses of
            0 -> undefined;
            Total -> DeltaHits / Total
        end,
    ReadRps = (DeltaReads * 1000) / Window,
    RangeRps = (DeltaRanges * 1000) / Window,
    SubCount = subscriber_count(NS),
    LagMaxMs = freshness_lag_max_ms(NS, Now),
    telemetry:execute(
        [bondy_oplog_core, metrics, refresh],
        #{
            cache_hit_rate => CacheHitRate,
            read_rps => ReadRps,
            range_rps => RangeRps,
            subscriber_count => SubCount,
            current_freshness_lag_max_ms => LagMaxMs
        },
        #{namespace => NS, interval_ms => Window}
    ),
    Acc#{NS => {Reads, Ranges, Hits, Misses, Now}}.

counter_value(Name, Label) ->
    case bondy_metrics:value(#{name => Name, label => Label}) of
        undefined -> 0;
        V -> V
    end.

counter_namespaces() ->
    %% Union the namespaces across all four counter names. Each
    %% with_name/1 returns `[{Label, _Value}]`; we extract the
    %% `namespace` from each label.
    Names = [?M_READS, ?M_RANGES, ?M_CACHE_HITS, ?M_CACHE_MISSES],
    Labels = lists:flatten([bondy_metrics:with_name(N) || N <- Names]),
    lists:usort([NS || {#{namespace := NS}, _V} <- Labels]).

safe_namespaces() ->
    try
        bondy_oplog_core_registry:namespaces()
    catch
        _:_ -> []
    end.

subscriber_count(NS) ->
    try
        bondy_oplog_core_dispatcher:subscription_count(NS)
    catch
        _:_ -> 0
    end.

freshness_lag_max_ms(NS, NowMs) ->
    try bondy_oplog_core_registry:shards_for(NS) of
        [] ->
            0;
        Entries ->
            lists:max(
                [
                    NowMs -
                        atomics:get(
                            bondy_oplog_core_registry:entry_ae_atomics(E), 1
                        )
                 || E <- Entries
                ]
            )
    catch
        _:_ -> 0
    end.
