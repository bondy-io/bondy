%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_prometheus_SUITE).
-moduledoc """
End-to-end check of the Prometheus exposition on a booted node: the
event-driven families (bondy_prometheus), the storage-stack bridge
(bondy_prometheus_db) and the router collector (bondy_prometheus_collector)
must all render on a real scrape without error.
""".

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).

-export([exposition_renders_all_family_groups/1]).
-export([router_events_feed_metrics/1]).
-export([wamp_message_metrics_via_telemetry/1]).
-export([net_session_metrics_via_telemetry/1]).
-export([inflight_by_procedure/1]).
-export([egress_metrics_via_telemetry/1]).

all() ->
    [
        exposition_renders_all_family_groups,
        router_events_feed_metrics,
        wamp_message_metrics_via_telemetry,
        net_session_metrics_via_telemetry,
        inflight_by_procedure,
        egress_metrics_via_telemetry
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

exposition_renders_all_family_groups(_) ->
    Output = prometheus_text_format:format(),
    true = is_binary(Output) andalso byte_size(Output) > 0,

    %% No series (name + labelset) may appear twice: duplicates make
    %% PromQL selectors fail with "vector cannot contain metrics with the
    %% same labelset". The `bondy_metrics` passthrough must render each
    %% declared family once.
    Samples = [
        L
     || L <- binary:split(Output, <<"\n">>, [global]),
        L =/= <<>>,
        binary:first(L) =/= $#
    ],
    Series = [hd(binary:split(L, <<" ">>)) || L <- Samples],
    Duplicates = lists:usort(Series -- lists:usort(Series)),
    Duplicates == [] orelse ct:fail({duplicate_series, Duplicates}),

    %% One representative family per collector/source. Families whose
    %% sources return no rows on a solo test node (e.g. per-peer
    %% connections) are deliberately not asserted.
    Expected = [
        %% bondy_prometheus (event-driven, declared at setup). The
        %% bondy_metrics-backed families (sessions, sockets, per-message)
        %% render only once touched and are asserted by the dedicated
        %% telemetry test cases below.
        <<"bondy_wamp_dropped_total">>,
        <<"bondy_http_requests_total">>,
        %% bondy_prometheus_db: declared counter families
        <<"bondy_oplog_wal_appends_total">>,
        <<"bondy_aae_merge_conflicts_total">>,
        %% bondy_prometheus_db: scrape-time collector families
        <<"bondy_cluster_members">>,
        <<"bondy_oplog_aae_enabled">>,
        <<"bondy_node_ready">>,
        %% bondy_prometheus_collector (router runtime state)
        <<"bondy_registry_size">>,
        <<"bondy_rpc_promises_inflight">>,
        <<"bondy_listener_connections">>,
        <<"bondy_jobs_queue_depth">>,
        %% Tier-3 source instrumentation (declared at setup)
        %% bondy_wamp_call_latency_milliseconds renders only once touched
        %% (bondy_metrics family); asserted by router_events_feed_metrics.
        <<"bondy_rate_limited_total">>,
        <<"bondy_rpc_promise_timeouts_total">>,
        %% bondy_registry_events_total renders only once touched (bondy_metrics
        %% family); asserted by bondy_meta_events_SUITE.
        %% VM collectors incl. the msacc one registered at setup
        <<"erlang_vm_memory_bytes">>,
        <<"erlang_vm_msacc_emulator_seconds_total">>
    ],
    Missing = [N || N <- Expected, binary:match(Output, N) == nomatch],
    Missing == [] orelse ct:fail({missing_metric_families, Missing}),
    ok.

router_events_feed_metrics(_) ->
    %% RPC latency and ping RTT ride telemetry into wait-free
    %% bondy_metrics sinks (visible immediately, no polling). The node is
    %% shared across the CT run, so all assertions are DELTA-based.
    %% NOTE: the registration/subscription lifecycle counters are covered
    %% end-to-end by bondy_meta_events_SUITE.
    Proc = <<"com.test.latency">>,
    Node = bondy_config:node(),
    RpcLabels = #{node => Node, procedure_uri => Proc},

    {CallCount0, CallSum0} = histogram_value(
        bondy_wamp_call_latency_milliseconds, RpcLabels
    ),
    {InvCount0, InvSum0} = histogram_value(
        bondy_wamp_invocation_latency_milliseconds, RpcLabels
    ),
    ok = bondy_telemetry:rpc_latency(call, Proc, 42, #{}),
    ok = bondy_telemetry:rpc_latency(invocation, Proc, 30, #{}),

    {CallCount1, CallSum1} = histogram_value(
        bondy_wamp_call_latency_milliseconds, RpcLabels
    ),
    {InvCount1, InvSum1} = histogram_value(
        bondy_wamp_invocation_latency_milliseconds, RpcLabels
    ),
    true = CallCount1 - CallCount0 == 1 andalso CallSum1 - CallSum0 == 42,
    true = InvCount1 - InvCount0 == 1 andalso InvSum1 - InvSum0 == 30,

    PingLabels = #{node => Node, protocol => wamp, transport => ws},
    {Rtt0, RttSum0} = histogram_value(
        bondy_ping_rtt_milliseconds, PingLabels
    ),
    ok = bondy_telemetry:ping_rtt(wamp, ws, 7),
    {Rtt1, RttSum1} = histogram_value(
        bondy_ping_rtt_milliseconds, PingLabels
    ),
    true = Rtt1 - Rtt0 == 1 andalso RttSum1 - RttSum0 == 7,
    ok.

inflight_by_procedure(_) ->
    %% The per-procedure inflight gauge is computed from the live promise
    %% store at scrape time (drift-free), not from hot-path inc/dec.
    Realm = <<"com.leapsight.bondy">>,
    Proc = <<"com.test.inflight.proc">>,
    Caller = bondy_ref:new(internal, self(), bondy_session_id:new()),
    Callee = bondy_ref:new(internal, self(), bondy_session_id:new()),
    Promise = bondy_rpc_promise:new_invocation(
        Realm, Caller, 1, Callee, 1, #{
            procedure_uri => Proc, timeout => 60000
        }
    ),
    ok = bondy_rpc_promise:add(Promise),

    #{Proc := 1} = bondy_rpc_promise:count_by_procedure(),
    Output = prometheus_text_format:format(),
    {_, _} = binary:match(Output, <<"bondy_rpc_inflight_invocations">>),
    {_, _} = binary:match(Output, Proc),

    Key = bondy_rpc_promise:invocation_key_pattern(
        Realm, Caller, 1, Callee, 1
    ),
    {ok, _} = bondy_rpc_promise:take(Key),
    false = maps:is_key(Proc, bondy_rpc_promise:count_by_procedure()),
    ok.

%% @private
%% {ObservationCount, Sum} of a bondy_metrics histogram, zeros when the
%% (name, label) pair has not been touched yet.
histogram_value(Name, Label) ->
    case bondy_metrics:histogram_snapshot(#{name => Name, label => Label}) of
        {ok, #{count := Count, sum := Sum}} -> {Count, Sum};
        not_found -> {0, 0}
    end.

wamp_message_metrics_via_telemetry(_) ->
    Proc = <<"com.test.metrics.telemetry.proc">>,
    M = bondy_wamp_message:call(1, #{}, Proc, [], #{}),
    Ctxt = bondy_context:local_context(<<"com.leapsight.bondy">>),

    %% Wire size is caller-provided (from the encode/decode site); the
    %% sized form is the one that feeds the bytes histogram.
    ok = bondy_telemetry:wamp_message(M, 128, Ctxt),

    %% The sink is inline and wait-free, so the counters are visible
    %% immediately — no polling needed.
    Rows = bondy_metrics:family(bondy_wamp_call_messages_total),
    Matching = [
        R
     || #{label := #{procedure_uri := P}} = R <- Rows, P == Proc
    ],
    [#{type := counter, value := 1}] = Matching,

    [_ | _] = bondy_metrics:family(bondy_wamp_messages_total),
    [#{type := histogram, value := #{count := Count}} | _] =
        bondy_metrics:family(bondy_wamp_message_bytes),
    true = Count >= 1,

    %% And the whole family renders on a real scrape.
    Output = prometheus_text_format:format(),
    {_, _} = binary:match(Output, <<"bondy_wamp_call_messages_total">>),
    {_, _} = binary:match(Output, <<"bondy_wamp_messages_total">>),
    {_, _} = binary:match(Output, <<"bondy_wamp_message_bytes">>),
    {_, _} = binary:match(Output, Proc),
    ok.

net_session_metrics_via_telemetry(_) ->
    Node = bondy_config:node(),
    SocketLabels = #{node => Node, protocol => wamp, transport => raw},

    Opened0 = gauge_value(bondy_sockets_total, SocketLabels),
    ok = bondy_telemetry:socket_open(wamp, raw),
    Opened1 = gauge_value(bondy_sockets_total, SocketLabels),
    1 = Opened1 - Opened0,

    ok = bondy_telemetry:socket_closed(wamp, raw, 7),
    Opened0 = gauge_value(bondy_sockets_total, SocketLabels),
    %% Other suites in a full run legitimately produce rows for other
    %% transports (e.g. ws), so select the raw row rather than asserting
    %% a singleton family.
    [#{type := histogram, value := #{count := C1, sum := Sum1}}] = [
        R
     || #{label := #{transport := raw}} = R <-
            bondy_metrics:family(bondy_socket_duration_seconds)
    ],
    true = C1 >= 1 andalso Sum1 >= 7,

    %% Error-class terminations always pair with a closed emission, so
    %% the error sink must NOT decrement the gauge (it would drift
    %% negative by one per errored socket).
    ok = bondy_telemetry:socket_error(wamp, raw),
    [_ | _] = bondy_metrics:family(bondy_socket_errors_total),
    Opened0 = gauge_value(bondy_sockets_total, SocketLabels),

    %% Session events through the real emitter, with a real session term.
    Realm = <<"com.leapsight.bondy">>,
    Session = bondy_session:new(Realm, #{
        peer => {{127, 0, 0, 1}, 10001},
        is_anonymous => true,
        security_enabled => true,
        roles => #{caller => #{}}
    }),
    SessionLabels = #{realm => Realm, node => Node},

    SOpen0 = gauge_value(bondy_sessions_total, SessionLabels),
    ok = bondy_telemetry:session_opened(Session),
    SOpen1 = gauge_value(bondy_sessions_total, SessionLabels),
    1 = SOpen1 - SOpen0,

    ok = bondy_telemetry:session_closed(Session, 5, <<"wamp.close.logout">>),
    SOpen0 = gauge_value(bondy_sessions_total, SessionLabels),
    Closed = bondy_metrics:family(bondy_sessions_closed_total),
    [_ | _] = [
        R
     || #{label := #{reason := <<"wamp.close.logout">>}} = R <- Closed
    ],

    %% And the families render on a real scrape.
    Output = prometheus_text_format:format(),
    {_, _} = binary:match(Output, <<"bondy_sockets_total">>),
    {_, _} = binary:match(Output, <<"bondy_sessions_closed_total">>),
    {_, _} = binary:match(Output, <<"wamp.close.logout">>),
    ok.

%% @private
gauge_value(Name, Labels) ->
    case bondy_metrics:value(#{name => Name, label => Labels}) of
        undefined -> 0;
        V -> V
    end.

egress_metrics_via_telemetry(_) ->
    %% Egress is the LAST hop before the wire — the subscriber's own connection
    %% process. It was the only unmeasured segment of the delivery path, and
    %% Fly runs S28-S30 are why it is measured: the delivery tail appeared in
    %% none of the router stages and relay ingress showed no backlog.
    %%
    %% This drives the REAL path (emitter -> telemetry -> sink -> scrape) on a
    %% booted node. The eunit sink tests call handle_net_event/4 directly, so
    %% they would stay green if the event were missing from setup/0's
    %% attach_many list; only this test would catch that.
    ok = bondy_telemetry:wamp_egress(websocket, 250, 4),

    [#{type := histogram, value := #{count := SCount}} | _] =
        bondy_metrics:family(bondy_wamp_egress_service_microseconds),
    true = SCount >= 1,

    [#{type := histogram, value := #{count := DCount}} | _] =
        bondy_metrics:family(bondy_wamp_egress_queue_depth),
    true = DCount >= 1,

    Output = prometheus_text_format:format(),
    {_, _} = binary:match(Output, <<"bondy_wamp_egress_service_microseconds">>),
    {_, _} = binary:match(Output, <<"bondy_wamp_egress_queue_depth">>),
    ok.
