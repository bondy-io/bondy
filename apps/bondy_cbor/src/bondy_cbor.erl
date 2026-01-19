%% =============================================================================
%% SPDX-FileCopyrightText: 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_cbor).

-moduledoc """
CBOR (RFC 8949) encoder and decoder.

This module implements the Concise Binary Object Representation (CBOR)
data format as specified in RFC 8949. The API design follows the
style of json.erl from OTP 28.

## Encoding

The `encode/1` function encodes Erlang terms to CBOR format:

```erlang
1> bondy_cbor:encode(#{<<"key">> => [1, 2, 3]}).
<<161,99,107,101,121,131,1,2,3>>
```

For deterministic encoding (RFC 8949 Section 4.2), use `encode_deterministic/1`:

```erlang
2> bondy_cbor:encode_deterministic(#{b => 1, a => 2}).
<<162,97,97,2,97,98,1>>
```

## Decoding

The `decode/1` function decodes CBOR binaries to Erlang terms:

```erlang
3> bondy_cbor:decode(<<161,99,107,101,121,131,1,2,3>>).
#{<<"key">> => [1, 2, 3]}
```

## Type Mapping

| CBOR Type | Erlang Encoding | Erlang Decoding |
|-----------|-----------------|-----------------|
| Unsigned int | `integer() >= 0` | `integer()` |
| Negative int | `integer() < 0` | `integer()` |
| Byte string | `binary()` | `binary()` |
| Text string | `{text, binary()}` or `atom()` | `binary()` |
| Array | `list()` | `list()` |
| Map | `map()` | `map()` |
| Tag | `{tag, N, Value}` | auto-converted or `{tag, N, Value}` |
| Simple/Float | `true/false/null/undefined/float()` | same |
""".

-include("bondy_cbor.hrl").


%% Cached decoder callbacks record for O(1) access during recursive calls.
-record(dec_callbacks, {
    array_start :: array_start_decoder(term()),
    array_push :: array_push_decoder(term()),
    array_finish :: array_finish_decoder(term(), term()),
    map_start :: map_start_decoder(term()),
    map_push :: map_push_decoder(term()),
    map_finish :: map_finish_decoder(term(), term()),
    null_value :: term(),
    undefined_value :: term()
}).


%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type tag() :: non_neg_integer().

-type encode_value() ::
    integer()
    | float()
    | binary()
    | atom()
    | list(encode_value())
    | #{encode_value() => encode_value()}
    | {text, binary()}
    | {tag, tag(), encode_value()}.

-type decode_value() ::
    integer()
    | float()
    | infinity | neg_infinity | nan
    | binary()
    | true | false | null | undefined
    | list(decode_value())
    | #{decode_value() => decode_value()}
    | {tag, tag(), decode_value()}.

-type encoder() :: fun((term(), encoder()) -> iodata()).

-type decoder(Acc) :: fun((decode_value(), Acc) -> Acc).

-type array_start_decoder(Acc) :: fun((non_neg_integer() | indefinite, Acc) -> Acc).
-type array_push_decoder(Acc) :: fun((decode_value(), Acc) -> Acc).
-type array_finish_decoder(Acc, Result) :: fun((Acc) -> {Result, Acc}).

-type map_start_decoder(Acc) :: fun(
    (non_neg_integer() | indefinite, Acc) -> Acc
).
-type map_push_decoder(Acc) :: fun(
    ({decode_value(), decode_value()}, Acc) -> Acc
).
-type map_finish_decoder(Acc, Result) :: fun((Acc) -> {Result, Acc}).

-type decoders(Acc, ArrayResult, MapResult) :: #{
    array_start => array_start_decoder(Acc),
    array_push => array_push_decoder(Acc),
    array_finish => array_finish_decoder(Acc, ArrayResult),
    map_start => map_start_decoder(Acc),
    map_push => map_push_decoder(Acc),
    map_finish => map_finish_decoder(Acc, MapResult),
    null => term(),
    undefined => term()
}.

-type decoders() :: decoders(term(), term(), term()).

-opaque continuation_state() :: {
    Stack :: list(),
    Acc :: term(),
    Decoders :: decoders()
}.


-export_type([continuation_state/0]).
-export_type([decode_value/0]).
-export_type([decoder/1]).
-export_type([decoders/0]).
-export_type([decoders/3]).
-export_type([encode_value/0]).
-export_type([encoder/0]).
-export_type([tag/0]).

%%--------------------------------------------------------------------
%% Public API - Encoding
%%--------------------------------------------------------------------

-export([encode/1]).
-export([encode/2]).
-export([encode_deterministic/1]).
-export([encode_integer/1]).
-export([encode_float/1]).
-export([encode_binary/1]).
-export([encode_string/1]).
-export([encode_list/2]).
-export([encode_map/2]).
-export([encode_map_sorted/2]).
-export([encode_atom/2]).
-export([encode_tagged/3]).
-export([encode_value/2]).
-export([encode_key_value_list/2]).
-export([encode_key_value_list_checked/2]).

%%--------------------------------------------------------------------
%% Public API - Decoding
%%--------------------------------------------------------------------

-export([decode/1]).
-export([decode/3]).
-export([decode_start/3]).
-export([decode_continue/2]).

%%--------------------------------------------------------------------
%% Public API - Formatting
%%--------------------------------------------------------------------

-export([format/1]).


%%====================================================================
%% Encoding API
%%====================================================================

-doc """
Encode an Erlang term to CBOR format.

Returns iodata that represents the CBOR encoding.
""".
-spec encode(encode_value()) -> iodata().
encode(Term) ->
    encode(Term, fun default_encoder/2).

-doc """
Encode a term using a custom encoder function.

The encoder function is called for each term and can customize
how specific types are encoded.
""".
-spec encode(term(), encoder()) -> iodata().
encode(Term, Encoder) when is_function(Encoder, 2) ->
    Encoder(Term, Encoder).

-doc """
Encode a term in deterministic CBOR format (RFC 8949 Section 4.2).

Deterministic encoding guarantees:
- Shortest integer encoding
- Shortest float encoding (half → single → double)
- Map keys sorted lexicographically by encoded bytes
- No indefinite-length items
""".
-spec encode_deterministic(encode_value()) -> binary().
encode_deterministic(Term) ->
    iolist_to_binary(encode(Term, fun deterministic_encoder/2)).

-doc """
Encode an integer to CBOR.

Handles positive integers, negative integers, and bignums.
""".
-spec encode_integer(integer()) -> iodata().
encode_integer(N) when is_integer(N), N >= 0 ->
    encode_unsigned(N);
encode_integer(N) when is_integer(N), N < 0 ->
    encode_negative(N).

-doc """
Encode a float to CBOR.

Uses double-precision (64-bit) IEEE 754 format.
""".
-spec encode_float(float()) -> iodata().
encode_float(F) when is_float(F) ->
    <<(?MT_SIMPLE bsl 5 bor ?AI_DOUBLE_FLOAT), F:64/float>>.

-doc "Encode a binary as a CBOR byte string (major type 2).".
-spec encode_binary(binary()) -> iodata().
encode_binary(Bin) when is_binary(Bin) ->
    [encode_head(?MT_BYTES, byte_size(Bin)), Bin].

