%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Byte-exact MessagePack vectors at every size boundary the format switches
%% representation, the inputs the decoder must reject, and the published
%% cross-implementation suite.
-module(bondy_msgpack_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(M, bondy_msgpack).

all() ->
    [
        unsigned_integers,
        negative_integers,
        integers_outside_64_bits_are_refused,
        floats,
        atoms_and_nil,
        utf8_binaries_are_str,
        other_binaries_are_bin,
        explicit_binary_and_string_encoders,
        arrays,
        maps,
        every_small_array_and_map_size,
        unencodable_terms_are_refused,
        malformed_input_is_refused,
        published_suite_decodes_every_encoding,
        published_suite_encodes_to_a_listed_form,
        published_suite_extensions_are_refused
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_) ->
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

unsigned_integers(_) ->
    vectors([
        {0, <<16#00>>},
        {127, <<16#7F>>},
        {128, <<16#CC, 16#80>>},
        {255, <<16#CC, 16#FF>>},
        {256, <<16#CD, 16#01, 16#00>>},
        {65535, <<16#CD, 16#FF, 16#FF>>},
        {65536, <<16#CE, 0, 1, 0, 0>>},
        {16#FFFFFFFF, <<16#CE, 16#FF, 16#FF, 16#FF, 16#FF>>},
        {16#100000000, <<16#CF, 0, 0, 0, 1, 0, 0, 0, 0>>},
        {16#FFFFFFFFFFFFFFFF, <<16#CF, 16#FFFFFFFFFFFFFFFF:64>>}
    ]).

negative_integers(_) ->
    vectors([
        {-1, <<16#FF>>},
        {-32, <<16#E0>>},
        {-33, <<16#D0, 16#DF>>},
        {-128, <<16#D0, 16#80>>},
        {-129, <<16#D1, 16#FF, 16#7F>>},
        {-32768, <<16#D1, 16#80, 16#00>>},
        {-32769, <<16#D2, 16#FF, 16#FF, 16#7F, 16#FF>>},
        {-16#80000000, <<16#D2, 16#80, 0, 0, 0>>},
        {-16#80000001, <<16#D3, -16#80000001:64/signed>>},
        {-16#8000000000000000, <<16#D3, 16#80, 0, 0, 0, 0, 0, 0, 0>>}
    ]).

integers_outside_64_bits_are_refused(_) ->
    ?assertError({badarg, _}, enc(16#10000000000000000)),
    ?assertError({badarg, _}, enc(-16#8000000000000001)).

floats(_) ->
    ?assertEqual(<<16#CB, 1.5:64/float>>, enc(1.5)),
    ?assertEqual(1.5, ?M:decode(<<16#CB, 1.5:64/float>>)),
    %% float 32 is decoded although this encoder never writes it.
    ?assertEqual(1.5, ?M:decode(<<16#CA, 1.5:32/float>>)).

atoms_and_nil(_) ->
    ?assertEqual(<<16#C0>>, enc(undefined)),
    ?assertEqual(<<16#C0>>, enc(null)),
    ?assertEqual(<<16#C2>>, enc(false)),
    ?assertEqual(<<16#C3>>, enc(true)),
    ?assertEqual(<<16#A3, "foo">>, enc(foo)),
    ?assertEqual(undefined, ?M:decode(<<16#C0>>)),
    ?assertEqual(false, ?M:decode(<<16#C2>>)),
    ?assertEqual(true, ?M:decode(<<16#C3>>)).

utf8_binaries_are_str(_) ->
    vectors([
        {<<>>, <<16#A0>>},
        {text(31), <<16#BF, (text(31))/binary>>},
        {text(32), <<16#D9, 32, (text(32))/binary>>},
        {text(255), <<16#D9, 255, (text(255))/binary>>},
        {text(256), <<16#DA, 1, 0, (text(256))/binary>>},
        {text(65535), <<16#DA, 16#FF, 16#FF, (text(65535))/binary>>},
        {text(65536), <<16#DB, 0, 1, 0, 0, (text(65536))/binary>>},
        {<<"h", 16#C3, 16#A9>>, <<16#A3, "h", 16#C3, 16#A9>>}
    ]).

other_binaries_are_bin(_) ->
    vectors([
        {<<255>>, <<16#C4, 1, 255>>},
        %% A truncated multi-byte sequence is not valid UTF-8.
        {<<16#C3>>, <<16#C4, 1, 16#C3>>},
        {bytes(255), <<16#C4, 255, (bytes(255))/binary>>},
        {bytes(256), <<16#C5, 1, 0, (bytes(256))/binary>>},
        {bytes(65536), <<16#C6, 0, 1, 0, 0, (bytes(65536))/binary>>}
    ]).

%% `encode_binary/1` and `encode_string/1` choose the type explicitly, whatever
%% the content: the split `encode/1` makes by UTF-8 validity is theirs to bypass.
explicit_binary_and_string_encoders(_) ->
    ?assertEqual(
        <<16#C4, 3, "abc">>, iolist_to_binary(?M:encode_binary(<<"abc">>))
    ),
    ?assertEqual(
        <<16#A3, "abc">>, iolist_to_binary(?M:encode_string(<<"abc">>))
    ),
    ?assertEqual(<<16#CC, 200>>, iolist_to_binary(?M:encode_integer(200))),
    ?assertEqual(
        <<16#CB, 2.0:64/float>>, iolist_to_binary(?M:encode_float(2.0))
    ).

arrays(_) ->
    vectors([
        {[], <<16#90>>},
        {lists:duplicate(15, 1), <<16#9F, (binary:copy(<<1>>, 15))/binary>>},
        {
            lists:duplicate(16, 1),
            <<16#DC, 0, 16, (binary:copy(<<1>>, 16))/binary>>
        },
        {
            lists:duplicate(65536, 1),
            <<16#DD, 0, 1, 0, 0, (binary:copy(<<1>>, 65536))/binary>>
        },
        {[[1], [<<"a">>]], <<16#92, 16#91, 1, 16#91, 16#A1, "a">>}
    ]).

%% Key order on the wire is unspecified, so maps are checked by header and by
%% round trip rather than byte for byte.
maps(_) ->
    ?assertEqual(<<16#80>>, enc(#{})),
    ?assertEqual(<<16#81, 16#A1, "k", 1>>, enc(#{<<"k">> => 1})),
    Small = maps:from_list([{N, N} || N <- lists:seq(1, 15)]),
    Large = maps:from_list([{N, N} || N <- lists:seq(1, 16)]),
    <<16#8F, _/binary>> = enc(Small),
    <<16#DE, 0, 16, _/binary>> = enc(Large),
    ?assertEqual(Small, ?M:decode(enc(Small))),
    ?assertEqual(Large, ?M:decode(enc(Large))),
    %% A repeated key keeps its first value.
    ?assertEqual(#{1 => 2}, ?M:decode(<<16#82, 1, 2, 1, 3>>)).

%% The encoder has a clause per fixarray length and per small fixmap size;
%% this walks each one across the boundary to the general clause.
every_small_array_and_map_size(_) ->
    lists:foreach(
        fun(N) ->
            List = [<<"e">> || _ <- lists:seq(1, N)],
            Expected = iolist_to_binary([
                array_head(N), binary:copy(<<16#A1, "e">>, N)
            ]),
            ?assertEqual(Expected, enc(List)),
            ?assertEqual(List, ?M:decode(Expected))
        end,
        lists:seq(0, 16)
    ),
    lists:foreach(
        fun(N) ->
            Map = maps:from_list([{K, -K} || K <- lists:seq(1, N)]),
            <<Head, _/binary>> = Bin = enc(Map),
            ?assertEqual(16#80 + N, Head),
            ?assertEqual(Map, ?M:decode(Bin))
        end,
        lists:seq(0, 5)
    ).

array_head(N) when N < 16 -> <<(16#90 + N)>>;
array_head(N) -> <<16#DC, N:16>>.

unencodable_terms_are_refused(_) ->
    ?assertError({badarg, _}, enc({a, b})),
    ?assertError({badarg, _}, enc(self())),
    ?assertError({badarg, _}, enc([1, {a}])),
    ?assertError({badarg, _}, enc(#{k => fun() -> ok end})).

malformed_input_is_refused(_) ->
    Bad = [
        %% Reserved type.
        <<16#C1>>,
        %% fixext 1, ext 8: extension types are not WAMP values.
        <<16#D4, 1, 0>>,
        <<16#C7, 1, 1, 0>>,
        %% Truncated: uint 16 missing a byte, str 8 shorter than its length,
        %% an array missing an element.
        <<16#CD, 1>>,
        <<16#D9, 5, "abc">>,
        <<16#92, 1>>,
        %% Trailing bytes after one complete value.
        <<1, 2>>,
        <<>>
    ],
    lists:foreach(
        fun(B) ->
            ?assertError(badarg, ?M:decode(B))
        end,
        Bad
    ).

%% Every encoding the published suite lists for a value decodes to that value.
%% Numbers compare by value, as the suite lists float forms of integers.
published_suite_decodes_every_encoding(Config) ->
    Cases = [C || C <- published_cases(Config), not is_extension(C)],
    ?assert(length(Cases) >= 50),
    lists:foreach(
        fun(#{value := V, encodings := Encs, group := G}) ->
            lists:foreach(
                fun(E) ->
                    ?assert(
                        same_value(V, ?M:decode(E)),
                        {G, V, E, ?M:decode(E)}
                    )
                end,
                Encs
            )
        end,
        Cases
    ).

%% The encoding of each value is one of the forms the suite lists, except a
%% `binary` value that is valid UTF-8, which encodes as str (see README.md).
published_suite_encodes_to_a_listed_form(Config) ->
    lists:foreach(
        fun
            (#{group := <<"12.binary.yaml">>, value := V} = C) ->
                case unicode:characters_to_binary(V) of
                    V -> ?assert(is_str(enc(V)), {binary_as_str, V});
                    _ -> assert_listed(C)
                end;
            (C) ->
                is_extension(C) orelse assert_listed(C)
        end,
        published_cases(Config)
    ).

%% Extension types have no mapping here: every timestamp and ext encoding the
%% suite lists is refused.
published_suite_extensions_are_refused(Config) ->
    Ext = [C || C <- published_cases(Config), is_extension(C)],
    ?assert(length(Ext) >= 20),
    lists:foreach(
        fun(#{encodings := Encs}) ->
            [?assertError(badarg, ?M:decode(E)) || E <- Encs]
        end,
        Ext
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private The published suite's cases as `#{group, value, encodings}`, the
%% value converted to the Erlang term the codec maps it to.
published_cases(Config) ->
    File = filename:join(?config(data_dir, Config), "msgpack-test-suite.json"),
    {ok, Json} = file:read_file(File),
    [
        #{group => G, value => case_value(C), encodings => [hex(H) || H <- Hs]}
     || {G, Cases} <- lists:sort(maps:to_list(json:decode(Json))),
        #{<<"msgpack">> := Hs} = C <- Cases
    ].

%% @private
case_value(#{<<"bignum">> := B}) -> binary_to_integer(B);
case_value(#{<<"nil">> := _}) -> undefined;
case_value(#{<<"bool">> := B}) -> B;
case_value(#{<<"binary">> := H}) -> hex(H);
case_value(#{<<"number">> := N}) -> N;
case_value(#{<<"string">> := S}) -> S;
case_value(#{<<"array">> := A}) -> json_value(A);
case_value(#{<<"map">> := M}) -> json_value(M);
case_value(#{<<"timestamp">> := T}) -> {timestamp, T};
case_value(#{<<"ext">> := E}) -> {ext, E}.

%% @private A JSON value as the codec's Erlang term.
json_value(null) -> undefined;
json_value(L) when is_list(L) -> [json_value(E) || E <- L];
json_value(M) when is_map(M) -> maps:map(fun(_, V) -> json_value(V) end, M);
json_value(V) -> V.

%% @private
is_extension(#{value := {timestamp, _}}) -> true;
is_extension(#{value := {ext, _}}) -> true;
is_extension(_) -> false.

%% @private
assert_listed(#{value := V, encodings := Encs, group := G}) ->
    Ours = enc(V),
    ?assert(lists:member(Ours, Encs), {G, V, Ours}).

%% @private Numbers by value (the suite lists float forms of integers); all else
%% exactly.
same_value(A, B) when is_number(A), is_number(B) -> A == B;
same_value(A, B) when is_list(A), is_list(B), length(A) =:= length(B) ->
    lists:all(fun({X, Y}) -> same_value(X, Y) end, lists:zip(A, B));
same_value(A, B) when is_map(A), is_map(B), map_size(A) =:= map_size(B) ->
    lists:all(
        fun({K, V}) ->
            is_map_key(K, B) andalso same_value(V, maps:get(K, B))
        end,
        maps:to_list(A)
    );
same_value(A, B) ->
    A =:= B.

%% @private A str header: fixstr or str 8/16/32.
is_str(<<2#101:3, _:5, _/binary>>) -> true;
is_str(<<T, _/binary>>) when T >= 16#D9, T =< 16#DB -> true;
is_str(_) -> false.

%% @private The suite's hex form, octets separated by `-`.
hex(<<>>) ->
    <<>>;
hex(H) ->
    binary:decode_hex(binary:replace(H, <<"-">>, <<>>, [global])).

%% @private Each `{Term, Bytes}`: `Term` encodes to exactly `Bytes`, and `Bytes`
%% decodes back to `Term`.
vectors(Pairs) ->
    lists:foreach(
        fun({Term, Bytes}) ->
            ?assertEqual(Bytes, enc(Term), Term),
            ?assertEqual(Term, ?M:decode(Bytes), Bytes)
        end,
        Pairs
    ).

%% @private The encoded bytes of `Term`.
enc(Term) ->
    iolist_to_binary(?M:encode(Term)).

%% @private `N` bytes of valid UTF-8 text.
text(N) ->
    binary:copy(<<"a">>, N).

%% @private `N` bytes that are not valid UTF-8.
bytes(N) ->
    binary:copy(<<255>>, N).
