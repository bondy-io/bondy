%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_retained_message_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-compile([nowarn_export_all, export_all]).

all() ->
    [
        {group, crud},
        take_decrements_counters,
        count_limit_is_enforced
    ].

groups() ->
    [
        {crud, [sequence], [
            put,
            prefix_match,
            wildcard_match
        ]}
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    %% bondy_ct:stop_bondy(),
    {save_config, Config}.

put(Config0) ->
    R = <<"com.leapsight.test">>,
    T = <<"com.foo.bar.1">>,
    Event = bondy_wamp_message:event(1, 1, #{}),
    ok = bondy_retained_message:put(R, T, Event, #{}),
    ?assertEqual(
        bondy_retained_message,
        element(1, bondy_retained_message:get(R, T))
    ),
    ok = bondy_retained_message:put(R, <<"com.foo.bar.1.1">>, Event, #{}),
    ok = bondy_retained_message:put(R, <<"com.foo.bar.1.2">>, Event, #{}),
    _ = [
        begin
            Topic = <<"com.foo.bar.2.", (integer_to_binary(X))/binary>>,
            bondy_retained_message:put(R, Topic, Event, #{})
        end
     || X <- lists:seq(1, 500)
    ],
    Config = [{realm, R}, {topic, T} | Config0],
    {save_config, Config}.

exact_match(Config) ->
    SavedConfig = element(2, ?config(saved_config, Config)),
    R = ?config(realm, SavedConfig),
    T = ?config(topic, SavedConfig),
    {Result, _} = bondy_retained_message:match(R, T, 1, <<"exact">>),
    ?assertEqual(1, length(Result)),
    {save_config, SavedConfig}.

prefix_match(Config) ->
    SavedConfig = element(2, ?config(saved_config, Config)),
    R = ?config(realm, SavedConfig),
    T = ?config(topic, SavedConfig),
    {Result, _} = bondy_retained_message:match(R, T, 1, <<"prefix">>),
    ?assertEqual(3, length(Result)),
    {save_config, SavedConfig}.

wildcard_match(Config) ->
    SavedConfig = element(2, ?config(saved_config, Config)),
    R = ?config(realm, SavedConfig),
    {Result, _} = bondy_retained_message:match(
        R, <<"com...">>, 1, <<"wildcard">>
    ),
    ?assertEqual(1, length(Result)),
    {L1, C1} = bondy_retained_message:match(
        R, <<"com....">>, 1, <<"wildcard">>
    ),
    ?assertEqual(100, length(L1)),
    {L2, C2} = bondy_retained_message:match(C1),
    ?assertEqual(100, length(L2)),
    ?assertNotEqual(C1, C2).

take_decrements_counters(_) ->
    %% The per-realm counters gate retention: once they read at the configured
    %% limit the realm retains nothing more. Taking a message removes it from
    %% storage, so a take that does not decrement them makes the realm look
    %% permanently fuller than it is.
    R = <<"com.example.retained.counters">>,
    T = <<"com.example.counters.topic">>,
    Event = bondy_wamp_message:event(1, 1, #{}),

    #{messages := M0, memory := B0} =
        bondy_retained_message_manager:counters(R),

    ok = bondy_retained_message_manager:put(R, T, Event, #{}),
    #{messages := M1, memory := B1} =
        bondy_retained_message_manager:counters(R),
    ?assertEqual(M0 + 1, M1),
    ?assert(B1 > B0),

    ?assertNotEqual(undefined, bondy_retained_message_manager:take(R, T)),
    ?assertEqual(undefined, bondy_retained_message:get(R, T)),

    #{messages := M2, memory := B2} =
        bondy_retained_message_manager:counters(R),
    ?assertEqual(M0, M2, "taking the message must give the count back"),
    ?assertEqual(B0, B2, "taking the message must give the memory back").

count_limit_is_enforced(_) ->
    %% `wamp_message_retention.max_messages` is a cap on how many messages a
    %% realm retains. Past it a publish is dropped and an alarm raised, so the
    %% limit has to be read from the same counters `put/5` maintains.
    R = <<"com.example.retained.count_limit">>,
    Event = bondy_wamp_message:event(1, 1, #{}),
    Old = bondy_config:get([wamp_message_retention, max_messages]),
    ok = bondy_config:set([wamp_message_retention, max_messages], 2),

    try
        _ = [
            bondy_retained_message_manager:put(
                R, topic(I), Event, #{}
            )
         || I <- lists:seq(1, 5)
        ],
        #{messages := N} = bondy_retained_message_manager:counters(R),
        ?assert(
            N =< 3,
            lists:flatten(
                io_lib:format("retained ~p messages under a limit of 2", [N])
            )
        )
    after
        ok = bondy_config:set([wamp_message_retention, max_messages], Old),
        _ = bondy_retained_message:remove_all(R)
    end.

topic(I) ->
    <<"com.example.count_limit.", (integer_to_binary(I))/binary>>.
