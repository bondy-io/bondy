%% =============================================================================
%%  bondy_bridge_relay_SUITE.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

-module(bondy_bridge_relay_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("wamp/include/wamp.hrl").

-include("bondy_security.hrl").

-compile([export_all]).

all() ->
    [pubsub_basic].

-define(BRIDGE_NAME, <<"bridge_relay_1">>).
-define(REALM_BRIDGE_RELAY, <<"ct.realm.bridge_relay">>).
-define(USERNAME_BRIDGE_RELAY, <<"ct_user_bridge_relay">>).

-define(CT_DEFAULT_PRIVKEY,
    <<"4ffddd896a530ce5ee8c86b83b0d31835490a97a9cd718cb2f09c9fd31c4a7d71766c9e6ec7d7b354fd7a2e4542753a23cae0b901228305621e5b8713299ccdd">>
).
-define(CT_DEFAULT_PUBKEY,
    <<"1766c9e6ec7d7b354fd7a2e4542753a23cae0b901228305621e5b8713299ccdd">>
).

-define(CONFIG_BRIDGE_DEFAULT, #{
    name => ?BRIDGE_NAME,
    enabled => true,
    endpoint => {{127, 0, 0, 1}, 18092},
    restart => permanent,
    idle_timeout => 5000,
    network_timeout => 5000,
    connect_timeout => 5000,
    transport => tls,
    tls_opts => #{},
    max_frame_size => infinity,
    reconnect =>
        #{
            enabled => true,
            backoff_max => 5000,
            backoff_min => 1000,
            backoff_type => jitter,
            max_retries => 2
        },
    ping =>
        #{
            enabled => true,
            idle_timeout => 1000,
            timeout => 1000,
            max_retries => 2
        },
    realms =>
        [
            #{
                uri => ?REALM_BRIDGE_RELAY,
                authid => ?USERNAME_BRIDGE_RELAY,
                cryptosign =>
                    % privkey_env_var => <<"CT_DEFAULT_PRIVKEY">>,
                    #{
                        privkey => ?CT_DEFAULT_PRIVKEY,
                        pubkey => ?CT_DEFAULT_PUBKEY
                    },
                procedures => [],
                topics =>
                    [
                        #{
                            uri => <<"ct.topic.in.">>,
                            match => <<"prefix">>,
                            direction => in
                        },
                        #{
                            uri => <<"ct.topic.out.">>,
                            match => <<"prefix">>,
                            direction => out
                        }
                    ]
            }
        ]
}).

