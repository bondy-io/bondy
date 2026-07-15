%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Tests the load-reactive yield in `bondy_oplog_sync_scheduler`: the temporal
%% lever that, on top of the node-wide concurrency cap, transiently defers AAE's
%% throttleable dispatches while the node is backlogged so background
%% reconciliation never steals scheduler time from routing.
%%
%% Two layers:
%%   - The pure decision (`load_decide/4`): EWMA smoothing + threshold, with no
%%     VM probe or clock. Asserts a disabled gate never yields, that a single
%%     moderate spike does not cross (hysteresis) while sustained load does, and
%%     that load falling back below the threshold resumes dispatch.
%%   - The wiring: with the gate forced on via a `0.0` threshold (every tick
%%     yields), a non-fence `live` shard is deferred (no session started, a
%%     `live_load_deferred` telemetry fires) while a fence-backer dispatches
%%     anyway (auth availability), and with the gate off the non-fence shard
%%     dispatches normally.
%% =============================================================================
-module(bondy_oplog_sync_scheduler_load_gate_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% PURE DECISION TESTS (no setup)
%% =============================================================================

%% A disabled gate never yields, however high the load — the EWMA is still
%% folded (so re-enabling sees a warm signal) but the verdict is always false.
load_decide_disabled_never_yields_test() ->
    ?assertMatch({_, false}, decide(false, 1000.0, 0.0, 2.0)),
    ?assertMatch({_, false}, decide(false, 1000.0, 999.0, 2.0)),
    {Ewma, false} = decide(false, 10.0, 0.0, 2.0),
    %% EWMA folded even while disabled.
    ?assert(close(Ewma, 3.0)).

%% Above the threshold yields; below does not.
load_decide_threshold_test() ->
    %% A baseline already above threshold stays above after a high sample.
    ?assertMatch({_, true}, decide(true, 5.0, 5.0, 2.0)),
    %% A baseline at zero with a zero sample is below threshold.
    ?assertMatch({_, false}, decide(true, 0.0, 0.0, 2.0)),
    %% Clearly above the threshold yields (`>=`).
    ?assertMatch({_, true}, decide(true, 2.5, 2.5, 2.0)).

%% A single moderate spike from a quiet baseline does NOT immediately yield;
%% sustained load builds the EWMA across ticks until it crosses.
load_decide_hysteresis_test() ->
    %% One tick of run-queue ratio 3.0 from cold: 0.3*3 = 0.9, well under 2.0.
    {E1, Y1} = decide(true, 3.0, 0.0, 2.0),
    ?assert(close(E1, 0.9)),
    ?assertEqual(false, Y1),
    %% Feed a sustained 3.0 and watch it cross only after several ticks.
    Verdicts = verdict_chain(true, lists:duplicate(5, 3.0), 0.0, 2.0),
    %% Not on tick 1–3, yes by tick 4 (0.9, 1.53, 1.971, 2.28, ...).
    ?assertEqual([false, false, false, true, true], Verdicts).

%% Once the gate is yielding, load dropping back to quiet resumes dispatch
%% after the EWMA decays below the threshold.
load_decide_resume_test() ->
    %% Start hot (Ewma 5.0), then feed quiet (0.0) samples.
    Verdicts = verdict_chain(true, lists:duplicate(5, 0.0), 5.0, 2.0),
    %% 3.5 (yield), 2.45 (yield), 1.715 (resume), ...
    ?assertEqual([true, true, false, false, false], Verdicts).

%% =============================================================================
%% WIRING TESTS (real scheduler + instances)
%% =============================================================================

wiring_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 15,
            {"load yield defers a non-fence live shard",
                fun load_yield_defers_non_fence_live/0}},
        {timeout, 15,
            {"a fence-backer is exempt from the load yield",
                fun load_yield_exempts_fence_backer/0}},
        {timeout, 15,
            {"gate off dispatches normally", fun gate_off_dispatches/0}}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok = bondy_oplog_sync_scheduler:set_interval_ms(0),
    ok = bondy_oplog_sync_scheduler:set_dispatch(
        fun bondy_oplog_sync_scheduler:default_dispatch/2
    ),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => [p1]}
    ),
    #{
        adaptive => application:get_env(bondy_oplog, aae_load_adaptive),
        threshold =>
            application:get_env(bondy_oplog, aae_load_run_queue_threshold)
    }.

cleanup(Prev) ->
    ok = bondy_oplog_sync_scheduler:set_interval_ms(500),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    restore(aae_load_adaptive, maps:get(adaptive, Prev)),
    restore(aae_load_run_queue_threshold, maps:get(threshold, Prev)),
    ok.

