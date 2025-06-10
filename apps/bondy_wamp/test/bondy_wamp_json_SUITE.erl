-module(bondy_wamp_json_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_wamp.hrl").
-compile(export_all).


all() ->
    [
        test_float,
        test_datetime
    ].



init_per_suite(Config) ->
    _ = application:ensure_all_started(bondy_wamp),
    ok = bondy_wamp_config:init(),
    Config.

end_per_suite(_) ->
    ok.


test_float(_) ->

    Default = [{float_format, [{decimals, 16}]}],
    ?assertEqual(bondy_wamp_json:encode(1.0), bondy_wamp_json:encode(1.0, Default)),
    ?assertEqual(bondy_wamp_json:encode(1.01), bondy_wamp_json:encode(1.01, Default)),
    ?assertEqual(bondy_wamp_json:encode(1.012), bondy_wamp_json:encode(1.012, Default)),
    ?assertEqual(bondy_wamp_json:encode(1.0123), bondy_wamp_json:encode(1.0123, Default)),
    ?assertEqual(bondy_wamp_json:encode(1.01234), bondy_wamp_json:encode(1.01234, Default)),
    ?assertEqual(<<"1.0000000000000000">>, bondy_wamp_json:encode(1.0)),
    ?assertEqual(<<"1.0100000000000000">>, bondy_wamp_json:encode(1.01)),
    ?assertEqual(<<"1.0120000000000000">>, bondy_wamp_json:encode(1.012)),
    ?assertEqual(<<"1.0123000000000000">>, bondy_wamp_json:encode(1.0123)),
    ?assertEqual(<<"1.0123400000000000">>, bondy_wamp_json:encode(1.01234)),

    Opts = [{float_format, [compact, {decimals, 4}]}],
    ?assertEqual(<<"1.0">>, bondy_wamp_json:encode(1.0, Opts)),
    ?assertEqual(<<"1.01">>, bondy_wamp_json:encode(1.01, Opts)),
    ?assertEqual(<<"1.012">>, bondy_wamp_json:encode(1.012, Opts)),
    ?assertEqual(<<"1.0123">>, bondy_wamp_json:encode(1.0123, Opts)),
    ?assertEqual(<<"1.0123">>, bondy_wamp_json:encode(1.01234, Opts)),

    Opts1 = [{float_format, [{decimals, 4}]}],
    ?assertEqual(<<"1.0000">>, bondy_wamp_json:encode(1.0, Opts1)),
    ?assertEqual(<<"1.0100">>, bondy_wamp_json:encode(1.01, Opts1)),
    ?assertEqual(<<"1.0120">>, bondy_wamp_json:encode(1.012, Opts1)),
    ?assertEqual(<<"1.0123">>, bondy_wamp_json:encode(1.0123, Opts1)),
    ?assertEqual(<<"1.0123">>, bondy_wamp_json:encode(1.01234, Opts1)),

    Opts2 = [{float_format, [{scientific, 3}]}],
    ?assertEqual(<<"1.000e+00">>, bondy_wamp_json:encode(1.0, Opts2)),
    ?assertEqual(<<"1.010e+00">>, bondy_wamp_json:encode(1.01, Opts2)),
    ?assertEqual(<<"1.012e+00">>, bondy_wamp_json:encode(1.012, Opts2)),
    ?assertEqual(<<"1.012e+00">>, bondy_wamp_json:encode(1.0123, Opts2)),
    ?assertEqual(<<"1.012e+00">>, bondy_wamp_json:encode(1.01234, Opts2)),


    ?assertError(badarg, bondy_wamp_json:encode(1.0, [{float_format, [foo]}])).


test_datetime(_) ->
    ok.


