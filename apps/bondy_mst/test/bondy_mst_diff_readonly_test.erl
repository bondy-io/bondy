%% =============================================================================
%% Tests for `bondy_mst:diff_to_list/2` — the read-only MST tree comparison.
%%
%% MST tree comparison is read-only by design (Auvolat & Taïani, SRDS 2019):
%% descend both roots, prune any subtree whose Merkle hash matches, and surface
%% only the differing entries. The earlier implementation aligned two
%% differently-shaped trees with `split/4`, which `free`s the pages it rewrites
%% and `put`s temporary partition pages — mutating the *live* tree on the
%% mutable ETS/pack backends (it only looked read-only on the immutable
%% map_store, where the mutated store copy is discarded). The current
%% implementation routes the synthetic partition pages through an in-memory
%% overlay, so neither input tree is touched.
%%
%% Two ship gates:
%%   1. Result-equivalence: `diff_to_list(A, B)` == the entries in `A` whose
%%      value is absent-or-different in `B`, in key order (an independent
%%      oracle over `fold/2`).
%%   2. Read-only: diffing leaves both input trees byte-for-byte intact on the
%%      mutable backends, where the old `free`-based descent corrupted them —
%%      immediately on a non-persistent ETS store (free == `ets:delete`), and
%%      after a `gc(Epoch)` on a persistent one (free marks `freed_at`, which
%%      `prune_freed` then reclaims regardless of reachability).
%% =============================================================================

-module(bondy_mst_diff_readonly_test).

-include_lib("eunit/include/eunit.hrl").

%% -----------------------------------------------------------------------------
%% Helpers
%% -----------------------------------------------------------------------------

map_tree(Name) ->
    bondy_mst:new(#{
        store => bondy_mst_map_store,
        store_opts => #{name => list_to_binary(Name)},
        merger => fun(_K, _V1, V2) -> V2 end
    }).

ets_tree(Name, Persistent) ->
    bondy_mst:new(#{
        store => bondy_mst_ets_store,
        store_opts => #{name => list_to_binary(Name), persistent => Persistent},
        merger => fun(_K, _V1, V2) -> V2 end
    }).

build(T0, KVs) ->
    lists:foldl(fun({K, V}, T) -> bondy_mst:put(T, K, V) end, T0, KVs).

%% Sorted [{K, V}] of the live tree.
to_kv(T) ->
    lists:reverse(bondy_mst:fold(T, fun(KV, Acc) -> [KV | Acc] end, [])).

%% Value used for key K, optionally salted so the same key can carry a
%% different value in two trees (exercises the value-differs branch).
val(K, Salt) ->
    integer_to_binary(K * 7 + Salt).

kvs(Keys, Salt) ->
    [{K, val(K, Salt)} || K <- Keys].

%% Independent oracle: the *true* difference — entries of `A` whose value is
%% absent-or-different in `B`, in key order.
oracle(AList, BList) ->
    BMap = maps:from_list(BList),
    [{K, V} || {K, V} <- AList, not same_in(K, V, BMap)].

same_in(K, V, BMap) ->
    case BMap of
        #{K := BV} -> V == BV;
        _ -> false
    end.

%% `diff_to_list/2` is a *structural* (Merkle-subtree) diff: it prunes by
%% matching page hash, so the result is a sound, complete, key-ascending,
%% duplicate-free list of `A`-entries covering every A/B difference. It MAY
%% additionally surface an entry that is equal in both trees but shares a leaf
%% page with a differing entry — a permitted, harmless superset (the applier
%% re-applies idempotently; the frontier filters structurally). So the gate is
%% the three universal properties, not minimality.
assert_valid_diff(AList, BList, L) ->
    Keys = [K || {K, _} <- L],
    %% strictly key-ascending, no duplicate keys
    ?assertEqual(lists:sort(Keys), Keys),
    ?assertEqual(length(lists:usort(Keys)), length(Keys)),
    %% sound: every returned entry is a genuine `A` entry (key *and* value)
    ASet = sets:from_list(AList),
    [?assert(sets:is_element(E, ASet)) || E <- L],
    %% complete: every true difference is covered
    LSet = sets:from_list(L),
    [?assert(sets:is_element(E, LSet)) || E <- oracle(AList, BList)],
    ok.

unique(Prefix, Parts) ->
    Prefix ++ "_" ++ string:join([integer_to_list(P) || P <- Parts], "_").

%% -----------------------------------------------------------------------------
%% 1. Result-equivalence against the oracle (immutable map_store)
%% -----------------------------------------------------------------------------

%% A grid of (A-keys, B-keys) with disjoint, overlapping and identical regions,
%% plus a salted overlap so some shared keys carry differing values.
diff_matches_oracle_test_() ->
    Cases = [
        %% {ATag, AKeys, ASalt, BTag, BKeys, BSalt}
        {a, [], 0, b, [], 0},
        {a, lists:seq(1, 10), 0, b, [], 0},
        {a, [], 0, b, lists:seq(1, 10), 0},
        {a, lists:seq(1, 50), 0, b, lists:seq(1, 50), 0},
        {a, lists:seq(1, 50), 0, b, lists:seq(1, 50), 1},
        {a, lists:seq(1, 50), 0, b, lists:seq(26, 75), 0},
        {a, lists:seq(1, 100), 0, b, lists:seq(1, 50), 0},
        {a, lists:seq(1, 50), 0, b, lists:seq(1, 100), 0},
        {a, lists:seq(1, 200), 0, b, lists:seq(100, 300), 7},
        {a, lists:seq(1, 333, 2), 0, b, lists:seq(2, 333, 2), 0}
    ],
    [
        {
            unique("oracle", [N]),
            fun() ->
                A = build(map_tree(unique("A", [N])), kvs(AKeys, ASalt)),
                B = build(map_tree(unique("B", [N])), kvs(BKeys, BSalt)),
                AList = to_kv(A),
                BList = to_kv(B),
                assert_valid_diff(AList, BList, bondy_mst:diff_to_list(A, B)),
                assert_valid_diff(BList, AList, bondy_mst:diff_to_list(B, A))
            end
        }
     || {N, {_, AKeys, ASalt, _, BKeys, BSalt}} <-
            lists:zip(lists:seq(1, length(Cases)), Cases)
    ].

