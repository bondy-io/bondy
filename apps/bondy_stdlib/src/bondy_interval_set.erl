%% =============================================================================
%% SPDX-FileCopyrightText: 2022, 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_interval_set).

-moduledoc """
An ordered set of integer points represented as a coalesced list of intervals.

A contiguous run of integers becomes a single `{Low, High}` pair; an isolated
point stays a bare integer:

```
1> bondy_interval_set:from_list([1, 2, 4, 6, 7, 8, 9, 10]).
[{1,2},4,{6,10}]
```

The list is sorted by interval start and is fully compacted: no overlapping and
no *adjacent* elements survive `from_list/1`, `add_element/2` or any set
operation. Adjacency coalescing is what makes `size/1` the count of maximal
runs, and `flat_size/1` the count of points.

## Provenance

Vendored from the Bondy Lang `IntervalSet` port
(`bondy_lang/lib/interval_set.bondy`), which is the maintained implementation.
It descends from `partisan_interval_sets` and `interval_sets` (leapsight/utils),
and exists here so that `bondy_stdlib` consumers need neither dependency.

Two defects in the ancestry are fixed in the Bondy Lang port and preserved here;
each is pinned by a test named in the comment at its call site:

- the element comparator was not antisymmetric, so `from_list/1` silently
  dropped points from overlapping inputs (`from_list([9, {9,10}])` lost 10);
- `del_element/2` passed a *list* of remainder pieces back as a single element,
  raising `{badarg, List}` whenever deleting an interval that strictly contained
  a set element while a further interval followed it.

A third is fixed here and is **not** in any ancestor: `add_element/2` did not
normalise a degenerate `{N, N}` argument on the empty set, so
`add_element({5,5}, new())` returned `[{5,5}]` while `from_list([{5,5}])`
returned `[5]` — two unequal representations of the same set, breaking the
structural equality that compaction is supposed to guarantee. See
`is_equal/2`.

## Complexity

`add_element/2`, `del_element/2` and `is_element/2` walk the interval list: you
pay the number of intervals, not the number of points.

`union/2`, `intersection/2`, `subtract/2`, `is_subset/2` and `is_disjoint/2`
materialise both sets to flat point lists, delegate to `ordsets`, then
re-compact. Correct, but linear in total *points* — not appropriate for sets
holding very wide intervals such as `{1, 1000000}`.

## Element shape

A pair `{Low, High}` always satisfies `Low < High`; a pair with `Low =:= High`
is normalised to the bare integer.
""".

-type interval() :: {integer(), integer()}.
-type element() :: integer() | interval().
-type t() :: [element()].

-export_type([interval/0]).
-export_type([element/0]).
-export_type([t/0]).

%% API - Construction
-export([new/0]).
-export([from_list/1]).

%% API - Inspection
-export([is_type/1]).
-export([is_empty/1]).
-export([size/1]).
-export([flat_size/1]).
-export([min/1]).
-export([max/1]).

%% API - Conversion
-export([to_list/1]).
-export([to_flat_list/1]).

%% API - Membership
-export([is_element/2]).

%% API - Mutation
-export([add_element/2]).
-export([del_element/2]).

%% API - Set operations
-export([union/2]).
-export([union/1]).
-export([intersection/2]).
-export([intersection/1]).
-export([subtract/2]).
-export([is_subset/2]).
-export([is_superset/2]).
-export([is_disjoint/2]).
-export([is_equal/2]).

%% API - Iteration
-export([fold/3]).
-export([filter/2]).

%% =============================================================================
%% API - CONSTRUCTION
%% =============================================================================

-doc "Returns a new empty set.".
-spec new() -> t().

new() ->
    [].

-doc """
Builds a set from a list of elements, sorting, deduplicating and coalescing
overlapping and adjacent members.

Fails with `{badarg, Element}` on any member that is neither an integer nor a
well-formed `{Low, High}` pair with `Low =< High`.
""".
-spec from_list([element()]) -> t().

