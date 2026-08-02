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

## Named instances

The scheduler holds no per-instance state, so a SECOND instance with its own
interval, cap and trigger is just another registration: pass `name` in
`Opts` (default `?MODULE`) — it becomes both the registered name and the
`child_spec/1` id. The control API's default arities address the default
instance; the name-first arities address a named one. Telemetry events carry
`scheduler => Name` so instances are distinguishable. This is what lets
projection-cell reclamation run on its own cadence
(`BONDY_DB_RECLAMATION_PLAN.md` Step 5) without duplicating this module or
smuggling per-instance time checks into a shared trigger.
""").

-record(state, {
    name :: atom(),
    enabled :: boolean(),
    interval_ms :: non_neg_integer(),
    trigger :: undefined | fun((instance_id()) -> any()),
    tick_ref :: undefined | reference(),
    max_concurrency :: pos_integer(),
    %% Pid → InstanceId of currently running workers.
    in_flight :: #{pid() => instance_id()},
    %% InstanceId → last wall-clock ms a stall was LOGGED for it. The
    %% rate limit for the stalled-reclamation warning (telemetry is never
    %% rate-limited; only the log line is).
    last_stall_log = #{} :: #{instance_id() => integer()},
    %% InstanceId → monotonic ms it was last fired. Ticks fire the
    %% least-recently-fired instances first; without this ordering, a
    %% tick always walks list_instances() from the head and — with fast
    %% triggers — the first max_concurrency instances monopolise every
    %% round while the rest are never compacted.
    last_fired = #{} :: #{instance_id() => integer()}
}).

%% A stalled instance is re-reported in the log at most this often. The
%% telemetry event fires on every occurrence regardless.
-define(STALL_LOG_INTERVAL_MS, 60_000).

%% Lifecycle
-export([start_link/0]).
-export([start_link/1]).
-export([child_spec/1]).

%% Control
-export([trigger/0]).
-export([trigger/1]).
-export([trigger_for/1]).
-export([trigger_for/2]).
-export([set_trigger/1]).
-export([set_trigger/2]).
-export([set_interval_ms/1]).
-export([set_interval_ms/2]).
-export([info/0]).
-export([info/1]).

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
    Name = maps:get(name, Opts, ?MODULE),
    gen_server:start_link({local, Name}, ?MODULE, Opts, []).

-spec child_spec(map()) -> supervisor:child_spec().

child_spec(Opts) ->
    #{
        %% The id follows the name — two scheduler children under one
        %% supervisor must not collide on `?MODULE`.
        id => maps:get(name, Opts, ?MODULE),
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
    trigger(?MODULE).

?DOC("As `trigger/0`, on the named scheduler instance.").
-spec trigger(Name :: atom()) -> ok.

trigger(Name) when is_atom(Name) ->
    gen_server:cast(Name, tick).

?DOC("""
Triggers GC for a single instance immediately.
""").
-spec trigger_for(instance_id()) -> ok.

trigger_for(InstanceId) ->
    trigger_for(?MODULE, InstanceId).

?DOC("As `trigger_for/1`, on the named scheduler instance.").
-spec trigger_for(Name :: atom(), instance_id()) -> ok.

trigger_for(Name, InstanceId) when is_atom(Name) ->
    gen_server:cast(Name, {tick_for, InstanceId}).

?DOC("""
Replaces the trigger callback at runtime. Pass `undefined` to
quiesce.
""").
-spec set_trigger(undefined | fun((instance_id()) -> any())) -> ok.

set_trigger(Fun) ->
    set_trigger(?MODULE, Fun).

?DOC("As `set_trigger/1`, on the named scheduler instance.").
-spec set_trigger(
    Name :: atom(), undefined | fun((instance_id()) -> any())
) -> ok.

set_trigger(Name, Fun) when
    is_atom(Name) andalso (is_function(Fun, 1) orelse Fun =:= undefined)
->
    gen_server:call(Name, {set_trigger, Fun}).

?DOC("""
Sets the periodic-tick interval (in milliseconds) at runtime. `0`
disables periodic ticks entirely; explicit `trigger/0` and
`trigger_for/1` still work. The currently-scheduled timer is
cancelled and a new one armed with the new interval (if non-zero).

