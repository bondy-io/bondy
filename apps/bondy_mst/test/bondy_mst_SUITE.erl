-module(bondy_mst_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(ISET(L), interval_sets:from_list(L)).

-compile(export_all).

%% All test cases to be run

all() ->
    [
        {group, local_store, []},
        {group, ets_store, []}
    ].

groups() ->
    [
        {local_store, [], [
            commutative_test,
            small_test,
            first_last_test,
            large_test,
            delete_simple_test,
            delete_multiple_test,
            delete_not_found_test,
            delete_all_test,
            delete_and_read_test
        ]},
        {ets_store, [], [
            commutative_test,
            small_test,
            first_last_test,
            persistent_test,
            large_test,
            delete_simple_test,
            delete_multiple_test,
            delete_not_found_test,
            delete_all_test,
            delete_and_read_test
        ]},
        {leveled_store, [], [
            commutative_test,
            small_test,
            first_last_test,
            large_test,
            delete_simple_test,
            delete_multiple_test,
            delete_not_found_test,
            delete_all_test,
            delete_and_read_test
        ]}
    ].

init_per_group(local_store, Config) ->
    [{store, bondy_mst_map_store}] ++ Config;
init_per_group(ets_store, Config) ->
    [{store, bondy_mst_ets_store}] ++ Config;
init_per_group(leveled_store, Config) ->
    {ok, _} = application:ensure_all_started(bondy_mst),
    [{store, bondy_mst_leveled_store}] ++ Config;
init_per_group(rocksdb_store, Config) ->
    {ok, _} = application:ensure_all_started(bondy_mst),
    [{store, bondy_mst_rocksdb_store}] ++ Config.

end_per_group(_, _Config) ->
    ok.

%% Setup and teardown functions

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

commutative_test(Config) ->
    Mod = ?config(store, Config),

    A = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        bondy_mst:new(#{
            store => Mod,
            store_opts => #{name => <<"bondy_mst_comm_a">>}
        }),
        lists:seq(1, 10)
    ),

    B = bondy_mst:new(#{
        store => Mod,
        store_opts => #{name => <<"bondy_mst_comm_b">>}
    }),

    M1 = bondy_mst:to_list(bondy_mst:merge(A, B)),
    M2 = bondy_mst:to_list(bondy_mst:merge(B, A)),
    ?assert(M1 == M2).

small_test(Config) ->
    Mod = ?config(store, Config),

    A = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        bondy_mst:new(#{
            store => Mod,
            store_opts => #{name => <<"bondy_mst_small_a">>}
        }),
        lists:seq(1, 10)
    ),
    ?assertEqual([{1, 10}], ?ISET([K || {K, true} <- bondy_mst:to_list(A)])),

    B = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        bondy_mst:new(#{
            store => Mod,
            store_opts => #{name => <<"bondy_mst_small_b">>}
        }),
        lists:seq(5, 15)
    ),
    ?assertEqual([{5, 15}], ?ISET([K || {K, true} <- bondy_mst:to_list(B)])),

    Z = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        bondy_mst:new(#{
            store => Mod,
            store_opts => #{name => <<"bondy_mst_small_z">>}
        }),
        lists:seq(1, 15)
    ),
    ?assertEqual([{1, 15}], ?ISET([K || {K, true} <- bondy_mst:to_list(Z)])),

    C = bondy_mst:merge(A, B),
    D = bondy_mst:merge(B, A),

    ?assertNotEqual(undefined, bondy_mst:root(C)),
    ?assertNotEqual(undefined, bondy_mst:root(D)),

    ?assertEqual(bondy_mst:root(C), bondy_mst:root(D)),
    ?assertEqual(bondy_mst:root(C), bondy_mst:root(Z)),
    ?assertEqual(bondy_mst:to_list(C), bondy_mst:to_list(Z)),

    case C =/= A of
        true ->
            %% Only true for map store
            DA = [K || {K, true} <- bondy_mst:diff_to_list(C, A)],
            ?assertEqual(
                ?ISET(lists:sort(lists:seq(11, 15))),
                ?ISET(lists:sort(DA))
            ),
            ?assertEqual(
                [],
                bondy_mst:diff_to_list(A, C)
            ),

            DB = [K || {K, true} <- bondy_mst:diff_to_list(C, B)],
            ?assertEqual(
                ?ISET(lists:sort(lists:seq(1, 4))),
                ?ISET(lists:sort(DB))
            ),

            ?assertEqual(
                [],
                bondy_mst:diff_to_list(B, C)
            ),

            DBA = [K || {K, _} <- bondy_mst:diff_to_list(B, A)],
            ?assertEqual(
                ?ISET(lists:seq(11, 15)),
                ?ISET(lists:sort(DBA))
            ),

            DAB = [K || {K, _} <- bondy_mst:diff_to_list(A, B)],
            ?assertEqual(
                ?ISET(lists:seq(1, 4)),
                ?ISET(lists:sort(DAB))
            );
        false ->
            ?assertEqual(A, C),
            ?assertEqual(D, B)
    end,

    ok = bondy_mst:destroy(A),
    ok = bondy_mst:destroy(B),
    ok = bondy_mst:destroy(Z).

