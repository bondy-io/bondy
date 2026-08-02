%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_relay).
-moduledoc """
Relays WAMP messages (PUBLISH, INVOCATION and their RESULT or ERROR,
INTERRUPT) between WAMP clients connected to different Bondy peers
(nodes).

This module is the egress half only — plain functions, no process. The
message is addressed to `{via, bondy_router_worker, PartitionKey}`,
where the partition key is the flow hash (`routing_opts/2`) that also
pins the flow to one connection of the `wamp_relay` Partisan channel.
On the receiving node the connection process resolves that key against
the local flow pool geometry (`bondy_router_worker:whereis_name/1`) and
delivers the message straight into the owning worker's mailbox — there
is no relay process on ingress, so relay capacity scales with channel
parallelism and flow pool size while each flow remains a single ordered
pipeline end to end.

```
+-------------------------+                    +-------------------------+
|         node_1          |                    |         node_2          |
|                         |                    |                         |
| +---------------------+ |    cast_message    | +---------------------+ |
| | wamp_relay channel  | |  {via, worker, K}  | | wamp_relay channel  | |
| |     connections     |<+--------------------+>|     connections     | |
| |  (flow-pinned by K) | |                    | |  (whereis_name(K))  | |
| +---------------------+ |                    | +---------------------+ |
|    ^          |         |                    |         |          ^    |
|    |          v         |                    |         v          |    |
| +---------------------+ |                    | +---------------------+ |
| | bondy_router_worker | |                    | | bondy_router_worker | |
| |     (flow pool)     | |                    | |     (flow pool)     | |
| +---------------------+ |                    | +---------------------+ |
|         ^    |          |                    |          |   ^          |
|         |    v          |                    |          v   |          |
| +---------------------+ |                    | +---------------------+ |
| |bondy_wamp_*_handler | |                    | |bondy_wamp_*_handler | |
| +---------------------+ |                    | +---------------------+ |
|         ^    |          |                    |          |   ^          |
+---------+----+----------+                    +----------+---+----------+
          |    |                                          |   |
     CALL |    | RESULT | ERROR                INVOCATION |   | YIELD
          |    v                                          v   |
+-------------------------+                    +-------------------------+
|         Caller          |                    |         Callee          |
+-------------------------+                    +-------------------------+
```
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

%% API
-export([forward/2]).
-export([forward/3]).
-export([routing_opts/2]).

%% =============================================================================
%% API
%% =============================================================================

-spec forward(Node :: node() | [node()], Msg :: any()) -> ok.

forward(Node, Msg) ->
    forward(Node, Msg, #{}).

-doc """
Forwards a wamp message to a peer (cluster node).
It returns `ok`.

`Opts` MUST contain the `partition_key` produced by `routing_opts/2`:
it selects the channel connection on the wire AND the flow pool worker
on the receiving node, so every message of a flow traverses one ordered
pipeline. Delivery is at-most-once: the receiving node sheds the
message when the owning worker's share of the flow pool capacity is in
use (see `bondy_router_worker:whereis_name/1`).

This only works for PUBLISH, ERROR, INTERRUPT, INVOCATION and RESULT
WAMP message types. It will fail with an exception if another type is
passed as the third argument.
""".
-spec forward(Node :: node() | [node()], Msg :: any(), Opts :: map()) -> ok.

forward(Node, Msg, Opts0) when is_atom(Node) ->
    Channel = bondy_config:get(wamp_peer_channel, undefined),
    Opts = Opts0#{channel => Channel},
    PartitionKey = maps:get(partition_key, Opts),
    partisan:cast_message(
        Node, {via, bondy_router_worker, PartitionKey}, Msg, Opts
    );
forward(Nodes, Msg, Opts) when is_list(Nodes) ->
    _ = [forward(Node, Msg, Opts) || Node <- Nodes],
    ok.

-doc """
Returns the options to use when forwarding a WAMP message that flows from
source ref `From` to destination ref `To` — the `router.forward` options
plus a `partition_key` derived from the pair.

The partition key pins every message of the same flow to one connection of
the (possibly parallel) `wamp_relay` Partisan channel, so the wire preserves
per-flow order while unrelated flows still spread across connections. WAMP
ordering guarantees are all pairwise between a source and a destination
session — events between a publisher and a subscriber, invocations between
a caller and a callee — so the pair is the finest key that preserves them.

`To` is `undefined` for PUBLISH forwards (they are node-addressed): the key
degrades to per-publisher, which those guarantees still require since the
receiving node mints the EVENTs for all its local subscribers from the
relayed PUBLISH.

The receiving node resolves the same key to a flow pool worker
(`bondy_router_worker:whereis_name/1`), so a flow is a single ordered
pipeline end to end.
""".
-spec routing_opts(
    From :: optional(bondy_ref:t()), To :: optional(bondy_ref:t())
) -> map().

routing_opts(From, To) ->
    Opts = bondy_config:get([router, forward]),
    Opts#{partition_key => erlang:phash2({From, To})}.
