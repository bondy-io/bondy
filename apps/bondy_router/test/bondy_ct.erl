%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_ct).
-include_lib("common_test/include/ct.hrl").

-if(?OTP_RELEASE >= 25).
-define(TEST_SERVER, test_server).
-else.
-define(TEST_SERVER, ct_slave).
-endif.

-define(KERNEL_ENV, [
    {logger_level, info},
    {logger, [
        {handler, default, logger_std_h, #{
            config => #{
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
                    {no_domain, {
                        fun logger_filters:domain/2, {log, undefined, []}
                    }},
                    {domain, {
                        fun logger_filters:domain/2,
                        {log, super, [otp, sasl, bondy_audit]}
                    }}
                ],
            formatter =>
                {bondy_logger_formatter, #{
                    colored => true,
                    colored_alert => "\e[0;45m",
                    colored_critical => "\e[0;35m",
                    colored_debug => "\e[0;38m",
                    colored_emergency => "\e[1;40;1m",
                    colored_error => "\e[0;31m",
                    colored_info => "\e[0;37m",
                    colored_notice => "\e[0;36m",
                    colored_warning => "\e[0;33m",
                    map_depth => 3,
                    template => [
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
                        {
                            {msg, description},
                            [" description=", description],
                            []
                        },
                        colored_end,
                        {{msg, reason}, [" reason=", reason], []},
                        {id, [" id=", id], []},
                        {span_id, [" span_id=", span_id], []},
                        {trace_id, [" trace_id=", trace_id], []},
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
    %% Mirrors the production posture: the bondy_telemetry_exporter
    %% schema ALWAYS writes `traces_exporter` explicitly (`none` when
    %% `tracing.otlp.enabled` is off) because the OpenTelemetry SDK's own
    %% default is to export to a localhost OTLP endpoint. Without this a
    %% CT node would boot the SDK with that default.
    {opentelemetry, [
        {traces_exporter, none}
    ]},
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
        {compression, lz4},
        {delete_threshold, 1000},
        {tiered_slow_level, 0}
    ]},
    {partisan, [
        {exchange_tick_period, 60000},
        {tls_server_options, [
            {cacertfile, "./etc/ssl/server/cacert.pem"},
            {keyfile, "./etc/ssl/server/key.pem"},
            {certfile, "./etc/ssl/server/keycert.pem"},
            {versions, ['tlsv1.3']}
        ]},
        {tls_client_options, [
            {cacertfile, "./etc/ssl/client/cacert.pem"},
            {keyfile, "./etc/ssl/client/key.pem"},
            {certfile, "./etc/ssl/client/keycert.pem"},
            {versions, ['tlsv1.3']}
        ]},
        {tls, false},
        {peer_service_manager, partisan_pluggable_peer_service_manager},
        {lazy_tick_period, 1000},
        {parallelism, 1},
        {peer_port, 18086}
    ]},
    {wamp, [
        {uri_strictness, loose}
    ]},
    {bondy_router, [
        %% The listener inventory, declared the way an operator now declares it.
        %% There is no second spelling: the legacy `admin_api.*',
        %% `api_gateway.*', `wamp.{tcp,tls}.*' and `bridge.listener.*' mappings
        %% are gone, so a listener exists only if it is named here. The seven
        %% below are exactly the seven this harness enabled before; the two
        %% bridge relays were disabled and are therefore simply absent.
        %%
        %% Each name matches its option block further down, which is what makes
        %% the block reach it: a listener's options are read under its CURRENT
        %% name. The admin listener is `admin' -- the reserved name -- so
        %% `bondy_listener_manager:with_reserved/1' finds it already present
        %% instead of injecting a second listener on 18081.
        {listeners, [
            {admin, #{
                transport => tcp,
                protocol => http,
                port => 18081,
                start_phase => early,
                services => [admin_api, wamp_ws, admin, metrics]
            }},
            {admin_api_https, #{
                transport => tls,
                protocol => http,
                port => 18084,
                start_phase => early,
                services => [admin_api, wamp_ws, admin, metrics]
            }},
            {api_gateway_http, #{
                transport => tcp,
                protocol => http,
                port => 18080,
                services => [api_gateway, wamp_ws, wamp_sse, wamp_longpoll]
            }},
            {api_gateway_https, #{
                transport => tls,
                protocol => http,
                port => 18083,
                services => [api_gateway, wamp_ws, wamp_sse, wamp_longpoll]
            }},
            {wamp_tcp, #{
                transport => tcp, protocol => wamp_rawsocket, port => 18082
            }},
            {wamp_tls, #{
                transport => tls, protocol => wamp_rawsocket, port => 18085
            }},
            {wamp_uds, #{
                transport => uds,
                protocol => wamp_rawsocket,
                path => "/tmp/bondy_ct_wamp_uds_" ++ os:getpid() ++ ".sock"
            }}
        ]},
        %% NOTE: no `wamp.{dealer,broker}.features` here. A feature is a
        %% capability of the build, seated by `bondy_config:setup_wamp/0` from
        %% `?DEALER_FEATURES` / `?BROKER_FEATURES`, and that runs on app start —
        %% so a copy in this fixture is overwritten before any test reads it.
        %% It also drifted: this one still said `call_reroute` was supported.
        {session_manager_pool, [{size, 32}]},
        {job_manager_queue, [{ttl, 60000}, {max_size, 160000}]},
        {job_manager_pool, [{size, 16}]},
        %% The relay forward options the cuttlefish schema would provide
        %% (`router.forward.*` defaults) — read by the cross-node EVENT /
        %% INVOCATION relay paths.
        {router, [{forward, #{ack => false, retransmission => false}}]},
        {router_pool, [{capacity, 1000000}, {size, 16}, {type, transient}]},
        %% The ordered flow pool's capacity (`router.flow_pool.capacity`).
        %% The rest of its geometry is stamped by bondy_router_flow_sup.
        {router_flow_pool, [{capacity, 100000}]},
        {load_regulation_enabled, true},
        {registry, [
            {partition_spawn_opts, [
                {message_queue_data, off_heap}
            ]},
            {partitions, 32}
        ]},
        {oauth2, [
            {max_tokens_per_user, 25},
            {refresh_token_length, 40},
            {refresh_token_duration, 2592000},
            {code_grant_duration, 600},
            {client_credentials_grant_duration, 900},
            {password_grant_duration, 900},
            {config_file, "./etc/oauth2_config.json"}
        ]},
        {bridge_relay, [{forward, #{ack => false, retransmission => false}}]},
        {bridge_relay_tls, [
            {proxy_protocol, [{mode, relaxed}, {enabled, false}]},
            {tls, [
                {cacertfile, "./etc/ssl/server/cacert.pem"},
                {keyfile, "./etc/ssl/server/key.pem"},
                {certfile, "./etc/ssl/server/keycert.pem"},
                {versions, ['tlsv1.3']}
            ]},
            {transport_opts, [
                {socket_opts, [
                    {nodelay, true},
                    {keepalive, true},
                    {backlog, 1024},
                    {port, 18093},
                    {ip_version, inet}
                ]},
                {max_connections, 100000},
                {num_acceptors, 200}
            ]},
            {max_frame_size, infinity},
            {hibernate, idle},
            {idle_timeout, 30000},
            {ping, [
                {max_attempts, 2},
                {timeout, 10000},
                {idle_timeout, 20000},
                {enabled, true}
            ]},
            {enabled, false}
        ]},
        {bridge_relay_tcp, [
            {proxy_protocol, [{mode, relaxed}, {enabled, false}]},
            {max_frame_size, infinity},
            {auth_timeout, 5000},
            {hibernate, idle},
            {idle_timeout, 28800000},
            {ping, [
                {max_attempts, 2},
                {timeout, 10000},
                {idle_timeout, 20000},
                {enabled, true}
            ]},
            {transport_opts, [
                {socket_opts, [
                    {nodelay, true},
                    {keepalive, true},
                    {backlog, 1024},
                    {ip_version, inet}
                ]},
                {max_connections, 100000},
                {num_acceptors, 200}
            ]},
            {port, 18092},
            {enabled, false}
        ]},
        {platform_log_dir, "./log"},
        {platform_etc_dir, "./etc"},
        %% Per-OS-pid: `admin_local` puts its socket here, and two concurrent CT
        %% runs sharing one path would collide —
        %% `bondy_listener_ranch:maybe_unlink_socket/1` deletes the node before
        %% binding, so the second run would silently take the first run's socket
        %% away. `bondy_listener_SUITE:init_per_suite/1` does the same for the
        %% same reason.
        {platform_tmp_dir, "./tmp/" ++ os:getpid()},
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
            {proxy_protocol, [{mode, relaxed}, {enabled, false}]},
            {tls, [
                {cacertfile, "./etc/ssl/server/cacert.pem"},
                {keyfile, "./etc/ssl/server/key.pem"},
                {certfile, "./etc/ssl/server/keycert.pem"},
                {versions, ['tlsv1.2', 'tlsv1.3']}
            ]},
            {transport_opts, [
                {socket_opts, [
                    {reuseport, false},
                    {nodelay, true},
                    {linger_timeout, 1000},
                    {keepalive, true},
                    {backlog, 1024},
                    {port, 18085},
                    {ip_version, inet}
                ]},
                {max_connections, 100000},
                {num_acceptors, 200}
            ]},
            {idle_timeout, 28800000},
            {ping, [
                {max_attempts, 3},
                {timeout, 10000},
                {interval, 30000},
                {enabled, true}
            ]},
            {port, 18085},
            {enabled, true}
        ]},
        {wamp_tcp, [
            {proxy_protocol, [{mode, relaxed}, {enabled, false}]},
            {idle_timeout, 28800000},
            {ping, [
                {max_attempts, 2},
                {timeout, 10000},
                {idle_timeout, 20000},
                {enabled, true}
            ]},
            {transport_opts, [
                {socket_opts, [
                    {reuseport, false},
                    {nodelay, true},
                    {linger_timeout, 0},
                    {keepalive, true},
                    {backlog, 1024},
                    {port, 18082},
                    {ip_version, inet}
                ]},
                {max_connections, 100000},
                {num_acceptors, 200}
            ]},
            {enabled, true}
        ]},
        {wamp_uds, [
            {proxy_protocol, [{mode, relaxed}, {enabled, false}]},
            %% The OS pid keeps two concurrent CT runs from stealing each
            %% other's socket. Not cosmetic: the driver deletes a socket node
            %% before binding (`maybe_unlink_socket/1`), so the second run
            %% SUCCEEDS on a shared path and the first keeps an unreachable
            %% listen socket, with nothing reported at either end. `/tmp`
            %% rather than a CT-nested directory because
            %% `sockaddr_un.sun_path` is 104 bytes on Darwin.
            {path, "/tmp/bondy_ct_wamp_uds_" ++ os:getpid() ++ ".sock"},
            {idle_timeout, 28800000},
            {ping, [
                {max_attempts, 2},
                {timeout, 10000},
                {idle_timeout, 20000},
                {enabled, true}
            ]},
            %% Nested under `transport_opts` like every other listener's,
            %% because ranch options now come from
            %% `bondy_config:listener_transport_opts/2` for every listener
            %% rather than from a per-transport module. `socket_opts` needs no
            %% address: `bondy_listener_ranch:with_bind/2` sets `{local, Path}`
            %% from the inventory's bind target and drops the address family,
            %% which a Unix domain socket has none of.
            {transport_opts, [
                {num_acceptors, 10},
                {max_connections, 100000},
                {socket_opts, [{ip_version, inet}]}
            ]},
            {enabled, true}
        ]},
        {wamp_serializers, [{bert, 4}, {erl, 15}]},
        {api_gateway_https, [
            {tls, [
                {cacertfile, "./etc/ssl/server/cacert.pem"},
                {keyfile, "./etc/ssl/server/key.pem"},
                {certfile, "./etc/ssl/server/keycert.pem"},
                {versions, ['tlsv1.3']}
            ]},
            {transport_opts, [
                {socket_opts, [
                    {reuseport, false},
                    {nodelay, true},
                    {keepalive, false},
                    {backlog, 1024},
                    {port, 18083},
                    {ip_version, inet}
                ]},
                {handshake_timeout, 5000},
                {max_connections, 500000},
                {num_acceptors, 200}
            ]},
            {proxy_protocol, [{mode, relaxed}, {enabled, false}]},
            {protocol_opts, [
                {sendfile, true},
                {max_skip_body_length, 1000000},
                {max_request_line_length, 8000},
                {max_method_length, 32},
                {max_headers, 100},
                {max_header_value_length, 4096},
                {max_header_name_length, 64},
                {max_empty_lines, 5},
                {initial_stream_flow_size, 65535},
                {max_keepalive, 1000},
                {reset_idle_timeout_on_send, false},
                {request_timeout, 5000},
                {linger_timeout, 1000},
                {inactivity_timeout, 300000},
                {idle_timeout, 15000},
                {active_n, 100}
            ]},
            {cors, #{
                enabled => true,
                allowed_origins => '*',
                allowed_methods => <<"GET,HEAD,OPTIONS,POST,PUT,PATCH,DELETE">>,
                allowed_headers =>
                    <<"origin,x-requested-with,content-type,accept,authorization,accept-language,x-csrf-token">>,
                max_age => <<"86400">>
            }},
            {security_headers, #{
                enabled => true,
                hsts => <<"max-age=31536000; includeSubDomains">>,
                frame_options => <<"SAMEORIGIN">>,
                content_type_options => <<"nosniff">>,
                content_security_policy => undefined
            }},
            {enabled, true}
        ]},
        {api_gateway_http, [
            {proxy_protocol, [{mode, relaxed}, {enabled, true}]},
            {protocol_opts, [
                {sendfile, true},
                {max_skip_body_length, 1000000},
                {max_request_line_length, 8000},
                {max_method_length, 32},
                {max_headers, 100},
                {max_header_value_length, 4096},
                {max_header_name_length, 64},
                {max_empty_lines, 5},
                {initial_stream_flow_size, 65535},
                {max_keepalive, 1000},
                {reset_idle_timeout_on_send, false},
                {request_timeout, 5000},
                {linger_timeout, 1000},
                {inactivity_timeout, 300000},
                {idle_timeout, 15000},
                {active_n, 100}
            ]},
            {transport_opts, [
                {handshake_timeout, 5000},
                {socket_opts, [
                    {reuseport, false},
                    {nodelay, true},
                    {keepalive, false},
                    {backlog, 4096},
                    {port, 18080},
                    {ip_version, inet}
                ]},
                {max_connections, 500000},
                {num_acceptors, 200}
            ]},
            {cors, #{
                enabled => true,
                allowed_origins => '*',
                allowed_methods => <<"GET,HEAD,OPTIONS,POST,PUT,PATCH,DELETE">>,
                allowed_headers =>
                    <<"origin,x-requested-with,content-type,accept,authorization,accept-language,x-csrf-token">>,
                max_age => <<"86400">>
            }},
            {security_headers, #{
                enabled => true,
                hsts => undefined,
                frame_options => <<"SAMEORIGIN">>,
                content_type_options => <<"nosniff">>,
                content_security_policy => undefined
            }},
            {enabled, true}
        ]},
        {api_gateway, [{config_file, "./etc/api_gateway_config.json"}]},
        {admin, [
            {proxy_protocol, [{mode, relaxed}, {enabled, true}]},
            {protocol_opts, [
                {sendfile, true},
                {max_skip_body_length, 1000000},
                {max_request_line_length, 8000},
                {max_method_length, 32},
                {max_headers, 100},
                {max_header_value_length, 4096},
                {max_header_name_length, 64},
                {max_empty_lines, 5},
                {initial_stream_flow_size, 65535},
                {max_keepalive, 1000},
                {reset_idle_timeout_on_send, false},
                {request_timeout, 5000},
                {linger_timeout, 1000},
                {inactivity_timeout, 300000},
                {idle_timeout, 15000},
                {active_n, 100}
            ]},
            {transport_opts, [
                {handshake_timeout, 5000},
                {socket_opts, [
                    {reuseport, true},
                    {reuseaddr, true},
                    {nodelay, true},
                    {keepalive, false},
                    {backlog, 65535},
                    {port, 18081},
                    {ip_version, inet}
                ]},
                {max_connections, 500000},
                {num_acceptors, 200}
            ]},
            {cors, #{
                enabled => true,
                allowed_origins => '*',
                allowed_methods => <<"GET,HEAD,OPTIONS,POST,PUT,PATCH,DELETE">>,
                allowed_headers =>
                    <<"origin,x-requested-with,content-type,accept,authorization,accept-language,x-csrf-token">>,
                max_age => <<"86400">>
            }},
            {security_headers, #{
                enabled => true,
                hsts => undefined,
                frame_options => <<"SAMEORIGIN">>,
                content_type_options => <<"nosniff">>,
                content_security_policy => undefined
            }},
            {enabled, true}
        ]},
        {admin_api_https, [
            {tls, [
                {cacertfile, "./etc/ssl/server/cacert.pem"},
                {keyfile, "./etc/ssl/server/key.pem"},
                {certfile, "./etc/ssl/server/keycert.pem"},
                {versions, ['tlsv1.3']}
            ]},
            {transport_opts, [
                {socket_opts, [
                    {reuseport, false},
                    {nodelay, true},
                    {keepalive, false},
                    {backlog, 4096},
                    {port, 18084},
                    {ip_version, inet}
                ]},
                {handshake_timeout, 5000},
                {max_connections, 250000},
                {num_acceptors, 200}
            ]},
            {proxy_protocol, [{mode, relaxed}, {enabled, false}]},
            {protocol_opts, [
                {sendfile, true},
                {max_skip_body_length, 1000000},
                {max_request_line_length, 8000},
                {max_method_length, 32},
                {max_headers, 100},
                {max_header_value_length, 4096},
                {max_header_name_length, 64},
                {max_empty_lines, 5},
                {initial_stream_flow_size, 65535},
                {max_keepalive, 1000},
                {reset_idle_timeout_on_send, false},
                {request_timeout, 5000},
                {linger_timeout, 1000},
                {inactivity_timeout, 300000},
                {idle_timeout, 15000},
                {active_n, 100}
            ]},
            {cors, #{
                enabled => true,
                allowed_origins => '*',
                allowed_methods => <<"GET,HEAD,OPTIONS,POST,PUT,PATCH,DELETE">>,
                allowed_headers =>
                    <<"origin,x-requested-with,content-type,accept,authorization,accept-language,x-csrf-token">>,
                max_age => <<"86400">>
            }},
            {security_headers, #{
                enabled => true,
                hsts => <<"max-age=31536000; includeSubDomains">>,
                frame_options => <<"SAMEORIGIN">>,
                content_type_options => <<"nosniff">>,
                content_security_policy => undefined
            }},
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

-export([
    all/0,
    groups/1,
    suite/0,
    tests/1,
    ensure_etc/0,
    start_bondy/0,
    stop_bondy/0,
    start_cluster/2,
    start_cluster/3,
    stop_cluster/1,
    freeze_gc/1,
    stop_nodes/1,
    stop_node/1,
    restart_node/4,
    rejoin/3,
    peer_boot/1,
    aae_reset_all_stale/0,
    aae_bump_isolated_all/0,
    aae_mock_nonsolo_membership/0,
    aae_unmock_nonsolo_membership/0
]).

%% =============================================================================
%% API
%% =============================================================================

all() ->
    [{group, main}].

groups(Module) ->
    [{main, [parallel], tests(Module)}].

suite() ->
    [{timetrap, {minutes, 5}}].

tests(Module) ->
    [
        Function
     || {Function, Arity} <- Module:module_info(exports),
        Arity == 1,
        is_a_test(Function)
    ].

is_a_test(is_a_test) ->
    false;
is_a_test(Function) ->
    hd(lists:reverse(string:tokens(atom_to_list(Function), "_"))) == "test".

%% -----------------------------------------------------------------------------
%% @doc Starts Bondy as part of the runner
%% @end
%% -----------------------------------------------------------------------------
start_bondy() ->
    case persistent_term:get({?MODULE, bondy_started}, false) of
        false ->
            ok = ensure_etc(),

            application:set_env([{kernel, ?KERNEL_ENV}]),

            ok = start_disterl(),

            _ = [
                begin
                    application:unload(App),
                    application:set_env([{App, Env}]),
                    case lists:member(App, [tuplespace]) of
                        true ->
                            ok;
                        false ->
                            application:load(App)
                    end
                end
             || {App, Env} <- ?ENV
            ],

            %% Every key `?ENV` declares must have been applied. Checked as a
            %% SUBSET, not by comparing lengths: `bondy_config:set/2` reaches
            %% `application:set_env/3` (`app_config:do_set/3`), so a test that
            %% configures a listener adds a top-level `bondy_router` key and an
            %% equal-length check then fails on a legitimate addition. It did:
            %% `bondy_admin_listener_SUITE` run after `bondy_listener_SUITE` in
            %% one `rebar3 ct` invocation exited `configuration_error` here,
            %% while each suite passed alone. The subset check catches what this
            %% guard is for — `?ENV` not reaching the application — and names
            %% the keys instead of reporting a bare atom.
            {bondy_router, BondyEnv} = lists:keyfind(bondy_router, 1, ?ENV),
            Applied = application:get_all_env(bondy_router),
            Missing = [
                K
             || {K, _} <- BondyEnv, not lists:keymember(K, 1, Applied)
            ],
            Missing == [] orelse
                exit({configuration_error, {missing, Missing}}),

            maybe_error(application:ensure_all_started(bondy_router)),
            persistent_term:put({?MODULE, bondy_started}, true),
            ok;
        true ->
            ok
    end.

%% -----------------------------------------------------------------------------
%% @doc Stops Bondy (to be used with start_bondy/0).
%% @end
%% -----------------------------------------------------------------------------
stop_bondy() ->
    ok = application:stop(gproc),
    ok = application:stop(jobs),
    persistent_term:put({?MODULE, bondy_started}, false),
    application:stop(bondy_router).

%% -----------------------------------------------------------------------------
%% @doc Starts `length(Names)' full `bondy_router' nodes as `peer' nodes on
%% 127.0.0.1, each with an isolated data directory and a unique Partisan listen
%% port, all client listeners disabled, and bondy_db anti-entropy
%% (`db.aae') enabled; then joins them into a single Partisan cluster and
%% waits for the membership to converge.
%%
%% `Names' is a list of short node-name atoms (e.g. `[bondy1, bondy2, bondy3]').
%% `Config' is the CT config — its `priv_dir' roots the per-node data dirs.
%% Returns `[{Name, Node, Peer}]' in the same order as `Names'.
%%
%% The controller drives the peers over Erlang distribution (`erpc'); Bondy's
%% own replication never uses disterl — its Partisan runs with `connect_disterl
%% => false', so all node-to-node AAE traffic rides the Partisan overlay.
%% @end
%% -----------------------------------------------------------------------------
-spec start_cluster([atom()], Config :: proplists:proplist()) ->
    [{atom(), node(), pid()}].

start_cluster(Names, Config) when is_list(Names) ->
    ok = start_disterl(),
    PrivDir = proplists:get_value(priv_dir, Config),
    PrivDir =/= undefined orelse error({missing_priv_dir, Config}),
    Cookie = atom_to_list(erlang:get_cookie()),
    %% A name is an atom, or `{Name, ExtraEnv}' where ExtraEnv is a list of
    %% `{KeyPath, Value}' overrides applied on top of the per-node env — for
    %% boot-time configuration a testcase cannot set after the fact (e.g.
    %% `[partisan, peer_port]').
    Specs = [
        case N of
            {Name, Extra} when is_atom(Name), is_list(Extra) -> {Name, Extra};
            Name when is_atom(Name) -> {Name, []}
        end
     || N <- Names
    ],
    Indexed = lists:zip(Specs, lists:seq(1, length(Specs))),
    Nodes = start_nodes_or_unwind(Indexed, PrivDir, Cookie, []),
    try
        ok = form_cluster(Nodes),
        ok = wait_for_members(Nodes, length(Nodes), 30000),
        Nodes
    catch
        Class:Reason:Stacktrace ->
            ok = stop_cluster(Nodes),
            erlang:raise(Class, Reason, Stacktrace)
    end.

%% @private
%% Peer ports are derived from a node's index within its cluster, so every
%% cluster suite in a run binds the same ports. A node left running by a
%% half-built cluster therefore makes every later cluster suite fail to bind
%% with `eaddrinuse', turning one bad boot into a run-wide cascade. Whatever
%% started before the failure is stopped before the error propagates.
start_nodes_or_unwind([], _PrivDir, _Cookie, Acc) ->
    lists:reverse(Acc);
start_nodes_or_unwind([{{Name, Extra}, Idx} | T], PrivDir, Cookie, Acc) ->
    Node =
        try
            start_node(Name, Idx, PrivDir, Cookie, Extra)
        catch
            Class:Reason:Stacktrace ->
                ok = stop_cluster(lists:reverse(Acc)),
                erlang:raise(Class, Reason, Stacktrace)
        end,
    start_nodes_or_unwind(T, PrivDir, Cookie, [Node | Acc]).

%% -----------------------------------------------------------------------------
%% @doc Backwards-compatible 3-arity form. `Options' must carry a `names' key
%% with the list of node-name atoms.
%% @end
%% -----------------------------------------------------------------------------
start_cluster(_Case, Config, #{names := Names}) ->
    start_cluster(Names, Config).

%% -----------------------------------------------------------------------------
%% @doc Stops ONE node of a cluster started by {@link start_cluster/2}, leaving
%% the rest running and its data directory intact.
%%
%% Note this is `peer:stop/1', NOT {@link stop_nodes/1}: `start_cluster/2'
%% brings nodes up with `peer:start/1', and `stop_nodes/1' belongs to the
%% other (test_server) start path — calling it on a peer-started node fails.
%% @end
%% -----------------------------------------------------------------------------
-spec stop_node({atom(), node(), pid()}) -> ok.

stop_node({_Name, _Node, Peer}) ->
    try
        peer:stop(Peer)
    catch
        _:_ -> ok
    end,
    ok.

%% -----------------------------------------------------------------------------
%% @doc Stops one node of a running cluster and starts it again ON ITS OWN
%% DATA DIRECTORY, then re-forms the cluster and waits for membership.
%%
%% `Idx' and `ExtraEnv' MUST be the node's ORIGINALS from `start_cluster/2':
%% the index selects the port block and `ExtraEnv' carries boot-time overrides
%% a testcase cannot set afterwards (notably `[partisan, peer_port]'). Passing
%% `[]' here brings the node back on a different Partisan port, which boots a
%% node that can never rejoin the cluster it left.
%%
%% The data directory is keyed on the node's NAME, so the restarted node picks
%% up the durable state it wrote before going down. That is the whole point —
%% a rejoin test that came back on an empty data dir would exercise a
%% fresh-peer bootstrap, not a rejoin.
%%
%% Returns the new `{Name, Node, Peer}' (the node name is stable, the peer pid
%% is not).
%% @end
%% -----------------------------------------------------------------------------
-spec restart_node(
    {atom(), node(), pid()}, pos_integer(), list(), list()
) -> {atom(), node(), pid()}.

restart_node({Name, Node, Peer}, Idx, ExtraEnv, Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    PrivDir =/= undefined orelse error({missing_priv_dir, Config}),
    Cookie = atom_to_list(erlang:get_cookie()),
    try
        peer:stop(Peer)
    catch
        _:_ -> ok
    end,
    %% The replacement takes the SAME node name, so the controller's stale
    %% connection to the previous incarnation has to be gone before we start
    %% it — otherwise `peer:start/1' succeeds and the very first `erpc' into
    %% the new node comes back `{erpc, noconnection}' against the dead one.
    _ = erlang:disconnect_node(Node),
    ok = wait_node_down(Node, 30000),
    start_node(Name, Idx, PrivDir, Cookie, ExtraEnv).

%% @private
wait_node_down(Node, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_node_down_loop(Node, Deadline).

%% @private
wait_node_down_loop(Node, Deadline) ->
    case net_adm:ping(Node) of
        pang ->
            ok;
        pong ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({node_still_up, Node});
                false ->
                    _ = erlang:disconnect_node(Node),
                    timer:sleep(250),
                    wait_node_down_loop(Node, Deadline)
            end
    end.

%% -----------------------------------------------------------------------------
%% @doc Rejoins `Node' to `Existing' and waits until every node sees the full
%% membership. Used after {@link restart_node/3}.
%% @end
%% -----------------------------------------------------------------------------
-spec rejoin(
    {atom(), node(), pid()}, [{atom(), node(), pid()}], timeout()
) -> ok.

rejoin({_, Node, _}, Existing, Timeout) ->
    [{_, First, _} | _] = Existing,
    ok = join(Node, First, []),
    wait_for_members(Existing, length(Existing), Timeout).

%% -----------------------------------------------------------------------------
%% @doc Stops a cluster started by {@link start_cluster/2}.
%% @end
%% -----------------------------------------------------------------------------
-spec stop_cluster([{atom(), node(), pid()}]) -> ok.

stop_cluster(Nodes) ->
    lists:foreach(
        fun({_Name, _Node, Peer}) ->
            try
                peer:stop(Peer)
            catch
                _:_ -> ok
            end
        end,
        Nodes
    ),
    ok.

%% -----------------------------------------------------------------------------
%% @doc Freezes BOTH scheduler-driven sweeps on `Node' and WAITS for their
%% in-flight workers to drain, so MST roots and projection cells are frozen when
%% this returns. Cluster suites that assert on root or frontier state call this
%% per node — a live tick truncates MSTs mid-assertion, skewing root comparisons
%% and (deliberately-)asymmetric compaction setups. Plain `erpc' into the node's
%% schedulers; no suite module needs pushing.
%%
%% `bondy_oplog_sup' starts TWO `bondy_oplog_gc_scheduler' instances: the
%% default-named one driving compaction, and `bondy_oplog_reclaim_scheduler'
%% driving the causal-stability cell sweep (on by default, slower cadence).
%% Freezing only the default leaves the second one running, so a suite that
%% believes it has frozen the node still has a sweep mutating state underneath
%% it.
%% -----------------------------------------------------------------------------
freeze_gc(Node) ->
    Deadline = erlang:monotonic_time(millisecond) + 10_000,
    lists:foreach(
        fun(Name) ->
            ok = erpc:call(
                Node, bondy_oplog_gc_scheduler, set_interval_ms, [Name, 0]
            ),
            freeze_gc_await(Node, Name, Deadline)
        end,
        [bondy_oplog_gc_scheduler, bondy_oplog_reclaim_scheduler]
    ).

%% @private
freeze_gc_await(Node, Name, Deadline) ->
    Info = erpc:call(Node, bondy_oplog_gc_scheduler, info, [Name]),
    case maps:get(in_flight, Info) of
        0 ->
            ok;
        N ->
            erlang:monotonic_time(millisecond) =< Deadline orelse
                error({gc_workers_stuck, Node, Name, N}),
            timer:sleep(50),
            freeze_gc_await(Node, Name, Deadline)
    end.

%% -----------------------------------------------------------------------------
%% @doc Boots `bondy_router' on the local (peer) node from the per-node `Env'.
%% Invoked on each peer via `erpc'. Mirrors {@link start_bondy/0}'s env-load
%% sequence, but (a) takes a caller-supplied env so each node gets isolated
%% data dirs / ports, and (b) does NOT touch distribution — the peer is already
%% a distributed node courtesy of `peer:start_link/1'.
%% @end
%% -----------------------------------------------------------------------------
-spec peer_boot([{atom(), term()}]) -> ok.

peer_boot(Env) ->
    ok = ensure_etc(),
    application:set_env([{kernel, ?KERNEL_ENV}]),
    ok = install_peer_log_handler(Env),
    _ = [
        begin
            _ = application:unload(App),
            application:set_env([{App, AppEnv}]),
            case lists:member(App, [tuplespace]) of
                true -> ok;
                false -> _ = application:load(App)
            end
        end
     || {App, AppEnv} <- Env
    ],
    maybe_error(application:ensure_all_started(bondy_router)).

%% @private
%% Peer nodes are otherwise SILENT. Two reasons compound:
%%
%%   - `peer_boot/1' runs under `erpc', which gives the calling process the
%%     CONTROLLER's group leader, and OTP's `default' handler carries a
%%     `logger_filters:remote_gl/2' STOP filter — so every event logged while
%%     the node boots (including the supervisor and crash reports that explain
%%     a failed boot) is dropped on the floor;
%%   - the peer's kernel is already running when `peer_boot/1' sets the kernel
%%     env, so `?KERNEL_ENV''s handler config never takes effect there either.
%%
%% Attach a per-node file handler with `filter_default => log' and NO filters,
%% so the node's own boot story lands next to its data directory
%% (`<priv_dir>/<node>/node.log') and survives the run. Best-effort: a peer we
%% cannot give a log file to should still boot.
install_peer_log_handler(Env) ->
    case key_value:get([bondy_router, platform_data_dir], Env, undefined) of
        undefined ->
            ok;
        Dir ->
            File = filename:join(Dir, "node.log"),
            ok = filelib:ensure_dir(File),
            Config = #{
                level => info,
                filter_default => log,
                filters => [],
                config => #{type => file, file => File},
                formatter =>
                    {logger_formatter, #{
                        legacy_header => false,
                        single_line => false,
                        template => [
                            time,
                            " ",
                            level,
                            " ",
                            pid,
                            " ",
                            mfa,
                            ":",
                            line,
                            "\n",
                            msg,
                            "\n"
                        ]
                    }}
            },
            _ = logger:add_handler(bondy_ct_peer_file, logger_std_h, Config),
            ok
    end.

%% -----------------------------------------------------------------------------
%% @doc Stop the CT peers in `Nodes'.
%% @end
%% -----------------------------------------------------------------------------
stop_nodes(Nodes) ->
    StopFun = fun({Name, _Node}) ->
        case ?TEST_SERVER:stop(Name) of
            {ok, _} ->
                ok;
            {error, stop_timeout, _} ->
                ct:pal("Failed to stop node ~p: stop_timeout!", [Name]),
                stop_nodes(Nodes),
                ok;
            {error, not_started, _} ->
                ok;
            Error ->
                ct:fail(Error)
        end
    end,
    lists:map(StopFun, Nodes),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
start_disterl() ->
    {ok, Hostname} = inet:gethostname(),
    %% Preferred stable name first; when another CT run on this host
    %% already holds it (an epmd name clash — e.g. two repos running CT
    %% concurrently) fall back to a per-OS-pid unique name. Nothing
    %% depends on the literal name: peers only reuse the host part (see
    %% controller_host/0).
    Names = [
        list_to_atom("runner@" ++ Hostname),
        list_to_atom("runner_" ++ os:getpid() ++ "@" ++ Hostname)
    ],
    start_disterl(Names).

%% @private
%% OTP 24+ `net_kernel:start/2' options-map API (the legacy
%% `net_kernel:start([Name, shortnames])' list form is deprecated and behaves
%% inconsistently on OTP 28). Always return `ok' — the retry branches must
%% not leak `{ok, Pid}'.
start_disterl([Nodename | Rest]) ->
    Opts = #{name_domain => shortnames},
    case net_kernel:start(Nodename, Opts) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok;
        {error, Reason} when Rest =/= [] ->
            %% A missing epmd daemon and a name clash both surface as
            %% nodistribution: make sure epmd is up, then try the next
            %% candidate name.
            _ = os:cmd(os:find_executable("epmd") ++ " -daemon"),
            logger:info(#{
                description =>
                    "Failed to start distribution; retrying with the next "
                    "candidate node name.",
                nodename => Nodename,
                reason => Reason
            }),
            start_disterl(Rest);
        {error, _} = Error ->
            error({nodistribution, Error})
    end.

%% Common Test sets the current working directory to the per-run `ct_run.*'
%% log dir, but relative certificate/config paths (e.g.
%% "./etc/ssl/server/keycert.pem") assume a release's cwd. Reproduce that
%% layout by symlinking `./etc' to the repository's `etc' directory so those
%% relative paths resolve. Idempotent and best-effort: a no-op when `./etc'
%% already exists or the repo root / its `etc' dir cannot be located.
%%
%% Exported (not just called from `start_bondy/0' and `start_cluster/3') so a
%% suite that never boots Bondy through this module — one driving
%% `bondy_listener_manager' directly against real sockets — can still resolve
%% the same relative certificate paths.
ensure_etc() ->
    case filelib:is_dir("etc") of
        true ->
            ok;
        false ->
            {ok, Cwd} = file:get_cwd(),
            case find_repo_root(Cwd) of
                {ok, Root} ->
                    EtcSrc = filename:join(Root, "etc"),
                    case filelib:is_dir(EtcSrc) of
                        true ->
                            _ = file:make_symlink(EtcSrc, "etc"),
                            ok;
                        false ->
                            ok
                    end;
                error ->
                    ok
            end
    end.

%% @private
%% Walk up from `Dir' to the repository root, identified by a directory that
%% holds both an `apps' subdirectory and a `rebar.config' (profile-independent,
%% unlike deriving it from `code:lib_dir/1').
find_repo_root(Dir) ->
    HasApps = filelib:is_dir(filename:join(Dir, "apps")),
    HasRebar = filelib:is_file(filename:join(Dir, "rebar.config")),
    case HasApps andalso HasRebar of
        true ->
            {ok, Dir};
        false ->
            case filename:dirname(Dir) of
                Dir ->
                    error;
                Parent ->
                    find_repo_root(Parent)
            end
    end.

%% @private
maybe_error({error, _} = Error) ->
    error(Error);
maybe_error({ok, _}) ->
    ok.

%% @private
codepath() ->
    lists:filter(fun filelib:is_dir/1, code:get_path()).

%% @private
join(Node, Peer, _Config) ->
    PeerSpec = rpc:call(Peer, partisan, node_spec, []),
    ct:pal("Joining node: ~p with peer: ~p", [Node, PeerSpec]),
    ok = rpc:call(Node, partisan_peer_service, join, [PeerSpec]).

%% @private
%% Boots one peer node, makes this module loadable on it, and starts
%% `bondy_router' from an isolated per-node env.
start_node(Name, Idx, PrivDir, Cookie, ExtraEnv) ->
    DataDir = filename:join(PrivDir, atom_to_list(Name)),
    ok = filelib:ensure_dir(filename:join(DataDir, ".keep")),
    %% Match the controller's host (and thus its short/long name domain) so the
    %% peer can start distribution; a literal "127.0.0.1" would force a longname
    %% under a shortnames controller and the peer would exit with
    %% `nodistribution'.
    PeerOpts = #{
        name => Name,
        host => controller_host(),
        connection => standard_io,
        args => ["-setcookie", Cookie, "-pa" | codepath()]
    },
    %% `peer:start/1' (not `start_link/1'): the peers must outlive the
    %% `init_per_suite' process that starts them and survive across testcases.
    %% The `peer'-spawned control process owns the stdio channel, so the nodes
    %% still halt cleanly if the controller node dies.
    {ok, Peer, Node} = peer:start(PeerOpts),
    %% The peer is up but not yet booted, and it already holds this index's
    %% peer port. Every later cluster suite reuses that port, so a boot failure
    %% that left the node running would make all of them fail to bind.
    try
        %% `peer_boot/1' runs on the peer, so make sure this module is loaded
        %% there.
        {?MODULE, Bin, File} = code:get_object_code(?MODULE),
        {module, ?MODULE} =
            erpc:call(Node, code, load_binary, [?MODULE, File, Bin]),
        Env0 = node_env(DataDir, 18086 + Idx),
        Env = lists:foldl(
            fun({Path, Value}, Acc) -> key_value:set(Path, Value, Acc) end,
            Env0,
            ExtraEnv
        ),
        ok = erpc:call(Node, ?MODULE, peer_boot, [Env], 60000),
        {Name, Node, Peer}
    catch
        Class:Reason:Stacktrace ->
            try
                peer:stop(Peer)
            catch
                _:_ -> ok
            end,
            erlang:raise(Class, Reason, Stacktrace)
    end.

%% @private
%% The host part of the controller's node name (e.g. "myhost" for
%% `runner@myhost'). Peers are created on this host so they share the
%% controller's short/long name domain.
controller_host() ->
    case string:split(atom_to_list(node()), "@") of
        [_, Host] -> Host;
        _ -> "localhost"
    end.

%% @private
%% Per-node override of ?ENV: isolated data dirs (so leveled / the bondy_db
%% `main' store don't collide or lock each other), a unique Partisan
%% listen port, all client listeners disabled (irrelevant to AAE and would
%% clash across same-host nodes), and bondy_db AAE enabled with a fast tick.
node_env(DataDir, PeerPort) ->
    E0 = key_value:set(
        [eleveldb, data_root], filename:join(DataDir, "leveldb"), ?ENV
    ),
    E1 = key_value:set([bondy_router, platform_data_dir], DataDir, E0),
    %% `platform_tmp_dir` per peer, not just `platform_data_dir`: it is where
    %% `bondy_listener_manager:admin_local_spec/0` puts the internal control
    %% socket, and that listener is injected UNCONDITIONALLY on every node. `?ENV`
    %% derives the directory from `os:getpid()`, which is evaluated in THIS VM, so
    %% every peer would otherwise bind `bondy_admin.sock` at the same path as the
    %% runner and as each other — and the driver unlinks a stale socket file
    %% before binding, so the last node to boot silently takes the path away from
    %% the others. Verified directly: without this line
    %% `bondy_admin_listener_SUITE:admin_local_socket_is_bound_and_serves` fails
    %% with `econnrefused` in a full `rebar3 ct` run, when a cluster suite has
    %% booted peers before it, while passing in isolation.
    %%
    %% SHORT and absolute, keyed on `PeerPort` (unique per peer) rather than
    %% nested under `DataDir`: a Unix domain socket path has a hard length limit
    %% of about 104 bytes on this platform, and a peer's `DataDir` sits deep
    %% inside the Common Test log tree, so `<DataDir>/tmp/bondy_admin.sock`
    %% overflows it and the bind fails with `{listen_error, admin_local, einval}`
    %% — verified directly, that is what this line looked like before it was
    %% shortened. `/tmp` with an `os:getpid()` namespace is the same shape
    %% `bondy_listener_SUITE`'s `init_per_suite/1` already uses.
    TmpDir = filename:join(
        "/tmp",
        "bondy_ct_" ++ os:getpid() ++ "_" ++ integer_to_list(PeerPort)
    ),
    ok = filelib:ensure_path(TmpDir),
    E1b = key_value:set([bondy_router, platform_tmp_dir], TmpDir, E1),
    E2 = key_value:set([partisan, peer_port], PeerPort, E1b),
    %% No CLIENT listeners on a peer node: they are irrelevant to AAE and
    %% would clash on every port with the primary node's, which share this
    %% host. Setting the inventory to a non-empty list is what puts a peer on
    %% the CONFIGURED path rather than the legacy one, and on that path
    %% `bondy_listener_manager' always adds the reserved `admin' listener —
    %% every peer gets one whether this list mentions it or not. `admin' is
    %% declared explicitly here, at `port => 0', for exactly that reason:
    %% left out, the manager's own default binds it at the fixed port 18081,
    %% and every peer on this host then races for that one port. Verified
    %% directly — `bondy_aae_cluster_SUITE' aborts `init_per_suite' with
    %% `eaddrinuse' without this entry, on the second peer to reach it.
    %%
    %% `ordering_probe_tls' exercises the ordering `bondy_config:init/1'
    %% depends on between `splat_listener_blocks/0' and
    %% `bondy_listener_manager:init/0': its certificate lives nested inside this
    %% inventory entry, so it reaches both
    %% `bondy_listener_config:assert_tls_keys/3' and
    %% `bondy_config:listener_transport_opts/2' — what ranch actually uses to
    %% bind — only after the splat has copied it out. Reordering those two calls
    %% makes every peer boot abort with `{missing, [tls, certfile]}'. Both
    %% listeners bind `port => 0`, so peers sharing this host never collide on
    %% either, and the certificate files are the ones every other TLS listener in
    %% this module's `?ENV' already reads.
    E3 = key_value:set(
        [bondy_router, listeners],
        [
            {admin, #{
                transport => tcp,
                protocol => http,
                port => 0,
                start_phase => early,
                services => [admin_api, wamp_ws, admin, metrics]
            }},
            {ordering_probe_tls, #{
                transport => tls,
                protocol => wamp_rawsocket,
                port => 0,
                tls => #{
                    certfile => "./etc/ssl/server/keycert.pem",
                    keyfile => "./etc/ssl/server/key.pem",
                    cacertfile => "./etc/ssl/server/cacert.pem"
                }
            }}
        ],
        E2
    ),
    E4 = key_value:set([bondy_oplog, aae_enabled], true, E3),
    E5 = key_value:set([bondy_oplog, sync_interval_ms], 200, E4),
    E6 = key_value:set([bondy_oplog, aae_fanout], 3, E5),
    %% Cluster suites assert on CONVERGENCE, not on scheduler politeness, so
    %% disable the adaptive live-sync throttle. With it on, a shard that goes
    %% quiescent is polled only every `live_sync_max_ms` (5s), and under the
    %% load of a full CT run — many namespaces, all competing for a node-wide
    %% cap of 3 concurrent sessions — a single namespace can wait long enough
    %% to blow even a generous convergence deadline. That produced an
    %% intermittent `wait_eq_timeout` in `bondy_aae_cluster_SUITE` that never
    %% reproduced when the suite ran alone.
    E7 = key_value:set([bondy_oplog, live_sync_adaptive], false, E6),
    %% More slots so no namespace queues behind the cap. This does NOT raise
    %% the node-wide page ceiling: `aae_pages_per_round` is
    %% `aae_max_pages_in_flight div aae_max_concurrency`, so more concurrency
    %% means smaller batches, not more memory.
    key_value:set([bondy_oplog, aae_max_concurrency], 8, E7).

%% @private
%% Joins every node to the first one. Partisan's full-membership strategy
%% gossips the membership so all nodes converge to the whole set.
form_cluster([{_, First, _} | Rest]) ->
    lists:foreach(
        fun({_, Node, _}) -> ok = join(Node, First, []) end,
        Rest
    ),
    ok;
form_cluster(_) ->
    ok.

%% @private
%% Polls every node's Partisan membership until each sees at least `Expected'
%% members (membership includes the local node), or fails after `Timeout' ms.
wait_for_members(Nodes, Expected, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_members_loop(Nodes, Expected, Deadline).

%% @private
wait_for_members_loop(Nodes, Expected, Deadline) ->
    Converged = lists:all(
        fun({_, Node, _}) ->
            case rpc:call(Node, partisan_peer_service, members, []) of
                {ok, Members} -> length(Members) >= Expected;
                _ -> false
            end
        end,
        Nodes
    ),
    case Converged of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    Status = [
                        {Node,
                            rpc:call(
                                Node, partisan_peer_service, members, []
                            )}
                     || {_, Node, _} <- Nodes
                    ],
                    error({cluster_membership_timeout, Status});
                false ->
                    timer:sleep(250),
                    wait_for_members_loop(Nodes, Expected, Deadline)
            end
    end.

%% =============================================================================
%% AAE FRESHNESS-FENCE TEST HELPERS
%% =============================================================================
%% Shared by the auth suites that exercise the `db.aae` freshness fence
%% (`bondy_auth_oauth2_SUITE`, `bondy_auth_password_SUITE`). They drive the
%% per-shard AE freshness atomics and the no-peer certification seam directly,
%% so a single-node suite can assert fence behaviour without a real cluster and
%% without tick-timing races.

-doc """
Reset every primary shard on this node to the "infinitely stale" sentinel, so
a fence assertion starts from a known-stale baseline.
""".
-spec aae_reset_all_stale() -> ok.

aae_reset_all_stale() ->
    lists:foreach(
        fun(NS) ->
            lists:foreach(
                fun(E) -> ok = bondy_oplog_core_registry:reset_stale_ae(E) end,
                bondy_oplog_core_registry:primary_shards_for(NS)
            )
        end,
        bondy_oplog_core_registry:namespaces()
    ).

-doc """
Drive the scheduler's no-peer freshness path for every running instance — the
exact function the sync scheduler invokes at its no-peer seam. Whether it
certifies freshness depends on `db.aae.fence.on_isolation` and whether the
node looks solo (see `aae_mock_nonsolo_membership/0`).
""".
-spec aae_bump_isolated_all() -> ok.

aae_bump_isolated_all() ->
    lists:foreach(
        fun(I) -> ok = bondy_oplog_sync_session:maybe_bump_ae_isolated(I) end,
        bondy_oplog:list_instances()
    ).

-doc """
Mock the Partisan membership so this single test node looks like one member of a
two-node cluster whose peer is unreachable: NOT solo (so the `on_isolation`
policy actually applies), and — since `partisan:nodes/0` really returns [] here
— not a connected majority either. The ghost peer is a node atom, so any sync
the scheduler attempts against it over the in-VM transport is rejected outright
(`{error, {invalid_peer_for_inline_transport, _}}`) and cannot falsely certify
freshness. Pair with `aae_unmock_nonsolo_membership/0` in an `after` clause.
""".
-spec aae_mock_nonsolo_membership() -> ok.

aae_mock_nonsolo_membership() ->
    ok = meck:new(partisan_peer_service, [passthrough, no_link]),
    ok = meck:expect(partisan_peer_service, members, fun() ->
        {ok, [node(), 'ghost@127.0.0.1']}
    end),
    ok.

-doc """
Undo `aae_mock_nonsolo_membership/0`.
""".
-spec aae_unmock_nonsolo_membership() -> ok.

aae_unmock_nonsolo_membership() ->
    try
        meck:unload(partisan_peer_service)
    catch
        _:_ -> ok
    end,
    ok.
