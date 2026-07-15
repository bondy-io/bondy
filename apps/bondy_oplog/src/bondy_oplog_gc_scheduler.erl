%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_gc_scheduler).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Default GC scheduler.

Periodic timer that, on each tick, spawns a short-lived worker
process per running instance to run the configured trigger. The
default trigger runs one compaction cycle per instance via
`bondy_oplog_compaction:compact/1`.

The scheduler itself never blocks on the trigger — every invocation
is in a separate worker. A semaphore caps the number of concurrent
workers so that a slow trigger (e.g. compaction on a very large
instance) cannot pile up unbounded.

## Configuration

| Key                  | Default | Meaning |
|---|---|---|
| `gc_scheduler`       | `true`  | Enable / disable. |
| `gc_interval_ms`     | `1000`  | Time between ticks. |
| `gc_trigger`         | `undefined` | `fun((InstanceId) -> any())`; defaults to running compaction per instance. |
| `gc_max_concurrency` | `4`     | Cap on concurrently running trigger workers. Instances over the cap on a tick are skipped this round. |

Errors raised by the trigger are caught and logged in the worker; they
do not crash the scheduler.
""").

-record(state, {
    enabled :: boolean(),
    interval_ms :: non_neg_integer(),
    trigger :: undefined | fun((instance_id()) -> any()),
    tick_ref :: undefined | reference(),
    max_concurrency :: pos_integer(),
    %% Pid → InstanceId of currently running workers.
    in_flight :: #{pid() => instance_id()}
}).

%% Lifecycle
-export([start_link/0]).
-export([start_link/1]).
-export([child_spec/1]).

%% Control
-export([trigger/0]).
-export([trigger_for/1]).
-export([set_trigger/1]).
-export([set_interval_ms/1]).
-export([info/0]).

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

?DOC("Forces a tick now (across all running instances).").
-spec trigger() -> ok.

trigger() ->
    gen_server:cast(?MODULE, tick).

?DOC("""
Triggers GC for a single instance immediately.
""").
-spec trigger_for(instance_id()) -> ok.

trigger_for(InstanceId) ->
    gen_server:cast(?MODULE, {tick_for, InstanceId}).

?DOC("""
Replaces the trigger callback at runtime. Pass `undefined` to
quiesce.
""").
-spec set_trigger(undefined | fun((instance_id()) -> any())) -> ok.

set_trigger(Fun) when is_function(Fun, 1); Fun =:= undefined ->
    gen_server:call(?MODULE, {set_trigger, Fun}).

?DOC("""
Sets the periodic-tick interval (in milliseconds) at runtime. `0`
disables periodic ticks entirely; explicit `trigger/0` and
`trigger_for/1` still work. The currently-scheduled timer is
cancelled and a new one armed with the new interval (if non-zero).

Useful for operator tuning and for tests that need to suppress
periodic firing while asserting on explicit triggers.
""").
-spec set_interval_ms(non_neg_integer()) -> ok.

set_interval_ms(Ms) when is_integer(Ms), Ms >= 0 ->
    gen_server:call(?MODULE, {set_interval_ms, Ms}).

-spec info() -> map().

info() ->
    gen_server:call(?MODULE, info).

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    Trigger =
        case maps:find(trigger, Opts) of
            {ok, V} ->
                V;
            error ->
                case application:get_env(bondy_oplog, gc_trigger) of
                    {ok, EnvFun} -> EnvFun;
                    undefined -> fun default_trigger/1
                end
        end,
    State = #state{
        enabled = maps:get(
            enabled, Opts, bondy_oplog_config:gc_scheduler_enabled()
        ),
        interval_ms = maps:get(
            interval_ms, Opts, bondy_oplog_config:gc_interval_ms()
        ),
        trigger = Trigger,
        max_concurrency = maps:get(
            max_concurrency, Opts, bondy_oplog_config:gc_max_concurrency()
        ),
        in_flight = #{}
    },
    {ok, schedule_tick(State)}.

handle_call(info, _From, State) ->
    Reply = #{
        enabled => State#state.enabled,
        interval_ms => State#state.interval_ms,
        trigger_set => State#state.trigger =/= undefined,
        max_concurrency => State#state.max_concurrency,
        in_flight => map_size(State#state.in_flight)
    },
    {reply, Reply, State};
handle_call({set_trigger, Fun}, _From, State) ->
    {reply, ok, State#state{trigger = Fun}};
handle_call({set_interval_ms, Ms}, _From, State0) ->
    State1 = cancel_pending_tick(State0),
    State2 = schedule_tick(State1#state{interval_ms = Ms}),
    {reply, ok, State2};
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(tick, State) ->
    {noreply, run_tick(State)};
handle_cast({tick_for, InstanceId}, State) ->
    {noreply, fire_async(InstanceId, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    {noreply, schedule_tick(run_tick(State))};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    {noreply, State#state{
        in_flight = maps:remove(Pid, State#state.in_flight)
    }};
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
run_tick(#state{} = State0) ->
    Instances = safe_list_instances(),
    State = lists:foldl(
        fun(I, S) -> fire_async(I, S) end,
        State0,
        Instances
    ),
    telemetry:execute(
        [bondy_oplog, scheduler, gc, tick],
        #{
            instances => length(Instances),
            in_flight => map_size(State#state.in_flight)
        },
        #{}
    ),
    State.

%% @private
%% Spawns one short-lived worker that runs the trigger for this
%% instance. The worker is monitored so we can decrement the in-flight
%% count when it exits. If the cap is full, or this instance already
%% has a worker running, we skip the round — compaction is idempotent
%% and re-runs on the next tick.
fire_async(_InstanceId, #state{trigger = undefined} = State) ->
    State;
fire_async(
    InstanceId,
    #state{
        in_flight = InFlight,
        max_concurrency = Cap
    } = State
) when map_size(InFlight) >= Cap ->
    telemetry:execute(
        [bondy_oplog, scheduler, gc, skipped],
        #{count => 1},
        #{instance_id => InstanceId, reason => max_concurrency}
    ),
    State;
fire_async(InstanceId, #state{in_flight = InFlight} = State) ->
    AlreadyRunning = lists:member(InstanceId, maps:values(InFlight)),
    case AlreadyRunning of
        true ->
            telemetry:execute(
                [bondy_oplog, scheduler, gc, skipped],
                #{count => 1},
                #{instance_id => InstanceId, reason => already_running}
            ),
            State;
        false ->
            Trigger = State#state.trigger,
            {Pid, _Ref} = spawn_monitor(fun() ->
                run_trigger(InstanceId, Trigger)
            end),
            State#state{in_flight = InFlight#{Pid => InstanceId}}
    end.

%% @private
run_trigger(InstanceId, Fun) when is_function(Fun, 1) ->
    try
        _ = Fun(InstanceId),
        ok
    catch
        K:V:S ->
            ?LOG_WARNING(#{
                description => "GC trigger raised",
                instance => InstanceId,
                class => K,
                reason => V,
                stacktrace => S
            }),
            ok
    end.

%% @private
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
%% Default trigger: run a compaction cycle for the instance. The cycle
%% is a no-op when there are no peers, no intersecting prefix, or no
%% CRDT module configured — so this is safe to call on every tick.
default_trigger(InstanceId) ->
    _ = bondy_oplog_compaction:compact(InstanceId),
    ok.
