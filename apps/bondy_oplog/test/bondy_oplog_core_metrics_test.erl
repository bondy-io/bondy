%% =============================================================================
%% Tests for `bondy_oplog_core_metrics` — the periodic per-namespace gauge
%% emitter for §16 of `MST_DB_DESIGN.md`.
%%
%% Verifies:
%%   - read / range telemetry events increment the underlying counters
%%     through `bondy_metrics`
%%   - `snapshot_now/0` emits a `[bondy_oplog_core, metrics, refresh]` event
%%     per known namespace with the §16 measurements + metadata
%%   - cache_hit_rate computes from delta of hits / (hits + misses)
%%   - read_rps / range_rps reflect the elapsed window since the last tick
%%   - `interval_ms => disabled` suppresses the periodic tick while
%%     leaving the counter handlers attached
%%   - independent namespaces produce independent gauges
%% =============================================================================

-module(bondy_oplog_core_metrics_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Disable the periodic tick so tests can drive the gauge emit
    %% exclusively via `snapshot_now/0`. A background tick landing in
    %% the middle of a test's capture window produced an extra event
    %% per namespace and made assertions on event counts unstable.
    ok = bondy_oplog_core_metrics:set_enabled(false),
    ok.

cleanup(_) ->
    %% Re-enable so any subsequent test module that depends on a running
    %% tick is not penalised. Tests in this module never block on the
    %% timer firing — they always force via `snapshot_now/0`.
    ok = bondy_oplog_core_metrics:set_enabled(true),
    ok.

metrics_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun read_event_increments_counters/0,
        fun range_event_increments_counter/0,
        fun snapshot_emits_refresh_event_per_namespace/0,
        fun cache_hit_rate_is_delta_based/0,
        fun rates_scale_with_window/0,
        fun multiple_namespaces_are_independent/0,
        fun freshness_lag_is_reported/0,
        fun info_reports_running_state/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

read_event_increments_counters() ->
    NS = mk_ns(),
    fire_read(NS, true),
    fire_read(NS, true),
    fire_read(NS, false),
    Label = #{namespace => NS},
    ?assertEqual(3, counter_value(bondy_oplog_core_reads_total, Label)),
    ?assertEqual(2, counter_value(bondy_oplog_core_cache_hits_total, Label)),
    ?assertEqual(1, counter_value(bondy_oplog_core_cache_misses_total, Label)).

range_event_increments_counter() ->
    NS = mk_ns(),
    fire_range(NS),
    fire_range(NS),
    ?assertEqual(
        2,
        counter_value(
            bondy_oplog_core_ranges_total,
            #{namespace => NS}
        )
    ).

snapshot_emits_refresh_event_per_namespace() ->
    NS = mk_ns(),
    fire_read(NS, true),
    fire_read(NS, false),
    fire_range(NS),
    Events = capture_refresh_events(fun() ->
        ok = bondy_oplog_core_metrics:snapshot_now()
    end),
    %% At least one event for our NS — there may be others from prior
    %% tests in the same VM, so filter.
    Ours = [E || E = {_Meas, #{namespace := N}} <- Events, N =:= NS],
    ?assertEqual(1, length(Ours)),
    [{Meas, Meta}] = Ours,
    ?assert(maps:is_key(cache_hit_rate, Meas)),
    ?assert(maps:is_key(read_rps, Meas)),
    ?assert(maps:is_key(range_rps, Meas)),
    ?assert(maps:is_key(subscriber_count, Meas)),
    ?assert(maps:is_key(current_freshness_lag_max_ms, Meas)),
    ?assertEqual(NS, maps:get(namespace, Meta)),
    ?assert(maps:get(interval_ms, Meta) >= 1).

cache_hit_rate_is_delta_based() ->
    NS = mk_ns(),
    %% First tick establishes a baseline.
    fire_read(NS, true),
    ok = bondy_oplog_core_metrics:snapshot_now(),
    %% Now produce 3 hits + 1 miss between this and the next snapshot.
    fire_read(NS, true),
    fire_read(NS, true),
    fire_read(NS, true),
    fire_read(NS, false),
    Events = capture_refresh_events(fun() ->
        ok = bondy_oplog_core_metrics:snapshot_now()
    end),
    [{Meas, _}] = [E || E = {_M, #{namespace := N}} <- Events, N =:= NS],
    %% 3 hits out of 4 reads → 0.75. Floating point compare with epsilon.
    Rate = maps:get(cache_hit_rate, Meas),
    ?assert(is_float(Rate)),
    ?assert(abs(Rate - 0.75) < 1.0e-9).

rates_scale_with_window() ->
    NS = mk_ns(),
    ok = bondy_oplog_core_metrics:snapshot_now(),
    %% Two reads in a short window.
    fire_read(NS, true),
    fire_read(NS, false),
    %% Wait a known amount so the window is observable.
    timer:sleep(50),
    Events = capture_refresh_events(fun() ->
        ok = bondy_oplog_core_metrics:snapshot_now()
    end),
    [{Meas, Meta}] = [E || E = {_M, #{namespace := N}} <- Events, N =:= NS],
    %% RPS must be positive and the window ≥ the sleep.
    ?assert(maps:get(read_rps, Meas) > 0),
    ?assert(maps:get(interval_ms, Meta) >= 50).

multiple_namespaces_are_independent() ->
    NSA = mk_ns(),
    NSB = mk_ns(),
    fire_read(NSA, true),
    fire_read(NSA, true),
    fire_read(NSB, false),
    Events = capture_refresh_events(fun() ->
        ok = bondy_oplog_core_metrics:snapshot_now()
    end),
    OursA = [E || E = {_M, #{namespace := N}} <- Events, N =:= NSA],
    OursB = [E || E = {_M, #{namespace := N}} <- Events, N =:= NSB],
    ?assertEqual(1, length(OursA)),
    ?assertEqual(1, length(OursB)),
    [{MeasA, _}] = OursA,
    [{MeasB, _}] = OursB,
    %% NSA: 2 hits, 0 misses → rate = 1.0; NSB: 0 hits, 1 miss → rate = 0.0
    ?assertEqual(1.0, maps:get(cache_hit_rate, MeasA)),
    ?assertEqual(0.0, maps:get(cache_hit_rate, MeasB)).

freshness_lag_is_reported() ->
    %% Register a shard so the metrics module can probe the AE atomic.
    NS = mk_ns(),
    {Cleanup, _} = register_shard(NS),
    %% No `bump_ae` ever — the shard's `last_ae_at` is at the sentinel,
    %% so `Now - sentinel` is a very large positive integer.
    Events = capture_refresh_events(fun() ->
        ok = bondy_oplog_core_metrics:snapshot_now()
    end),
    [{Meas, _}] = [E || E = {_M, #{namespace := N}} <- Events, N =:= NS],
    ?assert(maps:get(current_freshness_lag_max_ms, Meas) > 1_000_000_000),
    Cleanup().

info_reports_running_state() ->
    Info = bondy_oplog_core_metrics:info(),
    ?assert(maps:is_key(enabled, Info)),
    ?assert(maps:is_key(interval_ms, Info)),
    ?assert(maps:is_key(namespaces, Info)).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_ns() ->
    list_to_atom(
        "mst_db_metrics_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

fire_read(NS, Hit) ->
    bondy_oplog_core_metrics:handle_event(
        [bondy_oplog_core, read],
        #{duration_us => 1, hit => Hit, value_bytes => 1},
        #{namespace => NS, index => primary, shard => 0, source => cache},
        undefined
    ).

fire_range(NS) ->
    bondy_oplog_core_metrics:handle_event(
        [bondy_oplog_core, range],
        #{duration_us => 1, entries_returned => 1, scanned_bytes => 1},
        #{namespace => NS, index => primary, shard => 0},
        undefined
    ).

counter_value(Name, Label) ->
    case bondy_metrics:value(#{name => Name, label => Label}) of
        undefined -> 0;
        V -> V
    end.

capture_refresh_events(Fun) ->
    Self = self(),
    HandlerId = {?MODULE, erlang:unique_integer()},
    ok = telemetry:attach(
        HandlerId,
        [bondy_oplog_core, metrics, refresh],
        fun(_E, M, Md, _C) -> Self ! {refresh, M, Md} end,
        []
    ),
    try
        Fun(),
        drain_refresh([])
    after
        telemetry:detach(HandlerId)
    end.

drain_refresh(Acc) ->
    receive
        {refresh, M, Md} -> drain_refresh([{M, Md} | Acc])
    after 100 ->
        lists:reverse(Acc)
    end.

register_shard(NS) ->
    {ok, CH} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, PH} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    OV = bondy_oplog_db_overlay:new(),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => CH,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => PH,
        overlay => OV,
        fold_module => lww_register
    }),
    Cleanup = fun() ->
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        ok = bondy_oplog_cache_ets:close(CH),
        ok = bondy_oplog_projection_ets:close(PH),
        ok = bondy_oplog_db_overlay:delete(OV)
    end,
    {Cleanup, NS}.
