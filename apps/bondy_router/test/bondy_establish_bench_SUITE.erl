%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_establish_bench_SUITE).
-moduledoc """
Microbenchmark + profiler for the WAMP **session-establishment** control plane —
the path the Fly scale tests localized as the per-core ceiling (session open +
subscribe registry write). Drives the in-process APIs directly (no websocket),
reports ops/s single-core + at 1/4/8/16 concurrent workers, and dumps an eprof
breakdown so we can see where the per-op CPU goes.

Not an assertion suite — `ct:pal` numbers only (flaky thresholds across hardware).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").
-include("bondy_registry.hrl").

-compile([nowarn_export_all, export_all]).

-define(OPEN_OPS, 20000).
-define(SUB_OPS, 20000).
-define(AUTH_OPS, 20000).
-define(EPROF_OPS, 2000).
-define(SCALES, [1, 4, 8, 16]).

%% =============================================================================
%% CT CALLBACKS
%% =============================================================================

all() ->
    [
        bench_session_open,
        bench_session_open_scaling,
        bench_subscribe,
        bench_subscribe_scaling,
        eprof_session_open,
        eprof_subscribe
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    %% Security-disabled realm for open/subscribe (isolate the registry-write
    %% cost from authz), anonymous permitted for the auth bench.
    Realm = bondy_realm:create(<<"perf.bench">>),
    RealmUri = bondy_realm:uri(Realm),
    ok = bondy_realm:disable_security(Realm),
    [{realm_uri, RealmUri} | Config].

end_per_suite(Config) ->
    Config.

%% =============================================================================
%% BENCHMARKS — session open (HELLO -> WELCOME control-plane work)
%% =============================================================================

bench_session_open(Config) ->
    RealmUri = ?config(realm_uri, Config),
    N = ?OPEN_OPS,
    T0 = erlang:monotonic_time(nanosecond),
    _ = [do_open(RealmUri) || _ <- lists:seq(1, N)],
    T1 = erlang:monotonic_time(nanosecond),
    report(
        open,
        "session open (full: store+counters+gproc+monitor+register_procedures)",
        summarize(throughput, N, T1 - T0)
    ),
    ok.

bench_session_open_scaling(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Results = [
        {W, scale_run(W, ?OPEN_OPS, fun() -> do_open(RealmUri) end)}
     || W <- ?SCALES
    ],
    report_scaling(
        open_scaling, "session open throughput (N concurrent openers)", Results
    ),
    ok.

%% =============================================================================
%% BENCHMARKS — subscribe (registry write)
%% =============================================================================

bench_subscribe(Config) ->
    RealmUri = ?config(realm_uri, Config),
    N = ?SUB_OPS,
    T0 = erlang:monotonic_time(nanosecond),
    _ = [do_subscribe(RealmUri) || _ <- lists:seq(1, N)],
    T1 = erlang:monotonic_time(nanosecond),
    report(
        subscribe,
        "subscribe (registry add: dedup fold + ETS writes + RIB member + async apply)",
        summarize(throughput, N, T1 - T0)
    ),
    ok.

bench_subscribe_scaling(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Results = [
        {W, scale_run(W, ?SUB_OPS, fun() -> do_subscribe(RealmUri) end)}
     || W <- ?SCALES
    ],
    report_scaling(
        sub_scaling, "subscribe throughput (N concurrent subscribers)", Results
    ),
    ok.

%% =============================================================================
%% BENCHMARK — auth (per-HELLO method negotiation, anonymous)
%% =============================================================================

bench_auth(Config) ->
    RealmUri = ?config(realm_uri, Config),
    N = ?AUTH_OPS,
    T0 = erlang:monotonic_time(nanosecond),
    _ = [do_auth(RealmUri) || _ <- lists:seq(1, N)],
    T1 = erlang:monotonic_time(nanosecond),
    report(
        auth,
        "auth cycle (init -> challenge -> authenticate, anonymous)",
        summarize(throughput, N, T1 - T0)
    ),
    ok.

%% =============================================================================
%% EPROF — where the per-op CPU goes
%% =============================================================================

eprof_session_open(Config) ->
    RealmUri = ?config(realm_uri, Config),
    profile("session_open", fun() ->
        _ = [do_open(RealmUri) || _ <- lists:seq(1, ?EPROF_OPS)]
    end),
    ok.

eprof_subscribe(Config) ->
    RealmUri = ?config(realm_uri, Config),
    profile("subscribe", fun() ->
        _ = [do_subscribe(RealmUri) || _ <- lists:seq(1, ?EPROF_OPS)]
    end),
    ok.

%% =============================================================================
%% OPERATIONS UNDER TEST
%% =============================================================================

%% @private
do_open(RealmUri) ->
    Id = bondy_session_id:new(),
    {ok, _} = bondy_session_manager:open(Id, RealmUri, session_opts()),
    ok.

%% @private
%% Fresh subscriber session id per call (unique subscriber) + unique topic, so
%% the dedup fold stays O(1) and each call exercises the full registry+RIB write.
do_subscribe(RealmUri) ->
    Ref = bondy_ref:new(internal, self(), bondy_session_id:new()),
    Uri =
        <<"perf.topic.",
            (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    %% add/5 returns {ok, Entry} at runtime (spec claims a 3-tuple) — accept both.
    case
        bondy_registry:add(
            subscription, RealmUri, Uri, #{match => ?EXACT_MATCH}, Ref
        )
    of
        {ok, _} -> ok;
        {ok, _, _} -> ok
    end.

%% @private
do_auth(RealmUri) ->
    Id = bondy_session_id:new(),
    SourceIP = {127, 0, 0, 1},
    {ok, Ctxt0} = bondy_auth:init(
        Id, RealmUri, anonymous, [<<"anonymous">>], SourceIP
    ),
    {ok, _, Ctxt1} = bondy_auth:challenge(?WAMP_ANON_AUTH, #{}, Ctxt0),
    {ok, _, _} = bondy_auth:authenticate(
        ?WAMP_ANON_AUTH, undefined, #{}, Ctxt1
    ),
    ok.

%% @private
session_opts() ->
    #{
        peer => {{127, 0, 0, 1}, 10000},
        authid => <<"anonymous">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => true,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}, subscriber => #{}}
    }.

%% =============================================================================
%% HARNESS
%% =============================================================================

%% @private
%% Run Op NTotal times spread across W worker processes; return throughput.
scale_run(W, NTotal, Op) ->
    Per = NTotal div W,
    Parent = self(),
    T0 = erlang:monotonic_time(nanosecond),
    Pids = [
        spawn_link(fun() ->
            _ = [Op() || _ <- lists:seq(1, Per)],
            Parent ! {done, self()}
        end)
     || _ <- lists:seq(1, W)
    ],
    _ = [
        receive
            {done, P} -> ok
        end
     || P <- Pids
    ],
    T1 = erlang:monotonic_time(nanosecond),
    summarize(throughput, W * Per, T1 - T0).

%% @private
profile(Label, Fun) ->
    File = "/tmp/eprof_" ++ Label ++ ".txt",
    eprof:start(),
    %% Trace ALL current processes, not just self() — session open does its real
    %% work (register_procedures) inside a pool worker, a different process.
    _ = eprof:start_profiling(erlang:processes()),
    Fun(),
    _ = eprof:stop_profiling(),
    %% Write the FUNCTION/CALLS/%TIME/TIME breakdown to a file (stdout capture is
    %% unreliable under rebar3 ct); we read /tmp/eprof_<label>.txt afterwards.
    eprof:log(File),
    eprof:analyze(total),
    eprof:stop(),
    ct:pal("~n========== EPROF: ~s (~p ops) written to ~s ==========", [
        Label, ?EPROF_OPS, File
    ]).

%% =============================================================================
%% SUMMARIZATION / REPORTING
%% =============================================================================

%% @private
summarize(throughput, Ops, Nanos) ->
    #{
        ops => Ops,
        wall_ms => Nanos / 1_000_000,
        ops_per_sec => round((Ops * 1_000_000_000) / max(Nanos, 1)),
        avg_us => (Nanos / max(Ops, 1)) / 1000
    }.

%% @private
report(Case, Desc, #{
    ops := Ops, wall_ms := Ms, ops_per_sec := Ops_s, avg_us := Avg
}) ->
    ct:pal(
        "~n=== Bench ~s: ~s ===~n  ops=~p  wall=~.1f ms  ops/s=~p  avg=~.2f us/op",
        [string:to_upper(atom_to_list(Case)), Desc, Ops, Ms, Ops_s, Avg]
    ).

%% @private
report_scaling(Case, Desc, Results) ->
    Lines = [
        io_lib:format(
            "    W=~-3b ops/s=~-9b avg=~.2f us/op~n",
            [W, maps:get(ops_per_sec, M), maps:get(avg_us, M)]
        )
     || {W, M} <- Results
    ],
    ct:pal("~n=== Bench ~s: ~s ===~n~s", [
        string:to_upper(atom_to_list(Case)), Desc, Lines
    ]).
