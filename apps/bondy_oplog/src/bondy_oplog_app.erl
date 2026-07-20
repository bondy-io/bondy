%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_app).

-behaviour(application).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Application entry point for the `bondy_oplog` write/replication layer.

It boots the oplog supervision tree (`bondy_oplog_sup`) and initialises the
configuration of the `bondy_mst` replication-structure library this layer is
built on (`bondy_mst_config:init/0`). That init also runs via `bondy_mst`'s
own application start before `bondy_oplog` starts; it is idempotent, so the
call here is a defensive no-op.

This layer has no leveled concern of its own — leveled storage (bookies,
topologies, the projection adapter) belongs to `bondy_db`, which depends on
this application.
""").

-export([start/2, stop/1]).

%% =============================================================================
%% APPLICATION CALLBACKS
%% =============================================================================

start(_StartType, _StartArgs) ->
    ok = bondy_mst_config:init(),
    bondy_oplog_sup:start_link().

stop(_State) ->
    ok.
