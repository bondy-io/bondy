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
    _ = catch partisan_config:set(name, node()),
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
