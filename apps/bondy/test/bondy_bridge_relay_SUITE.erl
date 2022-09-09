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

-compile([export_all]).

all() ->
    [something].

-define(REALM_BRIDGE_RELAY, <<"ct.realm.bridge_relay">>).

-define(USERNAME_BRIDGE_RELAY, <<"ct_user_bridge_relay">>).

-define(CT_DEFAULT_PRIVKEY,
    <<"4ffddd896a530ce5ee8c86b83b0d31835490a97a9cd718cb2f09c9fd31c4a7d71766c9e6ec7d7b354fd7a2e4542753a23cae0b901228305621e5b8713299ccdd">>
).
-define(CT_DEFAULT_PUBKEY,
    <<"1766c9e6ec7d7b354fd7a2e4542753a23cae0b901228305621e5b8713299ccdd">>
).

-define(CONFIG_BRIDGE_DEFAULT, #{
    name => <<"relay1">>,
    enabled => true,
    endpoint => {{127, 0, 0, 1}, 18093},
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
    ct:pal("ct config: ~p~n", [Config]),
    bondy_ct:start_bondy(),
    NodeBridge = bondy_ct:start_bondy(bridge),
    {ok, _Bridge} =
        rpc:call(
            NodeBridge,
            bondy_bridge_relay_manager,
            add_bridge,
            [?CONFIG_BRIDGE_DEFAULT, ?OPT_AUTOSTART],
            5000
        ),
    [{slaves, [NodeBridge]} | Config].

end_per_suite(Config) ->
    Slaves = ?config(slaves, Config),
    lists:foreach(fun(Slave) -> ct_slave:stop(Slave) end, Slaves),
    {save_config, Config}.

something(_Config) ->
    ok.
