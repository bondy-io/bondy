%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(prop_bondy_interval_set).

-moduledoc """
Properties for `bondy_interval_set`, stated against a reference model: a plain
sorted list of the integer POINTS a set denotes. Every operation must agree with
the same operation on the model, which is what makes the interval encoding an
optimisation rather than a semantics.

The properties that matter most are the two the ancestry got wrong, and neither
is a happy-path check:

- `prop_from_list_order_invariant` — the antisymmetric-comparator defect. A
  shuffled input must give the same set.
- `prop_canonical_representation` — the `{N,N}` defect. Two constructors that
  denote the same set must return the same TERM, which is what licenses
  `is_equal/2` being `=:=`.
""".

-include_lib("proper/include/proper.hrl").

-define(M, bondy_interval_set).

-export([prop_from_list_matches_model/0]).
-export([prop_from_list_order_invariant/0]).
-export([prop_canonical_representation/0]).
-export([prop_no_adjacent_or_overlapping_elements/0]).
-export([prop_union_matches_model/0]).
-export([prop_intersection_matches_model/0]).
-export([prop_subtract_matches_model/0]).
-export([prop_add_matches_model/0]).
-export([prop_del_matches_model/0]).
-export([prop_is_element_matches_model/0]).
-export([prop_sizes_match_model/0]).
-export([prop_union_semilattice/0]).
-export([prop_add_idempotent/0]).
-export([prop_del_then_add_roundtrip/0]).
-export([prop_prefix_absorb/0]).

%% =============================================================================
%% GENERATORS
%% =============================================================================

element_gen() ->
    ?LET(
        A,
        integer(-8, 20),
        oneof([A, ?LET(W, integer(0, 5), {A, A + W})])
    ).

list_gen() ->
    list(element_gen()).

set_gen() ->
    ?LET(L, list_gen(), ?M:from_list(L)).

%% =============================================================================
%% MODEL
%% =============================================================================

points(L) ->
    lists:usort(
        lists:flatmap(
            fun
                ({A, B}) -> lists:seq(A, B);
                (N) -> [N]
            end,
            L
        )
    ).

%% =============================================================================
%% PROPERTIES
%% =============================================================================

prop_from_list_matches_model() ->
    ?FORALL(L, list_gen(), ?M:to_flat_list(?M:from_list(L)) =:= points(L)).

-doc "The comparator defect: a shuffled input must build the same set.".
prop_from_list_order_invariant() ->
    %% Tagging each member with a random key and sorting by it permutes the
    %% multiset, so the two lists differ only in order.
    ?FORALL(
        Tagged,
        list({integer(), element_gen()}),
        begin
            L = [E || {_, E} <- Tagged],
            Shuffled = [E || {_, E} <- lists:sort(Tagged)],
            ?M:from_list(L) =:= ?M:from_list(Shuffled)
        end
    ).

-doc """
The `{N,N}` defect: sets denoting the same points must be the same term, however
they were built. This is what makes `is_equal/2` sound as `=:=`.
""".
prop_canonical_representation() ->
    ?FORALL(
        {S, E},
        {set_gen(), element_gen()},
        begin
            Added = ?M:add_element(E, S),
            Rebuilt = ?M:from_list(?M:to_flat_list(Added)),
            Added =:= Rebuilt andalso ?M:is_equal(Added, Rebuilt)
        end
    ).

-doc "No two neighbouring elements may overlap or be adjacent, and no `{N,N}`.".
prop_no_adjacent_or_overlapping_elements() ->
    ?FORALL(
        S,
        set_gen(),
        begin
            NoDegenerate = [X || {A, B} = X <- S, A >= B] =:= [],
            Highs = [
                case X of
                    {_, H} -> H;
                    N -> N
                end
             || X <- S
            ],
            Lows = [
                case X of
                    {L, _} -> L;
                    N -> N
                end
             || X <- S
            ],
            Gapped =
                case {Highs, Lows} of
                    {[], []} ->
                        true;
                    _ ->
                        lists:all(
                            fun({H, L}) -> L > H + 1 end,
                            lists:zip(
                                lists:droplast(Highs), tl(Lows)
                            )
                        )
                end,
            NoDegenerate andalso Gapped
        end
    ).

