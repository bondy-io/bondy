%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_dispatch_SUITE).

-moduledoc """
Pure unit tests for `bondy_connect_dispatch` — the callee invocation + subscriber
FIFO + worker lifecycle subsystem extracted from the connection statem (review
A2). No sockets, no live workers: each test drives the module's
`{Dispatch, [Effect]}` API and interprets the effects with a **stub** spawn
result, asserting on the returned effects and (via `inspect/1`) the internal
maps. The `invariant_check/1` helper cross-checks the `mons` reverse-index
against `invocations` + `queues` after every settled step.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

init_per_suite(Config) ->
    %% The dispatch helper builds real WAMP error/yield messages, whose URI
    %% validation reads `bondy_wamp` app config — start the message library
    %% (no router, no sockets, no live workers).
    {ok, _} = application:ensure_all_started(bondy_wamp),
    Config.

end_per_suite(_) ->
    ok.

all() ->
    [
        invocation_admit_spawn_yield,
        invocation_overloaded,
        invocation_worker_start_fail_releases_load,
        invocation_worker_down_errors_and_releases,
        interrupt_kills_and_releases,
        event_unordered_fire_and_forget,
        event_fifo_order,
        event_done_then_stale_down_is_noop,
        event_live_down_spawns_exactly_one,
        clear_subscription_does_not_respawn,
        event_worker_start_fail_advances_fifo,
        kill_all_then_reset
    ].

%% =============================================================================
%% INVOCATION TESTS
%% =============================================================================

%% admit -> spawn -> worker_started(ok) records the monitor + charges load;
%% handler_done yields the worker's reply and releases the load token.
invocation_admit_spawn_yield(_) ->
    D0 = new(),
    {D1, Trace1} = settle(
        bondy_connect_dispatch:admit_invocation(10, inv_job(10), D0)
    ),
    ?assertEqual([{spawned, invocation, 10, inv_job(10)}], Trace1),
    ?assertEqual(1, bondy_connect_dispatch:in_flight(D1)),
    ?assertEqual(1, load_in_flight(D1)),
    invariant_check(D1),

    %% The worker finished: YIELD on the wire, in-flight + load back to zero.
    {D2, Trace2} = settle(
        bondy_connect_dispatch:handler_done(10, {yield, [42], #{}}, D1)
    ),
    ?assertMatch([{send, #yield{request_id = 10}}], Trace2),
    ?assertEqual(0, bondy_connect_dispatch:in_flight(D2)),
    ?assertEqual(0, load_in_flight(D2)),
    invariant_check(D2).

%% When the in-flight cap is hit, a further INVOCATION is answered with
%% ERROR(unavailable) and nothing is spawned or charged.
invocation_overloaded(_) ->
    D0 = new(#{max_concurrency => 1}),
    {D1, _} = settle(
        bondy_connect_dispatch:admit_invocation(1, inv_job(1), D0)
    ),
    ?assertEqual(1, load_in_flight(D1)),

    {D2, Trace} = settle(
        bondy_connect_dispatch:admit_invocation(2, inv_job(2), D1)
    ),
    ?assertMatch([{send, #error{error_uri = ?WAMP_UNAVAILABLE}}], Trace),
    %% No second worker, load unchanged.
    ?assertEqual(1, bondy_connect_dispatch:in_flight(D2)),
    ?assertEqual(1, load_in_flight(D2)),
    invariant_check(D2).

%% Pitfall 1: admit charges the load token; a failed worker spawn must release it
%% (and answer the router) or the in-flight cap leaks a slot forever.
invocation_worker_start_fail_releases_load(_) ->
    D0 = new(),
    {D1, Trace} = settle(
        bondy_connect_dispatch:admit_invocation(7, inv_job(7), D0),
        fail_spawn()
    ),
    ?assertMatch(
        [
            {spawned, invocation, 7, _},
            {send, #error{error_uri = ?BONDY_CONNECT_INTERNAL_ERROR}}
        ],
        Trace
    ),
    ?assertEqual(0, bondy_connect_dispatch:in_flight(D1)),
    ?assertEqual(0, load_in_flight(D1)),
    invariant_check(D1).

%% A monitored invocation worker dying before replying yields a synthetic ERROR
%% and releases the load; a stale second DOWN for the same monitor is a no-op.
invocation_worker_down_errors_and_releases(_) ->
    D0 = new(),
    {D1, _} = settle(
        bondy_connect_dispatch:admit_invocation(5, inv_job(5), D0)
    ),
    Mon = invocation_mon(5, D1),

    {D2, Trace} = settle(bondy_connect_dispatch:worker_down(Mon, killed, D1)),
    ?assertMatch(
        [{send, #error{error_uri = ?BONDY_CONNECT_INTERNAL_ERROR}}], Trace
    ),
    ?assertEqual(0, bondy_connect_dispatch:in_flight(D2)),
    ?assertEqual(0, load_in_flight(D2)),
    invariant_check(D2),

    {D3, Trace2} = settle(bondy_connect_dispatch:worker_down(Mon, killed, D2)),
    ?assertEqual([], Trace2),
    invariant_check(D3).

%% INTERRUPT kills the servicing worker (kill effect), answers the INTERRUPT with
%% ERROR(canceled) and releases the load; an unknown invocation is a no-op.
interrupt_kills_and_releases(_) ->
    D0 = new(),
    {D1, _} = settle(
        bondy_connect_dispatch:admit_invocation(9, inv_job(9), D0)
    ),

    {D2, Trace} = settle(bondy_connect_dispatch:interrupt(9, #{}, D1)),
    ?assertMatch(
        [{kill, _Pid}, {send, #error{error_uri = ?WAMP_CANCELLED}}],
        Trace
    ),
    ?assertEqual(0, bondy_connect_dispatch:in_flight(D2)),
    ?assertEqual(0, load_in_flight(D2)),
    invariant_check(D2),

    {_D3, Trace2} = settle(bondy_connect_dispatch:interrupt(404, #{}, D2)),
    ?assertEqual([], Trace2).

%% =============================================================================
%% SUBSCRIBER (EVENT) TESTS
%% =============================================================================

%% Unordered events fire-and-forget: no queue entry, no monitor, no load.
event_unordered_fire_and_forget(_) ->
    D0 = new(),
    {D1, Effects} = bondy_connect_dispatch:dispatch_event(
        1, false, ev_job(1), D0
    ),
    ?assertEqual([{spawn_nomon, ev_job(1)}], Effects),
    #{queues := Q} = bondy_connect_dispatch:inspect(D1),
    ?assertEqual(0, maps:size(Q)),
    ?assertEqual(0, load_in_flight(D1)),
    invariant_check(D1).

%% Invariant 1: per-subscription FIFO. Three events on one sub run strictly in
%% order; queuing while busy, draining on event_done, going idle when empty.
event_fifo_order(_) ->
    Sub = 100,
    D0 = new(),

    %% E1 starts immediately; E2/E3 queue behind it.
    {D1, T1} = settle(dispatch_ev(Sub, 1, D0)),
    ?assertEqual([{spawned, event, Sub, ev_job(1)}], T1),
    invariant_check(D1),
    {D2, T2} = settle(dispatch_ev(Sub, 2, D1)),
    ?assertEqual([], T2),
    {D3, T3} = settle(dispatch_ev(Sub, 3, D2)),
    ?assertEqual([], T3),
    invariant_check(D3),

    %% Drain in order: each event_done starts exactly the next queued event.
    {D4, T4} = settle(bondy_connect_dispatch:event_done(Sub, D3)),
    ?assertEqual([{spawned, event, Sub, ev_job(2)}], T4),
    invariant_check(D4),
    {D5, T5} = settle(bondy_connect_dispatch:event_done(Sub, D4)),
    ?assertEqual([{spawned, event, Sub, ev_job(3)}], T5),
    invariant_check(D5),

    %% Queue empty -> the subscription goes idle (its entry is removed).
    {D6, T6} = settle(bondy_connect_dispatch:event_done(Sub, D5)),
    ?assertEqual([], T6),
    #{queues := Q} = bondy_connect_dispatch:inspect(D6),
    ?assertEqual(0, maps:size(Q)),
    invariant_check(D6).

%% Pitfall 2: a clean event_done demonitors-with-flush; a later (stale) DOWN for
%% that same monitor must be a no-op (must NOT double-spawn the next event).
event_done_then_stale_down_is_noop(_) ->
    Sub = 200,
    D0 = new(),
    {D1, _} = settle(dispatch_ev(Sub, 1, D0)),
    {D2, _} = settle(dispatch_ev(Sub, 2, D1)),
    Mon1 = event_mon(Sub, D2),

    %% Clean completion drains to E2 (one spawn), and Mon1 is gone from mons.
    {D3, T3} = settle(bondy_connect_dispatch:event_done(Sub, D2)),
    ?assertEqual([{spawned, event, Sub, ev_job(2)}], T3),
    invariant_check(D3),

    %% The stale DOWN for the already-completed worker does nothing.
    {D4, T4} = settle(bondy_connect_dispatch:worker_down(Mon1, normal, D3)),
    ?assertEqual([], T4),
    %% E2 is still the busy worker — untouched.
    ?assertEqual(event_mon(Sub, D3), event_mon(Sub, D4)),
    invariant_check(D4).

%% Pitfall 2: a DOWN for the *live* busy worker advances the FIFO by exactly one
%% spawn (the DOWN consumed the monitor, so this path never demonitors).
event_live_down_spawns_exactly_one(_) ->
    Sub = 300,
    D0 = new(),
    {D1, _} = settle(dispatch_ev(Sub, 1, D0)),
    {D2, _} = settle(dispatch_ev(Sub, 2, D1)),
    LiveMon = event_mon(Sub, D2),

    {D3, T3} = settle(bondy_connect_dispatch:worker_down(LiveMon, crash, D2)),
    ?assertEqual([{spawned, event, Sub, ev_job(2)}], T3),
    invariant_check(D3).

%% Pitfall 3: unsubscribe clears the sub — queue and monitor dropped, NO respawn,
%% and a later DOWN for the cleared monitor is a no-op.
clear_subscription_does_not_respawn(_) ->
    Sub = 400,
    D0 = new(),
    {D1, _} = settle(dispatch_ev(Sub, 1, D0)),
    {D2, _} = settle(dispatch_ev(Sub, 2, D1)),
    Mon = event_mon(Sub, D2),

    {D3, T3} = bondy_connect_dispatch:clear_subscription(Sub, D2),
    ?assertEqual([], T3),
    #{queues := Q, mons := Mons} = bondy_connect_dispatch:inspect(D3),
    ?assertEqual(0, maps:size(Q)),
    ?assertEqual(0, maps:size(Mons)),
    invariant_check(D3),

    %% A late DOWN for the cleared worker must not resurrect the subscription.
    {D4, T4} = settle(bondy_connect_dispatch:worker_down(Mon, normal, D3)),
    ?assertEqual([], T4),
    #{queues := Q2} = bondy_connect_dispatch:inspect(D4),
    ?assertEqual(0, maps:size(Q2)).

%% A queued event whose worker fails to start is dropped and the FIFO still
%% drains the rest (a stuck busy flag would wedge the subscription).
event_worker_start_fail_advances_fifo(_) ->
    Sub = 500,
    D0 = new(),
    {D1, _} = settle(dispatch_ev(Sub, 1, D0)),
    {D2, _} = settle(dispatch_ev(Sub, 2, D1)),

    %% E1 done -> try E2, but E2's spawn fails -> drop E2; queue now empty so the
    %% sub goes idle. The whole drain happens in one settled step.
    {D3, T3} = settle(
        bondy_connect_dispatch:event_done(Sub, D2),
        fail_spawn()
    ),
    ?assertEqual([{spawned, event, Sub, ev_job(2)}], T3),
    #{queues := Q} = bondy_connect_dispatch:inspect(D3),
    ?assertEqual(0, maps:size(Q)),
    invariant_check(D3).

%% Teardown: kill_all emits a {kill, Pid} per in-flight invocation (and
%% demonitors event workers); reset then clears every map and zeroes the load.
kill_all_then_reset(_) ->
    D0 = new(),
    {D1, _} = settle(
        bondy_connect_dispatch:admit_invocation(1, inv_job(1), D0)
    ),
    {D2, _} = settle(
        bondy_connect_dispatch:admit_invocation(2, inv_job(2), D1)
    ),
    {D3, _} = settle(dispatch_ev(900, 1, D2)),

    {D4, Kills} = bondy_connect_dispatch:kill_all(D3),
    %% One kill per invocation worker (order-independent), none for the event.
    ?assertEqual(2, length([P || {kill, P} <- Kills])),
    ?assertEqual(2, length(Kills)),

    D5 = bondy_connect_dispatch:reset(D4),
    #{invocations := Inv, mons := Mons, queues := Q} =
        bondy_connect_dispatch:inspect(D5),
    ?assertEqual(0, maps:size(Inv)),
    ?assertEqual(0, maps:size(Mons)),
    ?assertEqual(0, maps:size(Q)),
    ?assertEqual(0, load_in_flight(D5)),
    invariant_check(D5).

%% =============================================================================
%% HELPERS
%% =============================================================================

new() ->
    new(#{}).

new(LoadOpts) ->
    bondy_connect_dispatch:new(bondy_connect_load:new(LoadOpts)).

inv_job(N) ->
    #{kind => invocation, req_id => N, handler => fun() -> ok end}.

ev_job(N) ->
    #{kind => event, n => N}.

dispatch_ev(Sub, N, D) ->
    bondy_connect_dispatch:dispatch_event(Sub, true, ev_job(N), D).

load_in_flight(D) ->
    maps:get(load_in_flight, bondy_connect_dispatch:inspect(D)).

%% @private The live monitor of in-flight invocation `ReqId`.
invocation_mon(ReqId, D) ->
    #{invocations := Inv} = bondy_connect_dispatch:inspect(D),
    {_Pid, Mon} = maps:get(ReqId, Inv),
    Mon.

%% @private The live monitor of busy subscription `SubId`.
event_mon(SubId, D) ->
    #{queues := Q} = bondy_connect_dispatch:inspect(D),
    maps:get(mon, maps:get(SubId, Q)).

%% @private Interpret a `{Dispatch, [Effect]}` step, spawning successfully.
settle(Step) ->
    settle(Step, ok_spawn()).

%% @private Interpret a `{Dispatch, [Effect]}` step. `SpawnFun(Tag, Key, Job)`
%% returns the stub spawn result. The returned `Trace` is the flat, ordered list
%% of observable effects with each `{spawn, Tag, Key, Job}` rendered as a
%% `{spawned, Tag, Key, Job}` marker — i.e. exactly what the connection's
%% effect interpreter would do, recording what was actually spawned so FIFO order
%% is assertable. The spawn-feedback trampoline (a failed/finished event spawn
%% emitting the next one) is followed to exhaustion, just like the statem.
settle({D, Effects}, SpawnFun) ->
    lists:foldl(
        fun(Eff, {DAcc, Trace}) -> apply_eff(Eff, SpawnFun, DAcc, Trace) end,
        {D, []},
        Effects
    ).

apply_eff({spawn, Tag, Key, Job}, SpawnFun, D0, Trace) ->
    Res = SpawnFun(Tag, Key, Job),
    {D1, Effects} = bondy_connect_dispatch:worker_started(Tag, Key, Res, D0),
    lists:foldl(
        fun(Eff, {DAcc, T}) -> apply_eff(Eff, SpawnFun, DAcc, T) end,
        {D1, Trace ++ [{spawned, Tag, Key, Job}]},
        Effects
    );
apply_eff(Other, _SpawnFun, D, Trace) ->
    {D, Trace ++ [Other]}.

%% @private Every spawn succeeds with a fresh fake worker (the pid is never used
%% by the module; the monitor reference is what matters).
ok_spawn() ->
    fun(_Tag, _Key, _Job) -> {ok, {self(), make_ref()}} end.

%% @private Every spawn fails (drives the start-failure paths).
fail_spawn() ->
    fun(_Tag, _Key, _Job) -> {error, max_children} end.

%% @private The mons reverse-index must be in exact lockstep with invocations and
%% the (real-ref) busy subscription monitors.
invariant_check(D) ->
    #{invocations := Inv, mons := Mons, queues := Q} =
        bondy_connect_dispatch:inspect(D),
    %% Forward: every invocation/busy-sub monitor is indexed.
    maps:foreach(
        fun(ReqId, {_Pid, Mon}) ->
            ?assertEqual({invocation, ReqId}, maps:get(Mon, Mons, missing))
        end,
        Inv
    ),
    maps:foreach(
        fun(SubId, #{mon := Mon}) ->
            case is_reference(Mon) of
                true ->
                    ?assertEqual({event, SubId}, maps:get(Mon, Mons, missing));
                false ->
                    ok
            end
        end,
        Q
    ),
    %% Reverse: every mons entry points at a live invocation / busy sub.
    maps:foreach(
        fun
            (Mon, {invocation, ReqId}) ->
                ?assertMatch({_, Mon}, maps:get(ReqId, Inv, missing));
            (Mon, {event, SubId}) ->
                ?assertEqual(
                    Mon, maps:get(mon, maps:get(SubId, Q, #{}), missing)
                )
        end,
        Mons
    ).
