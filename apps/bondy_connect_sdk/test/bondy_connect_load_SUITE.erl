%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_load_SUITE).

-moduledoc """
Unit tests for `bondy_connect_load`: the in-flight cap, plus the rate-limiter
token-bucket lifecycle (reuse on reconnect, and — the property that replaced
"free on teardown" — that the bucket owns no shared row for a teardown to
have to free).
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
        rate_bucket_is_unregistered,
        rate_bucket_reused_on_reset
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

%% The bucket must own NO row in the regulator's shared table. That table is
%% the only place a per-connection bucket could outlive its connection: its old
%% key was `{bondy_connect_load, Pid, unique_integer()}`, which nothing could
%% reconstruct, so a connection that died before its teardown ran orphaned the
%% row permanently. Owning no row is what makes that unreachable — the atomics
%% array is freed with the value.
%%
%% This is the falsifier for that leak: it fails if anyone re-registers the
%% bucket, whether or not a teardown is also added.
rate_bucket_is_unregistered(_) ->
    Before = ets:info(?REG_TAB, size),

    L0 = bondy_connect_load:new(#{rate => #{capacity => 5}}),
    ?assertEqual(Before, ets:info(?REG_TAB, size)),

    %% And it is a working bucket, not an absent one: capacity 5 admits 5.
    L1 = lists:foldl(
        fun(_, Acc) ->
            {ok, A} = bondy_connect_load:admit(Acc),
            bondy_connect_load:release(A)
        end,
        L0,
        lists:seq(1, 5)
    ),
    ?assertEqual({error, overloaded}, bondy_connect_load:admit(L1)),
    ?assertEqual(Before, ets:info(?REG_TAB, size)).

%% A reconnect (`reset/1`) keeps the SAME bucket rather than minting a fresh
%% one, so the reconnecting peer does not get handed a full burst.
rate_bucket_reused_on_reset(_) ->
    L0 = bondy_connect_load:new(#{rate => #{capacity => 2}}),
    {ok, L1} = bondy_connect_load:admit(L0),
    {ok, L2} = bondy_connect_load:admit(L1),
    ?assertEqual({error, overloaded}, bondy_connect_load:admit(L2)),

    %% reset/1 zeroes in-flight but must NOT refill the token bucket.
    L3 = bondy_connect_load:reset(L2),
    ?assertEqual(0, bondy_connect_load:in_flight(L3)),
    ?assertEqual({error, overloaded}, bondy_connect_load:admit(L3)).
