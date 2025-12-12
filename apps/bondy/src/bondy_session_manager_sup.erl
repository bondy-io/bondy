%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

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



