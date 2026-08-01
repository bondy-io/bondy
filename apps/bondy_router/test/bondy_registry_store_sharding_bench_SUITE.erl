%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_store_sharding_bench_SUITE).
-moduledoc """
Microbenchmarks isolating two independent design levers for
`bondy_registry_store`'s exact-match index tables (`reg_exact_idx_tab`,
`sub_local_exact_idx_tab`, `sub_remote_exact_idx_tab` — all `bag` ETS
tables with `{read_concurrency, true}`, `{write_concurrency, true}`,
`{decentralized_counters, true}`, `{keypos, 2}`).

The suite operates directly on synthetic ETS `bag` tables built with the
same options `bondy_registry_store:new/1` uses (see its `Opts` list) — it
does not go through `bondy_registry_store`/`bondy_registry`, mirroring how
`bondy_registry_ptrie_bench_SUITE` benchmarks `bondy_registry_ptrie`
directly rather than the full registry facade.

Two levers are isolated:

  (a) `write_concurrency` MODE (`true` vs `auto`) on ONE table, under
      concurrent writers all contending on the SAME bag key — the shape
      of a single hot realm/topic under heavy SUBSCRIBE/UNSUBSCRIBE
      churn. This is the lever that matters for a hot-realm bottleneck,
      since `bondy_registry_partition:pick/1` hashes only on `RealmUri`:
      every session for one realm already lands on the same partition
      (and therefore the same physical tables) regardless of partition
      count.

  (b) Partitioning vs one shared table under a MULTI-realm workload (32
      distinct realms, moderate load each) — checking whether collapsing
      to one global table would regress the case partitioning is
      actually good at.

A brief read/match latency check (concurrent `ets:lookup`/`ets:select`
against the exact-match key shape) under write contention is included for
both `write_concurrency` modes in lever (a), since read latency under
write load matters for the WAMP publish-side lookup path.

Output is `ct:pal` timing summaries only — no pass/fail assertions,
since absolute thresholds would be flaky across hardware.
""".

-include_lib("common_test/include/ct.hrl").

-compile([nowarn_export_all, export_all]).

