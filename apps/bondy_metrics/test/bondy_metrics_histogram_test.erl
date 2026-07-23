%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_metrics_histogram_test).

-include_lib("eunit/include/eunit.hrl").

-define(M, bondy_metrics).

%% =============================================================================
%% Bucket layout (pure)
%% =============================================================================

num_buckets_is_fixed_and_small_test() ->
    NB = ?M:hist_num_buckets(),
    ?assert(NB > 0),
    ?assert(NB < 1024).

linear_region_is_exact_test() ->
    [
        begin
            ?assertEqual(V, ?M:hist_bucket_index(V)),
            ?assertEqual(V, ?M:hist_bucket_low(V)),
            ?assertEqual(V, ?M:hist_bucket_high(V))
        end
     || V <- lists:seq(0, 15)
    ].

non_positive_clamps_to_zero_test() ->
    ?assertEqual(0, ?M:hist_bucket_index(0)),
    ?assertEqual(0, ?M:hist_bucket_index(-1)),
    ?assertEqual(0, ?M:hist_bucket_index(-999999)).

overflow_clamps_to_top_bucket_test() ->
    Top = ?M:hist_num_buckets() - 1,
    Max = (1 bsl 30) - 1,
    ?assertEqual(Top, ?M:hist_bucket_index(Max)),
    ?assertEqual(Top, ?M:hist_bucket_index(Max + 1)),
    ?assertEqual(Top, ?M:hist_bucket_index(1 bsl 40)).

bucket_index_is_monotonic_test() ->
    Vs = [
        1,
        2,
        3,
        15,
        16,
        17,
        31,
        32,
        33,
        63,
        64,
        100,
        1000,
        10000,
        100000,
        1000000,
        10000000,
        100000000
    ],
    lists:foldl(
        fun(V, Prev) ->
            I = ?M:hist_bucket_index(V),
            ?assert(I >= Prev),
            I
        end,
        0,
        Vs
    ).

round_trip_value_test() ->
    [
        begin
            I = ?M:hist_bucket_index(V),
            Lo = ?M:hist_bucket_low(I),
            Hi = ?M:hist_bucket_high(I),
            ?assert(Lo =< V),
            ?assert(V =< Hi),
            ?assertEqual(I, ?M:hist_bucket_index(Lo)),
            ?assertEqual(I, ?M:hist_bucket_index(Hi))
        end
     || V <- sample_values()
    ].

round_trip_index_test() ->
    NB = ?M:hist_num_buckets(),
    lists:foldl(
        fun(I, PrevHi) ->
            Lo = ?M:hist_bucket_low(I),
            Hi = ?M:hist_bucket_high(I),
            ?assert(Lo =< Hi),
            ?assertEqual(I, ?M:hist_bucket_index(Lo)),
            ?assertEqual(I, ?M:hist_bucket_index(Hi)),
            ?assertEqual(PrevHi + 1, Lo),
            Hi
        end,
        -1,
        lists:seq(0, NB - 1)
    ).

relative_error_bounded_test() ->
    [
        begin
            I = ?M:hist_bucket_index(V),
            Lo = ?M:hist_bucket_low(I),
            Hi = ?M:hist_bucket_high(I),
            ?assert((Hi - Lo + 1) * 16 =< Lo)
        end
     || V <- sample_values(), V >= 16
    ].

%% =============================================================================
%% Percentiles (pure)
%% =============================================================================

percentile_empty_is_zero_test() ->
    ?assertEqual(0, ?M:hist_percentile([], 0, 0.95)).

percentile_single_value_test() ->
    V = 4200,
    Sorted = sorted_counts(lists:duplicate(1000, V)),
    Expect = ?M:hist_bucket_high(?M:hist_bucket_index(V)),
    ?assertEqual(Expect, ?M:hist_percentile(Sorted, 1000, 0.50)),
    ?assertEqual(Expect, ?M:hist_percentile(Sorted, 1000, 0.95)),
    ?assertEqual(Expect, ?M:hist_percentile(Sorted, 1000, 0.99)),
    ?assert(Expect >= V),
    ?assert(Expect =< V * 107 div 100).

percentile_uniform_distribution_test() ->
    Sorted = sorted_counts(lists:seq(1, 1000)),
    check_pctile(Sorted, 1000, 0.50, 500),
    check_pctile(Sorted, 1000, 0.95, 950),
    check_pctile(Sorted, 1000, 0.99, 990),
    check_pctile(Sorted, 1000, 1.0, 1000).

