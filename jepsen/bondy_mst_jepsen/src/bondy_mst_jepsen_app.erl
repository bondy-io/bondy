%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_jepsen_app).
-behaviour(application).

-include_lib("kernel/include/logger.hrl").

-export([start/2, stop/1]).

%% =============================================================================
%% application callbacks
%% =============================================================================

start(_StartType, _StartArgs) ->
    ?LOG_NOTICE(#{
        description => "bondy_mst_jepsen starting",
        node        => node(),
        peers       => application:get_env(bondy_mst_jepsen, peers, [])
    }),
    %% Attach PR-J4 audit telemetry handler before anything is running
    %% so the first applier batch is observed.
    _ = bondy_mst_jepsen_audit:attach(),
    bondy_mst_jepsen_sup:start_link().

stop(_State) ->
    ok.
