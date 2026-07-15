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
%% - on `bondy_mst_map_store` / `bondy_mst_ets_store`, `free/3` physically
%%   removes the page, so it is gone;
%% - on `bondy_mst_pack_store`, `free/3` adds the hash to the `free_set`
%%   tombstone and `get/2`/`has/2`/`missing_set/2` then report the page as
%%   absent *even though its bytes are still on disk* — exactly the
%%   `peer_returned_empty_pages` signature.
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
            {timeout, 120, fun pack_store_invariant/0}
        ]}.

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
