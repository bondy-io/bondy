%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
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
    SupFlags = #{
        %% TODO move to one_for_one
        %% We can only use one_for_one when each partition can rebuild the its
        %% trie from plum_db on init
        strategy => one_for_all,
        intensity => 20, % max restarts
        period => 60, % seconds
        auto_shutdown => never
    },

    %% Start partitions first
    Children = partitions() ++ [
        ?WORKER(bondy_registry, [], permanent, 5000)
    ],

    {ok, {SupFlags, Children}}.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
partitions() ->
    WorkerMod = bondy_registry_partition,
    N = bondy_config:get([registry, partitions]),

    %% If the supervisor restarts and we call groc_pool:new it will fail with
    %% an exception
    _ = catch gproc_pool:new(?REGISTRY_POOL, hash, [{size, N}]),

    Indices = [
        begin
            WorkerName = {WorkerMod, Index},
            _ = catch gproc_pool:add_worker(?REGISTRY_POOL, WorkerName, Index),
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