%% =============================================================================
%% RECORD (mirrors bondy_registry_store's #sub_idx{} shape: key is the
%% first field, so keypos is 2 — same as production's {keypos, 2})
%% =============================================================================

-record(bench_idx, {
    key :: {binary(), binary()},
    protocol_session_id :: term(),
    entry_key :: term(),
    is_proxy :: boolean()
}).

-define(KEYPOS, #bench_idx.key).

%% =============================================================================
%% CONSTANTS
%% =============================================================================

-define(HOT_REALM, <<"com.leapsight.fleet">>).
-define(HOT_URI, <<"com.leapsight.fleet.telemetry.updated">>).

-define(WRITE_MODES, [true, auto]).
-define(CONCURRENCIES, [4, 16, 32, 64]).
-define(OPS_PER_WRITER, 8000).

-define(READ_WRITERS, 32).
-define(READ_OPS, 3000).
-define(BASELINE_HOT_ROWS, 100).
-define(BASELINE_OTHER_KEYS, 2000).

-define(MR_REALMS, 32).
-define(MR_WRITERS_PER_REALM, 8).
-define(MR_OPS_PER_WRITER, 3000).

%% =============================================================================
%% CT CALLBACKS
%% =============================================================================

all() ->
    [
        bench_a_write_scaling,
        bench_a_read_under_contention,
        bench_b_multi_realm_partitioning
    ].

init_per_suite(Config) ->
    ct:pal(
        "~nschedulers_online=~p otp_release=~p~n",
        [erlang:system_info(schedulers_online), erlang:system_info(otp_release)]
    ),
    Config.

end_per_suite(Config) ->
    Config.

%% =============================================================================
%% BENCH A: write_concurrency true vs auto, single hot realm/topic key
%% =============================================================================

bench_a_write_scaling(_Config) ->
    Results = [
        {N, [
            {Mode, run_write_bench(Mode, N, ?OPS_PER_WRITER)}
         || Mode <- ?WRITE_MODES
        ]}
     || N <- ?CONCURRENCIES
    ],
    report_write_scaling(
        a,
        io_lib:format(
            "write throughput+latency, single hot key {realm,uri}, "
            "~p ops/writer, write_concurrency true vs auto",
            [?OPS_PER_WRITER]
        ),
        Results
    ),
    ok.

bench_a_read_under_contention(_Config) ->
    Key = {?HOT_REALM, ?HOT_URI},
    Results = [
        {Mode, run_read_under_contention(Mode, Key, ?READ_WRITERS, ?READ_OPS)}
     || Mode <- ?WRITE_MODES
    ],
    %% Flatten {Mode, {LookupLatency, MatchLatency}} into report/3's
    %% [{Label, Metric}] shape.
    Flat = lists:append([
        [
            {io_lib:format("~p/lookup", [Mode]), LookupL},
            {io_lib:format("~p/match", [Mode]), MatchL}
        ]
     || {Mode, {LookupL, MatchL}} <- Results
    ]),
    report(
        a,
        io_lib:format(
            "read latency (ets:lookup / ets:select) under ~p concurrent "
            "writers hammering the same key, ~p read ops",
            [?READ_WRITERS, ?READ_OPS]
        ),
        Flat
    ),
    ok.

%% =============================================================================
%% BENCH B: 32 separate tables (today's partitioning) vs 1 shared
%% write_concurrency=auto table, under a 32-distinct-realm workload
%% =============================================================================

bench_b_multi_realm_partitioning(_Config) ->
    PartitionedResult = run_multi_realm_bench(
        partitioned, ?MR_REALMS, ?MR_WRITERS_PER_REALM, ?MR_OPS_PER_WRITER
    ),
    SharedResult = run_multi_realm_bench(
        shared, ?MR_REALMS, ?MR_WRITERS_PER_REALM, ?MR_OPS_PER_WRITER
    ),
    report(
        b,
        io_lib:format(
            "aggregate write throughput, ~p realms x ~p writers x ~p ops, "
            "32 tables (write_concurrency=true) vs 1 shared table "
            "(write_concurrency=auto)",
            [?MR_REALMS, ?MR_WRITERS_PER_REALM, ?MR_OPS_PER_WRITER]
        ),
        [
            {"32 tables (partitioned)", PartitionedResult},
            {"1 table (shared, auto)", SharedResult}
        ]
    ),
    ok.

%% =============================================================================
%% TABLE HARNESS
%% =============================================================================

%% @private
%% Same options as bondy_registry_store:new/1's `Opts` list (plus `bag`),
%% varying only `write_concurrency`.
make_table(WriteConcurrency) ->
    Name = list_to_atom(
        "bench_sharding_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ets:new(Name, [
        bag,
        named_table,
        public,
        {read_concurrency, true},
        {write_concurrency, WriteConcurrency},
        {decentralized_counters, true},
        {keypos, ?KEYPOS}
    ]).

%% @private
mk_row(Key, EntryKey) ->
    #bench_idx{
        key = Key,
        protocol_session_id = EntryKey,
        entry_key = EntryKey,
        is_proxy = false
    }.

%% @private
%% Baseline occupancy so lookup/match latency is measured against a
%% realistically-sized table, not an empty one: ?BASELINE_HOT_ROWS rows
%% under the hot key (concurrent subscribers already on that topic) plus
%% ?BASELINE_OTHER_KEYS distinct other keys (other topics on the realm).
populate_baseline(Tab, RealmUri, HotUri) ->
    lists:foreach(
        fun(I) -> ets:insert(Tab, mk_row({RealmUri, HotUri}, I)) end,
        lists:seq(1, ?BASELINE_HOT_ROWS)
    ),
    lists:foreach(
        fun(I) -> ets:insert(Tab, mk_row({RealmUri, other_uri(I)}, I)) end,
        lists:seq(1, ?BASELINE_OTHER_KEYS)
    ),
    ok.

%% @private
other_uri(I) ->
    iolist_to_binary(io_lib:format("com.leapsight.fleet.topic~6..0b", [I])).

%% @private
realm_uri(I) ->
    iolist_to_binary(io_lib:format("com.leapsight.fleet.realm~4..0b", [I])).

%% =============================================================================
%% BENCH A: WRITE WORKLOAD (SUBSCRIBE + UNSUBSCRIBE pair per iteration)
%% =============================================================================

%% @private
%% N concurrent writers, all contending on the SAME bag key, each doing
%% OpsPerWriter add/remove-shaped {ets:insert, ets:delete_object} pairs.
%% Returns {ThroughputSummary, LatencySummary} where latency is the
%% per-iteration (insert+delete) wall time observed by the writer itself
%% under real concurrent contention — no separate probe process needed.
run_write_bench(WriteConcurrency, N, OpsPerWriter) ->
    Tab = make_table(WriteConcurrency),
    Key = {?HOT_REALM, ?HOT_URI},
    Parent = self(),

    T0 = erlang:monotonic_time(nanosecond),
    Pids = [
        spawn_link(fun() -> writer_worker(Tab, Key, OpsPerWriter, Parent) end)
     || _ <- lists:seq(1, N)
    ],
    AllSamples = collect_samples(Pids, []),
    T1 = erlang:monotonic_time(nanosecond),

    true = ets:delete(Tab),

    TotalOps = N * OpsPerWriter,
    {
        summarize(throughput, TotalOps, T1 - T0),
        summarize(latency, AllSamples)
    }.

%% @private
writer_worker(Tab, Key, Ops, Parent) ->
    Samples = write_ops(Tab, Key, Ops, []),
    Parent ! {done, self(), Samples}.

%% @private
write_ops(_Tab, _Key, 0, Acc) ->
    Acc;
write_ops(Tab, Key, N, Acc) ->
    EntryKey = erlang:unique_integer([positive, monotonic]),
    Row = mk_row(Key, EntryKey),
    T0 = erlang:monotonic_time(nanosecond),
    true = ets:insert(Tab, Row),
    true = ets:delete_object(Tab, Row),
    T1 = erlang:monotonic_time(nanosecond),
    write_ops(Tab, Key, N - 1, [T1 - T0 | Acc]).

%% @private
collect_samples([], Acc) ->
    Acc;
collect_samples([P | Rest], Acc) ->
    receive
        {done, P, Samples} -> collect_samples(Rest, Samples ++ Acc)
    after 120_000 ->
        ct:fail({timeout, waiting_for, P})
    end.

%% =============================================================================
%% BENCH A: READ UNDER WRITE CONTENTION
%% =============================================================================

%% @private
%% NWriters busy-loop writers hammer Key while a single reader measures
%% ets:lookup/2 and an ets:select/2 (mirroring match_exact's own match
%% spec shape, key fully bound) latency.
run_read_under_contention(WriteConcurrency, Key, NWriters, ReadOps) ->
    Tab = make_table(WriteConcurrency),
    {RealmUri, HotUri} = Key,
    ok = populate_baseline(Tab, RealmUri, HotUri),

    Writers = [
        spawn_link(fun() -> write_loop(Tab, Key) end)
     || _ <- lists:seq(1, NWriters)
    ],

    LookupLatency = measure_lookups(Tab, Key, ReadOps),
    MatchLatency = measure_matches(Tab, Key, ReadOps),

    [unlink(P) || P <- Writers],
    [exit(P, kill) || P <- Writers],
    true = ets:delete(Tab),

    {LookupLatency, MatchLatency}.

%% @private
write_loop(Tab, Key) ->
    EntryKey = erlang:unique_integer([positive, monotonic]),
    Row = mk_row(Key, EntryKey),
    true = ets:insert(Tab, Row),
    true = ets:delete_object(Tab, Row),
    write_loop(Tab, Key).

%% @private
measure_lookups(Tab, Key, N) ->
    Samples = [
        begin
            T0 = erlang:monotonic_time(nanosecond),
            _ = ets:lookup(Tab, Key),
            T1 = erlang:monotonic_time(nanosecond),
            T1 - T0
        end
     || _ <- lists:seq(1, N)
    ],
    summarize(latency, Samples).

%% @private
%% Same match-spec shape as bondy_registry_store:match_exact/5: key fully
%% bound, other fields wild, projection '$_'.
measure_matches(Tab, Key, N) ->
    MS = [
        {
            #bench_idx{
                key = Key,
                protocol_session_id = '_',
                entry_key = '_',
                is_proxy = '_'
            },
            [],
            ['$_']
        }
    ],
    Samples = [
        begin
            T0 = erlang:monotonic_time(nanosecond),
            _ = ets:select(Tab, MS),
            T1 = erlang:monotonic_time(nanosecond),
            T1 - T0
        end
     || _ <- lists:seq(1, N)
    ],
    summarize(latency, Samples).

