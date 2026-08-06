%% =============================================================================
%% Tests for `bondy_mst:truncate/2` — the structural prefix-truncate used by
%% compaction to drop the stable prefix in O(log N) instead of O(P) per-key
%% deletes.
%%
%% The ship gate is *byte-identical-root equivalence*: because the MST is
%% history-independent, the tree of keys `> W` has a single canonical root,
%% so `truncate(T, W)` must produce the same root hash as
%%   (a) deleting every key `=< W` one at a time, and
%%   (b) building a fresh tree from `{K | K > W}`.
%% =============================================================================

-module(bondy_mst_truncate_test).

-include_lib("eunit/include/eunit.hrl").

%% -----------------------------------------------------------------------------
%% Helpers
%% -----------------------------------------------------------------------------

%% A fresh map-backed tree under a unique name (map store is deterministic and
%% needs no cleanup).
new_tree(Name) ->
    bondy_mst:new(#{
        store => bondy_mst_map_store,
        store_opts => #{name => list_to_binary(Name)},
        merger => fun(_K, _V1, V2) -> V2 end
    }).

build(Name, KVs) ->
    lists:foldl(
        fun({K, V}, T) -> bondy_mst:put(T, K, V) end,
        new_tree(Name),
        KVs
    ).

%% Sorted [{K, V}] of the live tree.
to_kv(T) ->
    lists:reverse(bondy_mst:fold(T, fun(KV, Acc) -> [KV | Acc] end, [])).

%% Reference truncation: delete every key `=< W`, one at a time.
truncate_by_delete(T, W) ->
    Keys = [K || {K, _V} <- to_kv(T), K =< W],
    %% Descending order — the order `truncate_below_or_equal/2` in the
    %% instance uses, and the order `delete/2` is documented to prefer.
    lists:foldl(
        fun(K, Acc) -> bondy_mst:delete(Acc, K) end,
        T,
        lists:reverse(lists:sort(Keys))
    ).

unique(Prefix, Parts) ->
    Prefix ++ "_" ++ string:join([integer_to_list(P) || P <- Parts], "_").

%% -----------------------------------------------------------------------------
%% Equivalence: truncate ≡ delete-each ≡ fresh-from-suffix (byte-identical root)
%% -----------------------------------------------------------------------------

truncate_matches_delete_and_fresh_test_() ->
    Sizes = [0, 1, 2, 3, 7, 16, 33, 100],
    {inparallel, [
        {
            lists:flatten(
                io_lib:format("size=~p w=~p", [N, W])
            ),
            fun() -> check_equivalence(N, W) end
        }
     || N <- Sizes,
        %% Watermarks below min, at every key, between keys, and above max.
        W <- watermarks(N)
    ]}.

watermarks(0) ->
    [0, 1];
watermarks(N) ->
    %% 0 (below all), each key, and N+1 (above all). Keys are 1..N so the
    %% half-integers are covered implicitly by `=<` semantics on integers;
    %% add an explicit "between" point at N div 2 already hit by a key.
    lists:usort([0, N + 1] ++ lists:seq(1, N)).

check_equivalence(N, W) ->
    %% Insert in a shuffled order to exercise the build path; the MST is
    %% history-independent so the canonical root is the same regardless.
    KVs = [{K, K * 10} || K <- shuffle(lists:seq(1, N))],

    T = build(unique("trunc", [N, W]), KVs),
    Truncated = bondy_mst:truncate(T, W),

    ByDelete = truncate_by_delete(
        build(unique("del", [N, W]), KVs), W
    ),

    SuffixKVs = [{K, K * 10} || K <- lists:seq(1, N), K > W],
    Fresh = build(unique("fresh", [N, W]), SuffixKVs),

    %% (1) Content is exactly the keys > W, values preserved.
    ?assertEqual(SuffixKVs, to_kv(Truncated)),
    %% (2) Byte-identical root vs delete-each.
    ?assertEqual(
        bondy_mst:root(ByDelete),
        bondy_mst:root(Truncated),
        "truncate root must equal delete-each root"
    ),
    %% (3) Byte-identical root vs fresh-from-suffix.
    ?assertEqual(
        bondy_mst:root(Fresh),
        bondy_mst:root(Truncated),
        "truncate root must equal fresh-from-suffix root"
    ).