from_list(L) when is_list(L) ->
    ok = lists:foreach(fun validate_element/1, L),
    compact(lists:usort(fun compare_lex/2, L)).

%% =============================================================================
%% API - INSPECTION
%% =============================================================================

-doc "Returns `true` when `Term` is a well-formed interval set.".
-spec is_type(Term :: any()) -> boolean().

is_type(L) when is_list(L) ->
    lists:all(fun is_element_type/1, L);
is_type(_) ->
    false.

-doc "Returns `true` when the set holds no points.".
-spec is_empty(t()) -> boolean().

is_empty([]) ->
    true;
is_empty([_ | _]) ->
    false.

-doc """
Returns the number of elements, counting each interval once.

This is the number of maximal runs, which coalescing makes well defined. Use
`flat_size/1` for the number of points.
""".
-spec size(t()) -> non_neg_integer().

size(S) ->
    length(S).

-doc "Returns the total number of integer points the set represents.".
-spec flat_size(t()) -> non_neg_integer().

flat_size(S) ->
    lists:foldl(
        fun
            ({H, T}, Acc) -> Acc + 1 + T - H;
            (_, Acc) -> Acc + 1
        end,
        0,
        S
    ).

-doc """
Returns the smallest point in the set.

Fails with `empty_interval_set` when the set is empty.
""".
-spec min(t()) -> integer() | no_return().

min([]) ->
    error(empty_interval_set);
min([{H, _} | _]) ->
    H;
min([N | _]) ->
    N.

-doc """
Returns the largest point in the set.

Fails with `empty_interval_set` when the set is empty.
""".
-spec max(t()) -> integer() | no_return().

max([]) ->
    error(empty_interval_set);
max([H | T]) ->
    case lists:last([H | T]) of
        {_, X} -> X;
        N when is_integer(N) -> N
    end.

%% =============================================================================
%% API - CONVERSION
%% =============================================================================

-doc "Returns the elements of the set, intervals left coalesced.".
-spec to_list(t()) -> [element()].

to_list(S) ->
    S.

-doc """
Expands the set to a flat sorted list of integer points.

```
1> bondy_interval_set:to_flat_list([{1,2}, 4, {6,7}]).
[1,2,4,6,7]
```
""".
-spec to_flat_list(t()) -> [integer()].

to_flat_list(S) ->
    lists:flatmap(
        fun
            ({H, T}) -> lists:seq(H, T);
            (N) -> [N]
        end,
        S
    ).

%% =============================================================================
%% API - MEMBERSHIP
%% =============================================================================

-doc """
Returns `true` when every point `Element` covers is in the set.

`Element` may be a bare integer or a `{Low, High}` interval.
""".
-spec is_element(element(), t()) -> boolean().

is_element(E, S) ->
    ok = validate_element(E),
    do_is_element(E, S).

%% =============================================================================
%% API - MUTATION
%% =============================================================================

-doc """
Returns the set with `Element` inserted. Idempotent.

The result is canonical: a degenerate `{N, N}` argument is normalised to the
bare integer `N`, so `add_element({N,N}, S)` and `add_element(N, S)` return
identical terms. The ancestors normalised only on some paths.
""".
-spec add_element(element(), t()) -> t().

add_element(E, S) ->
    ok = validate_element(E),
    do_add_element(simplify(E), S).

-doc "Returns the set with every point of `Element` removed.".
-spec del_element(element(), t()) -> t().

del_element(E, S) ->
    ok = validate_element(E),
    do_del_element(E, S).

%% =============================================================================
%% API - SET OPERATIONS
%% =============================================================================

-doc "Returns the union of two sets.".
-spec union(t(), t()) -> t().

union(A, B) ->
    compact(ordsets:union(to_flat_list(A), to_flat_list(B))).

-doc "Returns the union of a list of sets.".
-spec union([t()]) -> t().

union(L) when is_list(L) ->
    compact(lists:umerge([to_flat_list(S) || S <- L])).

-doc "Returns the intersection of two sets.".
-spec intersection(t(), t()) -> t().

