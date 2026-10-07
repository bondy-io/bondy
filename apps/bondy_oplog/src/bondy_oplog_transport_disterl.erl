%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_transport_disterl).
-behaviour(bondy_oplog_transport).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Distributed Erlang transport.

`peer_id` is interpreted as a node atom (e.g. `'b@host'`). Sync
requests are delivered to the peer's
`bondy_oplog_responder` via `gen_server:call/3` over the
disterl link; the responder dispatches to the local instance.

## Pre-requisites

- The Erlang runtime must be running in distributed mode (`erl
  -name`/`-sname`) on both nodes.
- Both nodes have the `bondy_oplog` application running, so the
  responder is registered and listening.
- The cookies and network reachability are operator concerns.

## Per-call options

| Key       | Default | Meaning |
|---|---|---|
| `timeout` | `5000`  | gen_server:call timeout (ms). |

## Choosing this vs Partisan

`bondy_oplog_transport_partisan` makes the same request with
`partisan_gen_server:call/3`, and is the transport Bondy wires when
clustering is enabled (`bondy_router_app`). This one needs only OTP.
""").

-export([request/4]).
-export([self_id/1]).

-spec request(
    peer_id(),
    instance_id(),
    bondy_oplog_transport:request(),
    map()
) -> bondy_oplog_transport:response() | {error, term()}.

request(PeerNode, InstanceId, Request, Opts) when
    is_atom(PeerNode), is_binary(InstanceId)
->
    Timeout = maps:get(timeout, Opts, 5000),
    Target = {bondy_oplog_responder, PeerNode},
    Msg = {sync_protocol, InstanceId, Request},
    try gen_server:call(Target, Msg, Timeout) of
        Reply -> bondy_oplog_transport:response(Reply)
    catch
        exit:Reason ->
            {error, {gen_server_call_failed, Reason}}
    end;
request(Peer, _InstanceId, _Request, _Opts) ->
    {error, {invalid_peer_for_disterl_transport, Peer}}.

-doc "Peers are addressed by Erlang node name on this transport.".
-spec self_id(instance_id()) -> peer_id().

self_id(_InstanceId) ->
    node().
