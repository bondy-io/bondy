%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_msgpack).

-moduledoc """
MessagePack encoding and decoding of Erlang terms.

nil maps to `undefined`, as it does in Bondy's JSON and CBOR codecs
(`bondy_wamp_encoding_SUITE:null_maps_alike_across_encodings_test/1`). The full
mapping:

| Erlang                        | MessagePack                          |
|-------------------------------|--------------------------------------|
| `undefined`, `null`           | nil (decoded as `undefined`)         |
| `true`, `false`               | bool                                 |
| any other atom                | str of the atom's name               |
| integer (64-bit range)        | the smallest int or uint that fits   |
| float                         | float 64 (float 32 is decoded too)   |
| binary, valid UTF-8           | str                                  |
| binary, not valid UTF-8       | bin                                  |
| list                          | array                                |
| map                           | map                                  |

Both str and bin decode to a binary. Extension types have no Erlang mapping
here and are rejected, as are the reserved type `0xC1`,
truncated input and trailing bytes. Encoding any other term, or an integer
outside the 64-bit range, raises `badarg`.
""".

-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).
-define(MIN_INT64, -16#8000000000000000).

-export([encode/1]).
-export([encode_integer/1]).
-export([encode_float/1]).
-export([encode_binary/1]).
-export([encode_string/1]).
-export([decode/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Encodes `Term` as MessagePack. Raises `{badarg, Term}` for a term with no
MessagePack form.
""".
-spec encode(term()) -> iodata() | no_return().

encode(Term) ->
    encode_value(Term).

-doc """
Encodes an integer as the smallest MessagePack int or uint that holds it.
Raises `{badarg, N}` outside the 64-bit range.
""".
-spec encode_integer(integer()) -> iodata() | no_return().

encode_integer(N) when is_integer(N), N >= 0 ->
    encode_unsigned(N);
encode_integer(N) when is_integer(N) ->
    encode_negative(N).

-doc "Encodes a float as a MessagePack float 64.".
-spec encode_float(float()) -> iodata().

encode_float(F) when is_float(F) ->
    <<16#CB, F:64/big-float>>.

-doc "Encodes a binary as a MessagePack bin, whatever its content.".
-spec encode_binary(binary()) -> iodata() | no_return().

encode_binary(Bin) when is_binary(Bin) ->
    case byte_size(Bin) of
        L when L =< 16#FF -> [<<16#C4, L>>, Bin];
        L when L =< 16#FFFF -> [<<16#C5, L:16>>, Bin];
        L when L =< 16#FFFFFFFF -> [<<16#C6, L:32>>, Bin];
        _ -> error({badarg, Bin})
    end.

-doc """
Encodes a binary as a MessagePack str. The binary must be valid UTF-8; this is
not checked.
""".
-spec encode_string(binary()) -> iodata() | no_return().

encode_string(Bin) when is_binary(Bin) ->
    case byte_size(Bin) of
        L when L < 32 -> [<<2#101:3, L:5>>, Bin];
        L when L =< 16#FF -> [<<16#D9, L>>, Bin];
        L when L =< 16#FFFF -> [<<16#DA, L:16>>, Bin];
        L when L =< 16#FFFFFFFF -> [<<16#DB, L:32>>, Bin];
        _ -> error({badarg, Bin})
    end.

-doc """
Decodes exactly one MessagePack value occupying all of `Bin`. Raises `badarg`
on malformed, truncated or trailing input, or an extension type.
""".
-spec decode(binary()) -> term() | no_return().

decode(Bin) when is_binary(Bin) ->
    case decode_value(Bin) of
        {Term, <<>>} -> Term;
        {_, _} -> error(badarg)
    end.

%% =============================================================================
%% PRIVATE — encoding
%% =============================================================================

%% @private
encode_value(N) when is_integer(N), N >= 0, N < 16#80 ->
    <<N>>;
encode_value(N) when is_integer(N), N >= 16#80, N =< 16#FF ->
    <<16#CC, N>>;
encode_value(N) when is_integer(N), N >= 16#100, N =< 16#FFFF ->
    <<16#CD, N:16>>;
encode_value(N) when is_integer(N) ->
    encode_integer(N);
encode_value(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Bin -> encode_string(Bin);
        _ -> encode_binary(Bin)
    end;
encode_value(F) when is_float(F) ->
    encode_float(F);
encode_value(undefined) ->
    <<16#C0>>;
encode_value(null) ->
    <<16#C0>>;
encode_value(false) ->
    <<16#C2>>;
encode_value(true) ->
    <<16#C3>>;
encode_value(Atom) when is_atom(Atom) ->
    encode_string(atom_to_binary(Atom, utf8));
encode_value([]) ->
    <<16#90>>;
encode_value([A]) ->
    [<<16#91>>, encode_value(A)];
encode_value([A, B]) ->
    [<<16#92>>, encode_value(A), encode_value(B)];
encode_value([A, B, C]) ->
    [<<16#93>>, encode_value(A), encode_value(B), encode_value(C)];
encode_value([A, B, C, D]) ->
    [
        <<16#94>>,
        encode_value(A),
        encode_value(B),
        encode_value(C),
        encode_value(D)
    ];
encode_value([A, B, C, D, E]) ->
    [
        <<16#95>>,
        encode_value(A),
        encode_value(B),
        encode_value(C),
        encode_value(D),
        encode_value(E)
    ];
encode_value([A, B, C, D, E, F]) ->
    [
        <<16#96>>,
        encode_value(A),
        encode_value(B),
        encode_value(C),
        encode_value(D),
        encode_value(E),
        encode_value(F)
    ];
encode_value([A, B, C, D, E, F, G]) ->
    [
        <<16#97>>,
        encode_value(A),
        encode_value(B),
        encode_value(C),
        encode_value(D),
        encode_value(E),
        encode_value(F),
        encode_value(G)
    ];
encode_value([A, B, C, D, E, F, G, H]) ->
    [
        <<16#98>>,
        encode_value(A),
        encode_value(B),
        encode_value(C),
        encode_value(D),
        encode_value(E),
        encode_value(F),
        encode_value(G),
        encode_value(H)
    ];
encode_value([A, B, C, D, E, F, G, H, I]) ->
    [
        <<16#99>>,
        encode_value(A),
        encode_value(B),
        encode_value(C),
        encode_value(D),
        encode_value(E),
        encode_value(F),
        encode_value(G),
        encode_value(H),
        encode_value(I)
    ];
encode_value([A, B, C, D, E, F, G, H, I, J]) ->
    [
        <<16#9A>>,
        encode_value(A),
        encode_value(B),
        encode_value(C),
        encode_value(D),
        encode_value(E),
        encode_value(F),
        encode_value(G),
        encode_value(H),
        encode_value(I),
        encode_value(J)
    ];
encode_value([A, B, C, D, E, F, G, H, I, J, K]) ->
    [
        <<16#9B>>,
        encode_value(A),
        encode_value(B),
        encode_value(C),
        encode_value(D),
        encode_value(E),
        encode_value(F),
        encode_value(G),
        encode_value(H),
        encode_value(I),
        encode_value(J),
        encode_value(K)
    ];
encode_value([A, B, C, D, E, F, G, H, I, J, K, L]) ->
    [
        <<16#9C>>,
        encode_value(A),
        encode_value(B),
        encode_value(C),
        encode_value(D),
        encode_value(E),
        encode_value(F),
        encode_value(G),
        encode_value(H),
        encode_value(I),
        encode_value(J),
        encode_value(K),
        encode_value(L)
    ];
encode_value([A, B, C, D, E, F, G, H, I, J, K, L, M]) ->
    [
        <<16#9D>>,
        encode_value(A),
        encode_value(B),
        encode_value(C),
        encode_value(D),
        encode_value(E),
        encode_value(F),
        encode_value(G),
        encode_value(H),
        encode_value(I),
        encode_value(J),
        encode_value(K),
        encode_value(L),
        encode_value(M)
    ];
encode_value([A, B, C, D, E, F, G, H, I, J, K, L, M, N]) ->
    [
        <<16#9E>>,
        encode_value(A),
        encode_value(B),
        encode_value(C),
        encode_value(D),
        encode_value(E),
        encode_value(F),
        encode_value(G),
        encode_value(H),
        encode_value(I),
        encode_value(J),
        encode_value(K),
        encode_value(L),
        encode_value(M),
        encode_value(N)
    ];
encode_value([A, B, C, D, E, F, G, H, I, J, K, L, M, N, O]) ->
    [
        <<16#9F>>,
        encode_value(A),
        encode_value(B),
        encode_value(C),
        encode_value(D),
        encode_value(E),
        encode_value(F),
        encode_value(G),
        encode_value(H),
        encode_value(I),
        encode_value(J),
        encode_value(K),
        encode_value(L),
        encode_value(M),
        encode_value(N),
        encode_value(O)
    ];
encode_value(List) when is_list(List) ->
    [encode_array_head(length(List)) | [encode_value(E) || E <- List]];
encode_value(Map) when map_size(Map) =:= 0 ->
    <<16#80>>;
encode_value(Map) when map_size(Map) =:= 1 ->
    [{K1, V1}] = maps:to_list(Map),
    [<<16#81>>, encode_value(K1), encode_value(V1)];
encode_value(Map) when map_size(Map) =:= 2 ->
    [{K1, V1}, {K2, V2}] = maps:to_list(Map),
    [
        <<16#82>>,
        encode_value(K1),
        encode_value(V1),
        encode_value(K2),
        encode_value(V2)
    ];
encode_value(Map) when map_size(Map) =:= 3 ->
    [{K1, V1}, {K2, V2}, {K3, V3}] = maps:to_list(Map),
    [
        <<16#83>>,
        encode_value(K1),
        encode_value(V1),
        encode_value(K2),
        encode_value(V2),
        encode_value(K3),
        encode_value(V3)
    ];
encode_value(Map) when map_size(Map) =:= 4 ->
    [{K1, V1}, {K2, V2}, {K3, V3}, {K4, V4}] = maps:to_list(Map),
    [
        <<16#84>>,
        encode_value(K1),
        encode_value(V1),
        encode_value(K2),
        encode_value(V2),
        encode_value(K3),
        encode_value(V3),
        encode_value(K4),
        encode_value(V4)
    ];
encode_value(Map) when is_map(Map) ->
    [encode_map_head(map_size(Map)) | encode_map_pairs(maps:iterator(Map))];
encode_value(Term) ->
    error({badarg, Term}).

%% @private
encode_map_pairs(Iter) ->
    case maps:next(Iter) of
        none ->
            [];
        {K, V, Next} ->
            [encode_value(K), encode_value(V) | encode_map_pairs(Next)]
    end.

%% @private
encode_unsigned(N) when N < 16#80 -> <<N>>;
encode_unsigned(N) when N =< 16#FF -> <<16#CC, N>>;
encode_unsigned(N) when N =< 16#FFFF -> <<16#CD, N:16>>;
encode_unsigned(N) when N =< 16#FFFFFFFF -> <<16#CE, N:32>>;
encode_unsigned(N) when N =< ?MAX_UINT64 -> <<16#CF, N:64>>;
encode_unsigned(N) -> error({badarg, N}).

%% @private
encode_negative(N) when N >= -32 -> <<N:8/signed>>;
encode_negative(N) when N >= -16#80 -> <<16#D0, N:8/signed>>;
encode_negative(N) when N >= -16#8000 -> <<16#D1, N:16/signed>>;
encode_negative(N) when N >= -16#80000000 -> <<16#D2, N:32/signed>>;
encode_negative(N) when N >= ?MIN_INT64 -> <<16#D3, N:64/signed>>;
encode_negative(N) -> error({badarg, N}).

%% @private
encode_array_head(L) when L < 16 -> <<2#1001:4, L:4>>;
encode_array_head(L) when L =< 16#FFFF -> <<16#DC, L:16>>;
encode_array_head(L) when L =< 16#FFFFFFFF -> <<16#DD, L:32>>.

%% @private
encode_map_head(L) when L < 16 -> <<2#1000:4, L:4>>;
encode_map_head(L) when L =< 16#FFFF -> <<16#DE, L:16>>;
encode_map_head(L) when L =< 16#FFFFFFFF -> <<16#DF, L:32>>.

%% =============================================================================
%% PRIVATE — decoding
%% =============================================================================

%% @private Decodes one value from the head of the binary, returning it with the
%% rest. Raises `badarg` on anything that is not a complete, supported value.
decode_value(<<0:1, N:7, R/binary>>) -> {N, R};
decode_value(<<2#111:3, N:5, R/binary>>) -> {N - 32, R};
decode_value(<<2#1000:4, L:4, R/binary>>) -> decode_map(L, R);
decode_value(<<2#1001:4, L:4, R/binary>>) -> decode_array(L, R);
decode_value(<<2#101:3, L:5, B:L/binary, R/binary>>) -> {B, R};
decode_value(<<16#C0, R/binary>>) -> {undefined, R};
decode_value(<<16#C2, R/binary>>) -> {false, R};
decode_value(<<16#C3, R/binary>>) -> {true, R};
decode_value(<<16#C4, L, B:L/binary, R/binary>>) -> {B, R};
decode_value(<<16#C5, L:16, B:L/binary, R/binary>>) -> {B, R};
decode_value(<<16#C6, L:32, B:L/binary, R/binary>>) -> {B, R};
decode_value(<<16#CA, F:32/float, R/binary>>) -> {F, R};
decode_value(<<16#CB, F:64/float, R/binary>>) -> {F, R};
decode_value(<<16#CC, N, R/binary>>) -> {N, R};
decode_value(<<16#CD, N:16, R/binary>>) -> {N, R};
decode_value(<<16#CE, N:32, R/binary>>) -> {N, R};
decode_value(<<16#CF, N:64, R/binary>>) -> {N, R};
decode_value(<<16#D0, N:8/signed, R/binary>>) -> {N, R};
decode_value(<<16#D1, N:16/signed, R/binary>>) -> {N, R};
decode_value(<<16#D2, N:32/signed, R/binary>>) -> {N, R};
decode_value(<<16#D3, N:64/signed, R/binary>>) -> {N, R};
decode_value(<<16#D9, L, B:L/binary, R/binary>>) -> {B, R};
decode_value(<<16#DA, L:16, B:L/binary, R/binary>>) -> {B, R};
decode_value(<<16#DB, L:32, B:L/binary, R/binary>>) -> {B, R};
decode_value(<<16#DC, L:16, R/binary>>) -> decode_array(L, R);
decode_value(<<16#DD, L:32, R/binary>>) -> decode_array(L, R);
decode_value(<<16#DE, L:16, R/binary>>) -> decode_map(L, R);
decode_value(<<16#DF, L:32, R/binary>>) -> decode_map(L, R);
decode_value(_) -> error(badarg).

%% @private
decode_array(L, R) ->
    decode_array(L, R, []).

decode_array(0, <<R/binary>>, Acc) ->
    {lists:reverse(Acc), R};
decode_array(L, <<R0/binary>>, Acc) ->
    {V, R} = decode_value(R0),
    decode_array(L - 1, R, [V | Acc]).

%% @private A repeated key keeps its first value (`bondy_msgpack_SUITE:maps/1`).
decode_map(L, R) ->
    decode_map(L, R, []).

decode_map(0, <<R/binary>>, Acc) ->
    {maps:from_list(Acc), R};
decode_map(L, <<R0/binary>>, Acc) ->
    {K, R1} = decode_value(R0),
    {V, R} = decode_value(R1),
    decode_map(L - 1, R, [{K, V} | Acc]).
