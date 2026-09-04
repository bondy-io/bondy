%% Regression test for `bondy_mst:first/1` and `last/1` against the
%% post-delete page shape where an internal page has `low = undefined`
%% and entry refs that are NOT undefined. This shape is produced by
%% `delete/2` and was crashing `first/2` with `case_clause`.

-module(bondy_mst_first_last_post_delete_test).

-include_lib("eunit/include/eunit.hrl").

%% Insert a chain of keys, delete a contiguous prefix, then assert
%% first/1 and last/1 don't crash and return the remaining ends.
first_last_after_prefix_delete_test() ->
    Tree0 = bondy_mst:new(#{
        store => bondy_mst_map_store,
        store_opts => #{name => <<"first_last_post_delete_map">>}
    }),
    Keys = lists:seq(1, 20),
    Tree1 = lists:foldl(fun(K, T) -> bondy_mst:put(T, K) end, Tree0, Keys),
    Tree2 = lists:foldl(
        fun(K, T) -> bondy_mst:delete(T, K) end,
        Tree1,
        lists:seq(1, 10)
    ),
    ?assertEqual({11, true}, bondy_mst:first(Tree2)),
    ?assertEqual({20, true}, bondy_mst:last(Tree2)).

%% Symmetric case: delete the suffix.
first_last_after_suffix_delete_test() ->
    Tree0 = bondy_mst:new(#{
        store => bondy_mst_map_store,
        store_opts => #{name => <<"first_last_post_suffix_delete">>}
    }),
    Tree1 = lists:foldl(
        fun(K, T) -> bondy_mst:put(T, K) end,
        Tree0,
        lists:seq(1, 20)
    ),
    Tree2 = lists:foldl(
        fun(K, T) -> bondy_mst:delete(T, K) end,
        Tree1,
        lists:seq(11, 20)
    ),
    ?assertEqual({1, true}, bondy_mst:first(Tree2)),
    ?assertEqual({10, true}, bondy_mst:last(Tree2)).

%% After deleting a hole in the middle, first/last still answer the
%% true extremes.
first_last_after_middle_delete_test() ->
    Tree0 = bondy_mst:new(#{
        store => bondy_mst_map_store,
        store_opts => #{name => <<"first_last_middle_delete">>}
    }),
    Tree1 = lists:foldl(
        fun(K, T) -> bondy_mst:put(T, K) end,
        Tree0,
        lists:seq(1, 20)
    ),
    Tree2 = lists:foldl(
        fun(K, T) -> bondy_mst:delete(T, K) end,
        Tree1,
        lists:seq(8, 13)
    ),
    ?assertEqual({1, true}, bondy_mst:first(Tree2)),
    ?assertEqual({20, true}, bondy_mst:last(Tree2)).

%% Empty tree returns undefined.
first_last_empty_test() ->
    Tree = bondy_mst:new(#{
        store => bondy_mst_map_store,
        store_opts => #{name => <<"first_last_empty">>}
    }),
    ?assertEqual(undefined, bondy_mst:first(Tree)),
    ?assertEqual(undefined, bondy_mst:last(Tree)).

%% After deleting EVERYTHING, the tree is empty.
first_last_after_full_delete_test() ->
    Tree0 = bondy_mst:new(#{
        store => bondy_mst_map_store,
        store_opts => #{name => <<"first_last_full_delete">>}
    }),
    Tree1 = lists:foldl(
        fun(K, T) -> bondy_mst:put(T, K) end,
        Tree0,
        lists:seq(1, 10)
    ),
    Tree2 = lists:foldl(
        fun(K, T) -> bondy_mst:delete(T, K) end,
        Tree1,
        lists:seq(1, 10)
    ),
    ?assertEqual(undefined, bondy_mst:first(Tree2)),
    ?assertEqual(undefined, bondy_mst:last(Tree2)).
