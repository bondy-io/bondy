%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_ws_SUITE).

-moduledoc """
M5 — **WAMP over WebSocket** integration tests against the live Bondy
`api_gateway_http` cowboy `/ws` endpoint (port 18080, enabled in `bondy_ct`).

- **Round trip (json/text)**: register→call and publish→event over `ws://`, with
  the `wamp.2.json` subprotocol carried in WebSocket **text** frames.
- **Round trip (msgpack/binary)**: a call negotiating `wamp.2.msgpack`, proving
  subprotocol negotiation and the **binary**-frame path (not just json/text).
- **wss (TLS)**: a verify_peer round trip over `wss://` against the
  `api_gateway_https` `/ws` endpoint (port 18083), validating the server cert
  chain against the test CA bundle, then carrying a full WAMP call over the
  encrypted WebSocket.
- **Clean failure**: upgrading at a path with no WebSocket handler fails with
  `{error, _}`, never a hang.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.m5.ws">>).
-define(HOST, "127.0.0.1").
-define(PORT, 18080).
-define(PORT_WSS, 18083).

all() ->
    [
        ws_call_round_trip,
        ws_pubsub_round_trip,
        ws_msgpack_round_trip,
        wss_verify_peer_round_trip,
        ws_upgrade_bad_path_fails,
        ws_inbound_message_too_large_rejected
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),
    ok = add_anon_realm(?REALM),
    %% Resolve the CA bundle absolutely now (cwd is the project root at suite
    %% init) so it stays valid regardless of any later cwd change.
    CACertFile = filename:absname("./etc/ssl/server/cacert.pem"),
    true = filelib:is_regular(CACertFile),
    [{cacertfile, CACertFile} | Config].

end_per_suite(_) ->
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

%% A full register→call works over ws:// with the json (text-frame) subprotocol.
ws_call_round_trip(_) ->
    Conn = connect([json]),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    {ok, _} = bondy_connect_client:register(
        Conn, <<"com.example.res.ws">>, echo_handler()
    ),
    {ok, R} = bondy_connect_client:call(Conn, <<"com.example.res.ws">>, [
        <<"hi">>
    ]),
    ?assertEqual([<<"hi">>], maps:get(args, R)),
    ok = bondy_connect_client:disconnect(Conn).

%% A subscribe→publish→event round trip works over the WebSocket transport.
ws_pubsub_round_trip(_) ->
    Topic = <<"com.example.res.ws.topic">>,
    Self = self(),
    Sub = connect([json]),
    {ok, _} = bondy_connect_client:subscribe(Sub, Topic, event_handler(Self)),

    Pub = connect([json]),
    ok = bondy_connect_client:publish(Pub, Topic, [<<"ping">>]),

    receive
        {event, [<<"ping">>]} -> ok
    after 5000 ->
        ct:fail(no_event)
    end,

    ok = bondy_connect_client:disconnect(Sub),
    ok = bondy_connect_client:disconnect(Pub).

%% A call negotiating `wamp.2.msgpack` exercises subprotocol negotiation and the
%% binary-frame path.
ws_msgpack_round_trip(_) ->
    Conn = connect([msgpack]),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    {ok, _} = bondy_connect_client:register(
        Conn, <<"com.example.res.ws.mp">>, echo_handler()
    ),
    {ok, R} = bondy_connect_client:call(Conn, <<"com.example.res.ws.mp">>, [
        <<"hi">>
    ]),
    ?assertEqual([<<"hi">>], maps:get(args, R)),
    ok = bondy_connect_client:disconnect(Conn).

%% A verify_peer round trip over wss:// proves the gun-over-TLS path: the server
%% certificate chain is validated against the test CA bundle and a full call
%% succeeds over the encrypted WebSocket. (Hostname checking is disabled because
%% the server cert's SAN is `host.example.com`, not the dialed loopback IP.)
wss_verify_peer_round_trip(Config) ->
    CACertFile = ?config(cacertfile, Config),
    {ok, Conn} = bondy_connect_client:connect(#{
        transport => wss,
        endpoint => {?HOST, ?PORT_WSS},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json],
        tls => #{
            verify => verify_peer,
            cacertfile => CACertFile,
            server_name_indication => disable
        }
    }),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    {ok, _} = bondy_connect_client:register(
        Conn, <<"com.example.res.wss">>, echo_handler()
    ),
    {ok, R} = bondy_connect_client:call(Conn, <<"com.example.res.wss">>, [
        <<"hi">>
    ]),
    ?assertEqual([<<"hi">>], maps:get(args, R)),
    ok = bondy_connect_client:disconnect(Conn).

%% Upgrading at a path with no WebSocket handler fails cleanly (the server
%% answers the GET with a normal HTTP response instead of a 101 switch).
ws_upgrade_bad_path_fails(_) ->
    Result = bondy_connect_client:connect(#{
        transport => ws,
        endpoint => {?HOST, ?PORT},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json],
        ws_path => <<"/this-path-has-no-ws-handler">>
    }),
    ?assertMatch({error, _}, Result).

%% An inbound WebSocket message larger than the negotiated `max_message_length`
%% is rejected before it is decoded into terms, rather than materialized
%% (asymmetric DoS protection). Callee `A` runs with the default
%% limit and returns a large result; caller `B` dials with a small limit and
%% must see its call fail instead of decoding the oversized RESULT. The
%% handshake WELCOME still fits comfortably under B's limit (asserted via
%% `established`), so the failure is attributable to the RESULT, not the
%% handshake.
ws_inbound_message_too_large_rejected(_) ->
    Proc = <<"com.example.res.ws.big">>,
    Big = binary:copy(<<"x">>, 200000),

    A = connect([json]),
    {ok, _} = bondy_connect_client:register(
        A, Proc, fun(_, _, _) -> {ok, #{args => [Big]}} end
    ),

    {ok, B} = bondy_connect_client:connect(#{
        transport => ws,
        endpoint => {?HOST, ?PORT},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json],
        max_message_length => 32768
    }),
    ?assertEqual(established, bondy_connect_client:status(B)),

    %% The ~200 KB RESULT exceeds B's 32 KB inbound limit, so the call fails
    %% rather than returning the oversized payload.
    ?assertMatch({error, _}, bondy_connect_client:call(B, Proc, [<<>>])),

    ok = bondy_connect_client:disconnect(A),
    _ =
        try
            bondy_connect_client:disconnect(B)
        catch
            _:_ -> ok
        end.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
echo_handler() ->
    fun(Args, _, _) -> {ok, #{args => Args}} end.

%% @private An event handler that forwards each event's args to `Pid`.
event_handler(Pid) ->
    fun(Args, _, _) ->
        Pid ! {event, Args},
        ok
    end.

%% @private Connect over ws:// offering the given serializer preference.
connect(Serializers) ->
    {ok, Conn} = bondy_connect_client:connect(#{
        transport => ws,
        endpoint => {?HOST, ?PORT},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => Serializers
    }),
    Conn.

%% @private
add_anon_realm(RealmUri) ->
    Cfg = #{
        uri => RealmUri,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => true,
        grants => [
            #{
                permissions => [
                    <<"wamp.register">>,
                    <<"wamp.unregister">>,
                    <<"wamp.call">>,
                    <<"wamp.subscribe">>,
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
