%% =============================================================================
%%  common.erl -
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

-module(bondy_ct).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(KERNEL_ENV, [
    {logger_level, info},
    {logger, [
        {handler, default, logger_std_h, #{
            config =>
                #{
                    burst_limit_enable => true,
                    burst_limit_max_count => 500,
                    burst_limit_window_time => 1000,
                    drop_mode_qlen => 200,
                    filesync_repeat_interval => no_repeat,
                    flush_qlen => 1000,
                    overload_kill_enable => false,
                    overload_kill_mem_size => 3000000,
                    overload_kill_qlen => 20000,
                    overload_kill_restart_after => 5000,
                    sync_mode_qlen => 10,
                    type => standard_io
                },
            filter_default => stop,
            filters =>
                [
                    {remote_gl, {fun logger_filters:remote_gl/2, stop}},
                    {no_domain, {fun logger_filters:domain/2, {log, undefined, []}}},
                    {domain, {fun logger_filters:domain/2, {stop, equal, [sasl]}}},
                    {domain, {fun logger_filters:domain/2, {log, super, [otp, bondy_audit]}}}
                ],
            formatter =>
                {bondy_logger_formatter, #{
                    colored => true,
                    colored_alert => "\e[1;45m",
                    colored_critical => "\e[1;35m",
                    colored_debug => "\e[0;38m",
                    colored_emergency => "\e[1;41;1m",
                    colored_error => "\e[1;31m",
                    colored_info => "\e[1;37m",
                    colored_notice => "\e[1;36m",
                    colored_warning => "\e[1;33m",
                    map_depth => 3,
                    template =>
                        [
                            colored_start,
                            "when=",
                            time,
                            " level=",
                            level,
                            {pid, [" pid=", pid], []},
                            " at=",
                            mfa,
                            ":",
                            line,
                            {{msg, description}, [" description=", description], []},
                            colored_end,
                            {{msg, reason}, [" reason=", reason], []},
                            {id, [" id=", id], []},
                            {parent_id, [" parent_id=", parent_id], []},
                            {correlation_id, [" correlation_id=", correlation_id], []},
                            {node, [" node=", node], []},
                            {router_vsn, [" router_vsn=", router_vsn], []},
                            {realm, [" realm=", realm], []},
                            {session_id, [" session_id=", session_id], []},
                            {protocol, [" protocol=", protocol], []},
                            {transport, [" transport=", transport], []},
                            {peername, [" peername=", peername], []},
                            " ",
                            msg,
                            "\n"
                        ],
                    term_depth => 50,
                    time_designator => "T",
                    time_offset => 0
                }},
            level => debug
        }}
    ]}
]).