large_test(Config) ->
    Mod = ?config(store, Config),

    ShuffledA = list_shuffle(lists:seq(1, 1000)),
    ShuffledB = list_shuffle(lists:seq(550, 1500)),
    A = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        bondy_mst:new(#{
            store => Mod,
            store_opts => #{name => <<"bondy_mst_large_a">>}
        }),
        ShuffledA
    ),
    B = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        bondy_mst:new(#{
            store => Mod,
            store_opts => #{name => <<"bondy_mst_large_b">>}
        }),
        ShuffledB
    ),
    Z = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        bondy_mst:new(#{
            store => Mod,
            store_opts => #{name => <<"bondy_mst_large_z">>}
        }),
        lists:seq(1, 1500)
    ),
    C = bondy_mst:merge(A, B),
    D = bondy_mst:merge(B, A),

    case C =/= A of
        true ->
            ?assertEqual(bondy_mst:root(C), bondy_mst:root(D)),
            ?assertEqual(bondy_mst:root(C), bondy_mst:root(Z)),

            FullList = [K || {K, _} <- bondy_mst:to_list(C)],
            ?assertEqual(
                ?ISET(lists:seq(1, 1500)), ?ISET(lists:sort(FullList))
            ),

            DCA = [K || {K, _} <- bondy_mst:diff_to_list(C, A)],
            ?assertEqual(?ISET(lists:seq(1001, 1500)), ?ISET(DCA)),
            DCB = [K || {K, _} <- bondy_mst:diff_to_list(C, B)],
            ?assertEqual(?ISET(lists:seq(1, 549)), ?ISET(DCB)),

            ?assertEqual([], bondy_mst:diff_to_list(A, C)),
            ?assertEqual([], bondy_mst:diff_to_list(B, C)),

            DBA = [K || {K, _} <- bondy_mst:diff_to_list(B, A)],
            ?assertEqual(?ISET(lists:seq(1001, 1500)), ?ISET(DBA)),
            DAB = [K || {K, _} <- bondy_mst:diff_to_list(A, B)],
            ?assertEqual(?ISET(lists:seq(1, 549)), ?ISET(DAB));
        false ->
            ?assertEqual(A, C),
            ?assertEqual(D, B)
    end,

    ok = bondy_mst:destroy(A),
    ok = bondy_mst:destroy(B),
    ok = bondy_mst:destroy(Z).

first_last_test(Config) ->
    Mod = ?config(store, Config),

    A = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        bondy_mst:new(#{
            store => Mod,
            store_opts => #{name => <<"first_last_test">>}
        }),
        lists:seq(1, 10)
    ),
    ?assertEqual({1, true}, bondy_mst:first(A)),
    ?assertEqual({10, true}, bondy_mst:last(A)).

