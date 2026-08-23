%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_uds_SUITE).

-moduledoc """
What is specific to **raw WAMP over a Unix domain socket**, against the live
Bondy `wamp_uds` listener (enabled in `bondy_ct`, bound to the path its
inventory entry declares).

Carrying WAMP over this transport is not tested here: every WAMP use case runs
on `uds` in `bondy_connect_conformance_SUITE`.

What is left is the one thing a filesystem-path transport can get wrong and no
other can — **dialing a path that is not there** must fail cleanly (`enoent`),
never hang and never crash.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.m5.uds">>).

all() ->
    [
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