%% Gate on with a 0.0 threshold ⇒ every tick yields. A non-fence live shard's
%% first sight would dispatch (the throttle always dispatches on first sight),
%% so the ONLY reason it does not is the load gate — making the deferral the
%% clean signal under test.
load_yield_defers_non_fence_live() ->
    force_gate(on, 0.0),
    Inst = live_instance(_Fence = false),
    {Started, Deferred} = one_tick(Inst, live_load_deferred),
    ?assertEqual(false, Started),
    ?assertEqual(true, Deferred),
    bondy_oplog:stop_instance(Inst),
    wait_until_total_inflight(0, 3000).

%% Same forced-yield, but a fence-backer must dispatch regardless (its freshness
%% bump must land within auth_max_lag or the read-side fence refuses auth).
load_yield_exempts_fence_backer() ->
    force_gate(on, 0.0),
    Inst = live_instance(_Fence = true),
    {Started, _Deferred} = one_tick(Inst, live_load_deferred),
    ?assertEqual(true, Started),
    bondy_oplog:stop_instance(Inst),
    wait_until_total_inflight(0, 3000).

%% Gate off ⇒ a non-fence shard dispatches even though a 0.0 threshold would
%% otherwise yield.
gate_off_dispatches() ->
    force_gate(off, 0.0),
    Inst = live_instance(_Fence = false),
    {Started, _Deferred} = one_tick(Inst, live_load_deferred),
    ?assertEqual(true, Started),
    bondy_oplog:stop_instance(Inst),
    wait_until_total_inflight(0, 3000).

%% =============================================================================
%% Helpers
%% =============================================================================

decide(Enabled, Sample, Prev, Threshold) ->
    bondy_oplog_sync_scheduler:load_decide(Enabled, Sample, Prev, Threshold).

%% Folds a list of samples through `load_decide/4`, threading the EWMA, and
%% returns the per-tick yield verdicts.
verdict_chain(Enabled, Samples, Prev0, Threshold) ->
    {_, Rev} = lists:foldl(
        fun(S, {Prev, Acc}) ->
            {Ewma, Yield} = decide(Enabled, S, Prev, Threshold),
            {Ewma, [Yield | Acc]}
        end,
        {Prev0, []},
        Samples
    ),
    lists:reverse(Rev).

close(A, B) ->
    abs(A - B) < 0.0001.

force_gate(OnOff, Threshold) ->
    application:set_env(
        bondy_oplog, aae_load_adaptive, OnOff =:= on
    ),
    application:set_env(
        bondy_oplog, aae_load_run_queue_threshold, Threshold
    ),
    ok.

restore(Key, undefined) ->
    application:unset_env(bondy_oplog, Key);
restore(Key, {ok, V}) ->
    application:set_env(bondy_oplog, Key, V).

%% A `live` instance; `Fence` true sets a non-empty AE target list so it backs
%% the fence and is exempt from the yield.
live_instance(Fence) ->
    Id = mk_id(),
    Dir = filename:join([
        "/tmp", "bondy_oplog_load_gate_test", binary_to_list(Id)
    ]),
    ok = filelib:ensure_path(Dir),
    Opts0 = #{storage_path => list_to_binary(Dir)},
    Opts =
        case Fence of
            true -> Opts0#{ae_targets => [{load_test_ns, load_test_idx, 0}]};
            false -> Opts0
        end,
    {ok, _} = bondy_oplog:start_instance(Id, Opts),
    ok = bondy_oplog_instance:mark_live(Id),
    ?assertEqual(live, bondy_oplog_instance:lifecycle_state(Id)),
    Id.

%% Triggers one tick and reports, for `Inst`, whether a live session started
%% and whether the named load-deferral telemetry fired.
one_tick(Inst, DeferEvent) ->
    Self = self(),
    Ref = make_ref(),
    HStarted = {?MODULE, started, Ref},
    HDeferred = {?MODULE, deferred, Ref},
    telemetry:attach(
        HStarted,
        [bondy_oplog, sync_scheduler, live, started],
        fun(_, _, Meta, _) ->
            (maps:get(instance_id, Meta) =:= Inst) andalso
                (Self ! {Ref, started})
        end,
        []
    ),
    telemetry:attach(
        HDeferred,
        [bondy_oplog, sync_scheduler, DeferEvent],
        fun(_, _, Meta, _) ->
            (maps:get(instance_id, Meta) =:= Inst) andalso
                (Self ! {Ref, deferred})
        end,
        []
    ),
    try
        bondy_oplog_sync_scheduler:trigger(),
        %% The tick processes this instance synchronously; one of the two
        %% events fires for it. Collect both outcomes over a short window.
        Started = collect_flag(Ref, started, 3000),
        Deferred = collect_flag(Ref, deferred, 100),
        {Started, Deferred}
    after
        telemetry:detach(HStarted),
        telemetry:detach(HDeferred)
    end.

collect_flag(Ref, Tag, Timeout) ->
    receive
        {Ref, Tag} -> true
    after Timeout -> false
    end.

current_total_inflight() ->
    maps:get(current_inflight_total, bondy_oplog_sync_scheduler:info()).

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
        "lgt_", integer_to_binary(erlang:unique_integer([positive]))
    ]).
