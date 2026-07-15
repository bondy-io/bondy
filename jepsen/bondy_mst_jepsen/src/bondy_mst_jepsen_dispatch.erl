%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_jepsen_dispatch).

-include_lib("kernel/include/logger.hrl").

-export([dispatch/2]).

%% Sync dispatch for the 3-node Jepsen cluster.
%%
%% Spawns one async `bondy_oplog_sync_session:start/3` per peer per
%% tick over the disterl transport. Sessions run in their own
%% processes and report success/failure via `bondy_oplog_peer_state`;
%% the scheduler does not wait for completion.
%%
%% A peer that net_kernel reports as down is filtered out upstream by
%% `bondy_mst_jepsen_peer_source` so this function never tries to
%% reach an unreachable node.
-spec dispatch(binary(), [node()]) -> ok.
dispatch(InstanceId, Peers) ->
    lists:foreach(
        fun(Peer) ->
            _ = bondy_oplog_sync_session:start(
                InstanceId, Peer,
                #{
                    transport      => bondy_oplog_transport_disterl,
                    transport_opts => #{timeout => 5_000}
                }
            )
        end,
        Peers
    ).
