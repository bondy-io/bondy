%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_jobs_sup).
-behaviour(supervisor).

-include("bondy.hrl").


%% API
-export([start_link/0]).


%% SUPERVISOR CALLBACKS
-export([init/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).



%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================



init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5, % max restarts
        period => 10, % seconds
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

    %% If the supervisor restarts and we call groc_pool:new it will fail with
    %% an exception, as the pool server is managed by the gproc supervisor
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