%% Persistence (multi-version reads) with keep-root reclamation: every
%% published root stays readable until a collection runs WITHOUT it in
%% the keep-root set — retaining a version IS pinning its root
%% (`bondy_mst_crdt`'s history does exactly this).
persistent_test(Config) ->
    Mod = ?config(store, Config),

    T0 = bondy_mst:new(#{
        store => Mod,
        store_opts => #{name => <<"persistent_test">>}
    }),

    T1 = bondy_mst:put(T0, 1),
    R1 = bondy_mst:root(T1),

    T2 = bondy_mst:put(T1, 2),
    R2 = bondy_mst:root(T2),

    T3 = bondy_mst:put(T2, 3),
    R3 = bondy_mst:root(T3),

    ?assertEqual([{1, true}], bondy_mst:to_list(T1, R1)),
    ?assertEqual([{1, true}, {2, true}], bondy_mst:to_list(T2, R2)),
    ?assertEqual([{1, true}, {2, true}, {3, true}], bondy_mst:to_list(T3, R3)),
    ?assertEqual(bondy_mst:to_list(T3, R3), bondy_mst:to_list(T3)),

    %% GC keeping R2 (the current root is always kept): R1's exclusive
    %% pages are reclaimed, R2 stays whole.
    T4 = bondy_mst:gc(T3, [R2]),
    ?assertEqual([], bondy_mst:to_list(T4, R1)),
    ?assertEqual([{1, true}, {2, true}], bondy_mst:to_list(T4, R2)),

    %% Dropping the R2 pin reclaims its exclusive pages too.
    T5 = bondy_mst:gc(T4, []),
    ?assertEqual([], bondy_mst:to_list(T5, R2)),

    ?assertEqual([{1, true}, {2, true}, {3, true}], bondy_mst:to_list(T5, R3)),
    ?assertEqual(bondy_mst:to_list(T5, R3), bondy_mst:to_list(T5)).

delete_simple_test(Config) ->
    Mod = ?config(store, Config),

    T0 = bondy_mst:new(#{
        store => Mod,
        store_opts => #{name => <<"delete_simple_test">>}
    }),

    T1 = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        T0,
        [1, 2, 3, 4, 5]
    ),

    ?assertEqual(
        [{1, true}, {2, true}, {3, true}, {4, true}, {5, true}],
        bondy_mst:to_list(T1)
    ),

    T2 = bondy_mst:delete(T1, 3),
    List2 = bondy_mst:to_list(T2),
    ?assertEqual([{1, true}, {2, true}, {4, true}, {5, true}], List2),

    ?assertEqual(true, bondy_mst:get(T2, 1)),
    ?assertEqual(true, bondy_mst:get(T2, 5)),
    ?assertEqual(undefined, bondy_mst:get(T2, 3)),

    T3 = bondy_mst:delete(T2, 1),
    ?assertEqual([{2, true}, {4, true}, {5, true}], bondy_mst:to_list(T3)),

    T4 = bondy_mst:delete(T3, 5),
    ?assertEqual([{2, true}, {4, true}], bondy_mst:to_list(T4)).

delete_multiple_test(Config) ->
    Mod = ?config(store, Config),

    T0 = bondy_mst:new(#{
        store => Mod,
        store_opts => #{name => <<"delete_multiple_test">>}
    }),

    T1 = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        T0,
        lists:seq(1, 20)
    ),

    ToDelete = [2, 5, 8, 11, 14, 17, 20],
    T2 = lists:foldl(
        fun(N, Acc) -> bondy_mst:delete(Acc, N) end,
        T1,
        ToDelete
    ),

    lists:foreach(
        fun(N) -> ?assertEqual(undefined, bondy_mst:get(T2, N)) end,
        ToDelete
    ),

    Remaining = lists:seq(1, 20) -- ToDelete,
    lists:foreach(
        fun(N) -> ?assertEqual(true, bondy_mst:get(T2, N)) end,
        Remaining
    ),

    Expected = [{N, true} || N <- Remaining],
    ?assertEqual(Expected, bondy_mst:to_list(T2)).

