%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_message_SUITE).
-include("bondy_wamp.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).

all() ->
    common:all().

groups() ->
    [{main, [parallel], common:tests(?MODULE)}].

%% =============================================================================
%% JSON
%% =============================================================================

init_per_suite(Config) ->
    _ = application:ensure_all_started(bondy_wamp),
    ok = bondy_wamp_config:init(),
    Config.

end_per_suite(_) ->
    ok.

abort_test(_) ->
    Uri = <<"com.example.foo">>,
    Details = #{bar => baz},
    Expected = #abort{reason_uri = Uri, details = Details},

    ?assertEqual(Expected, bondy_wamp_message:abort(Details, Uri)).

call_test(_) ->
    Uri = <<"com.example.foo">>,

    Opts0 = #{},
    ?assertEqual(
        #call{
            request_id = 1,
            options = Opts0,
            procedure_uri = Uri,
            args = undefined,
            kwargs = undefined
        },
        bondy_wamp_message:call(1, Opts0, Uri, [])
    ),

    Opts1 = #{ppt_scheme => <<"foo">>},
    ?assertError(
        badarg,
        bondy_wamp_message:call(1, Opts1, Uri, [], #{}),
        "We should have Args = [Payload :: binary()]"
    ),
    ?assertError(
        badarg,
        bondy_wamp_message:call(1, Opts1, Uri, [], #{a => 100}),
        "KWArgs should be undefined"
    ),
    ?assertError(
        badarg,
        bondy_wamp_message:call(1, Opts1, Uri, [1]),
        "Args should be a single binary"
    ),
    ?assertEqual(
        #call{
            request_id = 1,
            options = Opts1,
            procedure_uri = Uri,
            args = [<<>>],
            kwargs = undefined
        },
        bondy_wamp_message:call(1, Opts1, Uri, [<<>>])
    ).

yield_progress_test(_) ->
    %% The progress option is part of the YIELD options vocabulary and
    %% survives validation (both as atom and via its binary alias).
    ?assertEqual(
        #yield{
            request_id = 1,
            options = #{progress => true},
            args = [<<"chunk">>],
            kwargs = undefined
        },
        bondy_wamp_message:yield(1, #{progress => true}, [<<"chunk">>])
    ),

    ?assertEqual(
        #yield{
            request_id = 1,
            options = #{progress => true},
            args = undefined,
            kwargs = undefined
        },
        bondy_wamp_message:yield(1, #{<<"progress">> => true})
    ),

    %% Unknown options are still stripped.
    ?assertEqual(
        #yield{
            request_id = 1,
            options = #{},
            args = undefined,
            kwargs = undefined
        },
        bondy_wamp_message:yield(1, #{frobnicate => true})
    ).

result_from_progress_test(_) ->
    %% result_from/3 builds RESULT.Details from the YIELD options, so a
    %% progressive YIELD produces a RESULT with Details.progress = true.
    Yield = bondy_wamp_message:yield(
        99, #{progress => true}, [<<"chunk">>]
    ),
    Result = bondy_wamp_message:result_from(Yield, 1, Yield#yield.options),

    ?assertEqual(1, Result#result.request_id),
    ?assertEqual(true, maps:get(progress, Result#result.details)),
    ?assertEqual([<<"chunk">>], Result#result.args).
