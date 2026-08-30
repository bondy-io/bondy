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

%% The cluster-forward hop marker: a traced options map gains a fresh
%% `bondyhop=<span-id>` tracestate vendor entry (front, per the W3C
%% update rule), replacing any it already carries — a re-forward is a
%% new hop. An untraced map is untouched: no trace, no hop span.
maybe_hop_trace_test() ->
    %% No traceparent, non-binary traceparent: untouched.
    ?assertEqual(#{}, bondy_telemetry:maybe_hop_trace(#{})),
    Invalid = #{'_traceparent' => 42, '_tracestate' => ?TS},
    ?assertEqual(Invalid, bondy_telemetry:maybe_hop_trace(Invalid)),

    %% Traced, no tracestate: the marker is the whole tracestate; every
    %% other key is preserved.
    Bare = #{'_traceparent' => ?TP, timeout => 5000},
    #{'_tracestate' := TS1} = Stamped1 = bondy_telemetry:maybe_hop_trace(Bare),
    <<"bondyhop=", Hop1:16/binary>> = TS1,
    ?assertMatch({match, _}, re:run(Hop1, "^[0-9a-f]{16}$")),
    ?assertEqual(Bare, maps:remove('_tracestate', Stamped1)),

    %% Traced with a caller tracestate: prepended, caller entry intact.
    Carried = #{'_traceparent' => ?TP, '_tracestate' => ?TS},
    #{'_tracestate' := TS2} = bondy_telemetry:maybe_hop_trace(Carried),
    <<"bondyhop=", _:16/binary, ",", Rest2/binary>> = TS2,
    ?assertEqual(?TS, Rest2),

    %% An existing hop entry is REPLACED, never accumulated.
    Rehop = #{
        '_traceparent' => ?TP,
        '_tracestate' => <<"bondyhop=deadbeefdeadbeef,", ?TS/binary>>
    },
    #{'_tracestate' := TS3} = bondy_telemetry:maybe_hop_trace(Rehop),
    <<"bondyhop=", Hop3:16/binary, ",", Rest3/binary>> = TS3,
    ?assertNotEqual(<<"deadbeefdeadbeef">>, Hop3),
    ?assertEqual(?TS, Rest3),

    %% Fresh id per stamp.
    #{'_tracestate' := TS4} = bondy_telemetry:maybe_hop_trace(Bare),
    ?assertNotEqual(TS1, TS4).

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

%% =============================================================================
%% `trace_id_of/1` — the CORRELATION handle, as opposed to `trace_meta/1`,
%% which carries the header onward for PROPAGATION. An alarm stores this one.
%% =============================================================================

trace_id_of_extracts_the_trace_id_test() ->
    ?assertEqual(
        <<"0af7651916cd43dd8448eb211c80319c">>,
        bondy_telemetry:trace_id_of(#{'_traceparent' => ?TP})
    ).

%% EVENT.Details is the shape the retained-message producer actually reads:
%% `bondy_broker:make_event_details/3` passes `?WAMP_TRACE_ATTRS` through
%% verbatim, so the same parser serves both.
trace_id_of_reads_event_details_test() ->
    Details = #{
        '_traceparent' => ?TP,
        '_tracestate' => <<"bondy=b7ad6b7169203331">>,
        topic => <<"com.example.t">>
    },
    ?assertEqual(
        <<"0af7651916cd43dd8448eb211c80319c">>,
        bondy_telemetry:trace_id_of(Details)
    ).

no_traceparent_is_undefined_test() ->
    ?assertEqual(undefined, bondy_telemetry:trace_id_of(#{})),
    ?assertEqual(
        undefined, bondy_telemetry:trace_id_of(#{topic => <<"com.example.t">>})
    ).

%% W3C: an all-zero trace id is invalid. Accepting it would hand an operator a
%% correlation handle that resolves to nothing while looking real.
all_zero_trace_id_is_rejected_test() ->
    TP = <<"00-00000000000000000000000000000000-00f067aa0ba902b7-01">>,
    ?assertEqual(
        undefined, bondy_telemetry:trace_id_of(#{'_traceparent' => TP})
    ).

%% A malformed header must not become a plausible-looking handle. Uppercase is
%% rejected too: W3C fixes lowercase hex, and a case-varying id would not match
%% the same trace in Tempo.
malformed_traceparent_is_undefined_test() ->
    Bad = [
        <<"00-tooshort-00f067aa0ba902b7-01">>,
        <<"00-0AF7651916CD43DD8448EB211C80319C-b7ad6b7169203331-01">>,
        <<"00-0af7651916cd43dd8448eb211c80319c">>,
        <<"garbage">>,
        <<>>
    ],
    lists:foreach(
        fun(TP) ->
            ?assertEqual(
                undefined,
                bondy_telemetry:trace_id_of(#{'_traceparent' => TP}),
                TP
            )
        end,
        Bad
    ).

%% A non-binary value cannot be parsed and must not crash the caller — this is
%% read on a path that is already reporting a fault.
non_binary_traceparent_is_undefined_test() ->
    ?assertEqual(
        undefined,
        bondy_telemetry:trace_id_of(#{'_traceparent' => not_a_binary})
    ).
