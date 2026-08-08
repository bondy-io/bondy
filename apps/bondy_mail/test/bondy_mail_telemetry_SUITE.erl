%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_telemetry_SUITE).

-moduledoc """
The events, the metric families, and the relay-down alarm.

Every case drives a real send through `mock_smtp_server` and asserts on what
came out the other side, rather than calling the emitters directly. An emitter
called by a test and by nothing else is a function that compiles.

The two claims worth reading are `permanent_failure_does_not_mark_a_relay_down`
and `a_message_with_no_caller_is_a_dead_letter`. Both describe a distinction
that is easy to state and easy to lose in a refactor, and neither is visible
from the shape of the code.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_mail/include/bondy_mail.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, ~"com.example.app").
-define(HANDLER, ?MODULE).

-define(EVENTS, [
    [bondy, mail, accepted],
    [bondy, mail, sent],
    [bondy, mail, retried],
    [bondy, mail, failed],
    [bondy, mail, dead_letter],
    [bondy, mail, rate_limited],
    [bondy, mail, queue],
    [bondy, mail, rejected],
    [bondy, mail, relay_status]
]).

suite() ->
    [{timetrap, {minutes, 2}}].

all() ->
    [
        %% Events
        a_delivered_message_emits_accepted_sent_and_queue,
        the_surface_distinguishes_the_two_callers,
        a_retry_is_reported_with_its_error_class,
        a_permanent_failure_reports_its_nature,
        a_full_queue_is_a_rejection_not_a_failure,
        rate_limiting_is_its_own_event,
        a_message_with_no_caller_is_a_dead_letter,
        a_message_with_a_caller_is_not_a_dead_letter,
        %% Metrics
        families_are_declared_before_anything_is_sent,
        a_send_writes_its_families,
        %% Health and alarm
        consecutive_transient_failures_mark_a_relay_down,
        permanent_failure_does_not_mark_a_relay_down,
        one_success_brings_a_relay_back_up,
        removing_a_relay_clears_its_alarm
    ].

init_per_suite(Config) ->
    %% `alarm_handler` lives in sasl, and without it every alarm assertion
    %% would be asserting about a process that is not there.
    {ok, _} = application:ensure_all_started(sasl),
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(jobs),
    {ok, _} = application:ensure_all_started(bondy_regulator),

    %% `bondy_metrics` declares no `{mod, _}`: starting the application does
    %% not start its registry, so it is started here by hand. Unlinked, or its
    %% exit would take this process's tables with it when the suite's init
    %% process finishes.
    {ok, Pid} = start_metrics(),
    true = unlink(Pid),

    {ok, Port} = mock_smtp_server:start(),
    [{port, Port} | Config].

end_per_suite(_Config) ->
    _ = application:stop(bondy_mail),
    ok = mock_smtp_server:stop(),
    ok.

init_per_testcase(_Case, Config) ->
    ok = mock_smtp_server:clear(),
    ok = clear_alarms(),
    ok = restart(relays(?config(port, Config))),
    ok = subscribe(),
    Config.

end_per_testcase(_Case, _Config) ->
    ok = unsubscribe(),
    _ = application:stop(bondy_mail),
    ok.

%% =============================================================================
%% EVENTS
%% =============================================================================

a_delivered_message_emits_accepted_sent_and_queue(_) ->
    {ok, _} = send(#{}),
    Events = drain(),

    ?assertMatch(
        {#{count := 1}, #{relay := ~"default", realm := ?REALM}},
        find([bondy, mail, accepted], Events)
    ),
    ?assertMatch(
        {#{duration := _}, #{
            relay := ~"default", realm := ?REALM, attempts := 1
        }},
        find([bondy, mail, sent], Events)
    ),
    %% The depth is what was left behind rather than what was there: one
    %% message in, one message taken.
    ?assertMatch(
        {#{depth := 0, wait := _}, #{relay := ~"default"}},
        find([bondy, mail, queue], Events)
    ).

-doc """
The two surfaces are distinguishable, and default to `rpc`.

`surface` exists so an operator can tell mail a client asked for from mail an
event produced. It is set inside Bondy and is not a field a peer can supply.
""".
the_surface_distinguishes_the_two_callers(_) ->
    {ok, _} = bondy_mail:send(?REALM, base(), #{surface => bridge}),
    {_, #{surface := Bridge}} = await_event([bondy, mail, accepted]),
    ?assertEqual(bridge, Bridge),

    {ok, _} = bondy_mail:send(?REALM, base()),
    {_, #{surface := Default}} = await_event([bondy, mail, accepted]),
    ?assertEqual(rpc, Default).

a_retry_is_reported_with_its_error_class(_) ->
    ok = mock_smtp_server:fail_next_data({1, "451 greylisted"}),

    {ok, _} = send(#{}),

    {_, Meta} = await_event([bondy, mail, retried]),
    ?assertEqual(#{relay => ~"default", reason_class => deferred}, Meta).

-doc """
A failure reports whether it is worth waiting for.

