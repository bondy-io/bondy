%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_oidc_refresh_sup).
-moduledoc """
Supervisor for the OIDC refresh worker pool.

Uses gproc_pool (hash) to distribute refresh work across N workers, where N
defaults to the number of schedulers.
""".

-behaviour(supervisor).

-include("bondy.hrl").

-define(POOL_NAME, bondy_oidc_refresh_pool).


%% API
-export([start_link/0]).
-export([pool_name/0]).

%% SUPERVISOR CALLBACKS
-export([init/1]).



%% =============================================================================
%% API
%% =============================================================================



-doc false.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


-doc """
Returns the gproc pool name used by the refresh workers.
""".
-spec pool_name() -> atom().

pool_name() ->
    ?POOL_NAME.



%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================



init([]) ->
    %% Create the ETS table before starting workers
    ok = bondy_oidc_refresh_worker:init_table(),

    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10,
        auto_shutdown => never
    },

    Children = shards(),

    {ok, {SupFlags, Children}}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
shards() ->
    PoolName = ?POOL_NAME,
    WorkerMod = bondy_oidc_refresh_worker,
    N = bondy_config:get(
        [oidc, refresh_pool_size], erlang:system_info(schedulers)
    ),

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
