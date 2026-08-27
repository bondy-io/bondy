%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_telemetry).

-moduledoc """
Telemetry events emitted by the `bondy_connect_sdk` client.

## `[bondy_connect, rpc, latency]`

Emitted once per settled RPC leg, in the same shape as the router's
`[bondy, rpc, latency]` event so one operator handler serves both:

- Measurements: `#{duration => non_neg_integer()}` (milliseconds).
- Metadata: `#{kind => call | invocation, procedure_uri => binary(),
  trace => #{binary() => binary()}}`.

`kind => call` is the client-observed round trip of an outbound CALL —
from the send to the terminal RESULT/ERROR the router answers with
(client-side timeouts and disconnects emit nothing). `kind =>
invocation` is a callee handler run — from worker start to the handler's
return, including a caught handler crash (a worker killed by an
INTERRUPT emits nothing).

`trace` is the call's W3C trace context as `trace_meta/1` returns it
(`#{}` when the call is untraced). Handlers run synchronously in the
emitting process, so the handler's clock at handle time is the leg's end
and `duration` locates its start — enough to reconstruct a retroactive
span.
""".

-export([rpc_latency/5]).
-export([trace_meta/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Emit the `[bondy_connect, rpc, latency]` event for a settled RPC leg.
`Outcome` is how the leg settled: `success` for a RESULT/YIELD,
`error` for a WAMP ERROR (a callee handler crash is turned into an
error reply, so it settles as `error` too). See the module doc for the
event contract.
""".
-spec rpc_latency(
    Kind :: call | invocation,
    ProcedureUri :: binary(),
    DurationMs :: integer(),
    Trace :: #{binary() => binary()},
    Outcome :: success | error
) -> ok.

rpc_latency(Kind, ProcedureUri, DurationMs, Trace, Outcome) ->
    telemetry:execute(
        [bondy_connect, rpc, latency],
        #{duration => max(0, DurationMs)},
        #{
            kind => Kind,
            procedure_uri => ProcedureUri,
            trace => Trace,
            outcome => Outcome
        }
    ).

-doc """
The W3C trace context carried by a validated CALL's options or an
INVOCATION's details (the `'_traceparent'`/`'_tracestate'`/`'_baggage'`
atom wire keys), as a map under the W3C header names — the `trace`
metadata shape of the latency event.

Per W3C, `tracestate`/`baggage` without a (binary) `traceparent` is not
a trace context and yields `#{}`; a non-binary sibling is dropped alone.
Total over any map.

A deliberate body-twin of `bondy_telemetry:trace_meta/1` — not shared
because this application does not depend on `bondy_router`.
""".
-spec trace_meta(OptsOrDetails :: map()) -> #{binary() => binary()}.

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
