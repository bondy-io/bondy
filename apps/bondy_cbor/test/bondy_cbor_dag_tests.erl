%% =============================================================================
%% SPDX-FileCopyrightText: 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%%--------------------------------------------------------------------
%% @doc DAG-CBOR (IPLD) profile test suite for `bondy_cbor'.
%%
%% Exercises the `dag' profile against:
%%
%% <ul>
%%   <li>the upstream IPLD cross-codec fixtures (round-trip every fixture and
%%       assert the re-encoded bytes are identical - the canonical-form test);
%%       see {@link //bondy_cbor/dag_cbor_fixtures/README.md};</li>
%%   <li>the data-model representation (links, strings, bytes, map keys);</li>
%%   <li>the strictness rules a conformant decoder must enforce.</li>
%% </ul>
%% @end
%%--------------------------------------------------------------------

-module(bondy_cbor_dag_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Cross-codec fixtures (round-trip / canonical-form)
%%====================================================================

%% Sanity check: the vendored fixtures are actually found and loaded.
fixtures_present_test() ->
    ?assert(length(fixture_files()) >= 128).

%% One test per fixture: decode the canonical DAG-CBOR bytes, re-encode them and
%% assert the result is byte-for-byte identical. This validates the decoder
%% (it must accept every fixture) and the encoder (it must reproduce the
%% canonical form, including map key ordering and minimal/64-bit encodings).
fixtures_roundtrip_test_() ->
    [
        {fixture_name(File), fun() -> roundtrip_fixture(File) end}
     || File <- fixture_files()
    ].

roundtrip_fixture(File) ->
    {ok, Bytes} = file:read_file(File),
    Decoded = bondy_cbor:decode(Bytes, dag),
    Reencoded = bondy_cbor:encode(Decoded, dag),
    ?assertEqual(Bytes, Reencoded).

%%====================================================================
%% Data-model representation
%%====================================================================

%% Link (CID): tag 42 wrapping a 0x00-prefixed byte string of the raw CID.
%% Fixture `cid-bafkqabiaaebagba': d82a 4a 00 0155000500 01020304
link_decode_test() ->
    Bytes = <<16#D8, 16#2A, 16#4A, 0, 1, 16#55, 0, 5, 0, 1, 2, 3, 4>>,
    ?assertEqual({cid, <<1, 16#55, 0, 5, 0, 1, 2, 3, 4>>}, decode(Bytes)).

link_encode_test() ->
    Cid = <<1, 16#55, 0, 5, 0, 1, 2, 3, 4>>,
    Bytes = <<16#D8, 16#2A, 16#4A, 0, 1, 16#55, 0, 5, 0, 1, 2, 3, 4>>,
    ?assertEqual(Bytes, encode({cid, Cid})).

link_roundtrip_test() ->
    Cid = crypto:strong_rand_bytes(36),
    ?assertEqual({cid, Cid}, decode(encode({cid, Cid}))).

%% Strings decode to {text, Binary}; byte strings decode to a plain binary.
string_is_tagged_test() ->
    ?assertEqual({text, <<"a">>}, decode(<<16#61, $a>>)).

bytes_is_binary_test() ->
    ?assertEqual(<<1, 2, 3>>, decode(<<16#43, 1, 2, 3>>)).

%% Map keys are strings; they decode to plain binaries.
map_keys_decode_to_binary_test() ->
    Bytes = <<16#A2, 16#61, $a, 16#01, 16#61, $b, 16#02>>,
    ?assertEqual(#{<<"a">> => 1, <<"b">> => 2}, decode(Bytes)).

%% On encode a key may be given as a binary, an atom or {text, Binary}.
map_key_forms_encode_equally_test() ->
    Expected = <<16#A1, 16#61, $a, 16#01>>,
    ?assertEqual(Expected, encode(#{<<"a">> => 1})),
    ?assertEqual(Expected, encode(#{a => 1})),
    ?assertEqual(Expected, encode(#{{text, <<"a">>} => 1})).

%% Map keys are sorted length-first, then byte-wise (not pure byte-wise).
map_key_length_first_sort_test() ->
    %% "z" (len 1) must precede "aa" (len 2) despite 'z' > 'a' byte-wise.
    Bytes = encode(#{<<"aa">> => 1, <<"z">> => 2}),
    ?assertEqual(<<16#A2, 16#61, $z, 16#02, 16#62, $a, $a, 16#01>>, Bytes).

%%====================================================================
%% Integers (range and minimal encoding)
%%====================================================================

integer_boundaries_test() ->
    %% Full unsigned 64-bit range and full negative range (down to -2^64).
    MaxU64 = (1 bsl 64) - 1,
    MinNeg = -(1 bsl 64),
    ?assertEqual(
        <<16#1B, 255, 255, 255, 255, 255, 255, 255, 255>>, encode(MaxU64)
    ),
    ?assertEqual(
        <<16#3B, 255, 255, 255, 255, 255, 255, 255, 255>>, encode(MinNeg)
    ),
    ?assertEqual(MaxU64, decode(encode(MaxU64))),
    ?assertEqual(MinNeg, decode(encode(MinNeg))).

integer_out_of_range_rejected_test() ->
    ?assertError({integer_out_of_range, _}, encode(1 bsl 64)),
    ?assertError({integer_out_of_range, _}, encode(-(1 bsl 64) - 1)).

%%====================================================================
%% Floats (always 64-bit, no specials)
%%====================================================================

float_is_always_double_test() ->
    %% 1.5 fits in a half-float, but DAG-CBOR must use the 64-bit form.
    ?assertEqual(<<16#FB, 16#3F, 16#F8, 0, 0, 0, 0, 0, 0>>, encode(1.5)).

float_subnormal_roundtrip_test() ->
    %% Fixture `float--1e-323' is a subnormal double; it must round-trip.
    Bytes = <<16#FB, 16#80, 0, 0, 0, 0, 0, 0, 2>>,
    ?assertEqual(Bytes, encode(decode(Bytes))).

special_float_atoms_rejected_test() ->
    ?assertError({badarg, nan}, encode(nan)),
    ?assertError({badarg, infinity}, encode(infinity)),
    ?assertError({badarg, neg_infinity}, encode(neg_infinity)).

%%====================================================================
%% Strict decode rejections
%%====================================================================

reject_non_minimal_integer_test() ->
    %% 0 encoded with the redundant one-byte argument form.
    ?assertError(non_minimal_argument, decode(<<16#18, 16#00>>)).

reject_non_minimal_length_test() ->
    %% Text string of length 1 encoded with a redundant two-byte length.
    ?assertError(non_minimal_argument, decode(<<16#79, 16#00, 16#01, $a>>)).

reject_indefinite_array_test() ->
    ?assertError(indefinite_not_supported, decode(<<16#9F, 16#01, 16#FF>>)).

reject_indefinite_bytes_test() ->
    ?assertError(
        indefinite_not_supported, decode(<<16#5F, 16#41, 16#01, 16#FF>>)
    ).

reject_half_float_test() ->
    ?assertError(non_minimal_float, decode(<<16#F9, 16#3C, 16#00>>)).

reject_single_float_test() ->
    ?assertError(
        non_minimal_float, decode(<<16#FA, 16#47, 16#C3, 16#50, 16#00>>)
    ).

reject_nan_double_test() ->
    ?assertError(
        special_float_not_supported,
        decode(<<16#FB, 16#7F, 16#F8, 0, 0, 0, 0, 0, 0>>)
    ).

reject_infinity_double_test() ->
    ?assertError(
        special_float_not_supported,
        decode(<<16#FB, 16#7F, 16#F0, 0, 0, 0, 0, 0, 0>>)
    ).

reject_undefined_test() ->
    ?assertError(undefined_not_supported, decode(<<16#F7>>)).

reject_simple_value_test() ->
    ?assertError({unsupported_simple_value, _}, decode(<<16#F0>>)).

reject_non_cid_tag_test() ->
    %% Tag 0 (date/time) and tag 2 (bignum) are both forbidden.
    ?assertError({unsupported_tag, 0}, decode(<<16#C0, 16#61, $x>>)),
    ?assertError({unsupported_tag, 2}, decode(<<16#C2, 16#41, 16#01>>)).

reject_non_string_map_key_test() ->
    %% {1: 1} - an integer key.
    ?assertError(non_string_map_key, decode(<<16#A1, 16#01, 16#01>>)).

reject_unordered_map_keys_test() ->
    %% {"b": 1, "a": 2} - keys not in ascending order.
    ?assertError(
        unordered_map_keys,
        decode(<<16#A2, 16#61, $b, 16#01, 16#61, $a, 16#02>>)
    ).

reject_duplicate_map_keys_test() ->
    %% {"a": 1, "a": 2} - equal keys are not strictly ascending.
    ?assertError(
        unordered_map_keys,
        decode(<<16#A2, 16#61, $a, 16#01, 16#61, $a, 16#02>>)
    ).

reject_trailing_bytes_test() ->
    ?assertError(trailing_bytes, decode(<<16#01, 16#02>>)).

reject_cid_without_multibase_prefix_test() ->
    %% Tag 42 wrapping a byte string that does not start with 0x00.
    ?assertError(
        invalid_cid_multibase_prefix,
        decode(<<16#D8, 16#2A, 16#42, 16#01, 16#02>>)
    ).

reject_encode_int_map_key_test() ->
    ?assertError({invalid_map_key, 1}, encode(#{1 => 2})).

%%====================================================================
%% `default' profile parity with encode/1 and decode/1
%%====================================================================

default_profile_decode_test() ->
    Bytes = <<16#83, 1, 2, 3>>,
    ?assertEqual(bondy_cbor:decode(Bytes), bondy_cbor:decode(Bytes, default)).

default_profile_encode_test() ->
    Term = #{<<"a">> => [1, 2, 3]},
    Expected = iolist_to_binary(bondy_cbor:encode(Term)),
    ?assertEqual(Expected, bondy_cbor:encode(Term, default)).

%%====================================================================
%% Helpers
%%====================================================================

decode(Bytes) ->
    bondy_cbor:decode(Bytes, dag).

encode(Term) ->
    bondy_cbor:encode(Term, dag).

fixture_files() ->
    filelib:wildcard(filename:join(fixtures_dir(), "*.dag-cbor")).

fixture_name(File) ->
    filename:basename(File, ".dag-cbor").

%% Locate the vendored fixtures directory. `?FILE' is the path the compiler saw,
%% so the sibling `dag_cbor_fixtures' directory is the primary candidate; the
%% relative fallbacks cover running eunit from the umbrella or app root.
fixtures_dir() ->
    Candidates = [
        filename:join(filename:dirname(?FILE), "dag_cbor_fixtures"),
        filename:join(["apps", "bondy_cbor", "test", "dag_cbor_fixtures"]),
        filename:join(["test", "dag_cbor_fixtures"])
    ],
    case lists:dropwhile(fun(D) -> not filelib:is_dir(D) end, Candidates) of
        [Dir | _] -> Dir;
        [] -> error({fixtures_dir_not_found, Candidates})
    end.
