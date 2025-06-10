
%% =============================================================================
%%  bondy_jobs_sup.erl -
%%
%%  Copyright (c) 2018-2024 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
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



