%% =============================================================================
%%  bondy_edge_uplink_session_sup.erl -
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
-module(bondy_edge_exchanges_sup).

-behaviour(supervisor).

-include_lib("wamp/include/wamp.hrl").

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
-export([start_exchange/3]).
-export([stop_exchange/1]).


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
%% @doc Starts a new exchange provided we would not reach the limit set by the
%% `aae_concurrency' config parameter.
%% If the limit is reached returns the error tuple `{error, concurrency_limit}'
%% @end
%% -----------------------------------------------------------------------------
-spec start_exchange(
    Conn :: pid(), Sessions :: [bondy_edge_session:t()], Opts :: map()) ->
    {ok, pid()} | {error, any()}.

start_exchange(Conn, Sessions, Opts) ->
    Children = supervisor:count_children(?MODULE),
    {active, Count} = lists:keyfind(active, 1, Children),
    case bondy_config:get([edge, aae_concurrency], 1) > Count of
        true ->
            Args = [Conn, Sessions, Opts],
            supervisor:start_child(?MODULE, Args);
        false ->
            {error, concurrency_limit}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
stop_exchange(Pid) when is_pid(Pid)->
    supervisor:terminate_child(?MODULE, Pid).



%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================



init([]) ->
    Children = [
        ?WORKER(bondy_edge_exchange_statem, [], temporary, 5000)
    ],
    Specs = {{simple_one_for_one, 0, 1}, Children},
    {ok, Specs}.

