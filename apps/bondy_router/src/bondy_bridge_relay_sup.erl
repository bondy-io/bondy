%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_bridge_relay_sup).
-moduledoc """
Top-level supervisor for the bridge relay subsystem, supervising the
bridge relay client supervisor and the `bondy_bridge_relay_manager`.
""".
-behaviour(supervisor).

-include("bondy.hrl").

%% API
-export([start_link/0]).

%% SUPERVISOR CALLBACKS
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% add_sink_sup(Name, Config) ->
%%     {error, not_implemented}.

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        % max restarts
        intensity => 10,
        % seconds
        period => 60,
        auto_shutdown => never
    },
    Children = [
        ?SUPERVISOR(bondy_bridge_relay_client_sup, [], permanent, infinity),
        ?WORKER(bondy_bridge_relay_manager, [], permanent, 5000)
    ],
    {ok, {SupFlags, Children}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================
