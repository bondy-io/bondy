%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_longpoll_SUITE).
-moduledoc """
Test suite for HTTP-Longpoll transport infrastructure.

Tests the longpoll transport at the Erlang API level: protocol initialisation,
poll_receive blocking/timeout, message delivery via queue and sync replies,
subprotocol validation, and encoding round-trips.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-compile([nowarn_export_all, export_all]).



all() ->
    [
        subprotocol_validation,
        encoding_roundtrip,
        open_and_init_protocol,
        poll_receive_empty_timeout,
        poll_receive_queue_messages,
        poll_receive_buffered_replies,
        poll_receive_wakeup_on_enqueue,
        poll_receive_sync_reply_wakeup,
        close_transport,
        send_unknown_transport
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.


end_per_suite(Config) ->
    {save_config, Config}.


init_per_testcase(_TestCase, Config) ->
    bondy_config:set([transport_queue, max_messages], 1000),
    bondy_config:set([transport_queue, max_bytes], 10485760),
    bondy_config:set([transport_queue, message_ttl], 300000),
    bondy_config:set([transport_queue, transport_ttl], 3600000),
    Config.


end_per_testcase(_TestCase, _Config) ->
    ok.



%% =============================================================================
%% TEST CASES
%% =============================================================================



subprotocol_validation(_Config) ->
    %% {http_longpoll, text, json} should be valid
    ?assertMatch(
        {ok, {http_longpoll, text, json}},
        bondy_wamp_protocol:validate_subprotocol({http_longpoll, text, json})
    ),

    %% Unsupported longpoll variants should fail
    ?assertMatch(
        {error, invalid_subprotocol},
        bondy_wamp_protocol:validate_subprotocol({http_longpoll, text, msgpack})
    ).


encoding_roundtrip(_Config) ->
    %% Verify that the http_longpoll subprotocol can encode and decode
    Msg = #event{
        subscription_id = 100,
        publication_id = 200,
        details = #{},
        args = [<<"hello">>],
        kwargs = undefined
    },

    %% Encode using the json encoding
    Bin = bondy_wamp_encoding:encode(Msg, json),
    ?assert(is_binary(Bin)),

    %% Decode using the http_longpoll subprotocol
    {[DecodedMsg], <<>>} = bondy_wamp_encoding:decode(
        {http_longpoll, text, json}, Bin
    ),
    ?assertEqual(Msg, DecodedMsg).


open_and_init_protocol(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<>>,
    SessionId = bondy_session_id:new(),

    %% Start transport session
    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),
    ?assert(is_pid(Pid)),

    %% Init protocol with longpoll subprotocol
    Subprotocol = {http_longpoll, text, json},
    Peer = {{127, 0, 0, 1}, 12345},
    ?assertEqual(
        ok,
        bondy_http_transport_session:init_protocol(Pid, Subprotocol, Peer)
    ),

    %% Verify encoding
    ?assertEqual(json, bondy_http_transport_session:encoding(Pid)),

    %% Cleanup
    ok = bondy_http_transport_session:close(Pid).


poll_receive_empty_timeout(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<>>,
    SessionId = bondy_session_id:new(),

    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),
    ok = bondy_http_transport_session:init_protocol(
        Pid, {http_longpoll, text, json}, {{127, 0, 0, 1}, 12345}
    ),

    %% Poll with very short timeout — should return empty on timeout
    T0 = erlang:system_time(millisecond),
    Result = bondy_http_transport_session:poll_receive(Pid, 200),
    T1 = erlang:system_time(millisecond),

    ?assertEqual({ok, {messages, []}}, Result),
    %% Should have waited approximately 200ms
    Elapsed = T1 - T0,
    ?assert(Elapsed >= 150),

    %% Cleanup
    ok = bondy_http_transport_session:close(Pid).


poll_receive_queue_messages(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<>>,
    SessionId = bondy_session_id:new(),

    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),
    ok = bondy_http_transport_session:init_protocol(
        Pid, {http_longpoll, text, json}, {{127, 0, 0, 1}, 12345}
    ),

    %% Enqueue messages before polling
    Msg1 = make_event(1),
    Msg2 = make_event(2),
    ok = bondy_transport_queue:enqueue(TransportId, Msg1, #{}),
    ok = bondy_transport_queue:enqueue(TransportId, Msg2, #{}),

    %% Poll should return immediately with messages
    Result = bondy_http_transport_session:poll_receive(Pid, 5000),
    ?assertMatch({ok, {messages, [_ | _]}}, Result),

    {ok, {messages, Msgs}} = Result,
    ?assert(length(Msgs) >= 1),
    %% First message should be Msg1 (FIFO ordering)
    ?assertEqual(Msg1, hd(Msgs)),

    %% Cleanup
    ok = bondy_http_transport_session:close(Pid).


poll_receive_buffered_replies(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<>>,
    SessionId = bondy_session_id:new(),

    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),
    ok = bondy_http_transport_session:init_protocol(
        Pid, {http_longpoll, text, json}, {{127, 0, 0, 1}, 12345}
    ),

    %% Send a HELLO to generate a buffered reply (WELCOME or ABORT)
    RealmTestUri = <<"com.leapsight.test.longpoll_buffering">>,
    _ = bondy_realm:create(RealmTestUri),
    ok = bondy_realm:disable_security(RealmTestUri),

    HelloBin = bondy_wamp_encoding:encode(
        #hello{
            realm_uri = RealmTestUri,
            details = #{
                <<"roles">> => #{
                    <<"caller">> => #{},
                    <<"subscriber">> => #{}
                }
            }
        },
        json
    ),

    %% Handle client message — reply gets buffered (no SSE or poll waiting)
    ok = bondy_http_transport_session:handle_client_message(Pid, HelloBin),

    %% Now poll_receive should return the buffered reply immediately
    Result = bondy_http_transport_session:poll_receive(Pid, 5000),
    ?assertMatch({ok, {replies, [_ | _]}}, Result),

    {ok, {replies, [ReplyBin | _]}} = Result,
    {[Decoded], <<>>} = bondy_wamp_encoding:decode(
        {http_longpoll, text, json}, ReplyBin
    ),
    ?assert(is_record(Decoded, welcome) orelse is_record(Decoded, abort)),

    %% Cleanup
    ok = bondy_http_transport_session:close(Pid).


poll_receive_wakeup_on_enqueue(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<>>,
    SessionId = bondy_session_id:new(),

    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),
    ok = bondy_http_transport_session:init_protocol(
        Pid, {http_longpoll, text, json}, {{127, 0, 0, 1}, 12345}
    ),

    %% Start a poll_receive in a separate process (it will block)
    Self = self(),
    Poller = spawn_link(fun() ->
        Result = bondy_http_transport_session:poll_receive(Pid, 10000),
        Self ! {poll_result, Result}
    end),

    %% Give the poller time to register its poll_from
    timer:sleep(100),

    %% Enqueue a message and notify — this should wake up the poller
    Msg = make_event(42),
    ok = bondy_transport_queue:enqueue(TransportId, Msg, #{}),
    bondy_http_transport_session:notify_enqueue(TransportId),

    %% The poller should get the result quickly
    receive
        {poll_result, Result} ->
            ?assertMatch({ok, {messages, [_ | _]}}, Result),
            {ok, {messages, [ReceivedMsg | _]}} = Result,
            ?assertEqual(Msg, ReceivedMsg)
    after 5000 ->
        exit(Poller, kill),
        ct:fail("Poller did not receive message after enqueue notification")
    end,

    %% Cleanup
    ok = bondy_http_transport_session:close(Pid).


poll_receive_sync_reply_wakeup(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<>>,
    SessionId = bondy_session_id:new(),

    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),
    ok = bondy_http_transport_session:init_protocol(
        Pid, {http_longpoll, text, json}, {{127, 0, 0, 1}, 12345}
    ),

    %% Create realm for HELLO
    RealmTestUri = <<"com.leapsight.test.longpoll_sync_wakeup">>,
    _ = bondy_realm:create(RealmTestUri),
    ok = bondy_realm:disable_security(RealmTestUri),

    %% Start a poll_receive in a separate process (it will block)
    Self = self(),
    _Poller = spawn_link(fun() ->
        Result = bondy_http_transport_session:poll_receive(Pid, 10000),
        Self ! {poll_result, Result}
    end),

    %% Give the poller time to register its poll_from
    timer:sleep(100),

    %% Send a HELLO — the sync reply should wake up the poller
    HelloBin = bondy_wamp_encoding:encode(
        #hello{
            realm_uri = RealmTestUri,
            details = #{
                <<"roles">> => #{
                    <<"caller">> => #{}
                }
            }
        },
        json
    ),
    ok = bondy_http_transport_session:handle_client_message(Pid, HelloBin),

    %% The poller should receive the sync reply
    receive
        {poll_result, Result} ->
            ?assertMatch({ok, {replies, [_ | _]}}, Result),
            {ok, {replies, [ReplyBin | _]}} = Result,
            {[Decoded], <<>>} = bondy_wamp_encoding:decode(
                {http_longpoll, text, json}, ReplyBin
            ),
            ?assert(
                is_record(Decoded, welcome) orelse is_record(Decoded, abort)
            )
    after 5000 ->
        ct:fail("Poller did not receive sync reply wakeup")
    end,

    %% Cleanup
    ok = bondy_http_transport_session:close(Pid).


close_transport(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<>>,
    SessionId = bondy_session_id:new(),

    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),

    ok = bondy_http_transport_session:close(TransportId),
    timer:sleep(100),

    ?assertNot(erlang:is_process_alive(Pid)),
    ?assertEqual(
        undefined,
        bondy_http_transport_session:whereis(TransportId)
    ).


send_unknown_transport(_Config) ->
    FakeTransportId = <<"nonexistent-longpoll-transport">>,

    ?assertEqual(
        undefined,
        bondy_http_transport_session:whereis(FakeTransportId)
    ),

    ?assertEqual(
        ok,
        bondy_http_transport_session:notify_enqueue(FakeTransportId)
    ).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
make_transport_id() ->
    Bin = integer_to_binary(erlang:unique_integer([positive])),
    <<"test-longpoll-transport-", Bin/binary>>.


%% @private
make_event(N) ->
    #event{
        subscription_id = 1,
        publication_id = N,
        details = #{},
        args = [<<"payload-", (integer_to_binary(N))/binary>>],
        kwargs = undefined
    }.
