%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_jepsen_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => rest_for_one,
        intensity => 5,
        period    => 10
    },
    Children = [
        %% Owns the leveled supervisor (started inside its own init),
        %% the bondy_db handle, and the per-table handles. Also wires
        %% the sync scheduler's peer source + dispatch so the 3-node
        %% cluster converges via disterl.
        %%
        %% The leveled sup is *not* a sibling under this supervisor —
        %% if it were, this gen_server would deadlock trying to look
        %% up its pid via `supervisor:which_children/1` while the
        %% parent supervisor is still in the middle of starting its
        %% own children.
        #{
            id       => bondy_mst_jepsen_cluster,
            start    => {bondy_mst_jepsen_cluster, start_link, []},
            restart  => permanent,
            shutdown => 30_000,
            type     => worker,
            modules  => [bondy_mst_jepsen_cluster]
        },
        %% Tracks `net_kernel` connect/disconnect events for the
        %% configured peer list and exposes the current up-set to the
        %% sync dispatch so a downed peer is short-circuited instead
        %% of timing out every tick.
        #{
            id       => bondy_mst_jepsen_net_monitor,
            start    => {bondy_mst_jepsen_net_monitor, start_link, []},
            restart  => permanent,
            shutdown => 5_000,
            type     => worker,
            modules  => [bondy_mst_jepsen_net_monitor]
        },
        %% Cowboy HTTP listener. Started last so the table handles are
        %% already in place when the first request arrives.
        #{
            id       => bondy_mst_jepsen_http,
            start    => {bondy_mst_jepsen_http, start_link, []},
            restart  => permanent,
            shutdown => 5_000,
            type     => worker,
            modules  => [bondy_mst_jepsen_http]
        }
    ],
    {ok, {SupFlags, Children}}.
