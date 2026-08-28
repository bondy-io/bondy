%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Reproduction for the "dangling page" data-loss observed in production
%% AAE: a node advertises an MST root whose pages it then refuses to
%% serve (`peer_returned_empty_pages`), and local reads silently lose the
%% subtree (the dangling-page recovery in `bondy_mst:merge_aux/5`,
%% `split/4`, `put_at/6` treats the missing subtree as empty).
%%
%% Hypothesis under test: the MST is content-addressed, so identical
%% subtrees are stored once and referenced from more than one position
%% (structural sharing). `split/4` (reached from `merge/3`, the engine of
%% `put_batch/2`) calls `bondy_mst_store:free/3` on the page it rewrites.
%% When that page's hash is *also* reachable from a sibling subtree that
%% the merge keeps by reference, the free wrongly drops a page that is
%% still live:
%%
%% - on `bondy_mst_map_store`, `free/3` physically removes the page, so
%%   it is gone (sound only there: single consumer, no old roots);
%% - on `bondy_mst_ets_store` and `bondy_mst_pack_store`, `free/3` only
%%   tombstones and reads serve tombstoned pages (the tombstone gates
%%   reclamation and enumeration, never a read), so a wrong free is
%%   latent until a collection acts on it — the pack rewrite keeps
%%   `reachable ∩ non-tombstoned` and drops the page outright.
%%
%% The store-level invariant that must hold after every committed write is
%% therefore: every page reachable from the current root is present, i.e.
%% `missing_set(root) == []`, and `to_list/1` returns every live key.
%%
%% This harness drives a deterministic churn workload (no randomness, so a
%% failure is reproducible) that maximises structural sharing — a constant
%% value across keys makes equal-shaped subtrees byte-identical — and
%% interleaves the inserts so the merge has to split existing pages. The
%% same workload runs against the map store (algorithm-level loss) and the
%% pack store (free_set masking + durability across reopen).
-module(bondy_mst_free_reachable_test).

-include_lib("eunit/include/eunit.hrl").

%% A constant value maximises structural sharing: subtrees over different
%% key ranges that have the same shape become byte-identical pages and are
%% stored once, referenced from several positions.
-define(VAL, <<"v">>).

%% =============================================================================
%% EUNIT
%% =============================================================================

free_reachable_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_mst),
            ok
        end,
        fun(_) -> ok end, [
            {timeout, 60, fun map_store_invariant/0},
            {timeout, 120, fun pack_store_invariant/0},
            {timeout, 60, fun foreign_split_frees_nothing/0}
        ]}.

