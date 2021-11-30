%% =============================================================================
%%  bondy_edge_uplink_client_sup.erl -
%%
%%  Copyright (c) 2018-2021 Leapsight. All rights reserved.
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
-module(bondy_edge_uplink_client_sup).

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

%% API
-export([start_link/0]).


%% SUPERVISOR CALLBACKS
-export([init/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).



%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================



init([]) ->
    Opts = bondy_config:get([edge, uplink]),

    case key_value:get(enabled, Opts) of
        true ->
            Args = [
                key_value:get(transport, Opts),
                key_value:get(endpoint, Opts),
                Opts
            ],

            % Children = [
            %     ?WORKER(bondy_edge_uplink_client, Args, permanent, 5000),
            %     ?SUPERVISOR(
            %         bondy_edge_exchanges_sup, Args, permanent, infinity
            %     )
            % ],
            % {ok, {{rest_for_one, 5, 60}, Children}};

            Children = [
                ?WORKER(bondy_edge_uplink_client, Args, permanent, 5000)
            ],
            {ok, {{one_for_one, 5, 60}, Children}};

        false ->
            ignore
    end.

