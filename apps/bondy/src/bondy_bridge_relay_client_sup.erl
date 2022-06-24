%% =============================================================================
%%  bondy_bridge_relay_client_sup.erl -
%%
%%  Copyright (c) 2018-2022 Leapsight. All rights reserved.
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
-module(bondy_bridge_relay_client_sup).

-behaviour(supervisor).

-define(CLIENT(Id, Args, Restart, Timeout), #{
    id => Id,
    start => {bondy_bridge_relay_client, start_link, Args},
    restart => Restart,
    shutdown => Timeout,
    type => worker,
    modules => [bondy_bridge_relay_client]
}).

%% API
-export([start_link/0]).
-export([start_child/1]).
-export([delete_child/1]).
-export([terminate_child/1]).


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
-spec start_child(bondy_bridge_relay:t()) -> {ok, pid()} | {error, any()}.

start_child(Bridge) ->
    Id = maps:get(name, Bridge),
    ChildSpec = ?CLIENT(Id, [Bridge], transient, 5000),

    case supervisor:start_child(?MODULE, ChildSpec) of
        {ok, _} = OK ->
            OK;
        {error, already_present} ->
            ok = supervisor:delete_child(?MODULE, Id),
            start_child(Bridge);
        {error, _} = Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
terminate_child(Name) ->
    supervisor:terminate_child(?MODULE, Name).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
delete_child(Name) ->
    supervisor:delete_child(?MODULE, Name).


%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================



init([]) ->
    {ok, {{one_for_one, 5, 60}, []}}.
