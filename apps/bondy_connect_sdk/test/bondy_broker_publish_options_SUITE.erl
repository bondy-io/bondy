%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_broker_publish_options_SUITE).
-moduledoc """
PUBLISH options that decide who receives an event and what it says: Publisher
Exclusion (`exclude_me`), Subscriber Black- and Whitelisting by session id,
authid and authrole, Publisher Identification (`disclose_me`), and the same
lists applied to a retained event.

`alice` (group `team_a`), `bob` (group `team_b`) and `carol` (no group) each
open a session per case over TCP; `carol` publishes. Each case asserts both
halves: the subscribers the options admit receive the event, and the others
do not.

`acknowledge` is covered by `bondy_connect_pubsub_SUITE`. `rkey` is not
covered: the router announces `sharded_subscription => false`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-define(REALM, ~"com.example.test.broker_publish_options").
-define(PREFIX, ~"com.example.test.broker_publish_options").
-define(TOPIC, ~"com.example.test.broker_publish_options.topic").
-define(PASSWORD, ~"secret-password-123").
-define(RECV_TIMEOUT, 5000).
%% How long a subscriber the options withhold the event from is watched for
%% it, after every admitted subscriber has received it.
-define(SILENCE, 500).

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).
-export([exclude_me_by_default/1]).
-export([exclude_me_false/1]).
-export([exclude_session/1]).
-export([eligible_session/1]).
-export([exclude_me_prefix/1]).
-export([eligible_session_prefix/1]).
-export([empty_eligible_list_admits_no_one/1]).
-export([empty_eligible_list_admits_no_one_prefix/1]).
-export([eligible_list_emptied_by_exclusion_admits_no_one/1]).
-export([exclude_authid/1]).
-export([eligible_authid/1]).
-export([exclude_authrole/1]).
-export([eligible_authrole/1]).
-export([disclose_me_by_default/1]).
-export([disclose_me_false/1]).
-export([retained_event_honours_the_lists/1]).

all() ->
    [
        exclude_me_by_default,
        exclude_me_false,
        exclude_session,
        eligible_session,
        exclude_me_prefix,
        eligible_session_prefix,
        empty_eligible_list_admits_no_one,
        empty_eligible_list_admits_no_one_prefix,
        eligible_list_emptied_by_exclusion_admits_no_one,
        exclude_authid,
        eligible_authid,
        exclude_authrole,
        eligible_authrole,
        disclose_me_by_default,
        disclose_me_false,
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

%% The connections belong to the test case process: CT runs each case in its
%% own process, and a connection dies with the process that opened it.
init_per_testcase(_, Config) ->
    [{conns, #{N => connect(N) || N <- [alice, bob, carol]}} | Config].

end_per_testcase(_, Config) ->
    _ = [
        bondy_connect_client:disconnect(C)
     || _ := C <- ?config(conns, Config)
    ],
    ok.

%% =============================================================================
%% CASES
%% =============================================================================

%% A publisher subscribed to its own topic does not receive its own event.
exclude_me_by_default(Config) ->
    ok = subscribe([alice, carol], ?TOPIC, Config),
    assert_delivery([alice], #{}, Config).

exclude_me_false(Config) ->
    ok = subscribe([alice, carol], ?TOPIC, Config),
    assert_delivery([alice, carol], #{exclude_me => false}, Config).

exclude_session(Config) ->
    ok = subscribe([alice, bob], ?TOPIC, Config),
    Opts = #{exclude => [session_id(~"bob")]},
    assert_delivery([alice], Opts, Config).

eligible_session(Config) ->
    ok = subscribe([alice, bob], ?TOPIC, Config),
    Opts = #{eligible => [session_id(~"alice")]},
    assert_delivery([alice], Opts, Config).

%% A prefix subscription is matched through the registry's ptrie rather than
%% the exact-match index, so the session-id filters are checked there too.
exclude_me_prefix(Config) ->
    ok = subscribe([alice, carol], ?PREFIX, #{match => ~"prefix"}, Config),
    assert_delivery([alice], #{}, Config).

eligible_session_prefix(Config) ->
    ok = subscribe([alice, bob], ?PREFIX, #{match => ~"prefix"}, Config),
    Opts = #{eligible => [session_id(~"alice")]},
    assert_delivery([alice], Opts, Config).

%% An `eligible` list names the only sessions that may receive the event, so an
%% empty one names none; it is not read as an absent option.
empty_eligible_list_admits_no_one(Config) ->
    ok = subscribe([alice, bob], ?TOPIC, Config),
    assert_delivery([], #{eligible => []}, Config).

empty_eligible_list_admits_no_one_prefix(Config) ->
    ok = subscribe([alice, bob], ?PREFIX, #{match => ~"prefix"}, Config),
    assert_delivery([], #{eligible => []}, Config).

%% The publisher's own session leaves `eligible` through `exclude_me`.
eligible_list_emptied_by_exclusion_admits_no_one(Config) ->
    ok = subscribe([alice, bob, carol], ?TOPIC, Config),
    assert_delivery([], #{eligible => [session_id(~"carol")]}, Config),
    Opts = #{eligible => [session_id(~"bob")], exclude => [session_id(~"bob")]},
    assert_delivery([], Opts, Config).

exclude_authid(Config) ->
    ok = subscribe([alice, bob], ?TOPIC, Config),
    assert_delivery([bob], #{exclude_authid => [~"alice"]}, Config).

eligible_authid(Config) ->
    ok = subscribe([alice, bob], ?TOPIC, Config),
    assert_delivery([alice], #{eligible_authid => [~"alice"]}, Config).

exclude_authrole(Config) ->
    ok = subscribe([alice, bob], ?TOPIC, Config),
    assert_delivery([alice], #{exclude_authrole => [~"team_b"]}, Config).

eligible_authrole(Config) ->
    ok = subscribe([alice, bob], ?TOPIC, Config),
    assert_delivery([bob], #{eligible_authrole => [~"team_b"]}, Config).

%% The router discloses the publisher unless it asks not to be disclosed
%% (`bondy_broker:make_event_details/3`).
disclose_me_by_default(Config) ->
    ok = subscribe([alice], ?TOPIC, Config),
    [Details] = assert_delivery([alice], #{}, Config),
    ?assertEqual(session_id(~"carol"), detail(publisher, Details)),
    ?assertEqual(~"carol", detail(publisher_authid, Details)).

disclose_me_false(Config) ->
    ok = subscribe([alice], ?TOPIC, Config),
    [Details] = assert_delivery([alice], #{disclose_me => false}, Config),
    ?assertEqual(undefined, detail(publisher, Details)),
    ?assertEqual(undefined, detail(publisher_authid, Details)).

%% A retained event keeps the lists it was published with: a subscriber that
%% asks for retained events on subscribing gets it only if the lists admit it.
retained_event_honours_the_lists(Config) ->
    Topic = ~"com.example.test.broker_publish_options.retained",
    Payload = publish(
        #{retain => true, exclude_authrole => [~"team_b"]}, Topic, Config
    ),
    ok = subscribe([alice, bob], Topic, #{get_retained => true}, Config),
    assert_received([alice], Payload).

%% =============================================================================
%% HELPERS
%% =============================================================================

subscribe(Names, Topic, Config) ->
    subscribe(Names, Topic, #{}, Config).

subscribe(Names, Topic, Opts, Config) ->
    Self = self(),
    Conns = ?config(conns, Config),
    lists:foreach(
        fun(Name) ->
            Handler = fun(Args, _, Details) ->
                Self ! {event, Name, Args, Details},
                ok
            end,
            {ok, _} = bondy_connect_client:subscribe(
                maps:get(Name, Conns), Topic, Handler, Opts
            )
        end,
        Names
    ).

publish(Opts, Topic, Config) ->
    Payload = [erlang:unique_integer([positive])],
    {ok, _} = bondy_connect_client:publish_ack(
        maps:get(carol, ?config(conns, Config)), Topic, Payload, #{}, Opts
    ),
    Payload.

%% Publishes with `Opts` from `carol` and returns the details of the events
%% `Admitted` received, in order. Any other subscriber receiving it fails.
assert_delivery(Admitted, Opts, Config) ->
    assert_received(Admitted, publish(Opts, ?TOPIC, Config)).

assert_received(Admitted, Payload) ->
    Details = [
        receive
            {event, Name, Payload, D} -> D
        after ?RECV_TIMEOUT ->
            ct:fail({no_event, Name})
        end
     || Name <- Admitted
    ],
    receive
        {event, Other, Payload, _} ->
            ct:fail({delivered_to, Other})
    after ?SILENCE ->
        Details
    end.

%% EVENT details reach a handler with binary keys over a byte transport.
detail(Key, Details) ->
    maps:get(atom_to_binary(Key), Details, maps:get(Key, Details, undefined)).

session_id(Authid) ->
    [Session] = bondy_session:match(
        #{realm_uri => ?REALM, authid => Authid}, #{return => object}
    ),
    bondy_session:external_id(Session).

user(Name, Groups) ->
    #{username => Name, password => ?PASSWORD, groups => Groups, meta => #{}}.

connect(Name) ->
    {ok, Conn} = bondy_connect_client:connect(#{
        realm => ?REALM,
        transport => tcp,
        endpoint => {"127.0.0.1", 18082},
        serializers => [json],
        auth => #{
            method => ?WAMP_CRA_AUTH,
            authid => atom_to_binary(Name),
            password => ?PASSWORD
        }
    }),
    Conn.
