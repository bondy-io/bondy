%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_interval_set_test).

-include_lib("eunit/include/eunit.hrl").

-define(M, bondy_interval_set).

%% =============================================================================
%% REGRESSIONS
%%
%% One case per defect inherited from the ancestry. Each fails on at least one
%% ancestor; the module docs name which.
%% =============================================================================

-doc """
`from_list/1` dropped points when a bare integer and an interval shared a low
bound, because the comparator was not antisymmetric and `usort/2` treated them
as duplicates. Fails on `interval_sets` (leapsight/utils), which answers `[9]`.
""".
non_antisymmetric_comparator_test_() ->
    [
        ?_assertEqual([{9, 10}], ?M:from_list([9, {9, 10}])),
        ?_assertEqual([{9, 10}], ?M:from_list([{9, 10}, 9])),
        ?_assertEqual([{1, 3}], ?M:from_list([1, {1, 3}, 2])),
        ?_assertEqual([{1, 5}], ?M:from_list([{1, 5}, {2, 3}])),
        %% the property the comparator must have: order of the input list
        %% cannot change the result
        ?_assertEqual(
            ?M:from_list([9, {9, 10}, {2, 4}, 3]),
            ?M:from_list([3, {2, 4}, {9, 10}, 9])
        )
    ].

-doc """
Deleting an interval that strictly contains a set element splits it into TWO
remainder pieces; the ancestor passed the piece list back as a single element.
Fails on `interval_sets` with `{badarg, [{3,4},{7,8}]}`.
""".
two_piece_delete_split_test_() ->
    [
        ?_assertEqual([{11, 12}], ?M:del_element({3, 8}, [{5, 6}, {11, 12}])),
        ?_assertEqual([], ?M:del_element({1, 10}, [{5, 6}, {8, 9}])),
        ?_assertEqual(
            [1, {11, 12}], ?M:del_element({3, 8}, [1, {5, 6}, {11, 12}])
        ),
        %% control: the 0- and 1-piece cases the ancestor handled
        ?_assertEqual([{1, 4}, {7, 10}], ?M:del_element({5, 6}, [{1, 10}])),
        ?_assertEqual([{1, 4}, {6, 10}], ?M:del_element(5, [{1, 10}]))
    ].

-doc """
`add_element/2` left a degenerate `{N, N}` unnormalised, so two constructors
produced unequal terms for the same set. Fails on BOTH ancestors, which answer
`[{5,5}]`. This is what makes `is_equal/2` structural.
""".
degenerate_interval_is_normalised_test_() ->
    [
        ?_assertEqual([5], ?M:add_element({5, 5}, ?M:new())),
        ?_assertEqual(?M:from_list([{5, 5}]), ?M:add_element({5, 5}, ?M:new())),
        ?_assertEqual([{1, 3}, 7], ?M:add_element({7, 7}, [{1, 3}])),
        ?_assert(
            ?M:is_equal(?M:add_element({5, 5}, ?M:new()), ?M:from_list([5]))
        ),
        %% and the two spellings of the same insertion agree
        ?_assertEqual(
            ?M:add_element(5, ?M:from_list([1, 9])),
            ?M:add_element({5, 5}, ?M:from_list([1, 9]))
        )
    ].

%% =============================================================================
%% CORE BEHAVIOUR
%% =============================================================================

coalescing_test_() ->
    [
        %% adjacency coalesces: this is what makes size/1 the run count
        ?_assertEqual([{1, 2}], ?M:from_list([1, 2])),
        ?_assertEqual([{2, 3}], ?M:add_element(2, ?M:add_element(3, ?M:new()))),
        ?_assertEqual([{2, 5}], ?M:add_element(4, [{2, 3}, 5])),
        ?_assertEqual(
            [{1, 2}, 4, {6, 10}], ?M:from_list([1, 2, 4, 6, 7, 8, 9, 10])
        ),
        ?_assertEqual(2, ?M:size([{2, 3}, 5])),
        ?_assertEqual(3, ?M:flat_size([{2, 3}, 5]))
    ].