%% ENV IN DESIRED LOAD ORDER
-define(ENV, [
    {eleveldb, [
        {whole_file_expiry, true},
        {expiry_minutes, unlimited},
        {expiry_enabled, false},
        {cache_object_warming, true},
        {fadvise_willneed, false},
        {eleveldb_threads, 71},
        {verify_compaction, true},
        {verify_checksums, true},
        {block_size_steps, 16},
        {block_restart_interval, 16},
        {sst_block_size, 4096},
        {block_cache_threshold, 33554432},
        {use_bloomfilter, true},
        {write_buffer_size_max, 62914560},
        {write_buffer_size_min, 31457280},
        {limited_developer_mem, false},
        {sync, false},
        {total_leveldb_mem_percent, 70},
        {data_root, "./data/leveldb"},
        {compression, snappy},
        {delete_threshold, 1000},
        {tiered_slow_level, 0}
    ]},
    {partisan, [
        {connect_disterl, true},
        {exchange_tick_period, 60000},
        {tls_options, [
            {cacertfile, "./etc/cacert.pem"},
            {keyfile, "./etc/key.pem"},
            {certfile, "./etc/cert.pem"},
            {versions, ['tlsv1.3']}
        ]},
        {tls, false},
        {partisan_peer_service_manager, partisan_pluggable_peer_service_manager},
        {lazy_tick_period, 1000},
        {parallelism, 1},
        {peer_port, 18086}
    ]},
    {plum_db, [
        {aae_exchange_on_cluster_join, true},
        {hashtree_ttl, 604800},
        {hashtree_timer, 10000},
        {aae_enabled, true},
        {data_exchange_timeout, 60000},
        {data_dir, "./data"},
        {store_open_retries_delay, 2000},
        {store_open_retry_limit, 30},
        {shard_by, prefix},
        {partitions, 16},
        {wait_for_aae_exchange, false},
        {wait_for_hashtrees, true},
        {wait_for_partitions, true}
    ]},
    {wamp, [
        {uri_strictness, loose}
    ]},
    {bondy, [
        {session_manager_pool, [{size, 50}]},
        {router_pool, [{capacity, 10000}, {size, 8}, {type, transient}]},
        {load_regulation_enabled, true},
        {jobs_pool, [{size, 16}]},
        {registry, [
            {partition_spawn_opts, [
                {message_queue_data, on_heap}
            ]},
            {partitions, 32}
        ]},
        {oauth2, [
            {refresh_token_length, 40},
            {refresh_token_duration, 2592000},
            {code_grant_duration, 600},
            {client_credentials_grant_duration, 900},
            {password_grant_duration, 900},
            {config_file, "./etc/oauth2_config.json"}
        ]},
        {bridge_relay_tls, [
            {socket_opts, [
                {cacertfile, "./etc/cacert.pem"},
                {keyfile, "./etc/key.pem"},
                {certfile, "./etc/cert.pem"},
                {nodelay, true},
                {keepalive, true},
                {versions, ['tlsv1.3']}
            ]},
            {max_frame_size, infinity},
            {idle_timeout, 28800000},
            {ping, [{max_retries, 3}, {interval, 30000}, {enabled, true}]},
            {backlog, 1024},
            {max_connections, 100000},
            {acceptors_pool_size, 200},
            {port, 18093},
            {enabled, false}
        ]},
        {bridge_relay_tcp, [
            {max_frame_size, infinity},
            {idle_timeout, 28800000},
            {ping, [{max_retries, 3}, {interval, 30000}, {enabled, true}]},
            {socket_opts, [{nodelay, true}, {keepalive, true}]},
            {backlog, 1024},
            {max_connections, 100000},
            {acceptors_pool_size, 200},
            {port, 18092},
            {enabled, true}
        ]},
        {platform_log_dir, "./log"},
        {platform_etc_dir, "./etc"},
        {platform_tmp_dir, "./tmp"},
        {platform_data_dir, "./data"},
        {platform_lib_dir, "./lib"},
        {platform_bin_dir, "./bin"},
        {peer_discovery, [
            {type, bondy_peer_discovery_dns_agent},
            {join_retry_interval, 5000},
            {timeout, 5000},
            {polling_interval, 10000},
            {automatic_join, true},
            {initial_delay, 30000},
            {enabled, false}
        ]},
        {wamp_tls, [
            {socket_opts, [
                {cacertfile, "./etc/cacert.pem"},
                {keyfile, "./etc/key.pem"},
                {certfile, "./etc/cert.pem"},
                {nodelay, true},
                {keepalive, true},
                {versions, ['tlsv1.2', 'tlsv1.3']}
            ]},
            {backlog, 1024},
            {max_connections, 100000},
            {acceptors_pool_size, 200},
            {port, 18085},
            {enabled, false}
        ]},
        {wamp_tcp, [
            {socket_opts, [{nodelay, true}, {keepalive, true}]},
            {backlog, 1024},
            {max_connections, 100000},
            {acceptors_pool_size, 200},
            {port, 18082},
            {enabled, true}
        ]},
        {wamp_websocket, [
            {deflate_opts, [
                {client_context_takeover, takeover},
                {server_context_takeover, takeover},
                {strategy, default},
                {level, 5},
                {mem_level, 8},
                {server_max_window_bits, 11},
                {client_max_window_bits, 11}
            ]},
            {compress, true},
            {max_frame_size, infinity},
            {idle_timeout, 28800000},
            {ping, [{max_attempts, 3}, {interval, 30000}, {enabled, true}]}
        ]},
        {wamp_serializers, [{bert, 4}, {erl, 15}]},
        {api_gateway_https, [
            {socket_opts, [
                {cacertfile, "./etc/cacert.pem"},
                {keyfile, "./etc/key.pem"},
                {certfile, "./etc/cert.pem"},
                {nodelay, true},
                {keepalive, false},
                {versions, ['tlsv1.3']}
            ]},
            {backlog, 4096},
            {max_connections, 500000},
            {acceptors_pool_size, 200},
            {port, 18083},
            {enabled, false}
        ]},
        {api_gateway_http, [
            {socket_opts, [{nodelay, true}, {keepalive, false}]},
            {backlog, 4096},
            {max_connections, 500000},
            {acceptors_pool_size, 200},
            {port, 18080},
            {enabled, true}
        ]},
        {api_gateway, [{config_file, "./etc/api_gateway_config.json"}]},
        {admin_api_https, [
            {socket_opts, [
                {cacertfile, "./etc/cacert.pem"},
                {keyfile, "./etc/key.pem"},
                {certfile, "./etc/cert.pem"},
                {nodelay, true},
                {keepalive, false},
                {versions, ['tlsv1.3']}
            ]},
            {backlog, 18084},
            {max_connections, 250000},
            {acceptors_pool_size, 200},
            {port, 18084},
            {enabled, false}
        ]},
        {admin_api_http, [
            {socket_opts, [{nodelay, true}, {keepalive, false}]},
            {backlog, 1024},
            {max_connections, 250000},
            {acceptors_pool_size, 200},
            {port, 18081},
            {enabled, true}
        ]},
        {request_timeout, 20000},
        {wamp_message_retention, [
            {default_ttl, 0},
            {max_message_size, 65536},
            {max_memory, 1073741824},
            {max_messages, 1000000},
            {storage_type, ram},
            {enabled, true}
        ]},
        {wamp_max_call_timeout, 600000},
        {wamp_call_timeout, 30000},
        {wamp_connection_lifetime, session},
        {security, [
            {ticket, [
                {allow_not_found, true},
                {client_sso, [{persistence, true}]},
                {client_local, [{persistence, true}]},
                {sso, [{persistence, true}]},
                {local, [{persistence, true}]},
                {max_expiry_time_secs, 2592000},
                {expiry_time_secs, 2592000},
                {authmethods, [
                    <<"cryptosign">>,
                    <<"password">>,
                    <<"ticket">>,
                    <<"tls">>,
                    <<"trust">>,
                    <<"wamp-scram">>,
                    <<"wampcra">>
                ]}
            ]},
            {password, [
                {cra, [{kdf, pbkdf2}]},
                {scram, [{kdf, pbkdf2}]},
                {protocol_upgrade_enabled, false},
                {protocol, cra},
                {min_length, 6},
                {max_length, 254},
                {pbkdf2, [{iterations, 10000}]},
                {argon2id13, [{iterations, moderate}, {memory, interactive}]}
            ]},
            {allow_anonymous_user, true},
            {automatically_create_realms, false},
            {config_file, "./etc/security_config.json"}
        ]},
        {shutdown_grace_period, 5}
    ]},
    {bondy_broker_bridge, [
        {bridges, [
            {bondy_kafka_bridge, [
                {enabled, false},
                {topics, [{<<"wamp_events">>, <<"com.leapsight.wamp.events">>}]},
                {clients, [
                    {default, [
                        {endpoints, [{"127.0.0.1", 9092}]},
                        {extra_sock_opts, []},
                        {default_producer_config, [
                            {partition_restart_delay_seconds, 2},
                            {required_acks, 1},
                            {topic_restart_delay_seconds, 10}
                        ]},
                        {reconnect_cool_down_seconds, 10},
                        {auto_start_producers, true},
                        {restart_delay_seconds, 10},
                        {endpoints, "[{\"127.0.0.1\", 9092}]"},
                        {allow_topic_auto_creation, true},
                        {max_metadata_sock_retry, 5}
                    ]}
                ]}
            ]}
        ]},
        {config_file, "./etc/broker_bridge_config.json"}
    ]}
]).

