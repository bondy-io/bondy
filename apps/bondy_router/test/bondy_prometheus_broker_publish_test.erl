%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% EUnit coverage for the broker-publish stage split in `bondy_prometheus`
%% (`handle_net_event/4`), the sink for `[bondy, broker, publish]` emitted by
%% `bondy_broker:do_publish/2`.
%%
%% Why the split exists: a slow PUBLISH is otherwise unattributable. A wide
%% fanout and an expensive subscription match look identical from outside, and
%% both look identical to a downstream relay-ingress backlog. `match` and
%% `fanout` separate the first two; a tail visible in NEITHER is downstream
%% (`bondy_router_flow_queue_microseconds`, or the subscriber's own connection
%% process).
-module(bondy_prometheus_broker_publish_test).

-include_lib("eunit/include/eunit.hrl").

broker_publish_metrics_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"match and fanout histograms both move", fun both_stages/0},
        {"the two stages are recorded independently", fun independent/0},
        {"malformed measurement does not raise", fun malformed/0},
        {"relay ingress records mailbox depth", fun ingress_depth/0},
        {"a flow event without depth records none", fun no_depth/0}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_metrics),
    _ =
        case bondy_metrics:start_link() of
            {ok, _} -> ok;
            {error, {already_started, _}} -> ok
        end,
    %% The sink labels rows with `bondy_config:node()`; seed it so a bare eunit
    %% run (no partisan app) resolves the name the assertions read back.
    _ =
        try
            partisan_config:set(name, node())
        catch
            _:_ -> ok
        end,
    ok.

cleanup(_) ->
    ok.

both_stages() ->
    M0 = count(bondy_broker_publish_match_microseconds),
    F0 = count(bondy_broker_publish_fanout_microseconds),
    ok = emit(#{match => 120, fanout => 4500}),
    ?assertEqual(M0 + 1, count(bondy_broker_publish_match_microseconds)),
    ?assertEqual(F0 + 1, count(bondy_broker_publish_fanout_microseconds)).

%% A publish that matches instantly but fans out slowly (the wide-fanout case)
%% must not smear its cost across both histograms — that is the whole point of
%% splitting them.
independent() ->
    M0 = count(bondy_broker_publish_match_microseconds),
    F0 = count(bondy_broker_publish_fanout_microseconds),
    ok = emit(#{match => 0, fanout => 900_000}),
    ?assertEqual(M0 + 1, count(bondy_broker_publish_match_microseconds)),
    ?assertEqual(F0 + 1, count(bondy_broker_publish_fanout_microseconds)).

%% The sink must stay total: a raising telemetry handler is DETACHED by
%% telemetry, which would silently kill every metric sharing the handler id.
malformed() ->
    ?assertEqual(ok, emit(#{})),
    ?assertEqual(ok, emit(not_a_map)).

%% Relay-ingress tasks arrive from a peer with no local dispatch timestamp, so
%% `bondy_router_flow_queue_microseconds` records nothing for them — the flow
%% pool's ONLY data-plane role was unobservable. Depth is the substitute.
ingress_depth() ->
    D0 = count(bondy_router_flow_queue_depth),
    ok = flow(#{service => 90, depth => 7}, relay),
    ?assertEqual(D0 + 1, count(bondy_router_flow_queue_depth)).

%% The locally-dispatched path measures a real wait and must NOT be given a
%% fabricated depth — a zero there would read as "never any backlog".
no_depth() ->
    D0 = count(bondy_router_flow_queue_depth),
    ok = flow(#{queue => 10, service => 90}, router),
    ?assertEqual(D0, count(bondy_router_flow_queue_depth)).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
flow(Meas, Family) ->
    bondy_prometheus:handle_net_event(
        [bondy, router, flow], Meas, #{family => Family}, undefined
    ).

%% @private
emit(Meas) ->
    bondy_prometheus:handle_net_event(
        [bondy, broker, publish], Meas, #{}, undefined
    ).

%% @private
%% `bondy_metrics:with_name/1` returns the histogram's observation COUNT.
count(Name) ->
    try
        lists:sum([V || {_, V} <- bondy_metrics:with_name(Name)])
    catch
        _:_ -> 0
    end.

%% =============================================================================
%% EGRESS — the last hop before the wire
%% =============================================================================
%% `match`/`fanout` cover the publisher's connection process and
%% `router_flow_ingress/3` covers relay ingress; egress is the subscriber's own
%% connection process, and it was the only unmeasured segment of the delivery
%% path. Fly runs S28-S30 showed a delivery tail that appeared in NONE of the
%% router stages (all sub-400us at p99) and no relay-ingress backlog (mean
%% mailbox depth 0.046), which is what motivated measuring here.

egress_metrics_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"service and depth histograms both move", fun egress_both/0},
        {"a zero depth IS an observation", fun egress_zero_depth/0},
        {"malformed measurement does not raise", fun egress_malformed/0}
    ]}.

egress_both() ->
    S0 = count(bondy_wamp_egress_service_microseconds),
    D0 = count(bondy_wamp_egress_queue_depth),
    ok = egress(#{service => 45, depth => 3}),
    ?assertEqual(S0 + 1, count(bondy_wamp_egress_service_microseconds)),
    ?assertEqual(D0 + 1, count(bondy_wamp_egress_queue_depth)).

%% Unlike the flow-pool queue measurement — where ABSENT must not be recorded
%% as zero, because a fabricated zero reads as "never any backlog" — an egress
%% depth of 0 is a real reading: the mailbox was empty at dequeue. Dropping it
%% would bias the distribution toward whatever backlog existed.
egress_zero_depth() ->
    D0 = count(bondy_wamp_egress_queue_depth),
    ok = egress(#{service => 12, depth => 0}),
    ?assertEqual(D0 + 1, count(bondy_wamp_egress_queue_depth)).

egress_malformed() ->
    ?assertEqual(ok, egress(#{})),
    ?assertEqual(ok, egress(not_a_map)).

%% NOTE: these call `handle_net_event/4` directly, which proves the SINK and
%% proves NOTHING about whether the event reaches it — a missing entry in
%% `bondy_prometheus:setup/0`'s attach_many list would leave them all green
%% while the metric stayed dead in production. Attachment cannot be asserted
%% here (setup/0 returns {error, badarg} without a booted node, attaching
%% nothing at all — `[bondy, router, flow]` is equally unattached in eunit).
%% `bondy_prometheus_SUITE:egress_metrics_via_telemetry/1` covers it on a
%% booted node instead.

%% @private
egress(Meas) ->
    bondy_prometheus:handle_net_event(
        [bondy, wamp, egress], Meas, #{transport => websocket}, undefined
    ).