delete_not_found_test(Config) ->
    Mod = ?config(store, Config),

    T0 = bondy_mst:new(#{
        store => Mod,
        store_opts => #{name => <<"delete_not_found_test">>}
    }),

    T1 = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        T0,
        [1, 2, 3, 4, 5]
    ),

    T2 = bondy_mst:delete(T1, 10),

    ?assertEqual(bondy_mst:to_list(T1), bondy_mst:to_list(T2)),

    T3 = bondy_mst:new(#{
        store => Mod,
        store_opts => #{name => <<"delete_not_found_test_empty">>}
    }),
    T4 = bondy_mst:delete(T3, 1),
    ?assertEqual([], bondy_mst:to_list(T4)),
    ?assertEqual(undefined, bondy_mst:root(T4)).

delete_all_test(Config) ->
    Mod = ?config(store, Config),

    T0 = bondy_mst:new(#{
        store => Mod,
        store_opts => #{name => <<"delete_all_test">>}
    }),

    Elements = lists:seq(1, 10),
    T1 = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        T0,
        Elements
    ),

    T2 = lists:foldl(
        fun(N, Acc) -> bondy_mst:delete(Acc, N) end,
        T1,
        Elements
    ),

    ?assertEqual([], bondy_mst:to_list(T2)),
    ?assertEqual(undefined, bondy_mst:root(T2)),

    T3 = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        T0,
        Elements
    ),

    T4 = lists:foldl(
        fun(N, Acc) -> bondy_mst:delete(Acc, N) end,
        T3,
        lists:reverse(Elements)
    ),

    ?assertEqual([], bondy_mst:to_list(T4)),
    ?assertEqual(undefined, bondy_mst:root(T4)).

delete_and_read_test(Config) ->
    Mod = ?config(store, Config),

    T0 = bondy_mst:new(#{
        store => Mod,
        store_opts => #{name => <<"delete_and_read_test">>}
    }),

    T1 = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, N) end,
        T0,
        [1, 2, 3, 4, 5]
    ),

    T2 = bondy_mst:delete(T1, 3),
    ?assertEqual(undefined, bondy_mst:get(T2, 3)),

    T3 = bondy_mst:put(T2, 3),
    ?assertEqual(true, bondy_mst:get(T3, 3)),
    ?assertEqual(
        [{1, true}, {2, true}, {3, true}, {4, true}, {5, true}],
        bondy_mst:to_list(T3)
    ),

    T4 = bondy_mst:delete(T3, 2),
    T5 = bondy_mst:delete(T4, 4),
    ?assertEqual([{1, true}, {3, true}, {5, true}], bondy_mst:to_list(T5)),

    T6 = bondy_mst:put(T5, 4),
    T7 = bondy_mst:put(T6, 2),
    ?assertEqual(
        [{1, true}, {2, true}, {3, true}, {4, true}, {5, true}],
        bondy_mst:to_list(T7)
    ).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
randomize(1, List) ->
    randomize(List);
randomize(T, List) ->
    lists:foldl(
        fun(_E, Acc) -> randomize(Acc) end,
        randomize(List),
        lists:seq(1, (T - 1))
    ).

%% @private
randomize(List) ->
    D = lists:map(fun(A) -> {rand:uniform(), A} end, List),
    {_, D1} = lists:unzip(lists:keysort(1, D)),
    D1.

%% -----------------------------------------------------------------------------
%% @doc
%% From https://erlangcentral.org/wiki/index.php/RandomShuffle
%% @end
%% -----------------------------------------------------------------------------
list_shuffle([]) ->
    [];
list_shuffle(List) ->
    %% Determine the log n portion then randomize the list.
    randomize(round(math:log(length(List)) + 0.5), List).
