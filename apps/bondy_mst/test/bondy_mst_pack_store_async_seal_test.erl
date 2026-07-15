%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% EUnit suite for the `bondy_mst_pack_store` asynchronous-seal orchestration:
%% the `seal_mode = async` switch (put no longer seals inline), the
%% `maybe_roll_for_seal/1` → `run_seal_job/1` → `complete_seal/2` pipeline,
%% the in-flight=1 defer, and the read-union seen through the store while a
%% seal is in flight. Operates on the raw store record directly (the
%% `bondy_mst` surface delegation is wired separately).
%% =============================================================================

-module(bondy_mst_pack_store_async_seal_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_mst_pack.hrl").

%% =============================================================================
%% Fixture helpers
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_mst_pack_store_async_seal_test_~p_~p",
                [
                    erlang:system_time(microsecond),
                    erlang:unique_integer([positive])
                ]
            )
        ]
    ),
    Dir = lists:flatten(Base),
    ok = filelib:ensure_path(Dir),
    Dir.

rmrf(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.

with_tmp_dir(Fun) ->
    Dir = mktemp_dir(),
    try
        Fun(Dir)
    after
        rmrf(Dir)
    end.

%% Raw async-mode store with a low record threshold.
open_async(Dir, Threshold) ->
    bondy_mst_pack_store:open(sha256, #{
        dir => Dir,
        instance_id => <<"l2-async">>,
        seal_mode => async,
        auto_seal_records => Threshold,
        auto_seal_bytes => infinity
    }).

open_sync(Dir, Threshold) ->
    bondy_mst_pack_store:open(sha256, #{
        dir => Dir,
        instance_id => <<"l2-sync">>,
        auto_seal_records => Threshold,
        auto_seal_bytes => infinity
    }).

mk_page(Level, Low, List) ->
    bondy_mst_page:new(Level, Low, List).

%% Distinct pages, each a single-entry leaf keyed by index.
pages(N) ->
    [mk_page(0, undefined, [{I, I, undefined}]) || I <- lists:seq(1, N)].

%% Puts each page, returns {Store, [{Hash, Page}]} (insertion order reversed).
put_all(T0, Pages) ->
    lists:foldl(
        fun(Page, {T, Acc}) ->
            {Hash, T1} = bondy_mst_pack_store:put(T, Page),
            {T1, [{Hash, Page} | Acc]}
        end,
        {T0, []},
        Pages
    ).

assert_all_get(T, Pairs) ->
    lists:foreach(
        fun({Hash, Page}) ->
            ?assertEqual(Page, bondy_mst_pack_store:get(T, Hash)),
            ?assert(bondy_mst_pack_store:has(T, Hash))
        end,
        Pairs
    ).

%% =============================================================================
%% seal_mode wiring
%% =============================================================================

async_mode_put_never_seals_inline_test() ->
    with_tmp_dir(fun(Dir) ->
        T0 = open_async(Dir, 3),
        %% Put well past the threshold; in async mode put must NOT seal.
        {T1, _Pairs} = put_all(T0, pages(10)),
        ?assertEqual([], bondy_mst_pack_store:sealed_pack_ids(T1)),
        ?assertNot(bondy_mst_pack_store:seal_in_flight(T1)),
        bondy_mst_pack_store:close(T1)
    end).

sync_mode_put_still_seals_inline_test() ->
    with_tmp_dir(fun(Dir) ->
        %% Default mode is sync: put crossing the threshold seals inline.
        T0 = open_sync(Dir, 3),
        {T1, _Pairs} = put_all(T0, pages(5)),
        ?assertEqual([1], bondy_mst_pack_store:sealed_pack_ids(T1)),
        bondy_mst_pack_store:close(T1)
    end).

%% =============================================================================
%% roll → run → complete through the store
%% =============================================================================

maybe_roll_noop_below_threshold_test() ->
    with_tmp_dir(fun(Dir) ->
        T0 = open_async(Dir, 5),
        {T1, _} = put_all(T0, pages(2)),
        ?assertMatch({noop, _}, bondy_mst_pack_store:maybe_roll_for_seal(T1)),
        bondy_mst_pack_store:close(T1)
    end).