-doc """
Encode a binary as a CBOR text string (major type 3).

The binary must be valid UTF-8.
""".
-spec encode_string(binary()) -> iodata().
encode_string(Bin) when is_binary(Bin) ->
    [encode_head(?MT_TEXT, byte_size(Bin)), Bin].

-doc """
Encode a list as a CBOR array (major type 4).

Uses hand-unrolled encoding for small arrays (0-15 elements) for performance,
similar to msgpack's optimization strategy.
""".
-spec encode_list(list(), encoder()) -> iodata().
%% Hand-unrolled cases for small arrays (fixarray: 0x80-0x8F)
encode_list([], _Enc) ->
    <<16#80>>;
encode_list([A], Enc) ->
    [<<16#81>>, Enc(A, Enc)];
encode_list([A, B], Enc) ->
    [<<16#82>>, Enc(A, Enc), Enc(B, Enc)];
encode_list([A, B, C], Enc) ->
    [<<16#83>>, Enc(A, Enc), Enc(B, Enc), Enc(C, Enc)];
encode_list([A, B, C, D], Enc) ->
    [<<16#84>>, Enc(A, Enc), Enc(B, Enc), Enc(C, Enc), Enc(D, Enc)];
encode_list([A, B, C, D, E], Enc) ->
    [<<16#85>>, Enc(A, Enc), Enc(B, Enc), Enc(C, Enc), Enc(D, Enc), Enc(E, Enc)];
encode_list([A, B, C, D, E, F], Enc) ->
    [<<16#86>>, Enc(A, Enc), Enc(B, Enc), Enc(C, Enc), Enc(D, Enc), Enc(E, Enc),
     Enc(F, Enc)];
encode_list([A, B, C, D, E, F, G], Enc) ->
    [<<16#87>>, Enc(A, Enc), Enc(B, Enc), Enc(C, Enc), Enc(D, Enc), Enc(E, Enc),
     Enc(F, Enc), Enc(G, Enc)];
encode_list([A, B, C, D, E, F, G, H], Enc) ->
    [<<16#88>>, Enc(A, Enc), Enc(B, Enc), Enc(C, Enc), Enc(D, Enc), Enc(E, Enc),
     Enc(F, Enc), Enc(G, Enc), Enc(H, Enc)];
encode_list([A, B, C, D, E, F, G, H, I], Enc) ->
    [<<16#89>>, Enc(A, Enc), Enc(B, Enc), Enc(C, Enc), Enc(D, Enc), Enc(E, Enc),
     Enc(F, Enc), Enc(G, Enc), Enc(H, Enc), Enc(I, Enc)];
encode_list([A, B, C, D, E, F, G, H, I, J], Enc) ->
    [<<16#8A>>, Enc(A, Enc), Enc(B, Enc), Enc(C, Enc), Enc(D, Enc), Enc(E, Enc),
     Enc(F, Enc), Enc(G, Enc), Enc(H, Enc), Enc(I, Enc), Enc(J, Enc)];
encode_list([A, B, C, D, E, F, G, H, I, J, K], Enc) ->
    [<<16#8B>>, Enc(A, Enc), Enc(B, Enc), Enc(C, Enc), Enc(D, Enc), Enc(E, Enc),
     Enc(F, Enc), Enc(G, Enc), Enc(H, Enc), Enc(I, Enc), Enc(J, Enc), Enc(K, Enc)];
encode_list([A, B, C, D, E, F, G, H, I, J, K, L], Enc) ->
    [<<16#8C>>, Enc(A, Enc), Enc(B, Enc), Enc(C, Enc), Enc(D, Enc), Enc(E, Enc),
     Enc(F, Enc), Enc(G, Enc), Enc(H, Enc), Enc(I, Enc), Enc(J, Enc), Enc(K, Enc),
     Enc(L, Enc)];
encode_list([A, B, C, D, E, F, G, H, I, J, K, L, M], Enc) ->
    [<<16#8D>>, Enc(A, Enc), Enc(B, Enc), Enc(C, Enc), Enc(D, Enc), Enc(E, Enc),
     Enc(F, Enc), Enc(G, Enc), Enc(H, Enc), Enc(I, Enc), Enc(J, Enc), Enc(K, Enc),
     Enc(L, Enc), Enc(M, Enc)];
encode_list([A, B, C, D, E, F, G, H, I, J, K, L, M, N], Enc) ->
    [<<16#8E>>, Enc(A, Enc), Enc(B, Enc), Enc(C, Enc), Enc(D, Enc), Enc(E, Enc),
     Enc(F, Enc), Enc(G, Enc), Enc(H, Enc), Enc(I, Enc), Enc(J, Enc), Enc(K, Enc),
     Enc(L, Enc), Enc(M, Enc), Enc(N, Enc)];
encode_list([A, B, C, D, E, F, G, H, I, J, K, L, M, N, O], Enc) ->
    [<<16#8F>>, Enc(A, Enc), Enc(B, Enc), Enc(C, Enc), Enc(D, Enc), Enc(E, Enc),
     Enc(F, Enc), Enc(G, Enc), Enc(H, Enc), Enc(I, Enc), Enc(J, Enc), Enc(K, Enc),
     Enc(L, Enc), Enc(M, Enc), Enc(N, Enc), Enc(O, Enc)];
%% General case for larger arrays - use binary comprehension
encode_list(List, Enc) when is_list(List), is_function(Enc, 2) ->
    Len = length(List),
    [encode_head(?MT_ARRAY, Len) | encode_list_elements(List, Enc)].

%% @private Encode list elements efficiently
encode_list_elements(List, Enc) ->
    [Enc(E, Enc) || E <- List].

-doc """
Encode a map as a CBOR map (major type 5).

Keys are encoded in iteration order (not deterministic).
Uses hand-unrolled encoding for small maps (0-4 pairs) for performance.
""".
-spec encode_map(map(), encoder()) -> iodata().
encode_map(Map, _Enc) when map_size(Map) =:= 0 ->
    <<16#A0>>;
encode_map(Map, Enc) when map_size(Map) =:= 1 ->
    [{K, V}] = maps:to_list(Map),
    [<<16#A1>>, Enc(K, Enc), Enc(V, Enc)];
encode_map(Map, Enc) when map_size(Map) =:= 2 ->
    [{K1, V1}, {K2, V2}] = maps:to_list(Map),
    [<<16#A2>>, Enc(K1, Enc), Enc(V1, Enc), Enc(K2, Enc), Enc(V2, Enc)];
encode_map(Map, Enc) when map_size(Map) =:= 3 ->
    [{K1, V1}, {K2, V2}, {K3, V3}] = maps:to_list(Map),
    [<<16#A3>>, Enc(K1, Enc), Enc(V1, Enc), Enc(K2, Enc), Enc(V2, Enc),
     Enc(K3, Enc), Enc(V3, Enc)];
encode_map(Map, Enc) when map_size(Map) =:= 4 ->
    [{K1, V1}, {K2, V2}, {K3, V3}, {K4, V4}] = maps:to_list(Map),
    [<<16#A4>>, Enc(K1, Enc), Enc(V1, Enc), Enc(K2, Enc), Enc(V2, Enc),
     Enc(K3, Enc), Enc(V3, Enc), Enc(K4, Enc), Enc(V4, Enc)];
encode_map(Map, Enc) when is_map(Map), is_function(Enc, 2) ->
    %% General case: use iterator for efficiency
    Size = map_size(Map),
    [encode_head(?MT_MAP, Size) | encode_map_pairs(maps:iterator(Map), Enc)].

%% @private Encode map pairs using iterator
encode_map_pairs(Iter, Enc) ->
    case maps:next(Iter) of
        none -> [];
        {K, V, NextIter} -> [Enc(K, Enc), Enc(V, Enc) | encode_map_pairs(NextIter, Enc)]
    end.

-doc """
Encode a map with keys sorted by their encoded byte representation.

This is used for deterministic encoding (RFC 8949 Section 4.2.1).
""".
-spec encode_map_sorted(map(), encoder()) -> iodata().
encode_map_sorted(Map, _Enc) when map_size(Map) =:= 0 ->
    <<16#A0>>;
encode_map_sorted(Map, Enc) when is_map(Map), is_function(Enc, 2) ->
    %% Encode all key-value pairs, converting keys to binary for sorting
    %% Using maps:to_list is faster than maps:fold for this use case
    Pairs = maps:to_list(Map),
    EncodedPairs = [{iolist_to_binary(Enc(K, Enc)), Enc(V, Enc)} || {K, V} <- Pairs],
    %% Sort by encoded key bytes (CBOR deterministic requirement)
    SortedPairs = lists:sort(fun({K1, _}, {K2, _}) -> K1 =< K2 end, EncodedPairs),
    [encode_head(?MT_MAP, map_size(Map)) | [[K, V] || {K, V} <- SortedPairs]].

-doc "Encode an atom as a CBOR text string.".
-spec encode_atom(atom(), encoder()) -> iodata().
encode_atom(true, _Encoder) -> ?CBOR_TRUE;
encode_atom(false, _Encoder) -> ?CBOR_FALSE;
encode_atom(null, _Encoder) -> ?CBOR_NULL;
encode_atom(undefined, _Encoder) -> ?CBOR_UNDEFINED;
encode_atom(infinity, _Encoder) -> <<16#F9, 16#7C, 16#00>>;      % Half-precision +Infinity
encode_atom(neg_infinity, _Encoder) -> <<16#F9, 16#FC, 16#00>>; % Half-precision -Infinity
encode_atom(nan, _Encoder) -> <<16#F9, 16#7E, 16#00>>;           % Half-precision NaN
encode_atom(Atom, _Encoder) when is_atom(Atom) ->
    Bin = atom_to_binary(Atom, utf8),
    encode_string(Bin).

-doc "Encode a tagged value (major type 6).".
-spec encode_tagged(tag(), term(), encoder()) -> iodata().
encode_tagged(Tag, Value, Encoder) when is_integer(Tag), Tag >= 0 ->
    [encode_head(?MT_TAG, Tag), Encoder(Value, Encoder)].

-doc """
Encode a value using standard CBOR encoding, calling the encoder for nested values.

This function handles the basic CBOR types directly and delegates to the
encoder function for nested structures, following the same API as json:encode_value/2.
""".
-spec encode_value(term(), encoder()) -> iodata().
%% Tiny positive integers (0-23): single byte, most common case
encode_value(N, _Enc) when is_integer(N), N >= 0, N < 24 ->
    <<N>>;
%% Small positive integers (24-255): two bytes
encode_value(N, _Enc) when is_integer(N), N >= 24, N =< 16#FF ->
    <<24, N:8>>;
%% Medium positive integers (256-65535): three bytes
encode_value(N, _Enc) when is_integer(N), N >= 16#100, N =< 16#FFFF ->
    <<25, N:16>>;
%% Fallback to general integer encoding for larger values and negatives
encode_value(N, _Enc) when is_integer(N) ->
    encode_integer(N);
encode_value(F, _Enc) when is_float(F) ->
    encode_float(F);
encode_value(Bin, _Enc) when is_binary(Bin) ->
    encode_binary(Bin);
encode_value(Atom, Enc) when is_atom(Atom) ->
    encode_atom(Atom, Enc);
encode_value(List, Enc) when is_list(List) ->
    encode_list(List, Enc);
encode_value(Map, Enc) when is_map(Map) ->
    encode_map(Map, Enc);
encode_value({text, Bin}, _Enc) when is_binary(Bin) ->
    encode_string(Bin);
encode_value({tag, Tag, Value}, Enc) when is_integer(Tag), Tag >= 0 ->
    encode_tagged(Tag, Value, Enc);
encode_value(Term, _Enc) ->
    error({badarg, Term}).

-doc """
Encode a key-value list (proplist) as a CBOR map.

The list must contain 2-tuples {Key, Value}. Keys are not checked
for duplicates.
""".
-spec encode_key_value_list([{term(), term()}], encoder()) -> iodata().
encode_key_value_list(List, Encoder) when is_list(List), is_function(Encoder, 2) ->
    Len = length(List),
    [encode_head(?MT_MAP, Len) | encode_kv_pairs(List, Encoder)].

-doc """
Encode a key-value list (proplist) as a CBOR map, checking for duplicate keys.

Raises {duplicate_key, Key} error if a duplicate key is found.
""".
-spec encode_key_value_list_checked([{term(), term()}], encoder()) -> iodata().
encode_key_value_list_checked(List, Encoder) when is_list(List), is_function(Encoder, 2) ->
    check_duplicate_keys(List, #{}),
    encode_key_value_list(List, Encoder).

%% @private
encode_kv_pairs([], _Encoder) ->
    [];
encode_kv_pairs([{K, V} | Rest], Encoder) ->
    [Encoder(K, Encoder), Encoder(V, Encoder) | encode_kv_pairs(Rest, Encoder)].

%% @private
check_duplicate_keys([], _Seen) ->
    ok;
check_duplicate_keys([{K, _V} | Rest], Seen) ->
    case maps:is_key(K, Seen) of
        true ->
            error({duplicate_key, K});
        false ->
            check_duplicate_keys(Rest, Seen#{K => true})
    end.

%%====================================================================
%% Decoding API
%%====================================================================

-doc """
Decode a CBOR binary to an Erlang term.

Raises an error if the input is invalid or incomplete.
""".
-spec decode(binary()) -> decode_value().
decode(Binary) when is_binary(Binary) ->
    {Value, <<>>} = decode_value(Binary),
    Value.

-doc """
Decode a CBOR binary with custom decoders and accumulator.

Returns `{Result, Acc, Rest}` where Rest is any unconsumed bytes.
""".
-spec decode(binary(), Acc, decoders()) -> {decode_value(), Acc, binary()}
    when Acc :: term().
decode(Binary, Acc, Decoders) when is_binary(Binary), is_map(Decoders) ->
    {Value, Rest, NewAcc} = decode_value_custom(Binary, Acc, Decoders),
    {Value, NewAcc, Rest}.

-doc """
Start streaming decode of a CBOR binary.

Returns either a complete result or a continuation state if more data is needed.
""".
-spec decode_start(binary(), Acc, decoders()) ->
    {decode_value(), Acc, binary()} | {continue, continuation_state()}
    when Acc :: term().
decode_start(Binary, Acc, Decoders) when is_binary(Binary), is_map(Decoders) ->
    try
        {Value, Rest, NewAcc} = decode_value_custom(Binary, Acc, Decoders),
        {Value, NewAcc, Rest}
    catch
        throw:{incomplete, Stack, CurrentAcc} ->
            {continue, {Stack, CurrentAcc, Decoders}}
    end.

-doc """
Continue streaming decode with more data.

Pass `end_of_input` as the first argument to signal no more data.
""".
-spec decode_continue(binary() | end_of_input, continuation_state()) ->
    {decode_value(), term(), binary()} | {continue, continuation_state()}.
decode_continue(end_of_input, {_Stack, _Acc, _Decoders}) ->
    error(incomplete);
decode_continue(Binary, {Stack, Acc, Decoders}) when is_binary(Binary) ->
    try
        {Value, Rest, NewAcc} = continue_decode(Binary, Stack, Acc, Decoders),
        {Value, NewAcc, Rest}
    catch
        throw:{incomplete, NewStack, CurrentAcc} ->
            {continue, {NewStack, CurrentAcc, Decoders}}
    end.

%%====================================================================
%% Formatting API
%%====================================================================

-doc """
Format a CBOR-encodable term as diagnostic notation (RFC 8949 Section 8).

This produces a human-readable representation of CBOR data.
""".
-spec format(encode_value()) -> iodata().
format(Term) ->
    format_value(Term).

%%====================================================================
%% Internal - Encoding
%%====================================================================

%% @private
%% Encode the header byte(s) for a major type and argument.
-spec encode_head(0..7, non_neg_integer()) -> binary().
encode_head(MT, Arg) when Arg < 24 ->
    <<(MT bsl 5 bor Arg)>>;
encode_head(MT, Arg) when Arg =< ?MAX_UINT8 ->
    <<(MT bsl 5 bor ?AI_1BYTE), Arg:8>>;
encode_head(MT, Arg) when Arg =< ?MAX_UINT16 ->
    <<(MT bsl 5 bor ?AI_2BYTE), Arg:16>>;
encode_head(MT, Arg) when Arg =< ?MAX_UINT32 ->
    <<(MT bsl 5 bor ?AI_4BYTE), Arg:32>>;
encode_head(MT, Arg) when Arg =< ?MAX_UINT64 ->
    <<(MT bsl 5 bor ?AI_8BYTE), Arg:64>>.

%% @private
%% Encode an unsigned integer (major type 0) or bignum (tag 2).
-spec encode_unsigned(non_neg_integer()) -> iodata().
encode_unsigned(N) when N =< ?MAX_UINT64 ->
    encode_head(?MT_UNSIGNED, N);
encode_unsigned(N) ->
    %% Bignum: tag 2 + byte string of big-endian bytes
    Bytes = binary:encode_unsigned(N),
    [encode_head(?MT_TAG, ?TAG_POSITIVE_BIGNUM), encode_binary(Bytes)].

%% @private
%% Encode a negative integer (major type 1) or bignum (tag 3).
-spec encode_negative(neg_integer()) -> iodata().
encode_negative(N) when N >= -1 - ?MAX_UINT64 ->
    encode_head(?MT_NEGATIVE, -1 - N);
encode_negative(N) ->
    %% Negative bignum: tag 3 + byte string of big-endian bytes of (-1 - n)
    Bytes = binary:encode_unsigned(-1 - N),
    [encode_head(?MT_TAG, ?TAG_NEGATIVE_BIGNUM), encode_binary(Bytes)].

%% @private
%% Default encoder for encode/1.
%% Optimizes the most common integer ranges inline to avoid function call overhead.
%% Inspired by msgpack's approach of fast-pathing common values.
-spec default_encoder(term(), encoder()) -> iodata().
%% Tiny positive integers (0-23): single byte, most common case
default_encoder(N, _Enc) when is_integer(N), N >= 0, N < 24 ->
    <<N>>;
%% Small positive integers (24-255): two bytes
default_encoder(N, _Enc) when is_integer(N), N >= 24, N =< 16#FF ->
    <<24, N:8>>;
%% Medium positive integers (256-65535): three bytes
default_encoder(N, _Enc) when is_integer(N), N >= 16#100, N =< 16#FFFF ->
    <<25, N:16>>;
%% Fallback to general integer encoding for larger values and negatives
default_encoder(N, _Enc) when is_integer(N) ->
    encode_integer(N);
default_encoder(F, _Enc) when is_float(F) ->
    encode_float(F);
default_encoder(Bin, _Enc) when is_binary(Bin) ->
    encode_binary(Bin);
default_encoder(Atom, Enc) when is_atom(Atom) ->
    encode_atom(Atom, Enc);
default_encoder(List, Enc) when is_list(List) ->
    encode_list(List, Enc);
default_encoder(Map, Enc) when is_map(Map) ->
    encode_map(Map, Enc);
default_encoder({text, Bin}, _Enc) when is_binary(Bin) ->
    encode_string(Bin);
default_encoder({tag, Tag, Value}, Enc) when is_integer(Tag), Tag >= 0 ->
    encode_tagged(Tag, Value, Enc);
default_encoder(Term, _Enc) ->
    error({badarg, Term}).

%% @private
%% Deterministic encoder with shortest encodings and sorted maps.
%% Optimizes the most common integer ranges inline (same as default_encoder).
-spec deterministic_encoder(term(), encoder()) -> iodata().
%% Tiny positive integers (0-23): single byte, most common case
deterministic_encoder(N, _Enc) when is_integer(N), N >= 0, N < 24 ->
    <<N>>;
%% Small positive integers (24-255): two bytes
deterministic_encoder(N, _Enc) when is_integer(N), N >= 24, N =< 16#FF ->
    <<24, N:8>>;
%% Medium positive integers (256-65535): three bytes
deterministic_encoder(N, _Enc) when is_integer(N), N >= 16#100, N =< 16#FFFF ->
    <<25, N:16>>;
%% Fallback to general integer encoding for larger values and negatives
deterministic_encoder(N, _Enc) when is_integer(N) ->
    encode_integer(N);
deterministic_encoder(F, _Enc) when is_float(F) ->
    encode_float_shortest(F);
deterministic_encoder(Bin, _Enc) when is_binary(Bin) ->
    encode_binary(Bin);
deterministic_encoder(Atom, Enc) when is_atom(Atom) ->
    encode_atom(Atom, Enc);
deterministic_encoder(List, Enc) when is_list(List) ->
    encode_list(List, Enc);
deterministic_encoder(Map, Enc) when is_map(Map) ->
    encode_map_sorted(Map, Enc);
deterministic_encoder({text, Bin}, _Enc) when is_binary(Bin) ->
    encode_string(Bin);
deterministic_encoder({tag, Tag, Value}, Enc) when is_integer(Tag), Tag >= 0 ->
    encode_tagged(Tag, Value, Enc);
deterministic_encoder(Term, _Enc) ->
    error({badarg, Term}).

%% @private
%% Encode a float using the shortest representation that preserves the value.
%% Optimized with early-exit: checks exponent range before attempting conversion.
%% Inspired by msgpack's approach of checking feasibility before expensive operations.
-spec encode_float_shortest(float()) -> binary().
encode_float_shortest(F) ->
    %% Extract exponent to determine which formats might work
    <<_Sign:1, Exp:11, _Frac:52>> = <<F:64/float>>,
    %% Biased exponent: 0 = zero/subnormal, 2047 = inf/nan
    %% Half-float range: exp in [1009..1038] for normal numbers (biased)
    %% Single-float range: exp in [897..1150] for normal numbers (biased)
    case Exp of
        0 ->
            %% Zero or subnormal - try half first
            try_shortest_float(F);
        2047 ->
            %% Infinity or NaN - half-float can represent these
            try_shortest_float(F);
        _ when Exp >= 1009, Exp =< 1038 ->
            %% Within half-float range, try half first
            try_shortest_float(F);
        _ when Exp >= 897, Exp =< 1150 ->
            %% Outside half but within single range, skip half
            try_single_or_double(F);
        _ ->
            %% Outside both ranges, must use double
            <<(?MT_SIMPLE bsl 5 bor ?AI_DOUBLE_FLOAT), F:64/float>>
    end.

%% @private
%% Try half -> single -> double encoding (full cascade).
try_shortest_float(F) ->
    case encode_half_float(F) of
        {ok, Bin} -> Bin;
        error -> try_single_or_double(F)
    end.

%% @private
%% Try single -> double encoding (skip half).
try_single_or_double(F) ->
    case encode_single_float(F) of
        {ok, Bin} -> Bin;
        error -> <<(?MT_SIMPLE bsl 5 bor ?AI_DOUBLE_FLOAT), F:64/float>>
    end.

%% @private
%% Try to encode as half-precision float.
-spec encode_half_float(float()) -> {ok, binary()} | error.
encode_half_float(F) ->
    Half = float_to_half(F),
    case half_to_float(Half) of
        F -> {ok, <<(?MT_SIMPLE bsl 5 bor ?AI_HALF_FLOAT), Half:16>>};
        _ -> error
    end.

%% @private
%% Try to encode as single-precision float.
-spec encode_single_float(float()) -> {ok, binary()} | error.
encode_single_float(F) ->
    Single = <<F:32/float>>,
    <<Decoded:32/float>> = Single,
    case Decoded of
        F -> {ok, <<(?MT_SIMPLE bsl 5 bor ?AI_SINGLE_FLOAT), Single/binary>>};
        _ -> error
    end.

%% @private
%% Convert a float to IEEE 754 half-precision format.
-spec float_to_half(float()) -> 0..65535.
float_to_half(F) ->
    <<D:64/bits>> = <<F:64/float>>,
    <<Sign:1, Exp:11, Frac:52>> = D,
    case Exp of
        0 when Frac =:= 0 ->
            %% Zero
            Sign bsl 15;
        0 ->
            %% Subnormal double -> zero in half (too small)
            Sign bsl 15;
        2047 when Frac =:= 0 ->
            %% Infinity
            (Sign bsl 15) bor 16#7C00;
        2047 ->
            %% NaN - preserve some significand bits
            (Sign bsl 15) bor 16#7C00 bor ((Frac bsr 42) band 16#3FF);
        _ ->
            %% Normal number
            HalfExp = Exp - 1023 + 15,
            if
                HalfExp >= 31 ->
                    %% Overflow to infinity
                    (Sign bsl 15) bor 16#7C00;
                HalfExp > 0 ->
                    %% Normal half
                    HalfFrac = Frac bsr 42,
                    (Sign bsl 15) bor (HalfExp bsl 10) bor HalfFrac;
                HalfExp > -10 ->
                    %% Subnormal half
                    HalfFrac = (16#400 bor (Frac bsr 42)) bsr (1 - HalfExp),
                    (Sign bsl 15) bor HalfFrac;
                true ->
                    %% Too small, return zero
                    Sign bsl 15
            end
    end.

%% @private
%% Convert IEEE 754 half-precision to float.
-spec half_to_float(0..65535) -> float().
half_to_float(H) ->
    Sign = H bsr 15,
    Exp = (H bsr 10) band 16#1F,
    Frac = H band 16#3FF,
    case Exp of
        0 when Frac =:= 0 ->
            %% Zero
            case Sign of
                0 -> 0.0;
                1 -> -0.0
            end;
        0 ->
            %% Subnormal
            F = Frac / 1024.0 * math:pow(2, -14),
            case Sign of
                0 -> F;
                1 -> -F
            end;
        31 when Frac =:= 0 ->
            %% Infinity
            case Sign of
                0 -> float_infinity();
                1 -> float_neg_infinity()
            end;
        31 ->
            %% NaN
            float_nan();
        _ ->
            %% Normal
            DoubleExp = Exp - 15 + 1023,
            DoubleFrac = Frac bsl 42,
            <<F:64/float>> = <<Sign:1, DoubleExp:11, DoubleFrac:52>>,
            F
    end.

%% @private
%% IEEE 754 double-precision positive infinity
%% Erlang doesn't allow direct pattern matching on special floats,
%% so we return the infinity atom and handle it specially
float_infinity() ->
    infinity.

%% @private
%% IEEE 754 double-precision negative infinity
float_neg_infinity() ->
    neg_infinity.

%% @private
%% IEEE 754 double-precision NaN (quiet NaN)
float_nan() ->
    nan.

%%====================================================================
%% Internal - Decoding
%%====================================================================

%% @private
%% Decode a single CBOR value.
-spec decode_value(binary()) -> {decode_value(), binary()}.
decode_value(<<>>) ->
    error(incomplete);
decode_value(<<IB, Rest/binary>>) ->
    MT = IB bsr 5,
    AI = IB band 16#1F,
    decode_major_type(MT, AI, Rest).

%% @private
%% Dispatch based on major type.
-spec decode_major_type(0..7, 0..31, binary()) -> {decode_value(), binary()}.
decode_major_type(?MT_UNSIGNED, AI, Bin) ->
    decode_unsigned(AI, Bin);
decode_major_type(?MT_NEGATIVE, AI, Bin) ->
    {N, Rest} = decode_arg(AI, Bin),
    {-1 - N, Rest};
decode_major_type(?MT_BYTES, AI, Bin) ->
    decode_bytes(AI, Bin);
decode_major_type(?MT_TEXT, AI, Bin) ->
    decode_text(AI, Bin);
decode_major_type(?MT_ARRAY, AI, Bin) ->
    decode_array(AI, Bin);
decode_major_type(?MT_MAP, AI, Bin) ->
    decode_map(AI, Bin);
decode_major_type(?MT_TAG, AI, Bin) ->
    decode_tag(AI, Bin);
decode_major_type(?MT_SIMPLE, AI, Bin) ->
    decode_simple(AI, Bin).

%% @private
%% Decode argument value from additional info.
-spec decode_arg(0..31, binary()) -> {non_neg_integer(), binary()}.
decode_arg(AI, Bin) when AI < 24 ->
    {AI, Bin};
decode_arg(24, <<V, Rest/binary>>) ->
    {V, Rest};
decode_arg(25, <<V:16, Rest/binary>>) ->
    {V, Rest};
decode_arg(26, <<V:32, Rest/binary>>) ->
    {V, Rest};
decode_arg(27, <<V:64, Rest/binary>>) ->
    {V, Rest};
decode_arg(AI, _Bin) when AI >= 28, AI =< 30 ->
    error({invalid_ai, AI});
decode_arg(31, _Bin) ->
    {indefinite, <<>>};  % Handled specially by callers
decode_arg(_, <<>>) ->
    error(incomplete).

%% @private
%% Decode unsigned integer (major type 0).
-spec decode_unsigned(0..31, binary()) -> {non_neg_integer(), binary()}.
decode_unsigned(AI, Bin) ->
    decode_arg(AI, Bin).

%% @private
%% Decode byte string (major type 2).
-spec decode_bytes(0..31, binary()) -> {binary(), binary()}.
decode_bytes(?AI_INDEFINITE, Bin) ->
    decode_bytes_indefinite(Bin, []);
decode_bytes(AI, Bin) ->
    {Len, Rest} = decode_arg(AI, Bin),
    case Rest of
        <<Bytes:Len/binary, Rest2/binary>> ->
            {Bytes, Rest2};
        _ ->
            error(incomplete)
    end.

%% @private
decode_bytes_indefinite(<<16#FF, Rest/binary>>, Acc) ->
    {iolist_to_binary(lists:reverse(Acc)), Rest};
decode_bytes_indefinite(<<IB, Rest/binary>>, Acc) ->
    MT = IB bsr 5,
    AI = IB band 16#1F,
    case MT of
        ?MT_BYTES when AI =/= ?AI_INDEFINITE ->
            {Chunk, Rest2} = decode_bytes(AI, Rest),
            decode_bytes_indefinite(Rest2, [Chunk | Acc]);
        _ ->
            error({invalid_indefinite_chunk, MT})
    end;
decode_bytes_indefinite(<<>>, _Acc) ->
    error(incomplete).

%% @private
%% Decode text string (major type 3).
%% UTF-8 validation is skipped for performance (inspired by msgpack's approach).
%% The RFC 8949 requires text strings to be valid UTF-8, but validation
%% can be deferred to the application layer when needed.
%% Uses zero-copy sub-binary extraction: <<Text:Len/binary>> creates a
%% reference to the original binary, not a copy.
-spec decode_text(0..31, binary()) -> {binary(), binary()}.
decode_text(?AI_INDEFINITE, Bin) ->
    decode_text_indefinite(Bin, []);
decode_text(AI, Bin) ->
    {Len, Rest} = decode_arg(AI, Bin),
    case Rest of
        <<Text:Len/binary, Rest2/binary>> ->
            %% No UTF-8 validation for performance (msgpack-style)
            {Text, Rest2};
        _ ->
            error(incomplete)
    end.

%% @private
decode_text_indefinite(<<16#FF, Rest/binary>>, Acc) ->
    {iolist_to_binary(lists:reverse(Acc)), Rest};
decode_text_indefinite(<<IB, Rest/binary>>, Acc) ->
    MT = IB bsr 5,
    AI = IB band 16#1F,
    case MT of
        ?MT_TEXT when AI =/= ?AI_INDEFINITE ->
            {Chunk, Rest2} = decode_text(AI, Rest),
            decode_text_indefinite(Rest2, [Chunk | Acc]);
        _ ->
            error({invalid_indefinite_chunk, MT})
    end;
decode_text_indefinite(<<>>, _Acc) ->
    error(incomplete).

%% @private
%% Decode array (major type 4).
%% Uses <<Bin/binary>> wrapper for binary match context reuse optimization.
%% This pattern allows the BEAM to reuse the match context across recursive calls,
%% avoiding heap allocation for each element. Inspired by msgpack's unpacker.
-spec decode_array(0..31, binary()) -> {list(), binary()}.
decode_array(?AI_INDEFINITE, Bin) ->
    decode_array_indefinite(Bin, []);
decode_array(AI, Bin) ->
    {Len, Rest} = decode_arg(AI, Bin),
    decode_array_n(Len, Rest, []).

%% @private
%% Optimized array decoder with binary match context reuse.
%% Do not remove the <<Bin/binary>> wrapper - it enables match context reuse optimization.
decode_array_n(0, <<Bin/binary>>, Acc) ->
    {lists:reverse(Acc), Bin};
decode_array_n(N, <<Bin/binary>>, Acc) ->
    {Value, Rest} = decode_value(Bin),
    decode_array_n(N - 1, Rest, [Value | Acc]).

%% @private
decode_array_indefinite(<<16#FF, Rest/binary>>, Acc) ->
    {lists:reverse(Acc), Rest};
decode_array_indefinite(<<Bin/binary>>, Acc) ->
    {Value, Rest} = decode_value(Bin),
    decode_array_indefinite(Rest, [Value | Acc]).

%% @private
%% Decode map (major type 5).
%% Uses proplist accumulation then maps:from_list for efficiency.
%% Uses <<Bin/binary>> wrapper for binary match context reuse optimization.
%% Inspired by msgpack's unpacker.
-spec decode_map(0..31, binary()) -> {map(), binary()}.
decode_map(?AI_INDEFINITE, Bin) ->
    decode_map_indefinite(Bin, []);
decode_map(AI, Bin) ->
    {Len, Rest} = decode_arg(AI, Bin),
    decode_map_n(Len, Rest, []).

%% @private
%% Optimized map decoder with binary match context reuse.
%% Do not remove the <<Bin/binary>> wrapper - it enables match context reuse optimization.
%% Uses proplist accumulation to avoid repeated map updates (O(1) prepend vs O(log n) map update).
decode_map_n(0, <<Bin/binary>>, Acc) ->
    {maps:from_list(Acc), Bin};
decode_map_n(N, <<Bin/binary>>, Acc) ->
    {Key, Rest1} = decode_value(Bin),
    {Value, Rest2} = decode_value(Rest1),
    decode_map_n(N - 1, Rest2, [{Key, Value} | Acc]).

%% @private
decode_map_indefinite(<<16#FF, Rest/binary>>, Acc) ->
    {maps:from_list(Acc), Rest};
decode_map_indefinite(<<Bin/binary>>, Acc) ->
    {Key, Rest1} = decode_value(Bin),
    {Value, Rest2} = decode_value(Rest1),
    decode_map_indefinite(Rest2, [{Key, Value} | Acc]).

%% @private
%% Decode tag (major type 6).
-spec decode_tag(0..31, binary()) -> {decode_value(), binary()}.
decode_tag(AI, Bin) ->
    {Tag, Rest} = decode_arg(AI, Bin),
    {Value, Rest2} = decode_value(Rest),
    decode_tagged(Tag, Value, Rest2).

%% @private
%% Convert common tags to native types.
-spec decode_tagged(tag(), decode_value(), binary()) -> {decode_value(), binary()}.
decode_tagged(?TAG_POSITIVE_BIGNUM, Bytes, Rest) when is_binary(Bytes) ->
    {binary:decode_unsigned(Bytes), Rest};
decode_tagged(?TAG_NEGATIVE_BIGNUM, Bytes, Rest) when is_binary(Bytes) ->
    {-1 - binary:decode_unsigned(Bytes), Rest};
decode_tagged(?TAG_SELF_DESCRIBE, Value, Rest) ->
    %% Self-describing CBOR - unwrap the tag
    {Value, Rest};
decode_tagged(Tag, Value, Rest) ->
    {{tag, Tag, Value}, Rest}.

%% @private
%% Decode simple values and floats (major type 7).
-spec decode_simple(0..31, binary()) -> {decode_value(), binary()}.
decode_simple(?SIMPLE_FALSE, Bin) -> {false, Bin};
decode_simple(?SIMPLE_TRUE, Bin) -> {true, Bin};
decode_simple(?SIMPLE_NULL, Bin) -> {null, Bin};
decode_simple(?SIMPLE_UNDEFINED, Bin) -> {undefined, Bin};
decode_simple(24, <<V, Rest/binary>>) when V >= 32 ->
    %% Simple value in following byte
    {{simple, V}, Rest};
decode_simple(?AI_HALF_FLOAT, <<H:16, Rest/binary>>) ->
    {half_to_float(H), Rest};
decode_simple(?AI_SINGLE_FLOAT, <<F:32/float, Rest/binary>>) ->
    {F, Rest};
decode_simple(?AI_DOUBLE_FLOAT, <<F:64/float, Rest/binary>>) ->
    {F, Rest};
decode_simple(?AI_INDEFINITE, _Bin) ->
    error(unexpected_break);
decode_simple(AI, Bin) when AI < 20 ->
    {{simple, AI}, Bin};
decode_simple(_, <<>>) ->
    error(incomplete).

%%====================================================================
%% Internal - Custom Decoding with Callbacks
%%====================================================================

%% @private
%% Extract decoder callbacks once at entry point.
%% This optimization avoids repeated maps:get/3 calls during recursive
%% array/map decoding. Inspired by OTP json.erl's callback extraction pattern.
-spec extract_callbacks(decoders()) -> #dec_callbacks{}.
extract_callbacks(Decoders) ->
    #dec_callbacks{
        array_start = maps:get(array_start, Decoders, fun(_, A) -> A end),
        array_push = maps:get(array_push, Decoders, fun(_, A) -> A end),
        array_finish = maps:get(array_finish, Decoders, fun(A) -> {default, A} end),
        map_start = maps:get(map_start, Decoders, fun(_, A) -> A end),
        map_push = maps:get(map_push, Decoders, fun(_, A) -> A end),
        map_finish = maps:get(map_finish, Decoders, fun(A) -> {default, A} end),
        null_value = maps:get(null, Decoders, null),
        undefined_value = maps:get(undefined, Decoders, undefined)
    }.

%% @private
-spec decode_value_custom(binary(), Acc, decoders()) ->
    {decode_value(), binary(), Acc} when Acc :: term().
decode_value_custom(<<>>, _Acc, _Decoders) ->
    error(incomplete);
decode_value_custom(<<IB, Rest/binary>>, Acc, Decoders) ->
    %% Extract callbacks once at entry point for efficient recursive decoding
    Cbs = extract_callbacks(Decoders),
    decode_value_cached(<<IB, Rest/binary>>, Acc, Cbs).

%% @private
%% Decode with pre-extracted callbacks (avoids repeated maps:get calls).
%% This is the core optimization: callbacks are extracted once and passed
%% through all recursive calls, eliminating O(N) maps:get lookups for
%% arrays/maps of N elements. Pattern inspired by OTP json.erl.
-spec decode_value_cached(binary(), Acc, #dec_callbacks{}) ->
    {decode_value(), binary(), Acc} when Acc :: term().
decode_value_cached(<<>>, _Acc, _Cbs) ->
    error(incomplete);
decode_value_cached(<<IB, Rest/binary>>, Acc, Cbs) ->
    MT = IB bsr 5,
    AI = IB band 16#1F,
    decode_major_type_cached(MT, AI, Rest, Acc, Cbs).

%% @private
%% Dispatch to type-specific decoders using cached callbacks.
decode_major_type_cached(?MT_UNSIGNED, AI, Bin, Acc, _Cbs) ->
    {N, Rest} = decode_arg(AI, Bin),
    {N, Rest, Acc};
decode_major_type_cached(?MT_NEGATIVE, AI, Bin, Acc, _Cbs) ->
    {N, Rest} = decode_arg(AI, Bin),
    {-1 - N, Rest, Acc};
decode_major_type_cached(?MT_BYTES, AI, Bin, Acc, _Cbs) ->
    {Bytes, Rest} = decode_bytes(AI, Bin),
    {Bytes, Rest, Acc};
decode_major_type_cached(?MT_TEXT, AI, Bin, Acc, _Cbs) ->
    {Text, Rest} = decode_text(AI, Bin),
    {Text, Rest, Acc};
decode_major_type_cached(?MT_ARRAY, AI, Bin, Acc, Cbs) ->
    decode_array_cached(AI, Bin, Acc, Cbs);
decode_major_type_cached(?MT_MAP, AI, Bin, Acc, Cbs) ->
    decode_map_cached(AI, Bin, Acc, Cbs);
decode_major_type_cached(?MT_TAG, AI, Bin, Acc, Cbs) ->
    {Tag, Rest} = decode_arg(AI, Bin),
    {Value, Rest2, Acc2} = decode_value_cached(Rest, Acc, Cbs),
    case decode_tagged(Tag, Value, Rest2) of
        {{tag, T, V}, Rest3} -> {{tag, T, V}, Rest3, Acc2};
        {Converted, Rest3} -> {Converted, Rest3, Acc2}
    end;
decode_major_type_cached(?MT_SIMPLE, AI, Bin, Acc, Cbs) ->
    {Value, Rest} = decode_simple(AI, Bin),
    Value2 = case Value of
        null -> Cbs#dec_callbacks.null_value;
        undefined -> Cbs#dec_callbacks.undefined_value;
        _ -> Value
    end,
    {Value2, Rest, Acc}.

%% @private
%% Array decoding with cached callbacks - callbacks are passed directly,
%% eliminating maps:get calls on each element.
decode_array_cached(?AI_INDEFINITE, Bin, Acc, Cbs) ->
    ArrayStart = Cbs#dec_callbacks.array_start,
    Acc1 = ArrayStart(indefinite, Acc),
    decode_array_indefinite_cached(Bin, [], Acc1, Cbs);
decode_array_cached(AI, Bin, Acc, Cbs) ->
    {Len, Rest} = decode_arg(AI, Bin),
    ArrayStart = Cbs#dec_callbacks.array_start,
    Acc1 = ArrayStart(Len, Acc),
    decode_array_n_cached(Len, Rest, [], Acc1, Cbs).

%% @private
%% Decode N array elements with cached callbacks.
decode_array_n_cached(0, Bin, Items, Acc, Cbs) ->
    ArrayFinish = Cbs#dec_callbacks.array_finish,
    {Result, Acc2} = ArrayFinish(Acc),
    Result2 = case Result of
        default -> lists:reverse(Items);
        _ -> Result
    end,
    {Result2, Bin, Acc2};
decode_array_n_cached(N, Bin, Items, Acc, Cbs) ->
    {Value, Rest, Acc1} = decode_value_cached(Bin, Acc, Cbs),
    ArrayPush = Cbs#dec_callbacks.array_push,
    Acc2 = ArrayPush(Value, Acc1),
    decode_array_n_cached(N - 1, Rest, [Value | Items], Acc2, Cbs).

%% @private
%% Decode indefinite array with cached callbacks.
decode_array_indefinite_cached(<<16#FF, Rest/binary>>, Items, Acc, Cbs) ->
    ArrayFinish = Cbs#dec_callbacks.array_finish,
    {Result, Acc2} = ArrayFinish(Acc),
    Result2 = case Result of
        default -> lists:reverse(Items);
        _ -> Result
    end,
    {Result2, Rest, Acc2};
decode_array_indefinite_cached(Bin, Items, Acc, Cbs) ->
    {Value, Rest, Acc1} = decode_value_cached(Bin, Acc, Cbs),
    ArrayPush = Cbs#dec_callbacks.array_push,
    Acc2 = ArrayPush(Value, Acc1),
    decode_array_indefinite_cached(Rest, [Value | Items], Acc2, Cbs).

%% @private
%% Map decoding with cached callbacks - callbacks are passed directly,
%% eliminating maps:get calls on each key-value pair.
decode_map_cached(?AI_INDEFINITE, Bin, Acc, Cbs) ->
    MapStart = Cbs#dec_callbacks.map_start,
    Acc1 = MapStart(indefinite, Acc),
    decode_map_indefinite_cached(Bin, [], Acc1, Cbs);
decode_map_cached(AI, Bin, Acc, Cbs) ->
    {Len, Rest} = decode_arg(AI, Bin),
    MapStart = Cbs#dec_callbacks.map_start,
    Acc1 = MapStart(Len, Acc),
    decode_map_n_cached(Len, Rest, [], Acc1, Cbs).

%% @private
%% Decode N map pairs with cached callbacks.
%% Uses proplist accumulation then maps:from_list for efficiency
%% (inspired by msgpack's approach - avoids repeated map updates).
decode_map_n_cached(0, Bin, Pairs, Acc, Cbs) ->
    MapFinish = Cbs#dec_callbacks.map_finish,
    {Result, Acc2} = MapFinish(Acc),
    Result2 = case Result of
        default -> maps:from_list(lists:reverse(Pairs));
        _ -> Result
    end,
    {Result2, Bin, Acc2};
decode_map_n_cached(N, Bin, Pairs, Acc, Cbs) ->
    {Key, Rest1, Acc1} = decode_value_cached(Bin, Acc, Cbs),
    {Value, Rest2, Acc2} = decode_value_cached(Rest1, Acc1, Cbs),
    MapPush = Cbs#dec_callbacks.map_push,
    Acc3 = MapPush({Key, Value}, Acc2),
    decode_map_n_cached(N - 1, Rest2, [{Key, Value} | Pairs], Acc3, Cbs).

%% @private
%% Decode indefinite map with cached callbacks.
decode_map_indefinite_cached(<<16#FF, Rest/binary>>, Pairs, Acc, Cbs) ->
    MapFinish = Cbs#dec_callbacks.map_finish,
    {Result, Acc2} = MapFinish(Acc),
    Result2 = case Result of
        default -> maps:from_list(lists:reverse(Pairs));
        _ -> Result
    end,
    {Result2, Rest, Acc2};
decode_map_indefinite_cached(Bin, Pairs, Acc, Cbs) ->
    {Key, Rest1, Acc1} = decode_value_cached(Bin, Acc, Cbs),
    {Value, Rest2, Acc2} = decode_value_cached(Rest1, Acc1, Cbs),
    MapPush = Cbs#dec_callbacks.map_push,
    Acc3 = MapPush({Key, Value}, Acc2),
    decode_map_indefinite_cached(Rest2, [{Key, Value} | Pairs], Acc3, Cbs).


%% @private
%% Continue decoding from a continuation state.
-spec continue_decode(binary(), list(), term(), decoders()) ->
    {decode_value(), binary(), term()}.
continue_decode(Bin, [], Acc, Decoders) ->
    decode_value_custom(Bin, Acc, Decoders);
continue_decode(_Bin, _Stack, _Acc, _Decoders) ->
    %% More complex continuation handling would go here
    error(not_implemented).

%%====================================================================
%% Internal - Formatting (Diagnostic Notation)
%%====================================================================

%% @private
format_value(N) when is_integer(N) ->
    integer_to_list(N);
format_value(F) when is_float(F) ->
    format_float(F);
format_value(true) ->
    "true";
format_value(false) ->
    "false";
format_value(null) ->
    "null";
format_value(undefined) ->
    "undefined";
format_value(infinity) ->
    "Infinity";
format_value(neg_infinity) ->
    "-Infinity";
format_value(nan) ->
    "NaN";
format_value(Bin) when is_binary(Bin) ->
    format_bytes(Bin);
format_value({text, Bin}) when is_binary(Bin) ->
    format_text(Bin);
format_value(Atom) when is_atom(Atom) ->
    format_text(atom_to_binary(Atom, utf8));
format_value(List) when is_list(List) ->
    format_array(List);
format_value(Map) when is_map(Map) ->
    format_map(Map);
format_value({tag, Tag, Value}) ->
    [integer_to_list(Tag), "(", format_value(Value), ")"];
format_value({simple, N}) when is_integer(N) ->
    ["simple(", integer_to_list(N), ")"].

%% @private
format_float(F) ->
    case F of
        _ when F =/= F ->  % NaN check
            "NaN";
        _ ->
            case is_float(F) andalso F > 0 andalso F * 2 =:= F of
                true -> "Infinity";
                false ->
                    case is_float(F) andalso F < 0 andalso F * 2 =:= F of
                        true -> "-Infinity";
                        false -> io_lib:format("~p", [F])
                    end
            end
    end.

%% @private
format_bytes(Bin) ->
    ["h'", binary_to_list(binary_to_hex(Bin)), "'"].

%% @private
format_text(Bin) ->
    [$", escape_string(Bin), $"].

%% @private
format_array(List) ->
    ["[", lists:join(", ", [format_value(V) || V <- List]), "]"].

%% @private
format_map(Map) ->
    Pairs = maps:fold(
        fun(K, V, Acc) ->
            [[format_value(K), ": ", format_value(V)] | Acc]
        end,
        [],
        Map
    ),
    ["{", lists:join(", ", Pairs), "}"].

%% @private
binary_to_hex(Bin) ->
    << <<(hex_digit(H)), (hex_digit(L))>> || <<H:4, L:4>> <= Bin >>.

%% @private
hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

%% @private
escape_string(Bin) ->
    escape_string(Bin, []).

escape_string(<<>>, Acc) ->
    lists:reverse(Acc);
escape_string(<<$", Rest/binary>>, Acc) ->
    escape_string(Rest, [$", $\\ | Acc]);
escape_string(<<$\\, Rest/binary>>, Acc) ->
    escape_string(Rest, [$\\, $\\ | Acc]);
escape_string(<<$\n, Rest/binary>>, Acc) ->
    escape_string(Rest, [$n, $\\ | Acc]);
escape_string(<<$\r, Rest/binary>>, Acc) ->
    escape_string(Rest, [$r, $\\ | Acc]);
escape_string(<<$\t, Rest/binary>>, Acc) ->
    escape_string(Rest, [$t, $\\ | Acc]);
escape_string(<<C, Rest/binary>>, Acc) when C < 32 ->
    Hex = io_lib:format("\\u~4.16.0b", [C]),
    escape_string(Rest, [lists:reverse(lists:flatten(Hex)) | Acc]);
escape_string(<<C/utf8, Rest/binary>>, Acc) when C < 128 ->
    escape_string(Rest, [C | Acc]);
escape_string(<<C/utf8, Rest/binary>>, Acc) ->
    %% Multi-byte UTF-8 character, convert to list of bytes
    escape_string(Rest, lists:reverse(binary_to_list(<<C/utf8>>)) ++ Acc).
