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

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{
            id => bondy_api_gateway,
            start => {
                bondy_api_gateway,
                start_link,
                []
            },
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bondy_api_gateway]
        },
        #{
            id => bondy_peer_wamp_forwarder,
            start => {
                bondy_peer_wamp_forwarder,
                start_link,
                []
            },
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bondy_peer_wamp_forwarder]
        }
        #{
            id => bondy_registry,
            start => {
                bondy_registry,
                start_link,
                []
            },
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bondy_registry]
        }
    ],
    {ok, {{one_for_one, 1, 5}, Children}}.
