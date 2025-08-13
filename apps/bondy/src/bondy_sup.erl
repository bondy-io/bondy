%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_sup).
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



%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================



init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 2, % max restarts
        period => 5, % seconds
        auto_shutdown => never
    },
    Children = [
        ?WORKER(bondy_system_gc, [], permanent, 5000),
        %% ets table owner used by several other processes
        ?WORKER(bondy_table_manager, [], permanent, 5000),
        %% supervisor for event handlers
        ?SUPERVISOR(bondy_event_handler_watcher_sup, [], permanent, infinity),
        %% gen_event managers
        ?EVENT_MANAGER(bondy_event_manager, permanent, 5000),
        ?EVENT_MANAGER(bondy_wamp_event_manager, permanent, 5000),
        ?SUPERVISOR(bondy_jobs_sup, [], permanent, infinity),
        ?SUPERVISOR(bondy_registry_sup, [], permanent, infinity),
        ?SUPERVISOR(bondy_session_manager_sup, [], permanent, infinity),
        ?WORKER(bondy_rpc_promise_manager, [], permanent, 5000),
        ?SUPERVISOR(bondy_subscribers_sup, [], permanent, infinity),
        ?WORKER(bondy_retained_message_manager, [], permanent, 5000),
        %% TODO bondy_relay to be replaced by a pool of relays each
        %% corresponding to a Partisan channel connections
        ?WORKER(bondy_relay, [], permanent, 5000),
        ?WORKER(bondy_backup, [], permanent, 5000),
        ?WORKER(bondy_http_gateway, [], permanent, 5000),
        ?SUPERVISOR(bondy_bridge_relay_sup, [], permanent, infinity)
    ],
    {ok, {SupFlags, Children}}.