%% The FOREIGN owner rule in `bondy_mst:split/5`: decomposing the DONOR
%% tree's pages while merging must never `free/3` them — the receiver's
%% store holds them (the AAE adopt-then-integrate path `put_page`s the
%% peer's pages into the local store and then merges the peer root), and
%% until the merge commits they are reachable only from the pinned peer
%% root. Freeing them there tombstones pulled pages mid-integrate; on
%% the pack store a later collection (`reachable ∩ non-tombstoned`)
%% would then drop them outright.
%%
%% This drives the exact production shape — adopt a fully-interleaved
%% peer tree, merge its root — and asserts NO page of either the merged
%% root's tree or the peer's tree carries a tombstone afterwards. The
%% merge only ever frees pages it path-copied AWAY (owned rewrites of
%% the receiver's old spine, unreachable from the new root), so a
%% tombstone on anything still reachable is an over-free. Reverting
%% `foreign` to free (one word in `split_page/6`) trips this on the
%% peer-root walk.
foreign_split_frees_nothing() ->
    N = 200,
    %% DISJOINT, fully interleaved key sets, deliberately — both halves
    %% of the trap:
    %%
    %% - Every receiver key is absent from the donor, so the merge must
    %%   `split/5` the donor's pages at every receiver entry — the
    %%   foreign path runs down the donor's spine over and over.
    %%   (Overlapping key sets short-circuit the aligned regions and
    %%   barely exercise the foreign path.)
    %% - Disjoint keys mean no page of A can alias a page of P, so
    %%   "zero tombstones on either walk" is an exact invariant — an
    %%   OWNED free of A's replaced spine cannot legitimately tombstone
    %%   a row some kept twin still references.
    %%
    %% `put_batch/2` cannot catch this rule even though it merges a
    %% foreign (map-store) batch tree: the batch pages are absent from
    %% the receiver's store, so a wrong free there is a no-op. The
    %% adopt step below is what arms it.
    A0 = new_ets_tree(<<"foreign_recv">>),
    A = bondy_mst:put_batch(A0, [{2 * I, <<"a">>} || I <- lists:seq(1, N)]),

    P0 = new_ets_tree(<<"foreign_peer">>),
    P = bondy_mst:put_batch(
        P0, [{2 * I + 1, <<"p">>} || I <- lists:seq(0, N - 1)]
    ),
    PeerRoot = bondy_mst:root(P),

    %% Adopt: the sync session's `put_page` stream.
    A1 = lists:foldl(
        fun(Page, Acc) ->
            {_, Acc1} = bondy_mst:put_page(Acc, Page),
            Acc1
        end,
        A,
        [
            Pg
         || {_H, Pg} <- bondy_mst:fold_pages(
                P,
                fun(HP, Acc) -> [HP | Acc] end,
                [],
                #{root => PeerRoot}
            )
        ]
    ),
    %% The production integrate guard: the peer root is fully servable
    %% from the receiver's store before the merge.
    ?assertEqual(
        [], sets:to_list(sets_from(bondy_mst:missing_set(A1, PeerRoot)))
    ),

    A2 = bondy_mst:merge(A1, A1, PeerRoot),
    Store = bondy_mst:store(A2),

    ?assertEqual([], tombstoned_reachable(A2, Store, bondy_mst:root(A2))),
    ?assertEqual([], tombstoned_reachable(A2, Store, PeerRoot)),
    %% And the merge produced the union.
    ?assertEqual(
        lists:seq(1, 2 * N),
        lists:sort([K || {K, _} <- bondy_mst:to_list(A2)])
    ),
    %% The adopted peer root stays fully servable: until its pin is
    %% consumed, the next compaction marks from it.
    ?assertEqual(
        [], sets:to_list(sets_from(bondy_mst:missing_set(A2, PeerRoot)))
    ),

    ok = destroy_quiet(P),
    ok = destroy_quiet(A2).

%% @private
%% Every page reachable from `Root` that is not `live` in the store —
%% `fold_pages/4` reads THROUGH tombstones, so the walk itself cannot
%% distinguish them; `page_state/2` can.
tombstoned_reachable(T, Store, Root) ->
    lists:filtermap(
        fun({H, _}) ->
            case bondy_mst_store:page_state(Store, H) of
                live -> false;
                S -> {true, {H, S}}
            end
        end,
        bondy_mst:fold_pages(
            T, fun(HP, Acc) -> [HP | Acc] end, [], #{root => Root}
        )
    ).

%% @private
new_ets_tree(Name) ->
    bondy_mst:new(#{
        store => bondy_mst_ets_store,
        store_opts => #{name => Name},
        merger => fun(_K, _A, B) -> B end
    }).

%% @private
destroy_quiet(T) ->
    try
        bondy_mst:destroy(T)
    catch
        _:_ -> ok
    end.

%% The merge/split free path must never drop a page still reachable from
%% the root. On the map store an over-free physically loses the page.
map_store_invariant() ->
    M0 = bondy_mst:new(#{
        store => bondy_mst_map_store,
        store_opts => #{},
        merger => fun(_K, _A, B) -> B end
    }),
    _M = run_workload(M0, fun(M) -> M end),
    ok.

%% Same workload on the durable pack store: an over-free tombstones a
%% still-reachable page in the `free_set`, so the bytes survive on disk
%% but `get`/`missing_set` lie. We also flush + reopen to prove the
%% tombstone (and thus the dangling root) is durable, mirroring what AAE
%% advertises to a peer.
pack_store_invariant() ->
    with_tmp_dir(fun(Dir) ->
        Opts = #{
            dir => Dir,
            instance_id => <<"free-reachable-test">>,
            %% Force seals during the churn so the bug is exercised across
            %% the pending/sealed boundary, not just in pending.
            auto_seal_records => 64
        },
        M0 = bondy_mst:new(#{
            store => bondy_mst_pack_store,
            store_opts => Opts,
            merger => fun(_K, _A, B) -> B end
        }),
        %% Flush after each step so every assertion sees committed state.
        Flush = fun(M) ->
            {ok, M1} = bondy_mst:flush(M),
            M1
        end,
        {M1, Live} = run_workload_collect(M0, Flush),
        ok = bondy_mst_store:close(bondy_mst:store(M1)),

        %% Reopen: the persisted root must still be fully servable.
        M2 = bondy_mst:new(#{
            store => bondy_mst_pack_store,
            store_opts => Opts,
            merger => fun(_K, _A, B) -> B end
        }),
        assert_invariant(M2, Live),
        ok = bondy_mst_store:close(bondy_mst:store(M2))
    end).

