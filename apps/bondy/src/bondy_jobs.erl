%% =============================================================================
%%  bondy_jobs.erl -
%%
%%  Copyright (c) 2018-2024 Leapsight. All rights reserved.
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
%% @doc Load regulation
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_jobs).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

%% API
-export([enqueue/2]).
-export([enqueue/1]).



%% =============================================================================
%% API
%% =============================================================================



-spec enqueue(Fun :: function()) -> ok.

enqueue(Fun) ->
    enqueue(Fun, undefined).


-spec enqueue(Fun :: function(), PartitionKey :: any()) -> ok.

enqueue(Fun, PartitionKey) ->
    bondy_jobs_worker:enqueue(Fun, PartitionKey).



