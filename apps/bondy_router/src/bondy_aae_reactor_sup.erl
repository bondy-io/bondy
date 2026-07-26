%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_aae_reactor_sup).
-moduledoc """
Supervisor for the AAE merge-reaction subsystem: a `gproc_pool` of
`bondy_aae_reactor_worker` shards plus the single `bondy_aae_reactor` that
subscribes to the reacted-on tables and routes each remote-merge event to a
worker (hashed by cell `Key`).

Workers are started before the reactor so the pool is populated by the time the
reactor begins routing (routing only starts once its subscriptions are
established, which is itself deferred). `one_for_one`: a worker restart
re-registers it in the pool via its own `init`, and a reactor restart just
re-subscribes — neither needs the other restarted.
""".
-behaviour(supervisor).

-include("bondy.hrl").

%% API
-export([start_link/0]).

%% SUPERVISOR CALLBACKS
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

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

    %% Workers first, reactor last (see moduledoc).
    Children =
        shards() ++
            [
                #{
                    id => bondy_aae_reactor,
                    start => {bondy_aae_reactor, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [bondy_aae_reactor]
                }
            ],

    {ok, {SupFlags, Children}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
shards() ->
    PoolName = ?AAE_REACTOR_POOL,
    WorkerMod = bondy_aae_reactor_worker,
    N = bondy_config:get(
        [aae_reactor_pool, size], erlang:system_info(schedulers_online)
    ),

    %% On a supervisor restart the pool already exists; `gproc_pool:new/3` raises
    %% (the pool server is owned by the gproc supervisor), so we ignore it.
    _ = catch gproc_pool:new(PoolName, hash, [{size, N}]),

    Shards = [
        begin
            WorkerName = {WorkerMod, Shard},
            _ = catch gproc_pool:add_worker(PoolName, WorkerName, Shard),
            Shard
        end
     || Shard <- lists:seq(1, N)
    ],

    [
        #{
            id => Shard,
            start => {WorkerMod, start_link, [Shard]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [WorkerMod]
        }
     || Shard <- Shards
    ].
