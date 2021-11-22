%% =============================================================================
%%  bondy_sup.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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

-define(SUPERVISOR(Id, Args, Restart, Timeout), #{
    id => Id,
    start => {Id, start_link, Args},
    restart => Restart,
    shutdown => Timeout,
    type => supervisor,
    modules => [Id]
}).

-define(WORKER(Id, Args, Restart, Timeout), #{
    id => Id,
    start => {Id, start_link, Args},
    restart => Restart,
    shutdown => Timeout,
    type => worker,
    modules => [Id]
}).

-define(EVENT_MANAGER(Id, Restart, Timeout), #{
    id => Id,
    start => {gen_event, start_link, [{local, Id}]},
    restart => Restart,
    shutdown => Timeout,
    type => worker,
    modules => [dynamic]
}).



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
        %% bondy_config_manager should be first process to be started
        ?WORKER(bondy_config_manager, [], permanent, 30000),
        %% We start the included applications
        ?SUPERVISOR(tuplespace_sup, [], permanent, infinity),
        ?SUPERVISOR(plum_db_sup, [], permanent, infinity),
        %% We start bondy processes
        ?SUPERVISOR(bondy_event_handler_watcher_sup, [], permanent, infinity),
        ?EVENT_MANAGER(bondy_event_manager, permanent, 5000),
        ?EVENT_MANAGER(bondy_wamp_event_manager, permanent, 5000),
        ?SUPERVISOR(bondy_session_manager_sup, [], permanent, 5000),
        ?WORKER(bondy_registry, [], permanent, 5000),
        ?SUPERVISOR(bondy_subscribers_sup, [], permanent, infinity),
        ?WORKER(bondy_retained_message_manager, [], permanent, 5000),
        ?WORKER(bondy_peer_wamp_forwarder, [], permanent, 5000),
        ?WORKER(bondy_backup, [], permanent, 5000),
        ?WORKER(bondy_http_gateway, [], permanent, 5000),
        ?WORKER(bondy_peer_discovery_agent, [], permanent, 5000)
    ],
    {ok, {{one_for_one, 1, 5}, Children}}.
