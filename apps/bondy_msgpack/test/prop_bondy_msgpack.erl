%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Property-based tests for `bondy_msgpack`: the round trip, and agreement
%% with the `msgpack` library (a test-only dependency) over the terms both
%% handle: no atoms, and only UTF-8 binaries, which the library cannot encode
%% otherwise.
-module(prop_bondy_msgpack).

-include_lib("proper/include/proper.hrl").

-export([prop_round_trip/0]).
-export([prop_agrees_with_library/0]).

-define(M, bondy_msgpack).
-define(LIB_ENCODE, [{map_format, map}, {pack_str, from_binary}]).
-define(LIB_DECODE, [{map_format, map}, {unpack_str, as_binary}]).

%% =============================================================================
%% Properties
%% =============================================================================

prop_round_trip() ->
    ?FORALL(
        T,
        term(3, any_binary()),
        begin
            Decoded = ?M:decode(iolist_to_binary(?M:encode(T))),
            ?WHENFAIL(
                io:format("~p~n=> ~p~n", [T, Decoded]),
                Decoded =:= normalise(T)
            )
        end
    ).

prop_agrees_with_library() ->
    ?FORALL(
        T,
        plain_term(3),
        begin
            Ours = iolist_to_binary(?M:encode(T)),
            Theirs = msgpack:pack(T, ?LIB_ENCODE),
            ?WHENFAIL(
                io:format("~p~nours:   ~w~ntheirs: ~w~n", [T, Ours, Theirs]),
                conjunction([
                    {library_decodes_ours,
                        msgpack:unpack(Ours, ?LIB_DECODE) =:= {ok, T}},
                    {we_decode_theirs, ?M:decode(Theirs) =:= T},
                    {same_bytes_without_maps, has_map(T) orelse Ours =:= Theirs}
                ])
            )
        end
    ).

%% =============================================================================
%% Generators
%% =============================================================================

%% Any term the codec encodes, binaries drawn from `Bin`.
term(0, Bin) ->
    oneof([
        int64(),
        float(),
        boolean(),
        exactly(undefined),
        exactly(null),
        oneof([exactly(foo), exactly('bar.baz')]),
        Bin
    ]);
term(N, Bin) ->
    oneof([
        term(0, Bin),
        list(term(N - 1, Bin)),
        %% Keys that decode alike (`undefined` and `null`, an atom and its
        %% name) cannot both survive the round trip, so maps never hold both.
        ?SUCHTHAT(
            M,
            map(term(0, Bin), term(N - 1, Bin)),
            length(lists:usort([normalise(K) || K <- maps:keys(M)])) =:=
                map_size(M)
        )
    ]).

%% The terms the library also encodes: no atoms, UTF-8 binaries only.
plain_term(0) ->
    oneof([int64(), float(), utf8()]);
plain_term(N) ->
    oneof([
        plain_term(0),
        list(plain_term(N - 1)),
        map(plain_term(0), plain_term(N - 1))
    ]).

any_binary() ->
    oneof([utf8(), binary()]).

%% Integers, weighted toward each width boundary and the value either side of it.
int64() ->
    frequency([
        {1, integer()},
        {1, integer(-16#8000000000000000, 16#FFFFFFFFFFFFFFFF)},
        {6,
            ?LET(
                {B, D},
                {
                    elements([
                        127,
                        16#FF,
                        16#FFFF,
                        16#FFFFFFFF,
                        -32,
                        -16#80,
                        -16#8000,
                        -16#80000000
                    ]),
                    elements([-1, 0, 1])
                },
                B + D
            )},
        {1, elements([16#FFFFFFFFFFFFFFFF, -16#8000000000000000])}
    ]).

%% =============================================================================
%% Helpers
%% =============================================================================

%% @private What `T` decodes to: nil is `undefined`, any other atom its name.
normalise(null) ->
    undefined;
normalise(A) when is_atom(A), A =/= undefined, A =/= true, A =/= false ->
    atom_to_binary(A, utf8);
normalise(L) when is_list(L) -> [normalise(E) || E <- L];
normalise(M) when is_map(M) ->
    maps:from_list([{normalise(K), normalise(V)} || {K, V} <- maps:to_list(M)]);
normalise(T) ->
    T.

%% @private
has_map(M) when is_map(M) -> true;
has_map(L) when is_list(L) -> lists:any(fun has_map/1, L);
has_map(_) -> false.
