%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Reproduction for the production dangling-root: compaction (`truncate`)
%% runs every ~1s in production (and was DISABLED in every other MST test),
%% tombstoning pages into the pack store's `free_set`. Physical GC never
%% runs, so the bytes stay on disk — but `get`/`has`/`missing_set` return
%% `undefined` for anything in `free_set`. If `truncate` (alone, or
%% interleaved with `put_batch`) ever leaves a page that is STILL reachable
%% from the live root in the `free_set`, `missing_set(root)` reports a
%% dangling root even though the page is physically present.
%%
%% This exercises `put_batch` waves interleaved with `truncate` (what the
%% compaction scheduler does) on the durable pack store and asserts the
%% live root stays fully servable after every step.
-module(bondy_mst_truncate_dangling_test).

-include_lib("eunit/include/eunit.hrl").

-define(VAL, <<"v">>).

truncate_dangling_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_mst),
            ok
        end,
        fun(_) -> ok end, [
            {timeout, 120, fun truncate_under_churn_keeps_root_servable/0},
            {timeout, 60, fun merge_old_root_after_truncate_servable/0}
        ]}.

%% put_batch waves + truncate (compaction) interleaved.
truncate_under_churn_keeps_root_servable() ->
    with_tmp_dir(fun(Dir) ->
        M0 = pack_tree(Dir, <<"trunc-churn">>),
        N = 2000,
        M1 = bondy_mst:put_batch(M0, [{I, ?VAL} || I <- lists:seq(1, N)]),
        assert_servable(M1),

        %% Each round: append 200 new keys, then truncate the stable
        %% prefix keeping a ~500-key tail (mirrors compaction bounding the
        %% MST). Assert the root is fully servable after each op.
        {Mf, _} = lists:foldl(
            fun(_Round, {M, Hi}) ->
                Wave = [{I, ?VAL} || I <- lists:seq(Hi + 1, Hi + 200)],
                MA = bondy_mst:put_batch(M, Wave),
                assert_servable(MA),
                Hi1 = Hi + 200,
                W = Hi1 - 500,
                MB =
                    case W > 0 of
                        true -> bondy_mst:truncate(MA, W);
                        false -> MA
                    end,
                assert_servable(MB),
                {MB, Hi1}
            end,
            {M1, N},
            lists:seq(1, 30)
        ),
        _ =
            try
                bondy_mst_store:close(bondy_mst:store(Mf))
            catch
                _:_ -> ok
            end,
        ok
    end).

%% The suspected cross-node trigger: truncate tombstones a prefix, then an
%% OLD root (an AAE peer root that still references the tombstoned pages) is
%% merged back. The merged root must be fully servable.
merge_old_root_after_truncate_servable() ->
    with_tmp_dir(fun(Dir) ->
        M0 = pack_tree(Dir, <<"trunc-merge">>),
        M1 = bondy_mst:put_batch(M0, [{I, ?VAL} || I <- lists:seq(1, 1000)]),
        ROld = bondy_mst:root(M1),
        ?assert(is_binary(ROld)),

        %% Compaction bounds the MST to the tail; the prefix pages are
        %% tombstoned.
        M2 = bondy_mst:truncate(M1, 500),
        assert_servable(M2),

        %% Re-introduce the old root (what AAE does when a peer still has
        %% the un-compacted tree). The merged root must be servable and
        %% hold the full key set.
        M3 = bondy_mst:merge(M2, M1, ROld),
        assert_servable(M3),
        Keys = lists:sort([K || {K, _} <- bondy_mst:to_list(M3)]),
        ?assertEqual(lists:seq(1, 1000), Keys),
        _ =
            try
                bondy_mst_store:close(bondy_mst:store(M3))
            catch
                _:_ -> ok
            end,
        ok
    end).

%% =============================================================================
%% Helpers
%% =============================================================================

assert_servable(M) ->
    case bondy_mst:root(M) of
        undefined ->
            ok;
        Root ->
            Missing = lists:sort(
                sets:to_list(normalise(bondy_mst:missing_set(M, Root)))
            ),
            ?assertEqual([], Missing)
    end.

pack_tree(Dir, Id) ->
    bondy_mst:new(#{
        store => bondy_mst_pack_store,
        store_opts => #{
            dir => Dir,
            instance_id => Id,
            auto_seal_records => 64
        },
        merger => fun(_K, _A, B) -> B end
    }).

normalise(L) when is_list(L) -> sets:from_list(L, [{version, 2}]);
normalise(S) -> S.

mktemp_dir() ->
    Base = filename:join([
        "/tmp",
        lists:flatten(
            io_lib:format(
                "bondy_mst_truncate_dangling_~p_~p",
                [
                    erlang:system_time(microsecond),
                    erlang:unique_integer([positive])
                ]
            )
        )
    ]),
    ok = filelib:ensure_path(Base),
    Base.

with_tmp_dir(Fun) ->
    Dir = mktemp_dir(),
    try
        Fun(Dir)
    after
        _ = file:del_dir_r(Dir)
    end.
