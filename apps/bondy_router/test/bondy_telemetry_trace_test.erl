%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% `bondy_telemetry:trace_meta/1` (options/details → the `trace`
%% telemetry-metadata map) and the `[bondy, rpc, latency]` emission
%% carrying it. Pure functions plus a local telemetry attach — no node.
-module(bondy_telemetry_trace_test).

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
        bondy_telemetry:trace_meta(Opts)
    ).

trace_meta_traceparent_only_test() ->
    ?assertEqual(
        #{<<"traceparent">> => ?TP},
        bondy_telemetry:trace_meta(#{'_traceparent' => ?TP})
    ).

%% W3C rule: tracestate/baggage without a traceparent is not a context.
trace_meta_w3c_gate_test() ->
    ?assertEqual(
        #{},
        bondy_telemetry:trace_meta(#{
            '_tracestate' => ?TS, '_baggage' => ?BG
        })
    ).

trace_meta_non_binary_test() ->
    %% A non-binary traceparent voids the whole context...
    ?assertEqual(
        #{},
        bondy_telemetry:trace_meta(#{
            '_traceparent' => 42, '_tracestate' => ?TS
        })
    ),
    %% ...a non-binary sibling is dropped alone.
    ?assertEqual(
        #{<<"traceparent">> => ?TP, <<"baggage">> => ?BG},
        bondy_telemetry:trace_meta(#{
            '_traceparent' => ?TP,
            '_tracestate' => [<<"x">>],
            '_baggage' => ?BG
        })
    ).

trace_meta_untraced_test() ->
    ?assertEqual(#{}, bondy_telemetry:trace_meta(#{})),
    ?assertEqual(
        #{}, bondy_telemetry:trace_meta(#{timeout => 5000, disclose_me => true})
    ).

%% The emitted event's metadata carries kind, procedure_uri and the
%% trace map verbatim.
%% maybe_mint_trace/1: off (the default) and the sampled-out case leave
%% the map untouched; on, an absent (or non-binary — W3C invalid, may
%% restart) traceparent is replaced by a freshly minted sampled context
%% while a binary one is ALWAYS honoured, ratio or no ratio.
maybe_mint_trace_test() ->
    Opts = #{timeout => 5000},
    MintRx = "^00-[0-9a-f]{32}-[0-9a-f]{16}-01$",

    %% Default off (no config seeded): untouched. NOTE: bondy_config
    %% reads app_config's persistent_term snapshot, NOT the live app
    %% env — writes below go through bondy_config:set/2.
    ?assertEqual(Opts, bondy_telemetry:maybe_mint_trace(Opts)),

    try
        %% On, ratio 1.0: minted, other keys preserved, W3C shape, sampled,
        %% and the tracestate marker names EXACTLY the traceparent's
        %% span id (the bridge realizes the root span only on that
        %% match).
        ok = bondy_config:set(
            tracing_mint, [{enabled, true}, {ratio, 1.0}]
        ),
        Minted = bondy_telemetry:maybe_mint_trace(Opts),
        ?assertEqual(5000, maps:get(timeout, Minted)),
        TP1 = maps:get('_traceparent', Minted),
        ?assertMatch({match, _}, re:run(TP1, MintRx)),
        <<"00-", _:32/binary, "-", SpanHex:16/binary, "-01">> = TP1,
        ?assertEqual(
            <<"bondy=", SpanHex/binary>>, maps:get('_tracestate', Minted)
        ),
        %% Fresh ids per mint.
        TP2 = maps:get(
            '_traceparent', bondy_telemetry:maybe_mint_trace(Opts)
        ),
        ?assertNotEqual(TP1, TP2),

        %% A carried binary context is never re-minted.
        Carried = Opts#{'_traceparent' => ?TP},
        ?assertEqual(Carried, bondy_telemetry:maybe_mint_trace(Carried)),

        %% A non-binary traceparent counts as absent (restart the trace).
        Junk = Opts#{'_traceparent' => 42},
        ?assertMatch(
            {match, _},
            re:run(
                maps:get(
                    '_traceparent', bondy_telemetry:maybe_mint_trace(Junk)
                ),
                MintRx
            )
        ),

        %% Ratio 0.0 samples everything out: untouched.
        ok = bondy_config:set(
            tracing_mint, [{enabled, true}, {ratio, 0.0}]
        ),
        ?assertEqual(Opts, bondy_telemetry:maybe_mint_trace(Opts))
    after
        bondy_config:set(tracing_mint, [{enabled, false}])
    end.

rpc_latency_carries_trace_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Id = {?MODULE, rpc_latency_carries_trace_test},
    ok = telemetry:attach(
        Id,
        [bondy, rpc, latency],
        fun(_, Meas, Meta, _) -> Self ! {latency, Meas, Meta} end,
        undefined
    ),
    try
        Trace = #{<<"traceparent">> => ?TP},
        ok = bondy_telemetry:rpc_latency(
            call, <<"com.example.p">>, 7, Trace, error, undefined
        ),
        receive
            {latency, Meas, Meta} ->
                ?assertEqual(#{duration => 7}, Meas),
                ?assertEqual(
                    #{
                        kind => call,
                        procedure_uri => <<"com.example.p">>,
                        trace => Trace,
                        outcome => error,
                        peer_service => undefined
                    },
                    Meta
                )
        after 1000 ->
            error(latency_event_missing)
        end,

        %% A named peer (the callee's agent on an invocation leg)
        %% crosses the boundary verbatim.
        ok = bondy_telemetry:rpc_latency(
            invocation, <<"com.example.p">>, 7, Trace, success, <<"probe/1">>
        ),
        receive
            {latency, _, PeerMeta} ->
                ?assertEqual(
                    #{
                        kind => invocation,
                        procedure_uri => <<"com.example.p">>,
                        trace => Trace,
                        outcome => success,
                        peer_service => <<"probe/1">>
                    },
                    PeerMeta
                )
        after 1000 ->
            error(latency_event_missing)
        end
    after
        telemetry:detach(Id)
    end.
