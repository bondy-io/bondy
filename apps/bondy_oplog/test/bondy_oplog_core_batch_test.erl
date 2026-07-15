%% =============================================================================
%% Tests for `bondy_oplog_core:read_batch/2` (`MST_DB_DESIGN.md` §8).
%%
%% Pins fence semantics (overlay events past the fence are excluded;
%% projection cells past the fence are returned as-is), skew detection,
%% the consistency-knob defaults, and per-shard freshness gating.
%%
%% Batch reads take 4-tuples `{NS, Index, Bucket, Key}` — Bucket is a
%% first-class call-time parameter (`MST_DB_DESIGN.md` §18 item 14).
%% =============================================================================

-module(bondy_oplog_core_batch_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    ok.

batch_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun empty_batch_returns_empty_map/0,
        fun single_cell_batch_returns_value/0,
        fun multi_cell_batch_returns_all_values/0,
        fun batch_with_missing_shard_returns_error_per_cell/0,
        fun fence_excludes_overlay_events_past_it/0,
        fun fence_admits_overlay_events_at_or_below/0,
        fun fence_passes_through_projection_past_fence/0,
        fun skew_within_bound_returns_ok/0,
        fun skew_above_bound_returns_error/0,
        fun consistency_eventual_skips_freshness/0,
        fun consistency_causal_unbumped_shard_is_stale/0,
        fun consistency_causal_freshly_bumped_shard_is_fresh/0,
        fun consistency_causal_only_checks_touched_shards/0,
        fun consistency_snapshot_applies_half_lag_skew/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

empty_batch_returns_empty_map() ->
    {ok, Map, _Fence} = bondy_oplog_core:read_batch([], #{}),
    ?assertEqual(#{}, Map).

single_cell_batch_returns_value() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} = setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"k">>, {set, <<"v">>, 42}, 42),
    {ok, Map, _Fence} =
        bondy_oplog_core:read_batch([{NS, primary, ?B, <<"k">>}], #{}),
    ?assertEqual(#{{NS, primary, ?B, <<"k">>} => {<<"v">>, 42}}, Map),
    teardown_shard(Setup).

multi_cell_batch_returns_all_values() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} = setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"a">>, {set, <<"va">>, 10}, 10),
    materialise(PH, <<"b">>, {set, <<"vb">>, 20}, 20),
    materialise(PH, <<"c">>, {set, <<"vc">>, 30}, 30),
    Reads = [
        {NS, primary, ?B, <<"a">>},
        {NS, primary, ?B, <<"b">>},
        {NS, primary, ?B, <<"c">>}
    ],
    {ok, Map, _} = bondy_oplog_core:read_batch(Reads, #{}),
    ?assertEqual(3, map_size(Map)),
    ?assertEqual(
        {<<"va">>, 10},
        maps:get({NS, primary, ?B, <<"a">>}, Map)
    ),
    ?assertEqual(
        {<<"vb">>, 20},
        maps:get({NS, primary, ?B, <<"b">>}, Map)
    ),
    ?assertEqual(
        {<<"vc">>, 30},
        maps:get({NS, primary, ?B, <<"c">>}, Map)
    ),
    teardown_shard(Setup).

batch_with_missing_shard_returns_error_per_cell() ->
    NS = mk_ns(),
    {ok, Map, _} =
        bondy_oplog_core:read_batch([{NS, primary, ?B, <<"missing">>}], #{}),
    ?assertEqual(
        {error, no_shards},
        maps:get({NS, primary, ?B, <<"missing">>}, Map)
    ).

fence_excludes_overlay_events_past_it() ->
    NS = mk_ns(),
    {Setup, #{projection := PH, overlay := OV}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"k">>, {set, <<"old">>, 5}, 5),
    overlay_insert(OV, <<"k">>, 10, {set, 10, <<"mid">>}),
    overlay_insert(OV, <<"k">>, 20, {set, 20, <<"new">>}),
    {ok, Map, _Fence} =
        bondy_oplog_core:read_batch([{NS, primary, ?B, <<"k">>}], #{fence => 15}),
    ?assertEqual(
        {<<"mid">>, 10},
        maps:get({NS, primary, ?B, <<"k">>}, Map)
    ),
    teardown_shard(Setup).

fence_admits_overlay_events_at_or_below() ->
    NS = mk_ns(),
    {Setup, #{projection := PH, overlay := OV}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"k">>, {set, <<"old">>, 5}, 5),
    overlay_insert(OV, <<"k">>, 10, {set, 10, <<"mid">>}),
    {ok, Map, _} =
        bondy_oplog_core:read_batch([{NS, primary, ?B, <<"k">>}], #{fence => 10}),
    ?assertEqual(
        {<<"mid">>, 10},
        maps:get({NS, primary, ?B, <<"k">>}, Map)
    ),
    teardown_shard(Setup).

fence_passes_through_projection_past_fence() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"k">>, {set, <<"v">>, 100}, 100),
    {ok, Map, _} =
        bondy_oplog_core:read_batch([{NS, primary, ?B, <<"k">>}], #{fence => 50}),
    ?assertEqual(
        {<<"v">>, 100},
        maps:get({NS, primary, ?B, <<"k">>}, Map)
    ),
    teardown_shard(Setup).

skew_within_bound_returns_ok() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    H1 = bondy_oplog_hlc:encode(1_000, 0),
    H2 = bondy_oplog_hlc:encode(1_050, 0),
    materialise(PH, <<"a">>, {set, <<"va">>, H1}, H1),
    materialise(PH, <<"b">>, {set, <<"vb">>, H2}, H2),
    Reads = [{NS, primary, ?B, <<"a">>}, {NS, primary, ?B, <<"b">>}],
    {ok, _, _} = bondy_oplog_core:read_batch(Reads, #{require_skew_below => 100}),
    teardown_shard(Setup).

skew_above_bound_returns_error() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    H1 = bondy_oplog_hlc:encode(1_000, 0),
    H2 = bondy_oplog_hlc:encode(2_000, 0),
    materialise(PH, <<"a">>, {set, <<"va">>, H1}, H1),
    materialise(PH, <<"b">>, {set, <<"vb">>, H2}, H2),
    Reads = [{NS, primary, ?B, <<"a">>}, {NS, primary, ?B, <<"b">>}],
    ?assertMatch(
        {error, {skew_too_large, 1_000, 500}},
        bondy_oplog_core:read_batch(Reads, #{require_skew_below => 500})
    ),
    teardown_shard(Setup).

consistency_eventual_skips_freshness() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, 1, lww_register),
    {ok, _, _} = bondy_oplog_core:read_batch(
        [{NS, primary, ?B, <<"k">>}],
        #{consistency => eventual, max_lag => 50}
    ),
    teardown_shard(Setup).

consistency_causal_unbumped_shard_is_stale() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, 1, lww_register),
    ?assertEqual(
        {error, {stale, [NS]}},
        bondy_oplog_core:read_batch(
            [{NS, primary, ?B, <<"k">>}],
            #{consistency => causal, max_lag => 100}
        )
    ),
    teardown_shard(Setup).

consistency_causal_freshly_bumped_shard_is_fresh() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, 1, lww_register),
    ok = bondy_oplog_core_registry:bump_ae(NS, primary, 0),
    {ok, _, _} =
        bondy_oplog_core:read_batch(
            [{NS, primary, ?B, <<"k">>}],
            #{consistency => causal, max_lag => 1_000_000}
        ),
    teardown_shard(Setup).

consistency_causal_only_checks_touched_shards() ->
    NS = mk_ns(),
    {S0, _} = setup_shard(NS, primary, 0, 2, lww_register),
    {S1, _} = setup_shard(NS, primary, 1, 2, lww_register),
    ok = bondy_oplog_core_registry:bump_ae(NS, primary, 0),
    K0 = find_key_for_shard(NS, primary, 0),
    ?assertMatch(
        {ok, _, _},
        bondy_oplog_core:read_batch(
            [{NS, primary, ?B, K0}],
            #{consistency => causal, max_lag => 1_000_000}
        )
    ),
    K1 = find_key_for_shard(NS, primary, 1),
    ?assertEqual(
        {error, {stale, [NS]}},
        bondy_oplog_core:read_batch(
            [{NS, primary, ?B, K1}],
            #{consistency => causal, max_lag => 1_000_000}
        )
    ),
    teardown_shard(S0),
    teardown_shard(S1).

consistency_snapshot_applies_half_lag_skew() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    H1 = bondy_oplog_hlc:encode(1_000, 0),
    H2 = bondy_oplog_hlc:encode(1_150, 0),
    materialise(PH, <<"a">>, {set, <<"va">>, H1}, H1),
    materialise(PH, <<"b">>, {set, <<"vb">>, H2}, H2),
    Reads = [{NS, primary, ?B, <<"a">>}, {NS, primary, ?B, <<"b">>}],
    ?assertMatch(
        {error, {skew_too_large, 150, 50}},
        bondy_oplog_core:read_batch(Reads, #{
            consistency => snapshot,
            max_lag => infinity,
            require_skew_below => 50
        })
    ),
    teardown_shard(Setup).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_ns() ->
    list_to_atom(
        "mst_db_batch_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

find_key_for_shard(NS, Index, WantedShard) ->
    find_key_for_shard(NS, Index, WantedShard, 0).

find_key_for_shard(NS, Index, WantedShard, N) when N < 10_000 ->
    K = integer_to_binary(N),
    case bondy_oplog_core:shard_for(NS, Index, ?B, K) of
        {ok, WantedShard} -> K;
        _ -> find_key_for_shard(NS, Index, WantedShard, N + 1)
    end;
find_key_for_shard(_, _, _, _) ->
    erlang:error(no_key_for_shard).

mk_event(Hlc, Origin, Seq, Op) ->
    K = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(K, Op, undefined).

materialise(PH, Key, State, Hlc) ->
    Frame = bondy_oplog_test_helpers:frame(lww_register, State, Hlc),
    ok = bondy_oplog_projection_ets:put_batch(PH, [{?B, Key, Frame}]).

overlay_insert(OV, Key, Hlc, Op) ->
    Event = mk_event(Hlc, <<"origin">>, Hlc, Op),
    ok = bondy_oplog_db_overlay:insert(OV, ?B, Key, Event).

setup_shard(NS, Index, Shard, ShardCount, Strategy) ->
    {ok, CH} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, PH} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    OV = bondy_oplog_db_overlay:new(),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => ShardCount,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => CH,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => PH,
        overlay => OV,
        fold_module => Strategy
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
