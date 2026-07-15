%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Equivalence gate for the bulk bottom-up construction used by
%% `bondy_mst:put_batch/2`: the MST is history-independent, so the
%% bulk-built batch tree merged into a receiver MUST yield a root hash
%% byte-identical to folding sequential `put/3` calls over the same
%% items — for any key shape, duplicate-key batches (merger order
%% semantics), and non-empty receivers.
-module(bondy_mst_put_batch_bulk_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% EUNIT
%% =============================================================================

put_batch_bulk_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_mst),
            ok
        end,
        fun(_) -> ok end, [
            {timeout, 30, fun empty_batch/0},
            {timeout, 30, fun singleton_batch/0},
            {timeout, 30, fun integer_keys_match_sequential/0},
            {timeout, 30, fun binary_keys_match_sequential/0},
            {timeout, 30, fun unsorted_input_matches_sequential/0},
            {timeout, 30, fun duplicate_keys_merge_in_batch_order/0},
            {timeout, 30, fun non_empty_receiver_matches_sequential/0},
            {timeout, 30, fun oplog_shaped_keys_match_sequential/0},
            {timeout, 60, fun proper_equivalence/0}
        ]}.

empty_batch() ->
    T = new_tree(),
    ?assertEqual(undefined, bondy_mst:root(bondy_mst:put_batch(T, []))).

singleton_batch() ->
    Items = [{1, <<"v">>}],
    assert_equivalent(new_tree(), Items).

integer_keys_match_sequential() ->
    Items = [{N, integer_to_binary(N)} || N <- lists:seq(1, 500)],
    assert_equivalent(new_tree(), Items).

binary_keys_match_sequential() ->
    Items = [
        {crypto:hash(sha256, integer_to_binary(N)), N}
     || N <- lists:seq(1, 300)
    ],
    assert_equivalent(new_tree(), Items).

unsorted_input_matches_sequential() ->
    %% Reverse and interleave so the bulk path's sort is exercised.
    Items0 = [{N, integer_to_binary(N)} || N <- lists:seq(1, 200)],
    Items = lists:reverse(Items0) ++ [],
    assert_equivalent(new_tree(), Items).

duplicate_keys_merge_in_batch_order() ->
    %% A non-commutative merger exposes argument order: sequential puts
    %% call merger(K, EarlierValue, LaterValue); the bulk pre-merge must
    %% do exactly the same.
    Merger = fun(_K, A, B) -> <<A/binary, "|", B/binary>> end,
    T = new_tree(#{merger => Merger}),
    Items = [
        {1, <<"a">>},
        {2, <<"x">>},
        {1, <<"b">>},
        {3, <<"q">>},
        {1, <<"c">>},
        {2, <<"y">>}
    ],
    Bulk = bondy_mst:put_batch(T, Items),
    Seq = lists:foldl(
        fun({K, V}, Acc) -> bondy_mst:put(Acc, K, V) end,
        new_tree(#{merger => Merger}),
        Items
    ),
    ?assertEqual(bondy_mst:root(Seq), bondy_mst:root(Bulk)),
    ?assertEqual(<<"a|b|c">>, bondy_mst:get(Bulk, 1)),
    ?assertEqual(<<"x|y">>, bondy_mst:get(Bulk, 2)).

non_empty_receiver_matches_sequential() ->
    Pre = [{N, integer_to_binary(N)} || N <- lists:seq(1, 300, 3)],
    Items = [{N, integer_to_binary(N)} || N <- lists:seq(2, 300, 3)],
    T0 = lists:foldl(
        fun({K, V}, Acc) -> bondy_mst:put(Acc, K, V) end, new_tree(), Pre
    ),
    assert_equivalent(T0, Items).

oplog_shaped_keys_match_sequential() ->
    %% The hot caller's key/value shape: increasing-HLC event keys
    %% appended past the receiver's max key (the fast-install suffix).
    Origin = binary:copy(<<16#ab>>, 16),
    Key = fun(N) -> {key, 1749600000000000000 + N * 1000, Origin, N} end,
    Val = fun(N) -> {{set, N, <<"v">>}, undefined, undefined, undefined} end,
    Pre = [{Key(N), Val(N)} || N <- lists:seq(1, 512)],
    Items = [{Key(N), Val(N)} || N <- lists:seq(513, 768)],
    T0 = bondy_mst:put_batch(new_tree(), Pre),
    assert_equivalent(T0, Items).

%% =============================================================================
%% PROPER
%% =============================================================================

proper_equivalence() ->
    ?assert(
        proper:quickcheck(
            prop_bulk_equals_sequential(),
            [{numtests, 100}, {to_file, user}]
        )
    ).

prop_bulk_equals_sequential() ->
    ?FORALL(
        {Items, PreItems},
        {items_gen(), items_gen()},
        begin
            T0 = lists:foldl(
                fun({K, V}, Acc) -> bondy_mst:put(Acc, K, V) end,
                new_tree(#{merger => fun merger_last/3}),
                PreItems
            ),
            Bulk = bondy_mst:put_batch(T0, Items),
            Seq = lists:foldl(
                fun({K, V}, Acc) -> bondy_mst:put(Acc, K, V) end,
                T0,
                Items
            ),
            bondy_mst:root(Seq) =:= bondy_mst:root(Bulk)
        end
    ).

items_gen() ->
    list({oneof([integer(), binary(8)]), binary(4)}).

merger_last(_K, _A, B) -> B.

%% =============================================================================
%% PRIVATE
%% =============================================================================

new_tree() ->
    new_tree(#{}).

new_tree(Extra) ->
    bondy_mst:new(
        maps:merge(
            #{
                store => bondy_mst_map_store,
                store_opts => #{},
                merger => fun(_K, _A, B) -> B end
            },
            Extra
        )
    ).

assert_equivalent(T0, Items) ->
    Bulk = bondy_mst:put_batch(T0, Items),
    Seq = lists:foldl(
        fun({K, V}, Acc) -> bondy_mst:put(Acc, K, V) end, T0, Items
    ),
    ?assertEqual(bondy_mst:root(Seq), bondy_mst:root(Bulk)),
    %% Same content, not just same root.
    ?assertEqual(bondy_mst:to_list(Seq), bondy_mst:to_list(Bulk)).
