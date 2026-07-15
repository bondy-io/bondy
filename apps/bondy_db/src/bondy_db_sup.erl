%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_sup).

-behaviour(supervisor).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
`bondy_db` top-level supervisor.

The `bondy_db` layer has no permanent processes: leveled bookie supervisors
(`bondy_db_leveled_sup`, `simple_one_for_one`) and topology ETS owners
(`bondy_db_topology_memory_owner`) are started on demand when a table is
opened, linked to the opening process. This supervisor exists only so the
`bondy_db` application has a root to return from `start/2`.
""").

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

%% =============================================================================
%% API
%% =============================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    ChildSpecs = [],
    {ok, {SupFlags, ChildSpecs}}.
