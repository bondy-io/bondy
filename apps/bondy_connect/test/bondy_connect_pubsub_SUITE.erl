%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_pubsub_SUITE).

-moduledoc """
M2 integration tests for the **publisher** and **subscriber** roles against a
live Bondy router over raw TCP. Covers event delivery, acknowledged publish,
**per-subscription FIFO** ordering (the default) vs the opt-in unordered mode,
and unsubscription.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.m2.pubsub">>).
-define(HOST, "127.0.0.1").
-define(PORT, 18082).

all() ->
    [
        subscribe_and_receive,
        acknowledged_publish,
        ordered_events,
        unordered_events,
        subscriber_crash_preserves_fifo,
        unsubscribe_stops_events
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect),
    ok = add_anon_realm(?REALM),
    Config.

end_per_suite(_) ->
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

subscribe_and_receive(_) ->
    Self = self(),
    Sub = connect(),
    Handler = fun(Args, _KWArgs, _Details) -> Self ! {event, Args} end,
    {ok, SubId} = bondy_connect:subscribe(Sub, <<"com.example.t1">>, Handler),
    ?assert(is_integer(SubId)),

    Pub = connect(),
    ok = bondy_connect:publish(Pub, <<"com.example.t1">>, [<<"hi">>]),
    receive
        {event, Args} -> ?assertEqual([<<"hi">>], Args)
    after 5000 ->
        ct:fail(no_event)
    end,

    ok = bondy_connect:disconnect(Pub),
    ok = bondy_connect:disconnect(Sub).

acknowledged_publish(_) ->
    Pub = connect(),
    Result = bondy_connect:publish(
        Pub, <<"com.example.ack">>, [<<"x">>], #{}, #{acknowledge => true}
    ),
    ?assertMatch({ok, PubId} when is_integer(PubId), Result),
    ok = bondy_connect:disconnect(Pub).

ordered_events(_) ->
    Self = self(),
    Sub = connect(),
    %% Decreasing sleeps: if the dispatch were concurrent, later (faster) events
    %% would overtake earlier (slower) ones. Per-subscription FIFO must preserve
    %% publication order regardless.
    Handler = fun([Seq], _, _) ->
        timer:sleep(200 - Seq * 20),
        Self ! {seq, Seq}
    end,
    {ok, _} = bondy_connect:subscribe(Sub, <<"com.example.ordered">>, Handler),

    Pub = connect(),
    _ = [
        {ok, _} = bondy_connect:publish(
            Pub, <<"com.example.ordered">>, [N], #{}, #{acknowledge => true}
        )
     || N <- lists:seq(1, 5)
    ],

    Seqs = [
        receive
            {seq, S} -> S
        after 5000 -> ct:fail(timeout)
        end
     || _ <- lists:seq(1, 5)
    ],
    ?assertEqual([1, 2, 3, 4, 5], Seqs),

    ok = bondy_connect:disconnect(Pub),
    ok = bondy_connect:disconnect(Sub).

unordered_events(_) ->
    Self = self(),
    Sub = connect(),
    Handler = fun(Args, _, _) -> Self ! {uevent, Args} end,
    {ok, _} = bondy_connect:subscribe(
        Sub, <<"com.example.unordered">>, Handler, #{ordered => false}
    ),

    Pub = connect(),
    {ok, _} = bondy_connect:publish(
        Pub, <<"com.example.unordered">>, [<<"u">>], #{}, #{acknowledge => true}
    ),
    receive
        {uevent, Args} -> ?assertEqual([<<"u">>], Args)
    after 5000 ->
        ct:fail(no_event)
    end,

    ok = bondy_connect:disconnect(Pub),
    ok = bondy_connect:disconnect(Sub).

%% A crashing ordered-subscription handler must not wedge the per-subscription
%% FIFO: the worker DOWN drives `advance_event_down`, which drains the queued
%% events in publication order. The handler for event 1 sleeps (so events 2..5
%% queue behind it) then crashes; events 2..5 must still arrive, in order.
subscriber_crash_preserves_fifo(_) ->
    Self = self(),
    Sub = connect(),
    Handler = fun([Seq], _, _) ->
        case Seq of
            1 ->
                timer:sleep(500),
                error(boom);
            _ ->
                Self ! {seq, Seq}
        end
    end,
    {ok, _} = bondy_connect:subscribe(
        Sub, <<"com.example.crashfifo">>, Handler
    ),

    Pub = connect(),
    _ = [
        {ok, _} = bondy_connect:publish(
            Pub, <<"com.example.crashfifo">>, [N], #{}, #{acknowledge => true}
        )
     || N <- lists:seq(1, 5)
    ],

    Seqs = [
        receive
            {seq, S} -> S
        after 5000 -> ct:fail(timeout)
        end
     || _ <- lists:seq(1, 4)
    ],
    ?assertEqual([2, 3, 4, 5], Seqs),

    %% The crash neither wedged the subscription nor dropped the link.
    ?assertEqual(established, bondy_connect:status(Sub)),

    ok = bondy_connect:disconnect(Pub),
    ok = bondy_connect:disconnect(Sub).

unsubscribe_stops_events(_) ->
    Self = self(),
    Sub = connect(),
    Handler = fun(Args, _, _) -> Self ! {got, Args} end,
    {ok, SubId} = bondy_connect:subscribe(
        Sub, <<"com.example.unsub">>, Handler
    ),
    %% A control subscription on the SAME connection that stays subscribed. Its
    %% event is the deterministic barrier: both publishes are acknowledged and
    %% sequential, so a (hypothetical) leaked event for the unsubscribed topic is
    %% framed onto this subscriber's socket *before* the control event and is
    %% read+dispatched by the connection before the control event is. Replaces a
    %% blind 1 s window with a positive signal that propagation has completed.
    Ctrl = fun(Args, _, _) -> Self ! {ctrl, Args} end,
    {ok, _} = bondy_connect:subscribe(Sub, <<"com.example.unsub.ctrl">>, Ctrl),
    ok = bondy_connect:unsubscribe(Sub, SubId),

    Pub = connect(),
    {ok, _} = bondy_connect:publish(
        Pub, <<"com.example.unsub">>, [<<"x">>], #{}, #{acknowledge => true}
    ),
    {ok, _} = bondy_connect:publish(
        Pub, <<"com.example.unsub.ctrl">>, [<<"ok">>], #{}, #{
            acknowledge => true
        }
    ),
    receive
        {ctrl, _} -> ok
    after 5000 ->
        ct:fail(control_event_not_received)
    end,
    %% Barrier passed. A short bounded drain covers only the residual scheduling
    %% gap between the two concurrent per-subscription dispatch workers (the got
    %% worker, if any, was spawned before the ctrl worker that just fired).
    receive
        {got, _} -> ct:fail(received_after_unsubscribe)
    after 200 ->
        ok
    end,

    ok = bondy_connect:disconnect(Pub),
    ok = bondy_connect:disconnect(Sub).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
connect() ->
    {ok, Conn} = bondy_connect:connect(spec()),
    Conn.

%% @private
spec() ->
    #{
        transport => tcp,
        endpoint => {?HOST, ?PORT},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    }.

%% @private
add_anon_realm(RealmUri) ->
    Cfg = #{
        uri => RealmUri,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => true,
        grants => [
            #{
                permissions => [
                    <<"wamp.subscribe">>,
                    <<"wamp.unsubscribe">>,
                    <<"wamp.publish">>
                ],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => [<<"anonymous">>]
            }
        ],
        sources => [
            #{
                usernames => [<<"anonymous">>],
                authmethod => ?WAMP_ANON_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },
    _ = bondy_realm:create(Cfg),
    ok.
