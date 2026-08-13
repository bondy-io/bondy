%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Tests the node-wide AAE concurrency cap (`aae_max_concurrency`) and the
%% fair per-tick rotation in `bondy_oplog_sync_scheduler`. Together these are
%% what keep AAE subordinate to routing: a bulk reconciliation can never run
%% more than `aae_max_concurrency` sync sessions at once (the cap that — via
%% `aae_pages_per_round` — bounds bulk-sync RAM), and a low cap cannot starve
%% any shard because each tick rotates which instances win the free slots.
%%
%% Validates:
%%   - `rotate/2` is a correct left-rotation: every element heads the list
%%     exactly once over a full cycle (the fairness primitive).
%%   - The node-wide cap bounds LIVE sessions: with cap=2 and 4 live
%%     instances on one tick, exactly 2 start and 2 are capped.
%%   - A fence-backing instance bypasses the cap (auth availability) even
%%     when the in-flight table is already at the cap.
%% =============================================================================
-module(bondy_oplog_sync_scheduler_aae_concurrency_test).

-include_lib("eunit/include/eunit.hrl").

-define(INFLIGHT_TAB, bondy_oplog_sync_scheduler_inflight).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% `aae_max_concurrency` is a NODE-WIDE cap and the scheduler applies it
    %% across every registered instance, while `run_one_tick_and_count/1`
    %% only counts outcomes for the instances the test created. An instance
    %% leaked by a test that failed or timed out therefore consumes one of the
    %% slots the assertions are counting, and `started` comes back short.
    _ = [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok = bondy_oplog_sync_scheduler:set_interval_ms(0),
    ok = bondy_oplog_sync_scheduler:set_dispatch(
        fun bondy_oplog_sync_scheduler:default_dispatch/2
    ),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    Prev = application:get_env(bondy_oplog, aae_max_concurrency),
    %% Keep the live throttle out of the way: an instance's first sight
    %% always dispatches, which is all these single-tick assertions need.
    Prev.

cleanup(Prev) ->
    ok = bondy_oplog_sync_scheduler:set_interval_ms(500),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    case Prev of
        undefined -> application:unset_env(bondy_oplog, aae_max_concurrency);
        {ok, V} -> application:set_env(bondy_oplog, aae_max_concurrency, V)
    end,
    %% Remove this run's storage tree. Without it each test leaves its
    %% instance directories behind for good: 733, 462 and 168 stale trees
    %% had accumulated under the three bases these scheduler suites use.
    %% Stale trees are not merely untidy — a directory holding a manifest
    %% whose segment has since gone missing makes any later run that
    %% reuses the path fail in recovery.
    _ = file:del_dir_r(
        filename:join("/tmp/" ++ os:getpid(), "bondy_oplog_aae_concurrency_test")
    ),
    ok.

%% `foreach`, not `setup`: setup/cleanup run around EVERY test, so a failing
%% test cannot leave instances behind to eat the next one's concurrency slots.
aae_concurrency_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"rotate is a fair round-robin", fun rotate_round_robin/0},
        {timeout, 15,
            {"node-wide cap bounds live sessions",
                fun live_cap_honoured_within_a_tick/0}},
        {timeout, 15,
            {"fence-backer bypasses the cap", fun fence_backer_bypasses_cap/0}}
    ]}.

%% A pure unit test of the fairness primitive: no clock, no processes.
rotate_round_robin() ->
    L = [a, b, c, d],
    ?assertEqual([a, b, c, d], bondy_oplog_sync_scheduler:rotate(L, 0)),
    ?assertEqual([b, c, d, a], bondy_oplog_sync_scheduler:rotate(L, 1)),
    ?assertEqual([c, d, a, b], bondy_oplog_sync_scheduler:rotate(L, 2)),
    ?assertEqual([d, a, b, c], bondy_oplog_sync_scheduler:rotate(L, 3)),
    %% Wraps cleanly.
    ?assertEqual([a, b, c, d], bondy_oplog_sync_scheduler:rotate(L, 4)),
    ?assertEqual([b, c, d, a], bondy_oplog_sync_scheduler:rotate(L, 5)),
    ?assertEqual([], bondy_oplog_sync_scheduler:rotate([], 7)),
    %% Over a full cycle every element heads the list exactly once — the
    %% property that makes a low cap starvation-free.
    Heads = [
        hd(bondy_oplog_sync_scheduler:rotate(L, N))
     || N <- lists:seq(0, 3)
    ],
    ?assertEqual([a, b, c, d], lists:sort(Heads)).

live_cap_honoured_within_a_tick() ->
    application:set_env(bondy_oplog, aae_max_concurrency, 2),
    Insts = [live_instance(false) || _ <- lists:seq(1, 4)],
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => [p1]}
    ),
    %% Within a single tick the gen_server processes instances
    %% sequentially, so the in-flight count rises monotonically and the
    %% cap bites deterministically: 2 live sessions start, 2 are capped.
    Counts = run_one_tick_and_count(Insts),
    ?assertEqual(2, maps:get(started, Counts)),
    ?assertEqual(2, maps:get(capped, Counts)),
    [bondy_oplog:stop_instance(I) || I <- Insts],
    wait_until_total_inflight(0, 3000).

