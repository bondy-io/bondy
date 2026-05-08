%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_ptrie_bench_SUITE).
-moduledoc """
Microbenchmarks for `bondy_registry_ptrie` — regression detector for
future changes.

Each case exercises one dimension of the design:

  (a) single-writer insert throughput, no readers
  (b) match latency, no writers
  (c) match latency under 4-writer contention
  (d) insert latency under 16-reader contention
  (e) match throughput, N readers ∈ {1, 4, 8, 16}, no writers

Output is `ct:pal` lines with timing summaries. The suite does not assert
on absolute numbers — thresholds would be flaky on varied hardware.

Historical context: during the ART→ptrie migration this suite ran
side-by-side against `art`, which Bondy used for prefix/wildcard matches
via a gen_server (`bondy_registry_partition:execute/4`). The ART
comparison code was deleted once ptrie shipped; see the final numbers
captured in `_design/PATTERN_MATCHING_DESIGN_v2.md`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).


%% =============================================================================
%% CONSTANTS
%% =============================================================================

-define(PATTERN_COUNT, 1000).
-define(INSERT_OPS, 20000).
-define(MATCH_OPS, 50000).
-define(LATENCY_SAMPLE, 5000).


%% =============================================================================
%% CT CALLBACKS
%% =============================================================================


all() ->
    [
        bench_a_insert_single_writer,
        bench_b_match_no_writers,
        bench_c_match_under_4_writers,
        bench_d_insert_under_16_readers,
        bench_e_match_scaling
    ].


init_per_suite(Config) ->
    Config.


end_per_suite(Config) ->
    Config.


init_per_testcase(_TC, Config) ->
    Patterns = make_patterns(?PATTERN_COUNT),
    Targets = make_targets(?MATCH_OPS),
    [{patterns, Patterns}, {targets, Targets} | Config].


end_per_testcase(_TC, Config) ->
    Config.


%% =============================================================================
%% BENCHMARKS
%% =============================================================================


bench_a_insert_single_writer(Config) ->
    Patterns = ?config(patterns, Config),
    N = ?INSERT_OPS,
    Inserts = extend_cycling(Patterns, N),

    Result = bench_insert(Inserts),

    report(a, "insert throughput (single writer, no readers)",
           [{ptrie, Result}]),
    ok.


bench_b_match_no_writers(Config) ->
    Patterns = ?config(patterns, Config),
    Targets0 = ?config(targets, Config),
    Targets = lists:sublist(Targets0, ?LATENCY_SAMPLE),

    Result = with_ptrie(Patterns, fun(H) -> measure_match(H, Targets) end),

    report(b, "match latency (no writers)", [{ptrie, Result}]),
    ok.


bench_c_match_under_4_writers(Config) ->
    Patterns = ?config(patterns, Config),
    Targets0 = ?config(targets, Config),
    Targets = lists:sublist(Targets0, ?LATENCY_SAMPLE),
    Writers = 4,

    Result = with_ptrie(Patterns, fun(H) ->
        run_with_writers(Writers, fun() -> write_loop(H, Patterns) end,
                         fun() -> measure_match(H, Targets) end)
    end),

    report(c, "match latency (4 writers concurrent)", [{ptrie, Result}]),
    ok.


bench_d_insert_under_16_readers(Config) ->
    Patterns = ?config(patterns, Config),
    Targets = ?config(targets, Config),
    Readers = 16,
    InsertOps = ?LATENCY_SAMPLE,
    Inserts = extend_cycling(Patterns, InsertOps),

    Result = with_ptrie(Patterns, fun(H) ->
        run_with_readers(Readers, fun() -> read_loop(H, Targets) end,
                         fun() -> measure_inserts(H, Inserts) end)
    end),

    report(d, "insert latency (16 readers concurrent)", [{ptrie, Result}]),
    ok.


bench_e_match_scaling(Config) ->
    Patterns = ?config(patterns, Config),
    Targets0 = ?config(targets, Config),
    OpsPerReader = ?MATCH_OPS div 4,
    Scales = [1, 4, 8, 16],

    Results = with_ptrie(Patterns, fun(H) ->
        [{N, match_scale(H, Targets0, N, OpsPerReader)} || N <- Scales]
    end),

    report_scaling(e, "match throughput (N readers, no writers)",
                   [{ptrie, Results}]),
    ok.


%% =============================================================================
%% PTRIE HARNESS
%% =============================================================================


%% @private
with_ptrie(Patterns, Fun) ->
    Name = list_to_atom("bench_ptrie_"
                        ++ integer_to_list(erlang:unique_integer([positive]))),
    H = bondy_registry_ptrie:new(Name),
    try
        populate(H, Patterns),
        Fun(H)
    after
        catch bondy_registry_ptrie:delete(H)
    end.


%% @private
populate(H, Patterns) ->
    lists:foreach(
        fun({K, Policy, V}) ->
            EncodedK = case Policy of
                wildcard -> bondy_registry_ptrie:encode_pattern(K);
                _ -> K
            end,
            ok = bondy_registry_ptrie:insert(H, EncodedK, Policy, V)
        end,
        Patterns
    ).


%% @private
bench_insert(Inserts) ->
    H = bondy_registry_ptrie:new(
        list_to_atom("bench_ptrie_ins_"
                     ++ integer_to_list(erlang:unique_integer([positive])))
    ),
    try
        T0 = erlang:monotonic_time(nanosecond),
        lists:foreach(
            fun({K, Policy, V}) ->
                EncodedK = case Policy of
                    wildcard -> bondy_registry_ptrie:encode_pattern(K);
                    _ -> K
                end,
                ok = bondy_registry_ptrie:insert(H, EncodedK, Policy, V)
            end,
            Inserts
        ),
        T1 = erlang:monotonic_time(nanosecond),
        summarize(throughput, length(Inserts), T1 - T0)
    after
        catch bondy_registry_ptrie:delete(H)
    end.


%% @private
measure_match(H, Targets) ->
    Samples = [begin
        T0 = erlang:monotonic_time(nanosecond),
        _ = bondy_registry_ptrie:match(H, T),
        T1 = erlang:monotonic_time(nanosecond),
        T1 - T0
    end || T <- Targets],
    summarize(latency, Samples).


%% @private
measure_inserts(H, Inserts) ->
    Samples = [begin
        T0 = erlang:monotonic_time(nanosecond),
        EncodedK = case Policy of
            wildcard -> bondy_registry_ptrie:encode_pattern(K);
            _ -> K
        end,
        ok = bondy_registry_ptrie:insert(H, EncodedK, Policy, V),
        T1 = erlang:monotonic_time(nanosecond),
        T1 - T0
    end || {K, Policy, V} <- Inserts],
    summarize(latency, Samples).


%% @private
write_loop(H, Patterns) ->
    {K, Policy, V} = lists:nth(rand:uniform(length(Patterns)), Patterns),
    EncodedK = case Policy of
        wildcard -> bondy_registry_ptrie:encode_pattern(K);
        _ -> K
    end,
    _ = bondy_registry_ptrie:insert(
        H, EncodedK, Policy, {V, erlang:unique_integer()}
    ),
    write_loop(H, Patterns).


%% @private
read_loop(H, Targets) ->
    T = lists:nth(rand:uniform(length(Targets)), Targets),
    _ = bondy_registry_ptrie:match(H, T),
    read_loop(H, Targets).


%% @private
match_scale(H, Targets, NReaders, OpsPerReader) ->
    Parent = self(),
    T0 = erlang:monotonic_time(nanosecond),
    Pids = [spawn_link(fun() ->
        lists:foreach(
            fun(I) ->
                Target = lists:nth((I rem length(Targets)) + 1, Targets),
                _ = bondy_registry_ptrie:match(H, Target)
            end,
            lists:seq(1, OpsPerReader)
        ),
        Parent ! {done, self()}
    end) || _ <- lists:seq(1, NReaders)],
    [receive {done, P} -> ok end || P <- Pids],
    T1 = erlang:monotonic_time(nanosecond),
    TotalOps = NReaders * OpsPerReader,
    summarize(throughput, TotalOps, T1 - T0).


%% =============================================================================
%% WORKER HARNESS
%% =============================================================================


%% @private
run_with_writers(N, WriterFun, MeasureFun) ->
    Writers = [spawn_link(fun() -> WriterFun() end) || _ <- lists:seq(1, N)],
    Result = MeasureFun(),
    [unlink(P) || P <- Writers],
    [exit(P, kill) || P <- Writers],
    Result.


%% @private
run_with_readers(N, ReaderFun, MeasureFun) ->
    Readers = [spawn_link(fun() -> ReaderFun() end) || _ <- lists:seq(1, N)],
    Result = MeasureFun(),
    [unlink(P) || P <- Readers],
    [exit(P, kill) || P <- Readers],
    Result.


%% =============================================================================
%% SUMMARIZATION
%% =============================================================================


%% @private
summarize(throughput, Ops, Nanos) ->
    OpsPerSec = (Ops * 1_000_000_000) / max(Nanos, 1),
    AvgNs = Nanos / max(Ops, 1),
    #{
        kind => throughput,
        ops => Ops,
        wall_ns => Nanos,
        ops_per_sec => round(OpsPerSec),
        avg_ns => round(AvgNs)
    }.


%% @private
summarize(latency, Samples) ->
    Sorted = lists:sort(Samples),
    N = length(Sorted),
    Avg = round(lists:sum(Sorted) / max(N, 1)),
    P50 = pick(Sorted, N, 0.50),
    P99 = pick(Sorted, N, 0.99),
    #{
        kind => latency,
        samples => N,
        avg_ns => Avg,
        p50_ns => P50,
        p99_ns => P99
    }.


%% @private
pick(Sorted, N, Pct) ->
    Idx = max(1, round(N * Pct)),
    lists:nth(Idx, Sorted).


%% @private
report(Case, Description, Results) ->
    ct:pal(
        "~n=== Bench ~s: ~s ===~n~s",
        [string:to_upper(atom_to_list(Case)), Description,
         format_results(Results)]
    ).


%% @private
format_results(Results) ->
    lists:map(
        fun({Label, M}) ->
            io_lib:format("  ~-16s ~s~n", [Label, format_metric(M)])
        end,
        Results
    ).


%% @private
format_metric(#{kind := throughput} = M) ->
    io_lib:format(
        "ops=~p  wall=~.2f ms  ops/s=~p  avg=~p ns/op",
        [maps:get(ops, M),
         maps:get(wall_ns, M) / 1_000_000,
         maps:get(ops_per_sec, M),
         maps:get(avg_ns, M)]
    );
format_metric(#{kind := latency} = M) ->
    io_lib:format(
        "n=~p  avg=~p ns  p50=~p ns  p99=~p ns",
        [maps:get(samples, M),
         maps:get(avg_ns, M),
         maps:get(p50_ns, M),
         maps:get(p99_ns, M)]
    ).


%% @private
report_scaling(Case, Description, Runs) ->
    Lines = [io_lib:format("  ~-16s: ~s~n",
                           [Label,
                            lists:join(", ",
                                       [io_lib:format("N=~p ops/s=~p",
                                                      [N, maps:get(ops_per_sec, M)])
                                        || {N, M} <- Result])])
             || {Label, Result} <- Runs],
    ct:pal(
        "~n=== Bench ~s: ~s ===~n~s",
        [string:to_upper(atom_to_list(Case)), Description, Lines]
    ).


%% =============================================================================
%% WORKLOAD GENERATORS
%% =============================================================================


%% @private
%% Realistic WAMP-like mix: ~60% exact, ~25% prefix, ~15% wildcard.
make_patterns(N) ->
    rand:seed(exsss, {1, 2, 3}),
    [make_pattern(I) || I <- lists:seq(1, N)].


%% @private
make_pattern(I) ->
    Policy = case I rem 20 of
        R when R < 12 -> exact;
        R when R < 17 -> prefix;
        _             -> wildcard
    end,
    URI = make_uri(I, Policy),
    {URI, Policy, I}.


%% @private
make_uri(I, Policy) ->
    Domain = lists:nth((I rem 8) + 1,
                       [<<"com">>, <<"org">>, <<"net">>, <<"edu">>,
                        <<"example">>, <<"acme">>, <<"svc">>, <<"internal">>]),
    Service = iolist_to_binary(io_lib:format("service_~4..0b", [I rem 200])),
    Method = iolist_to_binary(io_lib:format("method_~4..0b", [I])),
    case Policy of
        exact ->
            iolist_to_binary([Domain, <<".">>, Service, <<".">>, Method]);
        prefix ->
            iolist_to_binary([Domain, <<".">>, Service, <<".">>]);
        wildcard ->
            case I rem 3 of
                0 -> iolist_to_binary([Domain, <<"..">>, Method]);
                1 -> iolist_to_binary([Domain, <<".">>, Service, <<"..">>,
                                       Method]);
                _ -> iolist_to_binary([<<"..">>, Service, <<".">>, Method])
            end
    end.


%% @private
make_targets(N) ->
    [make_target(I) || I <- lists:seq(1, N)].


%% @private
make_target(I) ->
    Domain = lists:nth((I rem 8) + 1,
                       [<<"com">>, <<"org">>, <<"net">>, <<"edu">>,
                        <<"example">>, <<"acme">>, <<"svc">>, <<"internal">>]),
    Service = iolist_to_binary(io_lib:format("service_~4..0b", [I rem 300])),
    Method = iolist_to_binary(io_lib:format("method_~4..0b", [I])),
    iolist_to_binary([Domain, <<".">>, Service, <<".">>, Method]).


%% @private
extend_cycling(L, N) ->
    extend_cycling(L, L, N, []).

extend_cycling(_L, _C, 0, Acc) ->
    lists:reverse(Acc);
extend_cycling(L, [], N, Acc) ->
    extend_cycling(L, L, N, Acc);
extend_cycling(L, [H | T], N, Acc) ->
    extend_cycling(L, T, N - 1, [H | Acc]).
