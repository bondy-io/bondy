%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Completeness tests for `bondy_db:fold/6` and `fold/7`.
%%
%% ## The defect these exist for
%%
%% `range_all/5` returns ONE page — `?DEFAULT_RANGE_LIMIT` rows, 1000 — and
%% several callers wanted a whole sub-band and passed `#{}`, taking that
%% default. The result is a silently truncated prefix that is indistinguishable
%% from a short band, so nothing anywhere raises. Where those callers were
%% REVOKING (`bondy_rbac:revoke_role_grants/3`,
%% `bondy_rbac_source:remove_all/2`) the truncation left rows behind through
%% the very operation that exists to remove them; where they were READING
%% (`find_grants/4`, `scan_user/2`, `bondy_rbac_user:member_groups/2`) it
%% dropped grants, sources and group memberships — permissions — off the end.
%%
%% Every band here is therefore deliberately LONGER than the default limit.
%% A test that stayed under it would pass against the defect, which is exactly
%% how the defect survived: every existing test used a handful of rows.
%%
%% The clear-while-folding case has its own test because it is the one that
%% could plausibly break under a forward cursor. It does not: a cleared cell
%% keeps its place in the band until stabilization, so the walk neither skips
%% the row after it nor revisits it.

-module(bondy_db_fold_completeness_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_lww_register).
-define(R, <<"realm">>).
%% Two shards, not more, and a band this long, for one reason: the walk pages
%% PER SHARD, so what has to exceed the chunk size is rows-per-shard, not rows
%% in the band. At 4 shards a 2500-row band is ~625 per shard — under the
%% 1000-row default — and the paging loop never runs at all. A mutation that
%% made the fold stop after its first page passed the whole suite before this
%% was corrected.
-define(SHARDS, 2).
%% ~1500 rows per shard: over `?DEFAULT_RANGE_LIMIT` (1000), which is both the
%% walk's default chunk and what a single `range_all/5` page capped at.
-define(BAND, 3000).
%% Rows outside the band, to prove the bounds still hold at this size.
-define(OUTSIDE, 50).

fold_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Ctx) ->
        [
            {timeout, 300,
                {"fold/6 returns a band longer than the default page", fun() ->
                    fold_is_complete(Ctx)
                end}},
            {timeout, 300,
                {"fold/6 respects the band's bounds", fun() ->
                    fold_respects_bounds(Ctx)
                end}},
            {timeout, 300,
                {"fold/7 shard-pinned covers that shard's rows exactly",
                    fun() -> fold_shard_pinned(Ctx) end}},
            {timeout, 300,
                {"clearing from inside the fold visits every row once", fun() ->
                        clear_while_folding(Ctx)
                    end}}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    {ok, Db} = bondy_db:open(bondy_db_fold_complete, #{
        topology => bondy_db_topology_memory,
        shard_count => ?SHARDS,
        fold_module => lww_register
    }),
    {ok, T} = bondy_db:open_table(Db, items, #{
        fold_module => lww_register,
        crdt_module => ?CRDT
    }),
    %% `b/...` is the band under test; `a/...` and `c/...` bracket it.
    Keys =
        [band_key(I) || I <- lists:seq(1, ?BAND)] ++
            [outside_key(<<"a">>, I) || I <- lists:seq(1, ?OUTSIDE)] ++
            [outside_key(<<"c">>, I) || I <- lists:seq(1, ?OUTSIDE)],
    _ = [
        bondy_db:apply(T, ?R, K, {set, bondy_db:tick(T), <<"v">>})
     || K <- Keys
    ],
    {Db, T}.

cleanup({Db, _T}) ->
    try
        bondy_db:close(Db)
    catch
        _:_ -> ok
    end,
    ok.

fold_is_complete({_Db, T}) ->
    Got = fold_keys(T, <<"b/">>, <<"b0">>),
    ?assertEqual(?BAND, length(Got)),
    ?assertEqual(expected_band(), lists:sort(Got)).

fold_respects_bounds({_Db, T}) ->
    %% Nothing from the bracketing bands, at either end.
    Got = fold_keys(T, <<"b/">>, <<"b0">>),
    ?assert(
        lists:all(
            fun
                (<<"b/", _/binary>>) -> true;
                (_) -> false
            end,
            Got
        )
    ),
    %% ...and the upper bound stays exclusive over a long band: stopping one
    %% row late is invisible unless the boundary row exists.
    Mid = band_key(1000),
    Under = fold_keys(T, <<"b/">>, Mid),
    ?assertEqual(999, length(Under)),
    ?assertNot(lists:member(Mid, Under)).

fold_shard_pinned({_Db, T}) ->
    %% The shard-pinned form must return exactly the band rows that live on
    %% that shard — no more (it must not walk the others) and no fewer (it
    %% must still page to exhaustion).
    PerShard = [
        {S, begin
            {ok, Rev} = bondy_db:fold(
                T,
                ?R,
                <<"b/">>,
                <<"b0">>,
                fun({K, _V, _H}, Acc) -> [K | Acc] end,
                [],
                #{shard => S}
            ),
            lists:reverse(Rev)
        end}
     || S <- lists:seq(0, ?SHARDS - 1)
    ],
    %% Every row lands on exactly one shard, and the union is the whole band.
    _ = [
        ?assert(
            lists:all(
                fun(K) -> bondy_db:shard_for(T, ?R, K) =:= S end, Keys
            )
        )
     || {S, Keys} <- PerShard
    ],
    Union = lists:append([Keys || {_S, Keys} <- PerShard]),
    ?assertEqual(?BAND, length(Union)),
    ?assertEqual(expected_band(), lists:sort(Union)).

clear_while_folding({_Db, T}) ->
    %% Clear every row of a band from inside the fold that is walking it. A
    %% forward cursor over storage keys must visit each row exactly once —
    %% a cleared cell keeps its place until stabilization, so it can neither
    %% swallow its successor nor be seen twice.
    Prefix = <<"d/">>,
    N = ?BAND,
    _ = [
        bondy_db:apply(
            T, ?R, seq_key(Prefix, I), {set, bondy_db:tick(T), <<"v">>}
        )
     || I <- lists:seq(1, N)
    ],
    {ok, Visited} = bondy_db:fold(
        T,
        ?R,
        Prefix,
        <<"d0">>,
        fun({K, _V, _H}, Acc) ->
            ok = bondy_db:apply(T, ?R, K, clear),
            [K | Acc]
        end,
        []
    ),
    ?assertEqual(N, length(Visited)),
    ?assertEqual(N, length(lists:usort(Visited))),
    %% ...and every cell really is cleared (cleared cells read back as a
    %% non-binary value, so the scan still sees the rows).
    Live = [
        K
     || {K, V, _H} <- fold_rows(T, Prefix, <<"d0">>), is_binary(V)
    ],
    ?assertEqual([], Live).

%% =============================================================================
%% HELPERS
%% =============================================================================

fold_keys(T, Lo, Hi) ->
    [K || {K, _V, _H} <- fold_rows(T, Lo, Hi)].

fold_rows(T, Lo, Hi) ->
    {ok, Rev} = bondy_db:fold(
        T, ?R, Lo, Hi, fun(Row, Acc) -> [Row | Acc] end, []
    ),
    lists:reverse(Rev).

expected_band() ->
    lists:sort([band_key(I) || I <- lists:seq(1, ?BAND)]).

band_key(I) ->
    seq_key(<<"b/">>, I).

seq_key(Prefix, I) ->
    iolist_to_binary([Prefix, io_lib:format("~8..0b", [I])]).

outside_key(Prefix, I) ->
    seq_key(<<Prefix/binary, "/">>, I).