percentile_is_nondecreasing_in_p_test() ->
    Vs = [V * 7 + 3 || V <- lists:seq(1, 5000)],
    Sorted = sorted_counts(Vs),
    Total = length(Vs),
    P50 = ?M:hist_percentile(Sorted, Total, 0.50),
    P95 = ?M:hist_percentile(Sorted, Total, 0.95),
    P99 = ?M:hist_percentile(Sorted, Total, 0.99),
    ?assert(P50 =< P95),
    ?assert(P95 =< P99).

%% =============================================================================
%% Stats / delta (pure)
%% =============================================================================

stats_zero_count_test() ->
    ?assertEqual(
        #{count => 0, mean => 0, p50 => 0, p95 => 0, p99 => 0, max => 0},
        ?M:histogram_stats(#{count => 0, sum => 0, buckets => []})
    ).

stats_mean_is_exact_test() ->
    Vs = [100, 200, 300, 400],
    Snap = #{count => 4, sum => lists:sum(Vs), buckets => sorted_counts(Vs)},
    #{mean := Mean, count := C} = ?M:histogram_stats(Snap),
    ?assertEqual(4, C),
    ?assertEqual(250, Mean).

delta_subtracts_snapshots_test() ->
    Prev = #{count => 3, sum => 60, buckets => [{5, 2}, {9, 1}]},
    Cur = #{count => 7, sum => 200, buckets => [{5, 3}, {9, 1}, {20, 3}]},
    ?assertEqual(
        #{count => 4, sum => 140, buckets => [{5, 1}, {20, 3}]},
        ?M:histogram_delta(Cur, Prev)
    ).

%% =============================================================================
%% End-to-end through the registry (stateful)
%% =============================================================================

registry_test_() ->
    {setup,
        %% Robust whether or not the bondy_mst app (and thus bondy_metrics)
        %% is already running: own the process only if we started it.
        fun() ->
            case bondy_metrics:start_link() of
                {ok, Pid} -> {started, Pid};
                {error, {already_started, Pid}} -> {existing, Pid}
            end
        end,
        fun
            ({started, Pid}) ->
                gen_server:stop(Pid),
                ok;
            ({existing, _Pid}) ->
                ok
        end,
        fun(_) ->
            [
                ?_test(observe_snapshot_stats()),
                ?_test(value_returns_count()),
                ?_test(wrong_type_rejected())
            ]
        end}.

observe_snapshot_stats() ->
    Spec = #{name => probe_latency_us, label => #{instance => <<"i0">>}},
    [
        ok = bondy_metrics:histogram(Spec#{value => V})
     || V <- [10, 10, 10, 1000, 1000, 250000]
    ],
    {ok, Snap} = bondy_metrics:histogram_snapshot(Spec),
    ?assertEqual(6, maps:get(count, Snap)),
    ?assertEqual(10 + 10 + 10 + 1000 + 1000 + 250000, maps:get(sum, Snap)),
    Stats = bondy_metrics:histogram_stats(Snap),
    ?assertEqual(6, maps:get(count, Stats)),
    %% p50 lands in the 10µs cluster (3 of 6 samples at 10).
    ?assert(maps:get(p50, Stats) >= 10),
    ?assert(maps:get(p50, Stats) < 1000),
    %% max bounds the largest observation.
    ?assert(maps:get(max, Stats) >= 250000).

value_returns_count() ->
    Spec = #{name => vh, label => #{}},
    ok = bondy_metrics:histogram(Spec#{value => 5}),
    ok = bondy_metrics:histogram(Spec#{value => 9}),
    ?assertEqual(2, bondy_metrics:value(Spec)).

wrong_type_rejected() ->
    ok = bondy_metrics:counter(#{name => clash}),
    ?assertMatch(
        {error, {wrong_type, counter}},
        bondy_metrics:histogram(#{name => clash, value => 1})
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

check_pctile(Sorted, Total, P, TrueVal) ->
    Est = ?M:hist_percentile(Sorted, Total, P),
    ?assert(Est >= TrueVal),
    ?assert(Est =< TrueVal * 107 div 100 + 1).

sample_values() ->
    Powers = [1 bsl K || K <- lists:seq(0, 29)],
    Around = lists:append([[P - 1, P, P + 1] || P <- Powers, P > 1]),
    Spread = [3, 5, 7, 11, 100, 250, 999, 1500, 33333, 250000, 9999999],
    lists:usort([V || V <- Powers ++ Around ++ Spread, V >= 0]).

sorted_counts(Vs) ->
    Map = lists:foldl(
        fun(V, Acc) ->
            I = ?M:hist_bucket_index(V),
            maps:update_with(I, fun(C) -> C + 1 end, 1, Acc)
        end,
        #{},
        Vs
    ),
    lists:keysort(1, maps:to_list(Map)).
