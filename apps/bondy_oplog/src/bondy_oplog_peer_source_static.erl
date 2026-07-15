%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_peer_source_static).
-behaviour(bondy_oplog_peer_source).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Static peer-list peer source for closed-cluster deployments.

`Opts` may contain a `peers` key whose value is the static list of
peer ids to return. If no list is configured, returns `[]`.

```erlang
peers_for(_InstanceId, #{peers => [Peer1, Peer2, Peer3]}) ->
    [Peer1, Peer2, Peer3].
```
""").

-export([peers_for/2]).

-spec peers_for(instance_id(), map()) -> [peer_id()].

peers_for(_InstanceId, #{peers := Peers}) when is_list(Peers) ->
    Peers;
peers_for(_InstanceId, _Opts) ->
    [].
