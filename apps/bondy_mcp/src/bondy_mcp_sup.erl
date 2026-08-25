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

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Flags = #{strategy => one_for_one, intensity => 5, period => 10},
    {ok, {Flags, []}}.
