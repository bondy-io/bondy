
%% =============================================================================
%%  bondy_session_manager_sup.erl -
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
-module(bondy_session_manager_sup).
-behaviour(supervisor).


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
    Pool = bondy_session_manager:pool(),
    Size = bondy_session_manager:pool_size(),
    Names = init_pool(Pool, Size),
    RestartStrategy = {one_for_one, 0, 1},

    Children = [
        #{
            id => Name,
            start => {bondy_session_manager, start_link, [Pool, Name]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bondy_session_manager]
        }
        || Name <- Names
    ],
    {ok, {RestartStrategy, Children}}.




%% =============================================================================
%% PRIVATE
%% =============================================================================



init_pool(Pool, Size) ->
    ok = gproc_pool:new(Pool, hash, [{size, Size}]),

    Names = [
        begin
            Name = name(Id),
            _ = gproc_pool:add_worker(Pool, Name),
            Name
        end
        || Id <- lists:seq(1, Size)
    ],

    Names.



name(Id) when is_integer(Id) ->
    list_to_atom("bondy_session_manager_" ++ integer_to_list(Id)).



