
%% =============================================================================
%%  bondy_session_manager_sup.erl -
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
-module(bondy_session_manager_sup).
-behaviour(supervisor).


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
    {PoolName, WorkerNames} = init_pool(),
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5, % max restarts
        period => 10, % seconds
        auto_shutdown => never
    },
    Children = [
        #{
            id => WorkerName,
            start => {bondy_session_manager, start_link, [PoolName, WorkerName]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bondy_session_manager]
        }
        || WorkerName <- WorkerNames
    ],
    {ok, {SupFlags, Children}}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



init_pool() ->
    #{
        name := PoolName,
        size := Size,
        algorithm := Algorithm
    } = bondy_session_manager:pool(),

    %% If the supervisor restarts and we call groc_pool:new it will fail with
    %% an exception
    _ = catch gproc_pool:new(PoolName, Algorithm, [{size, Size}]),

    WorkerNames = [
        begin
            WorkerName = worker_name(Id),
            _ = catch gproc_pool:add_worker(PoolName, WorkerName),
            WorkerName
        end
        || Id <- lists:seq(1, Size)
    ],
    {PoolName, WorkerNames}.


worker_name(Id) when is_integer(Id) ->
    list_to_atom("bondy_session_manager_" ++ integer_to_list(Id)).