intersection(A, B) ->
    compact(ordsets:intersection(to_flat_list(A), to_flat_list(B))).

-doc """
Returns the intersection of a non-empty list of sets.

Fails with `badarg` on the empty list, which has no intersection.
""".
-spec intersection([t()]) -> t().

intersection([S]) ->
    S;
intersection([A, B | Rest]) ->
    lists:foldl(
        fun(S, Acc) -> intersection(Acc, S) end, intersection(A, B), Rest
    );
intersection([]) ->
    error(badarg).

-doc "Returns the points of `A` that are not in `B`.".
-spec subtract(A :: t(), B :: t()) -> t().

subtract(A, B) ->
    compact(ordsets:subtract(to_flat_list(A), to_flat_list(B))).

-doc "Returns `true` when every point of `A` is also in `B`.".
-spec is_subset(A :: t(), B :: t()) -> boolean().

is_subset(A, B) ->
    ordsets:is_subset(to_flat_list(A), to_flat_list(B)).

-doc "Returns `true` when every point of `B` is also in `A`.".
-spec is_superset(A :: t(), B :: t()) -> boolean().

is_superset(A, B) ->
    is_subset(B, A).

-doc "Returns `true` when the two sets share no point.".
-spec is_disjoint(t(), t()) -> boolean().

is_disjoint(A, B) ->
    ordsets:is_disjoint(to_flat_list(A), to_flat_list(B)).

-doc """
Returns `true` when both sets hold the same points.

Every function in this module returns a canonical value, so this is structural
equality and is O(#intervals). It is only sound because `add_element/2`
normalises `{N, N}`; see the module docs.
""".
-spec is_equal(t(), t()) -> boolean().

is_equal(A, B) ->
    A =:= B.

%% =============================================================================
%% API - ITERATION
%% =============================================================================

-doc """
Folds over the elements in ascending order.

Intervals are passed verbatim, not expanded to points.
""".
-spec fold(fun((element(), Acc) -> Acc), Acc, t()) -> Acc.

fold(Fun, Acc, S) when is_function(Fun, 2) ->
    lists:foldl(Fun, Acc, S).

-doc """
Keeps the elements for which `Pred` returns `true`.

`Pred` sees whole intervals, not points, so the result needs no re-compaction:
a subset of a coalesced list is coalesced.
""".
-spec filter(fun((element()) -> boolean()), t()) -> t().

filter(Pred, S) when is_function(Pred, 1) ->
    lists:filter(Pred, S).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Total order on elements: a bare integer `N` is read as `{N, N}` and pairs
%% compare lexicographically on `{Low, High}`. Non-strict, so it composes with
%% `lists:usort/2`, which drops members comparing equal in both directions.
%%
%% Antisymmetry on distinct elements is the property that matters and the one
%% the ancestor violated: `9` must sort strictly before `{9, 10}` because the
%% highs differ. Without it `usort/2` treated them as duplicates and
%% `from_list([9, {9,10}])` returned `[9]`, losing the point 10.
compare_lex({H1, T1}, {H2, T2}) ->
    (H1 < H2) orelse (H1 =:= H2 andalso T1 =< T2);
compare_lex({H, T}, N) when is_integer(N) ->
    (H < N) orelse (H =:= N andalso T =< N);
compare_lex(N, {H, T}) when is_integer(N) ->
    (N < H) orelse (N =:= H andalso N =< T);
compare_lex(A, B) when is_integer(A), is_integer(B) ->
    A =< B.

%% @private
interval({H, T}) -> {H, T};
interval(N) when is_integer(N) -> {N, N}.

%% @private
simplify({N, N}) -> N;
simplify(E) -> E.

%% @private
element_equal(A, A) -> true;
element_equal(N, {N, N}) -> true;
element_equal({N, N}, N) -> true;
element_equal(_, _) -> false.

%% @private
is_element_type(X) when is_integer(X) ->
    true;
is_element_type({X, Y}) when is_integer(X), is_integer(Y), X =< Y ->
    true;
is_element_type(_) ->
    false.

