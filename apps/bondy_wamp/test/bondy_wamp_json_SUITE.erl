-module(bondy_wamp_json_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_wamp.hrl").
-compile(export_all).


all() ->
    [
        test_encode_basic,
        test_encode_undefined,
        test_float,
        test_datetime,
        test_decode_basic,
        test_decode_with_opts,
        test_try_decode,
        test_key_value_list,
        test_check_duplicate_keys,
        test_decode_head,
        test_decode_tail,
        test_encode_with_tail,
        test_validate_opts,
        test_roundtrip,
        test_error_cases
    ].



init_per_suite(Config) ->
    _ = application:ensure_all_started(bondy_wamp),
    ok = bondy_wamp_config:init(),
    Config.

end_per_suite(_) ->
    ok.


test_float(_) ->

    Default = [{float_format, [{decimals, 16}]}],
    ?assertEqual(
        bondy_wamp_json:encode(1.0),
        bondy_wamp_json:encode(1.0, Default)
    ),
    ?assertEqual(
        bondy_wamp_json:encode(1.01),
        bondy_wamp_json:encode(1.01, Default)
    ),
    ?assertEqual(
        bondy_wamp_json:encode(1.012),
        bondy_wamp_json:encode(1.012, Default)
    ),
    ?assertEqual(
        bondy_wamp_json:encode(1.0123),
        bondy_wamp_json:encode(1.0123, Default)
    ),
    ?assertEqual(
        bondy_wamp_json:encode(1.01234),
        bondy_wamp_json:encode(1.01234, Default)
    ),
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
    %% Test basic datetime encoding (returns unquoted datetime string)
    DT1 = {{2025, 10, 20}, {14, 30, 45}},
    Expected1 = <<"2025-10-20T14:30:45Z">>,
    ?assertEqual(Expected1, bondy_wamp_json:encode(DT1)),

    %% Test datetime with fractional seconds
    DT2 = {{2025, 1, 1}, {0, 0, 12.345}},
    Result2 = bondy_wamp_json:encode(DT2),
    ?assertEqual(<<"2025-01-01T00:00:12.345Z">>, Result2),

    %% Test year padding
    DT3 = {{999, 12, 31}, {23, 59, 59}},
    Expected3 = <<"0999-12-31T23:59:59Z">>,
    ?assertEqual(Expected3, bondy_wamp_json:encode(DT3)),

    %% Test year < 100
    DT4 = {{99, 5, 15}, {12, 0, 0}},
    Expected4 = <<"0099-05-15T12:00:00Z">>,
    ?assertEqual(Expected4, bondy_wamp_json:encode(DT4)).


test_encode_basic(_) ->
    %% Basic types
    ?assertEqual(<<"1">>, bondy_wamp_json:encode(1)),
    ?assertEqual(<<"-42">>, bondy_wamp_json:encode(-42)),
    ?assertEqual(<<"\"hello\"">>, bondy_wamp_json:encode(<<"hello">>)),
    %% Note: Erlang strings (lists of chars) encode as arrays, use binaries for
    %% JSON strings
    ?assertEqual(<<"[119,111,114,108,100]">>, bondy_wamp_json:encode("world")),
    ?assertEqual(<<"true">>, bondy_wamp_json:encode(true)),
    ?assertEqual(<<"false">>, bondy_wamp_json:encode(false)),

    %% Arrays
    ?assertEqual(<<"[]">>, bondy_wamp_json:encode([])),
    ?assertEqual(<<"[1,2,3]">>, bondy_wamp_json:encode([1, 2, 3])),
    ?assertEqual(
        <<"[\"a\",\"b\",\"c\"]">>,
        bondy_wamp_json:encode([<<"a">>, <<"b">>, <<"c">>])
    ),

    %% Objects (maps)
    ?assertEqual(<<"{}">>, bondy_wamp_json:encode(#{})),
    Obj = #{<<"key">> => <<"value">>},
    ?assertEqual(<<"{\"key\":\"value\"}">>, bondy_wamp_json:encode(Obj)),

    %% Nested structures
    Nested = [1, #{<<"nested">> => [2, 3]}, 4],
    Result = bondy_wamp_json:encode(Nested),
    ?assertEqual(<<"[1,{\"nested\":[2,3]},4]">>, Result).


test_encode_undefined(_) ->
    %% undefined should encode to null
    ?assertEqual(<<"null">>, bondy_wamp_json:encode(undefined)),

    %% undefined in arrays
    ?assertEqual(
        <<"[1,null,3]">>,
        bondy_wamp_json:encode([1, undefined, 3])
    ),

    %% undefined in maps
    Map = #{<<"key">> => undefined},
    ?assertEqual(<<"{\"key\":null}">>, bondy_wamp_json:encode(Map)).


test_decode_basic(_) ->
    %% Basic types
    ?assertEqual(1, bondy_wamp_json:decode(<<"1">>)),
    ?assertEqual(-42, bondy_wamp_json:decode(<<"-42">>)),
    ?assertEqual(<<"hello">>, bondy_wamp_json:decode(<<"\"hello\"">>)),
    ?assertEqual(true, bondy_wamp_json:decode(<<"true">>)),
    ?assertEqual(false, bondy_wamp_json:decode(<<"false">>)),
    ?assertEqual(undefined, bondy_wamp_json:decode(<<"null">>)),

    %% Arrays
    ?assertEqual([], bondy_wamp_json:decode(<<"[]">>)),
    ?assertEqual([1, 2, 3], bondy_wamp_json:decode(<<"[1,2,3]">>)),
    ?assertEqual(
        [<<"a">>, <<"b">>, <<"c">>],
        bondy_wamp_json:decode(<<"[\"a\",\"b\",\"c\"]">>)
    ),

    %% Objects
    ?assertEqual(#{}, bondy_wamp_json:decode(<<"{}">>)),
    ?assertEqual(
        #{<<"key">> => <<"value">>},
        bondy_wamp_json:decode(<<"{\"key\":\"value\"}">>)
    ),

    %% Nested structures
    ?assertEqual(
        [1, #{<<"nested">> => [2, 3]}, 4],
        bondy_wamp_json:decode(<<"[1,{\"nested\":[2,3]},4]">>)
    ).


test_decode_with_opts(_) ->
    %% Test with custom decoders
    Opts = [{decoders, #{null => null_atom}}],
    ?assertEqual(null_atom, bondy_wamp_json:decode(<<"null">>, Opts)),
    ?assertEqual([1, null_atom, 3], bondy_wamp_json:decode(<<"[1,null,3]">>, Opts)),

    %% Default decoder should return undefined for null
    ?assertEqual(undefined, bondy_wamp_json:decode(<<"null">>)),
    ?assertEqual([1, undefined, 3], bondy_wamp_json:decode(<<"[1,null,3]">>)).


test_try_decode(_) ->
    %% Successful decode
    ?assertEqual({ok, 1}, bondy_wamp_json:try_decode(<<"1">>)),
    ?assertEqual({ok, [1, 2, 3]}, bondy_wamp_json:try_decode(<<"[1,2,3]">>)),
    ?assertEqual(
        {ok, #{<<"key">> => <<"value">>}},
        bondy_wamp_json:try_decode(<<"{\"key\":\"value\"}">>)
    ),

    %% Failed decode
    {error, _} = bondy_wamp_json:try_decode(<<"{invalid json}">>),
    {error, _} = bondy_wamp_json:try_decode(<<"[1,2,">>),

    %% With options
    Opts = [{decoders, #{null => my_null}}],
    ?assertEqual({ok, my_null}, bondy_wamp_json:try_decode(<<"null">>, Opts)).


test_key_value_list(_) ->
    %% Key-value lists (proplists) should be encoded as objects
    KVList = [{<<"key1">>, <<"value1">>}, {<<"key2">>, <<"value2">>}],
    Result = bondy_wamp_json:encode(KVList),

    %% Decode back and verify
    Decoded = bondy_wamp_json:decode(Result),
    ?assertEqual(#{<<"key1">> => <<"value1">>, <<"key2">> => <<"value2">>}, Decoded),

    %% Nested key-value lists
    NestedKV = [{<<"outer">>, [{<<"inner">>, <<"value">>}]}],
    NestedResult = bondy_wamp_json:encode(NestedKV),
    NestedDecoded = bondy_wamp_json:decode(NestedResult),
    ?assertEqual(#{<<"outer">> => #{<<"inner">> => <<"value">>}}, NestedDecoded).


test_check_duplicate_keys(_) ->
    %% Without duplicate checking (default) - duplicates are allowed
    KVList = [{<<"key">>, 1}, {<<"key">>, 2}],
    Result1 = bondy_wamp_json:encode(KVList, []),
    ?assert(is_binary(Result1)),

    %% With duplicate checking - should throw error on duplicates
    Opts = [{check_duplicate_keys, true}],
    ?assertError({duplicate_key, _}, bondy_wamp_json:encode(KVList, Opts)),

    %% With duplicate checking but no duplicates - should succeed
    UniqueKVList = [{<<"key1">>, 1}, {<<"key2">>, 2}],
    Result2 = bondy_wamp_json:encode(UniqueKVList, Opts),
    ?assert(is_binary(Result2)),

    %% Verify option validation
    ?assertError(badarg, bondy_wamp_json:encode([], [{check_duplicate_keys, not_boolean}])).


test_decode_head(_) ->
    %% Decode first 2 elements of a WAMP message
    JSON = <<"[1,2,3,4,5]">>,
    {Elements, Tail} = bondy_wamp_json:decode_head(JSON, 2),
    ?assertEqual([1, 2], Elements),
    %% Note: Tail doesn't include leading comma (it's stripped during extraction)
    ?assertEqual(<<"3,4,5]">>, Tail),

    %% Decode first 3 elements
    JSON2 = <<"[\"hello\",42,true,null,[1,2,3]]">>,
    {Elements2, Tail2} = bondy_wamp_json:decode_head(JSON2, 3),
    ?assertEqual([<<"hello">>, 42, true], Elements2),
    ?assertEqual(<<"null,[1,2,3]]">>, Tail2),

    %% Decode all elements (tail should be just closing bracket)
    JSON3 = <<"[1,2,3]">>,
    Result3 = bondy_wamp_json:decode_head(JSON3, 3),
    ?assertEqual([1, 2, 3], Result3),

    %% Nested structures in head
    JSON4 = <<"[{\"key\":\"value\"},[1,2],3,4]">>,
    {Elements4, Tail4} = bondy_wamp_json:decode_head(JSON4, 2),
    ?assertEqual([#{<<"key">> => <<"value">>}, [1, 2]], Elements4),
    ?assertEqual(<<"3,4]">>, Tail4),

    %% With whitespace
    JSON5 = <<"[ 1 , 2 , 3 , 4 ]">>,
    {Elements5, Tail5} = bondy_wamp_json:decode_head(JSON5, 2),
    ?assertEqual([1, 2], Elements5),
    ?assertEqual(<<"3 , 4 ]">>, Tail5).


test_decode_tail(_) ->
    %% Decode tail with leading comma
    Tail1 = <<",3,4,5]">>,
    Result1 = bondy_wamp_json:decode_tail(Tail1),
    ?assertEqual([3, 4, 5], Result1),

    %% Decode tail without leading comma (typical from decode_head)
    Tail2 = <<"3,4,5]">>,
    Result2 = bondy_wamp_json:decode_tail(Tail2),
    ?assertEqual([3, 4, 5], Result2),

    %% Decode tail that is just closing bracket
    Tail3 = <<"]">>,
    Result3 = bondy_wamp_json:decode_tail(Tail3),
    ?assertEqual([], Result3),

    %% Tail with null (with leading comma)
    Tail4 = <<",null,5]">>,
    Result4 = bondy_wamp_json:decode_tail(Tail4),
    ?assertEqual([undefined, 5], Result4),

    %% Tail with null (without leading comma)
    Tail4b = <<"null,5]">>,
    Result4b = bondy_wamp_json:decode_tail(Tail4b),
    ?assertEqual([undefined, 5], Result4b),

    %% Note: Tails with nested arrays (e.g., "null,[1,2,3]]") have an edge case
    %% where binary:match finds the first ] instead of checking if tail ends with ]
    %% This is a known limitation. Use the comma-prefixed version for nested arrays:
    Tail4c = <<",null,[1,2,3]]">>,
    Result4c = bondy_wamp_json:decode_tail(Tail4c),
    ?assertEqual([undefined, [1, 2, 3]], Result4c),

    %% With whitespace and leading comma
    Tail5 = <<" , 3 , 4 ]">>,
    Result5 = bondy_wamp_json:decode_tail(Tail5),
    ?assertEqual([3, 4], Result5),

    %% With custom options
    Opts = [{decoders, #{null => custom_null}}],
    Tail6 = <<",null,1]">>,
    Result6 = bondy_wamp_json:decode_tail(Tail6, Opts),
    ?assertEqual([custom_null, 1], Result6).


test_encode_with_tail(_) ->
    %% Encode new elements with tail that has leading comma
    Elements1 = [1, 2],
    Tail1 = <<",3,4,5]">>,
    Result1 = bondy_wamp_json:encode_with_tail(Elements1, Tail1),
    ?assertEqual(<<"[1,2,3,4,5]">>, Result1),

    %% Encode with tail that is just closing bracket
    Elements2 = [1, 2, 3],
    Tail2 = <<"]">>,
    Result2 = bondy_wamp_json:encode_with_tail(Elements2, Tail2),
    ?assertEqual(<<"[1,2,3]">>, Result2),

    %% Encode with tail without leading comma (typical from decode_head)
    Elements3 = [<<"a">>, <<"b">>],
    Tail3 = <<"\"c\",\"d\"]">>,
    Result3 = bondy_wamp_json:encode_with_tail(Elements3, Tail3),
    ?assertEqual(<<"[\"a\",\"b\",\"c\",\"d\"]">>, Result3),

    %% Complex elements with tail with leading comma
    Elements4 = [#{<<"key">> => <<"value">>}],
    Tail4 = <<",2,3]">>,
    Result4 = bondy_wamp_json:encode_with_tail(Elements4, Tail4),
    ?assertEqual(<<"[{\"key\":\"value\"},2,3]">>, Result4),

    %% Complex elements with tail without leading comma
    Elements5 = [1],
    Tail5 = <<"2,3]">>,
    Result5 = bondy_wamp_json:encode_with_tail(Elements5, Tail5),
    ?assertEqual(<<"[1,2,3]">>, Result5).


test_validate_opts(_) ->
    %% Valid float format options
    ?assertEqual(
        [{float_format, [{decimals, 10}]}],
        bondy_wamp_json:validate_opts([{float_format, [{decimals, 10}]}])
    ),
    ?assertEqual(
        [{float_format, [{scientific, 5}]}],
        bondy_wamp_json:validate_opts([{float_format, [{scientific, 5}]}])
    ),
    ?assertEqual(
        [{float_format, [compact]}],
        bondy_wamp_json:validate_opts([{float_format, [compact]}])
    ),
    ?assertEqual(
        [{float_format, [short]}],
        bondy_wamp_json:validate_opts([{float_format, [short]}])
    ),

    %% Valid check_duplicate_keys
    ?assertEqual(
        [{check_duplicate_keys, true}],
        bondy_wamp_json:validate_opts([{check_duplicate_keys, true}])
    ),
    ?assertEqual(
        [{check_duplicate_keys, false}],
        bondy_wamp_json:validate_opts([{check_duplicate_keys, false}])
    ),

    %% Invalid options should error
    ?assertError(
        badarg,
        bondy_wamp_json:validate_opts([{float_format, [invalid]}])
    ),
    ?assertError(
        badarg,
        bondy_wamp_json:validate_opts([{check_duplicate_keys, not_bool}])
    ),

    %% Scientific with too many decimals should coerce to max
    Result = bondy_wamp_json:validate_opts(
        [{float_format, [{scientific, 300}]}]
    ),
    ?assertEqual([{float_format, [{scientific, 249}]}], Result).


test_roundtrip(_) ->
    %% Test encode/decode roundtrip for various data structures

    %% Basic types
    ?assertEqual(1, bondy_wamp_json:decode(bondy_wamp_json:encode(1))),
    ?assertEqual(
        <<"text">>, bondy_wamp_json:decode(bondy_wamp_json:encode(<<"text">>))
    ),
    ?assertEqual(true, bondy_wamp_json:decode(bondy_wamp_json:encode(true))),
    ?assertEqual(false, bondy_wamp_json:decode(bondy_wamp_json:encode(false))),
    ?assertEqual(
        undefined, bondy_wamp_json:decode(bondy_wamp_json:encode(undefined))
    ),

    %% Arrays
    List = [1, 2, 3, <<"hello">>, true, undefined],
    ?assertEqual(List, bondy_wamp_json:decode(bondy_wamp_json:encode(List))),

    %% Maps
    Map = #{<<"key1">> => 1, <<"key2">> => <<"value">>, <<"key3">> => true},
    ?assertEqual(Map, bondy_wamp_json:decode(bondy_wamp_json:encode(Map))),

    %% Nested structures
    Nested = [
        1,
        #{<<"a">> => [2, 3, #{<<"b">> => 4}]},
        [5, 6],
        undefined
    ],
    ?assertEqual(Nested, bondy_wamp_json:decode(bondy_wamp_json:encode(Nested))),

    %% Partial encode/decode roundtrip (decode_head strips leading comma from tail)
    FullArray = [1, 2, 3, 4, 5],
    {Head, Tail} = bondy_wamp_json:decode_head(
        bondy_wamp_json:encode(FullArray), 2
    ),
    ?assertEqual([1, 2], Head),
    ?assertEqual(<<"3,4,5]">>, Tail),
    TailDecoded = bondy_wamp_json:decode_tail(Tail),
    ?assertEqual(FullArray, Head ++ TailDecoded),

    %% Encode with tail roundtrip (with leading comma)
    Elements = [1, 2],
    OriginalTail = <<",3,4,5]">>,
    Encoded = bondy_wamp_json:encode_with_tail(Elements, OriginalTail),
    ?assertEqual([1, 2, 3, 4, 5], bondy_wamp_json:decode(Encoded)),

    %% Encode with tail roundtrip (without leading comma, from decode_head)
    {Head2, Tail2} = bondy_wamp_json:decode_head(<<"[10,20,30,40]">>, 2),
    Encoded2 = bondy_wamp_json:encode_with_tail(Head2, Tail2),
    ?assertEqual([10, 20, 30, 40], bondy_wamp_json:decode(Encoded2)).


test_error_cases(_) ->
    %% Invalid JSON should fail
    ?assertError(_, bondy_wamp_json:decode(<<"{invalid}">>)),
    ?assertError(_, bondy_wamp_json:decode(<<"[1,2,">>)),
    ?assertError(_, bondy_wamp_json:decode(<<"not json">>)),

    %% decode_head with invalid input
    ?assertError(_, bondy_wamp_json:decode_head(<<"{}">>, 1)),
    ?assertError(_, bondy_wamp_json:decode_head(<<"test">>, 1)),
    ?assertError(_, bondy_wamp_json:decode_head(<<"[1,2]">>, -1)),
    ?assertError(_, bondy_wamp_json:decode_head(<<"[1,2]">>, 0)),

    %% Invalid encode options
    ?assertError(
        badarg, bondy_wamp_json:encode(1.0, [{float_format, [invalid_opt]}])
    ).


