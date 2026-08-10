%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_regulator_load).
-moduledoc """
Node load monitor: a periodic sampler of the runtime's total run queue
length exposing a binary busy/normal status through a lock-free read
(`busy/0`).

The run queue is the direct measure of scheduling delay — how long a
runnable process waits for a scheduler — which is what actually degrades
under CPU saturation: work that is cheap in CPU terms (a session open, a
message dispatch) takes seconds of wall clock purely because its process
is scheduled late. Admission gates use `busy/0` to refuse NEW work
cheaply (an immediate, retryable refusal) instead of accepting work that
will time out expensively after holding resources.

The status has hysteresis to avoid flapping at the boundary: it becomes
`busy` when the sampled run queue reaches `high_watermark x
schedulers_online` and returns to `normal` only when it falls to
`low_watermark x schedulers_online`. A crossing must also hold for three
consecutive samples before it is committed. Hysteresis alone does not
cover the dominant case on a quiet node: an instantaneous run queue
spikes whenever a wave of periodic timers wakes together, and such a
spike clears within one sample, so a single-sample commit would refuse
admission — and log a state change — while nothing is actually
saturated. Thresholds are expressed as factors
of the online scheduler count so a configuration is portable across
machine sizes: a run queue of N x schedulers means roughly N runnable
processes ahead of any newly runnable one on every scheduler.

`busy/0` never blocks and never raises: it is a single `atomics` read
through a `persistent_term`-cached ref, and it FAILS OPEN (`normal`)
when the monitor is not running — availability outranks regulation.

Configuration (`bondy_regulator` application environment, set via the
`load_regulation.load_monitor.*` cuttlefish mappings):

- `load_monitor_high_watermark` — busy at `RunQueue >= High x
  SchedulersOnline` (default 8).
- `load_monitor_low_watermark` — back to normal at `RunQueue =< Low x
  SchedulersOnline` (default 4).
- `load_monitor_sample_interval_ms` — sampling period (default 100).
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-define(PT_KEY, {?MODULE, status}).
-define(STATUS_SLOT, 1).
-define(RUN_QUEUE_SLOT, 2).
-define(DEFAULT_HIGH_WATERMARK, 8).
-define(DEFAULT_LOW_WATERMARK, 4).
-define(DEFAULT_SAMPLE_INTERVAL_MS, 100).
%% Consecutive samples a crossing must hold before the status changes. An
%% instantaneous run queue spikes whenever a wave of periodic timers wakes
%% together, which an idle node does routinely; committing on one sample
%% turns that into a refused HELLO and a pair of log lines.
-define(DWELL_SAMPLES, 3).

-record(state, {
    ref :: atomics:atomics_ref(),
    high :: pos_integer(),
    low :: non_neg_integer(),
    interval_ms :: pos_integer(),
    %% Consecutive samples the pending (not yet committed) status has held.
    dwell = 0 :: non_neg_integer()
}).

%% API
-export([busy/0]).
-export([run_queue/0]).
-export([start_link/0]).
-export([status/0]).

-ifdef(TEST).
%% Exposed so the dwell window can be pinned directly: driving it through
%% the sampler would mean manufacturing a real run-queue spike shorter
%% than the sampling period, which is not reproducible.
-export([step/3]).
-endif.

%% GEN_SERVER CALLBACKS
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([init/1]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> {ok, pid()} | ignore | {error, any()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Returns `true` when the node is in the busy state. Lock-free (one
atomics read); fails open (`false`) when the monitor is not running.
""".
-spec busy() -> boolean().

busy() ->
    case persistent_term:get(?PT_KEY, undefined) of
        undefined ->
            false;
        Ref ->
            atomics:get(Ref, ?STATUS_SLOT) == 1
    end.

-doc "Returns the current status. Fails open (`normal`).".
-spec status() -> normal | busy.

status() ->
    case busy() of
        true -> busy;
        false -> normal
    end.

-doc """
Returns the last sampled total run queue length, or `0` when the
monitor is not running.
""".
-spec run_queue() -> non_neg_integer().

