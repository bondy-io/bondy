%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_trace).

-moduledoc """
Explicit W3C trace-context propagation for SDK applications —
propagation only, the SDK emits no spans.

A context is `t/0`: the W3C `traceparent`, `tracestate` and Baggage
header values, carried verbatim — neither the SDK nor the router parses
or modifies them.

Outbound, `attach/2` merges a context into the options of
`bondy_connect_client:call/5` or `publish/5`, as the `_traceparent` /
`_tracestate` / `_baggage` extension options; the router copies them
into the receiving side's INVOCATION or EVENT details. Inbound,
`extract/1` reads those keys from the `Details` map a callee or
subscriber handler receives. The two compose: a handler that calls
onward continues its inbound context with

```erlang
Handler = fun(Args, KWArgs, Details) ->
    Ctx = bondy_connect_trace:extract(Details),
    Opts = bondy_connect_trace:attach(#{}, Ctx),
    bondy_connect_client:call(Conn, Next, Args2, KWArgs2, Opts)
end
```

and when the inbound message carried no context, `extract/1` returns
`undefined` and `attach/2` is a no-op.
""".

-type t() :: #{
    traceparent := binary(),
    tracestate => binary(),
    baggage => binary()
}.

-export_type([t/0]).

-export([attach/2]).
-export([extract/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
`Opts` with `Ctx`'s fields added as the trace extension options.
`attach(Opts, undefined)` is `Opts`, so it composes with `extract/1`.
""".
-spec attach(map(), t() | undefined) -> map().

attach(Opts, undefined) when is_map(Opts) ->
    Opts;
attach(Opts, #{traceparent := TP} = Ctx) when is_map(Opts) ->
    Opts1 = Opts#{'_traceparent' => TP},
    Opts2 =
        case Ctx of
            #{tracestate := TS} -> Opts1#{'_tracestate' => TS};
            _ -> Opts1
        end,
    case Ctx of
        #{baggage := BG} -> Opts2#{'_baggage' => BG};
        _ -> Opts2
    end.

-doc """
The trace context of an INVOCATION or EVENT `Details` map, or
`undefined` when the map carries no `_traceparent` — per the W3C Trace
Context specification `tracestate` is meaningful only alongside a
`traceparent`, so neither it nor `baggage` is returned without one.
""".
-spec extract(map()) -> t() | undefined.

extract(#{'_traceparent' := TP} = Details) ->
    Ctx = #{traceparent => TP},
    Ctx1 =
        case Details of
            #{'_tracestate' := TS} -> Ctx#{tracestate => TS};
            _ -> Ctx
        end,
    case Details of
        #{'_baggage' := BG} -> Ctx1#{baggage => BG};
        _ -> Ctx1
    end;
extract(Details) when is_map(Details) ->
    undefined.
