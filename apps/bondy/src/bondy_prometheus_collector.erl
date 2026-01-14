%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
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
