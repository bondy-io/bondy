%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_registry_SUITE).

-moduledoc "Pure unit tests for `bondy_connect_registry`.".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        declare_then_confirm_registration,
        declare_then_confirm_subscription,
        confirm_without_declare_is_noop,
        lookup_by_id_and_uri,
        forget_registration_keeps_declared,
        forget_subscription_keeps_declared,
        undeclare_registration,
        undeclare_subscription,
        declared_lists,
        clear_established_keeps_declared
    ].

declare_then_confirm_registration(_) ->
    H = fun(_, _, _) -> ok end,
    R0 = bondy_connect_registry:new(),
    R1 = bondy_connect_registry:declare_registration(
        <<"a.b">>, H, #{x => 1}, R0
    ),
    %% Not established until confirmed.
    ?assertEqual(error, bondy_connect_registry:registration(99, R1)),
    R2 = bondy_connect_registry:confirm_registration(<<"a.b">>, 99, R1),
    ?assertMatch(
        {ok, #{uri := <<"a.b">>, handler := H, options := #{x := 1}}},
        bondy_connect_registry:registration(99, R2)
    ),
    ?assertEqual(
        {ok, 99}, bondy_connect_registry:registration_id(<<"a.b">>, R2)
    ).

declare_then_confirm_subscription(_) ->
    H = {mod, fun_name},
    R0 = bondy_connect_registry:new(),
    R1 = bondy_connect_registry:declare_subscription(<<"t.1">>, H, #{}, R0),
    R2 = bondy_connect_registry:confirm_subscription(<<"t.1">>, 7, R1),
    ?assertMatch(
        {ok, #{uri := <<"t.1">>, handler := H}},
        bondy_connect_registry:subscription(7, R2)
    ),
    ?assertEqual(
        {ok, 7}, bondy_connect_registry:subscription_id(<<"t.1">>, R2)
    ).

confirm_without_declare_is_noop(_) ->
    R0 = bondy_connect_registry:new(),
    R1 = bondy_connect_registry:confirm_registration(<<"ghost">>, 1, R0),
    ?assertEqual(error, bondy_connect_registry:registration(1, R1)).

lookup_by_id_and_uri(_) ->
    H = fun(_, _, _) -> ok end,
    R = lists:foldl(
        fun({Uri, Id}, Acc) ->
            A = bondy_connect_registry:declare_registration(Uri, H, #{}, Acc),
            bondy_connect_registry:confirm_registration(Uri, Id, A)
        end,
        bondy_connect_registry:new(),
        [{<<"p.1">>, 10}, {<<"p.2">>, 20}]
    ),
    ?assertEqual(
        {ok, 10}, bondy_connect_registry:registration_id(<<"p.1">>, R)
    ),
    ?assertEqual(
        {ok, 20}, bondy_connect_registry:registration_id(<<"p.2">>, R)
    ),
    ?assertEqual(error, bondy_connect_registry:registration_id(<<"p.3">>, R)).

%% forget_registration/2 is the session-scoped router-revocation path: it drops
%% the established id but KEEPS the declared entry, so a reconnect replays it.
forget_registration_keeps_declared(_) ->
    H = fun(_, _, _) -> ok end,
    R0 = bondy_connect_registry:new(),
    R1 = bondy_connect_registry:declare_registration(<<"p">>, H, #{x => 1}, R0),
    R2 = bondy_connect_registry:confirm_registration(<<"p">>, 5, R1),
    R3 = bondy_connect_registry:forget_registration(5, R2),
    %% Established routing is gone (by id and by uri).
    ?assertEqual(error, bondy_connect_registry:registration(5, R3)),
    ?assertEqual(error, bondy_connect_registry:registration_id(<<"p">>, R3)),
    %% Declared/desired entry survives for replay.
    ?assertEqual(
        [{<<"p">>, H, #{x => 1}}],
        bondy_connect_registry:declared_registrations(R3)
    ),
    %% Re-confirming with a fresh id (as reconnect replay does) re-establishes.
    R4 = bondy_connect_registry:confirm_registration(<<"p">>, 6, R3),
    ?assertEqual({ok, 6}, bondy_connect_registry:registration_id(<<"p">>, R4)).

forget_subscription_keeps_declared(_) ->
    H = fun(_, _, _) -> ok end,
    R0 = bondy_connect_registry:new(),
    R1 = bondy_connect_registry:declare_subscription(<<"t">>, H, #{y => 2}, R0),
    R2 = bondy_connect_registry:confirm_subscription(<<"t">>, 3, R1),
    R3 = bondy_connect_registry:forget_subscription(3, R2),
    ?assertEqual(error, bondy_connect_registry:subscription(3, R3)),
    ?assertEqual(error, bondy_connect_registry:subscription_id(<<"t">>, R3)),
    ?assertEqual(
        [{<<"t">>, H, #{y => 2}}],
        bondy_connect_registry:declared_subscriptions(R3)
    ),
    R4 = bondy_connect_registry:confirm_subscription(<<"t">>, 4, R3),
    ?assertEqual({ok, 4}, bondy_connect_registry:subscription_id(<<"t">>, R4)).

%% undeclare_registration/2 is the client-driven unregister path: a permanent
%% removal that drops BOTH established and declared, so a reconnect does NOT
%% replay it.
undeclare_registration(_) ->
    H = fun(_, _, _) -> ok end,
    R0 = bondy_connect_registry:new(),
    R1 = bondy_connect_registry:declare_registration(<<"p">>, H, #{}, R0),
    R2 = bondy_connect_registry:confirm_registration(<<"p">>, 5, R1),
    R3 = bondy_connect_registry:undeclare_registration(5, R2),
    ?assertEqual(error, bondy_connect_registry:registration(5, R3)),
    ?assertEqual(error, bondy_connect_registry:registration_id(<<"p">>, R3)),
    ?assertEqual([], bondy_connect_registry:declared_registrations(R3)).

undeclare_subscription(_) ->
    H = fun(_, _, _) -> ok end,
    R0 = bondy_connect_registry:new(),
    R1 = bondy_connect_registry:declare_subscription(<<"t">>, H, #{}, R0),
    R2 = bondy_connect_registry:confirm_subscription(<<"t">>, 3, R1),
    R3 = bondy_connect_registry:undeclare_subscription(3, R2),
    ?assertEqual(error, bondy_connect_registry:subscription(3, R3)),
    ?assertEqual(error, bondy_connect_registry:subscription_id(<<"t">>, R3)),
    ?assertEqual([], bondy_connect_registry:declared_subscriptions(R3)).

declared_lists(_) ->
    H = fun(_, _, _) -> ok end,
    R0 = bondy_connect_registry:new(),
    R1 = bondy_connect_registry:declare_registration(
        <<"p.1">>, H, #{a => 1}, R0
    ),
    R2 = bondy_connect_registry:declare_subscription(
        <<"t.1">>, H, #{b => 2}, R1
    ),
    ?assertEqual(
        [{<<"p.1">>, H, #{a => 1}}],
        bondy_connect_registry:declared_registrations(R2)
    ),
    ?assertEqual(
        [{<<"t.1">>, H, #{b => 2}}],
        bondy_connect_registry:declared_subscriptions(R2)
    ).

%% clear_established/1 drops server-assigned ids (so inbound routing finds
%% nothing) but keeps the declared set for reconnect replay.
clear_established_keeps_declared(_) ->
    H = fun(_, _, _) -> ok end,
    R0 = bondy_connect_registry:new(),
    R1 = bondy_connect_registry:declare_registration(
        <<"p.1">>, H, #{a => 1}, R0
    ),
    R2 = bondy_connect_registry:confirm_registration(<<"p.1">>, 10, R1),
    R3 = bondy_connect_registry:declare_subscription(
        <<"t.1">>, H, #{b => 2}, R2
    ),
    R4 = bondy_connect_registry:confirm_subscription(<<"t.1">>, 20, R3),

    R = bondy_connect_registry:clear_established(R4),

    %% Established lookups are gone (both by id and by uri).
    ?assertEqual(error, bondy_connect_registry:registration(10, R)),
    ?assertEqual(error, bondy_connect_registry:subscription(20, R)),
    ?assertEqual(error, bondy_connect_registry:registration_id(<<"p.1">>, R)),
    ?assertEqual(error, bondy_connect_registry:subscription_id(<<"t.1">>, R)),

    %% Declared set survives for replay.
    ?assertEqual(
        [{<<"p.1">>, H, #{a => 1}}],
        bondy_connect_registry:declared_registrations(R)
    ),
    ?assertEqual(
        [{<<"t.1">>, H, #{b => 2}}],
        bondy_connect_registry:declared_subscriptions(R)
    ),

    %% Re-confirming with fresh ids (as replay does) re-establishes routing.
    R5 = bondy_connect_registry:confirm_registration(<<"p.1">>, 11, R),
    ?assertEqual(
        {ok, 11}, bondy_connect_registry:registration_id(<<"p.1">>, R5)
    ).
