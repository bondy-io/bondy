%%--------------------------------------------------------------------
%% @doc CBOR (RFC 8949) test suite
%%
%% Contains RFC 8949 Appendix A test vectors and comprehensive tests.
%% @end
%%--------------------------------------------------------------------

-module(bondy_cbor_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% RFC 8949 Appendix A Test Vectors
%%====================================================================

%% Section: Integers

integer_0_test() ->
    ?assertEqual(<<16#00>>, iolist_to_binary(bondy_cbor:encode(0))),
    ?assertEqual(0, bondy_cbor:decode(<<16#00>>)).

integer_1_test() ->
    ?assertEqual(<<16#01>>, iolist_to_binary(bondy_cbor:encode(1))),
    ?assertEqual(1, bondy_cbor:decode(<<16#01>>)).

integer_10_test() ->
    ?assertEqual(<<16#0A>>, iolist_to_binary(bondy_cbor:encode(10))),
    ?assertEqual(10, bondy_cbor:decode(<<16#0A>>)).

integer_23_test() ->
    ?assertEqual(<<16#17>>, iolist_to_binary(bondy_cbor:encode(23))),
    ?assertEqual(23, bondy_cbor:decode(<<16#17>>)).

integer_24_test() ->
    ?assertEqual(<<16#18, 16#18>>, iolist_to_binary(bondy_cbor:encode(24))),
    ?assertEqual(24, bondy_cbor:decode(<<16#18, 16#18>>)).

integer_25_test() ->
    ?assertEqual(<<16#18, 16#19>>, iolist_to_binary(bondy_cbor:encode(25))),
    ?assertEqual(25, bondy_cbor:decode(<<16#18, 16#19>>)).

integer_100_test() ->
    ?assertEqual(<<16#18, 16#64>>, iolist_to_binary(bondy_cbor:encode(100))),
    ?assertEqual(100, bondy_cbor:decode(<<16#18, 16#64>>)).

integer_1000_test() ->
    ?assertEqual(<<16#19, 16#03, 16#E8>>, iolist_to_binary(bondy_cbor:encode(1000))),
    ?assertEqual(1000, bondy_cbor:decode(<<16#19, 16#03, 16#E8>>)).

integer_1000000_test() ->
    ?assertEqual(<<16#1A, 16#00, 16#0F, 16#42, 16#40>>, iolist_to_binary(bondy_cbor:encode(1000000))),
    ?assertEqual(1000000, bondy_cbor:decode(<<16#1A, 16#00, 16#0F, 16#42, 16#40>>)).

integer_1000000000000_test() ->
    ?assertEqual(<<16#1B, 16#00, 16#00, 16#00, 16#E8, 16#D4, 16#A5, 16#10, 16#00>>,
                 iolist_to_binary(bondy_cbor:encode(1000000000000))),
    ?assertEqual(1000000000000,
                 bondy_cbor:decode(<<16#1B, 16#00, 16#00, 16#00, 16#E8, 16#D4, 16#A5, 16#10, 16#00>>)).

integer_max_uint64_test() ->
    MaxU64 = 18446744073709551615,
    ?assertEqual(<<16#1B, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF>>,
                 iolist_to_binary(bondy_cbor:encode(MaxU64))),
    ?assertEqual(MaxU64,
                 bondy_cbor:decode(<<16#1B, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF>>)).

%% Bignums (tag 2)
bignum_positive_test() ->
    %% 18446744073709551616 (2^64)
    BigNum = 18446744073709551616,
    Encoded = iolist_to_binary(bondy_cbor:encode(BigNum)),
    ?assertEqual(BigNum, bondy_cbor:decode(Encoded)).

%% Negative integers
negative_1_test() ->
    ?assertEqual(<<16#20>>, iolist_to_binary(bondy_cbor:encode(-1))),
    ?assertEqual(-1, bondy_cbor:decode(<<16#20>>)).

negative_10_test() ->
    ?assertEqual(<<16#29>>, iolist_to_binary(bondy_cbor:encode(-10))),
    ?assertEqual(-10, bondy_cbor:decode(<<16#29>>)).

negative_100_test() ->
    ?assertEqual(<<16#38, 16#63>>, iolist_to_binary(bondy_cbor:encode(-100))),
    ?assertEqual(-100, bondy_cbor:decode(<<16#38, 16#63>>)).

negative_1000_test() ->
    ?assertEqual(<<16#39, 16#03, 16#E7>>, iolist_to_binary(bondy_cbor:encode(-1000))),
    ?assertEqual(-1000, bondy_cbor:decode(<<16#39, 16#03, 16#E7>>)).

%% Negative bignum (tag 3)
bignum_negative_test() ->
    %% -18446744073709551617 (-2^64 - 1)
    BigNeg = -18446744073709551617,
    Encoded = iolist_to_binary(bondy_cbor:encode(BigNeg)),
    ?assertEqual(BigNeg, bondy_cbor:decode(Encoded)).

%%====================================================================
%% Section: Floats
%%====================================================================

float_0_0_test() ->
    %% 0.0 in double precision
    Encoded = iolist_to_binary(bondy_cbor:encode(0.0)),
    ?assertEqual(0.0, bondy_cbor:decode(Encoded)).

float_neg_0_0_test() ->
    %% -0.0 in double precision
    Encoded = iolist_to_binary(bondy_cbor:encode(-0.0)),
    Decoded = bondy_cbor:decode(Encoded),
    ?assertEqual(-0.0, Decoded).

float_1_0_test() ->
    Encoded = iolist_to_binary(bondy_cbor:encode(1.0)),
    ?assertEqual(1.0, bondy_cbor:decode(Encoded)).

float_1_1_test() ->
    Encoded = iolist_to_binary(bondy_cbor:encode(1.1)),
    ?assert(abs(1.1 - bondy_cbor:decode(Encoded)) < 0.0001).

float_1_5_test() ->
    Encoded = iolist_to_binary(bondy_cbor:encode(1.5)),
    ?assertEqual(1.5, bondy_cbor:decode(Encoded)).

float_100000_0_test() ->
    Encoded = iolist_to_binary(bondy_cbor:encode(100000.0)),
    ?assertEqual(100000.0, bondy_cbor:decode(Encoded)).

float_3_4028234663852886e38_test() ->
    %% Large float
    F = 3.4028234663852886e+38,
    Encoded = iolist_to_binary(bondy_cbor:encode(F)),
    ?assertEqual(F, bondy_cbor:decode(Encoded)).

float_1_0e300_test() ->
    Encoded = iolist_to_binary(bondy_cbor:encode(1.0e+300)),
    ?assertEqual(1.0e+300, bondy_cbor:decode(Encoded)).

float_neg_4_1_test() ->
    Encoded = iolist_to_binary(bondy_cbor:encode(-4.1)),
    ?assert(abs(-4.1 - bondy_cbor:decode(Encoded)) < 0.0001).

%% Half-precision decoding
half_float_0_test() ->
    %% Half-precision 0.0
    ?assertEqual(0.0, bondy_cbor:decode(<<16#F9, 16#00, 16#00>>)).

half_float_neg_0_test() ->
    %% Half-precision -0.0
    ?assertEqual(-0.0, bondy_cbor:decode(<<16#F9, 16#80, 16#00>>)).

half_float_1_0_test() ->
    %% Half-precision 1.0
    ?assertEqual(1.0, bondy_cbor:decode(<<16#F9, 16#3C, 16#00>>)).

half_float_1_5_test() ->
    %% Half-precision 1.5
    ?assertEqual(1.5, bondy_cbor:decode(<<16#F9, 16#3E, 16#00>>)).

half_float_65504_test() ->
    %% Half-precision max normal value
    ?assertEqual(65504.0, bondy_cbor:decode(<<16#F9, 16#7B, 16#FF>>)).

half_float_subnormal_test() ->
    %% Half-precision smallest subnormal (5.960464477539063e-8)
    Decoded = bondy_cbor:decode(<<16#F9, 16#00, 16#01>>),
    ?assert(abs(5.960464477539063e-8 - Decoded) < 1.0e-15).

%% Single-precision decoding
single_float_100000_test() ->
    %% Single-precision 100000.0
    ?assertEqual(100000.0, bondy_cbor:decode(<<16#FA, 16#47, 16#C3, 16#50, 16#00>>)).

%% Special floats - returned as atoms since Erlang doesn't support IEEE 754 special values
float_infinity_test() ->
    ?assertEqual(infinity, bondy_cbor:decode(<<16#F9, 16#7C, 16#00>>)).

float_neg_infinity_test() ->
    ?assertEqual(neg_infinity, bondy_cbor:decode(<<16#F9, 16#FC, 16#00>>)).

float_nan_test() ->
    ?assertEqual(nan, bondy_cbor:decode(<<16#F9, 16#7E, 16#00>>)).

%% Round-trip special floats
special_float_roundtrip_test() ->
    ?assertEqual(<<16#F9, 16#7C, 16#00>>, iolist_to_binary(bondy_cbor:encode(infinity))),
    ?assertEqual(<<16#F9, 16#FC, 16#00>>, iolist_to_binary(bondy_cbor:encode(neg_infinity))),
    ?assertEqual(<<16#F9, 16#7E, 16#00>>, iolist_to_binary(bondy_cbor:encode(nan))).

%%====================================================================
%% Section: Simple Values
%%====================================================================

simple_false_test() ->
    ?assertEqual(<<16#F4>>, iolist_to_binary(bondy_cbor:encode(false))),
    ?assertEqual(false, bondy_cbor:decode(<<16#F4>>)).

simple_true_test() ->
    ?assertEqual(<<16#F5>>, iolist_to_binary(bondy_cbor:encode(true))),
    ?assertEqual(true, bondy_cbor:decode(<<16#F5>>)).

simple_null_test() ->
    ?assertEqual(<<16#F6>>, iolist_to_binary(bondy_cbor:encode(null))),
    ?assertEqual(null, bondy_cbor:decode(<<16#F6>>)).

simple_undefined_test() ->
    ?assertEqual(<<16#F7>>, iolist_to_binary(bondy_cbor:encode(undefined))),
    ?assertEqual(undefined, bondy_cbor:decode(<<16#F7>>)).

simple_16_test() ->
    %% Simple value 16 (unassigned)
    ?assertEqual({simple, 16}, bondy_cbor:decode(<<16#F0>>)).

simple_255_test() ->
    %% Simple value 255 (unassigned)
    ?assertEqual({simple, 255}, bondy_cbor:decode(<<16#F8, 16#FF>>)).

%%====================================================================
%% Section: Byte Strings
%%====================================================================

bytes_empty_test() ->
    ?assertEqual(<<16#40>>, iolist_to_binary(bondy_cbor:encode(<<>>))),
    ?assertEqual(<<>>, bondy_cbor:decode(<<16#40>>)).

bytes_4_test() ->
    Bytes = <<16#01, 16#02, 16#03, 16#04>>,
    ?assertEqual(<<16#44, 16#01, 16#02, 16#03, 16#04>>,
                 iolist_to_binary(bondy_cbor:encode(Bytes))),
    ?assertEqual(Bytes, bondy_cbor:decode(<<16#44, 16#01, 16#02, 16#03, 16#04>>)).

%% Indefinite-length byte string
bytes_indefinite_test() ->
    %% h'0102030405' encoded as indefinite chunks
    CBOR = <<16#5F, 16#42, 16#01, 16#02, 16#43, 16#03, 16#04, 16#05, 16#FF>>,
    ?assertEqual(<<16#01, 16#02, 16#03, 16#04, 16#05>>, bondy_cbor:decode(CBOR)).

%%====================================================================
%% Section: Text Strings
%%====================================================================

text_empty_test() ->
    ?assertEqual(<<16#60>>, iolist_to_binary(bondy_cbor:encode({text, <<>>}))),
    ?assertEqual(<<>>, bondy_cbor:decode(<<16#60>>)).

text_a_test() ->
    ?assertEqual(<<16#61, $a>>, iolist_to_binary(bondy_cbor:encode({text, <<"a">>}))),
    ?assertEqual(<<"a">>, bondy_cbor:decode(<<16#61, $a>>)).

text_ietf_test() ->
    ?assertEqual(<<16#64, $I, $E, $T, $F>>,
                 iolist_to_binary(bondy_cbor:encode({text, <<"IETF">>}))),
    ?assertEqual(<<"IETF">>, bondy_cbor:decode(<<16#64, "IETF">>)).

text_backslash_quote_test() ->
    %% "\"\\"
    ?assertEqual(<<"\"\\">>, bondy_cbor:decode(<<16#62, $", $\\>>)).

text_unicode_test() ->
    %% "\u00fc" (ü)
    ?assertEqual(<<16#C3, 16#BC>>, bondy_cbor:decode(<<16#62, 16#C3, 16#BC>>)).

text_unicode_4byte_test() ->
    %% Chinese character (U+6C34, water)
    ?assertEqual(<<16#E6, 16#B0, 16#B4>>,
                 bondy_cbor:decode(<<16#63, 16#E6, 16#B0, 16#B4>>)).

text_emoji_test() ->
    %% "\ud800\udd51" (U+10151)
    ?assertEqual(<<16#F0, 16#90, 16#85, 16#91>>,
                 bondy_cbor:decode(<<16#64, 16#F0, 16#90, 16#85, 16#91>>)).

%% Indefinite-length text string
text_indefinite_test() ->
    %% "streaming" encoded as indefinite chunks
    CBOR = <<16#7F, 16#65, "strea", 16#64, "ming", 16#FF>>,
    ?assertEqual(<<"streaming">>, bondy_cbor:decode(CBOR)).

%% Atom encoding (as text string)
atom_encoding_test() ->
    Encoded = iolist_to_binary(bondy_cbor:encode(hello)),
    ?assertEqual(<<"hello">>, bondy_cbor:decode(Encoded)).

%%====================================================================
%% Section: Arrays
%%====================================================================

array_empty_test() ->
    ?assertEqual(<<16#80>>, iolist_to_binary(bondy_cbor:encode([]))),
    ?assertEqual([], bondy_cbor:decode(<<16#80>>)).

array_123_test() ->
    ?assertEqual(<<16#83, 16#01, 16#02, 16#03>>,
                 iolist_to_binary(bondy_cbor:encode([1, 2, 3]))),
    ?assertEqual([1, 2, 3], bondy_cbor:decode(<<16#83, 16#01, 16#02, 16#03>>)).

array_nested_test() ->
    %% [1, [2, 3], [4, 5]]
    Expected = [1, [2, 3], [4, 5]],
    CBOR = <<16#83, 16#01, 16#82, 16#02, 16#03, 16#82, 16#04, 16#05>>,
    ?assertEqual(CBOR, iolist_to_binary(bondy_cbor:encode(Expected))),
    ?assertEqual(Expected, bondy_cbor:decode(CBOR)).

array_25_elements_test() ->
    %% [1, 2, 3, ..., 25]
    List = lists:seq(1, 25),
    CBOR = <<16#98, 16#19,  % array(25)
             16#01, 16#02, 16#03, 16#04, 16#05, 16#06, 16#07, 16#08, 16#09, 16#0A,
             16#0B, 16#0C, 16#0D, 16#0E, 16#0F, 16#10, 16#11, 16#12, 16#13, 16#14,
             16#15, 16#16, 16#17, 16#18, 16#18, 16#18, 16#19>>,
    ?assertEqual(List, bondy_cbor:decode(CBOR)).

%% Indefinite-length array
array_indefinite_test() ->
    CBOR = <<16#9F, 16#01, 16#02, 16#03, 16#FF>>,
    ?assertEqual([1, 2, 3], bondy_cbor:decode(CBOR)).

array_indefinite_nested_test() ->
    %% [_ 1, [2, 3], [_ 4, 5]]
    CBOR = <<16#9F, 16#01, 16#82, 16#02, 16#03, 16#9F, 16#04, 16#05, 16#FF, 16#FF>>,
    ?assertEqual([1, [2, 3], [4, 5]], bondy_cbor:decode(CBOR)).

%%====================================================================
%% Section: Maps
%%====================================================================

map_empty_test() ->
    ?assertEqual(<<16#A0>>, iolist_to_binary(bondy_cbor:encode(#{}))),
    ?assertEqual(#{}, bondy_cbor:decode(<<16#A0>>)).

map_simple_test() ->
    %% {1: 2, 3: 4}
    Map = #{1 => 2, 3 => 4},
    Encoded = iolist_to_binary(bondy_cbor:encode(Map)),
    ?assertEqual(Map, bondy_cbor:decode(Encoded)).

map_string_keys_test() ->
    %% {"a": 1, "b": [2, 3]}
    CBOR = <<16#A2, 16#61, $a, 16#01, 16#61, $b, 16#82, 16#02, 16#03>>,
    Expected = #{<<"a">> => 1, <<"b">> => [2, 3]},
    ?assertEqual(Expected, bondy_cbor:decode(CBOR)).

map_mixed_keys_test() ->
    %% {"a": "A", "b": "B", "c": "C", "d": "D", "e": "E"}
    CBOR = <<16#A5, 16#61, $a, 16#61, $A,
                    16#61, $b, 16#61, $B,
                    16#61, $c, 16#61, $C,
                    16#61, $d, 16#61, $D,
                    16#61, $e, 16#61, $E>>,
    Expected = #{<<"a">> => <<"A">>,
                 <<"b">> => <<"B">>,
                 <<"c">> => <<"C">>,
                 <<"d">> => <<"D">>,
                 <<"e">> => <<"E">>},
    ?assertEqual(Expected, bondy_cbor:decode(CBOR)).

%% Indefinite-length map
map_indefinite_test() ->
    %% {_ "a": 1, "b": [_ 2, 3]}
    CBOR = <<16#BF, 16#61, $a, 16#01, 16#61, $b, 16#9F, 16#02, 16#03, 16#FF, 16#FF>>,
    Expected = #{<<"a">> => 1, <<"b">> => [2, 3]},
    ?assertEqual(Expected, bondy_cbor:decode(CBOR)).

%%====================================================================
%% Section: Tags
%%====================================================================

tag_datetime_string_test() ->
    %% Tag 0: "2013-03-21T20:04:00Z"
    CBOR = <<16#C0, 16#74, "2013-03-21T20:04:00Z">>,
    {tag, 0, DateTime} = bondy_cbor:decode(CBOR),
    ?assertEqual(<<"2013-03-21T20:04:00Z">>, DateTime).

tag_datetime_epoch_test() ->
    %% Tag 1: 1363896240 (epoch time)
    CBOR = <<16#C1, 16#1A, 16#51, 16#4B, 16#67, 16#B0>>,
    {tag, 1, Epoch} = bondy_cbor:decode(CBOR),
    ?assertEqual(1363896240, Epoch).

tag_datetime_epoch_float_test() ->
    %% Tag 1: 1363896240.5 (epoch time with fraction)
    CBOR = <<16#C1, 16#FB, 16#41, 16#D4, 16#52, 16#D9, 16#EC, 16#20, 16#00, 16#00>>,
    {tag, 1, Epoch} = bondy_cbor:decode(CBOR),
    ?assert(abs(1363896240.5 - Epoch) < 0.001).

tag_positive_bignum_test() ->
    %% Tag 2: h'010000000000000000' (2^64)
    CBOR = <<16#C2, 16#49, 16#01, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00>>,
    ?assertEqual(18446744073709551616, bondy_cbor:decode(CBOR)).

tag_negative_bignum_test() ->
    %% Tag 3: h'010000000000000000' (-(2^64) - 1)
    CBOR = <<16#C3, 16#49, 16#01, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00>>,
    ?assertEqual(-18446744073709551617, bondy_cbor:decode(CBOR)).

tag_encoded_cbor_test() ->
    %% Tag 24: embedded CBOR encoding of [1, 2, 3]
    InnerCBOR = iolist_to_binary(bondy_cbor:encode([1, 2, 3])),
    Encoded = iolist_to_binary(bondy_cbor:encode({tag, 24, InnerCBOR})),
    {tag, 24, DecodedInner} = bondy_cbor:decode(Encoded),
    ?assertEqual([1, 2, 3], bondy_cbor:decode(DecodedInner)).

tag_uri_test() ->
    %% Tag 32: "http://www.example.com"
    CBOR = <<16#D8, 16#20, 16#76, "http://www.example.com">>,
    {tag, 32, URI} = bondy_cbor:decode(CBOR),
    ?assertEqual(<<"http://www.example.com">>, URI).

tag_self_describe_test() ->
    %% Tag 55799: self-describing CBOR (should unwrap)
    CBOR = <<16#D9, 16#D9, 16#F7, 16#45, 16#64, 16#49, 16#45, 16#54, 16#46>>,
    ?assertEqual(<<"dIETF">>, bondy_cbor:decode(CBOR)).

tag_custom_encode_test() ->
    %% Custom tag encoding
    Encoded = iolist_to_binary(bondy_cbor:encode({tag, 100, <<"test">>})),
    {tag, 100, Value} = bondy_cbor:decode(Encoded),
    ?assertEqual(<<"test">>, Value).

%%====================================================================
%% Round-trip Tests
%%====================================================================

roundtrip_test_() ->
    Values = [
        0, 1, 23, 24, 255, 256, 65535, 65536,
        -1, -24, -25, -256, -65536,
        0.0, 1.0, -1.0, 3.14159,
        true, false, null, undefined,
        <<>>, <<1, 2, 3>>, <<"hello">>,
        [], [1], [1, 2, 3],
        [[1, 2], [3, 4]],
        #{}, #{1 => 2}, #{<<"a">> => 1, <<"b">> => 2},
        {tag, 100, <<"data">>}
    ],
    [?_assertEqual(V, bondy_cbor:decode(iolist_to_binary(bondy_cbor:encode(V)))) ||
     V <- Values].

%% Text strings encode with {text, Binary} but decode to plain binaries
text_string_roundtrip_test() ->
    Encoded = iolist_to_binary(bondy_cbor:encode({text, <<"world">>})),
    ?assertEqual(<<"world">>, bondy_cbor:decode(Encoded)).

roundtrip_complex_test() ->
    Complex = #{
        <<"name">> => {text, <<"Test">>},
        <<"values">> => [1, 2.5, true, null],
        <<"nested">> => #{<<"x">> => 100, <<"y">> => -100}
    },
    Encoded = iolist_to_binary(bondy_cbor:encode(Complex)),
    Decoded = bondy_cbor:decode(Encoded),
    ?assertEqual(maps:get(<<"values">>, Complex), maps:get(<<"values">>, Decoded)),
    ?assertEqual(maps:get(<<"nested">>, Complex), maps:get(<<"nested">>, Decoded)).

%%====================================================================
%% Deterministic Encoding Tests
%%====================================================================

deterministic_integers_test() ->
    %% Shortest encoding
    ?assertEqual(<<16#00>>, bondy_cbor:encode_deterministic(0)),
    ?assertEqual(<<16#17>>, bondy_cbor:encode_deterministic(23)),
    ?assertEqual(<<16#18, 16#18>>, bondy_cbor:encode_deterministic(24)).

deterministic_map_order_test() ->
    %% Keys should be sorted by encoded bytes
    Map = #{10 => <<"ten">>, 1 => <<"one">>, 100 => <<"hundred">>},
    Encoded = bondy_cbor:encode_deterministic(Map),
    %% Verify determinism - same encoding every time
    ?assertEqual(Encoded, bondy_cbor:encode_deterministic(Map)),
    %% Decode and verify content
    Decoded = bondy_cbor:decode(Encoded),
    ?assertEqual(Map, Decoded).

deterministic_string_keys_test() ->
    %% String keys sorted lexicographically by encoded bytes
    Map = #{<<"b">> => 2, <<"a">> => 1, <<"aa">> => 3},
    E1 = bondy_cbor:encode_deterministic(Map),
    E2 = bondy_cbor:encode_deterministic(Map),
    ?assertEqual(E1, E2).

deterministic_float_shortest_test() ->
    %% 0.0 can be encoded as half-precision
    E1 = bondy_cbor:encode_deterministic(0.0),
    ?assertEqual(<<16#F9, 16#00, 16#00>>, E1),

    %% 1.0 can be encoded as half-precision
    E2 = bondy_cbor:encode_deterministic(1.0),
    ?assertEqual(<<16#F9, 16#3C, 16#00>>, E2),

    %% 1.5 can be encoded as half-precision
    E3 = bondy_cbor:encode_deterministic(1.5),
    ?assertEqual(<<16#F9, 16#3E, 16#00>>, E3).

%%====================================================================
%% Diagnostic Notation Tests
%%====================================================================

format_integer_test() ->
    ?assertEqual("0", lists:flatten(bondy_cbor:format(0))),
    ?assertEqual("1", lists:flatten(bondy_cbor:format(1))),
    ?assertEqual("-1", lists:flatten(bondy_cbor:format(-1))).

format_simple_test() ->
    ?assertEqual("true", lists:flatten(bondy_cbor:format(true))),
    ?assertEqual("false", lists:flatten(bondy_cbor:format(false))),
    ?assertEqual("null", lists:flatten(bondy_cbor:format(null))),
    ?assertEqual("undefined", lists:flatten(bondy_cbor:format(undefined))).

format_bytes_test() ->
    ?assertEqual("h''", lists:flatten(bondy_cbor:format(<<>>))),
    ?assertEqual("h'0102'", lists:flatten(bondy_cbor:format(<<1, 2>>))).

format_text_test() ->
    ?assertEqual("\"hello\"", lists:flatten(bondy_cbor:format({text, <<"hello">>}))).

format_array_test() ->
    ?assertEqual("[]", lists:flatten(bondy_cbor:format([]))),
    ?assertEqual("[1, 2, 3]", lists:flatten(bondy_cbor:format([1, 2, 3]))).

format_tag_test() ->
    ?assertEqual("100(h'01')", lists:flatten(bondy_cbor:format({tag, 100, <<1>>}))).

%%====================================================================
%% Custom Decoder Tests
%%====================================================================

custom_decoder_null_test() ->
    Decoders = #{null => nil},
    {Value, _, <<>>} = bondy_cbor:decode(<<16#F6>>, ok, Decoders),
    ?assertEqual(nil, Value).

custom_decoder_undefined_test() ->
    Decoders = #{undefined => none},
    {Value, _, <<>>} = bondy_cbor:decode(<<16#F7>>, ok, Decoders),
    ?assertEqual(none, Value).

%%====================================================================
%% Error Handling Tests
%%====================================================================

error_incomplete_test() ->
    ?assertError(incomplete, bondy_cbor:decode(<<>>)),
    ?assertError(incomplete, bondy_cbor:decode(<<16#18>>)),
    ?assertError(incomplete, bondy_cbor:decode(<<16#44, 1, 2>>)).

error_invalid_utf8_test() ->
    %% Text string with invalid UTF-8 bytes.
    %% UTF-8 validation is skipped for performance (msgpack-style).
    %% The decoder returns the bytes as-is; validation can be done at app level.
    ?assertEqual(<<16#FF, 16#FE>>, bondy_cbor:decode(<<16#62, 16#FF, 16#FE>>)).

error_reserved_ai_test() ->
    %% Additional info 28-30 are reserved
    ?assertError({invalid_ai, 28}, bondy_cbor:decode(<<16#1C>>)).

error_badarg_test() ->
    ?assertError({badarg, _}, bondy_cbor:encode(fun() -> ok end)).

%%====================================================================
%% Edge Cases
%%====================================================================

boundary_uint8_test() ->
    %% 255 is max uint8
    ?assertEqual(<<16#18, 16#FF>>, iolist_to_binary(bondy_cbor:encode(255))),
    ?assertEqual(255, bondy_cbor:decode(<<16#18, 16#FF>>)).

boundary_uint16_test() ->
    %% 65535 is max uint16
    ?assertEqual(<<16#19, 16#FF, 16#FF>>, iolist_to_binary(bondy_cbor:encode(65535))),
    ?assertEqual(65535, bondy_cbor:decode(<<16#19, 16#FF, 16#FF>>)).

boundary_uint32_test() ->
    %% 4294967295 is max uint32
    ?assertEqual(<<16#1A, 16#FF, 16#FF, 16#FF, 16#FF>>,
                 iolist_to_binary(bondy_cbor:encode(4294967295))),
    ?assertEqual(4294967295, bondy_cbor:decode(<<16#1A, 16#FF, 16#FF, 16#FF, 16#FF>>)).

boundary_negative_test() ->
    %% -256 requires 2 bytes
    ?assertEqual(<<16#38, 16#FF>>, iolist_to_binary(bondy_cbor:encode(-256))),
    ?assertEqual(-256, bondy_cbor:decode(<<16#38, 16#FF>>)).

deeply_nested_test() ->
    %% 10 levels of nesting
    Nested = lists:foldl(fun(N, Acc) -> [N, Acc] end, [], lists:seq(1, 10)),
    Encoded = iolist_to_binary(bondy_cbor:encode(Nested)),
    ?assertEqual(Nested, bondy_cbor:decode(Encoded)).

large_array_test() ->
    %% Array with 1000 elements
    Large = lists:seq(1, 1000),
    Encoded = iolist_to_binary(bondy_cbor:encode(Large)),
    ?assertEqual(Large, bondy_cbor:decode(Encoded)).

large_map_test() ->
    %% Map with 100 entries
    Large = maps:from_list([{N, N * 2} || N <- lists:seq(1, 100)]),
    Encoded = iolist_to_binary(bondy_cbor:encode(Large)),
    ?assertEqual(Large, bondy_cbor:decode(Encoded)).

mixed_key_types_test() ->
    %% Map with different key types
    Map = #{1 => <<"int">>, <<"a">> => <<"string">>, true => <<"bool">>},
    Encoded = iolist_to_binary(bondy_cbor:encode(Map)),
    ?assertEqual(Map, bondy_cbor:decode(Encoded)).
