%% =============================================================================
%%  bondy_prometheus_collector.erl -
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

-module(bondy_prometheus_collector).
-behaviour(prometheus_collector).

-export([deregister_cleanup/1]).
-export([collect_mf/2]).
-export([collect_metrics/2]).




%% =============================================================================
%% BEHAVIOUR CALLBACKS
%% =============================================================================



deregister_cleanup(_) -> ok.


-spec collect_mf(
    prometheus_registry:registry(), prometheus_collector:callback()) -> ok.

collect_mf(_Registry, CB) ->
    case lists:keyfind(bondy, 1, application:which_applications()) of
        false -> ok;
        _ -> do_collect(CB)
    end.


collect_metrics(_Key, {counter, Val}) ->
    prometheus_model_helpers:counter_metric(Val);

collect_metrics(_Key, {gauge, Val}) ->
    prometheus_model_helpers:gauge_metric(Val);

collect_metrics(_Key, {histogram, Val}) ->
    prometheus_model_helpers:histogram_metric(Val).




%% =============================================================================
%% PRIVATE
%% =============================================================================



do_collect(CB) ->
    Metrics = [

    ],
    lists:foreach(
        fun({Name, Help, Type, Fun}) ->
            Data = try
                Fun()
            catch _:_ -> undefined
            end,
            MF = prometheus_model_helpers:create_mf(
                Name, Help, Type, ?MODULE, {Type, Data}),
            CB(MF)
        end,
        Metrics
    ).