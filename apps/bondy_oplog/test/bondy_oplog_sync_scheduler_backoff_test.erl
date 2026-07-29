%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Tests the per-instance bootstrap-retry backoff in
%% `bondy_oplog_sync_scheduler`.
%%
%% Validates:
%%   - First non-normal DOWN schedules a retry at `now + base`.
%%   - Consecutive non-normal DOWNs double the wait, capped at
%%     `bootstrap_retry_max_ms`.
%%   - Normal-exit DOWN clears the entry.
%%   - `bootstrap_backoff_deferred` telemetry fires on cap-skip.
%%   - Setters take effect on the next failure.
%%
%% Strategy: drive DOWN messages directly into the scheduler gen_server
%% (insert a fake-pid row into the in-flight ETS, then send a DOWN with
%% a chosen reason). This isolates the backoff progression from the
%% actual session-timing, which is non-deterministic.
%% =============================================================================
-module(bondy_oplog_sync_scheduler_backoff_test).

-include_lib("eunit/include/eunit.hrl").

-define(BACKOFF_TAB, bondy_oplog_sync_scheduler_backoff).
-define(INFLIGHT_TAB, bondy_oplog_sync_scheduler_inflight).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok = bondy_oplog_sync_scheduler:set_interval_ms(0),
    ok = bondy_oplog_sync_scheduler:set_dispatch(
        fun bondy_oplog_sync_scheduler:default_dispatch/2
    ),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    %% Tight defaults for fast tests; jitter off for determinism.
    ok = bondy_oplog_config:set_bootstrap_retry_base_ms(100),
    ok = bondy_oplog_config:set_bootstrap_retry_max_ms(1000),
    ok = bondy_oplog_config:set_bootstrap_retry_jitter(false),
    ok.

cleanup(_) ->
    ok = bondy_oplog_sync_scheduler:set_interval_ms(500),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    ok = bondy_oplog_config:set_bootstrap_retry_base_ms(500),
    ok = bondy_oplog_config:set_bootstrap_retry_max_ms(30000),
    ok = bondy_oplog_config:set_bootstrap_retry_jitter(true),
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    %% Wipe lingering backoff entries between modules so a later
    %% suite doesn't inherit "instance X is in backoff".
    ets:delete_all_objects(?BACKOFF_TAB),
    ok.

backoff_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 10, fun first_failure_schedules_retry/0},
        {timeout, 10, fun consecutive_failures_double_up_to_max/0},
        {timeout, 10, fun normal_exit_clears_entry/0},
        {timeout, 10, fun backoff_deferred_telemetry_fires/0},
        {timeout, 10, fun setters_take_effect_on_next_failure/0},
        {timeout, 10, fun info_reports_backoff_knobs/0}
    ]}.

first_failure_schedules_retry() ->
    Inst = mk_id(),
    ets:delete(?BACKOFF_TAB, Inst),
    Before = erlang:monotonic_time(millisecond),
    push_failure(Inst, killed),
    [{Inst, NextMs, Count}] = ets:lookup(?BACKOFF_TAB, Inst),
    ?assertEqual(1, Count),
    %% base=100, count=1 → wait=100. NextMs ≈ Before+100. Allow
    %% generous slack for scheduling jitter.
    ?assert(NextMs >= Before + 100),
    ?assert(NextMs =< Before + 500),
    ets:delete(?BACKOFF_TAB, Inst).

consecutive_failures_double_up_to_max() ->
    Inst = mk_id(),
    ets:delete(?BACKOFF_TAB, Inst),
    Before = erlang:monotonic_time(millisecond),
    %% Push 6 failures; with base=100, max=1000 we expect waits
    %% (no jitter): 100, 200, 400, 800, 1000, 1000.
    push_failure(Inst, killed),
    push_failure(Inst, killed),
    push_failure(Inst, killed),
    push_failure(Inst, killed),
    push_failure(Inst, killed),
    push_failure(Inst, killed),
    [{Inst, NextMs, Count}] = ets:lookup(?BACKOFF_TAB, Inst),
    ?assertEqual(6, Count),
    %% After the 6th, wait should be clamped at max=1000.
    %% NextMs ≈ time-of-last-push + 1000. We bound it generously.
    ?assert(NextMs >= Before + 900),
    ?assert(NextMs =< Before + 2000),
    ets:delete(?BACKOFF_TAB, Inst).

normal_exit_clears_entry() ->
    Inst = mk_id(),
    ets:delete(?BACKOFF_TAB, Inst),
    push_failure(Inst, killed),
    ?assertMatch([{Inst, _, _}], ets:lookup(?BACKOFF_TAB, Inst)),
    push_failure(Inst, normal),
    ?assertEqual([], ets:lookup(?BACKOFF_TAB, Inst)).

