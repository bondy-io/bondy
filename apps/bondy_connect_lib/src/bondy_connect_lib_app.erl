%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_lib_app).

-behaviour(application).

-moduledoc """
Application entry point for `bondy_connect_lib`: starts `bondy_connect_lib_sup`.

The library is otherwise pure; the one process it runs is
`bondy_connect_table_manager`, which every Bondy application borrows ETS tables
from and which therefore has to start before any of them — being started
by the library they all depend on is what guarantees that.
""".

-export([start/2]).
-export([stop/1]).

%% =============================================================================
%% APPLICATION CALLBACKS
%% =============================================================================

start(_StartType, _StartArgs) ->
    bondy_connect_lib_sup:start_link().

stop(_State) ->
    ok.
