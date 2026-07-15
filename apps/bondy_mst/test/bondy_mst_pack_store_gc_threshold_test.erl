%% =============================================================================
%% Coverage for the `gc_threshold_dead_fraction` open option.
%%
%% Default (`0.0`) preserves the original "rewrite on any drop"
%% behaviour. A positive threshold lets operators accept up to that
%% fraction of dead pages in a single sealed pack before paying for
%% a rewrite. Multi-pack coalescing is unaffected — when there are
%% 2+ sealed packs the GC always merges them into one.
%%
%% Pack-store QA item #9.
%% =============================================================================

-module(bondy_mst_pack_store_gc_threshold_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Test helpers (mirror the patterns in bondy_mst_pack_store_test)
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_mst_pack_store_gc_threshold_~p_~p",
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

open_store_with(Dir, Extra) ->
    bondy_mst_store:open(
        bondy_mst_pack_store,
        sha256,
        maps:merge(
            #{
                dir => Dir,
                instance_id => <<"pack-store-gc-threshold-test">>
            },
            Extra
        )
    ).

mk_page(Key, Value) ->
    bondy_mst_page:new(0, undefined, [{Key, Value, undefined}]).

seal(S) ->
    {bondy_mst_store, _, Backend, _} = S,
    {ok, B1} = bondy_mst_pack_store:seal(Backend),
    setelement(3, S, B1).

pack_ids(S) ->
    {bondy_mst_store, _, Backend, _} = S,
    bondy_mst_pack_store:sealed_pack_ids(Backend).

put_many(S, KVs) ->
    lists:foldl(
        fun({K, V}, {HsAcc, SAcc}) ->
            {H, SAcc1} = bondy_mst_store:put(SAcc, mk_page(K, V)),
            {[H | HsAcc], SAcc1}
        end,
        {[], S},
        KVs
    ).

%% =============================================================================
%% Default behaviour: threshold=0.0 → any drop compacts (regression)
%% =============================================================================

default_threshold_compacts_any_drop_test() ->
    %% Threshold defaults to 0.0; any non-zero drop fires GC.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{}),
        {[H1 | _], S1} = put_many(S0, [{a, 1}, {b, 2}, {c, 3}]),
        S2 = seal(S1),
        ?assertEqual([1], pack_ids(S2)),
        {S3, Meta} = bondy_mst_store:gc(S2, [H1]),
        try
            ?assertMatch(
                #{
                    compacted := true,
                    retired := [1],
                    kept := 1,
                    dropped := 2
                },
                Meta
            )
        after
            _ = bondy_mst_store:close(S3)
        end
    end).

%% =============================================================================
%% Threshold gates single-pack rewrite when dead fraction is too low
%% =============================================================================

high_threshold_skips_low_dead_fraction_test() ->
    %% 1 of 10 pages dropped → fraction 0.1 < 0.5 → no rewrite.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{gc_threshold_dead_fraction => 0.5}),
        KVs = [{K, K} || K <- lists:seq(1, 10)],
        {Hs, S1} = put_many(S0, KVs),
        [HFirst | KeepRest] = lists:reverse(Hs),
        S2 = seal(S1),
        ?assertEqual([1], pack_ids(S2)),
        %% Keep all but the first hash → drops exactly 1.
        {S3, Meta} = bondy_mst_store:gc(S2, KeepRest),
        try
            ?assertMatch(
                #{
                    compacted := false,
                    reason := below_threshold,
                    kept := 9,
                    dropped := 1
                },
                Meta
            ),
            %% The pack is still there, untouched.
            ?assertEqual([1], pack_ids(S3)),
            %% And the "dropped" page is still gettable (it survived
            %% the threshold-skip — that's the whole point).
            ?assertNotEqual(undefined, bondy_mst_store:get(S3, HFirst))
        after
            _ = bondy_mst_store:close(S3)
        end
    end).

%% =============================================================================
%% Threshold lets rewrite through when dead fraction is high enough
%% =============================================================================

high_threshold_fires_when_fraction_met_test() ->
    %% 6 of 10 pages dropped → fraction 0.6 ≥ 0.5 → rewrite.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{gc_threshold_dead_fraction => 0.5}),
        KVs = [{K, K} || K <- lists:seq(1, 10)],
        {Hs, S1} = put_many(S0, KVs),
        S2 = seal(S1),
        %% Keep 4 of 10 → 6 dropped, fraction 0.6.
        Keep = lists:sublist(lists:reverse(Hs), 4),
        {S3, Meta} = bondy_mst_store:gc(S2, Keep),
        try
            ?assertMatch(
                #{
                    compacted := true,
                    retired := [1],
                    new_pack := 2,
                    kept := 4,
                    dropped := 6
                },
                Meta
            ),
            ?assertEqual([2], pack_ids(S3))
        after
            _ = bondy_mst_store:close(S3)
        end
    end).

