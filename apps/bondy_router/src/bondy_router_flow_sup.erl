%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_router_flow_sup).
-moduledoc """
Supervisor for the router flow pool: a fixed set of `m:bondy_router_worker`
`gen_server` workers dispatched by key hash via `bondy_router_worker:cast/2`.

Each worker executes its tasks sequentially in mailbox order, so all tasks
sharing a dispatch key — a WAMP flow — run FIFO while distinct keys run
concurrently across workers. The worker count is the `router_pool` size
option (both pools represent router concurrency), while the queue bound is
the flow pool's own, much tighter `load_regulation.router.flow_pool.capacity`
— an ordered lane cannot convert queue depth into throughput, so a large
bound only buys memory pressure.
""".
-behaviour(supervisor).

-include("bondy.hrl").

%% Total messages queued across all flow workers before a saturated flow
%% sheds. Overridden by `load_regulation.router.flow_pool.capacity'.
-define(DEFAULT_CAPACITY, 100000).
-define(SHED_WARN_WINDOW_SECS, 60).

%% API
-export([start_link/0]).

%% SUPERVISOR CALLBACKS
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> {ok, pid()} | ignore | {error, any()}.

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10,
        auto_shutdown => never
    },

    Size = key_value:get(size, bondy_config:get(router_pool)),
    Capacity = bondy_config:get(
        [router_flow_pool, capacity], ?DEFAULT_CAPACITY
    ),

    %% Dispatcher-side usage counters, one slot per worker: the dispatcher
    %% increments on enqueue, the worker decrements per executed task —
    %% a lock-free load bound (no process_info on the hot path). Signed:
    %% a worker restart resets its slot to zero while in-flight enqueues
    %% race it, so a transient negative is possible and harmless.
    Counters = atomics:new(Size, [{signed, true}]),

    %% One-slot window clock for the shed warning (monotonic seconds can
    %% be negative, hence signed). Seed one window in the past so the
    %% first shed after boot warns immediately.
    ShedWarn = atomics:new(1, [{signed, true}]),
    ok = atomics:put(
        ShedWarn,
        1,
        erlang:monotonic_time(second) - 2 * ?SHED_WARN_WINDOW_SECS
    ),

    %% Stamp the effective geometry ONCE. bondy_router_worker:cast/2 and
    %% report_shed/1 read only this stamp, so the dispatch modulus, the
    %% per-worker limit and the started worker count cannot drift apart —
    %% a later change to the router_pool env has no effect until restart.
    ok = bondy_config:set(router_flow_pool, [
        {size, Size},
        {capacity, Capacity},
        {worker_limit, max(1, Capacity div Size)},
        {counters, Counters},
        {shed_warn, ShedWarn},
        {shed_warn_window_secs, ?SHED_WARN_WINDOW_SECS}
    ]),

    Children = [
        #{
            id => {bondy_router_worker, Index},
            start => {bondy_router_worker, start_link, [Index]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bondy_router_worker]
        }
     || Index <- lists:seq(1, Size)
    ],

    {ok, {SupFlags, Children}}.
