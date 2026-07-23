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
-export([socket_open/2]).
-export([socket_closed/3]).
-export([socket_error/2]).
-export([session_opened/1]).
-export([session_closed/3]).
-export([registry_event/3]).
-export([rpc_latency/3]).
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
message.

Extracts the scalar metadata the metric sinks need (message type,
subprotocol triple, realm type and — for the URI-labelled families —
the procedure/topic/error URI) so no router term crosses the telemetry
boundary. Total: never throws.
""".
-spec wamp_message(M :: tuple(), Ctxt :: bondy_context:t()) -> ok.

wamp_message(M, Ctxt) ->
    try
        Size = erts_debug:flat_size(M) * 8,
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
        telemetry:execute([bondy, wamp, message], #{size => Size}, Meta)
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
