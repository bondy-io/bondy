%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% `bondy_connect_telemetry:trace_meta/1` (options/details → the `trace`
%% metadata map) and the `[bondy_connect, rpc, latency]` emission
%% carrying it. Pure functions plus a local telemetry attach — no
%% connection.
-module(bondy_connect_telemetry_test).

-include_lib("eunit/include/eunit.hrl").

-define(TP, <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>).
-define(TS, <<"congo=t61rcWkgMzE">>).
-define(BG, <<"userId=alice">>).

trace_meta_full_trio_test() ->
    Opts = #{
        '_traceparent' => ?TP,
        '_tracestate' => ?TS,
        '_baggage' => ?BG,
        timeout => 5000
    },
    ?assertEqual(
        #{
            <<"traceparent">> => ?TP,
            <<"tracestate">> => ?TS,
            <<"baggage">> => ?BG
        },
        bondy_connect_telemetry:trace_meta(Opts)
    ).

trace_meta_traceparent_only_test() ->
    ?assertEqual(
        #{<<"traceparent">> => ?TP},
        bondy_connect_telemetry:trace_meta(#{'_traceparent' => ?TP})
    ).

%% W3C rule: tracestate/baggage without a traceparent is not a context.
trace_meta_w3c_gate_test() ->
    ?assertEqual(
        #{},
        bondy_connect_telemetry:trace_meta(#{
            '_tracestate' => ?TS, '_baggage' => ?BG
        })
    ).

trace_meta_non_binary_test() ->
    %% A non-binary traceparent voids the whole context...
    ?assertEqual(
        #{},
        bondy_connect_telemetry:trace_meta(#{
            '_traceparent' => 42, '_tracestate' => ?TS
        })
    ),
    %% ...a non-binary sibling is dropped alone.
    ?assertEqual(
        #{<<"traceparent">> => ?TP, <<"baggage">> => ?BG},
        bondy_connect_telemetry:trace_meta(#{
            '_traceparent' => ?TP,
            '_tracestate' => [<<"x">>],
            '_baggage' => ?BG
        })
    ).

trace_meta_untraced_test() ->
    ?assertEqual(#{}, bondy_connect_telemetry:trace_meta(#{})),
    ?assertEqual(
        #{},
        bondy_connect_telemetry:trace_meta(#{
            timeout => 5000, disclose_me => true
        })
    ).

%% The emitted event's metadata carries kind, procedure_uri and the
%% trace map verbatim.
rpc_latency_carries_trace_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Id = {?MODULE, rpc_latency_carries_trace_test},
    ok = telemetry:attach(
        Id,
        [bondy_connect, rpc, latency],
        fun(_, Meas, Meta, _) -> Self ! {latency, Meas, Meta} end,
        undefined
    ),
    try
        Trace = #{<<"traceparent">> => ?TP},
        ok = bondy_connect_telemetry:rpc_latency(
            invocation, <<"com.example.p">>, 7, Trace
        ),
        receive
            {latency, Meas, Meta} ->
                ?assertEqual(#{duration => 7}, Meas),
                ?assertEqual(
                    #{
                        kind => invocation,
                        procedure_uri => <<"com.example.p">>,
                        trace => Trace
                    },
                    Meta
                )
        after 1000 ->
            error(latency_event_missing)
        end
    after
        telemetry:detach(Id)
    end.
