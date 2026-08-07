%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(prop_bondy_error).
-moduledoc """
Property-based tests for `bondy_error`.

Two invariants carry the whole design, and both are stated here as executable
properties rather than as prose:

1. `from_term/1` is **total**. Every catch handler in Bondy funnels arbitrary
   exception reasons into it, so an exception raised from inside it would be
   raised from inside an error handler, where nothing is left to recover.

2. `to_map/1` output is **always JSON-encodable**. A term with no JSON
   counterpart reaching the encoder raises after the HTTP status and headers
   have been chosen, or inside the process writing to the socket.

The generators deliberately produce terms a JSON encoder cannot handle - pids,
references, funs, improper lists, bitstrings, non-UTF-8 binaries, deep nesting -
because those are precisely the terms that used to leak.
""".

-include_lib("proper/include/proper.hrl").

%% Properties
-export([prop_from_term_is_total/0]).
-export([prop_from_term_preserves_error_values/0]).
-export([prop_sanitise_is_json_encodable/0]).
-export([prop_to_map_is_json_encodable/0]).
-export([prop_to_map_keys_are_binaries/0]).
-export([prop_to_map_round_trips_the_uri/0]).

%% =============================================================================
%% GENERATORS
%% =============================================================================

%% A term with no JSON counterpart.
exotic() ->
    oneof([
        exactly(self()),
        exactly(make_ref()),
        exactly(fun() -> ok end),
        exactly([1, 2 | 3]),
        exactly(<<1:3>>),
        exactly(<<255, 254, 253>>),
        exactly(undefined),
        exactly(null),
        exactly(make_deep(64))
    ]).

%% A fixed pool rather than PropEr's atom(), which mints a fresh atom per case
%% and will exhaust the atom table on a long run.
some_atom() ->
    oneof([ok, error, undefined, null, true, false, badarg, timeout, 'a b']).

leaf() ->
    oneof([
        integer(),
        float(),
        boolean(),
        some_atom(),
        binary(),
        utf8(),
        exotic()
    ]).

hostile() ->
    ?SIZED(Size, hostile(Size)).

hostile(0) ->
    leaf();
hostile(Size) ->
    Smaller = hostile(Size div 3),
    oneof([
        leaf(),
        list(Smaller),
        ?LET({A, B}, {Smaller, Smaller}, {A, B}),
        ?LET({A, B, C}, {Smaller, Smaller, Smaller}, {A, B, C}),
        map(oneof([some_atom(), binary(), integer(), exotic()]), Smaller)
    ]).

%% The shapes bondy_error is expected to recognise, mixed in so the recognised
%% and unrecognised paths both get exercised.
known_shape() ->
    oneof([
        ?LET(T, oneof(bondy_error:types()), T),
        exactly(enoent),
        ?LET(K, binary(), {missing_required_value, K}),
        ?LET({K, V}, {binary(), hostile()}, {invalid_value, K, V}),
        ?LET(Ks, list(binary()), {inconsistency_error, Ks}),
        ?LET(U, utf8(), {no_such_realm, U}),
        ?LET(T, hostile(), {error, T})
    ]).

term_under_test() ->
    oneof([hostile(), known_shape()]).

%% =============================================================================
%% PROPERTIES
%% =============================================================================

prop_from_term_is_total() ->
    ?FORALL(
        Term,
        term_under_test(),
        bondy_error:is_type(bondy_error:from_term(Term))
    ).

%% An error value passed back in must come out unchanged, so that repeated
%% conversion along a call chain is harmless.
prop_from_term_preserves_error_values() ->
    ?FORALL(
        Term,
        term_under_test(),
        begin
            E = bondy_error:from_term(Term),
            E =:= bondy_error:from_term(E)
        end
    ).

prop_to_map_is_json_encodable() ->
    ?FORALL(
        Term,
        term_under_test(),
        is_encodable(bondy_error:to_map(bondy_error:from_term(Term)))
    ).

prop_sanitise_is_json_encodable() ->
    ?FORALL(
        Term,
        hostile(),
        %% Wrapped in a map because a bare sanitised value may be a number or a
        %% boolean, which are valid JSON but not valid JSON *documents*.
        is_encodable(#{~"v" => bondy_error:sanitise(Term)})
    ).

prop_to_map_keys_are_binaries() ->
    ?FORALL(
        Term,
        term_under_test(),
        begin
            Map = bondy_error:to_map(bondy_error:from_term(Term)),
            lists:all(fun is_binary/1, maps:keys(Map)) andalso
                lists:all(
                    fun is_binary/1, maps:keys(maps:get(~"details", Map))
                )
        end
    ).

%% The URI is the error's identity, so it must survive a round trip through the
%% projection - a relay hop, a stored payload, a re-raise.
prop_to_map_round_trips_the_uri() ->
    ?FORALL(
        Term,
        term_under_test(),
        begin
            E0 = bondy_error:from_term(Term),
            E1 = bondy_error:from_term(bondy_error:to_map(E0)),
            maps:get(uri, E0) =:= maps:get(uri, E1)
        end
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

is_encodable(Term) ->
    try
        _ = iolist_to_binary(json:encode(Term)),
        true
    catch
        Class:Reason ->
            io:format(
                "not encodable: ~0p~n  raised ~p:~0p~n", [Term, Class, Reason]
            ),
            false
    end.

make_deep(0) ->
    leaf_value;
make_deep(N) ->
    #{nested => [make_deep(N - 1)]}.
