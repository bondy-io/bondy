%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_telemetry).
-moduledoc """
Telemetry conventions for Bondy's router instrumentation.

Hot-path events are emitted with `telemetry:execute/3` and follow two
rules (see METRICS_GAP_ANALYSIS.md Part II):

1. Emission passes **extracted scalars only** — never router terms such
   as WAMP messages or contexts. Telemetry handlers run inline in the
   emitting process, so the metadata map is the only per-event
   allocation.
2. Emitters are **total**: `telemetry:execute/3` is wrapped so a buggy
   or detached handler can never affect message routing.

The functions here are the emission sites' single entry point; the
matching sinks live in `bondy_prometheus` and write `bondy_metrics`
(wait-free BIF counters) rendered at scrape time by
`bondy_prometheus_collector`.

Also provides trace-identifier generation.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-export([trace_id/0]).
-export([wamp_message/2]).
-export([wamp_message/3]).
-export([socket_open/2]).
-export([socket_closed/3]).
-export([socket_error/2]).
-export([session_opened/1]).
-export([session_closed/3]).
-export([registry_event/3]).
-export([router_flow/2]).
-export([router_flow/3]).
-export([router_flow_ingress/3]).
-export([wamp_egress/3]).
-export([rpc_latency/6]).
-export([trace_meta/1]).
-export([broker_publish/2]).
-export([wamp_hello/1]).
-export([session_manager_open/2]).
-export([session_manager_cleanup/2]).
-export([ping_rtt/3]).
-export([realm_event/2]).
-export([user_event/3]).
-export([wamp_dropped/2]).
-export([http_request/1]).
-export([maybe_mint_trace/1]).
-export([maybe_hop_trace/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Generates a W3C Trace Context `trace-id`: 32 lowercase hex characters.

Shares its representation with the `trace_id` carried by `bondy_error:t()`, so
a request identifier and an error correlation identifier are the same kind of
value and can be propagated to an OpenTelemetry collector unchanged.
""".
-spec trace_id() -> binary().

