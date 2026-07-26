%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_details_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_wamp.hrl").

progressive_calls_test_() ->
    {setup,
        fun() ->
            _ = application:ensure_all_started(bondy_wamp),
            ok
        end,
        fun(_) -> ok end, [
            {"caller: progressive_calls requires call_canceling",
                fun caller_pairing/0},
            {"callee: progressive_calls requires call_canceling",
                fun callee_pairing/0},
            {"no progressive_calls => no pairing required",
                fun no_pairing_when_absent/0},
            {"CALL.Options.progress is a valid option",
                fun call_progress_option/0}
        ]}.

%% A role that announces `progressive_calls` MUST also announce `call_canceling`
%% (a streamed call has to be cancellable mid-stream), else HELLO is rejected —
%% mirroring the WAMP pairing rule for the results feature.
caller_pairing() ->
    Paired = hello(caller, #{progressive_calls => true, call_canceling => true}),
    ?assertMatch(#{roles := _}, bondy_wamp_details:new(hello, Paired)),

    Unpaired = hello(caller, #{progressive_calls => true}),
    ?assertError(
        #{code := invalid_feature_request},
        bondy_wamp_details:new(hello, Unpaired)
    ).

callee_pairing() ->
    Paired = hello(callee, #{progressive_calls => true, call_canceling => true}),
    ?assertMatch(#{roles := _}, bondy_wamp_details:new(hello, Paired)),

    Unpaired = hello(callee, #{progressive_calls => true}),
    ?assertError(
        #{code := invalid_feature_request},
        bondy_wamp_details:new(hello, Unpaired)
    ).

%% A role without `progressive_calls` is unaffected by the rule even without
%% `call_canceling`.
no_pairing_when_absent() ->
    Details = hello(caller, #{caller_identification => true}),
    ?assertMatch(#{roles := _}, bondy_wamp_details:new(hello, Details)).

%% The new CALL.Options.progress marker (a progressive-call chunk) validates and
%% is carried through, rather than being stripped as an unknown option.
call_progress_option() ->
    M = bondy_wamp_message:call(1, #{progress => true}, <<"com.example.p">>),
    ?assertEqual(true, maps:get(progress, M#call.options)).

%% @private
hello(Role, Features) ->
    #{roles => #{Role => #{features => Features}}}.
