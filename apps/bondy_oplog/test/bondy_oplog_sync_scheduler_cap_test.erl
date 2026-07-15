%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Tests the bootstrap-session count cap in `bondy_oplog_sync_scheduler`.
%%
%% Validates:
%%   - Cap honoured: with cap=2 and 3 pre_bootstrap instances on the
%%     same tick, exactly 2 dispatches and 1 cap-skip occur.
%%   - DOWN cleans up: the in-flight count drops back to 0 after the
%%     spawned sessions exit (they fail fast because the peer is not
%%     a registered instance).
%%   - Cap-skip telemetry fires with current/cap measurements.
%%   - `info/0` reports `max_inflight_bootstraps` and
%%     `current_inflight_bootstraps`.
%%   - `max_inflight_bootstraps = 0` disables dispatch (escape hatch).
%% =============================================================================
-module(bondy_oplog_sync_scheduler_cap_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok = bondy_oplog_sync_scheduler:set_interval_ms(0),
    ok = bondy_oplog_sync_scheduler:set_dispatch(
        fun bondy_oplog_sync_scheduler:default_dispatch/2
    ),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    ok = bondy_oplog_config:set_max_inflight_bootstraps(4),
    ok = bondy_oplog_config:set_bootstrap_peer_strategy(first),
    ok.

cleanup(_) ->
    ok = bondy_oplog_config:set_max_inflight_bootstraps(4),
    ok = bondy_oplog_sync_scheduler:set_interval_ms(500),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

cap_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 10, fun cap_honoured_within_a_tick/0},
        {timeout, 10, fun inflight_cleans_up_after_session_dies/0},
        {timeout, 10, fun info_reports_cap_and_current/0},
        {timeout, 10, fun zero_cap_disables_dispatch/0}
    ]}.

cap_honoured_within_a_tick() ->
    ok = bondy_oplog_config:set_max_inflight_bootstraps(2),
    Insts = [pre_bootstrap_instance() || _ <- lists:seq(1, 3)],
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => [p1]}
    ),
    Counts = run_one_tick_and_count(Insts),
    %% Across the 3 instances on a single tick:
    %%   - 2 dispatched (each gets a session pid spawned)
    %%   - 1 capped
    ?assertEqual(2, maps:get(dispatched, Counts)),
    ?assertEqual(1, maps:get(capped, Counts)),
    [bondy_oplog:stop_instance(I) || I <- Insts],
    %% Wait for DOWN cleanup so subsequent tests start clean.
    wait_until_inflight(0, 2000).

inflight_cleans_up_after_session_dies() ->
    ok = bondy_oplog_config:set_max_inflight_bootstraps(4),
    Inst = pre_bootstrap_instance(),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => [p_fast_fail]}
    ),
    bondy_oplog_sync_scheduler:trigger(),
    %% Sessions fail almost immediately because `p_fast_fail` is not
    %% a registered instance — DOWN fires on the scheduler.
    wait_until_inflight(0, 2000),
    ?assertEqual(0, current_inflight()),
    bondy_oplog:stop_instance(Inst).

info_reports_cap_and_current() ->
    ok = bondy_oplog_config:set_max_inflight_bootstraps(7),
    Info = bondy_oplog_sync_scheduler:info(),
    ?assertEqual(7, maps:get(max_inflight_bootstraps, Info)),
    ?assert(maps:is_key(current_inflight_bootstraps, Info)),
    %% Reset.
    ok = bondy_oplog_config:set_max_inflight_bootstraps(4).

zero_cap_disables_dispatch() ->
    ok = bondy_oplog_config:set_max_inflight_bootstraps(0),
    Inst = pre_bootstrap_instance(),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => [p1]}
    ),
    Counts = run_one_tick_and_count([Inst]),
    ?assertEqual(0, maps:get(dispatched, Counts)),
    ?assertEqual(1, maps:get(capped, Counts)),
    %% Restore to the default for downstream tests.
    ok = bondy_oplog_config:set_max_inflight_bootstraps(4),
    bondy_oplog:stop_instance(Inst).

%% =============================================================================
%% Helpers
%% =============================================================================

pre_bootstrap_instance() ->
    Id = mk_id(),
    Dir = filename:join([
        "/tmp",
        "bondy_mst_scheduler_cap_test",
        binary_to_list(Id)
    ]),
    ok = filelib:ensure_path(Dir),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        storage_path => list_to_binary(Dir)
    }),
    ?assertEqual(pre_bootstrap, bondy_oplog_instance:lifecycle_state(Id)),
    Id.

%% Triggers ONE tick and counts how many `dispatch_bootstrap` vs
%% `bootstrap_capped` telemetry events fire for the supplied instance
%% set. Within a tick the gen_server processes instances sequentially
%% so the in-flight count rises monotonically — perfect for asserting
%% the cap.
run_one_tick_and_count(InstanceIds) ->
    InstSet = sets:from_list(InstanceIds),
    Self = self(),
    Ref = make_ref(),
    HDispatch = {?MODULE, dispatch, Ref},
    HCapped = {?MODULE, capped, Ref},
    telemetry:attach(
        HDispatch,
        [bondy_oplog, sync_scheduler, dispatch_bootstrap],
        fun(_, _, Meta, _) ->
            case sets:is_element(maps:get(instance_id, Meta), InstSet) of
                true -> Self ! {Ref, dispatched};
                false -> ok
            end
        end,
        []
    ),
    telemetry:attach(
        HCapped,
        [bondy_oplog, sync_scheduler, bootstrap_capped],
        fun(_, _, Meta, _) ->
            case sets:is_element(maps:get(instance_id, Meta), InstSet) of
                true -> Self ! {Ref, capped};
                false -> ok
            end
        end,
        []
    ),
    try
        bondy_oplog_sync_scheduler:trigger(),
        collect_events(Ref, length(InstanceIds), 2000, #{
            dispatched => 0, capped => 0
        })
    after
        telemetry:detach(HDispatch),
        telemetry:detach(HCapped)
    end.

collect_events(_Ref, 0, _Timeout, Acc) ->
    Acc;
collect_events(Ref, Remaining, Timeout, Acc) ->
    receive
        {Ref, dispatched} ->
            collect_events(
                Ref,
                Remaining - 1,
                Timeout,
                Acc#{dispatched := maps:get(dispatched, Acc) + 1}
            );
        {Ref, capped} ->
            collect_events(
                Ref,
                Remaining - 1,
                Timeout,
                Acc#{capped := maps:get(capped, Acc) + 1}
            )
    after Timeout ->
        error({missing_events, Remaining, Acc})
    end.

current_inflight() ->
    maps:get(
        current_inflight_bootstraps,
        bondy_oplog_sync_scheduler:info()
    ).

wait_until_inflight(Target, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_until_inflight_loop(Target, Deadline).

wait_until_inflight_loop(Target, Deadline) ->
    case current_inflight() of
        Target ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(20),
                    wait_until_inflight_loop(Target, Deadline);
                false ->
                    error(
                        {timeout_waiting_for_inflight, Target,
                            current_inflight()}
                    )
            end
    end.

mk_id() ->
    iolist_to_binary([
        "sc_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).