%% =============================================================================
%% BENCH B: MULTI-REALM WORKLOAD
%% =============================================================================

%% @private
%% `partitioned`: RealmsCount separate tables (write_concurrency=true),
%% one per realm — mirrors today's per-partition table, upper bound of
%% partitioning's isolation benefit (zero cross-realm contention).
%% `shared`: ONE table (write_concurrency=auto) holding all realms' rows,
%% keyed by {RealmUri, Uri} so distinct realms occupy distinct bag keys
%% in the same table.
run_multi_realm_bench(partitioned, RealmsCount, WritersPerRealm, OpsPerWriter) ->
    Tables = [make_table(true) || _ <- lists:seq(1, RealmsCount)],
    Result = run_multi_realm(
        Tables, RealmsCount, WritersPerRealm, OpsPerWriter
    ),
    [ets:delete(T) || T <- Tables],
    Result;
run_multi_realm_bench(shared, RealmsCount, WritersPerRealm, OpsPerWriter) ->
    Shared = make_table(auto),
    Tables = lists:duplicate(RealmsCount, Shared),
    Result = run_multi_realm(
        Tables, RealmsCount, WritersPerRealm, OpsPerWriter
    ),
    ets:delete(Shared),
    Result.

%% @private
run_multi_realm(Tables, RealmsCount, WritersPerRealm, OpsPerWriter) ->
    Parent = self(),
    T0 = erlang:monotonic_time(nanosecond),
    Pids = lists:append([
        [
            spawn_link(fun() ->
                Tab = lists:nth(I, Tables),
                Key = {realm_uri(I), ?HOT_URI},
                throughput_ops(Tab, Key, OpsPerWriter),
                Parent ! {done, self()}
            end)
         || _ <- lists:seq(1, WritersPerRealm)
        ]
     || I <- lists:seq(1, RealmsCount)
    ]),
    ok = collect_done(Pids),
    T1 = erlang:monotonic_time(nanosecond),

    TotalOps = RealmsCount * WritersPerRealm * OpsPerWriter,
    summarize(throughput, TotalOps, T1 - T0).

