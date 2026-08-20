%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_tls_SUITE).

-moduledoc """
M5 — **raw WAMP socket over TLS** integration tests against a live Bondy
`wamp_tls` listener (port 18085, enabled in `bondy_ct`).

- **Round trip**: a full register→call and a publish→event over TLS
  (`verify_none`) prove the encrypted transport carries WAMP end to end — same
  4-octet handshake and frames as TCP, over `ssl`.
- **Secure by default is real**: with `verify_peer` and the test CA bundle
  (`etc/ssl/server/cacert.pem`, regenerated via `just certs`) the handshake
  performs genuine certificate-chain validation and a full WAMP round trip
  succeeds over the verified link. Hostname checking is disabled
  (`server_name_indication => disable`) because the server certificate's SAN is
  `host.example.com`, not the dialed loopback IP.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.m5.tls">>).
-define(HOST, "127.0.0.1").
-define(PORT, 18085).

all() ->
    [
        tls_call_round_trip,
        tls_pubsub_round_trip,
        verify_peer_round_trip
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

%% A full register→call works over the TLS transport.
tls_call_round_trip(_) ->
    Conn = connect(#{verify => verify_none}),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    {ok, _} = bondy_connect_client:register(
        Conn, <<"com.example.res.tls">>, echo_handler()
    ),
    {ok, R} = bondy_connect_client:call(Conn, <<"com.example.res.tls">>, [
        <<"hi">>
    ]),
    ?assertEqual([<<"hi">>], maps:get(args, R)),
    ok = bondy_connect_client:disconnect(Conn).

%% A subscribe→publish→event round trip works over the TLS transport, proving the
%% EVENT path (not just request/response) survives the encrypted link.
tls_pubsub_round_trip(_) ->
    Topic = <<"com.example.res.tls.topic">>,
    Self = self(),
    Sub = connect(#{verify => verify_none}),
    {ok, _} = bondy_connect_client:subscribe(Sub, Topic, event_handler(Self)),

    Pub = connect(#{verify => verify_none}),
    ok = bondy_connect_client:publish(Pub, Topic, [<<"ping">>]),

    receive
        {event, [<<"ping">>]} -> ok
    after 5000 ->
        ct:fail(no_event)
    end,

    ok = bondy_connect_client:disconnect(Sub),
    ok = bondy_connect_client:disconnect(Pub).

%% Secure-by-default verification is real: with `verify_peer` and the test CA
%% bundle the TLS handshake validates the server's certificate chain and a full
%% register→call round trip succeeds over the verified link. (Hostname checking
%% is disabled because the server cert's SAN is `host.example.com`, not the
%% dialed loopback IP.)
verify_peer_round_trip(Config) ->
    CACertFile = ?config(cacertfile, Config),
    {ok, Conn} = bondy_connect_client:connect(#{
        transport => tls,
        endpoint => {?HOST, ?PORT},
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
        Conn, <<"com.example.res.tls.vp">>, echo_handler()
    ),
    {ok, R} = bondy_connect_client:call(Conn, <<"com.example.res.tls.vp">>, [
        <<"hi">>
    ]),
    ?assertEqual([<<"hi">>], maps:get(args, R)),
    ok = bondy_connect_client:disconnect(Conn).

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

%% @private Connect over TLS with the given `tls` options merged in.
connect(TLS) ->
    {ok, Conn} = bondy_connect_client:connect(#{
        transport => tls,
        endpoint => {?HOST, ?PORT},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json],
        tls => TLS
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
