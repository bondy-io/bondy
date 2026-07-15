%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_transport_partisan).
-behaviour(bondy_oplog_transport).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Partisan transport for the sync protocol.

`peer_id` is interpreted as a **Partisan node name** (the values returned
by `partisan_peer_service:members/0` / `bondy_oplog_peer_source_partisan`),
never an `erlang:node()`/`nodes()` value. Sync requests are delivered to
the peer's `bondy_oplog_responder` (a `partisan_gen_server`) via
`partisan_gen_server:call/3`; the responder dispatches to the local
instance and replies back over Partisan.

This is the transport to use whenever the cluster runs Partisan with
`connect_disterl => false` (no Erlang-distribution mesh): the reply leg
cannot ride an OTP `gen_server:reply/2` over disterl, so both legs speak
Partisan. `bondy_oplog_transport_disterl` remains for Erlang-distributed
deployments.

## Per-call options

| Key       | Default              | Meaning |
|---|---|---|
| `timeout` | `5000`               | call timeout (ms). |
| `channel` | Partisan default     | Partisan channel to pin the traffic to (e.g. a dedicated anti-entropy channel so registry/security sync can't starve WAMP traffic). |

Both are passed through `Opts`. When `channel` is absent the call uses
Partisan's default channel.
""").

-export([request/4]).

%% =============================================================================
%% API
%% =============================================================================

-spec request(
    peer_id(),
    instance_id(),
    bondy_oplog_transport:request(),
    map()
) -> {ok, term()} | {error, term()}.

request(Peer, InstanceId, Request, Opts) when
    is_atom(Peer), is_binary(InstanceId)
->
    Timeout = maps:get(timeout, Opts, 5000),
    Target = {bondy_oplog_responder, Peer},
    Msg = {sync_protocol, InstanceId, Request},
    CallOpts = call_opts(Timeout, Opts),
    try partisan_gen_server:call(Target, Msg, CallOpts) of
        {ok, _} = OK -> OK;
        {ok, _, _} = OK -> OK;
        {error, _} = E -> E;
        Other -> {error, {unexpected_response, Other}}
    catch
        exit:Reason ->
            {error, {partisan_call_failed, Reason}}
    end;
request(Peer, _InstanceId, _Request, _Opts) ->
    {error, {invalid_peer_for_partisan_transport, Peer}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Builds the `partisan_gen_server:call/3' options list. The channel is
%% included only when the caller supplies one, so the default path uses
%% Partisan's default channel without us needing to know its name.
call_opts(Timeout, Opts) ->
    case maps:find(channel, Opts) of
        {ok, Channel} -> [{timeout, Timeout}, {channel, Channel}];
        error -> [{timeout, Timeout}]
    end.
