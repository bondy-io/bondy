%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_sup).

-moduledoc """
Top supervisor for `bondy_mcp`.

Supervises no static children: a node with no listener naming the `mcp`
service receives no MCP request, so nothing in this application should be
running there. Anything this application comes to own is to be created on
demand rather than started here.
""".

-behaviour(supervisor).

-export([start_gateway/0]).
-export([start_link/0]).
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

init([]) ->
    Flags = #{strategy => one_for_one, intensity => 5, period => 10},
    {ok, {Flags, []}}.
