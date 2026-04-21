%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_ptrie_bench_SUITE).
-behaviour(gen_server).

-moduledoc """
Microbenchmark comparing `bondy_registry_ptrie` against the `art` library
(which currently backs `bondy_registry_store`'s prefix / wildcard index).

Scenarios, from the landing plan:

  (a) single-writer insert throughput, no readers
  (b) match latency, no writers
  (c) match latency under 4-writer contention
  (d) insert latency under 16-reader contention
  (e) match throughput, N readers, N in {1, 4, 8, 16}, no writers

Targets:
  - (c), (d), (e) strictly better by 3x+
  - (a), (b) within 2x of current

Each scenario runs both the ptrie (direct ETS, multi-writer CAS) and the
ART library (wrapped in a gen_server — that's how production Bondy
actually deploys it via `bondy_registry_partition:execute/4`; running it
multi-writer-direct would corrupt since art is single-writer by design).

Output is `ct:pal` with a side-by-side summary. The suite does not assert
on numbers — tuning thresholds would make it flaky on varied CI hardware.
Read the summary line in the CT log.
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
-define(BACKGROUND_OPS, 50000).


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
    _ = application:ensure_all_started(art),
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

    Ptrie = bench_ptrie_insert(Inserts),
    Art   = bench_art_insert(Inserts),

    report(a, "insert throughput (single writer, no readers)",
           [{ptrie, Ptrie}, {art_direct, Art}]),
    ok.


bench_b_match_no_writers(Config) ->
    Patterns = ?config(patterns, Config),
    Targets0 = ?config(targets, Config),
    Targets = lists:sublist(Targets0, ?LATENCY_SAMPLE),

    Ptrie = with_ptrie(Patterns, fun(H) -> measure_match(H, Targets) end),
    Art   = with_art(Patterns, fun(T) -> measure_art_match(T, Targets) end),

    report(b, "match latency (no writers)",
           [{ptrie, Ptrie}, {art_direct, Art}]),
    ok.


bench_c_match_under_4_writers(Config) ->
    Patterns = ?config(patterns, Config),
    Targets0 = ?config(targets, Config),
    Targets = lists:sublist(Targets0, ?LATENCY_SAMPLE),
    Writers = 4,

    Ptrie = with_ptrie(Patterns, fun(H) ->
        run_with_writers(Writers, fun() -> ptrie_write_loop(H, Patterns) end,
                         fun() -> measure_match(H, Targets) end)
    end),
    Art = with_art_gs(Patterns, fun(Pid) ->
        run_with_writers(Writers, fun() -> art_gs_write_loop(Pid, Patterns) end,
                         fun() -> measure_art_gs_match(Pid, Targets) end)
    end),

    report(c, "match latency (4 writers concurrent)",
           [{ptrie, Ptrie}, {art_gs, Art}]),
    ok.


bench_d_insert_under_16_readers(Config) ->
    Patterns = ?config(patterns, Config),
    Targets = ?config(targets, Config),
    Readers = 16,
    InsertOps = ?LATENCY_SAMPLE,
    Inserts = extend_cycling(Patterns, InsertOps),

    Ptrie = with_ptrie(Patterns, fun(H) ->
        run_with_readers(Readers, fun() -> ptrie_read_loop(H, Targets) end,
                         fun() -> measure_ptrie_inserts(H, Inserts) end)
    end),
    Art = with_art_gs(Patterns, fun(Pid) ->
        run_with_readers(Readers, fun() -> art_gs_read_loop(Pid, Targets) end,
                         fun() -> measure_art_gs_inserts(Pid, Inserts) end)
    end),

    report(d, "insert latency (16 readers concurrent)",
           [{ptrie, Ptrie}, {art_gs, Art}]),
    ok.


bench_e_match_scaling(Config) ->
    Patterns = ?config(patterns, Config),
    Targets0 = ?config(targets, Config),
    OpsPerReader = ?MATCH_OPS div 4,   %% keep total workload bounded
    Scales = [1, 4, 8, 16],

    PtrieResults = with_ptrie(Patterns, fun(H) ->
        [{N, match_scale_ptrie(H, Targets0, N, OpsPerReader)} || N <- Scales]
    end),
    ArtResults = with_art_gs(Patterns, fun(Pid) ->
        [{N, match_scale_art_gs(Pid, Targets0, N, OpsPerReader)} || N <- Scales]
    end),

    report_scaling(e, "match throughput (N readers, no writers)",
                   [{ptrie, PtrieResults}, {art_gs, ArtResults}]),
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
        populate_ptrie(H, Patterns),
        Fun(H)
    after
        catch bondy_registry_ptrie:delete(H)
    end.


%% @private
populate_ptrie(H, Patterns) ->
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
bench_ptrie_insert(Inserts) ->
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
measure_ptrie_inserts(H, Inserts) ->
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
ptrie_write_loop(H, Patterns) ->
    %% Infinite until killed — drives the "background writer" in (c).
    P = lists:nth(rand:uniform(length(Patterns)), Patterns),
    {K, Policy, V} = P,
    EncodedK = case Policy of
        wildcard -> bondy_registry_ptrie:encode_pattern(K);
        _ -> K
    end,
    _ = bondy_registry_ptrie:insert(H, EncodedK, Policy, {V, erlang:unique_integer()}),
    ptrie_write_loop(H, Patterns).


%% @private
ptrie_read_loop(H, Targets) ->
    T = lists:nth(rand:uniform(length(Targets)), Targets),
    _ = bondy_registry_ptrie:match(H, T),
    ptrie_read_loop(H, Targets).


%% @private
match_scale_ptrie(H, Targets, NReaders, OpsPerReader) ->
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
%% ART HARNESS
%% =============================================================================


%% @private
with_art(Patterns, Fun) ->
    T = art:new(),
    try
        populate_art(T, Patterns),
        Fun(T)
    after
        catch art:delete(T)
    end.


%% @private
populate_art(T, Patterns) ->
    %% ART encoding:
    %%   exact    -> store raw key
    %%   prefix   -> store key ++ "*" (ART's prefix sentinel)
    %%   wildcard -> store URI with empty-segments as-is; ART matches ".." naturally
    lists:foreach(
        fun({K, Policy, V}) ->
            ArtKey = case Policy of
                exact -> K;
                prefix -> <<K/binary, "*">>;
                wildcard -> K
            end,
            _ = art:store(ArtKey, V, T)
        end,
        Patterns
    ).


%% @private
bench_art_insert(Inserts) ->
    T = art:new(),
    try
        T0 = erlang:monotonic_time(nanosecond),
        lists:foreach(
            fun({K, Policy, V}) ->
                ArtKey = case Policy of
                    exact -> K;
                    prefix -> <<K/binary, "*">>;
                    wildcard -> K
                end,
                _ = art:store(ArtKey, V, T)
            end,
            Inserts
        ),
        T1 = erlang:monotonic_time(nanosecond),
        summarize(throughput, length(Inserts), T1 - T0)
    after
        catch art:delete(T)
    end.


%% @private
measure_art_match(T, Targets) ->
    Samples = [begin
        T0 = erlang:monotonic_time(nanosecond),
        _ = art:find_matches(Target, T),
        T1 = erlang:monotonic_time(nanosecond),
        T1 - T0
    end || Target <- Targets],
    summarize(latency, Samples).


%% =============================================================================
%% ART-VIA-GEN_SERVER HARNESS (what production actually sees)
%% =============================================================================


%% Simple gen_server wrapping an ART trie. Mirrors
%% `bondy_registry_partition:execute/4` — every op is a gen_server:call.
%% (The `-behaviour(gen_server).` declaration is at the top of the file;
%% `-compile([nowarn_export_all, export_all]).` covers the callback exports.)


art_gs_start(Patterns) ->
    {ok, Pid} = gen_server:start_link(?MODULE, [], []),
    ok = gen_server:call(Pid, {populate, Patterns}, 60_000),
    Pid.


art_gs_stop(Pid) ->
    catch gen_server:stop(Pid, normal, 5_000).


art_gs_insert(Pid, K, Policy, V) ->
    gen_server:call(Pid, {insert, K, Policy, V}, 30_000).


art_gs_match(Pid, Target) ->
    gen_server:call(Pid, {match, Target}, 30_000).


init([]) ->
    {ok, art:new()}.


handle_call({populate, Patterns}, _From, T) ->
    lists:foreach(
        fun({K, Policy, V}) ->
            ArtKey = case Policy of
                exact -> K;
                prefix -> <<K/binary, "*">>;
                wildcard -> K
            end,
            _ = art:store(ArtKey, V, T)
        end,
        Patterns
    ),
    {reply, ok, T};
handle_call({insert, K, Policy, V}, _From, T) ->
    ArtKey = case Policy of
        exact -> K;
        prefix -> <<K/binary, "*">>;
        wildcard -> K
    end,
    _ = art:store(ArtKey, V, T),
    {reply, ok, T};
handle_call({match, Target}, _From, T) ->
    R = art:find_matches(Target, T),
    {reply, R, T};
handle_call(_, _, T) ->
    {reply, {error, unknown}, T}.


handle_cast(_, T) -> {noreply, T}.


%% @private
with_art_gs(Patterns, Fun) ->
    Pid = art_gs_start(Patterns),
    try
        Fun(Pid)
    after
        art_gs_stop(Pid)
    end.


%% @private
measure_art_gs_match(Pid, Targets) ->
    Samples = [begin
        T0 = erlang:monotonic_time(nanosecond),
        _ = art_gs_match(Pid, Target),
        T1 = erlang:monotonic_time(nanosecond),
        T1 - T0
    end || Target <- Targets],
    summarize(latency, Samples).


%% @private
measure_art_gs_inserts(Pid, Inserts) ->
    Samples = [begin
        T0 = erlang:monotonic_time(nanosecond),
        ok = art_gs_insert(Pid, K, Policy, V),
        T1 = erlang:monotonic_time(nanosecond),
        T1 - T0
    end || {K, Policy, V} <- Inserts],
    summarize(latency, Samples).


%% @private
art_gs_write_loop(Pid, Patterns) ->
    {K, Policy, V} = lists:nth(rand:uniform(length(Patterns)), Patterns),
    _ = art_gs_insert(Pid, K, Policy, {V, erlang:unique_integer()}),
    art_gs_write_loop(Pid, Patterns).


%% @private
art_gs_read_loop(Pid, Targets) ->
    Target = lists:nth(rand:uniform(length(Targets)), Targets),
    _ = art_gs_match(Pid, Target),
    art_gs_read_loop(Pid, Targets).


%% @private
match_scale_art_gs(Pid, Targets, NReaders, OpsPerReader) ->
    Parent = self(),
    T0 = erlang:monotonic_time(nanosecond),
    Pids = [spawn_link(fun() ->
        lists:foreach(
            fun(I) ->
                Target = lists:nth((I rem length(Targets)) + 1, Targets),
                _ = art_gs_match(Pid, Target)
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
%% COMMON HARNESS — spawn background workers, measure the foreground
%% =============================================================================


%% @private
run_with_writers(N, WriterFun, MeasureFun) ->
    Writers = [spawn_link(fun() -> WriterFun() end)
               || _ <- lists:seq(1, N)],
    Result = MeasureFun(),
    [unlink(P) || P <- Writers],
    [exit(P, kill) || P <- Writers],
    Result.


%% @private
run_with_readers(N, ReaderFun, MeasureFun) ->
    Readers = [spawn_link(fun() -> ReaderFun() end)
               || _ <- lists:seq(1, N)],
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
%% A realistic mix of WAMP-like URI patterns across the three policies.
%% The distribution (~60% exact, ~25% prefix, ~15% wildcard) mirrors what
%% a large WAMP registry tends to see in production.
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
            %% Randomize wildcard positions: sometimes service, sometimes method.
            case I rem 3 of
                0 -> iolist_to_binary([Domain, <<"..">>, Method]);
                1 -> iolist_to_binary([Domain, <<".">>, Service, <<"..">>,
                                       Method]);
                _ -> iolist_to_binary([<<"..">>, Service, <<".">>, Method])
            end
    end.


%% @private
%% Valid strict target URIs (no wildcards, no trailing dots). A mix of
%% hits and misses — some are structured to match registered patterns,
%% others are random.
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
%% Extend `L` by cycling to produce exactly `N` elements.
extend_cycling(L, N) ->
    extend_cycling(L, L, N, []).


extend_cycling(_L, _C, 0, Acc) ->
    lists:reverse(Acc);
extend_cycling(L, [], N, Acc) ->
    extend_cycling(L, L, N, Acc);
extend_cycling(L, [H | T], N, Acc) ->
    extend_cycling(L, T, N - 1, [H | Acc]).
