%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_bridge_relay_handshake_SUITE).
-moduledoc """
A malformed bridge relay handshake is refused with a `protocol_violation`
ABORT before the server closes the connection. Each case speaks the relay
framing (a 4-byte length and `term_to_binary/1`) to a listener started on an
ephemeral port.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(LISTENER, bondy_bridge_relay_handshake_SUITE).
-define(REALM, ~"com.example.test.bridge_relay_handshake").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([hello_without_authid/1]).
-export([hello_with_a_non_binary_authid/1]).
-export([hello_with_non_map_details/1]).
-export([authenticate_before_hello/1]).

all() ->
    [
        hello_without_authid,
        hello_with_a_non_binary_authid,
        hello_with_non_map_details,
        authenticate_before_hello
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    _ = bondy_realm:create(#{
        uri => ?REALM,
        description => ~"bridge relay handshake test realm",
        security_enabled => true
    }),
    {ok, _} = ranch:start_listener(
        ?LISTENER,
        ranch_tcp,
        #{socket_opts => [{port, 0}]},
        bondy_bridge_relay_server,
        [{auth_timeout, 5000}]
    ),
    Config.

end_per_suite(Config) ->
    ok = ranch:stop_listener(?LISTENER),
    Config.

%% =============================================================================
%% CASES
%% =============================================================================

hello_without_authid(_) ->
    assert_protocol_violation({hello, ?REALM, #{}}).

hello_with_a_non_binary_authid(_) ->
    assert_protocol_violation({hello, ?REALM, #{authid => 42}}).

hello_with_non_map_details(_) ->
    assert_protocol_violation({hello, ?REALM, [{authid, ~"alice"}]}).

authenticate_before_hello(_) ->
    assert_protocol_violation({authenticate, ~"signature", #{}}).

%% =============================================================================
%% HELPERS
%% =============================================================================

assert_protocol_violation(Message) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1},
        ranch:get_port(?LISTENER),
        [binary, {packet, 4}, {active, false}],
        5000
    ),
    ok = gen_tcp:send(Sock, term_to_binary(Message)),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 5000),
    ?assertMatch(
        {abort, _, protocol_violation, #{}}, binary_to_term(Reply)
    ),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)).
