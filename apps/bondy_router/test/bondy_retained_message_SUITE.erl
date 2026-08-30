%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_retained_message_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-compile([nowarn_export_all, export_all]).

%% Two distinct valid W3C traceparents; the trace id is the middle field.
-define(TRACE_A, <<"0af7651916cd43dd8448eb211c80319c">>).
-define(TRACE_B, <<"4bf92f3577b34da6a3ce929d0e0e4736">>).
-define(TP_A, <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>).
-define(TP_B, <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>).

all() ->
    [
        {group, crud},
        take_decrements_counters,
        count_limit_is_enforced,
        the_publication_trace_reaches_the_alarm,
        an_untraced_publication_leaves_the_alarm_uncorrelated,
        a_later_publication_does_not_relabel_the_alarm,
        one_realm_over_its_ceiling_does_not_alarm_another,
        the_alarm_clears_once_the_realm_is_under_its_ceiling,
        the_alarm_survives_a_reconcile_while_still_over,
        a_zero_memory_limit_means_no_limit
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

init_per_testcase(_, Config) ->
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

%% A retention-limit alarm is one of only two in the catalogue raised on a
%% request path, so it is the only place `onset_trace_id` can be populated
%% end-to-end. The trace reaches `put/5` inside EVENT.Details, which
%% `bondy_broker:make_event_details/3` fills verbatim from the PUBLISH options
%% (pinned by `bondy_trace_context_SUITE:same_node_publish_trace_context`).
the_publication_trace_reaches_the_alarm(_) ->
    R = <<"com.example.retained.trace_onset">>,
    trip_the_count_limit(R, event_with_trace(?TP_A)),
    ?assertEqual(
        {ok, ?TRACE_A},
        maps:find(onset_trace_id, active_count_limit_alarm(R))
    ).

%% The falsifier for the case above: absent, not `undefined` and not a
%% freshly minted id. Seven of the nine catalogued producers have no request
%% to inherit a trace from, so "no field" is the common case and must not be
%% confused with "correlated".
an_untraced_publication_leaves_the_alarm_uncorrelated(_) ->
    R = <<"com.example.retained.trace_absent">>,
    trip_the_count_limit(R, bondy_wamp_message:event(1, 1, #{})),
    ?assertEqual(
        error,
        maps:find(onset_trace_id, active_count_limit_alarm(R))
    ).

%% `onset_trace_id` names the occurrence that RAISED the condition. Every
%% later publication over the ceiling restates the same alarm, so a second
%% publication carrying a different trace must neither relabel the alarm nor
%% count as a transition — `bondy_alarm_handler:content/1` ignores the field
%% precisely so this restatement is silent. Without that, a realm sitting over
%% its ceiling would evict the history ring and flood `bondy.alarm.updated`
%% once per publish.
a_later_publication_does_not_relabel_the_alarm(_) ->
    R = <<"com.example.retained.trace_first_wins">>,
    trip_the_count_limit(R, event_with_trace(?TP_A)),
    Before = length(bondy_alarm_handler:history()),
    trip_the_count_limit(R, event_with_trace(?TP_B)),
    ?assertEqual(
        {ok, ?TRACE_A},
        maps:find(onset_trace_id, active_count_limit_alarm(R))
    ),
    ?assertEqual(
        Before,
        length(bondy_alarm_handler:history()),
        "a restatement with a new trace recorded a transition"
    ).

%% The falsifier for the id shape. The ceilings are node-wide VALUES, so a
%% node-wide alarm id looks reasonable until two realms are involved: with one
%% id, tripping realm A raises "the" alarm and realm B — which retains
%% normally — is reported over its ceiling too.
one_realm_over_its_ceiling_does_not_alarm_another(_) ->
    A = <<"com.example.retained.isolation_a">>,
    B = <<"com.example.retained.isolation_b">>,
    trip_the_count_limit(A, bondy_wamp_message:event(1, 1, #{})),
    ?assertMatch([_], count_limit_alarms(A)),
    ?assertEqual(
        [],
        count_limit_alarms(B),
        "a realm that never hit its ceiling is reported over it"
    ).

%% The defect this exists to prevent: an alarm that is raised on the write path
%% and observed false by nothing LATCHES, and then reads as "this realm hit its
%% ceiling once since boot" rather than "this realm is at its ceiling now".
%%
%% `trip_the_count_limit/2` drops the realm's retained messages on the way out,
%% so by the time it returns the condition is already false and only the
%% reconcile is missing.
the_alarm_clears_once_the_realm_is_under_its_ceiling(_) ->
    R = <<"com.example.retained.clears">>,
    trip_the_count_limit(R, bondy_wamp_message:event(1, 1, #{})),
    ?assertMatch([_], count_limit_alarms(R)),

    ok = bondy_retained_message_manager:reconcile_limit_alarms(),

    ?assertEqual(
        [],
        count_limit_alarms(R),
        "the alarm outlived the condition it states"
    ).

%% The vacuity guard for the case above. A reconcile that cleared
%% unconditionally would pass it while destroying the alarm's meaning, so this
%% holds the realm OVER its ceiling across the reconcile and requires the alarm
%% to survive. Five publications under a limit of 2 leave 3 retained — the
%% fourth is the one refused — so the condition is still true on the way out.
the_alarm_survives_a_reconcile_while_still_over(_) ->
    R = <<"com.example.retained.still_over">>,
    Event = bondy_wamp_message:event(1, 1, #{}),
    Old = bondy_config:get([wamp_message_retention, max_messages]),
    ok = bondy_config:set([wamp_message_retention, max_messages], 2),
    try
        _ = [
            bondy_retained_message_manager:put(R, topic(I), Event, #{})
         || I <- lists:seq(1, 5)
        ],
        ?assertMatch([_], count_limit_alarms(R)),

        ok = bondy_retained_message_manager:reconcile_limit_alarms(),

        ?assertMatch(
            [_],
            count_limit_alarms(R),
            "the alarm cleared while the realm was still over its ceiling"
        )
    after
        ok = bondy_config:set([wamp_message_retention, max_messages], Old),
        _ = bondy_retained_message:remove_all(R),
        ok = bondy_retained_message_manager:reconcile_limit_alarms()
    end.

%% `wamp.message_retention.max_memory` documents 0 as "no limit is enforced",
%% and the schema accepts it — it carries no `pos_integer` validator, unlike
%% `max_messages`. Compared rather than skipped, `Mem > 0` is true for every
%% realm holding anything at all, so the key that means "unlimited" would stop
%% retention after the FIRST message. The first put is not the falsifier: it
%% happens at `Mem == 0` and would succeed either way.
a_zero_memory_limit_means_no_limit(_) ->
    R = <<"com.example.retained.zero_memory">>,
    Event = bondy_wamp_message:event(1, 1, #{}),
    Old = bondy_config:get([wamp_message_retention, max_memory]),
    ok = bondy_config:set([wamp_message_retention, max_memory], 0),
    try
        ok = bondy_retained_message_manager:put(R, topic(1), Event, #{}),
        ok = bondy_retained_message_manager:put(R, topic(2), Event, #{}),
        ?assertNotEqual(
            undefined,
            bondy_retained_message:get(R, topic(2)),
            "a memory limit of 0 refused retention instead of not enforcing"
        ),
        ?assertEqual([], memory_limit_alarms(R))
    after
        ok = bondy_config:set([wamp_message_retention, max_memory], Old),
        _ = bondy_retained_message:remove_all(R)
    end.

%% @private
%% Publishes past `max_messages` so `put/5` raises the count-limit alarm,
%% then restores the limit and drops the realm's retained messages.
%%
%% Each case uses its OWN realm, which is what makes each of these a RAISE
%% rather than a restatement of the previous case's alarm: the id is
%% `{retained_messages_count_limit, Realm}`. That used to need
%% `init_per_testcase/2` to clear a node-wide alarm between cases.
trip_the_count_limit(Realm, Event) ->
    Old = bondy_config:get([wamp_message_retention, max_messages]),
    ok = bondy_config:set([wamp_message_retention, max_messages], 2),
    try
        _ = [
            bondy_retained_message_manager:put(Realm, topic(I), Event, #{})
         || I <- lists:seq(1, 5)
        ],
        ok
    after
        ok = bondy_config:set([wamp_message_retention, max_messages], Old),
        _ = bondy_retained_message:remove_all(Realm)
    end.

%% @private
event_with_trace(TraceParent) ->
    bondy_wamp_message:event(1, 1, #{'_traceparent' => TraceParent}).

%% @private
active_count_limit_alarm(Realm) ->
    [Alarm] = count_limit_alarms(Realm),
    Alarm.

%% @private
count_limit_alarms(Realm) ->
    alarms_of(retained_messages_count_limit, Realm).

%% @private
memory_limit_alarms(Realm) ->
    alarms_of(retained_messages_memory_limit, Realm).

%% @private
alarms_of(Head, Realm) ->
    [
        A
     || #{id := {H, R}} = A <- bondy_alarm_handler:list(),
        H == Head,
        R == Realm
    ].

topic(I) ->
    <<"com.example.count_limit.", (integer_to_binary(I))/binary>>.
