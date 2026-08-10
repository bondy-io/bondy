%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_regulator_load_test).

-include_lib("eunit/include/eunit.hrl").

-define(PT_KEY, {bondy_regulator_load, status}).

fails_open_when_not_running_test() ->
    _ = persistent_term:erase(?PT_KEY),
    ?assertNot(bondy_regulator_load:busy()),
    ?assertEqual(normal, bondy_regulator_load:status()),
    ?assertEqual(0, bondy_regulator_load:run_queue()).

%% A crossing shorter than the dwell window must not change the status.
%% This is the case an idle node hits constantly: a wave of periodic
%% timers wakes together, the instantaneous run queue spikes for one
%% sample, and committing on it would refuse a HELLO.
transient_spike_does_not_flip_test() ->
    %% normal(0) sees the high watermark crossed for two samples, then
    %% drops back before the third.
    ?assertEqual({hold, 1}, bondy_regulator_load:step(0, 1, 0)),
    ?assertEqual({hold, 2}, bondy_regulator_load:step(0, 1, 1)),
    ?assertEqual({hold, 0}, bondy_regulator_load:step(0, 0, 2)).

sustained_crossing_commits_test() ->
    ?assertEqual({hold, 1}, bondy_regulator_load:step(0, 1, 0)),
    ?assertEqual({hold, 2}, bondy_regulator_load:step(0, 1, 1)),
    ?assertEqual({commit, 1}, bondy_regulator_load:step(0, 1, 2)).

%% Recovery is debounced the same way, so a single quiet sample during
%% real saturation does not re-open admission.
sustained_recovery_commits_test() ->
    ?assertEqual({hold, 1}, bondy_regulator_load:step(1, 0, 0)),
    ?assertEqual({hold, 0}, bondy_regulator_load:step(1, 1, 1)),
    ?assertEqual({hold, 1}, bondy_regulator_load:step(1, 0, 0)),
    ?assertEqual({hold, 2}, bondy_regulator_load:step(1, 0, 1)),
    ?assertEqual({commit, 0}, bondy_regulator_load:step(1, 0, 2)).

%% Staying on the committed side is always a no-op reset.
steady_state_is_a_noop_test() ->
    ?assertEqual({hold, 0}, bondy_regulator_load:step(0, 0, 0)),
    ?assertEqual({hold, 0}, bondy_regulator_load:step(1, 1, 0)),
    ?assertEqual({hold, 0}, bondy_regulator_load:step(0, 0, 2)).

lifecycle_test_() ->
    {timeout, 10, fun lifecycle/0}.

lifecycle() ->
    {ok, Pid} = bondy_regulator_load:start_link(),

    %% An idle node samples as normal within a few intervals.
    ok = timer:sleep(350),
    ?assertEqual(normal, bondy_regulator_load:status()),
    ?assert(bondy_regulator_load:run_queue() >= 0),

    %% White-box: force the busy state through the published ref while
    %% the sampler is suspended; lock-free readers observe it.
    Ref = persistent_term:get(?PT_KEY),
    ok = sys:suspend(bondy_regulator_load),
    ok = atomics:put(Ref, 1, 1),
    ?assert(bondy_regulator_load:busy()),
    ?assertEqual(busy, bondy_regulator_load:status()),

    %% The sampler's next tick returns an idle node to normal (run
    %% queue far below the low watermark).
    ok = sys:resume(bondy_regulator_load),
    ok = timer:sleep(350),
    ?assertNot(bondy_regulator_load:busy()),

    %% A restart resets the published status to normal (fail open), and
    %% so does termination.
    ok = sys:suspend(bondy_regulator_load),
    ok = atomics:put(Ref, 1, 1),
    ok = sys:resume(bondy_regulator_load),
    ok = gen_server:stop(Pid),
    ?assertNot(bondy_regulator_load:busy()),

    {ok, Pid2} = bondy_regulator_load:start_link(),
    ?assertNot(bondy_regulator_load:busy()),
    ok = gen_server:stop(Pid2).
