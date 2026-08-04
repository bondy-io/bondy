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
-export([rpc_latency/3]).
-export([wamp_hello/1]).
-export([session_manager_open/2]).
-export([session_manager_cleanup/2]).
-export([ping_rtt/3]).
-export([realm_event/2]).
-export([user_event/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Generates a 128 bit random integer to use as a trace id.
""".
-spec trace_id() -> integer().

trace_id() ->
    %% 2 shifted left by 127 == 2 ^ 128
    rand:uniform(2 bsl 127 - 1).

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
As `router_flow/3` but with the service time only — for tasks delivered
straight into the worker's mailbox by a remote peer's relayed message
(the `{via, bondy_router_worker, Key}` resolution), where no local
dispatch timestamp exists: the mailbox wait would span two nodes'
monotonic clocks, which are not comparable. Total: never throws.
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
can attribute latency to the router or the application. Total: never
throws.
""".
-spec rpc_latency(
    Kind :: call | invocation,
    ProcedureUri :: binary(),
    DurationMs :: integer()
) -> ok.

rpc_latency(Kind, ProcedureUri, DurationMs) ->
    execute(
        [bondy, rpc, latency],
        #{duration => max(0, DurationMs)},
        #{kind => Kind, procedure_uri => ProcedureUri}
    ).

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
