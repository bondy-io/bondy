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
- Both nodes have the `bondy_mst` application running, so the
  responder is registered and listening.
- The cookies and network reachability are operator concerns.

## Per-call options

| Key       | Default | Meaning |
|---|---|---|
| `timeout` | `5000`  | gen_server:call timeout (ms). |

## Choosing this vs Partisan

A `partisan` consumer simply implements
`bondy_oplog_transport` itself with `partisan_gen_server:call`
in place of `gen_server:call`, addressing
`{bondy_oplog_responder, Peer}` over the partisan layer.
The library does not ship a partisan transport (it would otherwise
have to take partisan as a hard dependency); the disterl transport
is shipped because disterl is part of OTP.
""").

-export([request/4]).

-spec request(
    peer_id(),
    instance_id(),
    bondy_oplog_transport:request(),
    map()
) -> {ok, term()} | {error, term()}.

request(PeerNode, InstanceId, Request, Opts) when
    is_atom(PeerNode), is_binary(InstanceId)
->
    Timeout = maps:get(timeout, Opts, 5000),
    Target = {bondy_oplog_responder, PeerNode},
    Msg = {sync_protocol, InstanceId, Request},
    try gen_server:call(Target, Msg, Timeout) of
        {ok, _} = OK -> OK;
        {ok, _, _} = OK -> OK;
        {error, _} = E -> E;
        Other -> {error, {unexpected_response, Other}}
    catch
        exit:Reason ->
            {error, {gen_server_call_failed, Reason}}
    end;
request(Peer, _InstanceId, _Request, _Opts) ->
    {error, {invalid_peer_for_disterl_transport, Peer}}.
