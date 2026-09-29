%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_stdlib_app).

-behaviour(application).

-moduledoc """
Application entry point for `bondy_stdlib`: starts `bondy_stdlib_sup`.

The library is otherwise pure; the one process it runs is
`bondy_table_manager`, which every Bondy application borrows ETS tables
from and which therefore has to start before any of them — being started
by the library they all depend on is what guarantees that.
""".

-export([start/2]).
-export([stop/1]).

%% =============================================================================
%% APPLICATION CALLBACKS
%% =============================================================================

start(_StartType, _StartArgs) ->
    bondy_stdlib_sup:start_link().

stop(_State) ->
    ok.
