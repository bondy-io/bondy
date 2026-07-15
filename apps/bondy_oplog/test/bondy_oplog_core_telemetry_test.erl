%% =============================================================================
%% Tests for `bondy_oplog_core` telemetry instrumentation (`MST_DB_DESIGN.md`
%% §16). Each event is exercised by triggering a path that fires it and
%% asserting on the captured measurements + metadata maps. A telemetry
%% handler routes every event into the test process mailbox; the test
%% drains and decodes by event name.
%% =============================================================================

-module(bondy_oplog_core_telemetry_test).

-include_lib("eunit/include/eunit.hrl").

-define(EVENTS, [
    [bondy_oplog_core, read],
    [bondy_oplog_core, read_batch],
    [bondy_oplog_core, ensure_fresh],
    [bondy_oplog_core, range],
    [bondy_oplog_core, read_at_hlc],
    [bondy_oplog_core, subscribe]
]).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    ok.

telemetry_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun read_cache_hit_emits_source_cache/0,
        fun read_projection_only_emits_source_projection/0,
        fun read_with_overlay_emits_projection_with_overlay/0,
        fun read_overlay_only_emits_source_overlay_only/0,
        fun read_batch_event_carries_namespaces_and_fence/0,
        fun range_event_counts_entries/0,
        fun read_at_hlc_success_not_refused/0,
        fun read_at_hlc_refusal_carries_reason/0,
        fun ensure_fresh_event_counts_namespaces_and_stale/0,
        fun subscribe_event_carries_pattern_type_and_count/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

read_cache_hit_emits_source_cache() ->
    NS = mk_ns(),
    {Setup, #{cache_handle := CH}} = setup_shard(NS, primary, 0),
    ok = bondy_oplog_cache_ets:put(CH, <<>>, <<"k">>, {<<"v">>, 99}),
    with_handler(?EVENTS, fun() ->
        {<<"v">>, 99} = bondy_oplog_core:read(NS, primary, <<"k">>)
    end),
    {Meas, Meta} = expect_event([bondy_oplog_core, read]),
    ?assertEqual(true, maps:get(hit, Meas)),
    ?assert(maps:get(duration_us, Meas) >= 0),
    ?assert(maps:get(value_bytes, Meas) > 0),
    ?assertEqual(cache, maps:get(source, Meta)),
    ?assertEqual(none, maps:get(path, Meta)),
    ?assertEqual(NS, maps:get(namespace, Meta)),
    ?assertEqual(primary, maps:get(index, Meta)),
    ?assertEqual(0, maps:get(shard, Meta)),
    teardown_shard(Setup).

read_projection_only_emits_source_projection() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} = setup_shard(NS, primary, 0),
    seed_projection(PH, <<"k">>, 42, {set, <<"v">>, 42}),
    with_handler(?EVENTS, fun() ->
        {<<"v">>, 42} = bondy_oplog_core:read(NS, primary, <<"k">>)
    end),
    {_Meas, Meta} = expect_event([bondy_oplog_core, read]),
    ?assertEqual(projection, maps:get(source, Meta)),
    ?assertEqual(head, maps:get(path, Meta)),
    %% ETS test adapter does not export head/3 so the substrate falls
    %% back to get/3 + extract_head/1.
    ?assertEqual(fallback, maps:get(head_path, Meta)),
    teardown_shard(Setup).