%% Deterministic shuffle (no Date.now / random seeding needed — keyed on the
%% value so different sizes get different orders but runs are reproducible).
shuffle(L) ->
    [X || {_, X} <- lists:sort([{erlang:phash2({K, length(L)}), K} || K <- L])].

%% -----------------------------------------------------------------------------
%% Edge cases
%% -----------------------------------------------------------------------------

truncate_empty_tree_test() ->
    T = new_tree("trunc_empty"),
    T1 = bondy_mst:truncate(T, 5),
    ?assertEqual(undefined, bondy_mst:root(T1)),
    ?assertEqual([], to_kv(T1)).

truncate_below_min_is_noop_test() ->
    KVs = [{K, K} || K <- lists:seq(5, 15)],
    T = build("trunc_noop", KVs),
    T1 = bondy_mst:truncate(T, 4),
    ?assertEqual(bondy_mst:root(T), bondy_mst:root(T1)),
    ?assertEqual(to_kv(T), to_kv(T1)).

truncate_at_or_above_max_empties_test() ->
    KVs = [{K, K} || K <- lists:seq(1, 10)],
    T = build("trunc_all", KVs),
    %% W == max key drops everything (`=<`).
    T1 = bondy_mst:truncate(T, 10),
    ?assertEqual(undefined, bondy_mst:root(T1)),
    ?assertEqual([], to_kv(T1)),
    %% W above max likewise.
    T2 = bondy_mst:truncate(T, 99),
    ?assertEqual(undefined, bondy_mst:root(T2)),
    ?assertEqual([], to_kv(T2)).

truncate_between_existing_keys_test() ->
    %% Keys 10,20,30,...,100; truncate at a non-existent boundary 45.
    KVs = [{K, K} || K <- lists:seq(10, 100, 10)],
    T = build("trunc_between", KVs),
    T1 = bondy_mst:truncate(T, 45),
    ?assertEqual([{K, K} || K <- lists:seq(50, 100, 10)], to_kv(T1)),
    %% Equivalence to fresh.
    Fresh = build("trunc_between_fresh", [{K, K} || K <- lists:seq(50, 100, 10)]),
    ?assertEqual(bondy_mst:root(Fresh), bondy_mst:root(T1)).

%% first/1 and last/1 must answer correctly on the post-truncate page shape
%% (the bug `delete/2` had — guard against the same in truncate's output).
truncate_first_last_test() ->
    KVs = [{K, K} || K <- lists:seq(1, 50)],
    T = build("trunc_firstlast", KVs),
    T1 = bondy_mst:truncate(T, 30),
    ?assertEqual({31, 31}, bondy_mst:first(T1)),
    ?assertEqual({50, 50}, bondy_mst:last(T1)).

%% -----------------------------------------------------------------------------
%% ETS store: the actual compaction backend. A prior root must remain readable
%% after truncate (compaction reads peer/prior roots via diff_to_list), because
%% `free/3` only tombstones — pages are reclaimed by `gc/2`, which establishes
%% liveness first. This is the property that makes the structure persistent.
%% -----------------------------------------------------------------------------

truncate_keeps_prior_root_readable_test() ->
    Name = list_to_binary(
        "trunc_persist_" ++ integer_to_list(erlang:phash2(self()))
    ),
    T0 = bondy_mst:new(#{
        store => bondy_mst_ets_store,
        store_opts => #{name => Name},
        merger => fun(_K, _V1, V2) -> V2 end
    }),
    T = lists:foldl(
        fun(K, Acc) -> bondy_mst:put(Acc, K, K) end,
        T0,
        lists:seq(1, 40)
    ),
    PriorRoot = bondy_mst:root(T),

    T1 = bondy_mst:truncate(T, 25),
    ?assertEqual([{K, K} || K <- lists:seq(26, 40)], to_kv(T1)),

    %% The prior (full) root is still fully reachable — pages were soft-freed,
    %% not deleted. This is what lets compaction diff against a prior root.
    ?assertEqual(
        [{K, K} || K <- lists:seq(1, 40)],
        bondy_mst:to_list(T1, PriorRoot)
    ).