prop_union_matches_model() ->
    ?FORALL(
        {A, B},
        {list_gen(), list_gen()},
        ?M:to_flat_list(?M:union(?M:from_list(A), ?M:from_list(B))) =:=
            lists:umerge(points(A), points(B))
    ).

prop_intersection_matches_model() ->
    ?FORALL(
        {A, B},
        {list_gen(), list_gen()},
        begin
            Pb = points(B),
            ?M:to_flat_list(?M:intersection(?M:from_list(A), ?M:from_list(B))) =:=
                [X || X <- points(A), lists:member(X, Pb)]
        end
    ).

prop_subtract_matches_model() ->
    ?FORALL(
        {A, B},
        {list_gen(), list_gen()},
        begin
            Pb = points(B),
            ?M:to_flat_list(?M:subtract(?M:from_list(A), ?M:from_list(B))) =:=
                [X || X <- points(A), not lists:member(X, Pb)]
        end
    ).

prop_add_matches_model() ->
    ?FORALL(
        {L, E},
        {list_gen(), element_gen()},
        ?M:to_flat_list(?M:add_element(E, ?M:from_list(L))) =:=
            lists:umerge(points(L), points([E]))
    ).

prop_del_matches_model() ->
    ?FORALL(
        {L, E},
        {list_gen(), element_gen()},
        begin
            Pe = points([E]),
            ?M:to_flat_list(?M:del_element(E, ?M:from_list(L))) =:=
                [X || X <- points(L), not lists:member(X, Pe)]
        end
    ).

prop_is_element_matches_model() ->
    ?FORALL(
        {L, E},
        {list_gen(), element_gen()},
        begin
            Pl = points(L),
            ?M:is_element(E, ?M:from_list(L)) =:=
                lists:all(fun(X) -> lists:member(X, Pl) end, points([E]))
        end
    ).

prop_sizes_match_model() ->
    ?FORALL(
        L,
        list_gen(),
        begin
            S = ?M:from_list(L),
            ?M:flat_size(S) =:= length(points(L)) andalso
                ?M:size(S) =:= length(S) andalso
                ?M:size(S) =< ?M:flat_size(S)
        end
    ).

-doc "Union is a semilattice: commutative, associative, idempotent.".
prop_union_semilattice() ->
    ?FORALL(
        {A, B, C},
        {set_gen(), set_gen(), set_gen()},
        ?M:union(A, B) =:= ?M:union(B, A) andalso
            ?M:union(?M:union(A, B), C) =:= ?M:union(A, ?M:union(B, C)) andalso
            ?M:union(A, A) =:= A
    ).

prop_add_idempotent() ->
    ?FORALL(
        {S, E},
        {set_gen(), element_gen()},
        begin
            Once = ?M:add_element(E, S),
            ?M:add_element(E, Once) =:= Once andalso ?M:is_element(E, Once)
        end
    ).

prop_del_then_add_roundtrip() ->
    ?FORALL(
        {S, E},
        {set_gen(), element_gen()},
        begin
            Deleted = ?M:del_element(E, S),
            not ?M:is_element(E, Deleted) orelse
                ?M:flat_size(?M:from_list([E])) =:= 0
        end andalso
            ?M:is_subset(?M:del_element(E, S), S)
    ).

-doc """
The operation the applied-frontier design needs: `subtract(S, [{0, P}])` absorbs
every point at or below `P`. Stated over positive points only, which is the
domain it is used in (seqs are >= 1).
""".
prop_prefix_absorb() ->
    ?FORALL(
        {L, P},
        {non_empty(list(integer(1, 20))), integer(0, 20)},
        begin
            S = ?M:from_list(L),
            Absorbed =
                case P of
                    0 -> S;
                    _ -> ?M:subtract(S, [{0, P}])
                end,
            ?M:to_flat_list(Absorbed) =:= [X || X <- points(L), X > P]
        end
    ).