%% @private
throughput_ops(_Tab, _Key, 0) ->
    ok;
throughput_ops(Tab, Key, N) ->
    EntryKey = erlang:unique_integer([positive, monotonic]),
    Row = mk_row(Key, EntryKey),
    true = ets:insert(Tab, Row),
    true = ets:delete_object(Tab, Row),
    throughput_ops(Tab, Key, N - 1).

%% @private
collect_done([]) ->
    ok;
collect_done([P | Rest]) ->
    receive
        {done, P} -> collect_done(Rest)
    after 120_000 ->
        ct:fail({timeout, waiting_for, P})
    end.

%% =============================================================================
%% SUMMARIZATION (mirrors bondy_registry_ptrie_bench_SUITE's shape)
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
        [
            string:to_upper(atom_to_list(Case)),
            Description,
            format_results(Results)
        ]
    ).

%% @private
format_results(Results) ->
    lists:map(
        fun({Label, M}) ->
            io_lib:format("  ~-20s ~s~n", [Label, format_metric(M)])
        end,
        Results
    ).

%% @private
format_metric(#{kind := throughput} = M) ->
    io_lib:format(
        "ops=~p  wall=~.2f ms  ops/s=~p  avg=~p ns/op",
        [
            maps:get(ops, M),
            maps:get(wall_ns, M) / 1_000_000,
            maps:get(ops_per_sec, M),
            maps:get(avg_ns, M)
        ]
    );
format_metric(#{kind := latency} = M) ->
    io_lib:format(
        "n=~p  avg=~p ns  p50=~p ns  p99=~p ns",
        [
            maps:get(samples, M),
            maps:get(avg_ns, M),
            maps:get(p50_ns, M),
            maps:get(p99_ns, M)
        ]
    ).

%% @private
report_write_scaling(Case, Description, Results) ->
    Lines = [
        io_lib:format("~n  N=~p writers~n~s", [
            N, format_mode_results(ModeResults)
        ])
     || {N, ModeResults} <- Results
    ],
    ct:pal(
        "~n=== Bench ~s: ~s ===~s",
        [string:to_upper(atom_to_list(Case)), Description, Lines]
    ).

%% @private
format_mode_results(ModeResults) ->
    lists:map(
        fun({Mode, {Throughput, Latency}}) ->
            io_lib:format(
                "    write_concurrency=~-6s ops=~p ops/s=~p avg=~p ns/op "
                "p50=~p ns p99=~p ns~n",
                [
                    atom_to_list(Mode),
                    maps:get(ops, Throughput),
                    maps:get(ops_per_sec, Throughput),
                    maps:get(avg_ns, Latency),
                    maps:get(p50_ns, Latency),
                    maps:get(p99_ns, Latency)
                ]
            )
        end,
        ModeResults
    ).