`nature` is the one label that decides whether an operator pages someone or
lets the retry budget do its work, so it is asserted exactly rather than
matched loosely.
""".
a_permanent_failure_reports_its_nature(_) ->
    ok = mock_smtp_server:fail_data("550 mailbox unavailable"),

    {error, _} = send(#{}),
    Events = drain(),

    ?assertMatch(
        {#{duration := _}, #{
            relay := ~"default", nature := permanent, reason_class := rejected
        }},
        find([bondy, mail, failed], Events)
    ),
    %% And it is not retried: a permanent failure is offered once. The relay
    %% has a retry budget of 2, so a classification bug would show here.
    ?assertEqual(0, count([bondy, mail, retried], Events)).

-doc """
A refusal before a worker is a rejection, not a failure.

The distinction is the whole point of having both: `failed` means a relay
declined a message it was shown, and nothing counted in `rejected` was ever
offered to a relay. Conflating them makes a saturated queue look like a broken
relay.
""".
a_full_queue_is_a_rejection_not_a_failure(_) ->
    ok = mock_smtp_server:latency(3000),

    _ = [
        bondy_mail:send_async(?REALM, (base())#{~"relay" => ~"slow"})
     || _ <- lists:seq(1, 20)
    ],

    {_, Meta} = await_event([bondy, mail, rejected]),
    ?assertEqual(#{relay => ~"slow", reason => queue_full}, Meta).

rate_limiting_is_its_own_event(_) ->
    _ = [
        bondy_mail:send_async(?REALM, (base())#{~"relay" => ~"limited"})
     || _ <- lists:seq(1, 10)
    ],

    {_, Meta} = await_event([bondy, mail, rate_limited]),
    ?assertEqual(#{relay => ~"limited", realm => ?REALM}, Meta).

-doc """
A failed message nobody is waiting for is a dead letter.

That is what makes it dead rather than merely failed: there is no caller to
receive the error, so this event and the log line beside it are the only record
it existed. Every message the broker bridge sends is in this category.
""".
a_message_with_no_caller_is_a_dead_letter(_) ->
    ok = mock_smtp_server:fail_data("550 mailbox unavailable"),

    {ok, _} = bondy_mail:send_async(?REALM, base()),

    {_, Meta} = await_event([bondy, mail, dead_letter]),
    ?assertEqual(
        #{relay => ~"default", realm => ?REALM, reason_class => rejected}, Meta
    ).

-doc """
A synchronous send that fails is not a dead letter.

The caller received the error and can decide what to do about it. Counting it
here as well would make the dead-letter rate -- which exists to surface
failures nobody saw -- track failures somebody did.
""".
a_message_with_a_caller_is_not_a_dead_letter(_) ->
    ok = mock_smtp_server:fail_data("550 mailbox unavailable"),

    {error, _} = send(#{}),
    Events = drain(),

    %% The failure itself is reported.
    ?assertMatch({_, _}, find([bondy, mail, failed], Events)),
    ?assertEqual(0, count([bondy, mail, dead_letter], Events)).

%% =============================================================================
%% METRICS
%% =============================================================================

-doc """
Every family the dashboard queries is declared.

Declaring registers the name, type and help text; it does not by itself put the
family in the exposition, which `bondy_prometheus_collector` populates from the
first write onwards. What this case protects against is the other failure: a
dashboard panel querying a family no emitter ever declares, which renders as an
empty graph and reads as "nothing is wrong".
""".
families_are_declared_before_anything_is_sent(_) ->
    Declared = maps:keys(bondy_metrics:declared()),
    Expected = [
        bondy_mail_accepted_total,
        bondy_mail_dead_letter_total,
        bondy_mail_failed_total,
        bondy_mail_queue_depth,
        bondy_mail_queue_wait_milliseconds,
        bondy_mail_rate_limited_total,
        bondy_mail_rejected_total,
        bondy_mail_relay_up,
        bondy_mail_retried_total,
        bondy_mail_send_duration_milliseconds,
        bondy_mail_sent_total
    ],
    Missing = Expected -- Declared,
    ?assertEqual([], Missing).

-doc """
A send moves the families the dashboard reads.

