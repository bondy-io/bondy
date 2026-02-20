%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_sse_SUITE).
-moduledoc """
Test suite for SSE transport infrastructure.

Tests the SSE transport at the Erlang API level: protocol initialisation,
message handling, SSE stream registration, reply buffering/flushing,
queue notification forwarding, and subprotocol validation.
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
        register_sse_stream,
        reply_buffering,
        queue_notification_forwarding,
        sse_stream_down_cleanup,
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
    %% wamp.2.json.sse should be valid
    ?assertMatch(
        {ok, {http_sse, text, json}},
        bondy_wamp_protocol:validate_subprotocol(<<"wamp.2.json.sse">>)
    ),

    %% The tuple form should also validate
    ?assertMatch(
        {ok, {http_sse, text, json}},
        bondy_wamp_protocol:validate_subprotocol({http_sse, text, json})
    ),

    %% Unsupported variants should fail
    ?assertMatch(
        {error, invalid_subprotocol},
        bondy_wamp_protocol:validate_subprotocol(<<"wamp.2.msgpack.sse">>)
    ).


encoding_roundtrip(_Config) ->
    %% Verify that the http_sse subprotocol can encode and decode WAMP messages
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

    %% Decode using the http_sse subprotocol
    {[DecodedMsg], <<>>} = bondy_wamp_encoding:decode(
        {http_sse, text, json}, Bin
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

    %% Init protocol
    Subprotocol = {http_sse, text, json},
    Peer = {{127, 0, 0, 1}, 12345},
    ?assertEqual(
        ok,
        bondy_http_transport_session:init_protocol(Pid, Subprotocol, Peer)
    ),

    %% Verify encoding
    ?assertEqual(json, bondy_http_transport_session:encoding(Pid)),

    %% Cleanup
    ok = bondy_http_transport_session:close(Pid).


register_sse_stream(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<>>,
    SessionId = bondy_session_id:new(),

    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),

    %% Init protocol
    ok = bondy_http_transport_session:init_protocol(
        Pid, {http_sse, text, json}, {{127, 0, 0, 1}, 12345}
    ),

    %% Register self as SSE stream
    ok = bondy_http_transport_session:register_sse_stream(Pid, self()),

    %% Enqueue a message and verify drain_queue notification arrives
    Msg = make_event(1),
    ok = bondy_transport_queue:enqueue(TransportId, Msg, #{}),
    bondy_http_transport_session:notify_enqueue(TransportId),

    receive
        drain_queue ->
            ok
    after 2000 ->
        ct:fail("Expected drain_queue message")
    end,

    %% Cleanup
    ok = bondy_http_transport_session:close(Pid).


reply_buffering(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<>>,
    SessionId = bondy_session_id:new(),

    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),

    %% Init protocol
    ok = bondy_http_transport_session:init_protocol(
        Pid, {http_sse, text, json}, {{127, 0, 0, 1}, 12345}
    ),

    %% Send a HELLO before SSE stream is connected - the WELCOME/ABORT reply
    %% should be buffered. We encode a HELLO message for the test realm.
    HelloBin = bondy_wamp_encoding:encode(
        #hello{
            realm_uri = <<"com.leapsight.test.sse_buffering">>,
            details = #{
                <<"roles">> => #{
                    <<"caller">> => #{},
                    <<"subscriber">> => #{}
                }
            }
        },
        json
    ),

    %% Create the realm first
    RealmTestUri = <<"com.leapsight.test.sse_buffering">>,
    _ = bondy_realm:create(RealmTestUri),
    ok = bondy_realm:disable_security(RealmTestUri),

    %% Handle client message — this should produce a reply (WELCOME or ABORT)
    %% which gets buffered since no SSE stream is connected
    ok = bondy_http_transport_session:handle_client_message(Pid, HelloBin),

    %% Now register as SSE stream — buffered replies should be flushed
    ok = bondy_http_transport_session:register_sse_stream(Pid, self()),

    %% We should receive the buffered sync_reply
    receive
        {sync_reply, ReplyBin} when is_binary(ReplyBin) ->
            %% The reply should be a valid WAMP message (WELCOME or ABORT)
            {[Decoded], <<>>} = bondy_wamp_encoding:decode(
                {http_sse, text, json}, ReplyBin
            ),
            ?assert(
                is_record(Decoded, welcome) orelse is_record(Decoded, abort)
            )
    after 2000 ->
        ct:fail("Expected buffered sync_reply to be flushed")
    end,

    %% Cleanup
    ok = bondy_http_transport_session:close(Pid).


queue_notification_forwarding(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<>>,
    SessionId = bondy_session_id:new(),

    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),

    %% Without SSE stream, notify_enqueue should not send any message
    bondy_http_transport_session:notify_enqueue(TransportId),
    receive
        drain_queue ->
            ct:fail("Should not receive drain_queue without SSE stream")
    after 200 ->
        ok
    end,

    %% Register SSE stream
    ok = bondy_http_transport_session:register_sse_stream(Pid, self()),

    %% Now notify_enqueue should forward drain_queue to us
    bondy_http_transport_session:notify_enqueue(TransportId),
    receive
        drain_queue ->
            ok
    after 2000 ->
        ct:fail("Expected drain_queue after notify_enqueue")
    end,

    %% Cleanup
    ok = bondy_http_transport_session:close(Pid).


sse_stream_down_cleanup(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<>>,
    SessionId = bondy_session_id:new(),

    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),

    %% Spawn a fake SSE stream process and register it
    FakeSse = spawn_link(fun() ->
        receive stop -> ok end
    end),
    ok = bondy_http_transport_session:register_sse_stream(Pid, FakeSse),

    %% Kill the fake SSE stream
    FakeSse ! stop,
    timer:sleep(200),

    %% After SSE stream is down, notify_enqueue should not crash
    %% and should not forward drain_queue
    bondy_http_transport_session:notify_enqueue(TransportId),
    receive
        drain_queue ->
            ct:fail("Should not receive drain_queue after SSE stream died")
    after 200 ->
        ok
    end,

    %% Transport session itself should still be alive
    ?assert(erlang:is_process_alive(Pid)),

    %% Cleanup
    ok = bondy_http_transport_session:close(Pid).


close_transport(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<>>,
    SessionId = bondy_session_id:new(),

    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),

    %% Close by TransportId
    ok = bondy_http_transport_session:close(TransportId),
    timer:sleep(100),

    ?assertNot(erlang:is_process_alive(Pid)),
    ?assertEqual(
        undefined,
        bondy_http_transport_session:whereis(TransportId)
    ).


send_unknown_transport(_Config) ->
    FakeTransportId = <<"nonexistent-transport-id">>,

    %% whereis should return undefined
    ?assertEqual(
        undefined,
        bondy_http_transport_session:whereis(FakeTransportId)
    ),

    %% notify_enqueue should not crash
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
    <<"test-sse-transport-", Bin/binary>>.


%% @private
make_event(N) ->
    #event{
        subscription_id = 1,
        publication_id = N,
        details = #{},
        args = [<<"payload-", (integer_to_binary(N))/binary>>],
        kwargs = undefined
    }.
