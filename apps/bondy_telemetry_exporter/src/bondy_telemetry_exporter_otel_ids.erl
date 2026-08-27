%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_telemetry_exporter_otel_ids).

-moduledoc """
The OpenTelemetry SDK's `id_generator` for Bondy (configured via the
`opentelemetry.id_generator` env the schema writes): the default random
generator, plus a per-process override that lets the span bridge give
one span the EXACT ids a minted W3C traceparent pre-allocated for it
(`bondy_telemetry:maybe_mint_trace/1` mints the id, the bridge realizes
the root span under it — the SDK offers no per-span id in
`start_span`'s opts, but threads this module into every id decision:
`otel_tracer_server` embeds the configured module in each tracer and
`otel_span_utils:root_span_ctx/1` calls it for a parentless span, read
from those sources).

The override lives in the process dictionary: `with_forced/3` sets it
for exactly the synchronous extent of its fun and erases it on any
exit, and the SDK generates ids inside the caller's own
`start_span` call stack, so no other process — and no other span in
this process — can observe it.
""".

-behaviour(otel_id_generator).

-export([generate_trace_id/0]).
-export([generate_span_id/0]).
-export([with_forced/3]).

-define(FORCED_KEY, {?MODULE, forced}).

-doc """
Runs `Fun` with the SDK's id generation forced to `TraceId`/`SpanId`
(the integers a minted traceparent carries), restoring normal random
generation afterwards even if `Fun` raises.
""".
-spec with_forced(
    TraceId :: pos_integer(), SpanId :: pos_integer(), Fun :: fun(() -> Res)
) -> Res.

with_forced(TraceId, SpanId, Fun) ->
    _ = erlang:put(?FORCED_KEY, {TraceId, SpanId}),
    try
        Fun()
    after
        _ = erlang:erase(?FORCED_KEY)
    end.

-doc false.
-spec generate_trace_id() -> opentelemetry:trace_id().

generate_trace_id() ->
    case erlang:get(?FORCED_KEY) of
        {TraceId, _} -> TraceId;
        undefined -> otel_id_generator:generate_trace_id()
    end.

-doc false.
-spec generate_span_id() -> opentelemetry:span_id().

generate_span_id() ->
    case erlang:get(?FORCED_KEY) of
        {_, SpanId} -> SpanId;
        undefined -> otel_id_generator:generate_span_id()
    end.
