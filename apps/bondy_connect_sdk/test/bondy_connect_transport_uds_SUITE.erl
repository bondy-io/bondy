%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_uds_SUITE).

-moduledoc """
M5 — **raw WAMP socket over a Unix domain socket** integration tests against a
live Bondy `wamp_uds` listener (enabled in `bondy_ct`, bound to the path its
inventory entry declares).

- **Round trip**: a full register→call and a publish→event over the UDS prove the
  filesystem-path transport carries WAMP end to end — same 4-octet handshake and
  frames as TCP, over `gen_tcp` with the `{local, Path}` address family.
- **Clean failure**: dialing a non-existent socket path fails with `{error, _}`
  (e.g. `enoent`), never a hang or a crash.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.m5.uds">>).

all() ->
    [
        uds_call_round_trip,
        uds_pubsub_round_trip,
        connect_missing_path_fails
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),
    ok = add_anon_realm(?REALM),
    Config.

end_per_suite(_) ->
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

%% A full register→call works over the Unix domain socket transport.
uds_call_round_trip(_) ->
    Conn = connect(),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    {ok, _} = bondy_connect_client:register(
        Conn, <<"com.example.res.uds">>, echo_handler()
    ),
    {ok, R} = bondy_connect_client:call(Conn, <<"com.example.res.uds">>, [
        <<"hi">>
    ]),
    ?assertEqual([<<"hi">>], maps:get(args, R)),
    ok = bondy_connect_client:disconnect(Conn).

%% A subscribe→publish→event round trip works over the UDS transport, proving the
%% EVENT path (not just request/response) survives the local link.
uds_pubsub_round_trip(_) ->
    Topic = <<"com.example.res.uds.topic">>,
    Self = self(),
    Sub = connect(),
    {ok, _} = bondy_connect_client:subscribe(Sub, Topic, event_handler(Self)),

    Pub = connect(),
    ok = bondy_connect_client:publish(Pub, Topic, [<<"ping">>]),

    receive
        {event, [<<"ping">>]} -> ok
    after 5000 ->
        ct:fail(no_event)
    end,

    ok = bondy_connect_client:disconnect(Sub),
    ok = bondy_connect_client:disconnect(Pub).

%% Dialing a path with no listener fails cleanly rather than hanging or crashing.
connect_missing_path_fails(_) ->
    Result = bondy_connect_client:connect(#{
        transport => uds,
        endpoint => {local, "/tmp/bondy_connect_uds_does_not_exist.sock"},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    }),
    ?assertMatch({error, _}, Result).

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

%% @private Connect over the live Bondy `wamp_uds` listener's socket path. The
%% path is taken from the resolved listener rather than from configuration: the
%% inventory's bind target is what the listener actually bound.
connect() ->
    {ok, #{bind := {path, Path}}} =
        bondy_listener_manager:listener(wamp_uds),
    {ok, Conn} = bondy_connect_client:connect(#{
        transport => uds,
        endpoint => {local, Path},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
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
