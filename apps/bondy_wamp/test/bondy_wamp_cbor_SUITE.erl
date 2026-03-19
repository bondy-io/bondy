%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_cbor_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_wamp.hrl").
-compile(export_all).


all() ->
    [
        test_encode_basic,
        test_encode_undefined,
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


test_datetime(_) ->
    %% Test basic datetime encoding (returns datetime string)
    DT1 = {{2025, 10, 20}, {14, 30, 45}},
    Encoded1 = bondy_wamp_cbor:encode(DT1),
    %% Decode and verify
    Decoded1 = bondy_wamp_cbor:decode(Encoded1),
    ?assertEqual(<<"2025-10-20T14:30:45Z">>, Decoded1),

    %% Test datetime with fractional seconds
    DT2 = {{2025, 1, 1}, {0, 0, 12.345}},
    Encoded2 = bondy_wamp_cbor:encode(DT2),
    Decoded2 = bondy_wamp_cbor:decode(Encoded2),
    ?assertEqual(<<"2025-01-01T00:00:12.345Z">>, Decoded2),

    %% Test year padding
    DT3 = {{999, 12, 31}, {23, 59, 59}},
    Encoded3 = bondy_wamp_cbor:encode(DT3),
    Decoded3 = bondy_wamp_cbor:decode(Encoded3),
    ?assertEqual(<<"0999-12-31T23:59:59Z">>, Decoded3),

    %% Test year < 100
    DT4 = {{99, 5, 15}, {12, 0, 0}},
    Encoded4 = bondy_wamp_cbor:encode(DT4),
    Decoded4 = bondy_wamp_cbor:decode(Encoded4),
    ?assertEqual(<<"0099-05-15T12:00:00Z">>, Decoded4).


test_encode_basic(_) ->
    %% Basic types - encode and decode to verify
    ?assertEqual(1, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(1))),
    ?assertEqual(-42, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(-42))),
    ?assertEqual(
        <<"hello">>,
        bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(<<"hello">>))
    ),
    ?assertEqual(true, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(true))),
    ?assertEqual(false, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(false))),

    %% Arrays
    ?assertEqual([], bondy_wamp_cbor:decode(bondy_wamp_cbor:encode([]))),
    ?assertEqual([1, 2, 3], bondy_wamp_cbor:decode(bondy_wamp_cbor:encode([1, 2, 3]))),
    ?assertEqual(
        [<<"a">>, <<"b">>, <<"c">>],
        bondy_wamp_cbor:decode(bondy_wamp_cbor:encode([<<"a">>, <<"b">>, <<"c">>]))
    ),

    %% Objects (maps)
    ?assertEqual(#{}, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(#{}))),
    Obj = #{<<"key">> => <<"value">>},
    ?assertEqual(Obj, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(Obj))),

    %% Nested structures
    Nested = [1, #{<<"nested">> => [2, 3]}, 4],
    ?assertEqual(Nested, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(Nested))),

    %% Floats
    ?assertEqual(1.5, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(1.5))),
    ?assertEqual(3.14159, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(3.14159))).


test_encode_undefined(_) ->
    %% undefined should encode to null
    ?assertEqual(undefined, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(undefined))),

    %% undefined in arrays
    ?assertEqual(
        [1, undefined, 3],
        bondy_wamp_cbor:decode(bondy_wamp_cbor:encode([1, undefined, 3]))
    ),

    %% undefined in maps
    Map = #{<<"key">> => undefined},
    ?assertEqual(Map, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(Map))).