roll_run_complete_through_store_test() ->
    with_tmp_dir(fun(Dir) ->
        T0 = open_async(Dir, 4),
        {T1, Pairs} = put_all(T0, pages(4)),

        %% Threshold crossed, no seal in flight → rolled.
        {rolled, Job, T2} = bondy_mst_pack_store:maybe_roll_for_seal(T1),
        ?assert(bondy_mst_pack_store:seal_in_flight(T2)),
        ?assertEqual(1, maps:get(pack_id, Job)),
        %% Not yet a sealed view — still in flight.
        ?assertEqual([], bondy_mst_pack_store:sealed_pack_ids(T2)),

        %% Reads are served from the in-flight snapshot mid-seal.
        assert_all_get(T2, Pairs),

        %% Worker runs the job, instance completes it.
        ?assertEqual(ok, bondy_mst_pack_store:run_seal_job(Job)),
        {ok, T3} = bondy_mst_pack_store:complete_seal(T2, 1),
        ?assertNot(bondy_mst_pack_store:seal_in_flight(T3)),
        ?assertEqual([1], bondy_mst_pack_store:sealed_pack_ids(T3)),

        %% Reads now served from the mounted sealed view.
        assert_all_get(T3, Pairs),
        bondy_mst_pack_store:close(T3)
    end).

%% =============================================================================
%% in-flight=1 defer
%% =============================================================================

defer_while_seal_in_flight_then_roll_again_test() ->
    with_tmp_dir(fun(Dir) ->
        T0 = open_async(Dir, 3),
        {T1, Pairs1} = put_all(T0, pages(3)),
        {rolled, Job1, T2} = bondy_mst_pack_store:maybe_roll_for_seal(T1),
        ?assertEqual(1, maps:get(pack_id, Job1)),

        %% Append more past the threshold while the first seal is in flight.
        {T3, Pairs2} = put_all(T2, [
            mk_page(0, undefined, [{n, I, undefined}])
         || I <- lists:seq(1, 4)
        ]),
        ?assertMatch({defer, _}, bondy_mst_pack_store:maybe_roll_for_seal(T3)),

        %% Complete the first seal, then a second roll is admitted.
        ?assertEqual(ok, bondy_mst_pack_store:run_seal_job(Job1)),
        {ok, T4} = bondy_mst_pack_store:complete_seal(T3, 1),
        ?assertNot(bondy_mst_pack_store:seal_in_flight(T4)),

        {rolled, Job2, T5} = bondy_mst_pack_store:maybe_roll_for_seal(T4),
        ?assertEqual(2, maps:get(pack_id, Job2)),
        ?assertEqual(ok, bondy_mst_pack_store:run_seal_job(Job2)),
        {ok, T6} = bondy_mst_pack_store:complete_seal(T5, 2),
        ?assertEqual([2, 1], bondy_mst_pack_store:sealed_pack_ids(T6)),

        %% Both batches readable across the two sealed packs.
        assert_all_get(T6, Pairs1 ++ Pairs2),
        bondy_mst_pack_store:close(T6)
    end).

%% =============================================================================
%% capability advertisement
%% =============================================================================

capabilities_async_seal_flag_test() ->
    with_tmp_dir(fun(Dir) ->
        T = open_async(Dir, 100),
        ?assertEqual(
            true, maps:get(async_seal, bondy_mst_pack_store:capabilities(T))
        ),
        bondy_mst_pack_store:close(T),
        Ets = bondy_mst_ets_store:open(sha256, #{name => <<"ets-cap">>}),
        ?assertEqual(
            false, maps:get(async_seal, bondy_mst_ets_store:capabilities(Ets))
        )
    end).

invalid_seal_mode_rejected_test() ->
    with_tmp_dir(fun(Dir) ->
        ?assertError(
            {invalid_opt, seal_mode, bogus},
            bondy_mst_pack_store:open(sha256, #{
                dir => Dir,
                instance_id => <<"bad">>,
                seal_mode => bogus
            })
        )
    end).
