%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_app).

-moduledoc """
OTP application behaviour for `bondy_mcp`.

Started by `bondy_app:start/2` after the early-phase listeners and before the
normal-phase ones bind, so an MCP socket never accepts a request while the
application that answers it is down.
""".

-behaviour(application).

-export([start/2]).
-export([stop/1]).

start(_Type, _Args) ->
    bondy_mcp_sup:start_link().

stop(_State) ->
    ok.
