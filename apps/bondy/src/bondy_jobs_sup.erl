
%% =============================================================================
%%  bondy_jobs_sup.erl -
%%
%%  Copyright (c) 2018-2023 Leapsight. All rights reserved.
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
    RestartStrategy = {one_for_one, 0, 1},

    %% Start partitions first
    Children = partitions(),

    {ok, {RestartStrategy, Children}}.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
partitions() ->
    PoolName = ?JOBS_POOLNAME,
    WorkerMod = bondy_jobs_worker,
    N = bondy_config:get([jobs_pool, size]),

    ok = gproc_pool:new(PoolName, hash, [{size, N}]),

    Indices = [
        begin
            WorkerName = {WorkerMod, Index},
            Index = gproc_pool:add_worker(PoolName, WorkerName, Index),
            Index
        end
        || Index <- lists:seq(1, N)
    ],

    [
        #{
            id => Index,
            start => {WorkerMod, start_link, [Index]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [WorkerMod]
        }
        || Index <- Indices
    ].



