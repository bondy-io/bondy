%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% The applier's drain-stall detector: actively processing frames without
%% ever committing a position BEYOND the historical maximum must raise the
%% `{bondy_oplog_drain_stalled, InstanceId}` alarm — the signal that a
%% node's applied state is falling behind its own WAL even while
%% anti-entropy reports it converged — and progress (or catching up) must
%% clear it. Driven through the clock-decoupled `/2` test seams.
-module(bondy_oplog_applier_stall_test).

-include_lib("eunit/include/eunit.hrl").

-define(M, bondy_oplog_applier).
-define(ID, <<"stall-test">>).
-define(ALARM_ID, {bondy_oplog_drain_stalled, ?ID}).

stall_test_() ->
    {setup,
        fun() ->
            %% The SASL alarm handler receives the alarms.
            {ok, Started} = application:ensure_all_started(sasl),
            Started
        end,
        fun(Started) ->
            _ = alarm_handler:clear_alarm(?ALARM_ID),
            _ = [application:stop(A) || A <- lists:reverse(Started)],
            ok
        end,
        [
            {"below the window is not a stall", fun below_window/0},
            {"beyond the window raises the alarm once", fun raises_once/0},
            {"disabled detector never raises", fun disabled/0},
            {"progress beyond max clears and re-arms", fun progress_clears/0},
            {"re-covered ground is not progress", fun replay_not_progress/0},
            {"caught-up idle clears and re-arms", fun idle_clears/0}
        ]}.

below_window() ->
    S0 = ?M:stall_test_state(#{
        drain_progress_at => 1000, drain_stall_alarm_ms => 500
    }),
    S1 = ?M:check_drain_stall(1400, S0),
    ?assertMatch(#{drain_stalled := false}, ?M:stall_test_fields(S1)),
    ?assertEqual(false, is_alarm_set()).

raises_once() ->
    S0 = ?M:stall_test_state(#{
        drain_progress_at => 1000, drain_stall_alarm_ms => 500
    }),
    S1 = ?M:check_drain_stall(1501, S0),
    ?assertMatch(#{drain_stalled := true}, ?M:stall_test_fields(S1)),
    ?assertEqual(true, is_alarm_set()),

    %% Already stalled: a further check must not duplicate the alarm.
    S2 = ?M:check_drain_stall(9999, S1),
    ?assertMatch(#{drain_stalled := true}, ?M:stall_test_fields(S2)),
    ?assertEqual(1, alarm_count()),
    _ = alarm_handler:clear_alarm(?ALARM_ID),
    ok.

disabled() ->
    S0 = ?M:stall_test_state(#{
        drain_progress_at => 0, drain_stall_alarm_ms => 0
    }),
    S1 = ?M:check_drain_stall(1_000_000, S0),
    ?assertMatch(#{drain_stalled := false}, ?M:stall_test_fields(S1)),
    ?assertEqual(false, is_alarm_set()).

progress_clears() ->
    S0 = ?M:stall_test_state(#{
        drain_progress_at => 1000,
        drain_stall_alarm_ms => 500,
        drain_max_pos => {3, 900},
        consumer_offset => co({3, 1200})
    }),
    S1 = ?M:check_drain_stall(2000, S0),
    ?assertEqual(true, is_alarm_set()),

    %% A commit beyond the max is progress: watermark and clock advance,
    %% the alarm clears.
    S2 = ?M:note_drain_progress(2100, S1),
    ?assertMatch(
        #{
            drain_stalled := false,
            drain_max_pos := {3, 1200},
            drain_progress_at := 2100
        },
        ?M:stall_test_fields(S2)
    ),
    ?assertEqual(false, is_alarm_set()).

replay_not_progress() ->
    %% Commits at or below the historical max — the re-read failure shape —
    %% must NOT reset the stall clock.
    S0 = ?M:stall_test_state(#{
        drain_progress_at => 1000,
        drain_max_pos => {5, 4096},
        consumer_offset => co({5, 2048})
    }),
    S1 = ?M:note_drain_progress(9000, S0),
    ?assertMatch(
        #{drain_progress_at := 1000, drain_max_pos := {5, 4096}},
        ?M:stall_test_fields(S1)
    ),
    %% An earlier segment is equally not progress.
    S2 = ?M:note_drain_progress(
        9000,
        ?M:stall_test_state(#{
            drain_progress_at => 1000,
            drain_max_pos => {5, 4096},
            consumer_offset => co({4, 9999})
        })
    ),
    ?assertMatch(#{drain_progress_at := 1000}, ?M:stall_test_fields(S2)).

idle_clears() ->
    S0 = ?M:stall_test_state(#{
        drain_progress_at => 1000, drain_stall_alarm_ms => 500
    }),
    S1 = ?M:check_drain_stall(2000, S0),
    ?assertEqual(true, is_alarm_set()),
    S2 = ?M:note_drain_idle(2500, S1),
    ?assertMatch(
        #{drain_stalled := false, drain_progress_at := 2500},
        ?M:stall_test_fields(S2)
    ),
    ?assertEqual(false, is_alarm_set()).

%% =============================================================================
%% Helpers
%% =============================================================================

%% A consumer offset committed at `{Seg, Off}`.
co({Seg, Off}) ->
    CO0 = bondy_oplog_wal_state:new_consumer_offset(),
    CO1 = bondy_oplog_wal_state:with_position(CO0, Seg, Off),
    bondy_oplog_wal_state:with_commit_count(CO1, 1).

is_alarm_set() ->
    lists:keymember(?ALARM_ID, 1, alarm_handler:get_alarms()).

alarm_count() ->
    length([A || {Id, _} = A <- alarm_handler:get_alarms(), Id =:= ?ALARM_ID]).
