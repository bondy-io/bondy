%% =============================================================================
%% Equivalence tests for `bondy_oplog_instance:compute_frontier_for/2` — the
%% O(diff), read-only stability frontier.
%%
%% The frontier is the largest local key K such that every local key `=< K` is
%% confirmed by EVERY peer root. The new implementation walks the read-only
%% structural diff to the first genuine divergence (filtering structural
%% false-positives with `bondy_mst:get/3`); the reference is the previous O(N)
%% set longest-common-prefix, inlined here as `oracle_frontier/2`. The two must
%% agree on every local/peer configuration.
%%
%% Construction: all peer roots must be reachable in the local MST's store (as
%% they are in production after anti-entropy sync). We build one lineage on a
%% single ETS store — where `free` tombstones (`freed_at`) but keeps the
%% page — so every intermediate root stays readable. Peer roots are built
%% first (capturing each root hash as the table advances), then the local tree
%% is built last from the final peer, so the live handle's root is the local
%% root while its store still holds every peer root.
%% =============================================================================

-module(bondy_oplog_compaction_frontier_test).

-include_lib("eunit/include/eunit.hrl").

%% -----------------------------------------------------------------------------
%% Lineage construction (single ETS store, all roots reachable)
%% -----------------------------------------------------------------------------

ets_tree(Name) ->
    bondy_mst:new(#{
        store => bondy_mst_ets_store,
        store_opts => #{name => list_to_binary(Name)},
        merger => fun(_K, _V1, V2) -> V2 end
    }).

%% Reshape the tree from keyset `From` to keyset `To` via deletes + puts
%% (value `true`); MST history-independence makes the resulting root the
%% canonical root for `To` regardless of path.
reshape(T, From, To) ->
    ToSet = sets:from_list(To),
    FromSet = sets:from_list(From),
    T1 = lists:foldl(
        fun(K, A) -> bondy_mst:delete(A, K) end,
        T,
        [K || K <- From, not sets:is_element(K, ToSet)]
    ),
    lists:foldl(
        fun(K, A) -> bondy_mst:put(A, K) end,
        T1,
        [K || K <- To, not sets:is_element(K, FromSet)]
    ).

%% Build one lineage; return {[RootHashPerKeyset], FinalHandle}.
build_lineage(Name, Keysets) ->
    {RootsRev, _Prev, FinalT} =
        lists:foldl(
            fun(Ks, {Acc, Prev, T}) ->
                T1 = reshape(T, Prev, Ks),
                {[bondy_mst:root(T1) | Acc], Ks, T1}
            end,
            {[], [], ets_tree(Name)},
            Keysets
        ),
    {lists:reverse(RootsRev), FinalT}.

%% PeerKeysets are built first, the local keyset last; the local handle holds
%% every peer root in its store.
setup(Name, PeerKeysets, LocalKeys) ->
    {Roots, Local} = build_lineage(Name, PeerKeysets ++ [LocalKeys]),
    {Local, lists:droplast(Roots)}.

%% -----------------------------------------------------------------------------
%% Reference frontier: the previous O(N) set longest-common-prefix
%% -----------------------------------------------------------------------------

oracle_frontier(_Local, []) ->
    undefined;
oracle_frontier(Local, Roots0) ->
    case [R || R <- Roots0, is_binary(R)] of
        [] ->
            undefined;
        Roots ->
            PeerSets = [keys_set_at_root(Local, R) || R <- Roots],
            lcp(sorted_keys(Local), PeerSets, undefined)
    end.

keys_set_at_root(Local, R) ->
    bondy_mst:fold(
        Local,
        fun({K, _V}, A) -> sets:add_element(K, A) end,
        sets:new([{version, 2}]),
        [{root, R}]
    ).

sorted_keys(Local) ->
    lists:reverse(bondy_mst:fold(Local, fun({K, _V}, A) -> [K | A] end, [])).

lcp([], _PeerSets, Acc) ->
    Acc;
lcp([K | Rest], PeerSets, Acc) ->
    case lists:all(fun(S) -> sets:is_element(K, S) end, PeerSets) of
        true -> lcp(Rest, PeerSets, K);
        false -> Acc
    end.

%% -----------------------------------------------------------------------------
%% Hand-checked scenarios: assert new == oracle == expected
%% -----------------------------------------------------------------------------

scenarios() ->
    [
        %% {Name, PeerKeysets, LocalKeys, ExpectedFrontier}
        {"peer_subset", [lists:seq(1, 6)], lists:seq(1, 10), 6},
        {"identical", [lists:seq(1, 10)], lists:seq(1, 10), 10},
        {"peer_superset", [lists:seq(1, 10)], lists:seq(1, 6), 6},
        {"gap_in_middle", [[1, 2, 3, 5, 6, 7, 8, 9, 10]], lists:seq(1, 10), 3},
        {"two_peers_min", [lists:seq(1, 8), lists:seq(1, 5)], lists:seq(1, 10),
            5},
        {"disjoint", [lists:seq(6, 10)], lists:seq(1, 5), undefined},
        {"no_peers", [], lists:seq(1, 10), undefined},
        {"empty_local", [lists:seq(1, 5)], [], undefined},
        {"two_full_peers", [lists:seq(1, 10), lists:seq(1, 10)],
            lists:seq(1, 10), 10},
        {"peer_extra_and_hole", [[1, 2, 3, 11, 12]], lists:seq(1, 10), 3}
    ].

frontier_scenarios_test_() ->
    [
        {Name, fun() ->
            {Local, PeerRoots} = setup(
                "frontier_" ++ Name, PeerKeysets, LocalKeys
            ),
            New = bondy_oplog_instance:compute_frontier_for(Local, PeerRoots),
            Oracle = oracle_frontier(Local, PeerRoots),
            ?assertEqual(Oracle, New),
            ?assertEqual(Expected, New)
        end}
     || {Name, PeerKeysets, LocalKeys, Expected} <- scenarios()
    ].

%% -----------------------------------------------------------------------------
%% Randomised sweep: new == oracle on many random local/peer configurations
%% -----------------------------------------------------------------------------

random_sweep_test() ->
    %% Deterministic seed for reproducibility.
    _ = rand:seed(exsss, {17, 42, 99}),
    Universe = lists:seq(1, 30),
    lists:foreach(
        fun(N) ->
            NPeers = 1 + rand:uniform(3),
            PeerKeysets = [
                random_subset(Universe)
             || _ <- lists:seq(1, NPeers)
            ],
            LocalKeys = random_subset(Universe),
            {Local, PeerRoots} = setup(
                "sweep_" ++ integer_to_list(N), PeerKeysets, LocalKeys
            ),
            New = bondy_oplog_instance:compute_frontier_for(Local, PeerRoots),
            Oracle = oracle_frontier(Local, PeerRoots),
            case New =:= Oracle of
                true ->
                    ok;
                false ->
                    erlang:error(
                        {frontier_mismatch, #{
                            n => N,
                            peers => PeerKeysets,
                            local => LocalKeys,
                            new => New,
                            oracle => Oracle
                        }}
                    )
            end
        end,
        lists:seq(1, 80)
    ).

random_subset(Universe) ->
    [K || K <- Universe, rand:uniform() < 0.6].