trace_id() ->
    bondy_uuidv7:format(bondy_uuidv7:new(), #{mode => compact_hex}).

-doc """
Emits the `[bondy, wamp, message]` telemetry event for a routed WAMP
message whose wire size is unknown (internal callers that never touch a
transport). Counter families only — no size measurement is emitted.

Extracts the scalar metadata the metric sinks need (message type,
subprotocol triple, realm type and — for the URI-labelled families —
the procedure/topic/error URI) so no router term crosses the telemetry
boundary. Total: never throws.
""".
-spec wamp_message(M :: tuple(), Ctxt :: bondy_context:t()) -> ok.

wamp_message(M, Ctxt) ->
    do_wamp_message(M, #{}, Ctxt).

-doc """
Emits the `[bondy, wamp, message]` telemetry event for a WAMP message
crossing a transport boundary. `WireSize` is the byte size of the
encoded frame — callers pass it from the encode/decode site, so the
size metric costs a `byte_size`/`iolist_size` instead of a term
traversal. Total: never throws.
""".
-spec wamp_message(
    M :: tuple(),
    WireSize :: non_neg_integer(),
    Ctxt :: bondy_context:t()
) -> ok.

wamp_message(M, WireSize, Ctxt) ->
    do_wamp_message(M, #{size => WireSize}, Ctxt).

-doc """
Emits `[bondy, socket, open]` for an accepted transport connection.
Total: never throws.
""".
-spec socket_open(Protocol :: atom(), Transport :: atom()) -> ok.

socket_open(Protocol, Transport) ->
    execute(
        [bondy, socket, open],
        #{count => 1},
        #{protocol => Protocol, transport => Transport}
    ).

-doc """
Emits `[bondy, socket, closed]` with the connection duration in seconds.
Total: never throws.
""".
-spec socket_closed(
    Protocol :: atom(), Transport :: atom(), DurationSecs :: integer()
) -> ok.

socket_closed(Protocol, Transport, DurationSecs) ->
    execute(
        [bondy, socket, closed],
        #{duration => DurationSecs},
        #{protocol => Protocol, transport => Transport}
    ).

-doc """
Emits `[bondy, socket, error]` for a connection terminated by a
transport error. Total: never throws.
""".
-spec socket_error(Protocol :: atom(), Transport :: atom()) -> ok.

socket_error(Protocol, Transport) ->
    execute(
        [bondy, socket, error],
        #{count => 1},
        #{protocol => Protocol, transport => Transport}
    ).

-doc """
Emits `[bondy, session, opened]`. Extracts the realm URI from the
session so no session term crosses the telemetry boundary. Total:
never throws.
""".
-spec session_opened(Session :: bondy_session:t()) -> ok.

session_opened(Session) ->
    try bondy_session:realm_uri(Session) of
        RealmUri ->
            execute(
                [bondy, session, opened], #{count => 1}, #{realm => RealmUri}
            )
    catch
        _:_ ->
            ok
    end.

-doc """
Emits `[bondy, session, closed]` with the session duration in seconds
and the WAMP close reason URI (or `undefined`). Total: never throws.
""".
-spec session_closed(
    Session :: bondy_session:t(),
    DurationSecs :: integer(),
    Reason :: binary() | undefined
) -> ok.

session_closed(Session, DurationSecs, Reason) ->
    try bondy_session:realm_uri(Session) of
        RealmUri ->
            execute(
                [bondy, session, closed],
                #{duration => DurationSecs},
                #{realm => RealmUri, reason => Reason}
            )
    catch
        _:_ ->
            ok
    end.

-doc """
Emits `[bondy, wamp, hello]` with the in-process time (µs) spent
handling a HELLO message on the connection process: realm lookup, auth
context build and — when no challenge is needed — the full session open
up to the encoded WELCOME. Together with `[bondy, session_manager,
open]` this decomposes client-observed session-establishment latency
into connection-process time vs session-manager queue/service time.
Total: never throws.
""".
-spec wamp_hello(DurationUs :: integer()) -> ok.

wamp_hello(DurationUs) ->
    execute([bondy, wamp, hello], #{duration => max(0, DurationUs)}, #{}).

-doc """
Emits `[bondy, broker, publish]` for one PUBLISH handled inline in the
publisher's connection process.

Splits the publish into the two stages that can independently dominate it:
`MatchUs` is the registry/trie lookup of matching subscriptions, `FanoutUs` is
delivering to every local subscriber plus one relayed PUBLISH per peer node
holding one. Without this split a slow publish is unattributable — a wide
fanout and an expensive match look identical from outside, and both look
identical to a downstream relay-ingress backlog (which
`bondy_router_flow_queue_microseconds` already covers).

Total: never throws.
""".
-spec broker_publish(MatchUs :: integer(), FanoutUs :: integer()) -> ok.

broker_publish(MatchUs, FanoutUs) ->
    execute(
        [bondy, broker, publish],
        #{match => max(0, MatchUs), fanout => max(0, FanoutUs)},
        #{}
    ).

-doc """
Emits `[bondy, session_manager, open]` for a session open served by a
`bondy_session_manager` pool worker. `QueueUs` is the time the request
waited in the worker's mailbox (enqueue at the caller to dequeue at the
worker); `ServiceUs` is the time the worker spent serving it. A high
queue/service ratio means opens are stuck behind other worker work
(e.g. crashed-session cleanup), not that opening is slow. Total: never
throws.
""".
-spec session_manager_open(QueueUs :: integer(), ServiceUs :: integer()) -> ok.

session_manager_open(QueueUs, ServiceUs) ->
    execute(
        [bondy, session_manager, open],
        #{queue => max(0, QueueUs), service => max(0, ServiceUs)},
        #{}
    ).

-doc """
Emits `[bondy, session_manager, cleanup]` with the time (µs) a
`bondy_session_manager` pool worker spent on session teardown work.
`Kind` is `down` (connection process died, full router flush), `close`
(explicit close request) or `error` (rollback of a failed open). This
work shares the worker mailbox with session opens, so its duration is
open-latency the next queued open will pay. Total: never throws.
""".
-spec session_manager_cleanup(
    Kind :: down | close | error, DurationUs :: integer()
) -> ok.

session_manager_cleanup(Kind, DurationUs) ->
    execute(
        [bondy, session_manager, cleanup],
        #{duration => max(0, DurationUs)},
        #{kind => Kind}
    ).

-doc """
Emits `[bondy, router, flow]` for a task executed by a router flow pool
worker (`bondy_router_worker:cast/2,3`). `QueueUs` is the time the task
waited in the worker's mailbox (cast at the dispatcher to execution at
the worker); `ServiceUs` is the execution time. `Family` is `relay` for
tasks dispatched by the relay ingress for messages arriving from
cluster peers, `bridge_relay` for bridge-relay ingress, and `router`
(the `cast/2` default) for anything else. Because ordered flows cannot
convert queue depth into throughput, sustained queue growth here is
delivery latency every event behind it will pay — and once a worker's
share of the pool capacity is full, further tasks are shed (see
`bondy_wamp_dropped_total`). Total: never throws.
""".
-spec router_flow(
    Family :: atom(), QueueUs :: integer(), ServiceUs :: integer()
) -> ok.

router_flow(Family, QueueUs, ServiceUs) ->
    execute(
        [bondy, router, flow],
        #{queue => max(0, QueueUs), service => max(0, ServiceUs)},
        #{family => Family}
    ).

-doc """
As `router_flow/3` but reporting mailbox DEPTH instead of wait — for tasks
delivered straight into the worker's mailbox by a remote peer's relayed
message (the `{via, bondy_router_worker, Key}` resolution).

There is no local dispatch timestamp for these, and there cannot usefully be
one: a stamp applied at the sending node would span two nodes' monotonic
clocks (not comparable) and would fold network transit into what is supposed
to be a queueing measurement. Carrying a per-message timestamp to make the
wait exact would also cost an allocation on the hottest cross-node path.

Depth is the local, allocation-free substitute, and it answers the question
the wait was wanted for — is relay ingress backing up? Because a flow is FIFO
on its worker, `depth x service` estimates the wait every message behind this
one will pay. Relay ingress is the flow pool's ONLY data-plane role, so
without this the pool is unobservable exactly where it matters.

Total: never throws.
""".
-spec router_flow_ingress(
    Family :: atom(), ServiceUs :: integer(), Depth :: non_neg_integer()
) -> ok.

router_flow_ingress(Family, ServiceUs, Depth) ->
    execute(
        [bondy, router, flow],
        #{service => max(0, ServiceUs), depth => max(0, Depth)},
        #{family => Family}
    ).

-doc """
Emits `[bondy, wamp, egress]` for ONE outbound WAMP message handled by a
subscriber's own connection process — the last hop before the wire.

`Depth` is the connection process's mailbox depth at dequeue; `ServiceUs` is
the in-process time spent handling the message. Same shape, and the same
reasoning, as `router_flow_ingress/3`: router deliveries arrive as a plain
`!` into this process's mailbox and carry no dispatch timestamp, so depth is
the local, allocation-free backlog signal. A connection process handles its
mailbox FIFO, so `depth x service` estimates the wait every message behind
this one pays.

This closes the last unmeasured segment of the delivery path. `match` and
`fanout` cover the publisher's connection process, `router_flow_ingress/3`
covers relay ingress, and this covers egress; a delivery tail visible in
none of them is the socket, the network or the client.

CAVEAT — what `ServiceUs` does NOT include: for WebSocket, cowboy performs
the socket write AFTER the handler callback returns, so this measures the
encode, not the send. For a transport whose handler calls `Transport:send`
itself the send IS included. Compare across transports accordingly.

Total: never throws.
""".
-spec wamp_egress(
    Transport :: atom(), ServiceUs :: integer(), Depth :: non_neg_integer()
) -> ok.

wamp_egress(Transport, ServiceUs, Depth) ->
    execute(
        [bondy, wamp, egress],
        #{service => max(0, ServiceUs), depth => max(0, Depth)},
        #{transport => Transport}
    ).

-doc """
Emits `[bondy, wamp, dropped]` for a message or event Bondy declined to
deliver. `Reason` is the cause (e.g. `shed` when dropped by load
shedding, `admission` when refused by the session admission gate) and
`Family` the class of dropped work (e.g. `subscription` for a dropped
subscription meta event). Total: never throws.
""".
-spec wamp_dropped(Reason :: atom(), Family :: atom()) -> ok.

wamp_dropped(Reason, Family) ->
    execute(
        [bondy, wamp, dropped],
        #{count => 1},
        #{reason => Reason, family => Family}
    ).

-doc """
Cowboy [metrics stream handler](https://github.com/ninenines/cowboy/blob/master/src/cowboy_metrics_h.erl)
callback: emits `[bondy, http, request]` once per HTTP request/stream,
with the complete Cowboy metrics map as the event metadata. Passed as
`metrics_callback` by `bondy_listener_ranch`, so listeners carry no
reference to any metrics sink. The map is an exception to the
extracted-scalars rule above: it already exists in the emitting process
(cowboy_metrics_h built it), so forwarding it allocates nothing. Total:
never throws.
""".
-spec http_request(Metrics :: map()) -> ok.

http_request(Metrics) ->
    execute([bondy, http, request], #{count => 1}, Metrics).

-doc """
As `router_flow/3` but with the service time only. Total: never throws.
""".
-spec router_flow(Family :: atom(), ServiceUs :: integer()) -> ok.

router_flow(Family, ServiceUs) ->
    execute(
        [bondy, router, flow],
        #{service => max(0, ServiceUs)},
        #{family => Family}
    ).

-doc """
Emits `[bondy, registry, event]` for a registration/subscription
lifecycle action. This is the unconditional aggregate signal — it is
counted whether or not the corresponding WAMP meta event is demanded
(see `bondy_meta_events`). Extracts the realm URI so no registry entry
crosses the telemetry boundary. Total: never throws.
""".
-spec registry_event(
    Type :: registration | subscription,
    Action :: created | added | removed | deleted,
    Entry :: bondy_registry_entry:t()
) -> ok.

registry_event(Type, Action, Entry) ->
    RealmUri =
        try
            bondy_registry_entry:realm_uri(Entry)
        catch
            _:_ -> undefined
        end,
    execute(
        [bondy, registry, event],
        #{count => 1},
        #{type => Type, action => Action, realm => RealmUri}
    ).

-doc """
Emits `[bondy, rpc, latency]` for a settled RPC promise.

`Kind` distinguishes the two observation points: `call` is the full
CALL→first-response round trip (router + callee time); `invocation` is
the INVOCATION→YIELD leg (callee execution + transport), so operators
can attribute latency to the router or the application.

`Trace` is the call's W3C trace context in the shape `trace_meta/1`
returns (`#{}` when the call was untraced), so a handler can export
this observation as a span: handlers run synchronously in the settling
process, so the handler's own clock at handle time is the observation's
end and `duration` locates its start.

`Outcome` is how the leg settled: `success` for a RESULT/YIELD,
`error` for a WAMP ERROR — a promise evicted on timeout emits no
latency event at all, so those are the only two values. Total: never
throws.

`PeerService` names the leg's remote party when the emitter knows one —
the callee's HELLO agent for an `invocation` leg — and is `undefined`
otherwise (`call` legs always pass `undefined`: their remote party is
the caller, which the trace context already identifies). A span
consumer maps it to the OTel `peer.service` attribute on client-kind
spans, which is what lets a service graph draw an edge to an
uninstrumented callee.
""".
-spec rpc_latency(
    Kind :: call | invocation,
    ProcedureUri :: binary(),
    DurationMs :: integer(),
    Trace :: #{binary() => binary()},
    Outcome :: success | error,
    PeerService :: binary() | undefined
) -> ok.

rpc_latency(Kind, ProcedureUri, DurationMs, Trace, Outcome, PeerService) ->
    execute(
        [bondy, rpc, latency],
        #{duration => max(0, DurationMs)},
        #{
            kind => Kind,
            procedure_uri => ProcedureUri,
            trace => Trace,
            outcome => Outcome,
            peer_service => PeerService
        }
    ).

-doc """
Injects a freshly minted W3C trace context into a validated CALL
options map that carries none — the router-as-trace-boundary behaviour
API gateways implement, gated on `tracing.mint.enabled` (default off)
and its head-sampling companion `tracing.mint.ratio`.

A map already carrying a **binary** `'_traceparent'` is returned
unchanged: the router only ever joins a caller's context, and a
malformed binary stays carried verbatim (extraction downstream treats
it as untraced). A non-binary `'_traceparent'` counts as absent — per
W3C, a participant receiving an invalid `traceparent` may restart the
trace. When minting is off, or the sampling coin toss rejects the
call, the map is returned unchanged and the call stays untraced end to
end — an unsampled call costs one config read and at most one
`rand:uniform/0`. A minted context has the sampled flag set (`-01`);
its trace id is `trace_id/0`'s, which is never all-zero (UUIDv7
version bits), and the all-zero span id W3C forbids is regenerated.

A minted context also carries the W3C tracestate vendor entry
`bondy=<span-id>`, naming the traceparent's parent span id: the span-id
seat in a minted traceparent is not (as in a carried context) an
already-emitted upstream span but a PRE-ALLOCATED id that the
router-leg span bridge realizes as the trace's ROOT span when the call
leg completes (`bondy_telemetry_exporter_otel`). Binding the marker to
the specific span id keeps it inert everywhere else: propagated
downstream per W3C, it no longer matches once any participant starts
its own spans. Any `'_tracestate'` present alongside an absent or
non-binary traceparent is not a valid context (W3C) and is overwritten.
Total: never throws.
""".
-spec maybe_mint_trace(map()) -> map().

maybe_mint_trace(#{'_traceparent' := TP} = Opts) when is_binary(TP) ->
    Opts;
maybe_mint_trace(Opts) when is_map(Opts) ->
    case bondy_config:get([tracing_mint, enabled], false) of
        true ->
            Ratio = bondy_config:get([tracing_mint, ratio], 1.0),
            case Ratio >= 1.0 orelse rand:uniform() =< Ratio of
                true ->
                    SpanId = binary:encode_hex(mint_span_id(), lowercase),
                    Opts#{
                        '_traceparent' =>
                            <<"00-", (trace_id())/binary, "-", SpanId/binary,
                                "-01">>,
                        '_tracestate' => <<"bondy=", SpanId/binary>>
                    };
                false ->
                    Opts
            end;
        _ ->
            Opts
    end.

-doc """
Stamps the cluster-forward hop marker into a TRACED call's options: a
fresh pre-allocated span id as the W3C tracestate vendor entry
`bondyhop=<span-id>`, replacing any entry already carried under that
key (a re-forward is a new hop) and prepending the rest of the
caller's `tracestate` per the W3C update rule. The span bridge
realizes the id as the inter-node forward's CLIENT/SERVER span pair —
the pairing a trace backend's service graph draws a node-to-node edge
from. An options map without a binary `'_traceparent'` is returned
unchanged: no trace, no hop span. `'_traceparent'` and `'_baggage'`
are never touched — updating our own `tracestate` entry at a
propagation seat is exactly what that field exists for, and is the
one deliberate exception to Bondy's carry-verbatim rule.

Not gated on any local tracing flag: the spans the id serves are
emitted by whichever nodes have an exporter enabled, which the
forwarding node cannot know. Total: never throws.
""".
-spec maybe_hop_trace(map()) -> map().

maybe_hop_trace(#{'_traceparent' := TP} = Opts) when is_binary(TP) ->
    Hop = binary:encode_hex(mint_span_id(), lowercase),
    Entry = <<"bondyhop=", Hop/binary>>,
    TS =
        case Opts of
            #{'_tracestate' := TS0} when is_binary(TS0), TS0 =/= <<>> ->
                case
                    [
                        E
                     || E <- binary:split(TS0, <<",">>, [global]),
                        not is_hop_entry(E)
                    ]
                of
                    [] ->
                        Entry;
                    Rest ->
                        iolist_to_binary(
                            lists:join(<<",">>, [Entry | Rest])
                        )
                end;
            _ ->
                Entry
        end,
    Opts#{'_tracestate' => TS};
maybe_hop_trace(Opts) when is_map(Opts) ->
    Opts.

%% @private
is_hop_entry(<<"bondyhop=", _/binary>>) -> true;
is_hop_entry(_) -> false.

-doc """
Maps a validated CALL options (or INVOCATION details) map to the
`trace` telemetry-metadata value: the W3C header-named binary map
(`traceparent`, `tracestate`, `baggage`), or `#{}` when the message
carries no usable context. Values are carried verbatim, never parsed.
W3C Trace Context rule: `tracestate` (and a Baggage entry) without a
`traceparent` is not a context, so a lone or non-binary
`'_traceparent'` voids all three while a non-binary sibling is dropped
alone. Total over any map.
""".
-spec trace_meta(map()) -> #{binary() => binary()}.

trace_meta(#{'_traceparent' := TP} = Opts) when is_binary(TP) ->
    Meta =
        case Opts of
            #{'_tracestate' := TS} when is_binary(TS) ->
                #{<<"traceparent">> => TP, <<"tracestate">> => TS};
            _ ->
                #{<<"traceparent">> => TP}
        end,
    case Opts of
        #{'_baggage' := BG} when is_binary(BG) ->
            Meta#{<<"baggage">> => BG};
        _ ->
            Meta
    end;
trace_meta(Opts) when is_map(Opts) ->
    #{}.

-doc """
Emits `[bondy, realm, event]` for a realm lifecycle action
(`created | updated | deleted`). Total: never throws.
""".
-spec realm_event(Action :: atom(), RealmUri :: binary()) -> ok.

realm_event(Action, RealmUri) ->
    execute(
        [bondy, realm, event],
        #{count => 1},
        #{action => Action, realm => RealmUri}
    ).

-doc """
Emits `[bondy, user, event]` for a user lifecycle action
(`added | updated | deleted | credentials_updated`). Only scalars cross
the boundary — never the user record. Total: never throws.
""".
-spec user_event(
    Action :: atom(), RealmUri :: binary(), Username :: binary()
) -> ok.

user_event(Action, RealmUri, _Username) ->
    %% Username deliberately NOT a label (unbounded cardinality); the
    %% arity keeps the emission site honest about what happened.
    execute(
        [bondy, user, event],
        #{count => 1},
        #{action => Action, realm => RealmUri}
    ).

-doc """
Emits `[bondy, socket, ping_rtt]` with the round-trip time of a
transport-level ping the router initiated. Total: never throws.
""".
-spec ping_rtt(
    Protocol :: atom(), Transport :: atom(), DurationMs :: integer()
) -> ok.

ping_rtt(Protocol, Transport, DurationMs) ->
    execute(
        [bondy, socket, ping_rtt],
        #{duration => max(0, DurationMs)},
        #{protocol => Protocol, transport => Transport}
    ).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
do_wamp_message(M, Measurements, Ctxt) ->
    try
        %% Internal contexts (e.g. gateway/internal callers) may carry no
        %% subprotocol (bondy_context:subprotocol/1 is partial).
        {Transport, FrameType, Encoding} =
            try bondy_context:subprotocol(Ctxt) of
                {_, _, _} = Subprotocol -> Subprotocol;
                _ -> {undefined, undefined, undefined}
            catch
                _:_ -> {undefined, undefined, undefined}
            end,
        Meta0 = #{
            type => element(1, M),
            realm_type => realm_type(Ctxt),
            protocol => wamp,
            transport => Transport,
            frame_type => FrameType,
            encoding => Encoding
        },
        Meta = add_uri(M, Meta0),
        telemetry:execute([bondy, wamp, message], Measurements, Meta)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_DEBUG(#{
                description => "Failed to emit wamp message telemetry",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

%% @private
%% Total wrapper: an emitter must never affect the caller (WAL
%% convention, see METRICS_GAP_ANALYSIS.md Part II Rule 5).
execute(Event, Measurements, Meta) ->
    try
        telemetry:execute(Event, Measurements, Meta)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_DEBUG(#{
                description => "Failed to emit telemetry event",
                event => Event,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

%% @private
realm_type(Ctxt) ->
    try bondy_context:realm_uri(Ctxt) of
        ?MASTER_REALM_URI -> master;
        _ -> user
    catch
        _:_ ->
            undefined
    end.

%% @private
%% W3C forbids the all-zero span id (probability 2^-64 — regenerate).
mint_span_id() ->
    case crypto:strong_rand_bytes(8) of
        <<0:64>> -> mint_span_id();
        Bytes -> Bytes
    end.

%% @private
%% The URI label the per-type metric family carries, when it carries one.
add_uri(#call{procedure_uri = Val}, Meta) ->
    Meta#{uri => Val};
add_uri(#register{procedure_uri = Val}, Meta) ->
    Meta#{uri => Val};
add_uri(#publish{topic_uri = Val}, Meta) ->
    Meta#{uri => Val};
add_uri(#subscribe{topic_uri = Val}, Meta) ->
    Meta#{uri => Val};
add_uri(#error{error_uri = Val}, Meta) ->
    Meta#{uri => Val};
add_uri(_, Meta) ->
    Meta.
