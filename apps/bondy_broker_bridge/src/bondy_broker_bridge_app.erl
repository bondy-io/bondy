%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_broker_bridge_app).

-moduledoc """
OTP application callback module for `bondy_broker_bridge`.

Starts the top-level supervisor `bondy_broker_bridge_sup`.
""".

-behaviour(application).

-export([start/2, stop/1]).



%% =============================================================================
%% API
%% =============================================================================


-doc false.
start(_StartType, _StartArgs) ->
    bondy_broker_bridge_sup:start_link().


-doc false.
stop(_State) ->
    ok.
