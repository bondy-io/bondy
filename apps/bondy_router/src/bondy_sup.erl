%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_sup).
-moduledoc """
The top-level supervisor for the `bondy` application, starting and supervising
its core processes and sub-supervisors.
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

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        % max restarts
        intensity => 2,
        % seconds
        period => 5,
        auto_shutdown => never
    },
    Children = [
        ?WORKER(bondy_system_gc, [], permanent, 5000),
        %% ets table owner used by several other processes
        ?WORKER(bondy_table_manager, [], permanent, 5000),
        %% bondy_db namespace catalogue: owns the durable `main` DB + its
        %% leveled supervisor (gated off by default — see the module).
        ?WORKER(bondy_namespace_catalog, [], permanent, 5000),
        %% supervisor for event handlers
        ?SUPERVISOR(bondy_event_handler_watcher_sup, [], permanent, infinity),
        %% gen_event managers
        ?EVENT_MANAGER(bondy_event_manager, permanent, 5000),
        ?EVENT_MANAGER(bondy_wamp_event_manager, permanent, 5000),
        ?SUPERVISOR(bondy_jobs_sup, [], permanent, infinity),
        %% Router flow pool: keyed FIFO workers used on relay and
        %% bridge-relay ingress to preserve WAMP pairwise ordering. Relay
        %% ingress resolves the flow key straight to a worker
        %% (bondy_router_worker:whereis_name/1); bridge relay dispatches
        %% via bondy_router_worker:cast/3. Must be up before Partisan
        %% accepts peer connections so relayed traffic can be delivered.
        ?SUPERVISOR(bondy_router_flow_sup, [], permanent, infinity),
        ?SUPERVISOR(bondy_registry_sup, [], permanent, infinity),
        %% OIDC support
        ?WORKER(bondy_oidc_state, [], permanent, 5000),
        ?SUPERVISOR(bondy_oidc_provider_sup, [], permanent, infinity),
        ?SUPERVISOR(bondy_oidc_refresh_sup, [], permanent, infinity),
        ?SUPERVISOR(bondy_session_manager_sup, [], permanent, infinity),
        ?WORKER(bondy_rpc_promise_manager, [], permanent, 5000),
        ?WORKER(bondy_http_transport_queue_manager, [], permanent, 5000),
        ?SUPERVISOR(bondy_http_transport_session_sup, [], permanent, infinity),
        ?SUPERVISOR(bondy_subscribers_sup, [], permanent, infinity),
        ?WORKER(bondy_retained_message_manager, [], permanent, 5000),
        ?WORKER(bondy_export, [], permanent, 5000),
        ?WORKER(bondy_http_gateway, [], permanent, 5000),
        %% Node-local reactor for bondy_db remote-merge (AAE) changes; depends
        %% on the namespace catalogue (above) having provisioned the tables.
        ?SUPERVISOR(bondy_aae_reactor_sup, [], permanent, infinity),
        ?SUPERVISOR(bondy_bridge_relay_sup, [], permanent, infinity),
        %% Periodic storage reclamation. Last: it only schedules, and every
        %% sweep it enqueues needs the namespace catalogue and the jobs pool
        %% (both above) already up.
        ?WORKER(bondy_reclaimer, [], permanent, 5000)
    ],
    {ok, {SupFlags, Children}}.
