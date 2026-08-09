%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_keepalive_SUITE).

-moduledoc """
Pure unit tests for `bondy_connect_keepalive` — the idle keepalive budget
extracted from the connection statem. No sockets, no processes.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

-define(IDLE, 5000).
-define(TIMEOUT, 1000).
-define(MAX, 3).

all() ->
    [
        enabled_idle_pings,
        enabled_actions_and_payload,
        ping_timeouts_exhaust_to_give_up,
        activity_resets_budget,
        disabled_is_all_noop
    ].

%% An enabled keepalive answers the idle timer with a ping + its deadline.
enabled_idle_pings(_) ->
    KA = bondy_connect_keepalive:new(enabled()),
    ?assertEqual({ping, ?TIMEOUT}, bondy_connect_keepalive:on_idle(KA)).

%% Timer actions and payload reflect the config.
enabled_actions_and_payload(_) ->
    KA = bondy_connect_keepalive:new(enabled()),
    ?assertEqual(
        [{{timeout, ping_idle}, ?IDLE, ping_idle}],
        bondy_connect_keepalive:idle_actions(KA)
    ),
    ?assertEqual(
        [{{timeout, ping}, cancel}, {{timeout, ping_idle}, ?IDLE, ping_idle}],
        bondy_connect_keepalive:reset_actions(KA)
    ),
    P = bondy_connect_keepalive:payload(KA),
    ?assert(is_binary(P)),
    ?assertEqual(12, byte_size(P)).

%% Repeated unanswered ping deadlines eventually give up (reconnect) — and every
%% step before that asks for another ping.
ping_timeouts_exhaust_to_give_up(_) ->
    KA = bondy_connect_keepalive:new(enabled()),
    {Decisions, _KA1} = drain_timeouts(KA, 0),
    ?assertEqual(give_up, lists:last(Decisions)),
    ?assert(lists:all(fun(D) -> D =:= ping end, lists:droplast(Decisions))),
    %% It must take more than one failure to give up (a budget, not a hair
    %% trigger) but still be bounded by the configured attempts.
    ?assert(length(Decisions) > 1),
    ?assert(length(Decisions) =< ?MAX + 2).

%% Inbound activity resets the failure budget: after some failures, an
%% on_activity restores the full budget before the next give-up.
activity_resets_budget(_) ->
    KA0 = bondy_connect_keepalive:new(enabled()),
    %% Burn two failures (still pinging, not yet given up).
    {ping, _, KA1} = bondy_connect_keepalive:on_ping_timeout(KA0),
    {ping, _, KA2} = bondy_connect_keepalive:on_ping_timeout(KA1),
    %% Activity resets the counter.
    KA3 = bondy_connect_keepalive:on_activity(KA2),
    %% The budget to give up is now the full budget again, not the 1-2 remaining.
    {Decisions, _} = drain_timeouts(KA3, 0),
    ?assertEqual(give_up, lists:last(Decisions)),
    {DecisionsFresh, _} = drain_timeouts(KA0, 0),
    ?assertEqual(length(DecisionsFresh), length(Decisions)).

%% A disabled keepalive is a no-op everywhere.
disabled_is_all_noop(_) ->
    lists:foreach(
        fun(Cfg) ->
            KA = bondy_connect_keepalive:new(Cfg),
            ?assertEqual(disabled, bondy_connect_keepalive:on_idle(KA)),
            ?assertEqual(disabled, bondy_connect_keepalive:on_ping_timeout(KA)),
            ?assertEqual(KA, bondy_connect_keepalive:on_activity(KA)),
            ?assertEqual([], bondy_connect_keepalive:idle_actions(KA)),
            ?assertEqual([], bondy_connect_keepalive:reset_actions(KA)),
            ?assertEqual(undefined, bondy_connect_keepalive:payload(KA))
        end,
        [#{}, #{enabled => false}, #{enabled => false, idle_timeout => 1}]
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

enabled() ->
    #{
        enabled => true,
        idle_timeout => ?IDLE,
        timeout => ?TIMEOUT,
        max_attempts => ?MAX
    }.

%% @private Fire ping-deadline timeouts until give_up, collecting the decision
%% kind (`ping' | `give_up') at each step. Guarded against a runaway loop.
drain_timeouts(_KA, N) when N > 50 ->
    ct:fail(never_gave_up);
drain_timeouts(KA, N) ->
    case bondy_connect_keepalive:on_ping_timeout(KA) of
        {ping, _Deadline, KA1} ->
            {Rest, KAEnd} = drain_timeouts(KA1, N + 1),
            {[ping | Rest], KAEnd};
        {give_up, KA1} ->
            {[give_up], KA1}
    end.
