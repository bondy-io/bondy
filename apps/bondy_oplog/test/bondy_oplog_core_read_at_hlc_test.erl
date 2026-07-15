%% =============================================================================
%% Tests for `bondy_oplog_core:read_at_hlc/3` (`MST_DB_DESIGN.md` §10, wired
%% in D6).
%%
%% Pins: projection at-or-before T returns; projection past T refuses;
%% overlay events through T fold in; nothing-yet returns initial_value
%% at HLC=0; per-cell window respected (events `> ProjHlc AND <= T`).
%% =============================================================================

-module(bondy_oplog_core_read_at_hlc_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    ok.

read_at_hlc_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun unknown_namespace_returns_no_shards/0,
        fun absent_cell_returns_initial_value_at_zero/0,
        fun projection_at_or_before_t_returns_projection/0,
        fun projection_past_t_refuses/0,
        fun overlay_events_through_t_are_folded/0,
        fun overlay_events_past_t_are_excluded/0,
        fun overlay_below_projection_hlc_is_ignored/0,
        fun mix_projection_and_overlay_with_partial_window/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

unknown_namespace_returns_no_shards() ->
    NS = mk_ns(),
    ?assertEqual(
        {error, no_shards},
        bondy_oplog_core:read_at_hlc(NS, <<"k">>, 100)
    ).

absent_cell_returns_initial_value_at_zero() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, 1, lww_register),
    ?assertEqual(
        {ok, undefined, 0},
        bondy_oplog_core:read_at_hlc(NS, <<"absent">>, 100)
    ),
    teardown_shard(Setup).

projection_at_or_before_t_returns_projection() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"k">>, {set, <<"v">>, 5}, 5),
    %% T = 10; projection HLC 5 ≤ T → return.
    ?assertEqual(
        {ok, <<"v">>, 5},
        bondy_oplog_core:read_at_hlc(NS, <<"k">>, 10)
    ),
    %% T = 5; projection HLC 5 ≤ T → return (=< boundary).
    ?assertEqual(
        {ok, <<"v">>, 5},
        bondy_oplog_core:read_at_hlc(NS, <<"k">>, 5)
    ),
    teardown_shard(Setup).

projection_past_t_refuses() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"k">>, {set, <<"v">>, 50}, 50),
    %% T = 10; projection HLC 50 > T → refuse.
    ?assertEqual(
        {error, {historical_read_unavailable, 50, 10}},
        bondy_oplog_core:read_at_hlc(NS, <<"k">>, 10)
    ),
    teardown_shard(Setup).

overlay_events_through_t_are_folded() ->
    NS = mk_ns(),
    {Setup, #{projection := PH, overlay := OV}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"k">>, {set, <<"old">>, 5}, 5),
    overlay_insert(OV, <<"k">>, 10, {set, 10, <<"mid">>}),
    overlay_insert(OV, <<"k">>, 20, {set, 20, <<"new">>}),
    %% T = 15; project=5, overlay events <= 15: only HLC=10.
    ?assertEqual(
        {ok, <<"mid">>, 10},
        bondy_oplog_core:read_at_hlc(NS, <<"k">>, 15)
    ),
    teardown_shard(Setup).

overlay_events_past_t_are_excluded() ->
    NS = mk_ns(),
    {Setup, #{projection := PH, overlay := OV}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"k">>, {set, <<"old">>, 5}, 5),
    %% Two overlay events both past T.
    overlay_insert(OV, <<"k">>, 100, {set, 100, <<"far">>}),
    overlay_insert(OV, <<"k">>, 200, {set, 200, <<"farther">>}),
    %% T = 10; projection at 5; no overlay applies.
    ?assertEqual(
        {ok, <<"old">>, 5},
        bondy_oplog_core:read_at_hlc(NS, <<"k">>, 10)
    ),
    teardown_shard(Setup).

overlay_below_projection_hlc_is_ignored() ->
    %% If the overlay still holds an event with HLC =< projection's HLC,
    %% it should not re-apply (the projection already absorbed it).
    NS = mk_ns(),
    {Setup, #{projection := PH, overlay := OV}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"k">>, {set, <<"absorbed">>, 50}, 50),
    overlay_insert(OV, <<"k">>, 20, {set, 20, <<"stale">>}),
    %% T = 100; projection at 50; overlay at 20 (=< proj) → ignored.
    ?assertEqual(
        {ok, <<"absorbed">>, 50},
        bondy_oplog_core:read_at_hlc(NS, <<"k">>, 100)
    ),
    teardown_shard(Setup).

mix_projection_and_overlay_with_partial_window() ->
    NS = mk_ns(),
    {Setup, #{projection := PH, overlay := OV}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"k">>, {set, <<"v5">>, 5}, 5),
    overlay_insert(OV, <<"k">>, 10, {set, 10, <<"v10">>}),
    overlay_insert(OV, <<"k">>, 15, {set, 15, <<"v15">>}),
    overlay_insert(OV, <<"k">>, 25, {set, 25, <<"v25">>}),
    %% T = 15; window = (5, 15] → events 10 and 15 apply.
    ?assertEqual(
        {ok, <<"v15">>, 15},
        bondy_oplog_core:read_at_hlc(NS, <<"k">>, 15)
    ),
    %% T = 12; window = (5, 12] → only event 10 applies.
    ?assertEqual(
        {ok, <<"v10">>, 10},
        bondy_oplog_core:read_at_hlc(NS, <<"k">>, 12)
    ),
    teardown_shard(Setup).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_ns() ->
    list_to_atom(
        "mst_db_rah_" ++
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
