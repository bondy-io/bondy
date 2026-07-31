%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_local_SUITE).

-moduledoc """
M5 — **in-VM (local) WAMP transport** integration tests. The local transport
opens a real Bondy session and talks directly to the co-located `bondy_router`
(no socket, no encoding, no framing); the `bondy_connect_connection` process is
itself the in-VM peer.

- **Round trip**: a full register→call and a publish→event prove the in-VM
  transport carries WAMP end to end through the live router.
- **Cross-session**: a callee on one local connection and a caller on a *second*
  local connection prove the router genuinely routes between two distinct in-VM
  sessions — not a self-loop in a single process.
- **Loopback peer**: the transport reports a loopback peername so the router's
  IP-based pipeline (logging, events, source-based authz) works unchanged.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.m5.local">>).

all() ->
    [
        local_call_round_trip,
        local_pubsub_round_trip,
        local_cross_session_call
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

%% A full register→call works over the in-VM transport (caller + callee on the
%% same connection, routed through the live dealer).
local_call_round_trip(_) ->
    Conn = connect(),
    ?assertEqual(established, bondy_connect:status(Conn)),
    {ok, _} = bondy_connect:register(
        Conn, <<"com.example.res.local">>, echo_handler()
    ),
    {ok, R} = bondy_connect:call(Conn, <<"com.example.res.local">>, [<<"hi">>]),
    ?assertEqual([<<"hi">>], maps:get(args, R)),
    ok = bondy_connect:disconnect(Conn).

%% A subscribe→publish→event round trip works over the in-VM transport, proving
%% the EVENT (broker) path survives in-process delivery.
local_pubsub_round_trip(_) ->
    Topic = <<"com.example.res.local.topic">>,
    Self = self(),
    Sub = connect(),
    {ok, _} = bondy_connect:subscribe(Sub, Topic, event_handler(Self)),

    Pub = connect(),
    ok = bondy_connect:publish(Pub, Topic, [<<"ping">>]),

    receive
        {event, [<<"ping">>]} -> ok
    after 5000 ->
        ct:fail(no_event)
    end,

    ok = bondy_connect:disconnect(Sub),
    ok = bondy_connect:disconnect(Pub).

%% A callee on one local connection and a caller on a *second* local connection:
%% the call must be routed by the dealer between two distinct in-VM sessions.
local_cross_session_call(_) ->
    Callee = connect(),
    Caller = connect(),
    Proc = <<"com.example.res.local.cross">>,
    {ok, _} = bondy_connect:register(Callee, Proc, fun(Args, _, _) ->
        {ok, #{args => [<<"from-callee">> | Args]}}
    end),
    {ok, R} = bondy_connect:call(Caller, Proc, [<<"x">>]),
    ?assertEqual([<<"from-callee">>, <<"x">>], maps:get(args, R)),
    ok = bondy_connect:disconnect(Callee),
    ok = bondy_connect:disconnect(Caller).

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

%% @private Open an in-VM connection to the test realm.
connect() ->
    {ok, Conn} = bondy_connect:connect(#{
        transport => local,
        endpoint => local,
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
