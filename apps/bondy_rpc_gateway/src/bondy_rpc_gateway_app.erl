%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_app).

-moduledoc """
OTP application callback module for `bondy_rpc_gateway`.

Initialises configuration via `bondy_rpc_gateway_config:init/0` and starts
the top-level supervisor.
""".

-behaviour(application).

-export([start/2]).
-export([stop/1]).

-doc false.
start(_StartType, _StartArgs) ->
    ok = bondy_rpc_gateway_config:init(),
    bondy_rpc_gateway_sup:start_link().

-doc false.
stop(_State) ->
    ok.