%% =============================================================================
%% Workload
%% =============================================================================

%% @private
run_workload(M0, Flush) ->
    {M, _Live} = run_workload_collect(M0, Flush),
    M.

%% @private
%% Deterministic churn:
%%   1. seed evens via put_batch (one canonical bulk-built tree),
%%   2. interleave odds in chunks via put_batch (forces the merge to
%%      split existing even-keyed pages — the free path under test),
%%   3. a delete sweep (a second free path),
%% asserting after every committed step that nothing reachable is missing.
run_workload_collect(M0, Flush) ->
    N = 1500,

    %% Wave 0 — seed with evens.
    Evens = [{2 * I, ?VAL} || I <- lists:seq(1, N)],
    M1 = Flush(bondy_mst:put_batch(M0, Evens)),
    Live1 = lists:sort([K || {K, _} <- Evens]),
    assert_invariant(M1, Live1),

    %% Waves 1..K — interleave odds in chunks so each batch straddles
    %% existing keys and the merge must split pages.
    OddItems = [{2 * I + 1, ?VAL} || I <- lists:seq(1, N)],
    {M2, Live2} = lists:foldl(
        fun(Chunk, {MAcc, LAcc}) ->
            MAcc1 = Flush(bondy_mst:put_batch(MAcc, Chunk)),
            LAcc1 = lists:umerge(LAcc, lists:sort([K || {K, _} <- Chunk])),
            assert_invariant(MAcc1, LAcc1),
            {MAcc1, LAcc1}
        end,
        {M1, Live1},
        chunks(OddItems, 100)
    ),

    %% Delete sweep — every 5th live key.
    ToDelete = [K || K <- Live2, K rem 5 =:= 0],
    {M3, Live3} = lists:foldl(
        fun(K, {MAcc, LAcc}) ->
            MAcc1 = Flush(bondy_mst:delete(MAcc, K)),
            {MAcc1, lists:delete(K, LAcc)}
        end,
        {M2, Live2},
        ToDelete
    ),
    assert_invariant(M3, Live3),

    {M3, Live3}.

%% =============================================================================
%% Assertions
%% =============================================================================

%% @private
%% The core invariant: the committed root is fully servable and the tree
%% holds exactly the live key set.
assert_invariant(M, ExpectedKeys) ->
    case bondy_mst:root(M) of
        undefined ->
            ?assertEqual([], ExpectedKeys);
        Root ->
            Missing = lists:sort(
                sets:to_list(
                    sets_from(bondy_mst:missing_set(M, Root))
                )
            ),
            ?assertEqual([], Missing),
            Got = lists:sort([K || {K, _} <- bondy_mst:to_list(M)]),
            ?assertEqual(ExpectedKeys, Got)
    end.

%% @private
%% `missing_set/2` returns a list on some backends and a sets:set() on
%% others; normalise to a set.
sets_from(L) when is_list(L) ->
    sets:from_list(L, [{version, 2}]);
sets_from(S) ->
    S.

%% =============================================================================
%% Helpers
%% =============================================================================

%% @private
chunks([], _) ->
    [];
chunks(L, N) ->
    {H, T} = lists:split(min(N, length(L)), L),
    [H | chunks(T, N)].

%% @private
mktemp_dir() ->
    Base = filename:join([
        "/tmp",
        lists:flatten(
            io_lib:format(
                "bondy_mst_free_reachable_~p_~p",
                [
                    erlang:system_time(microsecond),
                    erlang:unique_integer([positive])
                ]
            )
        )
    ]),
    ok = filelib:ensure_path(Base),
    Base.

%% @private
with_tmp_dir(Fun) ->
    Dir = mktemp_dir(),
    try
        Fun(Dir)
    after
        _ = file:del_dir_r(Dir)
    end.