-define(OPT_AUTOSTART, #{autostart => true}).

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Realm = add_realm(?REALM_BRIDGE_RELAY),
    ?assertEqual(?REALM_BRIDGE_RELAY, bondy_realm:uri(Realm)),

    NodeBridge = bondy_ct:start_bondy(bridge, 1000),
    ct:pal("Running nodes: ~p", [nodes()]),
    {ok, Bridge} =
        rpc:call(
            NodeBridge,
            bondy_bridge_relay_manager,
            add_bridge,
            [?CONFIG_BRIDGE_DEFAULT, ?OPT_AUTOSTART],
            5000
        ),
    ct:pal("Bridge~n~p", [Bridge]),
    % sanity checks
    {ok, Bridge} = rpc:call(NodeBridge, bondy_bridge_relay_manager, get_bridge, [?BRIDGE_NAME]),
    StatusBridge = rpc:call(NodeBridge, bondy_bridge_relay_manager, status, []),
    ?assertEqual(#{status => running}, maps:get(?BRIDGE_NAME, StatusBridge)),

    [{slaves, [NodeBridge]} | Config].

end_per_suite(Config) ->
    Slaves = ?config(slaves, Config),
    lists:foreach(fun(Slave) -> ct_slave:stop(Slave) end, Slaves),
    {save_config, Config}.

pubsub_basic(Config) ->
    {slaves, Slaves} = lists:keyfind(slaves, 1, Config),
    NodeBridge = lists:nth(1, Slaves),
    ?assert(lists:member(NodeBridge, nodes())),

    AppsMaster = lists:sort([element(1, E) || E <- application:which_applications()]),
    AppsSlave = lists:sort([
        element(1, E)
     || E <- rpc:call(NodeBridge, application, which_applications, [])
    ]),
    ?assertEqual(AppsMaster, AppsSlave),

    RealmUri = ?REALM_BRIDGE_RELAY,
    ?assert(bondy_realm:exists(RealmUri)),
    ?assert(not rpc:call(NodeBridge, bondy_realm, exists, [RealmUri], 1000)),
    Realm = bondy_realm:lookup(RealmUri),

    % raises a badarg on ets.lookup_element for [ranch_server,{listener_sup,bridge_relay_tls},2]
    ?assertException(error, badarg, bondy_bridge_relay_manager:connections()),
    ConnectionsSlave = rpc:call(NodeBridge, bondy_bridge_relay_manager, connections, [], 1000),
    {badrpc, {'EXIT', {badarg, BadargErrorDetails}}} = ConnectionsSlave,
    ct:pal("bondy_bridge_relay_manager:connections error:~n~p", [BadargErrorDetails]),
    ConnectionsTcpMaster = bondy_bridge_relay_manager:tcp_connections(),
    ConnectionsTcpSlave = rpc:call(
        NodeBridge, bondy_bridge_relay_manager, tcp_connections, [], 1000
    ),
    ct:pal("TCP connections~nMaster: ~p~nSlave: ~p", [ConnectionsTcpMaster, ConnectionsTcpSlave]),

    Me = self(),

    TopicFoo = <<"ct.topic.in.foo">>,
    {ok, _IdSubFoo, _PidFoo} = rpc:call(
        NodeBridge,
        bondy_broker,
        subscribe,
        [?REALM_BRIDGE_RELAY, #{}, TopicFoo, fun(T, E) -> Me ! {T, E} end],
        3000
    ),

    TopicBar = <<"ct.topic.in.bar">>,
    {ok, _IdSubBar, _PidBar} = rpc:call(
        NodeBridge,
        bondy_broker,
        subscribe,
        [?REALM_BRIDGE_RELAY, #{}, TopicBar, fun(T, E) -> Me ! {T, E} end],
        3000
    ),

    ok = bondy_realm:disable_security(Realm),
    Peer = {{127, 0, 0, 1}, 18082},
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => ?USERNAME_BRIDGE_RELAY,
        authmethod => ?WAMP_CRYPTOSIGN_AUTH,
        authroles => [],
        roles => #{caller => #{}}
    }),
    Ctxt0 = bondy_context:new(Peer, {ws, text, json}),
    Ctxt = bondy_context:set_session(Ctxt0, Session),

    Message = "Hello!",
    {ok, _IdPubFoo} = bondy_broker:publish(#{}, TopicFoo, [Message], #{}, Ctxt),
    {ok, _IdPubBar} = bondy_broker:publish(#{}, TopicBar, [Message], #{}, Ctxt),

    receive
        {Topic, Event} ->
            ct:pal("Got '~s' on ~p", [Event, Topic]),
            ?assertEqual(TopicFoo, Topic),
            ?assertEqual(Message, Event)
    after 2000 ->
        error("No message received on time")
    end.

add_realm(RealmUri) ->
    add_realm(node(), RealmUri).

add_realm(Where, RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"Test realm for bridge relay">>,
        authmethods => [?WAMP_ANON_AUTH, ?WAMP_CRYPTOSIGN_AUTH],
        security_enabled => true,
        grants => [
            #{
                permissions => [
                    <<"wamp.register">>,
                    <<"wamp.unregister">>,
                    <<"wamp.subscribe">>,
                    <<"wamp.unsubscribe">>,
                    <<"wamp.call">>,
                    <<"wamp.cancel">>,
                    <<"wamp.publish">>
                ],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => <<"all">>
            }
        ],
        users => [
            #{
                username => ?USERNAME_BRIDGE_RELAY,
                authorized_keys => [?CT_DEFAULT_PUBKEY],
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            #{
                usernames => [<<"anonymous">>],
                authmethod => ?WAMP_ANON_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [?USERNAME_BRIDGE_RELAY],
                authmethod => ?WAMP_CRYPTOSIGN_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },
    NodeMaster = node(),
    case Where of
        NodeMaster ->
            bondy_realm:create(Config);
        NodeName ->
            rpc:call(NodeName, bondy_realm, create, [Config], 1000)
    end.
