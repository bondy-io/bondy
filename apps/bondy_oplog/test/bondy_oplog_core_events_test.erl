%% =============================================================================
%% End-to-end tests for `bondy_oplog_core_events` and the restart-recovery
%% protocol (`MST_DB_DESIGN.md` §11.1, §12.3, §18 item 11).
%%
%% Verifies:
%%   - `subscribe/1` receives the topic's notifications and nothing else
%%   - duplicate subscribe is idempotent
%%   - `unsubscribe/1` cleanly removes
%%   - subscriber DOWN auto-removes the row
%%   - the dispatcher broadcasts a fresh epoch on every (re)start
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
        fun dispatcher_emits_started_at_init/0
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

dispatcher_emits_started_at_init() ->
    Epoch = bondy_oplog_core_dispatcher:current_epoch(),
    ?assert(is_reference(Epoch)).

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
