%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_router_worker).
-moduledoc """
Implements the router worker pools used by `m:bondy_router` to forward WAMP
messages asynchronously with load regulation.

Two pools coexist because they offer different ordering guarantees:

* The `router_pool` (`cast/1`) is a `sidejob` pool — either a permanent pool
  of supervised `m:gen_server` workers or a transient pool that spawns a new
  worker per task. Tasks run concurrently with no ordering relationship, so
  this pool is only suitable for work where relative order does not matter.
* The flow pool (`cast/2`) is a fixed set of supervised `m:gen_server`
  workers (see `m:bondy_router_flow_sup`) where the worker is chosen by
  hashing the caller-provided key. All tasks sharing a key execute on the
  same worker in submission order, giving per-key FIFO execution while
  keeping tasks with different keys concurrent. It is used to preserve the
  WAMP per-source ordering guarantees (events between a publisher and a
  subscriber, invocations between a caller and a callee).
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-define(POOL_NAME, router_pool).
-define(FLOW_WORKER_NAME(Index), {?MODULE, flow, Index}).

-record(state, {
    pool_type :: permanent | transient | flow,
    %% Flow workers only: this worker's slot in the flow pool usage
    %% counters, decremented once per executed task.
    index :: pos_integer() | undefined,
    counters :: atomics:atomics_ref() | undefined,
    op :: function()
}).

%% API
-export([start_pool/0]).
-export([start_link/1]).
-export([cast/1]).
-export([cast/2]).
-export([report_shed/1]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([handle_continue/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Starts a sidejob pool of workers according to the configuration
for the entry named `router_pool`.
""".
-spec start_pool() -> ok.

start_pool() ->
    case do_start_pool() of
        {ok, _Child} -> ok;
        {ok, _Child, _Info} -> ok;
        {error, already_present} -> ok;
        {error, {already_started, _Child}} -> ok;
        {error, Reason} -> error(Reason)
    end.

-doc """
Executes `Fun` asynchronously on the `router_pool`. Tasks submitted through
this function run concurrently and can complete in any order. Returns
`{error, overload}` when the pool is at capacity.
""".
-spec cast(Fun :: fun(() -> any())) -> ok | {error, overload}.

cast(Fun) when is_function(Fun, 0) ->
    Opts = bondy_config:get(router_pool),
    PoolType = key_value:get(type, Opts, transient),

    case do_cast(PoolType, router_pool, Fun) of
        ok ->
            ok;
        {ok, _} ->
            ok;
        {error, overload} = Error ->
            Error
    end.

-doc """
Executes `Fun` asynchronously on the flow pool worker owning `Key`.

The worker is `erlang:phash2(Key, Size)`, so all tasks sharing a key run on
the same worker and thus execute in submission order (per-key FIFO), while
tasks with different keys run concurrently on other workers. Callers that
need a WAMP flow (a source/destination session pair) delivered in order
submit every message of the flow with the same key.

Returns `{error, overload}` when the worker's share of the flow pool
capacity (`load_regulation.router.flow_pool.capacity`) is in use — the
caller must drop the task to preserve ordering (executing it inline would
overtake the tasks already queued for the same key). Callers report the
drop through `report_shed/1`.

The pool geometry (size, per-worker limit, usage counters) is read from
the stamp `bondy_router_flow_sup` wrote at startup, never from the live
env, so the dispatch modulus can never drift from the started worker set.
The load bound is a dispatcher-incremented / worker-decremented atomics
slot per worker — no `process_info/2` on the hot path.
""".
-spec cast(Key :: any(), Fun :: fun(() -> any())) -> ok | {error, overload}.

cast(Key, Fun) when is_function(Fun, 0) ->
    case bondy_config:get(router_flow_pool, undefined) of
        undefined ->
            %% The pool has not started yet.
            {error, overload};
        Opts ->
            Size = key_value:get(size, Opts),
            Limit = key_value:get(worker_limit, Opts),
            Counters = key_value:get(counters, Opts),
            Index = erlang:phash2(Key, Size) + 1,

            case atomics:add_get(Counters, Index, 1) > Limit of
                true ->
                    ok = atomics:sub(Counters, Index, 1),
                    {error, overload};
                false ->
                    Name = bondy_gproc:local_name(?FLOW_WORKER_NAME(Index)),

                    case gproc:where(Name) of
                        undefined ->
                            %% The worker is restarting; dropping
                            %% preserves at-most-once.
                            ok = atomics:sub(Counters, Index, 1),
                            {error, overload};
                        Pid ->
                            gen_server:cast(Pid, Fun)
                    end
            end
    end.

-doc """
Records a message shed by an ordered (flow pool) dispatch site.

Always bumps `bondy_wamp_dropped_total{reason="shed"}` for `Family`; logs
a warning at most once per window across ALL callers (the window clock is
a shared atomic, so a shed storm cannot become a log storm) and a debug
line otherwise.
""".
-spec report_shed(Family :: atom()) -> ok.