read_with_overlay_emits_projection_with_overlay() ->
    NS = mk_ns(),
    {Setup, #{projection := PH, overlay := OV}} = setup_shard(NS, primary, 0),
    seed_projection(PH, <<"k">>, 10, {set, <<"old">>, 10}),
    Event = mk_event(20, <<"o">>, 0, {set, 20, <<"new">>}),
    ok = bondy_oplog_db_overlay:insert(OV, <<>>, <<"k">>, Event),
    with_handler(?EVENTS, fun() ->
        {<<"new">>, 20} =
            bondy_oplog_core:read(NS, primary, <<"k">>)
    end),
    {_Meas, Meta} = expect_event([bondy_oplog_core, read]),
    ?assertEqual(projection_with_overlay, maps:get(source, Meta)),
    ?assertEqual(slow, maps:get(path, Meta)),
    teardown_shard(Setup).

read_overlay_only_emits_source_overlay_only() ->
    NS = mk_ns(),
    {Setup, #{overlay := OV}} = setup_shard(NS, primary, 0),
    %% No projection write — cell exists only in overlay.
    Event = mk_event(15, <<"o">>, 0, {set, 15, <<"v">>}),
    ok = bondy_oplog_db_overlay:insert(OV, <<>>, <<"k">>, Event),
    with_handler(?EVENTS, fun() ->
        {<<"v">>, 15} =
            bondy_oplog_core:read(NS, primary, <<"k">>)
    end),
    {_Meas, Meta} = expect_event([bondy_oplog_core, read]),
    ?assertEqual(overlay_only, maps:get(source, Meta)),
    ?assertEqual(slow, maps:get(path, Meta)),
    teardown_shard(Setup).

read_batch_event_carries_namespaces_and_fence() ->
    NSA = mk_ns(),
    NSB = mk_ns(),
    {SetupA, #{projection := PA}} = setup_shard(NSA, primary, 0),
    {SetupB, #{projection := PB}} = setup_shard(NSB, primary, 0),
    seed_projection(PA, <<"a">>, 11, {set, <<"av">>, 11}),
    seed_projection(PB, <<"b">>, 22, {set, <<"bv">>, 22}),
    Reads = [{NSA, primary, <<>>, <<"a">>}, {NSB, primary, <<>>, <<"b">>}],
    with_handler(?EVENTS, fun() ->
        {ok, _, _} = bondy_oplog_core:read_batch(Reads, #{fence => 100})
    end),
    {Meas, Meta} = expect_event([bondy_oplog_core, read_batch]),
    ?assertEqual(2, maps:get(read_count, Meas)),
    ?assert(maps:get(total_bytes, Meas) > 0),
    ?assertEqual(lists:usort([NSA, NSB]), maps:get(namespaces, Meta)),
    ?assertEqual(100, maps:get(fence_hlc, Meta)),
    teardown_shard(SetupA),
    teardown_shard(SetupB).

range_event_counts_entries() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} = setup_shard(NS, primary, 0),
    seed_projection(PH, <<"k1">>, 1, {set, <<"v1">>, 1}),
    seed_projection(PH, <<"k2">>, 2, {set, <<"v2">>, 2}),
    with_handler(?EVENTS, fun() ->
        {ok, Rows} =
            bondy_oplog_core:range(NS, primary, {<<"k">>, <<"l">>}, #{
                shard => 0
            }),
        2 = length(Rows)
    end),
    {Meas, Meta} = expect_event([bondy_oplog_core, range]),
    ?assertEqual(2, maps:get(entries_returned, Meas)),
    ?assert(maps:get(scanned_bytes, Meas) > 0),
    ?assertEqual(NS, maps:get(namespace, Meta)),
    ?assertEqual(primary, maps:get(index, Meta)),
    ?assertEqual(0, maps:get(shard, Meta)),
    teardown_shard(Setup).

read_at_hlc_success_not_refused() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} = setup_shard(NS, primary, 0),
    seed_projection(PH, <<"k">>, 5, {set, <<"v">>, 5}),
    with_handler(?EVENTS, fun() ->
        {ok, _, _} = bondy_oplog_core:read_at_hlc(NS, <<"k">>, 100)
    end),
    {Meas, Meta} = expect_event([bondy_oplog_core, read_at_hlc]),
    ?assertEqual(false, maps:get(refused, Meas)),
    ?assertEqual(undefined, maps:get(refusal_reason, Meta)),
    ?assertEqual(NS, maps:get(namespace, Meta)),
    teardown_shard(Setup).

read_at_hlc_refusal_carries_reason() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} = setup_shard(NS, primary, 0),
    %% Projection at HLC=100; read at T=10 forces a refusal.
    seed_projection(PH, <<"k">>, 100, {set, <<"v">>, 100}),
    with_handler(?EVENTS, fun() ->
        {error, {historical_read_unavailable, 100, 10}} =
            bondy_oplog_core:read_at_hlc(NS, <<"k">>, 10)
    end),
    {Meas, Meta} = expect_event([bondy_oplog_core, read_at_hlc]),
    ?assertEqual(true, maps:get(refused, Meas)),
    ?assertEqual(historical_read_unavailable, maps:get(refusal_reason, Meta)),
    teardown_shard(Setup).

ensure_fresh_event_counts_namespaces_and_stale() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0),
    with_handler(?EVENTS, fun() ->
        %% Force a stale return: the shard has never been bumped so its
        %% lag is effectively infinite; a tiny `MaxLag` will catch it.
        {stale, _} = bondy_oplog_core:ensure_fresh([NS], 1)
    end),
    {Meas, _Meta} = expect_event([bondy_oplog_core, ensure_fresh]),
    ?assertEqual(1, maps:get(namespaces_checked, Meas)),
    ?assertEqual(1, maps:get(stale_count, Meas)),
    teardown_shard(Setup).