-define(OPTS_SLAVE, [
    {monitor_master, true}
]).

-export([
    all/0,
    groups/1,
    suite/0,
    tests/1,
    start_bondy/0,
    start_bondy/1,
    start_bondy/2,
    stop_bondy/0
]).

all() ->
    [{group, main}].

groups(Module) ->
    [{main, [parallel], tests(Module)}].

suite() ->
    [{timetrap, {minutes, 5}}].

tests(Module) ->
    [Function || {Function, Arity} <- Module:module_info(exports), Arity == 1, is_a_test(Function)].

is_a_test(is_a_test) ->
    false;
is_a_test(Function) ->
    hd(lists:reverse(string:tokens(atom_to_list(Function), "_"))) == "test".

master_nodename() ->
    {ok, Hostname} = inet:gethostname(),
    list_to_atom("master" ++ Hostname).

enable_distributed_erlang() ->
    NetKernelOptions = [master_nodename(), shortnames],
    case net_kernel:start(NetKernelOptions) of
        {ok, Pid} ->
            Pid;
        {error, {already_started, Pid}} ->
            Pid;
        {error, {
            {shutdown, {failed_to_start_child, net_kernel, {'EXIT', nodistribution}}}, _
        }} ->
            os:cmd("epmd -daemon"),
            % Sometimes on fresh start (e.g. post reboot) epmd takes longer to start.
            timer:sleep(100),
            {ok, Pid} = net_kernel:start(NetKernelOptions),
            Pid
    end.

%% Start bondy on the master node.
start_bondy() ->
    case persistent_term:get({?MODULE, bondy_started}, false) of
        false ->
            application:set_env([{kernel, ?KERNEL_ENV}]),
            enable_distributed_erlang(),

            [
                begin
                    application:stop(App),
                    application:unload(App),
                    application:set_env([{App, Env}]),
                    application:load(App)
                end
             || {App, Env} <- ?ENV
            ],

            {bondy, BondyEnv} = lists:keyfind(bondy, 1, ?ENV),
            length(BondyEnv) == length(application:get_all_env(bondy)) orelse
                exit(configuration_error),

            maybe_error(application:ensure_all_started(bondy)),
            persistent_term:put({?MODULE, bondy_started}, true),
            ok;
        true ->
            ok
    end,
    node().

