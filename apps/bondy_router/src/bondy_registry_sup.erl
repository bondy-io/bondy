%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_sup).
-moduledoc """
Top-level supervisor for the registry subsystem. It starts the registry
partition workers (one per partition, managed through a `gproc_pool`) and the
`bondy_registry` worker.
""".
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
        % max restarts
        intensity => 20,
        % seconds
        period => 60,
        auto_shutdown => never
    },

    %% Start partitions first, then the registry worker, then the per-node
    %% meta responder (the peer leg of the distributed introspection walk),
    %% which reads through the registry so it must come up after it.
    Children =
        partitions() ++
            [
                ?WORKER(bondy_registry, [], permanent, 5000),
                bondy_registry_meta:child_spec()
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
    _ =
        try
            gproc_pool:new(?REGISTRY_POOL, hash, [{size, N}])
        catch
            _:_ -> ok
        end,

    Indices = [
        begin
            WorkerName = {WorkerMod, Index},
            _ =
                try
                    gproc_pool:add_worker(?REGISTRY_POOL, WorkerName, Index)
                catch
                    _:_ -> ok
                end,
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
