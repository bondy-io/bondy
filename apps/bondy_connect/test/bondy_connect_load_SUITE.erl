%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_load_SUITE).

-moduledoc """
Unit tests for `bondy_connect_load`: the in-flight cap, plus the rate-limiter
token-bucket lifecycle (reuse on reconnect, free on teardown — review B4).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

%% The bondy_regulator rate-limiter's (public, named) ETS table.
-define(REG_TAB, bondy_regulator_rate_limit).

all() ->
    [
        unlimited_by_default,
        cap_admits_up_to_max,
        cap_rejects_over_max,
        release_frees_a_slot,
        release_floors_at_zero,
        reset_zeroes_in_flight,
        delete_without_rate_is_noop,
        rate_bucket_reused_on_reset_and_freed_on_delete
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(bondy_regulator),
    Config.

end_per_suite(_) ->
    ok.

unlimited_by_default(_) ->
    L0 = bondy_connect_load:new(#{}),
    L = lists:foldl(
        fun(_, Acc) ->
            {ok, A} = bondy_connect_load:admit(Acc),
            A
        end,
        L0,
        lists:seq(1, 1000)
    ),
    ?assertEqual(1000, bondy_connect_load:in_flight(L)).

cap_admits_up_to_max(_) ->
    L0 = bondy_connect_load:new(#{max_concurrency => 2}),
    {ok, L1} = bondy_connect_load:admit(L0),
    {ok, L2} = bondy_connect_load:admit(L1),
    ?assertEqual(2, bondy_connect_load:in_flight(L2)).

cap_rejects_over_max(_) ->
    L0 = bondy_connect_load:new(#{max_concurrency => 1}),
    {ok, L1} = bondy_connect_load:admit(L0),
    ?assertEqual({error, overloaded}, bondy_connect_load:admit(L1)).

release_frees_a_slot(_) ->
    L0 = bondy_connect_load:new(#{max_concurrency => 1}),
    {ok, L1} = bondy_connect_load:admit(L0),
    ?assertEqual({error, overloaded}, bondy_connect_load:admit(L1)),
    L2 = bondy_connect_load:release(L1),
    ?assertEqual(0, bondy_connect_load:in_flight(L2)),
    ?assertMatch({ok, _}, bondy_connect_load:admit(L2)).

release_floors_at_zero(_) ->
    L0 = bondy_connect_load:new(#{}),
    L1 = bondy_connect_load:release(L0),
    ?assertEqual(0, bondy_connect_load:in_flight(L1)).

reset_zeroes_in_flight(_) ->
    L0 = bondy_connect_load:new(#{}),
    {ok, L1} = bondy_connect_load:admit(L0),
    {ok, L2} = bondy_connect_load:admit(L1),
    ?assertEqual(2, bondy_connect_load:in_flight(L2)),
    L3 = bondy_connect_load:reset(L2),
    ?assertEqual(0, bondy_connect_load:in_flight(L3)).

delete_without_rate_is_noop(_) ->
    ?assertEqual(ok, bondy_connect_load:delete(bondy_connect_load:new(#{}))).

%% A rate-limited load reuses its token bucket across reconnects (`reset/1`)
%% instead of orphaning a bondy_regulator ETS row each time, and frees it on
%% `delete/1` (review B4). Measured as row-count deltas on the regulator's table.
rate_bucket_reused_on_reset_and_freed_on_delete(_) ->
    Before = ets:info(?REG_TAB, size),

    %% new/1 with a `rate` spec creates exactly one bucket row.
    L0 = bondy_connect_load:new(#{rate => #{capacity => 5}}),
    ?assertEqual(Before + 1, ets:info(?REG_TAB, size)),

    %% reset/1 (the reconnect path) must NOT create another row...
    L1 = bondy_connect_load:reset(L0),
    ?assertEqual(Before + 1, ets:info(?REG_TAB, size)),

    %% ...even repeatedly (proving no per-reconnect leak).
    L2 = bondy_connect_load:reset(L1),
    ?assertEqual(Before + 1, ets:info(?REG_TAB, size)),

    %% delete/1 frees the row.
    ok = bondy_connect_load:delete(L2),
    ?assertEqual(Before, ets:info(?REG_TAB, size)).