fence_backer_bypasses_cap() ->
    application:set_env(bondy_oplog, aae_max_concurrency, 1),
    %% Pre-fill the in-flight table to the cap with a dead fake live entry,
    %% so `at_node_cap/0` is already true. A non-fence instance would be
    %% capped here; a fence-backer must still dispatch (auth availability).
    Fake = spawn(fun() -> ok end),
    _ = monitor_until_dead(Fake),
    ets:insert(
        ?INFLIGHT_TAB,
        {Fake, <<"fake">>, live, p_fake, erlang:monotonic_time(millisecond)}
    ),

    Inst = live_instance(true),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => [p1]}
    ),
    Started = collect_started_for(Inst, 2000),
    %% Clean the fake entry we injected (its DOWN may or may not have been
    %% routed to the scheduler depending on ownership; delete defensively).
    catch ets:delete(?INFLIGHT_TAB, Fake),
    ?assert(Started),
    bondy_oplog:stop_instance(Inst),
    wait_until_total_inflight(0, 3000).

%% =============================================================================
%% Helpers
%% =============================================================================

%% A `live` instance (so the scheduler routes it through the live-sync
%% path). `Fence` true sets a non-empty AE target list so `backs_fence/1`
%% reports true and the cap is bypassed.
live_instance(Fence) ->
    Id = mk_id(),
    Dir = filename:join([
        "/tmp/" ++ os:getpid(), "bondy_oplog_aae_concurrency_test", binary_to_list(Id)
    ]),
    ok = filelib:ensure_path(Dir),
    Opts0 = #{storage_path => list_to_binary(Dir)},
    Opts =
        case Fence of
            true -> Opts0#{ae_targets => [{aae_test_ns, aae_test_idx, 0}]};
            false -> Opts0
        end,
    {ok, _} = bondy_oplog:start_instance(Id, Opts),
    ok = bondy_oplog_instance:mark_live(Id),
    ?assertEqual(live, bondy_oplog_instance:lifecycle_state(Id)),
    Id.

%% Triggers ONE tick and counts `live, started` vs `live_capped` telemetry
%% for the supplied instance set (one event per instance on the first tick).
run_one_tick_and_count(InstanceIds) ->
    InstSet = sets:from_list(InstanceIds),
    Self = self(),
    Ref = make_ref(),
    HStarted = {?MODULE, started, Ref},
    HCapped = {?MODULE, capped, Ref},
    telemetry:attach(
        HStarted,
        [bondy_oplog, sync_scheduler, live, started],
        fun(_, _, Meta, _) ->
            sets:is_element(maps:get(instance_id, Meta), InstSet) andalso
                (Self ! {Ref, started})
        end,
        []
    ),
    telemetry:attach(
        HCapped,
        [bondy_oplog, sync_scheduler, live_capped],
        fun(_, _, Meta, _) ->
            sets:is_element(maps:get(instance_id, Meta), InstSet) andalso
                (Self ! {Ref, capped})
        end,
        []
    ),
    try
        bondy_oplog_sync_scheduler:trigger(),
        collect_events(Ref, length(InstanceIds), 3000, #{
            started => 0, capped => 0
        })
    after
        telemetry:detach(HStarted),
        telemetry:detach(HCapped)
    end.

collect_events(_Ref, 0, _Timeout, Acc) ->
    Acc;
collect_events(Ref, Remaining, Timeout, Acc) ->
    receive
        {Ref, started} ->
            collect_events(Ref, Remaining - 1, Timeout, Acc#{
                started := maps:get(started, Acc) + 1
            });
        {Ref, capped} ->
            collect_events(Ref, Remaining - 1, Timeout, Acc#{
                capped := maps:get(capped, Acc) + 1
            })
    after Timeout ->
        error({missing_events, Remaining, Acc})
    end.

%% Triggers one tick and reports whether a `live, started` fired for Inst.
collect_started_for(Inst, Timeout) ->
    Self = self(),
    Ref = make_ref(),
    H = {?MODULE, started_for, Ref},
    telemetry:attach(
        H,
        [bondy_oplog, sync_scheduler, live, started],
        fun(_, _, Meta, _) ->
            (maps:get(instance_id, Meta) =:= Inst) andalso
                (Self ! {Ref, started})
        end,
        []
    ),
    try
        bondy_oplog_sync_scheduler:trigger(),
        receive
            {Ref, started} -> true
        after Timeout -> false
        end
    after
        telemetry:detach(H)
    end.

monitor_until_dead(Pid) ->
    Ref = monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 500 -> error(fake_pid_did_not_die)
    end.

current_total_inflight() ->
    maps:get(
        current_inflight_total, bondy_oplog_sync_scheduler:info()
    ).

wait_until_total_inflight(Target, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_loop(Target, Deadline).

wait_loop(Target, Deadline) ->
    case current_total_inflight() of
        Target ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(20),
                    wait_loop(Target, Deadline);
                false ->
                    error(
                        {timeout_waiting_for_inflight, Target,
                            current_total_inflight()}
                    )
            end
    end.

mk_id() ->
    iolist_to_binary([
        "aaec_", integer_to_binary(erlang:unique_integer([positive]))
    ]).