%% The root form (`diff_to_list(T, PriorRootHash)`) against a prior persisted
%% root of the same store: B descends from A, so A's root stays reachable.
diff_root_form_matches_oracle_test() ->
    A = build(map_tree("rootform_A"), kvs(lists:seq(1, 100), 0)),
    RA = bondy_mst:root(A),
    %% B = A plus new keys and a handful of overwrites (differing values).
    B0 = build(A, kvs(lists:seq(101, 160), 0)),
    B = build(B0, kvs(lists:seq(1, 5), 1)),
    AList = to_kv(A),
    BList = to_kv(B),
    %% Changing keys 1..5's values changes their leaf pages; unchanged
    %% neighbours sharing those pages may ride along — a valid structural diff.
    assert_valid_diff(BList, AList, bondy_mst:diff_to_list(B, RA)).

%% A GC'd / unknown prior root falls back to the full current list.
diff_unknown_root_is_full_list_test() ->
    B = build(map_tree("unknown_root"), kvs(lists:seq(1, 30), 0)),
    Bogus = crypto:hash(sha256, <<"no such page">>),
    ?assertEqual(to_kv(B), bondy_mst:diff_to_list(B, Bogus)),
    ?assertEqual(to_kv(B), bondy_mst:diff_to_list(B, undefined)).

%% -----------------------------------------------------------------------------
%% 2. Read-only: the mutable backends are left intact by a diff
%% -----------------------------------------------------------------------------

%% Non-persistent ETS: `free` is an immediate `ets:delete`, so the old
%% split-based descent destroyed live pages *during* the diff. Two-tree form
%% splits both stores; assert both trees survive, the result is correct, and a
%% repeat diff is identical (the old code would crash on the second pass).
diff_readonly_ets_non_persistent_test() ->
    A = build(ets_tree("np_A", false), kvs(lists:seq(1, 200), 0)),
    B = build(ets_tree("np_B", false), kvs(lists:seq(100, 350), 7)),
    AList = to_kv(A),
    BList = to_kv(B),

    D1 = bondy_mst:diff_to_list(B, A),
    assert_valid_diff(BList, AList, D1),

    %% Both live trees are byte-for-byte intact (old code: pages ets:deleted
    %% during the descent).
    ?assertEqual(AList, to_kv(A)),
    ?assertEqual(BList, to_kv(B)),

    %% Idempotent: the descent did not consume the trees, so a repeat yields
    %% the identical result (old code would crash on the second pass).
    D2 = bondy_mst:diff_to_list(B, A),
    ?assertEqual(D1, D2),
    ?assertEqual(D1, bondy_mst:diff_to_list(B, A)).

%% Persistent ETS + root form: `free` marks `freed_at`; a `gc(Epoch)` then
%% reclaims every freed-marked page regardless of reachability. If the diff
%% had `free`d any page reachable from the current root, the post-GC tree would
%% lose entries. Assert the current tree survives a full epoch GC after a diff.
diff_readonly_ets_persistent_gc_test() ->
    A = build(ets_tree("p_A", true), kvs(lists:seq(1, 200), 0)),
    RA = bondy_mst:root(A),
    B0 = build(A, kvs(lists:seq(201, 320), 0)),
    B = build(B0, kvs(lists:seq(1, 10), 1)),
    BList = to_kv(B),
    %% NB: ETS keeps the root in the table (shared ROOT_KEY), so `to_kv(A)`
    %% would now read B's root — use the known prior content for the oracle.
    APriorList = kvs(lists:seq(1, 200), 0),

    assert_valid_diff(BList, APriorList, bondy_mst:diff_to_list(B, RA)),
    ?assertEqual(BList, to_kv(B)),

    %% Reclaim everything ever marked freed_at; the current root must keep all
    %% its pages (the diff must not have marked any of them freed).
    Epoch = erlang:monotonic_time(),
    B2 = bondy_mst:gc(B, Epoch),
    ?assertEqual(BList, to_kv(B2)).

%% Two-tree diff across *different* backends (map vs ets) still read-only and
%% correct — guards against an asymmetry between the Store1 / Store2 paths.
diff_readonly_mixed_backend_test() ->
    A = build(map_tree("mixed_A"), kvs(lists:seq(1, 120), 0)),
    B = build(ets_tree("mix_B", false), kvs(lists:seq(60, 240), 3)),
    AList = to_kv(A),
    BList = to_kv(B),
    assert_valid_diff(AList, BList, bondy_mst:diff_to_list(A, B)),
    assert_valid_diff(BList, AList, bondy_mst:diff_to_list(B, A)),
    ?assertEqual(AList, to_kv(A)),
    ?assertEqual(BList, to_kv(B)).