report_shed(Family) ->
    ok = bondy_prometheus:report_dropped(shed, Family),

    case bondy_config:get(router_flow_pool, undefined) of
        undefined ->
            ok;
        Opts ->
            Clock = key_value:get(shed_warn, Opts),
            Window = key_value:get(shed_warn_window_secs, Opts),
            Now = erlang:monotonic_time(second),
            Last = atomics:get(Clock, 1),

            case
                Now - Last >= Window andalso
                    ok == atomics:compare_exchange(Clock, 1, Last, Now)
            of
                true ->
                    ?LOG_WARNING(#{
                        description =>
                            "Dropping messages due to load shedding: a "
                            "router flow pool worker is at capacity. "
                            "Sheds preserve per-flow ordering (delivery "
                            "is at-most-once); further drops in the next "
                            "window are counted in "
                            "bondy_wamp_dropped_total and logged at "
                            "debug level.",
                        family => Family,
                        window_secs => Window
                    });
                false ->
                    ?LOG_DEBUG(#{
                        description =>
                            "Dropped message due to load shedding: "
                            "router flow pool worker at capacity",
                        family => Family
                    })
            end
    end.

-doc """
Starts a flow pool worker and registers it under its hash index. Called by
`m:bondy_router_flow_sup` only.
""".
-spec start_link(Index :: pos_integer()) ->
    {ok, pid()} | ignore | {error, any()}.

start_link(Index) ->
    Name = {via, gproc, bondy_gproc:local_name(?FLOW_WORKER_NAME(Index))},
    %% Flow workers absorb bursts in their mailbox, so we store messages
    %% off heap to avoid excessive GC.
    Opts = [{spawn_opt, [{message_queue_data, off_heap}]}],
    gen_server:start_link(Name, ?MODULE, [flow, Index], Opts).

%% =============================================================================
%% API : GEN_SERVER CALLBACKS FOR SIDEJOB WORKER
%% =============================================================================

init([?POOL_NAME]) ->
    %% We've been called by sidejob_worker
    %% We will be called via a a cast (handle_cast/2)
    %% TODO publish metaevent and stats
    {ok, #state{pool_type = permanent}};
init([flow, Index]) ->
    %% We've been called by bondy_router_flow_sup.
    %% We will be called via a cast (handle_cast/2)
    Counters = key_value:get(counters, bondy_config:get(router_flow_pool)),
    %% A restart lost the previous incarnation's mailbox, so the usage
    %% this slot accounted for is gone with it.
    ok = atomics:put(Counters, Index, 0),
    {ok, #state{pool_type = flow, index = Index, counters = Counters}};
init([Fun]) ->
    %% We've been called by sidejob_supervisor
    State = #state{pool_type = transient},
    {ok, State, {continue, {apply, Fun}}}.

handle_continue({apply, Fun}, State) ->
    %% We apply and terminate as this is a transient worker.
    _ = Fun(),
    {stop, normal, State}.

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.

handle_cast(Fun, State) when is_function(Fun, 0) ->
    try
        _ = Fun(),
        {noreply, State}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {noreply, State}
    after
        %% We cleanup, liberating the Fun from having to try..catch and do it
        bondy:unset_process_metadata(),
        ok = release_usage(State)
    end;
handle_cast(Event, State) ->
    ?LOG_DEBUG(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unsupported_event,
        event => Info
    }),
    {noreply, State}.

terminate(normal, _State) ->
    ok;
terminate(shutdown, _State) ->
    ok;
terminate({shutdown, _}, _State) ->
    ok;
terminate(_Reason, _State) ->
    %% TODO publish metaevent
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Flow workers return their usage-counter slot after each executed task;
%% the other pool types account for load elsewhere (sidejob).
release_usage(#state{pool_type = flow, counters = Counters, index = Index}) ->
    ok = atomics:sub(Counters, Index, 1);
release_usage(#state{}) ->
    ok.

%% @private
-doc """
Actually starts a sidejob pool based on system configuration.
""".
do_start_pool() ->
    Opts = bondy_config:get(router_pool),
    Size = key_value:get(size, Opts),
    Capacity = key_value:get(capacity, Opts),
    PoolType = key_value:get(type, Opts, transient),

    case PoolType of
        permanent ->
            Mod = ?MODULE,
            sidejob:new_resource(?POOL_NAME, Mod, Capacity, Size);
        transient ->
            Mod = sidejob_supervisor,
            sidejob:new_resource(?POOL_NAME, Mod, Capacity, Size)
    end.

%% @private
-doc """
Helper function for `async_forward/2`.
""".
do_cast(permanent, PoolName, Fun) ->
    %% We send a request to an existing permanent worker
    %% using bondy_router acting as a sidejob_worker
    case sidejob:cast(PoolName, Fun) of
        ok ->
            ok;
        overload ->
            {error, overload}
    end;
do_cast(transient, PoolName, Fun) ->
    Opts = [
        {spawn_opt, [
            {min_heap_size, 1598}
        ]}
    ],
    %% We spawn a transient worker using sidejob_supervisor
    sidejob_supervisor:start_child(
        PoolName,
        gen_server,
        start_link,
        [?MODULE, [Fun], Opts]
    ).
