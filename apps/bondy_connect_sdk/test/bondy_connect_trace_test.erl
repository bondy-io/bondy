%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Falsifiers for the explicit trace-context surface:
%%
%% - `attach/2` / `extract/1` are inverses over the wire keys, for a full
%%   and a traceparent-only context;
%% - `tracestate` and `baggage` are never surfaced without a
%%   `traceparent` (the W3C rule), and never invented;
%% - `attach(Opts, undefined)` is exactly `Opts`, and attach never
%%   disturbs unrelated option keys;
%% - `ensure_wamp_extensions/0` MERGES the client's declarations into the
%%   `wamp` environment — pre-existing entries survive, nothing is
%%   duplicated, and a second run changes nothing (both start orders when
%%   co-located with a router).
-module(bondy_connect_trace_test).

-include_lib("eunit/include/eunit.hrl").

-define(TP, <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>).
-define(TS, <<"congo=t61rcWkgMzE">>).
-define(BG, <<"userId=alice,serverNode=DF%2028">>).

-define(EXT_PATHS, [
    [extended_options, call],
    [extended_options, publish],
    [extended_details, invocation],
    [extended_details, event]
]).

attach_extract_round_trip_test() ->
    Full = #{traceparent => ?TP, tracestate => ?TS, baggage => ?BG},
    ?assertEqual(
        Full, bondy_connect_trace:extract(bondy_connect_trace:attach(#{}, Full))
    ),
    Min = #{traceparent => ?TP},
    ?assertEqual(
        Min, bondy_connect_trace:extract(bondy_connect_trace:attach(#{}, Min))
    ).

attach_test() ->
    ?assertEqual(#{}, bondy_connect_trace:attach(#{}, undefined)),
    Opts = #{timeout => 5000},
    ?assertEqual(Opts, bondy_connect_trace:attach(Opts, undefined)),
    ?assertEqual(
        #{timeout => 5000, '_traceparent' => ?TP},
        bondy_connect_trace:attach(Opts, #{traceparent => ?TP})
    ),
    %% A partial context attaches only its own keys.
    Attached = bondy_connect_trace:attach(#{}, #{
        traceparent => ?TP, baggage => ?BG
    }),
    ?assertEqual(#{'_traceparent' => ?TP, '_baggage' => ?BG}, Attached).

extract_test() ->
    ?assertEqual(undefined, bondy_connect_trace:extract(#{})),
    ?assertEqual(
        undefined, bondy_connect_trace:extract(#{procedure => <<"com.x.y">>})
    ),
    %% The W3C rule: tracestate/baggage without a traceparent are not a
    %% context.
    ?assertEqual(
        undefined,
        bondy_connect_trace:extract(#{'_tracestate' => ?TS, '_baggage' => ?BG})
    ),
    ?assertEqual(
        #{traceparent => ?TP, baggage => ?BG},
        bondy_connect_trace:extract(#{
            '_traceparent' => ?TP,
            '_baggage' => ?BG,
            procedure => <<"com.x.y">>
        })
    ).

ensure_wamp_extensions_test() ->
    ok = bondy_wamp_config:init(),
    Saved = [{P, bondy_wamp_config:get(P, [])} || P <- ?EXT_PATHS],
    try
        %% A pre-existing (router-set) entry must survive the merge.
        ok = bondy_wamp_config:set([extended_options, call], ['_routing_key']),
        ok = lists:foreach(
            fun(P) -> bondy_wamp_config:set(P, []) end, tl(?EXT_PATHS)
        ),
        ok = bondy_connect_app:ensure_wamp_extensions(),
        Expected = ['_traceparent', '_tracestate', '_baggage'],
        Call1 = bondy_wamp_config:get([extended_options, call]),
        ?assert(lists:member('_routing_key', Call1)),
        ?assert(lists:member('_deadline', Call1)),
        ok = lists:foreach(
            fun(K) -> ?assert(lists:member(K, Call1)) end, Expected
        ),
        ok = lists:foreach(
            fun(P) ->
                Keys = bondy_wamp_config:get(P),
                lists:foreach(
                    fun(K) -> ?assert(lists:member(K, Keys)) end, Expected
                )
            end,
            tl(?EXT_PATHS)
        ),
        %% Idempotent: a second run adds nothing (no duplicates).
        Before = [bondy_wamp_config:get(P) || P <- ?EXT_PATHS],
        ok = bondy_connect_app:ensure_wamp_extensions(),
        ?assertEqual(Before, [bondy_wamp_config:get(P) || P <- ?EXT_PATHS])
    after
        lists:foreach(
            fun({P, V}) -> bondy_wamp_config:set(P, V) end, Saved
        )
    end.