%% =============================================================================
%% Multi-pack coalescing ignores the threshold
%% =============================================================================

multi_pack_always_coalesces_test() ->
    %% Two sealed packs, zero drops → threshold should NOT block the
    %% merge (coalescing is independent of dead fraction).
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{gc_threshold_dead_fraction => 0.99}),
        {[H1], S1} = put_many(S0, [{a, 1}]),
        S2 = seal(S1),
        {[H2], S3} = put_many(S2, [{b, 2}]),
        S4 = seal(S3),
        ?assertEqual([2, 1], pack_ids(S4)),
        {S5, Meta} = bondy_mst_store:gc(S4, [H1, H2]),
        try
            ?assertMatch(
                #{
                    compacted := true,
                    retired := [1, 2],
                    new_pack := 3,
                    kept := 2,
                    dropped := 0
                },
                Meta
            ),
            ?assertEqual([3], pack_ids(S5))
        after
            _ = bondy_mst_store:close(S5)
        end
    end).

%% =============================================================================
%% Multi-pack with low-fraction drops still merges
%% =============================================================================

multi_pack_with_drops_below_threshold_still_merges_test() ->
    %% Two sealed packs + 1 dropped of 10 → fraction 0.1 < 0.99 but
    %% multi-pack coalescing wins → rewrite.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{gc_threshold_dead_fraction => 0.99}),
        {Hs1, S1} = put_many(S0, [{K, K} || K <- lists:seq(1, 5)]),
        S2 = seal(S1),
        {Hs2, S3} = put_many(S2, [{K, K} || K <- lists:seq(6, 10)]),
        S4 = seal(S3),
        AllHs = lists:reverse(Hs1) ++ lists:reverse(Hs2),
        [_HDropped | Keep] = AllHs,
        {S5, Meta} = bondy_mst_store:gc(S4, Keep),
        try
            ?assertMatch(
                #{
                    compacted := true,
                    kept := 9,
                    dropped := 1
                },
                Meta
            ),
            ?assertEqual([3], pack_ids(S5))
        after
            _ = bondy_mst_store:close(S5)
        end
    end).

%% =============================================================================
%% Single-pack with zero drops is still no-op regardless of threshold
%% =============================================================================

single_pack_zero_drops_still_no_op_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{gc_threshold_dead_fraction => 0.5}),
        {Hs, S1} = put_many(S0, [{K, K} || K <- lists:seq(1, 5)]),
        S2 = seal(S1),
        {S3, Meta} = bondy_mst_store:gc(S2, lists:reverse(Hs)),
        try
            ?assertMatch(#{compacted := false}, Meta),
            ?assertNotEqual(
                #{reason => below_threshold},
                #{reason => maps:get(reason, Meta, undefined)}
            ),
            ?assertEqual([1], pack_ids(S3))
        after
            _ = bondy_mst_store:close(S3)
        end
    end).

%% =============================================================================
%% Boundary: 0 / 1 integer aliasing
%% =============================================================================

integer_zero_and_one_accepted_test() ->
    with_tmp_dir(fun(Dir1) ->
        S0 = open_store_with(Dir1, #{gc_threshold_dead_fraction => 0}),
        _ = bondy_mst_store:close(S0)
    end),
    with_tmp_dir(fun(Dir2) ->
        S0 = open_store_with(Dir2, #{gc_threshold_dead_fraction => 1}),
        _ = bondy_mst_store:close(S0)
    end).

%% =============================================================================
%% Validation: bad values rejected at open time
%% =============================================================================

bad_threshold_rejected_at_open_test() ->
    with_tmp_dir(fun(Dir) ->
        ?assertError(
            {invalid_opt, gc_threshold_dead_fraction, -0.1},
            open_store_with(Dir, #{gc_threshold_dead_fraction => -0.1})
        ),
        ?assertError(
            {invalid_opt, gc_threshold_dead_fraction, 1.5},
            open_store_with(Dir, #{gc_threshold_dead_fraction => 1.5})
        ),
        ?assertError(
            {invalid_opt, gc_threshold_dead_fraction, half},
            open_store_with(Dir, #{gc_threshold_dead_fraction => half})
        )
    end).

%% =============================================================================
%% Threshold exactly at boundary fires the rewrite
%% =============================================================================

threshold_at_exact_boundary_fires_test() ->
    %% 2 of 4 pages dropped → fraction 0.5 exactly, threshold 0.5 → fires.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{gc_threshold_dead_fraction => 0.5}),
        {Hs, S1} = put_many(S0, [{K, K} || K <- lists:seq(1, 4)]),
        S2 = seal(S1),
        Keep = lists:sublist(lists:reverse(Hs), 2),
        {S3, Meta} = bondy_mst_store:gc(S2, Keep),
        try
            ?assertMatch(
                #{
                    compacted := true,
                    kept := 2,
                    dropped := 2
                },
                Meta
            )
        after
            _ = bondy_mst_store:close(S3)
        end
    end).
