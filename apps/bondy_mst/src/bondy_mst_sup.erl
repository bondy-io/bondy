%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_sup).

-behaviour(supervisor).

-include("bondy_mst.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("bondy_mst top level supervisor.").

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

%% =============================================================================
%% API
%% =============================================================================

start_link() ->
    case supervisor:start_link({local, ?SERVER}, ?MODULE, []) of
        {ok, _} = OK ->
            OK;
        Error ->
            Error
    end.

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

init([]) ->
    ok = bondy_mst_config:init(),
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    %% `bondy_mst` is a library: it has no long-lived processes of its own
    %% (pack-store workers are started per-store, not globally). This
    %% supervisor exists only to initialise the library configuration when
    %% `bondy_mst` is started standalone. The `bondy_oplog`/`bondy_db` layer
    %% is supervised by `bondy_oplog_sup` (started by `bondy_oplog_app`).
    ChildSpecs = [],

    {ok, {SupFlags, ChildSpecs}}.
