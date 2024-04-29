%% =============================================================================
%%  bondy_sup.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
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
    Children = [
        %% We start bondy processes
        ?WORKER(bondy_table_owner, [], permanent, 5000),
        ?SUPERVISOR(bondy_event_handler_watcher_sup, [], permanent, infinity),
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
    {ok, {{one_for_one, 1, 5}, Children}}.
