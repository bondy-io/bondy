%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% End-to-end tests for per-instance write→readable latency telemetry
%% (`bondy_oplog_latency`). Real user writes are sampled on the synchronous
%% `bondy_db:apply/4` path; a periodic tick emits one
%% `[bondy_oplog, instance, write_latency]` event per instance that saw
%% writes in the window. These tests drive real writes through the substrate
%% and assert the emitted measurements (count + mean/p50/p95/p99/max) and the
%% disabled-gate no-op.

-module(bondy_oplog_latency_e2e_test).

-include_lib("eunit/include/eunit.hrl").

-define(EVENT, [bondy_oplog, instance, write_latency]).

%% =============================================================================
%% Fixture
%% =============================================================================

latency_e2e_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"real writes are sampled and emitted per instance",
                fun samples_emitted/0},
            {"the histogram count matches the number of writes",
                fun histogram_count_matches/0},
            {"disabling suppresses sampling and emit",
                fun disabled_suppresses/0},
            {"idle probe makes an idle instance report a heartbeat",
                {timeout, 30, fun idle_probe_heartbeats/0}},
            {"probe_write is type-correct for tier_2 (aw_map) and dynamic lww",
                {timeout, 30, fun probe_write_per_type/0}},
            {"a stopped instance's histogram is pruned",
                {timeout, 30, fun churn_prune/0}}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok = bondy_oplog_latency:set_enabled(true),
    ok.

cleanup(_) ->
    _ = bondy_oplog_latency:set_enabled(true),
    _ = bondy_oplog_latency:set_probe_enabled(false),
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

%% N synchronous counter increments produce N samples; forcing a tick emits
%% exactly one event for that instance, with sane ordered percentiles.
samples_emitted() ->
    ok = bondy_oplog_latency:set_enabled(true),
    Db = open_counter_db(lat_emit),
    {ok, T} = bondy_db:open_table(Db, counters, #{}),
    Id = instance_of(T),
    N = 25,
    [ok = bondy_db:counter_inc(T, <<"r">>, <<"k">>, 1) || _ <- lists:seq(1, N)],

    {Meas, Meta} = with_handler(fun() ->
        ok = bondy_oplog_latency:snapshot_now(),
        recv_for(Id, 2000)
    end),

    ?assertEqual(N, maps:get(count, Meas)),
    %% mean/percentiles/max are non-negative integers and correctly ordered.
    #{
        mean_us := Mean,
        p50_us := P50,
        p95_us := P95,
        p99_us := P99,
        max_us := Max
    } = Meas,
    [?assert(is_integer(X) andalso X >= 0) || X <- [Mean, P50, P95, P99, Max]],
    ?assert(P50 =< P95),
    ?assert(P95 =< P99),
    ?assert(P99 =< Max),
    ?assert(is_integer(maps:get(interval_ms, Meta))),
    ?assert(maps:get(interval_ms, Meta) >= 1),
    close_stop(Db, Id).

%% The bondy_metrics histogram backing the instance records exactly one
%% observation per write (independent of the emit path).
histogram_count_matches() ->
    ok = bondy_oplog_latency:set_enabled(true),
    Db = open_counter_db(lat_count),
    {ok, T} = bondy_db:open_table(Db, counters, #{}),
    Id = instance_of(T),
    N = 13,
    [ok = bondy_db:counter_inc(T, <<"r">>, <<"k">>, 1) || _ <- lists:seq(1, N)],
    {ok, Snap} = bondy_metrics:histogram_snapshot(#{
        name => bondy_oplog_latency:metric_name(),
        label => #{instance_id => Id}
    }),
    ?assertEqual(N, maps:get(count, Snap)),
    ?assert(maps:get(sum, Snap) >= 0),
    close_stop(Db, Id).

%% With sampling disabled, a fresh instance accumulates no histogram and the
%% forced tick emits nothing for it.
disabled_suppresses() ->
    ok = bondy_oplog_latency:set_enabled(false),
    Db = open_counter_db(lat_off),
    {ok, T} = bondy_db:open_table(Db, counters, #{}),
    Id = instance_of(T),
    [
        ok = bondy_db:counter_inc(T, <<"r">>, <<"k">>, 1)
     || _ <- lists:seq(1, 10)
    ],

    %% No histogram was created for this instance.
    ?assertEqual(
        not_found,
        bondy_metrics:histogram_snapshot(#{
            name => bondy_oplog_latency:metric_name(),
            label => #{instance_id => Id}
        })
    ),
    %% And the tick emits no event for it.
    Result = with_handler(fun() ->
        ok = bondy_oplog_latency:snapshot_now(),
        recv_for(Id, 500)
    end),
    ?assertEqual(timeout, Result),
    ok = bondy_oplog_latency:set_enabled(true),
    close_stop(Db, Id).

