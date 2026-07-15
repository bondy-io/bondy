%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_regulator_app).
-moduledoc """
The `bondy_regulator` application callback.
""".

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    bondy_regulator_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
