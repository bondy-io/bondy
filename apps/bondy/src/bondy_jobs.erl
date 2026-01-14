%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
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



-spec enqueue(Fun :: function()) -> ok | {error, any()}.

enqueue(Fun) ->
    enqueue(Fun, undefined).


-spec enqueue(Fun :: function(), PartitionKey :: any()) -> ok | {error, any()}.

enqueue(Fun, PartitionKey) ->
    bondy_jobs_worker:enqueue(Fun, PartitionKey).