Asserted through `bondy_metrics` rather than through the events, because an
event that fires and a sink that records it are two different things, and the
sink is what a dashboard sees.
""".
a_send_writes_its_families(_) ->
    Label = #{relay => ~"default"},
    Duration = #{name => bondy_mail_send_duration_milliseconds, label => Label},
    Accepted = Label#{surface => rpc},

    %% A delta, and not an absolute count. `bondy_metrics` is a registry that
    %% outlives the application, so its counters accumulate across every case
    %% in this suite -- an assertion on the absolute value would pass or fail
    %% on which cases ran first.
    Before = snapshot(Duration),
    BeforeAccepted = counter_value(bondy_mail_accepted_total, Accepted),

    {ok, _} = send(#{}),
    _ = drain(),

    Delta = bondy_metrics:histogram_delta(snapshot(Duration), Before),
    Stats = bondy_metrics:histogram_stats(Delta),
    ?assertEqual(1, maps:get(count, Stats)),

    %% The counter too, since a histogram that records and a counter that does
    %% not would still satisfy the line above.
    AfterAccepted = counter_value(bondy_mail_accepted_total, Accepted),
    ?assertEqual(1, AfterAccepted - BeforeAccepted).

%% =============================================================================
%% HEALTH AND ALARM
%% =============================================================================

-doc """
A relay goes down after `health.failure_threshold` consecutive transient
failures, and not before.

One timeout happens to healthy infrastructure. The threshold is what stops a
single bad minute becoming a page, and the first assertion here is that one
failure is not enough.
""".
consecutive_transient_failures_mark_a_relay_down(_) ->
    %% `flaky` has a threshold of 2.
    ok = mock_smtp_server:fail_data("451 try again later"),

    {error, _} = send(#{~"relay" => ~"flaky"}),
    ?assertEqual(0, count([bondy, mail, relay_status], drain())),
    ?assertNot(alarm_set(~"flaky")),

    {error, _} = send(#{~"relay" => ~"flaky"}),
    %% The event before the alarm, and not the other way round: the worker
    %% reports to the relay with a cast, so the send returning says nothing
    %% about the relay having processed it yet. The event is emitted just
    %% before the alarm is raised, which makes it the signal to wait on.
    ?assertEqual(
        {#{count => 1}, #{relay => ~"flaky", status => down}},
        await_event([bondy, mail, relay_status])
    ),
    ?assert(alarm_set(~"flaky")).

-doc """
A permanent failure never marks a relay down, however many there are.

A rejected recipient, an oversized message and a refused credential are all the
relay working correctly. Counting them against its health would raise a page
about a caller's mistake -- and, worse, would do so at exactly the moment an
operator most needs the signal to mean something.
""".
permanent_failure_does_not_mark_a_relay_down(_) ->
    ok = mock_smtp_server:fail_data("550 mailbox unavailable"),

    _ = [send(#{~"relay" => ~"flaky"}) || _ <- lists:seq(1, 5)],

    ?assertEqual(0, count([bondy, mail, relay_status], drain())),
    ?assertNot(alarm_set(~"flaky")).

-doc """
Traffic recovers on the first success, and so does the alarm at the default
threshold.

Recovery is fail-open on purpose: a relay that is merely flaky should not be
described as down a moment longer than it is. `health.success_threshold` gates
only the alarm, so an operator who wants more evidence before the page clears
can ask for it without making callers wait for it.
""".
one_success_brings_a_relay_back_up(_) ->
    ok = mock_smtp_server:fail_data("451 try again later"),
    {error, _} = send(#{~"relay" => ~"flaky"}),
    {error, _} = send(#{~"relay" => ~"flaky"}),
    {_, #{status := down}} = await_event([bondy, mail, relay_status]),

    ok = mock_smtp_server:clear(),
    {ok, _} = send(#{~"relay" => ~"flaky"}),

    {_, Meta} = await_event([bondy, mail, relay_status]),
    ?assertEqual(#{relay => ~"flaky", status => up}, Meta),
    ?assertNot(alarm_set(~"flaky")).

-doc """
A relay that is removed takes its alarm with it.

