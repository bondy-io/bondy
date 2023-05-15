%% =============================================================================
%%  bondy_jobs.erl -
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
%% @doc Temp hack for future reliable workflow stuff.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_jobs).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").


%% API
-export([enqueue/2]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc  A temp hack, not actually enqueuing externally, just sending the fun
%% to a gen_server worker, hashed by RealmUri.
%% @end
%% -----------------------------------------------------------------------------
-spec enqueue(RealmUri :: uri(), Fun :: function()) -> ok.

enqueue(RealmUri, Fun) ->
    Pid = bondy_jobs_worker:pick(RealmUri),
    bondy_jobs_worker:async_execute(Pid, Fun).