backoff_deferred_telemetry_fires() ->
    %% Set a very long backoff so the entry doesn't expire during
    %% the test.
    ok = bondy_oplog_config:set_bootstrap_retry_base_ms(60000),
    ok = bondy_oplog_config:set_bootstrap_retry_max_ms(60000),
    Inst = pre_bootstrap_instance(),
    push_failure(Inst, killed),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => [p1]}
    ),
    Self = self(),
    Ref = make_ref(),
    HandlerId = {?MODULE, Ref},
    telemetry:attach(
        HandlerId,
        [bondy_oplog, sync_scheduler, bootstrap_backoff_deferred],
        fun(_, M, Meta, _) -> Self ! {Ref, M, Meta} end,
        []
    ),
    try
        bondy_oplog_sync_scheduler:trigger(),
        receive
            {Ref, #{wait_ms := Wait, fail_count := 1}, #{instance_id := Inst}} when
                Wait > 0
            ->
                ok
        after 2000 ->
            error(no_backoff_deferred)
        end
    after
        telemetry:detach(HandlerId)
    end,
    bondy_oplog:stop_instance(Inst),
    %% Restore tight defaults for subsequent tests.
    ok = bondy_oplog_config:set_bootstrap_retry_base_ms(100),
    ok = bondy_oplog_config:set_bootstrap_retry_max_ms(1000),
    ets:delete(?BACKOFF_TAB, Inst).

setters_take_effect_on_next_failure() ->
    Inst = mk_id(),
    ets:delete(?BACKOFF_TAB, Inst),
    ok = bondy_oplog_config:set_bootstrap_retry_base_ms(50),
    Before50 = erlang:monotonic_time(millisecond),
    push_failure(Inst, killed),
    [{Inst, NextMs50, _}] = ets:lookup(?BACKOFF_TAB, Inst),
    ?assert(NextMs50 =< Before50 + 200),

    ets:delete(?BACKOFF_TAB, Inst),
    ok = bondy_oplog_config:set_bootstrap_retry_base_ms(800),
    Before800 = erlang:monotonic_time(millisecond),
    push_failure(Inst, killed),
    [{Inst, NextMs800, _}] = ets:lookup(?BACKOFF_TAB, Inst),
    ?assert(NextMs800 >= Before800 + 700),

    ets:delete(?BACKOFF_TAB, Inst),
    ok = bondy_oplog_config:set_bootstrap_retry_base_ms(100).

info_reports_backoff_knobs() ->
    ok = bondy_oplog_config:set_bootstrap_retry_base_ms(123),
    ok = bondy_oplog_config:set_bootstrap_retry_max_ms(45678),
    ok = bondy_oplog_config:set_bootstrap_retry_jitter(false),
    Info = bondy_oplog_sync_scheduler:info(),
    ?assertEqual(123, maps:get(bootstrap_retry_base_ms, Info)),
    ?assertEqual(45678, maps:get(bootstrap_retry_max_ms, Info)),
    ?assertEqual(false, maps:get(bootstrap_retry_jitter, Info)),
    ok = bondy_oplog_config:set_bootstrap_retry_base_ms(100),
    ok = bondy_oplog_config:set_bootstrap_retry_max_ms(1000),
    ok = bondy_oplog_config:set_bootstrap_retry_jitter(false).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Simulates a session DOWN by inserting a fake pid into the
%% in-flight table and posting a `{'DOWN', ...}` message to the
%% scheduler. Uses `sys:get_state/1` as a synchronous fence — the
%% gen_server will not respond until it has processed all messages
%% ahead of the get_state call, which guarantees the DOWN has been
%% handled (and `update_backoff/2` has run) before we return.
push_failure(InstanceId, Reason) ->
    Sched = whereis(bondy_oplog_sync_scheduler),
    FakePid = spawn(fun() -> ok end),
    %% Wait for FakePid to die so the monitor would fire DOWN
    %% naturally — we still send our own DOWN to control timing.
    Ref = monitor(process, FakePid),
    receive
        {'DOWN', Ref, process, FakePid, _} -> ok
    after 500 -> error(fake_pid_did_not_die)
    end,
    ets:insert(
        ?INFLIGHT_TAB,
        {FakePid, InstanceId, bootstrap, undefined, erlang:monotonic_time(millisecond)}
    ),
    Sched ! {'DOWN', make_ref(), process, FakePid, Reason},
    _ = sys:get_state(Sched),
    ok.

pre_bootstrap_instance() ->
    Id = mk_id(),
    Dir = filename:join([
        "/tmp",
        "bondy_mst_scheduler_backoff_test",
        binary_to_list(Id)
    ]),
    ok = filelib:ensure_path(Dir),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        storage_path => list_to_binary(Dir)
    }),
    ?assertEqual(pre_bootstrap, bondy_oplog_instance:lifecycle_state(Id)),
    Id.

mk_id() ->
    iolist_to_binary([
        "bo_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).