run_queue() ->
    case persistent_term:get(?PT_KEY, undefined) of
        undefined ->
            0;
        Ref ->
            atomics:get(Ref, ?RUN_QUEUE_SLOT)
    end.

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    Schedulers = erlang:system_info(schedulers_online),
    HighFactor = get_env(
        load_monitor_high_watermark, ?DEFAULT_HIGH_WATERMARK
    ),
    LowFactor = get_env(load_monitor_low_watermark, ?DEFAULT_LOW_WATERMARK),
    IntervalMs = get_env(
        load_monitor_sample_interval_ms, ?DEFAULT_SAMPLE_INTERVAL_MS
    ),

    Ref =
        case persistent_term:get(?PT_KEY, undefined) of
            undefined ->
                New = atomics:new(2, []),
                ok = persistent_term:put(?PT_KEY, New),
                New;
            Existing ->
                %% A restart reuses the published ref (readers hold no
                %% subscription to invalidate); reset to normal.
                ok = atomics:put(Existing, ?STATUS_SLOT, 0),
                Existing
        end,

    State = #state{
        ref = Ref,
        high = max(1, HighFactor) * Schedulers,
        low = max(0, LowFactor) * Schedulers,
        interval_ms = IntervalMs
    },
    {ok, schedule_sample(State)}.

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.

handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

handle_info(sample, State0) ->
    #state{ref = Ref, high = High, low = Low, dwell = Dwell0} = State0,
    RunQueue = erlang:statistics(total_run_queue_lengths_all),
    ok = atomics:put(Ref, ?RUN_QUEUE_SLOT, RunQueue),

    Status = atomics:get(Ref, ?STATUS_SLOT),
    Pending = transition(Status, RunQueue, High, Low),

    State =
        case step(Status, Pending, Dwell0) of
            {hold, Dwell} ->
                State0#state{dwell = Dwell};
            {commit, 1} ->
                ok = atomics:put(Ref, ?STATUS_SLOT, 1),
                ?LOG_NOTICE(#{
                    description =>
                        "Node entered the busy state: admission gates will "
                        "refuse new work until the run queue drains below "
                        "the low watermark.",
                    run_queue => RunQueue,
                    high_watermark => High,
                    low_watermark => Low,
                    dwell_samples => ?DWELL_SAMPLES
                }),
                State0#state{dwell = 0};
            {commit, 0} ->
                ok = atomics:put(Ref, ?STATUS_SLOT, 0),
                ?LOG_NOTICE(#{
                    description => "Node returned to the normal state.",
                    run_queue => RunQueue,
                    low_watermark => Low,
                    dwell_samples => ?DWELL_SAMPLES
                }),
                State0#state{dwell = 0}
        end,

    {noreply, schedule_sample(State)};
handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unsupported_event,
        event => Info
    }),
    {noreply, State}.

terminate(_Reason, #state{ref = Ref}) ->
    %% Fail open for readers while we are down.
    ok = atomics:put(Ref, ?STATUS_SLOT, 0),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The dwell step. A crossing is committed only once it has held for
%% `?DWELL_SAMPLES` consecutive samples; a return to the committed side
%% voids any partial dwell, so a spike shorter than the dwell window
%% never changes the status.
step(Status, Status, _Dwell) ->
    {hold, 0};
step(_Status, Pending, Dwell) when Dwell + 1 >= ?DWELL_SAMPLES ->
    {commit, Pending};
step(_Status, _Pending, Dwell) ->
    {hold, Dwell + 1}.

%% @private
%% The hysteresis step: `1` (busy) at or above the high watermark, `0`
%% (normal) at or below the low watermark, unchanged in between.
transition(0, RunQueue, High, _Low) when RunQueue >= High ->
    1;
transition(1, RunQueue, _High, Low) when RunQueue =< Low ->
    0;
transition(Status, _RunQueue, _High, _Low) ->
    Status.

%% @private
schedule_sample(#state{interval_ms = IntervalMs} = State) ->
    _ = erlang:send_after(IntervalMs, self(), sample),
    State.

%% @private
get_env(Key, Default) ->
    case application:get_env(bondy_regulator, Key) of
        {ok, Value} when is_integer(Value), Value >= 0 ->
            Value;
        _ ->
            Default
    end.