test_decode_basic(_) ->
    %% CBOR uses binary format, so we test by encoding then decoding
    %% Basic types
    ?assertEqual(1, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(1))),
    ?assertEqual(-42, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(-42))),
    ?assertEqual(<<"hello">>, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(<<"hello">>))),
    ?assertEqual(true, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(true))),
    ?assertEqual(false, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(false))),
    ?assertEqual(undefined, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(undefined))),

    %% Arrays
    ?assertEqual([], bondy_wamp_cbor:decode(bondy_wamp_cbor:encode([]))),
    ?assertEqual([1, 2, 3], bondy_wamp_cbor:decode(bondy_wamp_cbor:encode([1, 2, 3]))),
    ?assertEqual(
        [<<"a">>, <<"b">>, <<"c">>],
        bondy_wamp_cbor:decode(bondy_wamp_cbor:encode([<<"a">>, <<"b">>, <<"c">>]))
    ),

    %% Objects
    ?assertEqual(#{}, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(#{}))),
    ?assertEqual(
        #{<<"key">> => <<"value">>},
        bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(#{<<"key">> => <<"value">>}))
    ),

    %% Nested structures
    ?assertEqual(
        [1, #{<<"nested">> => [2, 3]}, 4],
        bondy_wamp_cbor:decode(bondy_wamp_cbor:encode([1, #{<<"nested">> => [2, 3]}, 4]))
    ).


test_decode_with_opts(_) ->
    %% Test with custom decoders
    Encoded = bondy_wamp_cbor:encode(undefined),
    Opts = [{decoders, #{null => null_atom}}],
    ?assertEqual(null_atom, bondy_wamp_cbor:decode(Encoded, Opts)),

    EncodedArray = bondy_wamp_cbor:encode([1, undefined, 3]),
    ?assertEqual([1, null_atom, 3], bondy_wamp_cbor:decode(EncodedArray, Opts)),

    %% Default decoder should return undefined for null
    ?assertEqual(undefined, bondy_wamp_cbor:decode(Encoded)),
    ?assertEqual([1, undefined, 3], bondy_wamp_cbor:decode(EncodedArray)).


test_try_decode(_) ->
    %% Successful decode
    ?assertEqual({ok, 1}, bondy_wamp_cbor:try_decode(bondy_wamp_cbor:encode(1))),
    ?assertEqual(
        {ok, [1, 2, 3]},
        bondy_wamp_cbor:try_decode(bondy_wamp_cbor:encode([1, 2, 3]))
    ),
    ?assertEqual(
        {ok, #{<<"key">> => <<"value">>}},
        bondy_wamp_cbor:try_decode(bondy_wamp_cbor:encode(#{<<"key">> => <<"value">>}))
    ),

    %% Failed decode - invalid CBOR
    {error, _} = bondy_wamp_cbor:try_decode(<<255, 255, 255>>),
    {error, _} = bondy_wamp_cbor:try_decode(<<>>),

    %% With options
    Opts = [{decoders, #{null => my_null}}],
    ?assertEqual(
        {ok, my_null},
        bondy_wamp_cbor:try_decode(bondy_wamp_cbor:encode(undefined), Opts)
    ).


test_key_value_list(_) ->
    %% Key-value lists (proplists) should be encoded as objects
    KVList = [{<<"key1">>, <<"value1">>}, {<<"key2">>, <<"value2">>}],
    Result = bondy_wamp_cbor:encode(KVList),

    %% Decode back and verify
    Decoded = bondy_wamp_cbor:decode(Result),
    ?assertEqual(#{<<"key1">> => <<"value1">>, <<"key2">> => <<"value2">>}, Decoded),

    %% Nested key-value lists
    NestedKV = [{<<"outer">>, [{<<"inner">>, <<"value">>}]}],
    NestedResult = bondy_wamp_cbor:encode(NestedKV),
    NestedDecoded = bondy_wamp_cbor:decode(NestedResult),
    ?assertEqual(#{<<"outer">> => #{<<"inner">> => <<"value">>}}, NestedDecoded).


test_check_duplicate_keys(_) ->
    %% Without duplicate checking (default) - duplicates are allowed
    KVList = [{<<"key">>, 1}, {<<"key">>, 2}],
    Result1 = bondy_wamp_cbor:encode(KVList, []),
    ?assert(is_binary(Result1)),

    %% With duplicate checking - should throw error on duplicates
    Opts = [{check_duplicate_keys, true}],
    ?assertError({duplicate_key, _}, bondy_wamp_cbor:encode(KVList, Opts)),

    %% With duplicate checking but no duplicates - should succeed
    UniqueKVList = [{<<"key1">>, 1}, {<<"key2">>, 2}],
    Result2 = bondy_wamp_cbor:encode(UniqueKVList, Opts),
    ?assert(is_binary(Result2)),

    %% Verify option validation
    ?assertError(badarg, bondy_wamp_cbor:encode([], [{check_duplicate_keys, not_boolean}])).


test_decode_head(_) ->
    %% Decode first 2 elements of a WAMP message
    CBOR = bondy_wamp_cbor:encode([1, 2, 3, 4, 5]),
    {Elements, Tail} = bondy_wamp_cbor:decode_head(CBOR, 2),
    ?assertEqual([1, 2], Elements),
    %% Tail is raw CBOR elements without array wrapper
    TailDecoded = bondy_wamp_cbor:decode_tail(Tail),
    ?assertEqual([3, 4, 5], TailDecoded),

    %% Decode first 3 elements
    CBOR2 = bondy_wamp_cbor:encode([<<"hello">>, 42, true, undefined, [1, 2, 3]]),
    {Elements2, Tail2} = bondy_wamp_cbor:decode_head(CBOR2, 3),
    ?assertEqual([<<"hello">>, 42, true], Elements2),
    TailDecoded2 = bondy_wamp_cbor:decode_tail(Tail2),
    ?assertEqual([undefined, [1, 2, 3]], TailDecoded2),

    %% Decode all elements (should return just the list)
    CBOR3 = bondy_wamp_cbor:encode([1, 2, 3]),
    Result3 = bondy_wamp_cbor:decode_head(CBOR3, 3),
    ?assertEqual([1, 2, 3], Result3),

    %% Nested structures in head
    CBOR4 = bondy_wamp_cbor:encode([#{<<"key">> => <<"value">>}, [1, 2], 3, 4]),
    {Elements4, Tail4} = bondy_wamp_cbor:decode_head(CBOR4, 2),
    ?assertEqual([#{<<"key">> => <<"value">>}, [1, 2]], Elements4),
    TailDecoded4 = bondy_wamp_cbor:decode_tail(Tail4),
    ?assertEqual([3, 4], TailDecoded4).


test_decode_tail(_) ->
    %% Get a tail from decode_head and decode it
    CBOR = bondy_wamp_cbor:encode([1, 2, 3, 4, 5]),
    {_, Tail1} = bondy_wamp_cbor:decode_head(CBOR, 2),
    Result1 = bondy_wamp_cbor:decode_tail(Tail1),
    ?assertEqual([3, 4, 5], Result1),

    %% Empty tail
    Result2 = bondy_wamp_cbor:decode_tail(<<>>),
    ?assertEqual([], Result2),

    %% Tail with undefined
    CBOR3 = bondy_wamp_cbor:encode([1, undefined, 5]),
    {_, Tail3} = bondy_wamp_cbor:decode_head(CBOR3, 1),
    Result3 = bondy_wamp_cbor:decode_tail(Tail3),
    ?assertEqual([undefined, 5], Result3),

    %% Tail with nested array
    CBOR4 = bondy_wamp_cbor:encode([1, undefined, [1, 2, 3]]),
    {_, Tail4} = bondy_wamp_cbor:decode_head(CBOR4, 1),
    Result4 = bondy_wamp_cbor:decode_tail(Tail4),
    ?assertEqual([undefined, [1, 2, 3]], Result4),

    %% With custom options
    Opts = [{decoders, #{null => custom_null}}],
    CBOR5 = bondy_wamp_cbor:encode([1, undefined, 2]),
    {_, Tail5} = bondy_wamp_cbor:decode_head(CBOR5, 1),
    Result5 = bondy_wamp_cbor:decode_tail(Tail5, Opts),
    ?assertEqual([custom_null, 2], Result5).


test_encode_with_tail(_) ->
    %% Get tail from decode_head, encode new elements with it
    CBOR = bondy_wamp_cbor:encode([1, 2, 3, 4, 5]),
    {_, Tail1} = bondy_wamp_cbor:decode_head(CBOR, 2),
    Result1 = bondy_wamp_cbor:encode_with_tail([10, 20], Tail1),
    ?assertEqual([10, 20, 3, 4, 5], bondy_wamp_cbor:decode(Result1)),

    %% Empty tail
    Result2 = bondy_wamp_cbor:encode_with_tail([1, 2, 3], <<>>),
    ?assertEqual([1, 2, 3], bondy_wamp_cbor:decode(Result2)),

    %% Complex elements with tail
    CBOR3 = bondy_wamp_cbor:encode([1, 2, 3]),
    {_, Tail3} = bondy_wamp_cbor:decode_head(CBOR3, 1),
    Result3 = bondy_wamp_cbor:encode_with_tail([#{<<"key">> => <<"value">>}], Tail3),
    ?assertEqual([#{<<"key">> => <<"value">>}, 2, 3], bondy_wamp_cbor:decode(Result3)),

    %% Single element with tail
    CBOR4 = bondy_wamp_cbor:encode([10, 20, 30, 40]),
    {_, Tail4} = bondy_wamp_cbor:decode_head(CBOR4, 2),
    Result4 = bondy_wamp_cbor:encode_with_tail([1], Tail4),
    ?assertEqual([1, 30, 40], bondy_wamp_cbor:decode(Result4)).


test_validate_opts(_) ->
    %% Valid check_duplicate_keys
    ?assertEqual(
        [{check_duplicate_keys, true}],
        bondy_wamp_cbor:validate_opts([{check_duplicate_keys, true}])
    ),
    ?assertEqual(
        [{check_duplicate_keys, false}],
        bondy_wamp_cbor:validate_opts([{check_duplicate_keys, false}])
    ),

    %% Invalid options should error
    ?assertError(
        badarg,
        bondy_wamp_cbor:validate_opts([{check_duplicate_keys, not_bool}])
    ),

    %% Unknown options should pass through (for extensibility)
    ?assertEqual(
        [{some_option, some_value}],
        bondy_wamp_cbor:validate_opts([{some_option, some_value}])
    ).


test_roundtrip(_) ->
    %% Test encode/decode roundtrip for various data structures

    %% Basic types
    ?assertEqual(1, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(1))),
    ?assertEqual(
        <<"text">>, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(<<"text">>))
    ),
    ?assertEqual(true, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(true))),
    ?assertEqual(false, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(false))),
    ?assertEqual(
        undefined, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(undefined))
    ),

    %% Floats
    ?assertEqual(1.5, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(1.5))),
    ?assertEqual(-3.14, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(-3.14))),

    %% Arrays
    List = [1, 2, 3, <<"hello">>, true, undefined],
    ?assertEqual(List, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(List))),

    %% Maps
    Map = #{<<"key1">> => 1, <<"key2">> => <<"value">>, <<"key3">> => true},
    ?assertEqual(Map, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(Map))),

    %% Nested structures
    Nested = [
        1,
        #{<<"a">> => [2, 3, #{<<"b">> => 4}]},
        [5, 6],
        undefined
    ],
    ?assertEqual(Nested, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(Nested))),

    %% Partial encode/decode roundtrip
    FullArray = [1, 2, 3, 4, 5],
    Encoded = bondy_wamp_cbor:encode(FullArray),
    {Head, Tail} = bondy_wamp_cbor:decode_head(Encoded, 2),
    ?assertEqual([1, 2], Head),
    TailDecoded = bondy_wamp_cbor:decode_tail(Tail),
    ?assertEqual(FullArray, Head ++ TailDecoded),

    %% Encode with tail roundtrip
    {Head2, Tail2} = bondy_wamp_cbor:decode_head(bondy_wamp_cbor:encode([10, 20, 30, 40]), 2),
    Encoded2 = bondy_wamp_cbor:encode_with_tail(Head2, Tail2),
    ?assertEqual([10, 20, 30, 40], bondy_wamp_cbor:decode(Encoded2)),

    %% Large integers
    LargeInt = 9007199254740993,
    ?assertEqual(LargeInt, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(LargeInt))),

    %% Binary data
    BinData = <<1, 2, 3, 4, 5, 255, 254, 253>>,
    ?assertEqual(BinData, bondy_wamp_cbor:decode(bondy_wamp_cbor:encode(BinData))).


test_error_cases(_) ->
    %% Invalid CBOR should fail
    ?assertError(_, bondy_wamp_cbor:decode(<<255, 255, 255>>)),

    %% decode_head with invalid input (not an array)
    MapEncoded = bondy_wamp_cbor:encode(#{}),
    ?assertError(_, bondy_wamp_cbor:decode_head(MapEncoded, 1)),

    IntEncoded = bondy_wamp_cbor:encode(42),
    ?assertError(_, bondy_wamp_cbor:decode_head(IntEncoded, 1)),

    %% decode_head with invalid count
    ArrayEncoded = bondy_wamp_cbor:encode([1, 2]),
    ?assertError(_, bondy_wamp_cbor:decode_head(ArrayEncoded, -1)),
    ?assertError(_, bondy_wamp_cbor:decode_head(ArrayEncoded, 0)),

    %% Invalid encode options
    ?assertError(
        badarg, bondy_wamp_cbor:encode(#{}, [{check_duplicate_keys, invalid}])
    ).
