%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_app).

-behaviour(application).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Application entry point for the `bondy_mst` replication-structure library.

`bondy_mst` is a library with no long-lived processes of its own; this app
exists only so the library can be started standalone (it initialises the
library configuration via `bondy_mst_sup`). The `bondy_oplog`/`bondy_db`
layer that builds on top of it is booted by `bondy_oplog_app`, not here.
""").

-export([start/2, stop/1]).

%% =============================================================================
%% APPLICATION CALLBACKS
%% =============================================================================

start(_StartType, _StartArgs) ->
    bondy_mst_sup:start_link().

stop(_State) ->
    ok.
