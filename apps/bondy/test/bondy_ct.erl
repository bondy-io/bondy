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

-define(SLAVE_PARTISAN, [
    {lazy_tick_period, 1000},
    {reservations, []},
    {distance_enabled, true},
    {disable_fast_forward, false},
    {listen_addrs, [#{ip => {127, 0, 0, 1}, port => 19086}]},
    {exchange_selection, optimized},
    {ref_encoding, false},
    {tag, undefined},
    {random_promotion, true},
    {membership_strategy_tracing, false},
    {tracing, false},
    {relay_ttl, 5},
    {register_pid_for_encoding, false},
    {gossip, true},
    {name, 'bridge@Alans-MacBook-Pro'},
    {shrinking, false},
    % to be updated !!
    {peer_port, 18086},
    {tree_refresh, 1000},
    {remote_ref_binary_padding, false},
    {ingress_delay, 0},
    {random_seed, {90873625, -576460750611642483, -576460752303423455}},
    {periodic_interval, 10000},
    {parallelism, 1},
    {exchange_tick_period, 10000},
    {replaying, false},
    {periodic_enabled, true},
    {connect_disterl, true},
    {min_active_size, 3},
    {membership_strategy, partisan_full_membership_strategy},
    {tls_client_options, [
        {verify, verify_none},
        {versions, ['tlsv1.3']}
    ]},
    {disable_fast_receive, false},
    {arwl, 5},
    {channels, [data, membership, rpc, undefined, wamp_peer_relay]},
    {fanout, 5},
    {peer_host, undefined},
    {passive_view_shuffle_period, 10000},
    {binary_padding, false},
    {partisan_peer_service_manager, partisan_pluggable_peer_service_manager},
    {egress_delay, 0},
    {tls_server_options, [
        {verify, verify_none},
        {versions, ['tlsv1.3']}
    ]},
    {orchestration_strategy, undefined},
    {peer_ip, {127, 0, 0, 1}},
    {broadcast_mods, [partisan_plumtree_backend, plum_db]},
    {remote_ref_uri_padding, false},
    {prwl, 30},
    {nodestring, <<"bridge@Alans-MacBook-Pro">>},
    {connection_jitter, 1000},
    {tls, false},
    {causal_labels, []},
    {remote_ref_as_uri, true},
    {max_active_size, 6},
    {max_passive_size, 30},
    {pid_encoding, false},
    {xbot_interval, 32708},
    {broadcast, false}
]).

-define(OPTS_SLAVE, [
    {monitor_master, true}
]).

-define(ORDER_CRITICAL_APPS, [
    jobs,
    gproc,
    tuplespace,
    partisan,
    plum_db,
    bondy
]).

-export([
    all/0,
    groups/1,
    suite/0,
    tests/1,
    start_bondy/0,
    start_bondy/1,
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

%% Start bondy on the master node.
start_bondy() ->
    case persistent_term:get({?MODULE, bondy_started}, false) of
        false ->
            application:set_env([{kernel, ?KERNEL_ENV}]),

            {ok, Hostname} = inet:gethostname(),
            NetKernelOptions = [list_to_atom("runner@" ++ Hostname), shortnames],
            case net_kernel:start(NetKernelOptions) of
                {ok, _} ->
                    ok;
                {error, {already_started, _}} ->
                    ok;
                {error, {
                    {shutdown, {failed_to_start_child, net_kernel, {'EXIT', nodistribution}}}, _
                }} ->
                    os:cmd("epmd -daemon"),
                    {ok, _} = net_kernel:start(NetKernelOptions)
            end,

            _ = [
                begin
                    application:unload(App),
                    application:set_env([{App, Env}]),
                    case lists:member(App, [tuplespace, plum_db]) of
                        true ->
                            ok;
                        false ->
                            application:load(App)
                    end
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
    end.

%% Start bondy on a slave node with a given name and return the full node name.
start_bondy(Node) ->
    % List in the right order of the apps to start on the slave node
    AllApps = [element(1, Line) || Line <- application:which_applications()],
    ?assert(
        lists:member(bondy, AllApps),
        "bondy must run on master before starting a slave."
    ),
    OrderedApps = lists:append(AllApps -- ?ORDER_CRITICAL_APPS, ?ORDER_CRITICAL_APPS),
    write_term("out/master_apps", OrderedApps),
    [
        begin
            case application:get_all_env(App) of
                [] ->
                    ok;
                AppConfig ->
                    Filename = io_lib:format("out/master_app_~p", [App]),
                    write_term(Filename, lists:sort(AppConfig))
            end
        end
     || App <- lists:sort(OrderedApps)
    ],
    PrivDirs = [{App, code:priv_dir(App)} || App <- lists:sort(OrderedApps)],
    write_term("out/master_priv_dirs", lists:sort(PrivDirs)),

    NodeName = start_slave(Node),
    ct:pal("Node: ~p", [NodeName]),

    %EnvNoPartisan = [{App, Config} || {App, Config} <- ?ENV, App /= partisan],
    %EnvWithPartisan = EnvNoPartisan ++ [{partisan, ?SLAVE_PARTISAN}],
    %EnvSlave = update_for_slave(Node, EnvWithPartisan),
    EnvSlave = update_for_slave(Node, ?ENV),

    ok = rpc:call(NodeName, application, set_env, [EnvSlave], 1000),

    PathsValid = [D || D <- code:get_path(), filelib:is_dir(D)],
    write_term("out/master_path", lists:sort(PathsValid)),
    maybe_error(rpc:call(NodeName, code, set_path, [PathsValid], 1000)),

    % Load all apps then ensure they are started
    try
        _ = [
            case rpc:call(NodeName, application, Fct, [App], 5000) of
                ok ->
                    ok;
                {ok, _} ->
                    ok;
                {error, {already_loaded, _}} ->
                    ok;
                {error, Error} ->
                    error({Fct, App, Error});
                {badrpc, Error} ->
                    error({Fct, App, Error})
            end
         || Fct <- [load, ensure_all_started], App <- OrderedApps
        ],
        ok
    catch
        _:E ->
            ct:pal("Got an exception"),
            SlaveAllApps = lists:sort([
                element(1, L)
             || L <- rpc:call(NodeName, application, which_applications, [], 1000)
            ]),
            write_term("out/slave_apps", lists:sort(SlaveAllApps)),
            [
                case rpc:call(NodeName, application, get_all_env, [App], 1000) of
                    [] ->
                        ok;
                    AppConfig ->
                        Filename = io_lib:format("out/slave_app_~p", [App]),
                        write_term(Filename, lists:sort(AppConfig))
                end
             || App <- OrderedApps
            ],
            error(E)
    end,

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
    case ct_slave:start(Node, ?OPTS_SLAVE) of
        {ok, NodeName} ->
            NodeName;
        {error, already_started, NodeName} ->
            NodeName;
        {error, not_alive, nonode@nohost} ->
            exit("Master is not a distributed node, call net_kernel:start before ct_slave:start");
        {error, started_not_connected, NodeName} ->
            % Only happens if slave was started with {monitor_master, false}
            net_kernel:connect_node(NodeName) orelse
                exit("Unable to connect to slave node " ++ NodeName),
            NodeName
    end.

%% Functions to update ?ENV to start bondy on a slave node

%% @private
update_for_slave(Node, Config) ->
    Plus1000 = fun(Port) -> 1000 + Port end,
    ExtendPath = fun(Path) -> Path ++ "_" ++ atom_to_list(Node) end,

    Updates = [
        {[bondy, admin_api_http, port], Plus1000},
        {[bondy, admin_api_https, port], Plus1000},
        {[bondy, api_gateway_http, port], Plus1000},
        {[bondy, api_gateway_https, port], Plus1000},
        %{[bondy, bridge_relay_tcp, enabled], false},
        {[bondy, bridge_relay_tcp, port], Plus1000},
        {[bondy, bridge_relay_tls, port], Plus1000},
        {[bondy, platform_data_dir], ExtendPath},
        {[bondy, platform_etc_dir], ExtendPath},
        {[bondy, platform_log_dir], ExtendPath},
        {[bondy, platform_tmp_dir], ExtendPath},
        {[bondy, wamp_tcp, port], Plus1000},
        {[bondy, wamp_tls, port], Plus1000},
        {[eleveldb, data_root], ExtendPath},
        {[partisan, peer_port], Plus1000},
        % reverted?
        {[plum_db, aae_enabled], true},
        {[plum_db, data_dir], ExtendPath}
    ],
    Config1 = lists:foldl(fun(Elem, Acc) -> key_value_apply(Elem, Acc) end, Config, Updates),

    AllApps = [element(1, Line) || Line <- application:which_applications()],
    lists:foldl(
        fun(App, Acc) ->
            PrivDir = code:priv_dir(App),
            key_value:set([App, priv_dir], ExtendPath(PrivDir), Acc)
        end,
        Config1,
        AllApps
    ).

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

%% @private
write_term(Filename, Term) ->
    T = io_lib:format("~p.~n", [Term]),
    B = unicode:characters_to_binary(T),
    ok = filelib:ensure_dir(Filename),
    ok = file:write_file(Filename, B).