empty_and_bounds_test_() ->
    [
        ?_assertEqual([], ?M:new()),
        ?_assert(?M:is_empty(?M:new())),
        ?_assertNot(?M:is_empty([1])),
        ?_assertEqual(0, ?M:size(?M:new())),
        ?_assertEqual(0, ?M:flat_size(?M:new())),
        ?_assertError(empty_interval_set, ?M:min(?M:new())),
        ?_assertError(empty_interval_set, ?M:max(?M:new())),
        ?_assertEqual(2, ?M:min([{2, 3}, 5])),
        ?_assertEqual(5, ?M:max([{2, 3}, 5])),
        ?_assertEqual(3, ?M:max([{2, 3}]))
    ].

validation_test_() ->
    [
        ?_assertError({badarg, {9, 3}}, ?M:from_list([{9, 3}])),
        ?_assertError({badarg, foo}, ?M:from_list([foo])),
        ?_assertError({badarg, foo}, ?M:add_element(foo, ?M:new())),
        ?_assertError({badarg, foo}, ?M:del_element(foo, [1])),
        ?_assertNot(?M:is_type([{9, 3}])),
        ?_assertNot(?M:is_type([foo])),
        ?_assertNot(?M:is_type(foo)),
        ?_assert(?M:is_type([{1, 3}, 7])),
        ?_assert(?M:is_type([]))
    ].

set_ops_test_() ->
    [
        ?_assertEqual([{2, 4}, 9], ?M:union([2, 3], [4, 9])),
        ?_assertEqual([{1, 10}], ?M:union([{1, 5}], [{6, 10}])),
        ?_assertEqual([3], ?M:intersection([{1, 3}], [{3, 9}])),
        ?_assertEqual([], ?M:intersection([1], [9])),
        ?_assertEqual([1, 3], ?M:subtract([{1, 3}], [2])),
        ?_assert(?M:is_subset([2], [{1, 3}])),
        ?_assertNot(?M:is_subset([{1, 4}], [{1, 3}])),
        ?_assert(?M:is_superset([{1, 3}], [2])),
        ?_assert(?M:is_disjoint([1], [9])),
        ?_assertNot(?M:is_disjoint([{1, 3}], [3])),
        ?_assertEqual([{1, 9}], ?M:union([[{1, 3}], [{4, 6}], [{7, 9}]])),
        ?_assertEqual(
            [{2, 3}], ?M:intersection([[{1, 3}], [{2, 6}], [{2, 9}]])
        ),
        ?_assertEqual([2], ?M:intersection([[{1, 2}], [{2, 6}], [{2, 9}]])),
        ?_assertError(badarg, ?M:intersection([])),
        ?_assertEqual([{1, 3}], ?M:intersection([[{1, 3}]]))
    ].

negatives_test_() ->
    [
        ?_assertEqual([{-3, -2}, 0], ?M:from_list([-3, -2, 0])),
        ?_assertEqual([{-3, 1}], ?M:from_list([-3, -2, -1, 0, 1])),
        ?_assertEqual(-3, ?M:min([{-3, -2}, 0]))
    ].

conversion_test_() ->
    [
        ?_assertEqual([{1, 3}], ?M:to_list([{1, 3}])),
        ?_assertEqual([1, 2, 3], ?M:to_flat_list([{1, 3}])),
        ?_assertEqual([], ?M:to_flat_list([])),
        ?_assertEqual([1, 2, 4], ?M:to_flat_list([{1, 2}, 4]))
    ].

iteration_test_() ->
    [
        ?_assertEqual(
            [5, {2, 3}], ?M:fold(fun(E, A) -> [E | A] end, [], [{2, 3}, 5])
        ),
        %% a subset of a coalesced list is coalesced, so filter needs no recompaction
        ?_assertEqual([5], ?M:filter(fun is_integer/1, [{2, 3}, 5])),
        ?_assertEqual([{2, 3}], ?M:filter(fun is_tuple/1, [{2, 3}, 5]))
    ].

-doc """
The operation the applied-frontier design needs: absorb every point at or below
a prefix bound. Seqs are >= 1, so `{0, P}` means "everything up to P".
""".
prefix_absorb_test_() ->
    [
        ?_assertEqual([5], ?M:subtract([{2, 3}, 5], [{0, 3}])),
        %% a run STRADDLING the bound is split, not dropped
        ?_assertEqual([{5, 9}], ?M:subtract([{2, 9}], [{0, 4}])),
        %% a no-op at prefix 0
        ?_assertEqual([{2, 3}, 5], ?M:subtract([{2, 3}, 5], [{0, 0}])),
        ?_assertEqual([], ?M:subtract([{2, 3}, 5], [{0, 5}]))
    ].
