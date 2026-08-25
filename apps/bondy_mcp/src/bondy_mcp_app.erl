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
    %% Declare the §15 metric families and attach the Prometheus sink
    %% before any emitter can run. `bondy_metrics` is up: its gen_server
    %% is a `bondy_oplog_sup` child and `bondy_oplog` precedes
    %% `bondy_router`, which starts this application mid-boot.
    ok = bondy_mcp_metrics:setup(),
    case bondy_mcp_sup:start_link() of
        {ok, _} = OK ->
            case application:get_env(bondy_mcp, upstreams, []) of
                [] ->
                    OK;
                [_ | _] ->
                    %% The client direction (§13). An invalid declaration
                    %% set fails the application start deliberately.
                    case bondy_mcp_sup:start_upstreams() of
                        {ok, _} -> OK;
                        {error, _} = Error -> Error
                    end
            end;
        Other ->
            Other
    end.

stop(_State) ->
    ok.
