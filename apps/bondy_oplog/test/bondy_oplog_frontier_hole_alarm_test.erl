%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% The applied-frontier hole detector in `bondy_oplog_sync_scheduler`: an
%% instance that has carried a per-origin contiguity gap for longer than
%% `db.frontier.hole_alarm` must raise `{bondy_oplog_frontier_hole, Id}`, and
%% closing the gap must clear it.
%%
%% `hole_step/4` is the decision, driven with an injected clock; `check_holes/4`
%% is the sweep, driven against a real registry entry and a real
%% `alarm_handler`, where a mis-wired id or a duplicate raise would show. The
%% transitions are quantified over schedules in
%% `prop_bondy_oplog_frontier_holes`.
%% =============================================================================
-module(bondy_oplog_frontier_hole_alarm_test).

-include_lib("eunit/include/eunit.hrl").

-define(M, bondy_oplog_sync_scheduler).
-define(T, 1000).

%% =============================================================================
%% The decision
%% =============================================================================

hole_step_test_() ->
    [
        {"first sighting of a healthy instance adopts and clears",
            ?_assertEqual({healthy, clear}, step(none, undefined, 100))},
        {"first sighting of a holed instance adopts, clears and starts",
            ?_assertEqual({{100, false}, clear}, step(hole, undefined, 100))},

        {"healthy stays healthy, silently",
            ?_assertEqual({healthy, none}, step(none, healthy, 100))},
        {"a hole opening starts the clock and says nothing",
            ?_assertEqual({{100, false}, none}, step(hole, healthy, 100))},

        {"below the threshold is silent",
            ?_assertEqual({{100, false}, none}, step(hole, {100, false}, 900))},
        {"exactly at the threshold is still silent",
            ?_assertEqual({{100, false}, none}, step(hole, {100, false}, 1100))},
        {"past the threshold raises, keeping the original clock",
            ?_assertEqual({{100, true}, raise}, step(hole, {100, false}, 1101))},

        {"an alarmed episode never raises again",
            ?_assertEqual({{100, true}, none}, step(hole, {100, true}, 99999))},

        {"closing the hole clears an alarmed episode",
            ?_assertEqual({healthy, clear}, step(none, {100, true}, 200))},
        {"closing it before the alarm clears nothing",
            ?_assertEqual({healthy, none}, step(none, {100, false}, 200))},

        %% Unreachable via `check_holes/1`, which short-circuits on 0; the
        %% guard is on the raise so the decision is total for any caller.
        {"a zero threshold never raises",
            ?_assertEqual(
                {{100, false}, none},
                ?M:hole_step(pending(hole), {100, false}, 99999, 0)
            )}
    ].

%% =============================================================================
%% The sweep
%% =============================================================================

sweep_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun a_standing_hole_raises_once_then_clears/0},
        {timeout, 30, fun a_healthy_instance_never_raises/0},
        {timeout, 30, fun a_vanished_instance_takes_its_alarm_with_it/0}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(sasl),
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

%% The whole lifecycle against a real registry entry and a real alarm handler.
a_standing_hole_raises_once_then_clears() ->
    {Id, O} = fresh(),
    %% Seq 2 folds with 1 absent: the prefix cannot leave 0 and 2 is held.
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [2]}),
    ?assertEqual([2], maps:get(O, bondy_oplog_registry:pending(Id))),

    %% First sweep: adopt. The clock starts now, nothing is raised.
    H1 = sweep([Id], 0, #{}),
    ?assertEqual(#{Id => {0, false}}, H1),
    ?assertEqual(0, alarm_count(Id)),

    %% Still inside the window.
    H2 = sweep([Id], ?T, H1),
    ?assertEqual(#{Id => {0, false}}, H2),
    ?assertEqual(0, alarm_count(Id)),

    %% Past it. Raised exactly once, and repeated sweeps do not duplicate it —
    %% `alarm_handler` would happily hold two.
    H3 = sweep([Id], ?T + 1, H2),
    ?assertEqual(#{Id => {0, true}}, H3),
    ?assertEqual(1, alarm_count(Id)),
    H4 = sweep([Id], 99999, H3),
    ?assertEqual(#{Id => {0, true}}, H4),
    ?assertEqual(1, alarm_count(Id)),

    %% Filling the hole absorbs the pending seq and clears the alarm.
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [1]}),
    ?assertEqual(2, maps:get(O, bondy_oplog_registry:frontier(Id), 0)),
    ?assertEqual(#{}, bondy_oplog_registry:pending(Id)),
    H5 = sweep([Id], 100000, H4),
    ?assertEqual(#{Id => healthy}, H5),
    ?assertEqual(0, alarm_count(Id)).

%% The healthy path costs one adopt-clear and then nothing at all, however
%% long it runs.
a_healthy_instance_never_raises() ->
    {Id, O} = fresh(),
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [1, 2, 3]}),
    H = lists:foldl(
        fun(Now, Acc) -> sweep([Id], Now, Acc) end,
        #{},
        [0, ?T, ?T * 100, ?T * 10000]
    ),
    ?assertEqual(#{Id => healthy}, H),
    ?assertEqual(0, alarm_count(Id)).

%% An instance that goes away while alarmed leaves nothing behind: no episode
%% remembers the id, so no later sweep could ever clear it.
a_vanished_instance_takes_its_alarm_with_it() ->
    Id = <<"hole_alarm_vanished">>,
    ok = alarm_handler:set_alarm({{bondy_oplog_frontier_hole, Id}, <<"x">>}),
    ?assertEqual(1, alarm_count(Id)),
    ?assertEqual(#{}, sweep([], 500, #{Id => {0, true}})),
    ?assertEqual(0, alarm_count(Id)).

%% =============================================================================
%% Helpers
%% =============================================================================

step(Shape, Episode, Now) ->
    ?M:hole_step(pending(Shape), Episode, Now, ?T).

pending(none) -> #{};
pending(hole) -> #{<<"o">> => [2]}.

sweep(Instances, Now, Holes) ->
    ?M:check_holes(Instances, Now, ?T, Holes).

fresh() ->
    Id = list_to_binary(
        "hole_alarm_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    {ok, _} = bondy_oplog:start_instance(Id),
    {Id, bondy_oplog_origin:new()}.

%% SASL's own `alarm_handler` answers `get_alarms/0` with the raw term the
%% producer raised, so match on the id alone: this module asserts THAT the
%% alarm is raised and how many times, never what it carries.
alarm_count(Id) ->
    AlarmId = {bondy_oplog_frontier_hole, Id},
    length([
        A
     || A <- alarm_handler:get_alarms(),
        is_tuple(A),
        element(1, A) =:= AlarmId
    ]).
