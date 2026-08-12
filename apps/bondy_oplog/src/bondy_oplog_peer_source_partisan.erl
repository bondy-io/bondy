%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_peer_source_partisan).
-behaviour(bondy_oplog_peer_source).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Partisan-membership peer source for clustered deployments.

Returns a uniformly-random subset of the cluster members this node is
currently connected to, excluding the local node. Each returned
`peer_id()` is therefore a **Partisan node name** — never an
`erlang:node()`/`nodes()` value — which is what the Partisan transport
(`bondy_oplog_transport_partisan`) and responder address.

Membership and connectivity are distinct: a node that is down remains a
member until it is removed from the cluster. Only connected members are
offered, because the scheduler opens one session per instance per tick
against every peer it is given, and a session against an unreachable
member can only fail. An isolated node therefore offers no peers rather
than offering members it cannot reach.

Connectivity is read per call, from the lock-free connection table, so
it costs one ETS lookup per member and reflects the state at the moment
of selection. A peer can still go down between selection and the call;
that race belongs to the caller.

`Opts` keys:

- `count` :: how many peers to pick per call (default 3). Sampling is
  delegated to `bondy_oplog_peer_source_sample`, so when the connected
  pool is smaller than `count` the whole pool is returned.

Used by `bondy_oplog_sync_scheduler` once per tick; membership and
connectivity are both re-read every call, so peers that join, leave or
reconnect are picked up on the next round without any explicit refresh.
""").

-export([peers_for/2]).

-spec peers_for(instance_id(), map()) -> [peer_id()].

peers_for(InstanceId, Opts) when is_map(Opts) ->
    {ok, Members} = partisan_peer_service:members(),
    Pool = [
        Peer
     || Peer <- Members -- [partisan:node()],
        partisan_peer_connections:is_connected(Peer)
    ],
    Count = maps:get(count, Opts, 3),
    bondy_oplog_peer_source_sample:peers_for(
        InstanceId, #{pool => Pool, count => Count}
    ).