subscribe_event_carries_pattern_type_and_count() ->
    NS = mk_ns(),
    with_handler(?EVENTS, fun() ->
        {ok, R1} = bondy_oplog_core:subscribe(NS, all),
        {ok, R2} = bondy_oplog_core:subscribe(NS, {prefix, <<"a">>}),
        ok = bondy_oplog_core:unsubscribe(R1),
        ok = bondy_oplog_core:unsubscribe(R2)
    end),
    {_Meas1, Meta1} = expect_event([bondy_oplog_core, subscribe]),
    ?assertEqual(all, maps:get(pattern_type, Meta1)),
    ?assertEqual(NS, maps:get(namespace, Meta1)),
    ?assert(maps:get(current_subscribers, Meta1) >= 1),
    {_Meas2, Meta2} = expect_event([bondy_oplog_core, subscribe]),
    ?assertEqual(prefix, maps:get(pattern_type, Meta2)),
    ?assert(maps:get(current_subscribers, Meta2) >= 2).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_ns() ->
    list_to_atom(
        "mst_tel_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

mk_event(Hlc, Origin, Seq, Op) ->
    K = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(K, Op, undefined).

setup_shard(NS, Index, Shard) ->
    {ok, CH} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, PH} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    OV = bondy_oplog_db_overlay:new(),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => CH,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => PH,
        overlay => OV,
        fold_module => lww_register
    }),
    Setup = #{
        ns => NS,
        index => Index,
        shard => Shard,
        cache_handle => CH,
        projection => PH,
        overlay => OV
    },
    {Setup, Setup}.

teardown_shard(#{
    ns := NS,
    index := Index,
    shard := Shard,
    cache_handle := CH,
    projection := PH,
    overlay := OV
}) ->
    ok = bondy_oplog_core_registry:unregister(NS, Index, Shard),
    ok = bondy_oplog_cache_ets:close(CH),
    ok = bondy_oplog_projection_ets:close(PH),
    ok = bondy_oplog_db_overlay:delete(OV).

seed_projection(PH, Key, Hlc, State) ->
    Frame = bondy_oplog_test_helpers:frame(lww_register, State, Hlc),
    ok = bondy_oplog_projection_ets:put_batch(PH, [{<<>>, Key, Frame}]).

%% Attach a handler that forwards every event to the test process,
%% run `Fun`, and detach.
with_handler(Events, Fun) ->
    Self = self(),
    HandlerId = {?MODULE, erlang:unique_integer()},
    ok = telemetry:attach_many(
        HandlerId,
        Events,
        fun(EventName, Meas, Meta, _Cfg) ->
            Self ! {telemetry_event, EventName, Meas, Meta}
        end,
        []
    ),
    try
        Fun()
    after
        telemetry:detach(HandlerId)
    end.

%% Drain the mailbox for the first matching event; fail loudly if not
%% received within a short window.
expect_event(EventName) ->
    receive
        {telemetry_event, EventName, Meas, Meta} -> {Meas, Meta}
    after 1000 ->
        erlang:error({telemetry_event_not_received, EventName})
    end.
