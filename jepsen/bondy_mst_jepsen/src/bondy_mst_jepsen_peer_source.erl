%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_jepsen_peer_source).
-behaviour(bondy_oplog_peer_source).

-include_lib("kernel/include/logger.hrl").

-export([peers_for/2]).

%% =============================================================================
%% bondy_oplog_peer_source callback
%% =============================================================================

%% Returns the subset of the configured peer list that net_kernel
%% currently sees as `up`. The membership snapshot is maintained by
%% `bondy_mst_jepsen_net_monitor`, which keeps it in an ETS table so
%% the scheduler hot-path stays lock-free. The full configured list is
%% the source of truth — net_monitor narrows it.
peers_for(_InstanceId, _Opts) ->
    bondy_mst_jepsen_net_monitor:up_peers().
