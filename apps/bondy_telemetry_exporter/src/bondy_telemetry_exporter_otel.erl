%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_telemetry_exporter_otel).

-moduledoc """
The telemetry-event → OpenTelemetry-span bridge.

Attaches (by name — no dependency on the producing apps) to the span
substrate's completion events:

- `[bondy, rpc, latency]` — router RPC legs (ms)
- `[bondy_connect, rpc, latency]` — SDK client RPC legs (ms)
- `[bondy, mcp, tool, call, stop]` — MCP `tools/call` (µs)
- `[bondy, mcp, resource, read, stop]` — MCP `resources/read` (µs)
- `[bondy, mcp, upstream, call, stop]` — MCP upstream tool calls (µs)

Each event carries the request's W3C trace context as `trace` metadata
(binary header-named map, `#{}` untraced) and a `duration` measurement;
the rpc events carry an `outcome` and the MCP events a `status`, either
of which maps onto the span's OTel status (`success` ⇒ unset, anything
else ⇒ error).
The handler runs synchronously in the emitting process at completion
time, so it builds a **retroactive span**: end = now, start = end −
duration, parented to the carried context — the metadata map is fed
directly to `otel_propagator_trace_context` as its carrier.

Untraced events (`trace` empty) and events whose carried `traceparent`
fails W3C decoding produce no span. The SDK's default sampler
(`parent_based`, root `always_on` — read from `otel_configuration`)
honours the carried sampled flag, so a `-00` traceparent records
nothing.

A context the router MINTED (`bondy_telemetry:maybe_mint_trace/1`,
recognized by its span-id-bound `bondy=<span-id>` tracestate entry) has
no upstream span behind its parent id: the router CALL leg at the
minting node is emitted as the trace's parentless ROOT span carrying
those pre-allocated ids (via `bondy_telemetry_exporter_otel_ids`),
giving a minted trace the natural `call → invocation` nesting instead
of siblings under a phantom parent no backend can root.

`telemetry` permanently detaches a handler that raises (verified in
`telemetry:execute`), so one malformed event would silently end all
span export for the node's lifetime — `handle_event/4` therefore
catches and logs instead of crashing.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-define(EVENTS, [
    [bondy, rpc, latency],
    [bondy_connect, rpc, latency],
    [bondy, mcp, tool, call, stop],
    [bondy, mcp, resource, read, stop],
    [bondy, mcp, upstream, call, stop]
]).

%% API
-export([start_link/0]).

%% TELEMETRY HANDLER
-export([handle_event/4]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> gen_server:start_ret().

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% =============================================================================
%% TELEMETRY HANDLER
%% =============================================================================

-doc false.
-spec handle_event(
    telemetry:event_name(),
    telemetry:event_measurements(),
    telemetry:event_metadata(),
    term()
) -> ok.

handle_event(Event, Measurements, Metadata, _Config) ->
    try
        span(Event, Measurements, Metadata)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description => "OpenTelemetry span emission failed",
                event => Event,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            })
    end.

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

-doc false.
init([]) ->
    process_flag(trap_exit, true),
    ok = telemetry:attach_many(
        ?MODULE, ?EVENTS, fun ?MODULE:handle_event/4, undefined
    ),
    {ok, undefined}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, _State) ->
    telemetry:detach(?MODULE).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private One clause per subscribed event: name, span kind, duration
%% unit and attributes differ; the emission mechanics are emit/7.
span([bondy, rpc, latency], #{duration := Ms}, Meta) ->
    #{
        kind := Kind, procedure_uri := Uri, trace := Trace, outcome := Outcome
    } = Meta,
    Attrs = #{
        <<"bondy.emitter">> => <<"router">>,
        <<"bondy.procedure">> => Uri,
        <<"bondy.node">> => atom_to_binary(node(), utf8)
    },
    case minted_root_ids(Kind, Trace) of
        {TraceId, SpanId} ->
            emit_root(
                TraceId,
                SpanId,
                Uri,
                router_span_kind(Kind),
                Ms,
                millisecond,
                span_status(Outcome),
                Attrs#{<<"bondy.trace.minted">> => true}
            );
        false ->
            emit(
                Trace,
                Uri,
                router_span_kind(Kind),
                Ms,
                millisecond,
                span_status(Outcome),
                Attrs
            )
    end;
span([bondy_connect, rpc, latency], #{duration := Ms}, Meta) ->
    #{
        kind := Kind, procedure_uri := Uri, trace := Trace, outcome := Outcome
    } = Meta,
    emit(
        Trace,
        Uri,
        sdk_span_kind(Kind),
        Ms,
        millisecond,
        span_status(Outcome),
        #{
            <<"bondy.emitter">> => <<"sdk">>,
            <<"bondy.procedure">> => Uri,
            <<"bondy.node">> => atom_to_binary(node(), utf8)
        }
    );
span([bondy, mcp, tool, call, stop], #{duration := Us}, Meta) ->
    #{realm := Realm, name := Name, status := Status, trace := Trace} = Meta,
    emit(
        Trace,
        <<"tools/call ", Name/binary>>,
        ?SPAN_KIND_SERVER,
        Us,
        microsecond,
        span_status(Status),
        #{
            <<"bondy.emitter">> => <<"mcp">>,
            <<"bondy.realm">> => Realm,
            <<"bondy.mcp.status">> => atom_to_binary(Status, utf8),
            <<"bondy.node">> => atom_to_binary(node(), utf8)
        }
    );
span([bondy, mcp, resource, read, stop], #{duration := Us}, Meta) ->
    #{realm := Realm, name := Name, status := Status, trace := Trace} = Meta,
    emit(
        Trace,
        <<"resources/read ", Name/binary>>,
        ?SPAN_KIND_SERVER,
        Us,
        microsecond,
        span_status(Status),
        #{
            <<"bondy.emitter">> => <<"mcp">>,
            <<"bondy.realm">> => Realm,
            <<"bondy.mcp.status">> => atom_to_binary(Status, utf8),
            <<"bondy.node">> => atom_to_binary(node(), utf8)
        }
    );
span([bondy, mcp, upstream, call, stop], #{duration := Us}, Meta) ->
    #{upstream := Upstream, status := Status, trace := Trace} = Meta,
    emit(
        Trace,
        <<"upstream ", Upstream/binary>>,
        ?SPAN_KIND_CLIENT,
        Us,
        microsecond,
        span_status(Status),
        #{
            <<"bondy.emitter">> => <<"mcp">>,
            <<"bondy.mcp.upstream">> => Upstream,
            <<"bondy.mcp.status">> => atom_to_binary(Status, utf8),
            <<"bondy.node">> => atom_to_binary(node(), utf8)
        }
    ).

%% @private The router observes a CALL as its server leg and an
%% INVOCATION as its client leg (it is calling out to the callee); the
%% SDK is the mirror image.
router_span_kind(call) -> ?SPAN_KIND_SERVER;
router_span_kind(invocation) -> ?SPAN_KIND_CLIENT.

sdk_span_kind(call) -> ?SPAN_KIND_CLIENT;
sdk_span_kind(invocation) -> ?SPAN_KIND_SERVER.

%% @private A minted trace's parent span id is PRE-ALLOCATED by
%% `bondy_telemetry:maybe_mint_trace/1` — no upstream span exists, and a
%% trace whose only spans hang off a phantom parent has no root (Tempo
%% classifies none of them `nestedSetParent < 0`, so root-scoped TraceQL
%% — all of Grafana Traces Drilldown — sees nothing; measured). The
%% mint marks the context with the tracestate vendor entry
%% `bondy=<span-id>`, and the one leg whose traceparent still names that
%% exact span id as its parent — the CALL leg at the minting node — is
%% the trace boundary: its span is emitted AS the root, carrying the
%% pre-allocated ids themselves rather than a fresh id under a phantom
%% parent. Binding the marker to the id keeps a propagated stale marker
%% inert: any downstream participant that starts its own spans changes
%% the parent id and the marker no longer matches (`false` here means
%% "join normally"). Ids are validated here — 32/16 lowercase-hex,
%% non-zero (W3C forbids zero ids) — since tracestate arrives off the
%% wire unvalidated.
minted_root_ids(call, #{
    <<"traceparent">> :=
        <<"00-", TraceHex:32/binary, "-", SpanHex:16/binary, "-", _/binary>>,
    <<"tracestate">> := TraceState
}) ->
    Marker = <<"bondy=", SpanHex/binary>>,
    case
        lists:member(Marker, binary:split(TraceState, <<",">>, [global])) andalso
            is_lower_hex(TraceHex) andalso is_lower_hex(SpanHex)
    of
        true ->
            case
                {
                    binary_to_integer(TraceHex, 16),
                    binary_to_integer(SpanHex, 16)
                }
            of
                {0, _} -> false;
                {_, 0} -> false;
                Ids -> Ids
            end;
        false ->
            false
    end;
minted_root_ids(_, _) ->
    false.

%% @private `binary_to_integer/2` alone is NOT a validator — it accepts
%% uppercase and sign characters, which W3C traceparent forbids and
%% whose ids would not round-trip to the hex the children reference.
is_lower_hex(<<>>) ->
    true;
is_lower_hex(<<C, Rest/binary>>) when
    C >= $0, C =< $9; C >= $a, C =< $f
->
    is_lower_hex(Rest);
is_lower_hex(_) ->
    false.

%% @private Build and end the retroactive ROOT span of a minted trace:
%% parentless, carrying exactly the pre-allocated ids the minted
%% traceparent named — every other leg of the trace references them as
%% its parent. `start_span` offers no per-span id, so the ids are
%% forced through the SDK's configured `id_generator`
%% (`bondy_telemetry_exporter_otel_ids`, set by the schema's hidden
%% `opentelemetry.id_generator` mapping) for the synchronous extent of
%% this one `start_span`. The pattern match on the returned ctx asserts
%% the forced ids actually took: if the SDK is running with a different
%% generator the minted ids did NOT take, and exporting the root under
%% fresh ids would orphan every child — the badmatch surfaces in
%% handle_event's log instead. The parentless root goes through the
%% sampler's root branch (`always_on` under the SDK default
%% parent_based sampler), not the parent branch.
emit_root(TraceId, SpanId, Name, Kind, Duration, Unit, Status, Attrs) ->
    End = opentelemetry:timestamp(),
    Start = End - erlang:convert_time_unit(Duration, Unit, native),
    Tracer = opentelemetry:get_application_tracer(?MODULE),
    SpanCtx = bondy_telemetry_exporter_otel_ids:with_forced(
        TraceId, SpanId, fun() ->
            otel_tracer:start_span(otel_ctx:new(), Tracer, Name, #{
                kind => Kind,
                start_time => Start,
                attributes => Attrs
            })
        end
    ),
    #span_ctx{trace_id = TraceId, span_id = SpanId} = SpanCtx,
    _ = Status =:= error andalso otel_span:set_status(SpanCtx, error),
    _ = otel_span:end_span(SpanCtx, End),
    ok.

%% @private `success` leaves the OTel status UNSET (the convention for
%% "nothing went wrong"); every other outcome/status atom marks the
%% span as an error. Shared by the rpc events' `outcome`
%% (`success | error`) and the MCP events' `status` (whose atom is
%% additionally preserved in `bondy.mcp.status`).
span_status(success) -> unset;
span_status(_) -> error.

%% @private Build and end the retroactive span. The `trace` map's keys
%% are already the W3C header names, so `maps:to_list/1` of it is a
%% valid default text-map carrier; extraction is total — an
%% undecodable `traceparent` leaves the context without a span context
%% and no span is emitted (the wire carries these values verbatim and
%% unvalidated, so this is the validation point).
emit(Trace, Name, Kind, Duration, Unit, Status, Attrs) when
    map_size(Trace) > 0
->
    Ctx = otel_propagator_text_map:extract_to(
        otel_ctx:new(), otel_propagator_trace_context, maps:to_list(Trace)
    ),
    case otel_tracer:current_span_ctx(Ctx) of
        undefined ->
            ok;
        _Parent ->
            End = opentelemetry:timestamp(),
            Start = End - erlang:convert_time_unit(Duration, Unit, native),
            Tracer = opentelemetry:get_application_tracer(?MODULE),
            SpanCtx = otel_tracer:start_span(Ctx, Tracer, Name, #{
                kind => Kind,
                start_time => Start,
                attributes => Attrs
            }),
            _ = Status =:= error andalso otel_span:set_status(SpanCtx, error),
            _ = otel_span:end_span(SpanCtx, End),
            ok
    end;
emit(_, _, _, _, _, _, _) ->
    ok.
