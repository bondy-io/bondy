%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_jobs_sup).
-moduledoc """
Supervisor for the Bondy jobs worker pool. Starts one `bondy_jobs_worker` per
shard and registers them in a `gproc_pool`.
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
        %% max restarts
        intensity => 5,
        %% seconds
        period => 10,
        auto_shutdown => never
    },

    %% Start shards first
    Children = shards(),

    {ok, {SupFlags, Children}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
shards() ->
    PoolName = ?JOBS_POOLNAME,
    WorkerMod = bondy_jobs_worker,
    N = bondy_config:get([job_manager_pool, size], 32),

    %% gproc owns the pool and its workers, so both outlive a restart of this
    %% supervisor. `gproc_pool` then raises `exists` for each of them.
    _ =
        try
            gproc_pool:new(PoolName, hash, [{size, N}])
        catch
            error:exists -> ok
        end,

    Shards = [
        begin
            WorkerName = {WorkerMod, Shard},
            _ =
                try
                    gproc_pool:add_worker(PoolName, WorkerName, Shard)
                catch
                    error:exists -> ok
                end,
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