%% Start bondy on a slave node with a given name and return the full node name.
start_bondy(Node) ->
    start_bondy(Node, 0).

start_bondy(Node, N) ->
    NodeName = start_slave(Node),

    PathsValid = [D || D <- code:get_path(), filelib:is_dir(D)],
    ct:pal("Set path: ~p", [rpc:call(NodeName, code, set_path, [PathsValid])]),

    % Reload the apps with the correct env
    EnvUpdated = update_for_slave(Node, N, ?ENV),
    ResultReloads = [
        {App, rpc:call(NodeName, application, stop, [App]),
            rpc:call(NodeName, application, unload, [App]),
            rpc:call(NodeName, application, set_env, [[{App, Env}]]),
            rpc:call(NodeName, application, load, [App])}
     || {App, Env} <- EnvUpdated
    ],
    ct:pal("~p: Reload apps {App, stop, unload, set_env, load}~n~p", [
        Node, lists:sort(ResultReloads)
    ]),

    {ok, StartedApps} = rpc:call(NodeName, application, ensure_all_started, [bondy]),
    ct:pal("Started applications~n~p", [lists:sort(StartedApps)]),
    RunningApps = [element(1, L) || L <- rpc:call(NodeName, application, which_applications, [])],
    ct:pal("Running applications~n~p", [lists:sort(RunningApps)]),

    NodeName.

stop_bondy() ->
    ok = application:stop(gproc),
    ok = application:stop(jobs),
    persistent_term:put({?MODULE, bondy_started}, false),
    application:stop(bondy).

maybe_error({error, _} = Error) ->
    error(Error);
maybe_error({ok, _}) ->
    ok;
maybe_error(true) ->
    ok.

%% @private
start_slave(Node) ->
    start_slave(Node, ?OPTS_SLAVE).

%% @private
start_slave(Node, Opts) ->
    case ct_slave:start(Node, Opts) of
        {ok, NodeName} ->
            ct:pal("~p started", [NodeName]),
            NodeName;
        {error, already_started, NodeName} ->
            ct:pal("~p already started. Restarting slave.", [NodeName]),
            net_adm:ping(NodeName),
            ct_slave:stop(NodeName),
            {ok, NodeName} = ct_slave:start(Node),
            NodeName;
        {error, not_alive, nonode@nohost} ->
            ct:pal("Master not a distributed node. Turning into one and starting slave again."),
            enable_distributed_erlang(),
            {ok, NodeName} = ct_slave:start(Node),
            NodeName;
        {error, started_not_connected, NodeName} ->
            % Happens if slave was started with {monitor_master, false} before.
            ct:pal("~p started not connected. Connecting.", [NodeName]),
            net_kernel:connect_node(NodeName) orelse
                exit("Unable to connect to slave node " ++ NodeName),
            NodeName
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Functions to update ?ENV to start bondy on a slave node

%% @private
update_for_slave(Node, N, Config) ->
    PlusN = fun(Port) -> N + Port end,
    ExtendPath = fun(Path) -> Path ++ "_" ++ atom_to_list(Node) end,

    Updates = [
        {[bondy, admin_api_http, port], PlusN},
        {[bondy, admin_api_https, port], PlusN},
        {[bondy, api_gateway_http, port], PlusN},
        {[bondy, api_gateway_https, port], PlusN},
        {[bondy, bridge_relay_tcp, port], PlusN},
        {[bondy, bridge_relay_tls, port], PlusN},
        {[bondy, platform_data_dir], ExtendPath},
        {[bondy, platform_etc_dir], ExtendPath},
        {[bondy, platform_log_dir], ExtendPath},
        {[bondy, platform_tmp_dir], ExtendPath},
        {[bondy, wamp_tcp, port], PlusN},
        {[bondy, wamp_tls, port], PlusN},
        {[eleveldb, data_root], ExtendPath},
        {[partisan, peer_port], PlusN},
        {[plum_db, data_dir], ExtendPath}
    ],
    lists:foldl(fun(Elem, Acc) -> key_value_apply(Elem, Acc) end, Config, Updates).

%% @private
key_value_apply({Key, Change}, Config) when is_function(Change, 0) ->
    Value = Change(),
    key_value:set(Key, Value, Config);
key_value_apply({Key, Change}, Config) when is_function(Change, 1) ->
    OldValue = key_value:get(Key, Config),
    NewValue = Change(OldValue),
    key_value:set(Key, NewValue, Config);
key_value_apply({Key, Change}, Config) when not is_function(Change) ->
    key_value:set(Key, Change, Config).
