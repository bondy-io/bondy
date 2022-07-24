
%% =============================================================================
%%  bondy_registry_sup.erl -
%%
%%  Copyright (c) 2018-2022 Leapsight. All rights reserved.
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
-module(bondy_registry_sup).
-behaviour(supervisor).

-include("bondy.hrl").
-include("bondy_registry.hrl").

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
    Children = partitions() ++ [
        ?WORKER(bondy_registry, [], permanent, 5000)
    ],

    {ok, {RestartStrategy, Children}}.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
partitions() ->
    WorkerMod = bondy_registry_partition,
    N = bondy_config:get([registry, partitions]),

    ok = gproc_pool:new(?REGISTRY_POOL, hash, [{size, N}]),

    Indices = [
        begin
            WorkerName = {WorkerMod, Index},
            Index = gproc_pool:add_worker(?REGISTRY_POOL, WorkerName, Index),
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



