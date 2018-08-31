%% =============================================================================
%%  bondy_sup.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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

-define(CHILD(Id, Type, Args, Restart, Timeout), #{
    id => Id,
    start => {Id, start_link, Args},
    restart => Restart,
    shutdown => Timeout,
    type => Type,
    modules => [Id]
}).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        ?CHILD(bondy_registry, worker, [], permanent, 5000),
        ?CHILD(bondy_broker_events, worker, [], permanent, 5000),
        ?CHILD(bondy_peer_wamp_forwarder, worker, [], permanent, 5000),
        ?CHILD(bondy_api_gateway, worker, [], permanent, 5000),
        ?CHILD(bondy_backup, worker, [], permanent, 5000)
    ],
    %% REVIEW SUPERVISION TREE, MAYBE SPLIT IN SUPERVISORS TO ADOPT
    %% MIXED STRATEGY
    %% TODO, we should use rest_for_one strategy.
    %% If the registry or the wamp forwarder dies it is useless to
    %% accept HTTP requests. Also they need to wait for the registry
    %% to restore data from disk and maybe perform an exchange
    {ok, {{one_for_one, 1, 5}, Children}}.