Useful for operator tuning and for tests that need to suppress
periodic firing while asserting on explicit triggers.
""").
-spec set_interval_ms(non_neg_integer()) -> ok.

set_interval_ms(Ms) ->
    set_interval_ms(?MODULE, Ms).

?DOC("As `set_interval_ms/1`, on the named scheduler instance.").
-spec set_interval_ms(Name :: atom(), non_neg_integer()) -> ok.

set_interval_ms(Name, Ms) when is_atom(Name), is_integer(Ms), Ms >= 0 ->
    gen_server:call(Name, {set_interval_ms, Ms}).

-spec info() -> map().

info() ->
    info(?MODULE).

?DOC("As `info/0`, on the named scheduler instance.").
-spec info(Name :: atom()) -> map().

info(Name) when is_atom(Name) ->
    gen_server:call(Name, info).

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
        name = maps:get(name, Opts, ?MODULE),
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
        name => State#state.name,
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
handle_cast({stalled, InstanceId, Reason}, State) ->
    %% A trigger reported "no stability, reclaimed nothing" for this
    %% instance. Log it — rate-limited per instance, because a genuinely
    %% stalled member re-reports on every tick — naming the members holding
    %% stability down: this is the difference between "GC is working" and
    %% "GC has been stalled for a week on a decommissioned node nobody
    %% retired".
    {noreply, maybe_log_stall(InstanceId, Reason, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    {noreply, schedule_tick(run_tick(State))};
handle_info({'DOWN', _Ref, process, Pid, Reason}, State) ->
    %% `run_trigger/3` catches trigger exceptions, so an abnormal worker
    %% exit is something outside it (e.g. a kill). It must not be silent:
    %% a permanently dying worker would otherwise look identical to a
    %% permanently healthy one.
    Reason =:= normal orelse
        ?LOG_WARNING(#{
            description => "GC worker exited abnormally",
            scheduler => State#state.name,
            instance =>
                maps:get(Pid, State#state.in_flight, undefined),
            reason => Reason
        }),
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
    Instances0 = safe_list_instances(),
    %% Least-recently-fired first: the cap admits only max_concurrency
    %% workers per round, so a stable head-of-list order would starve
    %% every instance beyond the cap forever whenever the head's
    %% triggers complete within one interval. Sorting by last-fired
    %% time round-robins the cap across all instances. The map is
    %% pruned to the live instance set so departed instances don't
    %% accumulate.
    LastFired = maps:with(Instances0, State0#state.last_fired),
    %% Never-fired sorts first. erlang:monotonic_time/1 can be
    %% negative, so the never-fired default must undercut any real
    %% timestamp — not 0.
    Never = -(1 bsl 63),
    Instances = lists:sort(
        fun(A, B) ->
            maps:get(A, LastFired, Never) =< maps:get(B, LastFired, Never)
        end,
        Instances0
    ),
    State = lists:foldl(
        fun(I, S) -> fire_async(I, S) end,
        State0#state{last_fired = LastFired},
        Instances
    ),
    telemetry:execute(
        [bondy_oplog, scheduler, gc, tick],
        #{
            instances => length(Instances),
            in_flight => map_size(State#state.in_flight)
        },
        #{scheduler => State#state.name}
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
        #{
            instance_id => InstanceId,
            reason => max_concurrency,
            scheduler => State#state.name
        }
    ),
    State;
fire_async(InstanceId, #state{in_flight = InFlight} = State) ->
    AlreadyRunning = lists:member(InstanceId, maps:values(InFlight)),
    case AlreadyRunning of
        true ->
            telemetry:execute(
                [bondy_oplog, scheduler, gc, skipped],
                #{count => 1},
                #{
                    instance_id => InstanceId,
                    reason => already_running,
                    scheduler => State#state.name
                }
            ),
            State;
        false ->
            Trigger = State#state.trigger,
            Name = State#state.name,
            {Pid, _Ref} = spawn_monitor(fun() ->
                run_trigger(Name, InstanceId, Trigger)
            end),
            LastFired = State#state.last_fired,
            Now = erlang:monotonic_time(millisecond),
            State#state{
                in_flight = InFlight#{Pid => InstanceId},
                last_fired = LastFired#{InstanceId => Now}
            }
    end.

%% @private
%% Runs the trigger and REPORTS its outcome — a permanently failing or
%% permanently stalled instance must produce a scheduler-level signal, not
%% vanish into a discarded return value. Every run emits
%% `[bondy_oplog, scheduler, gc, trigger_outcome]`; a reclamation-style
%% "no stability" outcome is additionally cast back to the scheduler for
%% the rate-limited stall log.
run_trigger(Name, InstanceId, Fun) when is_function(Fun, 1) ->
    Outcome =
        try Fun(InstanceId) of
            {error, Reason} -> {error, Reason};
            _ -> ok
        catch
            K:V:S ->
                ?LOG_WARNING(#{
                    description => "GC trigger raised",
                    scheduler => Name,
                    instance => InstanceId,
                    class => K,
                    reason => V,
                    stacktrace => S
                }),
                {error, {raised, K, V}}
        end,
    telemetry:execute(
        [bondy_oplog, scheduler, gc, trigger_outcome],
        #{count => 1},
        #{
            scheduler => Name,
            instance_id => InstanceId,
            outcome => outcome_label(Outcome)
        }
    ),
    case Outcome of
        {error, Stall} ->
            %% EVERY stall reason is reported — no_frontier included: a
            %% down-but-not-retired member whose confirmed root has gone
            %% stale stalls as no_frontier, and that must not be silent.
            gen_server:cast(Name, {stalled, InstanceId, Stall});
        _ ->
            ok
    end.

%% @private
outcome_label(ok) -> ok;
outcome_label({error, {unconfirmed, _}}) -> unconfirmed;
outcome_label({error, {raised, K, _}}) -> {raised, K};
outcome_label({error, Reason}) when is_atom(Reason) -> Reason;
outcome_label({error, _}) -> error.

%% @private
%% See the `{stalled, _, _}` cast. The rate limit is per instance and
%% applies to the LOG only; the telemetry emitted by the trigger and by
%% `bondy_oplog_instance:reclaim_stable_cells/1` is never limited.
%%
%% `idle` — an empty local tree, the steady state of a converged quiescent
%% shard — is not operator-actionable, so it never reaches the warning:
%% logging it would tell the operator to revive members that are alive and
%% converged, and its noise would bury the stalls that DO need action. It
%% remains observable through the never-limited telemetry (the
%% `bondy_oplog_reclamation_stalled_total` family, reason `idle`).
maybe_log_stall(_InstanceId, idle, State) ->
    State;
maybe_log_stall(InstanceId, Reason, State) ->
    Now = erlang:monotonic_time(millisecond),
    Last = maps:get(InstanceId, State#state.last_stall_log, undefined),
    case Last =:= undefined orelse Now - Last >= ?STALL_LOG_INTERVAL_MS of
        false ->
            State;
        true ->
            Missing =
                case Reason of
                    {unconfirmed, Peers} -> Peers;
                    _ -> []
                end,
            ?LOG_WARNING(#{
                description =>
                    "Reclamation stalled: no causal stability for this "
                    "instance, nothing reclaimed. See member_status for "
                    "the member(s) holding stability down (highest "
                    "last_sync_age_ms, or never_synced). Bring them back "
                    "online, or retire them with a deliberate cluster "
                    "membership removal — a stalled member never ages "
                    "out.",
                scheduler => State#state.name,
                instance => InstanceId,
                reason =>
                    case Reason of
                        {unconfirmed, _} -> unconfirmed;
                        {Tag, []} when is_atom(Tag) -> Tag;
                        _ -> Reason
                    end,
                missing_members => Missing,
                member_status => member_status(InstanceId)
            }),
            State#state{
                last_stall_log =
                    (State#state.last_stall_log)#{InstanceId => Now}
            }
    end.

%% @private
%% Per-member sync recency for the stall log: the operator's call to
%% action requires NAMING the member holding stability down, which the
%% stall reason alone does not always do (a down member with a stale
%% confirmed root stalls as `no_frontier`, naming nobody). `never_synced`
%% means the member has no peer-state entry for this instance at all
%% (e.g. it has been down since this node booted). Runs only on the
%% rate-limited log path; total.
member_status(InstanceId) ->
    try
        {ok, Members} = bondy_oplog_instance:reclamation_members(),
        States = bondy_oplog_peer_state:get_instance_peer_states(
            InstanceId, 0
        ),
        ByPeer = maps:from_list([
            {to_bin(P), S}
         || #{peer := P} = S <- States
        ]),
        Now = os:system_time(millisecond),
        lists:map(
            fun(Member) ->
                case maps:get(to_bin(Member), ByPeer, undefined) of
                    #{last_sync := T} ->
                        #{member => Member, last_sync_age_ms => Now - T};
                    undefined ->
                        #{member => Member, status => never_synced}
                end
            end,
            Members
        )
    catch
        _:_ ->
            unavailable
    end.

%% @private
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> list_to_binary(V).

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
%% The result is RETURNED, not discarded: `run_trigger/3` reports it, so a
%% permanently failing instance produces a scheduler-level signal.
default_trigger(InstanceId) ->
    bondy_oplog_compaction:compact(InstanceId).
