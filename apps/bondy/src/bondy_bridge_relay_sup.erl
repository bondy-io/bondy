%% =============================================================================
%%  bondy_bridge_relay_sup.erl -
%%
%%  Copyright (c) 2018-2023 Leapsight. All rights reserved.
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
-module(bondy_bridge_relay_sup).
-behaviour(supervisor).

-include("bondy.hrl").

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


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
%% add_sink_sup(Name, Config) ->
%%     {error, not_implemented}.




%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================



init([]) ->
    Children = [
        ?WORKER(bondy_bridge_relay_manager, [], permanent, 5000),
        ?SUPERVISOR(bondy_bridge_relay_client_sup, [], permanent, infinity)
    ],
    {ok, {{one_for_one, 1, 5}, Children}}.



%% =============================================================================
%% PRIVATE
%% =============================================================================


