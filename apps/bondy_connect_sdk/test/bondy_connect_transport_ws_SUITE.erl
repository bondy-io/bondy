%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_ws_SUITE).

-moduledoc """
What is specific to **WAMP over WebSocket**, against the live Bondy
`api_gateway_http` cowboy `/ws` endpoint (port 18080, enabled in `bondy_ct`).

Carrying WAMP over this transport is not tested here: every WAMP use case runs
on `ws` and `wss` in `bondy_connect_conformance_SUITE`, which also covers the
json/text and msgpack/binary frame paths through its serializer cases.

What is left belongs to the **upgrade** and to **framing**, neither of which
exists on any other transport: an upgrade at a path with no WebSocket handler
must fail cleanly rather than hang, and an inbound message over the negotiated
limit must be rejected.
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
