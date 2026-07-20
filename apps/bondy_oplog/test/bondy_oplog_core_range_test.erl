%% =============================================================================
%% Tests for `bondy_oplog_core:range/4` (`MST_DB_DESIGN.md` §9, wired in D5).
%%
%% Pins: projection-only ranges, overlay-only ranges, projection+overlay
%% merge per key, limit, direction, include_overlay flag, fence on
%% overlay events, half-open `[Low, High)` semantics, undefined cells
%% (overlay-only with no terminal value) suppressed from results.
%% =============================================================================

-module(bondy_oplog_core_range_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    ok.

range_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun empty_range_returns_empty_list/0,
        fun projection_only_range_returns_in_order/0,
        fun overlay_only_range_returns_in_order/0,
        fun projection_and_overlay_merge_per_key/0,
        fun half_open_interval_excludes_high_key/0,
        fun limit_caps_the_result/0,
        fun include_overlay_false_drops_overlay_events/0,
        fun fence_excludes_overlay_events_past_it/0,
        fun overlay_only_undefined_terminal_is_filtered/0,
        fun unknown_namespace_returns_no_shards/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

empty_range_returns_empty_list() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, 1, lww_register),
    {ok, []} = bondy_oplog_core:range(NS, primary, {<<"a">>, <<"z">>}, #{}),
    teardown_shard(Setup).

projection_only_range_returns_in_order() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"a">>, {set, <<"va">>, 1}, 1),
    materialise(PH, <<"b">>, {set, <<"vb">>, 2}, 2),
    materialise(PH, <<"c">>, {set, <<"vc">>, 3}, 3),
    {ok, Rows} = bondy_oplog_core:range(NS, primary, {<<"a">>, <<"z">>}, #{}),
    ?assertEqual(
        [
            {<<"a">>, <<"va">>, 1},
            {<<"b">>, <<"vb">>, 2},
            {<<"c">>, <<"vc">>, 3}
        ],
        Rows
    ),
    teardown_shard(Setup).

overlay_only_range_returns_in_order() ->
    NS = mk_ns(),
    {Setup, #{overlay := OV}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    %% Three overlay-only cells; lww_register's initial_value is undefined,
    %% so after fold the values are the event payloads.
    overlay_insert(OV, <<"a">>, 10, {set, 10, <<"va">>}),
    overlay_insert(OV, <<"b">>, 20, {set, 20, <<"vb">>}),
    overlay_insert(OV, <<"c">>, 30, {set, 30, <<"vc">>}),
    {ok, Rows} = bondy_oplog_core:range(NS, primary, {<<"a">>, <<"z">>}, #{}),
    ?assertEqual(
        [
            {<<"a">>, <<"va">>, 10},
            {<<"b">>, <<"vb">>, 20},
            {<<"c">>, <<"vc">>, 30}
        ],
        Rows
    ),
    teardown_shard(Setup).

projection_and_overlay_merge_per_key() ->
    NS = mk_ns(),
    {Setup, #{projection := PH, overlay := OV}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    %% Projection has a at HLC=5, c at HLC=15. Overlay has a (newer) at
    %% HLC=30 and b (new key) at HLC=20.
    materialise(PH, <<"a">>, {set, <<"old-a">>, 5}, 5),
    materialise(PH, <<"c">>, {set, <<"old-c">>, 15}, 15),
    overlay_insert(OV, <<"a">>, 30, {set, 30, <<"new-a">>}),
    overlay_insert(OV, <<"b">>, 20, {set, 20, <<"new-b">>}),
    {ok, Rows} = bondy_oplog_core:range(NS, primary, {<<"a">>, <<"z">>}, #{}),
    ?assertEqual(
        [
            {<<"a">>, <<"new-a">>, 30},
            {<<"b">>, <<"new-b">>, 20},
            {<<"c">>, <<"old-c">>, 15}
        ],
        Rows
    ),
    teardown_shard(Setup).

half_open_interval_excludes_high_key() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"a">>, {set, <<"va">>, 1}, 1),
    materialise(PH, <<"b">>, {set, <<"vb">>, 2}, 2),
    materialise(PH, <<"c">>, {set, <<"vc">>, 3}, 3),
    {ok, Rows} = bondy_oplog_core:range(NS, primary, {<<"a">>, <<"c">>}, #{}),
    %% `c` is excluded by the half-open upper bound.
    ?assertEqual(
        [
            {<<"a">>, <<"va">>, 1},
            {<<"b">>, <<"vb">>, 2}
        ],
        Rows
    ),
    teardown_shard(Setup).

limit_caps_the_result() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    [materialise(PH, <<"k", N>>, {set, <<N>>, N}, N) || N <- lists:seq($a, $e)],
    {ok, Rows} =
        bondy_oplog_core:range(NS, primary, {<<"k">>, <<"z">>}, #{limit => 2}),
    ?assertEqual(2, length(Rows)),
    teardown_shard(Setup).

include_overlay_false_drops_overlay_events() ->
    NS = mk_ns(),
    {Setup, #{projection := PH, overlay := OV}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"a">>, {set, <<"old">>, 1}, 1),
    overlay_insert(OV, <<"a">>, 10, {set, 10, <<"new">>}),
    {ok, Rows} =
        bondy_oplog_core:range(
            NS,
            primary,
            {<<"a">>, <<"z">>},
            #{include_overlay => false}
        ),
    ?assertEqual([{<<"a">>, <<"old">>, 1}], Rows),
    teardown_shard(Setup).

fence_excludes_overlay_events_past_it() ->
    NS = mk_ns(),
    {Setup, #{projection := PH, overlay := OV}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"a">>, {set, <<"old">>, 1}, 1),
    overlay_insert(OV, <<"a">>, 10, {set, 10, <<"mid">>}),
    overlay_insert(OV, <<"a">>, 30, {set, 30, <<"new">>}),
    %% Fence at 20 → only the HLC=10 overlay event applies.
    {ok, Rows} =
        bondy_oplog_core:range(NS, primary, {<<"a">>, <<"z">>}, #{fence => 20}),
    ?assertEqual([{<<"a">>, <<"mid">>, 10}], Rows),
    teardown_shard(Setup).

overlay_only_undefined_terminal_is_filtered() ->
    %% A `clear` op produces state `{cleared, H}`, which `to_value/1`
    %% maps to `undefined`. The substrate's range path filters
    %% `undefined` rows out (matches `bondy_oplog_core:read/3` semantics),
    %% so a cleared overlay-only cell does not appear in range results.
    NS = mk_ns(),
    {Setup, #{overlay := OV}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    overlay_insert(OV, <<"k">>, 10, {clear, 10}),
    {ok, Rows} =
        bondy_oplog_core:range(NS, primary, {<<"a">>, <<"z">>}, #{}),
    ?assertEqual([], Rows),
    teardown_shard(Setup).

unknown_namespace_returns_no_shards() ->
    NS = mk_ns(),
    ?assertEqual(
        {error, no_shards},
        bondy_oplog_core:range(NS, primary, {<<"a">>, <<"z">>}, #{})
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_ns() ->
    list_to_atom(
        "mst_db_range_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

mk_event(Hlc, Origin, Seq, Op) ->
    K = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(K, Op, undefined).

materialise(PH, Key, State, Hlc) ->
    Frame = bondy_oplog_test_helpers:frame(lww_register, State, Hlc),
    ok = bondy_oplog_projection_ets:put_batch(PH, [{<<>>, Key, Frame}]).

overlay_insert(OV, Key, Hlc, Op) ->
    Event = mk_event(Hlc, <<"origin">>, Hlc, Op),
    ok = bondy_oplog_db_overlay:insert(OV, <<>>, Key, Event).

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
