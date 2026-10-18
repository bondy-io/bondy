%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_broker_auth_filter_SUITE).
-moduledoc """
The authid and authrole lists of WAMP Subscriber Black- and Whitelisting,
which the router announces as `subscriber_blackwhite_listing`.

`alice` (group `team_a`) and `bob` (group `team_b`) subscribe to one topic, and
`carol` publishes to it with one list at a time. Each case asserts both halves:
the subscriber the list admits receives the event, and the other does not.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-define(REALM, ~"com.example.test.broker_auth_filter").
-define(TOPIC, ~"com.example.test.broker_auth_filter.topic").
-define(PASSWORD, ~"secret-password-123").
-define(RECV_TIMEOUT, 5000).
%% How long a subscriber the list withholds the event from is watched for it,
%% after the admitted subscriber has already received it.
-define(SILENCE, 500).

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([exclude_authid/1]).
-export([eligible_authid/1]).
-export([exclude_authrole/1]).
-export([eligible_authrole/1]).
-export([retained_event_honours_the_lists/1]).

all() ->
    [
        exclude_authid,
        eligible_authid,
        exclude_authrole,
        eligible_authrole,
        retained_event_honours_the_lists
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),
    _ = bondy_realm:create(#{
        uri => ?REALM,
        authmethods => [?WAMP_CRA_AUTH],
        security_enabled => true,
        groups => [#{name => ~"team_a"}, #{name => ~"team_b"}],
        users => [
            user(~"alice", [~"team_a"]),
            user(~"bob", [~"team_b"]),
            user(~"carol", [])
        ],
        grants => [
            #{
                permissions => [~"wamp.subscribe", ~"wamp.publish"],
                uri => ~"",
                match => ~"prefix",
                roles => ~"all"
            }
        ],
        sources => [
            #{
                usernames => [~"alice", ~"bob", ~"carol"],
                authmethod => ?WAMP_CRA_AUTH,
                cidr => ~"0.0.0.0/0"
            }
        ]
    }),
    Config.

end_per_suite(Config) ->
    Config.

%% =============================================================================
%% CASES
%% =============================================================================

exclude_authid(Config) ->
    assert_only(bob, #{exclude_authid => [~"alice"]}, Config).

eligible_authid(Config) ->
    assert_only(alice, #{eligible_authid => [~"alice"]}, Config).

exclude_authrole(Config) ->
    assert_only(alice, #{exclude_authrole => [~"team_b"]}, Config).

eligible_authrole(Config) ->
    assert_only(bob, #{eligible_authrole => [~"team_b"]}, Config).

%% A retained event keeps the lists it was published with: a subscriber that
%% asks for retained events on subscribing gets it only if the lists admit it.
retained_event_honours_the_lists(_Config) ->
    Topic = ~"com.example.test.broker_auth_filter.retained",
    Carol = connect(~"carol"),
    Payload = [erlang:unique_integer([positive])],
    {ok, _} = bondy_connect_client:publish_ack(
        Carol, Topic, Payload, #{}, #{
            retain => true, exclude_authrole => [~"team_b"]
        }
    ),
    Self = self(),
    Alice = connect(~"alice"),
    Bob = connect(~"bob"),
    {ok, _} = bondy_connect_client:subscribe(
        Bob, Topic, handler(Self, bob), #{get_retained => true}
    ),
    {ok, _} = bondy_connect_client:subscribe(
        Alice, Topic, handler(Self, alice), #{get_retained => true}
    ),
    receive
        {event, alice, Payload} -> ok
    after ?RECV_TIMEOUT ->
        ct:fail(no_retained_event)
    end,
    receive
        {event, bob, Payload} -> ct:fail(retained_event_delivered_to_bob)
    after ?SILENCE ->
        ok
    end,
    _ = [bondy_connect_client:disconnect(C) || C <- [Alice, Bob, Carol]],
    ok.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% Publishes with `Opts` and asserts that `Who` receives the event and the
%% other subscriber does not.
assert_only(Who, Opts, _Config) ->
    Self = self(),
    Alice = connect(~"alice"),
    Bob = connect(~"bob"),
    Carol = connect(~"carol"),
    {ok, _} = bondy_connect_client:subscribe(
        Alice, ?TOPIC, handler(Self, alice)
    ),
    {ok, _} = bondy_connect_client:subscribe(Bob, ?TOPIC, handler(Self, bob)),
    Payload = [erlang:unique_integer([positive])],
    {ok, _} = bondy_connect_client:publish_ack(
        Carol, ?TOPIC, Payload, #{}, Opts
    ),
    receive
        {event, Who, Payload} -> ok
    after ?RECV_TIMEOUT ->
        ct:fail({no_event, Who, Opts})
    end,
    receive
        {event, Other, Payload} -> ct:fail({delivered_to, Other, Opts})
    after ?SILENCE ->
        ok
    end,
    _ = [bondy_connect_client:disconnect(C) || C <- [Alice, Bob, Carol]],
    ok.

user(Name, Groups) ->
    #{username => Name, password => ?PASSWORD, groups => Groups, meta => #{}}.

connect(Authid) ->
    {ok, Conn} = bondy_connect_client:connect(#{
        realm => ?REALM,
        transport => tcp,
        endpoint => {"127.0.0.1", 18082},
        serializers => [json],
        auth => #{
            method => ?WAMP_CRA_AUTH,
            authid => Authid,
            password => ?PASSWORD
        }
    }),
    Conn.

handler(Pid, Who) ->
    fun(Args, _, _) ->
        Pid ! {event, Who, Args},
        ok
    end.
