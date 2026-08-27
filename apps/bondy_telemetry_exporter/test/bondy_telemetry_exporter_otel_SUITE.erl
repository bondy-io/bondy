%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_telemetry_exporter_otel_SUITE).

-moduledoc """
Falsifiers for the telemetry-event → OpenTelemetry-span bridge.

The OpenTelemetry SDK is configured with `otel_simple_processor` +
`otel_exporter_pid`, whose export is a synchronous `gen_statem:call`
from the emitting process — so by the time an emitter returns, the
exported span (or nothing) is already in this suite's collector, and
every assertion is deterministic with no timing games.

Events are emitted through the REAL producer modules
(`bondy_telemetry`, `bondy_connect_telemetry`, `bondy_mcp_metrics` —
pure `telemetry:execute` wrappers, no node needed), so the bridge's
subscribed event names cannot silently drift from the producers'.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

-compile([nowarn_export_all, export_all]).

-define(TP, <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>).
-define(TP_UNSAMPLED,
    <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00">>
).
-define(TS, <<"congo=t61rcWkgMzE">>).
-define(TRACE_ID, 16#0af7651916cd43dd8448eb211c80319c).
-define(PARENT_SPAN_ID, 16#b7ad6b7169203331).

all() ->
    [
        router_call_span,
        rpc_kind_mapping,
        rpc_error_status,
        untraced_and_malformed_no_span,
        unsampled_parent_no_span,
        minted_root_span,
        mcp_spans,
        disabled_gate_and_detach
    ].

init_per_suite(Config) ->
    Collector = spawn(fun collector_loop/0),
    true = register(span_collector, Collector),
    MetricsStarted = ensure_metrics_registry(),
    %% A suite that ran earlier on this node may have booted Bondy, and
    %% bondy_app starts bondy_telemetry_exporter with the production
    %% posture (`traces_exporter = none`) — so stop it (and the SDK,
    %% which reads its env only at start) before setting this suite's.
    _ = application:stop(bondy_telemetry_exporter),
    _ = application:stop(opentelemetry),
    %% An explicitly-set `traces_exporter` OVERRIDES any per-processor
    %% `exporter` opt (otel_configuration:merge_processor_config_), so
    %% the pid exporter must be configured here, not on the processor —
    %% `none` here would silently drop every span.
    ok = application:set_env(
        opentelemetry, traces_exporter, {otel_exporter_pid, Collector}
    ),
    ok = application:set_env(opentelemetry, processors, [
        {otel_simple_processor, #{}}
    ]),
    %% The production posture the schema's hidden `tracing.id_generator`
    %% mapping writes: minted-root realization depends on it.
    ok = application:set_env(
        opentelemetry, id_generator, bondy_telemetry_exporter_otel_ids
    ),
    {ok, _} = application:ensure_all_started(bondy_telemetry_exporter),
    [{collector, Collector}, {metrics_started, MetricsStarted} | Config].

end_per_suite(Config) ->
    ok = application:stop(bondy_telemetry_exporter),
    ok = application:stop(opentelemetry),
    exit(?config(collector, Config), kill),
    ok = application:set_env(opentelemetry, traces_exporter, none),
    case ?config(metrics_started, Config) of
        true ->
            %% This suite hosted the registry, so no booted node needs
            %% the sinks: leave app AND registry stopped. An orphan
            %% registry would clash with bondy_oplog_sup's own
            %% bondy_metrics child on a later suite's full boot (failing
            %% the PERMANENT bondy_db app halts the CT node), and a
            %% running app would hold declares made against the wiped
            %% tables — the later boot restarts the app fresh instead.
            ok = gen_server:stop(bondy_metrics);
        _ ->
            %% A booted node's posture: the Prometheus sinks belong
            %% attached, so leave the app running (disabled tracing).
            {ok, _} = application:ensure_all_started(
                bondy_telemetry_exporter
            )
    end,
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

%% A traced router CALL leg becomes a retroactive SERVER span parented
%% to the carried context, with the duration realized exactly as
%% end − start and the tracestate carried through.
router_call_span(_) ->
    ok = bondy_telemetry:rpc_latency(
        call, <<"com.example.p">>, 250, trace(), success
    ),
    [Span] = flush_spans(),
    ?assertEqual(?TRACE_ID, Span#span.trace_id),
    ?assertEqual(?PARENT_SPAN_ID, Span#span.parent_span_id),
    ?assertEqual(true, Span#span.parent_span_is_remote),
    ?assertEqual(<<"com.example.p">>, Span#span.name),
    ?assertEqual(server, Span#span.kind),
    ?assertEqual(
        erlang:convert_time_unit(250, millisecond, native),
        Span#span.end_time - Span#span.start_time
    ),
    ?assertEqual(
        otel_tracestate:decode_header(?TS),
        Span#span.tracestate
    ),
    %% `success` leaves the OTel status UNSET.
    ?assertEqual(undefined, Span#span.status),
    Attrs = otel_attributes:map(Span#span.attributes),
    ?assertEqual(<<"router">>, maps:get(<<"bondy.emitter">>, Attrs)),
    ?assertEqual(<<"com.example.p">>, maps:get(<<"bondy.procedure">>, Attrs)),
    ?assertEqual(
        atom_to_binary(node(), utf8), maps:get(<<"bondy.node">>, Attrs)
    ).

%% The four RPC legs map to span kinds as mirror images: the router
%% serves a CALL and calls out an INVOCATION; the SDK is the inverse.
rpc_kind_mapping(_) ->
    ok = bondy_telemetry:rpc_latency(
        invocation, <<"com.example.a">>, 5, trace(), success
    ),
    ok = bondy_connect_telemetry:rpc_latency(
        call, <<"com.example.b">>, 5, trace(), success
    ),
    ok = bondy_connect_telemetry:rpc_latency(
        invocation, <<"com.example.c">>, 5, trace(), success
    ),
    Spans = flush_spans(),
    ?assertEqual(
        [
            {<<"com.example.a">>, client},
            {<<"com.example.b">>, client},
            {<<"com.example.c">>, server}
        ],
        lists:sort([{S#span.name, S#span.kind} || S <- Spans])
    ).

%% An `error` outcome on either rpc event marks the exported span's
%% OTel status as error (`success` leaves it unset — asserted by
%% router_call_span).
rpc_error_status(_) ->
    ok = bondy_telemetry:rpc_latency(
        call, <<"com.example.err">>, 5, trace(), error
    ),
    ok = bondy_connect_telemetry:rpc_latency(
        invocation, <<"com.example.err.sdk">>, 5, trace(), error
    ),
    [Router, Sdk] = flush_spans(),
    ?assertEqual(<<"com.example.err">>, Router#span.name),
    ?assertMatch(#status{code = error}, Router#span.status),
    ?assertEqual(<<"com.example.err.sdk">>, Sdk#span.name),
    ?assertMatch(#status{code = error}, Sdk#span.status).

%% No trace context ⇒ no span; a garbage traceparent (the wire carries
%% these verbatim and unvalidated) ⇒ no span. The trailing traced
%% sentinel proves the negatives by FIFO order through the processor.
untraced_and_malformed_no_span(_) ->
    ok = bondy_telemetry:rpc_latency(
        call, <<"com.example.untraced">>, 5, #{}, success
    ),
    ok = bondy_telemetry:rpc_latency(
        call,
        <<"com.example.malformed">>,
        5,
        #{<<"traceparent">> => <<"garbage">>},
        success
    ),
    ok = bondy_telemetry:rpc_latency(
        call, <<"com.example.sentinel">>, 5, trace(), success
    ),
    [Span] = flush_spans(),
    ?assertEqual(<<"com.example.sentinel">>, Span#span.name).

%% A `-00` traceparent means the upstream did not sample: the default
%% parent_based sampler honours it and nothing is exported.
unsampled_parent_no_span(_) ->
    ok = bondy_telemetry:rpc_latency(
        call,
        <<"com.example.unsampled">>,
        5,
        #{<<"traceparent">> => ?TP_UNSAMPLED},
        success
    ),
    ok = bondy_telemetry:rpc_latency(
        call, <<"com.example.sentinel2">>, 5, trace(), success
    ),
    [Span] = flush_spans(),
    ?assertEqual(<<"com.example.sentinel2">>, Span#span.name).

%% A MINTED context (span-id-bound `bondy=<id>` tracestate entry) has no
%% upstream span: the router CALL leg is exported as the trace's
%% parentless ROOT span carrying exactly the pre-allocated ids, and the
%% INVOCATION leg of the same trace parents to it — the natural
%% call → invocation nesting. The marker is inert everywhere else: a
%% stale entry naming a DIFFERENT span id (any downstream participant
%% that started its own spans) joins normally, and the SDK client leg
%% never roots even on an exact match (minting is a router-boundary
%% behaviour).
minted_root_span(_) ->
    TraceHex = <<"4bf92f3577b34da6a3ce929d0e0e4736">>,
    SpanHex = <<"00f067aa0ba902b7">>,
    Minted = #{
        <<"traceparent">> =>
            <<"00-", TraceHex/binary, "-", SpanHex/binary, "-01">>,
        <<"tracestate">> => <<"bondy=", SpanHex/binary>>
    },
    TraceId = binary_to_integer(TraceHex, 16),
    SpanId = binary_to_integer(SpanHex, 16),

    ok = bondy_telemetry:rpc_latency(
        call, <<"com.example.mint">>, 30, Minted, success
    ),
    ok = bondy_telemetry:rpc_latency(
        invocation, <<"com.example.mint">>, 20, Minted, success
    ),
    [Root, Child] = flush_spans(),

    ?assertEqual(TraceId, Root#span.trace_id),
    ?assertEqual(SpanId, Root#span.span_id),
    ?assertEqual(undefined, Root#span.parent_span_id),
    ?assertEqual(server, Root#span.kind),
    ?assertEqual(<<"com.example.mint">>, Root#span.name),
    ?assertEqual(
        true,
        maps:get(
            <<"bondy.trace.minted">>, otel_attributes:map(Root#span.attributes)
        )
    ),

    ?assertEqual(TraceId, Child#span.trace_id),
    ?assertEqual(SpanId, Child#span.parent_span_id),
    ?assertNotEqual(SpanId, Child#span.span_id),
    ?assertEqual(client, Child#span.kind),

    %% A stale marker: tracestate names a span id that is NOT the
    %% traceparent's parent — some downstream participant continued the
    %% trace with its own spans. Join normally, never hijack root.
    Stale = Minted#{
        <<"traceparent">> =>
            <<"00-", TraceHex/binary, "-c3d4e5f60718293a-01">>
    },
    ok = bondy_telemetry:rpc_latency(
        call, <<"com.example.mint.stale">>, 5, Stale, success
    ),
    [StaleSpan] = flush_spans(),
    ?assertEqual(
        16#c3d4e5f60718293a, StaleSpan#span.parent_span_id
    ),
    ?assertNotEqual(16#c3d4e5f60718293a, StaleSpan#span.span_id),

    %% The SDK client leg with an exact marker match still joins.
    ok = bondy_connect_telemetry:rpc_latency(
        call, <<"com.example.mint.sdk">>, 5, Minted, success
    ),
    [SdkSpan] = flush_spans(),
    ?assertEqual(SpanId, SdkSpan#span.parent_span_id),
    ?assertNotEqual(SpanId, SdkSpan#span.span_id),

    %% The root path bypasses W3C extraction, so it validates ids
    %% itself, stricter than the propagator: UPPERCASE hex (which the
    %% propagator accepts on extract — measured here — but W3C forbids
    %% and which does not round-trip to the hex the children reference)
    %% JOINS instead of rooting even with a matching marker, and the
    %% all-zero trace id produces no span at all (the propagator
    %% rejects it; the root path's own zero guard backs that). The
    %% traced sentinel proves the no-span negative by FIFO order.
    UpperHex = string:uppercase(SpanHex),
    ok = bondy_telemetry:rpc_latency(
        call,
        <<"com.example.mint.upper">>,
        5,
        #{
            <<"traceparent">> =>
                <<"00-", TraceHex/binary, "-", UpperHex/binary, "-01">>,
            <<"tracestate">> => <<"bondy=", UpperHex/binary>>
        },
        success
    ),
    ZeroTrace = binary:copy(<<"0">>, 32),
    ok = bondy_telemetry:rpc_latency(
        call,
        <<"com.example.mint.zero">>,
        5,
        #{
            <<"traceparent">> =>
                <<"00-", ZeroTrace/binary, "-", SpanHex/binary, "-01">>,
            <<"tracestate">> => <<"bondy=", SpanHex/binary>>
        },
        success
    ),
    ok = bondy_telemetry:rpc_latency(
        call, <<"com.example.mint.sentinel">>, 5, trace(), success
    ),
    [UpperSpan, Sentinel] = flush_spans(),
    ?assertEqual(<<"com.example.mint.upper">>, UpperSpan#span.name),
    %% Same integer either case — joined as parent, not claimed as own.
    ?assertEqual(SpanId, UpperSpan#span.parent_span_id),
    ?assertNotEqual(SpanId, UpperSpan#span.span_id),
    ?assertEqual(<<"com.example.mint.sentinel">>, Sentinel#span.name).

%% The three MCP completion events (µs durations): tool/resource are
%% SERVER spans, upstream a CLIENT span; `success` leaves OTel status
%% unset, any other status atom marks the span as an error.
mcp_spans(_) ->
    ok = bondy_mcp_metrics:tool_call(
        <<"com.example.realm">>, mcp1, <<"get_weather">>, success, 1500, trace()
    ),
    ok = bondy_mcp_metrics:resource_read(
        <<"com.example.realm">>,
        mcp1,
        <<"trace:///probe">>,
        success,
        900,
        trace()
    ),
    ok = bondy_mcp_metrics:upstream_call(
        <<"up1">>, internal_error, 2000, trace()
    ),
    [Tool, Resource, Upstream] = flush_spans(),

    ?assertEqual(<<"tools/call get_weather">>, Tool#span.name),
    ?assertEqual(server, Tool#span.kind),
    ?assertEqual(
        erlang:convert_time_unit(1500, microsecond, native),
        Tool#span.end_time - Tool#span.start_time
    ),
    ?assertEqual(undefined, Tool#span.status),
    ToolAttrs = otel_attributes:map(Tool#span.attributes),
    ?assertEqual(<<"mcp">>, maps:get(<<"bondy.emitter">>, ToolAttrs)),
    ?assertEqual(
        <<"com.example.realm">>, maps:get(<<"bondy.realm">>, ToolAttrs)
    ),

    ?assertEqual(<<"resources/read trace:///probe">>, Resource#span.name),
    ?assertEqual(server, Resource#span.kind),

    ?assertEqual(<<"upstream up1">>, Upstream#span.name),
    ?assertEqual(client, Upstream#span.kind),
    ?assertMatch(#status{code = error}, Upstream#span.status),
    UpAttrs = otel_attributes:map(Upstream#span.attributes),
    ?assertEqual(
        <<"internal_error">>, maps:get(<<"bondy.mcp.status">>, UpAttrs)
    ).

%% Stopping the app detaches the handlers (traced traffic exports
%% nothing), and a restart with `traces_exporter = none` — the disabled
%% posture the schema writes — attaches none.
disabled_gate_and_detach(Config) ->
    ok = application:stop(bondy_telemetry_exporter),
    ?assertNot(bridge_attached()),
    ok = bondy_telemetry:rpc_latency(
        call, <<"com.example.gone">>, 5, trace(), success
    ),
    ?assertEqual([], flush_spans()),

    ok = application:set_env(opentelemetry, traces_exporter, none),
    {ok, _} = application:ensure_all_started(bondy_telemetry_exporter),
    ?assertEqual(
        [], supervisor:which_children(bondy_telemetry_exporter_sup)
    ),
    ?assertNot(bridge_attached()),

    %% Restore the enabled posture for any case run after this one.
    ok = application:stop(bondy_telemetry_exporter),
    ok = application:set_env(
        opentelemetry,
        traces_exporter,
        {otel_exporter_pid, ?config(collector, Config)}
    ),
    {ok, _} = application:ensure_all_started(bondy_telemetry_exporter),
    ?assertMatch(
        [_], supervisor:which_children(bondy_telemetry_exporter_sup)
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private Whether the bridge's handler is attached to the latency
%% event (other suites may attach their own handlers in combined runs,
%% so absence is asserted by id, not by an empty list).
bridge_attached() ->
    lists:any(
        fun(#{id := Id}) -> Id =:= bondy_telemetry_exporter_otel end,
        telemetry:list_handlers([bondy, rpc, latency])
    ).

%% @private
%% bondy_metrics is a LIBRARY app: its named gen_server (which owns the
%% counter + declaration ETS tables `bondy_prometheus:setup/0` writes)
%% is hosted by the consumer's supervision tree — `bondy_oplog_sup` in a
%% full node, which bondy_app starts before bondy_telemetry_exporter. On
%% a standalone test node this suite is the consumer. Unlinked so the
%% server survives this init process.
ensure_metrics_registry() ->
    case whereis(bondy_metrics) of
        undefined ->
            {ok, Pid} = bondy_metrics:start_link(),
            true = unlink(Pid),
            true;
        _ ->
            false
    end.

%% @private The full W3C trio, as the substrate events carry it.
trace() ->
    #{
        <<"traceparent">> => ?TP,
        <<"tracestate">> => ?TS,
        <<"baggage">> => <<"userId=alice">>
    }.

%% @private Exported spans arrive as `{span, #span{}}` messages sent
%% synchronously from within the emitter's call stack, so by the time
%% an emitter returned they are already queued: a flush with a short
%% drain settles the set. Spans are returned in export order.
flush_spans() ->
    span_collector ! {flush, self()},
    receive
        {spans, Spans} -> Spans
    after 5000 -> ct:fail(collector_timeout)
    end.

%% @private
collector_loop() ->
    collector_loop([]).

collector_loop(Acc) ->
    receive
        {span, Span} ->
            collector_loop([Span | Acc]);
        {flush, From} ->
            From ! {spans, lists:reverse(Acc)},
            collector_loop([])
    end.
