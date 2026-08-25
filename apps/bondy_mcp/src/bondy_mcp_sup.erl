%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_sup).

-moduledoc """
Top supervisor for `bondy_mcp`.

Supervises no static children: a node with no listener naming the `mcp`
service receives no inbound MCP request, and the outbound client
direction (§13) runs only where `mcp.upstreams` declares it — so nothing
in this application should be running by default. Anything this
application comes to own is created on demand: the inbound servers on
first use, the upstream supervisor at application start when (and only
when) upstreams are declared.
""".

-behaviour(supervisor).

-export([start_door/0]).
-export([start_gateway/0]).
-export([start_link/0]).
-export([start_upstreams/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc """
Starts the manifest cache manager (`bondy_mcp_gateway`) on demand — the
first `bondy_mcp_gateway:manifest/1` call on this node lands here. Once
started it is permanent: it owns the manifest cache and the change-event
subscriptions that keep it valid.
""".
-spec start_gateway() -> {ok, pid()} | {error, any()}.

start_gateway() ->
    Spec = #{
        id => bondy_mcp_gateway,
        start => {bondy_mcp_gateway, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },
    case supervisor:start_child(?MODULE, Spec) of
        {ok, _} = OK ->
            OK;
        {error, already_present} ->
            supervisor:restart_child(?MODULE, bondy_mcp_gateway);
        {error, _} = Error ->
            Error
    end.

-doc """
Starts the handshake-era door (`bondy_mcp_handshake`'s per-node
`partisan_gen_server`) on demand — the first handshake request on this
node lands here. Once started it is permanent: peers address it by
registered name to reach sessions this node owns.
""".
-spec start_door() -> {ok, pid()} | {error, any()}.

start_door() ->
    Spec = #{
        id => bondy_mcp_handshake,
        start => {bondy_mcp_handshake, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },
    case supervisor:start_child(?MODULE, Spec) of
        {ok, _} = OK ->
            OK;
        {error, already_present} ->
            supervisor:restart_child(?MODULE, bondy_mcp_handshake);
        {error, _} = Error ->
            Error
    end.

-doc """
Starts the upstream supervisor (`bondy_mcp_upstream_sup`, the client
direction §13). Called by `bondy_mcp_app` at application start when
`mcp.upstreams` declares at least one upstream; an invalid declaration
set fails the start, and with it the application — see that supervisor's
own doc for what is validated.
""".
-spec start_upstreams() -> {ok, pid()} | {error, any()}.

start_upstreams() ->
    Spec = #{
        id => bondy_mcp_upstream_sup,
        start => {bondy_mcp_upstream_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor
    },
    case supervisor:start_child(?MODULE, Spec) of
        {ok, _} = OK ->
            OK;
        {error, already_present} ->
            supervisor:restart_child(?MODULE, bondy_mcp_upstream_sup);
        {error, _} = Error ->
            Error
    end.

init([]) ->
    Flags = #{strategy => one_for_one, intensity => 5, period => 10},
    {ok, {Flags, []}}.
