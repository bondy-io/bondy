%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_prometheus_collector_test).
-moduledoc """
EUnit tests for the `bondy_metrics` → Prometheus exposition path:
`bondy_metrics:declare/1` +
`bondy_prometheus_collector:collect_bondy_metrics_families/1`.
""".

-include_lib("eunit/include/eunit.hrl").
-include_lib("prometheus/include/prometheus_model.hrl").

-define(DECLARED_TAB, bondy_metrics_declared_tab).

%% =============================================================================
%% FIXTURE
%% =============================================================================

exposition_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun undeclared_families_not_exposed/0,
        fun counter_family/0,
        fun gauge_family/0,
        fun histogram_family/0,
        fun empty_family_skipped/0
    ]}.

setup() ->
    %% Another suite in the same run may have left the (registered)
    %% server running — reuse it in that case.
    case bondy_metrics:start_link() of
        {ok, Pid} ->
            {new, Pid};
        {error, {already_started, Pid}} ->
            {reused, Pid}
    end.

cleanup({new, Pid}) ->
    %% Stopping the owner drops the declared table with it.
    unlink(Pid),
    exit(Pid, shutdown),
    ok;
cleanup({reused, _}) ->
    %% Server owned elsewhere: clear only the declaration registry (same
    %% effect the old persistent_term erase had — a full reset).
    try
        ets:delete_all_objects(?DECLARED_TAB)
    catch
        _:_ -> ok
    end,
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

undeclared_families_not_exposed() ->
    ok = bondy_metrics:counter(#{name => bmc_undeclared_total}),
    Families = collect(),
    ?assertNot(lists:keymember(<<"bmc_undeclared_total">>, 1, Families)).

counter_family() ->
    ok = bondy_metrics:declare(#{
        name => bmc_events_total, help => <<"Test events.">>
    }),
    ok = bondy_metrics:counter(#{
        name => bmc_events_total, label => #{kind => a}, delta => 3
    }),
    ok = bondy_metrics:counter(#{
        name => bmc_events_total, label => #{kind => b}
    }),

    {_, MF} = lists:keyfind(<<"bmc_events_total">>, 1, collect()),
    ?assertEqual('COUNTER', MF#'MetricFamily'.type),
    ?assertEqual(<<"Test events.">>, MF#'MetricFamily'.help),

    Rows = lists:sort([
        {
            [{N, V} || #'LabelPair'{name = N, value = V} <- M#'Metric'.label],
            (M#'Metric'.counter)#'Counter'.value
        }
     || M <- MF#'MetricFamily'.metric
    ]),
    ?assertEqual(
        [
            {[{<<"kind">>, <<"a">>}], 3},
            {[{<<"kind">>, <<"b">>}], 1}
        ],
        Rows
    ).

gauge_family() ->
    ok = bondy_metrics:declare(#{name => bmc_depth, help => <<"Test gauge.">>}),
    ok = bondy_metrics:gauge(#{name => bmc_depth, value => 42}),

    {_, MF} = lists:keyfind(<<"bmc_depth">>, 1, collect()),
    ?assertEqual('GAUGE', MF#'MetricFamily'.type),
    [M] = MF#'MetricFamily'.metric,
    ?assertEqual(42, (M#'Metric'.gauge)#'Gauge'.value).

histogram_family() ->
    ok = bondy_metrics:declare(#{
        name => bmc_latency, help => <<"Test histogram.">>
    }),
    Values = [0, 3, 3, 500, 70000],
    [
        ok = bondy_metrics:histogram(#{name => bmc_latency, value => V})
     || V <- Values
    ],

    {_, MF} = lists:keyfind(<<"bmc_latency">>, 1, collect()),
    ?assertEqual('HISTOGRAM', MF#'MetricFamily'.type),
    [M] = MF#'MetricFamily'.metric,
    H = M#'Metric'.histogram,
    ?assertEqual(length(Values), H#'Histogram'.sample_count),
    ?assertEqual(lists:sum(Values), H#'Histogram'.sample_sum),

    Buckets = [
        {B#'Bucket'.upper_bound, B#'Bucket'.cumulative_count}
     || B <- H#'Histogram'.bucket
    ],
    %% Cumulative counts are non-decreasing and the +Inf bucket holds the
    %% total observation count.
    Counts = [C || {_, C} <- Buckets],
    ?assertEqual(Counts, lists:sort(Counts)),
    ?assertEqual({infinity, length(Values)}, lists:last(Buckets)),

    %% Every observation is covered by the bucket whose inclusive bounds
    %% contain it (bounded relative error of the log-linear layout).
    Bounds = [Bound || {Bound, _} <- Buckets, Bound =/= infinity],
    [
        ?assert(lists:any(fun(Bound) -> V =< Bound end, Bounds))
     || V <- Values
    ].

empty_family_skipped() ->
    ok = bondy_metrics:declare(#{
        name => bmc_never_touched_total, help => <<"Never written.">>
    }),
    Families = collect(),
    ?assertNot(lists:keymember(<<"bmc_never_touched_total">>, 1, Families)).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% Runs the collector callback capture. The static (router-state)
%% families are skipped because the bondy_router application is not
%% running under EUnit, so only bondy_metrics families are collected.
collect() ->
    Self = self(),
    Ref = make_ref(),
    CB = fun(MF) -> Self ! {Ref, MF} end,
    ok = bondy_prometheus_collector:collect_mf(default, CB),
    collect_loop(Ref, []).

collect_loop(Ref, Acc) ->
    receive
        {Ref, #'MetricFamily'{name = Name} = MF} ->
            collect_loop(Ref, [{Name, MF} | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.
