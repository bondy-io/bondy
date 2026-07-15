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

Returns a uniformly-random subset of the live Partisan cluster
membership (`partisan_peer_service:members/0`), excluding the local
node. Each returned `peer_id()` is therefore a **Partisan node name** —
never an `erlang:node()`/`nodes()` value — which is what the Partisan
transport (`bondy_oplog_transport_partisan`) and responder address.

`Opts` keys:

- `count` :: how many peers to pick per call (default 3). Sampling is
  delegated to `bondy_oplog_peer_source_sample`, so when the live pool
  is smaller than `count` the whole pool is returned.

Used by `bondy_oplog_sync_scheduler` once per tick; the membership is
re-read every call so peers that join/leave are picked up on the next
round without any explicit refresh.
""").

-export([peers_for/2]).

-spec peers_for(instance_id(), map()) -> [peer_id()].

peers_for(InstanceId, Opts) when is_map(Opts) ->
    {ok, Members} = partisan_peer_service:members(),
    Pool = Members -- [partisan:node()],
    Count = maps:get(count, Opts, 3),
    bondy_oplog_peer_source_sample:peers_for(
        InstanceId, #{pool => Pool, count => Count}
    ).