Leaving it set would leave an operator paging about infrastructure that no
longer exists, and no later success can clear it because nothing will ever
succeed on a relay that is gone.
""".
removing_a_relay_clears_its_alarm(Config) ->
    ok = mock_smtp_server:fail_data("451 try again later"),
    {error, _} = send(#{~"relay" => ~"flaky"}),
    {error, _} = send(#{~"relay" => ~"flaky"}),
    {_, #{status := down}} = await_event([bondy, mail, relay_status]),
    ?assert(alarm_set(~"flaky")),

    %% Reconfigured without it.
    Remaining = [
        R
     || R <- relays(?config(port, Config)), maps:get(name, R) =/= ~"flaky"
    ],
    ok = restart(Remaining),

    ?assertNot(alarm_set(~"flaky")).

%% =============================================================================
%% PRIVATE -- SENDING
%% =============================================================================

%% @private
send(Overrides) ->
    bondy_mail:send(?REALM, maps:merge(base(), Overrides)).

%% @private
base() ->
    #{
        ~"relay" => ~"default",
        ~"to" => [~"user@example.com"],
        ~"subject" => ~"Hello",
        ~"text" => ~"Body"
    }.

%% @private
restart(Relays) ->
    _ = application:stop(bondy_mail),
    ok = application:set_env(bondy_mail, relays, Relays),
    ok = application:set_env(bondy_mail, default_relay, undefined),
    {ok, _} = application:ensure_all_started(bondy_mail),
    ok.

%% @private
relays(Port) ->
    Common = #{
        host => ~"127.0.0.1",
        port => Port,
        transport => plain,
        auth => never,
        from => ~"no-reply@example.com",
        realms => any,
        retry_max_attempts => 0,
        retry_backoff_min => 10,
        retry_backoff_max => 50
    },
    [
        %% Retries enabled here and nowhere else: a_retry_is_reported asserts
        %% on an event that only a relay with a retry budget can produce.
        Common#{name => ~"default", retry_max_attempts => 2},
        %% Two failures rather than the default three, so the case that proves
        %% one is not enough still only needs two.
        Common#{name => ~"flaky", health_failure_threshold => 2},
        Common#{
            name => ~"limited", rate_limit_rate => 1, rate_limit_burst => 1
        },
        Common#{
            name => ~"slow",
            pool_size => 1,
            queue_max_size => 1,
            timeout => 10000
        }
    ].

%% =============================================================================
%% PRIVATE -- TELEMETRY
%% =============================================================================

%% @private
subscribe() ->
    Pid = self(),
    Fun = fun(Event, Measurements, Meta, _) ->
        Pid ! {telemetry, Event, Measurements, Meta}
    end,
    telemetry:attach_many(?HANDLER, ?EVENTS, Fun, undefined).

%% @private
unsubscribe() ->
    _ = telemetry:detach(?HANDLER),
    ok = flush(),
    ok.

%% @private
flush() ->
    receive
        {telemetry, _, _, _} -> flush()
    after 0 -> ok
    end.

%% @private
%% Collect every event that arrives, then assert over the collection.
%%
%% The obvious helper -- wait for the one event this assertion is about,
%% discarding the rest -- is wrong here, and quietly so: a single send emits
%% `accepted`, `queue` and `sent` in that order, so waiting for `sent` throws
%% away the `queue` event that preceded it and the next assertion reports an
%% event that did fire as missing. Draining first costs a few hundred
%% milliseconds per case and cannot lose anything.
drain() ->
    lists:reverse(drain([], 5000)).

%% @private
%% Waits `First` for something to happen at all, then a short quiet period for
%% the rest. A `send_async` failure arrives well after the call returns, which
%% is why the first wait is generous and the others are not.
drain(Acc, First) ->
    receive
        {telemetry, Event, Measurements, Meta} ->
            drain([{Event, Measurements, Meta} | Acc], 300)
    after First ->
        Acc
    end.

%% @private
await_event(Event) ->
    case find(Event, drain()) of
        false -> ct:fail({no_event, Event});
        Found -> Found
    end.

%% @private
find(_Event, []) ->
    false;
find(Event, [{Event, Measurements, Meta} | _]) ->
    {Measurements, Meta};
find(Event, [_ | T]) ->
    find(Event, T).

%% @private
%% Every occurrence, for the cases that assert an event fired exactly once.
count(Event, Events) ->
    length([E || {E, _, _} <- Events, E == Event]).

%% =============================================================================
%% PRIVATE -- METRICS AND ALARMS
%% =============================================================================

%% @private
%% `not_found` before anything has been recorded under this label, which is
%% the state the first case to run finds it in.
snapshot(Spec) ->
    case bondy_metrics:histogram_snapshot(Spec) of
        {ok, Snapshot} -> Snapshot;
        not_found -> #{count => 0, sum => 0, buckets => []}
    end.

%% @private
counter_value(Name, Label) ->
    case bondy_metrics:value(#{name => Name, label => Label}) of
        undefined -> 0;
        Value -> Value
    end.

%% @private
%% @private
start_metrics() ->
    case bondy_metrics:start_link() of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid}
    end.

%% @private
alarm_set(Relay) ->
    Id = {mail_relay_down, Relay},
    lists:keymember(Id, 1, alarm_handler:get_alarms()).

%% @private
clear_alarms() ->
    _ = [
        alarm_handler:clear_alarm(Id)
     || {Id, _} <- alarm_handler:get_alarms()
    ],
    ok.
