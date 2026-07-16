%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% The periodic heap monitor in `bondy_oplog_instance`: a long-lived instance
%% accumulates transient apply/AAE garbage the BEAM does not return until a
%% fullsweep. Under a solo import (no peers) the AAE-driven hibernate never
%% fires, so the heap climbs unbounded. A `gc_tick` fullsweep-hibernates the
%% instance once its heap grows past `instance_gc_heap_delta_bytes` over its
%% post-GC baseline — capping the transient peak without touching the hot
%% append/drain path, and keying on *growth* so a large live MST is never
%% GC-thrashed.
%%
%% Validates:
%%   - `gc_decision/3` (the pure growth/baseline logic): grow→hibernate,
%%     shrink→rebaseline, small-growth→keep, and that slow steady growth
%%     trips eventually against a stable baseline.
%%   - Integration: an instance running an aggressive monitor (hibernating on
%%     nearly every tick) stays fully functional — state survives the
%%     fullsweep + sleep/wake, and new writes after the hibernations still
%%     land. (The reclaim *magnitude* is backend-sensitive — only durable
%%     instances hold the MST off-heap, so their process heap is transient —
%%     and is validated on the dev cluster, not asserted on a byte count here.)
%% =============================================================================
-module(bondy_oplog_instance_heap_monitor_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Pure decision logic
%% =============================================================================

gc_decision_test() ->
    Delta = 1000,
    %% Grew past the delta → reclaim, provisional baseline at the pre-GC size.
    ?assertEqual(
        {hibernate, 5000},
        bondy_oplog_heap_monitor:gc_decision(5000, 3500, Delta)
    ),
    %% Exactly at the delta → reclaim.
    ?assertEqual(
        {hibernate, 4500},
        bondy_oplog_heap_monitor:gc_decision(4500, 3500, Delta)
    ),
    %% Shrank below the baseline (post-hibernate) → adopt the lower live size.
    ?assertEqual(
        {rebaseline, 2500},
        bondy_oplog_heap_monitor:gc_decision(2500, 3500, Delta)
    ),
    %% Grew, but under the delta → keep accumulating against the same baseline.
    ?assertEqual(keep, bondy_oplog_heap_monitor:gc_decision(4000, 3500, Delta)),
    %% From a zero baseline, the first non-trivial heap trips once, then the
    %% next tick (lower post-GC heap) rebaselines and settles.
    ?assertEqual(
        {hibernate, 1200}, bondy_oplog_heap_monitor:gc_decision(1200, 0, Delta)
    ),
    ok.

%% Slow steady growth still trips: each tick grows < Delta, but accumulated
%% growth over a stable baseline crosses Delta and fires.
slow_growth_trips_test() ->
    Delta = 1000,
    Base = 2000,
    %% Three ticks at +400 each: 2400, 2800 → keep; 3200 → grown 1200 ≥ Δ.
    ?assertEqual(keep, bondy_oplog_heap_monitor:gc_decision(2400, Base, Delta)),
    ?assertEqual(keep, bondy_oplog_heap_monitor:gc_decision(2800, Base, Delta)),
    ?assertEqual(
        {hibernate, 3200},
        bondy_oplog_heap_monitor:gc_decision(3200, Base, Delta)
    ),
    ok.

%% =============================================================================
%% Integration
%% =============================================================================

monitor_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun functional_across_hibernations/0}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    {
        application:get_env(bondy_oplog, instance_gc_interval_ms),
        application:get_env(bondy_oplog, instance_gc_heap_delta_bytes)
    }.

cleanup({PrevInt, PrevDelta}) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    restore(instance_gc_interval_ms, PrevInt),
    restore(instance_gc_heap_delta_bytes, PrevDelta),
    ok.

restore(K, undefined) -> application:unset_env(bondy_oplog, K);
restore(K, {ok, V}) -> application:set_env(bondy_oplog, K, V).

functional_across_hibernations() ->
    %% Tiny delta + fast tick → the monitor hibernates the instance on nearly
    %% every tick. The instance must remain fully functional: its state must
    %% survive the fullsweep + sleep/wake, and new writes after the
    %% hibernations must still land and move the MST root.
    application:set_env(bondy_oplog, instance_gc_interval_ms, 30),
    application:set_env(bondy_oplog, instance_gc_heap_delta_bytes, 1024),

    Id = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(Id, originated_opts()),
    Pid = bondy_oplog_registry:instance_pid(Id),

    [bondy_oplog:append(Id, {before, N}) || N <- lists:seq(1, 50)],
    timer:sleep(200),
    %% Responds to a call across many hibernations, with state intact.
    Root1 = bondy_oplog:root_hash(Id),
    ?assert(is_binary(Root1)),
    ?assert(is_process_alive(Pid)),

    %% New writes after the hibernations still land → root moves.
    [bondy_oplog:append(Id, {'after', N}) || N <- lists:seq(1, 50)],
    timer:sleep(150),
    Root2 = bondy_oplog:root_hash(Id),
    ?assert(is_binary(Root2)),
    ?assertNotEqual(Root1, Root2),
    ?assert(is_process_alive(Pid)),
    bondy_oplog:stop_instance(Id).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_inst() ->
    list_to_binary(
        "heapmon_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

originated_opts() ->
    #{origin => bondy_oplog_origin:new()}.