%% @private
validate_element(E) ->
    is_element_type(E) orelse error({badarg, E}),
    ok.

%% @private
do_is_element(_, []) ->
    false;
do_is_element(A, [B | Es]) ->
    case element_starts_before(A, B) orelse element_precedes(A, B) of
        true ->
            false;
        false ->
            case element_included(A, B) of
                true -> true;
                false -> element_succeeds(A, B) andalso do_is_element(A, Es)
            end
    end.

%% @private
%% `A` arrives already simplified, so the terminal clause is canonical — the
%% gap that made `add_element({5,5}, new())` return `[{5,5}]`.
do_add_element(E, []) ->
    [E];
do_add_element(A, [B | Es] = Set) ->
    case element_equal(A, B) of
        true ->
            Set;
        false ->
            case element_meets(A, B) of
                true ->
                    do_add_element(unsafe_element_union(A, B), Es);
                false ->
                    case element_precedes(A, B) of
                        true ->
                            [simplify(A) | Set];
                        false ->
                            case element_succeeds(A, B) of
                                true ->
                                    [B | do_add_element(A, Es)];
                                false ->
                                    case element_overlaps(A, B) of
                                        true ->
                                            do_add_element(
                                                unsafe_element_union(A, B), Es
                                            );
                                        false ->
                                            error(badarg)
                                    end
                            end
                    end
            end
    end.

%% @private
do_del_element(_, []) ->
    [];
do_del_element(A, [B | Es] = Set) ->
    case element_equal(A, B) of
        true ->
            Es;
        false ->
            case element_precedes(A, B) of
                true ->
                    Set;
                false ->
                    case element_succeeds(A, B) of
                        true ->
                            [B | do_del_element(A, Es)];
                        false ->
                            case element_overlaps(A, B) of
                                true ->
                                    I = element_intersection(A, B),
                                    New = [
                                        simplify(X)
                                     || X <- element_subtract(B, I)
                                    ],
                                    %% Removing the shared intersection can
                                    %% split `A` into 0, 1 or TWO disjoint
                                    %% pieces, and each must be deleted from
                                    %% the rest in turn. The ancestor passed
                                    %% the piece LIST itself as one element and
                                    %% raised `{badarg, List}` whenever a
                                    %% further interval followed `B`.
                                    New ++
                                        lists:foldl(
                                            fun do_del_element/2,
                                            Es,
                                            element_subtract(A, I)
                                        );
                                false ->
                                    error(badarg)
                            end
                    end
            end
    end.

%% =============================================================================
%% PRIVATE - ELEMENT ALGEBRA
%% =============================================================================

%% @private
element_includes({H1, T1}, {H2, T2}) -> H1 =< H2 andalso T1 >= T2;
element_includes({H, T}, N) when is_integer(N) -> H =< N andalso T >= N;
element_includes(N, {N, N}) when is_integer(N) -> true;
element_includes(N, {_, _}) when is_integer(N) -> false;
element_includes(N, M) -> N =:= M.

%% @private
element_included(A, B) ->
    element_includes(B, A).

%% @private
element_precedes({_, T1}, {H2, _}) -> T1 < H2;
element_precedes({_, T}, N) when is_integer(N) -> T < N;
element_precedes(N, {H, _}) when is_integer(N) -> N < H;
element_precedes(N, M) -> N < M.

%% @private
element_succeeds(A, B) ->
    element_precedes(B, A).

%% @private
element_starts_before({H1, _}, {H2, _}) -> H1 < H2;
element_starts_before({H, _}, N) when is_integer(N) -> H < N;
element_starts_before(N, {H, _}) when is_integer(N) -> N < H;
element_starts_before(N, M) -> N < M.

%% @private
element_overlaps({H1, T1}, {H2, T2}) ->
    H1 =< T2 andalso H2 =< T1;
element_overlaps({_, _} = A, N) when is_integer(N) ->
    element_overlaps(A, interval(N));
element_overlaps(N, {_, _} = B) when is_integer(N) ->
    element_overlaps(interval(N), B);