%% An instance that takes NO real writes still reports a heartbeat once the
%% idle probe is enabled: tick 1 probes it (async reserved-cell write),
%% tick 2 emits the probe sample as the instance's latency.
idle_probe_heartbeats() ->
    ok = bondy_oplog_latency:set_enabled(true),
    ok = bondy_oplog_latency:set_probe_enabled(true),
    Db = open_counter_db(lat_probe),
    {ok, T} = bondy_db:open_table(Db, counters, #{}),
    Id = instance_of(T),
    %% No user writes at all. The instance is registered but idle.
    ?assertEqual(not_found, hist_snapshot(Id)),

    %% Tick 1 sees it idle and spawns the probe; wait for the probe write
    %% to land in the histogram.
    ok = bondy_oplog_latency:snapshot_now(),
    ok = wait_hist(Id, 1, 5000),

    %% Tick 2 emits the probe sample as a heartbeat for the instance.
    {Meas, _Meta} = with_handler(fun() ->
        ok = bondy_oplog_latency:snapshot_now(),
        recv_for(Id, 2000)
    end),
    ?assert(maps:get(count, Meas) >= 1),

    %% The probe lives in a reserved bucket: a normal user read of a key we
    %% never wrote returns not_found (no user-keyspace pollution).
    ?assertEqual(
        {error, not_found}, bondy_db:read(T, <<"realm">>, <<"never">>)
    ),
    close_stop(Db, Id).

%% probe_write must produce a type-correct, accepted op for each CRDT: a
%% tier_2 add-wins map (context-stamped) and the dynamic-HLC lww register.
probe_write_per_type() ->
    ok = bondy_oplog_latency:set_enabled(true),
    %% tier_2 aw_map
    {DbM, _Om} = open_aw_map_db(lat_probe_map),
    {ok, Tm} = bondy_db:open_table(DbM, items, #{}),
    IdM = instance_of(Tm),
    ?assertEqual(ok, bondy_db:probe_write(IdM)),
    ?assertEqual(ok, bondy_db:probe_write(IdM)),
    %% the reserved cell is invisible to a normal read of the user keyspace
    ?assertEqual({error, not_found}, bondy_db:read(Tm, <<"realm">>, <<"k">>)),
    close_stop(DbM, IdM),

    %% tier_0 lww (the default type) — probe op carries a fresh HLC
    {DbL, _Ol} = open_lww_db(lat_probe_lww),
    {ok, Tl} = bondy_db:open_table(DbL, items, #{}),
    IdL = instance_of(Tl),
    ?assertEqual(ok, bondy_db:probe_write(IdL)),
    ?assertEqual(ok, bondy_db:probe_write(IdL)),
    close_stop(DbL, IdL).

%% When an instance is stopped, the next tick prunes its histogram so it
%% does not leak across instance churn.
churn_prune() ->
    ok = bondy_oplog_latency:set_enabled(true),
    ok = bondy_oplog_latency:set_probe_enabled(false),
    Db = open_counter_db(lat_churn),
    {ok, T} = bondy_db:open_table(Db, counters, #{}),
    Id = instance_of(T),
    ok = bondy_db:counter_inc(T, <<"r">>, <<"k">>, 1),
    ok = wait_hist(Id, 1, 5000),
    %% Record a snapshot so the histogram is tracked.
    ok = bondy_oplog_latency:snapshot_now(),

    %% Stop the instance (close/1 only drops the table handle); the next
    %% tick reconciles against the registry and deletes the orphaned
    %% histogram.
    close_stop(Db, Id),
    ?assertNot(lists:member(Id, bondy_oplog_registry:list())),
    ok = bondy_oplog_latency:snapshot_now(),
    ?assertEqual(not_found, hist_snapshot(Id)).

%% =============================================================================
%% Helpers
%% =============================================================================

open_counter_db(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => pn_counter,
        oplog_instance_opts => #{origin => Origin}
    }),
    Db.

open_aw_map_db(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        crdt_module => bondy_oplog_crdt_aw_map,
        oplog_instance_opts => #{origin => Origin}
    }),
    {Db, Origin}.

open_lww_db(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        oplog_instance_opts => #{origin => Origin}
    }),
    {Db, Origin}.

instance_of(Table) ->
    #{0 := InstanceId} = maps:get(instance_ids, Table),
    InstanceId.

%% Fully tear down: close the handle AND stop the instance, so it leaves
%% the registry (close/1 alone leaves a registered instance with a dead
%% projection that the idle probe would otherwise hit).
close_stop(Db, Id) ->
    ok = bondy_db:close(Db),
    ok = bondy_oplog:stop_instance(Id).

hist_snapshot(Id) ->
    bondy_metrics:histogram_snapshot(#{
        name => bondy_oplog_latency:metric_name(),
        label => #{instance_id => Id}
    }).

%% Poll the instance's histogram until it has at least MinCount samples.
wait_hist(_Id, _MinCount, Timeout) when Timeout =< 0 ->
    {error, timeout};
wait_hist(Id, MinCount, Timeout) ->
    case hist_snapshot(Id) of
        {ok, #{count := C}} when C >= MinCount ->
            ok;
        _ ->
            timer:sleep(50),
            wait_hist(Id, MinCount, Timeout - 50)
    end.

%% Attach a per-test telemetry handler that forwards events to this process,
%% run Fun, then detach. Unique handler id per call.
with_handler(Fun) ->
    Self = self(),
    Ref = make_ref(),
    HandlerId = {?MODULE, Ref},
    ok = telemetry:attach(
        HandlerId,
        ?EVENT,
        fun(_E, Meas, Meta, #{pid := P}) ->
            P ! {lat_evt, Meas, Meta},
            ok
        end,
        #{pid => Self}
    ),
    try
        Fun()
    after
        telemetry:detach(HandlerId)
    end.

%% Selective receive for the event whose metadata instance_id == Id.
recv_for(Id, Timeout) ->
    receive
        {lat_evt, Meas, #{instance_id := Id} = Meta} -> {Meas, Meta}
    after Timeout -> timeout
    end.
