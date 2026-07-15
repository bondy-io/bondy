%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Tests the `bootstrap_peer_strategy` plumbing in
%% `bondy_oplog_sync_scheduler`. Each test asserts the chosen peer
%% reported via telemetry meta against an expected pattern for the
%% configured strategy:
%%
%%   - `first`        : always head of peer list.
%%   - `random`       : drawn uniformly; verified by sampling many
%%                      dispatches and asserting the empirical
%%                      distribution covers >1 of the offered peers.
%%   - `round_robin`  : per-instance index advances on every
%%                      dispatch; consecutive dispatches yield
%%                      consecutive peers, wrapping at length(Peers).
%%
%% The tests do NOT exercise the actual bootstrap session — they
%% install a no-op dispatch wrapper that records the chosen peer
%% through the existing scheduler-emitted telemetry event. That keeps
%% these tests independent of the bootstrap protocol itself.
%% =============================================================================
-module(bondy_oplog_sync_scheduler_peer_strategy_test).

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
    %% Disable backoff: these tests assert routing decisions on
    %% rapid-fire triggers. Backoff (PR-D6) is exercised by its own
    %% dedicated suite.
    ok = bondy_oplog_config:set_bootstrap_retry_base_ms(0),
    ok = bondy_oplog_config:set_bootstrap_retry_max_ms(0),
    ok = bondy_oplog_config:set_bootstrap_retry_jitter(false),
    ok.

cleanup(_) ->
    ok = bondy_oplog_config:set_bootstrap_peer_strategy(first),
    ok = bondy_oplog_sync_scheduler:set_interval_ms(500),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    ok = bondy_oplog_config:set_bootstrap_retry_base_ms(500),
    ok = bondy_oplog_config:set_bootstrap_retry_max_ms(30000),
    ok = bondy_oplog_config:set_bootstrap_retry_jitter(true),
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

peer_strategy_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 10, fun first_strategy_picks_head/0},
        {timeout, 10, fun random_strategy_distributes/0},
        {timeout, 10, fun round_robin_strategy_advances/0},
        {timeout, 10, fun unknown_strategy_falls_back_to_first/0},
        {timeout, 10, fun set_strategy_takes_effect_next_tick/0},
        {timeout, 10, fun info_reports_strategy/0}
    ]}.

first_strategy_picks_head() ->
    ok = bondy_oplog_config:set_bootstrap_peer_strategy(first),
    Inst = pre_bootstrap_instance(),
    Peers = [p1, p2, p3],
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => Peers}
    ),
    Chosen = capture_chosen_peers(Inst, 5),
    ?assertEqual([p1, p1, p1, p1, p1], Chosen),
    bondy_oplog:stop_instance(Inst).

random_strategy_distributes() ->
    ok = bondy_oplog_config:set_bootstrap_peer_strategy(random),
    Inst = pre_bootstrap_instance(),
    Peers = [p1, p2, p3, p4],
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => Peers}
    ),
    %% Sample 60 dispatches. With uniform draw the probability that
    %% only one peer appears is (1/4)^59 ≈ 3.4e-36 — effectively zero.
    Chosen = capture_chosen_peers(Inst, 60),
    Unique = lists:usort(Chosen),
    ?assert(length(Unique) > 1),
    %% Every chosen peer was one of the offered.
    ?assertEqual([], Unique -- Peers),
    bondy_oplog:stop_instance(Inst).

round_robin_strategy_advances() ->
    ok = bondy_oplog_config:set_bootstrap_peer_strategy(
        round_robin
    ),
    Inst = pre_bootstrap_instance(),
    Peers = [p1, p2, p3],
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => Peers}
    ),
    %% Reset any pre-existing RR counter (other tests in this suite
    %% may have advanced it under a different instance id; this id
    %% is fresh per call so the counter starts at 0).
    Chosen = capture_chosen_peers(Inst, 7),
    %% First three: full sweep. Then wraps.
    ?assertEqual([p1, p2, p3, p1, p2, p3, p1], Chosen),
    bondy_oplog:stop_instance(Inst).

unknown_strategy_falls_back_to_first() ->
    %% Write an unknown atom directly through app env (the setter
    %% guards against it).
    application:set_env(bondy_oplog, bootstrap_peer_strategy, gibberish),
    Inst = pre_bootstrap_instance(),
    Peers = [p1, p2, p3],
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => Peers}
    ),
    Chosen = capture_chosen_peers(Inst, 4),
    ?assertEqual([p1, p1, p1, p1], Chosen),
    ok = bondy_oplog_config:set_bootstrap_peer_strategy(first),
    bondy_oplog:stop_instance(Inst).

set_strategy_takes_effect_next_tick() ->
    ok = bondy_oplog_config:set_bootstrap_peer_strategy(first),
    Inst = pre_bootstrap_instance(),
    Peers = [p1, p2, p3],
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => Peers}
    ),
    [p1] = capture_chosen_peers(Inst, 1),
    ok = bondy_oplog_config:set_bootstrap_peer_strategy(
        round_robin
    ),
    %% Round-robin starts fresh for this instance id (no prior
    %% counter entry). First call after the switch must be p1.
    [p1, p2, p3] = capture_chosen_peers(Inst, 3),
    bondy_oplog:stop_instance(Inst).

info_reports_strategy() ->
    ok = bondy_oplog_config:set_bootstrap_peer_strategy(random),
    Info = bondy_oplog_sync_scheduler:info(),
    ?assertEqual(random, maps:get(bootstrap_peer_strategy, Info)),
    ok = bondy_oplog_config:set_bootstrap_peer_strategy(first),
    Info2 = bondy_oplog_sync_scheduler:info(),
    ?assertEqual(first, maps:get(bootstrap_peer_strategy, Info2)).

%% =============================================================================
%% Helpers
%% =============================================================================

pre_bootstrap_instance() ->
    Id = mk_id(),
    Dir = filename:join([
        "/tmp",
        "bondy_mst_peer_strategy_test",
        binary_to_list(Id)
    ]),
    ok = filelib:ensure_path(Dir),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        storage_path => list_to_binary(Dir)
    }),
    ?assertEqual(pre_bootstrap, bondy_oplog_instance:lifecycle_state(Id)),
    Id.

%% Triggers `N` ticks and returns the peers chosen for `InstanceId`,
%% in dispatch order. We attach to the telemetry event the scheduler
%% emits on every `dispatch_bootstrap` decision and read the `peer`
%% metadata. The bootstrap session itself fails (`some-peer` is not
%% registered) — fine, this test exercises the routing layer only.
capture_chosen_peers(InstanceId, N) ->
    Self = self(),
    Ref = make_ref(),
    HandlerId = {?MODULE, Ref},
    telemetry:attach(
        HandlerId,
        [bondy_oplog, sync_scheduler, dispatch_bootstrap],
        fun(_, _, Meta, _) ->
            case maps:get(instance_id, Meta) of
                InstanceId ->
                    Self ! {Ref, maps:get(peer, Meta)};
                _ ->
                    ok
            end
        end,
        []
    ),
    try
        Peers = [
            begin
                bondy_oplog_sync_scheduler:trigger(),
                receive
                    {Ref, P} -> P
                after 2000 -> error(no_dispatch)
                end
            end
         || _ <- lists:seq(1, N)
        ],
        Peers
    after
        telemetry:detach(HandlerId)
    end.

mk_id() ->
    iolist_to_binary([
        "ps_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).
