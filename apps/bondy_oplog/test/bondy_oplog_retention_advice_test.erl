%% =============================================================================
%% Unit tests for `bondy_oplog:retention_advice/1,2` and the underlying
%% pure decision function `bondy_oplog:retention_decision/1`.
%%
%% Coverage:
%% - Decision tree on every branch (pure function, no instance needed).
%% - Integration test wiring the helper through a running instance.
%% - `instance_not_running` error path.
%% =============================================================================

-module(bondy_oplog_retention_advice_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Helpers
%% =============================================================================

mk_id() ->
    iolist_to_binary(
        io_lib:format(
            "ra-~p-~p",
            [
                erlang:system_time(microsecond),
                erlang:unique_integer([positive])
            ]
        )
    ).

inputs(Overrides) ->
    Defaults = #{
        pressure => #{
            bytes_total => 0,
            max_total_wal_size => 1024,
            bytes_ratio => 0.0,
            live_segments_count => 1,
            max_live_segments => 16,
            segments_ratio => 1 / 16,
            backpressure => ok
        },
        has_snapshot => false,
        snapshot_watermark => undefined,
        scrubber_alerts => [],
        bootstrap_consumers => 0
    },
    maps:merge(Defaults, Overrides).

with_pressure(BytesR, SegsR, Base) ->
    P0 = maps:get(pressure, Base),
    P1 = P0#{bytes_ratio := BytesR, segments_ratio := SegsR},
    Base#{pressure := P1}.

%% =============================================================================
%% Decision tree — pure function
%% =============================================================================

low_pressure_recommends_none_test() ->
    In = with_pressure(0.1, 0.1, inputs(#{})),
    Advice = bondy_oplog:retention_decision(In),
    ?assertEqual(none, maps:get(recommended_action, Advice)),
    ?assertMatch(
        <<"retention pressure is low", _/binary>>,
        maps:get(rationale, Advice)
    ).

scrubber_alert_short_circuits_to_none_test() ->
    %% Even at maximum pressure, an outstanding scrubber alert wins.
    In = with_pressure(
        0.95,
        0.95,
        inputs(#{
            scrubber_alerts => [{7, bad_crc}, {12, torn_write}],
            has_snapshot => true,
            bootstrap_consumers => 0
        })
    ),
    Advice = bondy_oplog:retention_decision(In),
    ?assertEqual(none, maps:get(recommended_action, Advice)),
    Rationale = maps:get(rationale, Advice),
    ?assertMatch(
        <<"scrubber alert outstanding on 2 segment(s)", _/binary>>,
        Rationale
    ).

high_pressure_with_snapshot_no_bootstrap_recommends_compact_test() ->
    In = with_pressure(
        0.85,
        0.3,
        inputs(#{has_snapshot => true, bootstrap_consumers => 0})
    ),
    Advice = bondy_oplog:retention_decision(In),
    ?assertEqual(compact, maps:get(recommended_action, Advice)).

high_pressure_no_snapshot_no_bootstrap_recommends_truncate_test() ->
    In = with_pressure(
        0.85,
        0.3,
        inputs(#{has_snapshot => false, bootstrap_consumers => 0})
    ),
    Advice = bondy_oplog:retention_decision(In),
    ?assertEqual(truncate_prefix, maps:get(recommended_action, Advice)).

high_pressure_with_snapshot_and_bootstrap_recommends_compact_test() ->
    %% bootstrap consumers are preserved by compact (snapshot watermark
    %% is the durability seam), so this is the safe pick.
    In = with_pressure(
        0.7,
        0.7,
        inputs(#{has_snapshot => true, bootstrap_consumers => 2})
    ),
    Advice = bondy_oplog:retention_decision(In),
    ?assertEqual(compact, maps:get(recommended_action, Advice)),
    Rationale = maps:get(rationale, Advice),
    ?assertMatch(
        <<"bootstrap consumers active; compact", _/binary>>,
        Rationale
    ).

high_pressure_no_snapshot_with_bootstrap_recommends_none_test() ->
    %% truncate would orphan bootstrap; compact has nothing to fold.
    %% No safe automatic recommendation — wait or snapshot.
    In = with_pressure(
        0.9,
        0.4,
        inputs(#{has_snapshot => false, bootstrap_consumers => 1})
    ),
    Advice = bondy_oplog:retention_decision(In),
    ?assertEqual(none, maps:get(recommended_action, Advice)),
    Rationale = maps:get(rationale, Advice),
    ?assertMatch(
        <<"bootstrap consumers active but no snapshot exists", _/binary>>,
        Rationale
    ).

segment_pressure_alone_triggers_recommendation_test() ->
    %% bytes are fine, but live_segments is full — pick should still
    %% fire on the higher of the two ratios.
    In = with_pressure(
        0.05,
        0.95,
        inputs(#{has_snapshot => false, bootstrap_consumers => 0})
    ),
    Advice = bondy_oplog:retention_decision(In),
    ?assertEqual(truncate_prefix, maps:get(recommended_action, Advice)).

boundary_at_threshold_recommends_action_test() ->
    %% At exactly the threshold (0.5), the predicate `max(B, S) <
    %% 0.5` is false → non-low branch fires. We want this so an
    %% operator at the boundary still gets a non-trivial answer.
    In = with_pressure(
        0.5,
        0.0,
        inputs(#{has_snapshot => true, bootstrap_consumers => 0})
    ),
    Advice = bondy_oplog:retention_decision(In),
    ?assertEqual(compact, maps:get(recommended_action, Advice)).

advice_carries_inputs_through_test() ->
    In = with_pressure(
        0.85,
        0.3,
        inputs(#{has_snapshot => true, bootstrap_consumers => 4})
    ),
    Advice = bondy_oplog:retention_decision(In),
    ?assertEqual(In, maps:get(inputs, Advice)).

%% =============================================================================
%% Integration — through `retention_advice/1,2`
%% =============================================================================

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

integration_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun advice_returns_error_when_instance_not_running/0,
        fun advice_against_idle_instance_returns_none/0,
        fun advice_propagates_bootstrap_consumers_opt/0
    ]}.

advice_returns_error_when_instance_not_running() ->
    Id = mk_id(),
    ?assertEqual(
        {error, instance_not_running},
        bondy_oplog:retention_advice(Id)
    ).

advice_against_idle_instance_returns_none() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{}),
    try
        {ok, Advice} = bondy_oplog:retention_advice(Id),
        ?assertEqual(none, maps:get(recommended_action, Advice)),
        Inputs = maps:get(inputs, Advice),
        Pressure = maps:get(pressure, Inputs),
        %% Idle instance — both ratios should be at or near zero.
        ?assert(maps:get(bytes_ratio, Pressure) < 0.1),
        ?assertEqual(0, maps:get(bootstrap_consumers, Inputs)),
        ?assertEqual(false, maps:get(has_snapshot, Inputs)),
        ?assertEqual([], maps:get(scrubber_alerts, Inputs))
    after
        ok = bondy_oplog:stop_instance(Id)
    end.

advice_propagates_bootstrap_consumers_opt() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{}),
    try
        {ok, Advice} = bondy_oplog:retention_advice(
            Id, #{bootstrap_consumers => 3}
        ),
        Inputs = maps:get(inputs, Advice),
        ?assertEqual(3, maps:get(bootstrap_consumers, Inputs))
    after
        ok = bondy_oplog:stop_instance(Id)
    end.