element_overlaps(A, B) ->
    A =:= B.

%% @private
%% Adjacency: the property that keeps the representation coalesced, and so
%% keeps `size/1` equal to the number of maximal runs.
element_meets({H1, T1} = A, {H2, T2} = B) ->
    (element_precedes(A, B) andalso H2 =:= T1 + 1) orelse
        (element_precedes(B, A) andalso H1 =:= T2 + 1);
element_meets({_, _} = A, N) when is_integer(N) ->
    element_meets(A, interval(N));
element_meets(N, {_, _} = B) when is_integer(N) ->
    element_meets(interval(N), B);
element_meets(A, B) ->
    abs(A - B) =:= 1.

%% @private
%% Assumes the elements meet or overlap; undefined otherwise.
unsafe_element_union(A, B) ->
    {H1, T1} = interval(A),
    {H2, T2} = interval(B),
    {erlang:min(H1, H2), erlang:max(T1, T2)}.

%% @private
element_intersection(A, B) ->
    element_overlaps(A, B) orelse error(badarg),
    {H1, T1} = interval(A),
    {H2, T2} = interval(B),
    {erlang:max(H1, H2), erlang:min(T1, T2)}.

%% @private
%% The points of `A` that `B` does not cover: 0, 1 or 2 pieces.
element_subtract(A, B) ->
    case
        element_precedes(A, B) orelse
            element_included(A, B) orelse
            element_succeeds(A, B)
    of
        true ->
            [];
        false ->
            {H1, T1} = interval(A),
            {H2, T2} = interval(B),
            if
                H1 >= H2, T1 > T2 ->
                    [{erlang:max(T2 + 1, H1), T1}];
                H1 < H2, T1 =< T2 ->
                    [{H1, erlang:min(H2 - 1, T1)}];
                H1 < H2, T1 > T2 ->
                    [{H1, H2 - 1}, {T2 + 1, T1}];
                true ->
                    error(badarg)
            end
    end.

%% =============================================================================
%% PRIVATE - COMPACTION
%% =============================================================================

%% @private
%% Collapses a sorted but uncoalesced list into a canonical set.
compact([]) ->
    [];
compact([E1 | Es]) ->
    compact_step(Es, [], E1).

%% @private
compact_step([], Acc, E) ->
    lists:reverse([simplify(E) | Acc]);
compact_step([E | Es], Acc, E) ->
    compact_step(Es, Acc, E);
compact_step([{V3, V4} | Es], Acc, {V1, V2}) when V2 + 1 >= V3, V2 =< V4 ->
    compact_step(Es, Acc, {V1, V4});
compact_step([{V3, V4} | Es], Acc, {_, V2} = E1) when V2 + 1 >= V3, V2 > V4 ->
    compact_step(Es, Acc, E1);
compact_step([{_, _} = E2 | Es], Acc, {_, _} = E1) ->
    compact_step(Es, [simplify(E1) | Acc], E2);
compact_step([{V1, V2} | Es], Acc, E1) when
    is_integer(E1), E1 + 1 >= V1, E1 =< V2
->
    compact_step(Es, Acc, {E1, V2});
compact_step([{_, _} = E2 | Es], Acc, E1) when is_integer(E1) ->
    compact_step(Es, [simplify(E1) | Acc], E2);
compact_step([E2 | Es], Acc, {V1, V2}) when is_integer(E2), E2 - 1 =< V2 ->
    compact_step(Es, Acc, {V1, erlang:max(E2, V2)});
compact_step([E2 | Es], Acc, {_, _} = E1) when is_integer(E2) ->
    compact_step(Es, [simplify(E1) | Acc], E2);
compact_step([E2 | Es], Acc, E1) when
    is_integer(E1), is_integer(E2), E1 + 1 =:= E2
->
    compact_step(Es, Acc, {E1, E2});
compact_step([E2 | Es], Acc, E1) when is_integer(E1), is_integer(E2) ->
    compact_step(Es, [simplify(E1) | Acc], E2).
