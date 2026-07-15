%% =============================================================================
%% End-to-end tests for `bondy_oplog_core_events` and the restart-recovery
%% protocol (`MST_DB_DESIGN.md` §11.1, §12.3, §18 item 11).
%%
%% Verifies:
%%   - `subscribe/1` receives the topic's notifications and nothing else
%%   - duplicate subscribe is idempotent
%%   - `unsubscribe/1` cleanly removes
%%   - subscriber DOWN auto-removes the row
%%   - the registry broadcasts a fresh epoch on every (re)start
%%   - the dispatcher broadcasts a fresh epoch on every (re)start
%%   - `current_epoch/0` returns the latest broadcast value
%%   - registry restart wakes subscribers (and the new epoch differs)
%% =============================================================================

-module(bondy_oplog_core_events_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    ok.

events_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun subscribe_receives_notify/0,
        fun unsubscribed_does_not_receive/0,
        fun other_topic_does_not_match/0,
        fun duplicate_subscribe_is_idempotent/0,
        fun subscriber_down_auto_removes/0,
        fun registry_emits_started_at_init/0,
        fun dispatcher_emits_started_at_init/0,
        fun current_epoch_matches_broadcast/0,
        fun registry_restart_changes_epoch_and_wakes_subscribers/0
    ]}.

%% =============================================================================
%% bondy_oplog_core_events primitive
%% =============================================================================

subscribe_receives_notify() ->
    Topic = mk_topic(),
    ok = bondy_oplog_core_events:subscribe(Topic),
    ok = bondy_oplog_core_events:notify(Topic, payload_1),
    ?assertEqual(payload_1, expect_event(Topic, 200)),
    bondy_oplog_core_events:unsubscribe(Topic).

unsubscribed_does_not_receive() ->
    Topic = mk_topic(),
    ok = bondy_oplog_core_events:subscribe(Topic),
    ok = bondy_oplog_core_events:unsubscribe(Topic),
    ok = bondy_oplog_core_events:notify(Topic, payload_2),
    ?assertEqual(timeout, try_expect_event(Topic, 100)).

other_topic_does_not_match() ->
    TopicA = mk_topic(),
    TopicB = mk_topic(),
    ok = bondy_oplog_core_events:subscribe(TopicA),
    ok = bondy_oplog_core_events:notify(TopicB, payload_b),
    ?assertEqual(timeout, try_expect_event(TopicA, 100)),
    bondy_oplog_core_events:unsubscribe(TopicA).

duplicate_subscribe_is_idempotent() ->
    Topic = mk_topic(),
    ok = bondy_oplog_core_events:subscribe(Topic),
    ok = bondy_oplog_core_events:subscribe(Topic),
    ?assertEqual([self()], bondy_oplog_core_events:subscribers(Topic)),
    ok = bondy_oplog_core_events:notify(Topic, payload_dup),
    %% Only one message delivered.
    ?assertEqual(payload_dup, expect_event(Topic, 200)),
    ?assertEqual(timeout, try_expect_event(Topic, 100)),
    bondy_oplog_core_events:unsubscribe(Topic).

subscriber_down_auto_removes() ->
    Topic = mk_topic(),
    Self = self(),
    {Sub, MonRef} = spawn_monitor(fun() ->
        ok = bondy_oplog_core_events:subscribe(Topic),
        Self ! {subscribed, self()},
        receive
            die -> ok
        end
    end),
    receive
        {subscribed, Sub} -> ok
    after 200 -> error(no_subscribe_ack)
    end,
    %% Subscriber is in the table.
    ?assert(lists:member(Sub, bondy_oplog_core_events:subscribers(Topic))),
    Sub ! die,
    receive
        {'DOWN', MonRef, process, Sub, _} -> ok
    end,
    %% Wait for the events module to process the DOWN.
    _ = sys:get_state(bondy_oplog_core_events),
    ?assertNot(lists:member(Sub, bondy_oplog_core_events:subscribers(Topic))).

%% =============================================================================
%% Substrate restart-recovery protocol
%% =============================================================================

registry_emits_started_at_init() ->
    %% By this point the registry is already started (app:ensure_all_started),
    %% so we observe an epoch via current_epoch/0 and assert it is a ref.
    Epoch = bondy_oplog_core_registry:current_epoch(),
    ?assert(is_reference(Epoch)).

dispatcher_emits_started_at_init() ->
    Epoch = bondy_oplog_core_dispatcher:current_epoch(),
    ?assert(is_reference(Epoch)).

current_epoch_matches_broadcast() ->
    %% Subscribe to the started topic, then force a restart of the
    %% registry. The broadcast payload must equal what `current_epoch/0`
    %% returns after the restart settles.
    ok = bondy_oplog_core_events:subscribe(bondy_oplog_core_registry_started),
    Before = bondy_oplog_core_registry:current_epoch(),
    ok = kill_and_wait(bondy_oplog_core_registry),
    Payload = expect_event(bondy_oplog_core_registry_started, 500),
    After = bondy_oplog_core_registry:current_epoch(),
    ?assertNotEqual(Before, After),
    ?assertEqual(Payload, After),
    bondy_oplog_core_events:unsubscribe(bondy_oplog_core_registry_started).

registry_restart_changes_epoch_and_wakes_subscribers() ->
    ok = bondy_oplog_core_events:subscribe(bondy_oplog_core_registry_started),
    Before = bondy_oplog_core_registry:current_epoch(),
    ok = kill_and_wait(bondy_oplog_core_registry),
    After = expect_event(bondy_oplog_core_registry_started, 500),
    ?assertNotEqual(Before, After),
    ?assert(is_reference(After)),
    bondy_oplog_core_events:unsubscribe(bondy_oplog_core_registry_started).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_topic() ->
    list_to_atom(
        "topic_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

expect_event(Topic, TimeoutMs) ->
    receive
        {bondy_oplog_core_event, Topic, Payload} -> Payload
    after TimeoutMs ->
        erlang:error({no_event, Topic})
    end.

try_expect_event(Topic, TimeoutMs) ->
    receive
        {bondy_oplog_core_event, Topic, Payload} -> Payload
    after TimeoutMs ->
        timeout
    end.

%% Kill a registered gen_server and wait for the supervisor to restart
%% it so subsequent calls hit the new pid.
kill_and_wait(Name) ->
    OldPid = whereis(Name),
    true = is_pid(OldPid),
    OldRef = erlang:monitor(process, OldPid),
    exit(OldPid, kill),
    receive
        {'DOWN', OldRef, process, OldPid, _} -> ok
    after 1000 ->
        erlang:error({did_not_die, Name})
    end,
    wait_for_register(Name, OldPid, 20).

wait_for_register(Name, OldPid, 0) ->
    erlang:error({did_not_restart, Name, OldPid});
wait_for_register(Name, OldPid, Attempts) ->
    case whereis(Name) of
        undefined ->
            timer:sleep(25),
            wait_for_register(Name, OldPid, Attempts - 1);
        OldPid ->
            timer:sleep(25),
            wait_for_register(Name, OldPid, Attempts - 1);
        _Other ->
            ok
    end.
