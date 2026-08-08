%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_app).
-moduledoc """
The `application` behaviour implementation for the Bondy OTP application.

Handles startup and shutdown: initialising configuration, starting
dependencies (`tuplespace`, Partisan, `bondy_db`), the supervision tree and the
network listeners, and tearing them down gracefully on stop.
""".
-behaviour(application).
-include_lib("kernel/include/logger.hrl").
-include("bondy.hrl").

-export([prep_stop/1]).
-export([start/2]).
-export([status/0]).
-export([stop/0]).
-export([stop/1]).
-export([vsn/0]).

-ifdef(TEST).
-export([peer_plane_gate/1]).
-endif.

%% =============================================================================
%% API
%% =============================================================================

-doc """
A convenience function. Calls `init:stop/0`.
""".
stop() ->
    init:stop().

status() ->
    #{
        vsn => vsn(),
        status => bondy_config:get(status)
    }.

-spec vsn() -> list().
vsn() ->
    bondy_config:get(vsn, "undefined").

%% =============================================================================
%% APPLICATION BEHAVIOUR CALLBACKS
%% =============================================================================

-doc """
Application behaviour callback.
""".
start(_Type, Args) ->
    %% We initialise the Bondy config, we need to make this call before
    %% starting tuplespace, partisan and bondy_db. This is because we are
    %% modifying their application environments.
    ok = bondy_config:init(Args),

    %% Now that we have initialised the configuration we start the following
    %% dependencies
    {ok, _} = application:ensure_all_started(tuplespace, permanent),

    %% Start Partisan explicitly: bondy_router owns the cluster transport.
    %% bondy_db is transport-agnostic (it works over disterl or Partisan via
    %% its callbacks). Partisan was configured by bondy_config:init/1 above.
    {ok, _} = application:ensure_all_started(partisan, permanent),

    %% C-1: refuse to boot an auto-clustering node whose peer plane is insecure
    %% (plaintext or `verify_none`) unless the operator acknowledged it via
    %% `cluster.tls.allow_insecure`. Runs before the substrate/listeners start.
    ok = guard_peer_plane(),

    %% When oplog anti-entropy is enabled (off by default) wire the sync
    %% scheduler to Partisan BEFORE the substrate starts, so it reads the
    %% peer source / transport from app env at init.
    ok = maybe_setup_oplog_replication(),

    %% Start the bondy_db storage substrate (pulls in bondy_oplog, bondy_mst and
    %% leveled). Partisan — its cluster transport — is already up, started
    %% explicitly above by bondy_router. Nothing reads from it yet — tables are
    %% opened per-domain by the migration.
    {ok, _} = application:ensure_all_started(bondy_db, permanent),

    %% Now that Partisan is up we can get our nodename
    ok = logger:update_primary_config(#{
        metadata => #{
            node => partisan:node(),
            router_vsn => vsn()
        }
    }),

    %% Finally we start the supervisor
    case bondy_sup:start_link() of
        {ok, Pid} ->
            maybe
                %% Please do not change the order of this function calls
                %% unless, of course, you know exactly what you are doing.
                ok ?= setup_commons(),
                ok ?= bondy_sysmon_handler:add_handler(),
                ok ?= bondy_router_worker:start_pool(),
                ok ?= setup_event_handlers(),
                ok ?= configure_services(),
                ok ?= init_registry_indices(),
                ok ?= setup_wamp_subscriptions(),
                %% We just start the admin API rest listeners [HTTP(S), WS(S)].
                %% This is to enable certain operations during startup i.e.
                %% liveness and readiness http probes.
                ok ?= start_admin_listeners(),
                %% Finally we allow clients to connect
                ok ?= start_public_listeners(),
                {ok, _} = application:ensure_all_started(
                    bondy_http_connector, permanent
                ),
                %% Realm inheritance is a router concept and bondy_mail sits
                %% below the router in the dependency graph, so it is told
                %% which module resolves a realm's prototype rather than
                %% calling into one directly.
                ok = application:set_env(
                    bondy_mail, realm_module, bondy_realm
                ),
                ok = application:set_env(
                    bondy_mail, master_realm_uri, ?MASTER_REALM_URI
                ),
                %% Dormant unless a `mail.relay.*` is configured: it starts,
                %% supervises nothing, and the bondy.mail.* procedures report
                %% that mail is not configured.
                {ok, _} = application:ensure_all_started(
                    bondy_mail, permanent
                ),
                %% Started here as well as by the release boot script, so that
                %% it also runs under CT and `rebar3 shell`. Every bridge
                %% defaults to disabled, so this starts a manager with no
                %% subscribers unless one is configured.
                {ok, _} = application:ensure_all_started(
                    bondy_broker_bridge, permanent
                ),
                {ok, Pid}
            else
                {error, _} = Error ->
                    Error
            end;
        Error ->
            Error
    end.

-doc """
Application behaviour callback.
""".
prep_stop(_State) ->
    ok = bondy_config:set(status, shutting_down),

    ok = suspend_listeners(),

    %% We ask the router to shutdown.
    %% This will send a goodbye to all sessions
    ?LOG_NOTICE(#{
        description => "Shutting down all existing client sessions."
    }),
    ok = bondy_router:pre_stop(),

    %% We sleep for a while to allow all sessions to terminate gracefully
    Secs = bondy_config:get(shutdown_grace_period, 5),
    ?LOG_NOTICE(#{
        description => "Awaiting for client sessions to gracefully terminate",
        timer_secs => Secs
    }),
    ok = timer:sleep(timer:seconds(Secs)),

    %% We remove all session and their registrations and subscriptions, also
    %% broadcasting those to the other nodes.
    ok = bondy_router:stop(),

    ok = maybe_leave(),

    ok = stop_listeners().

-doc """
Application behaviour callback.
""".
stop(_State) ->
    ?LOG_NOTICE(#{description => "Shutdown finished"}),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
setup_commons() ->
    ok.

%% @private
%% C-1 peer-plane safety gate. Reads the effective Partisan config and the
%% `cluster.tls.allow_insecure` acknowledgement, then acts on the verdict:
%% `refuse` aborts startup (fail-closed), `warn` logs prominently and continues.
%% The gate only engages when auto-clustering is configured
%% (`cluster.peer_discovery.enabled`), so solo / dev / test nodes are untouched.
guard_peer_plane() ->
    Input = #{
        clustering => auto_clustering_enabled(),
        tls => partisan_tls_enabled(),
        server_verify => partisan_verify(tls_server_options),
        client_verify => partisan_verify(tls_client_options),
        allow_insecure =>
            bondy_config:get([cluster, tls, allow_insecure], false)
    },
    case peer_plane_gate(Input) of
        ok ->
            ok;
        {warn, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "The cluster peer plane (Partisan) is insecure. An on-path "
                    "attacker can read or modify replicated credentials and "
                    "realm signing keys, and a rogue peer can inject security "
                    "state. Enable cluster.tls with verify_peer and a private "
                    "cluster CA. Proceeding because cluster.tls.allow_insecure "
                    "is on.",
                reason => Reason,
                peer_ip => partisan_peer_ip()
            }),
            ok;
        {refuse, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "Refusing to start: this node is configured to cluster "
                    "(cluster.peer_discovery.enabled) but its Partisan peer "
                    "plane is insecure. Configure cluster.tls.enabled = on with "
                    "cluster.tls.{server,client}.verify = verify_peer and a "
                    "private cluster CA, or set cluster.tls.allow_insecure = on "
                    "to override (NOT recommended off a trusted network).",
                reason => Reason,
                peer_ip => partisan_peer_ip()
            }),
            error({insecure_cluster_peer_plane, Reason})
    end.

%% @private
%% Pure verdict for the peer-plane gate. `clustering` is whether auto-clustering
%% is configured; `tls` whether Partisan TLS is on; `server_verify`/
%% `client_verify` the per-side verify mode; `allow_insecure` the operator
%% acknowledgement. Non-clustering nodes are never gated.
-spec peer_plane_gate(map()) ->
    ok
    | {warn, tls_disabled | verify_none}
    | {refuse, tls_disabled | verify_none}.

peer_plane_gate(#{clustering := false}) ->
    ok;
peer_plane_gate(#{clustering := true} = Input) ->
    #{
        tls := Tls,
        server_verify := SV,
        client_verify := CV,
        allow_insecure := Allow
    } = Input,
    case insecure_reason(Tls, SV, CV) of
        none ->
            ok;
        Reason when Allow == true ->
            {warn, Reason};
        Reason ->
            {refuse, Reason}
    end.

%% @private
insecure_reason(false, _SV, _CV) ->
    tls_disabled;
insecure_reason(true, verify_peer, verify_peer) ->
    none;
insecure_reason(true, _SV, _CV) ->
    verify_none.

%% @private
auto_clustering_enabled() ->
    PeerDiscovery = application:get_env(partisan, peer_discovery, #{}),
    opt(enabled, PeerDiscovery, false) == true.

%% @private
partisan_tls_enabled() ->
    application:get_env(partisan, tls, false) == true.

%% @private
partisan_verify(OptsKey) ->
    Opts = application:get_env(partisan, OptsKey, #{}),
    opt(verify, Opts, verify_none).

%% @private
%% Partisan normalises option groups to maps at runtime, but cuttlefish/sys.config
%% may still present them as proplists — tolerate both.
opt(Key, Opts, Default) when is_map(Opts) ->
    maps:get(Key, Opts, Default);
opt(Key, Opts, Default) when is_list(Opts) ->
    proplists:get_value(Key, Opts, Default);
opt(_Key, _Opts, Default) ->
    Default.

%% @private
partisan_peer_ip() ->
    application:get_env(partisan, peer_ip, undefined).

%% @private
configure_services() ->
    ?LOG_NOTICE(#{
        description =>
            "Configuring master and user realms from configuration file"
    }),

    ok = bondy_message_id:init(),

    %% We use bondy_realm:get/1 to force the creation of the bondy admin realm
    %% if it does not exist.
    _ = bondy_realm:get(?MASTER_REALM_URI),
    %% Idempotent one-shot hardening for installs provisioned before the
    %% master-realm hardening (D-1/D-2). No-op on fresh installs.
    ok = bondy_realm:harden_master_realm(),
    ok = bondy_realm:apply_config(),
    ok = bondy_http_gateway:apply_config().

%% @private
init_registry_indices() ->
    case bondy_registry:init_indices() of
        ok ->
            ok;
        {error, Reason} ->
            exit(Reason)
    end.

%% @private
start_admin_listeners() ->
    %% The /ping (liveness) and /metrics paths will now go live
    %% The /ready (readiness) path will now go live but will return false as
    %% bondy_config:get(status) will return `initialising'
    ?LOG_NOTICE(#{description => "Starting Admin API listeners"}),
    bondy_http_gateway:start_admin_listeners().

%% @private
start_public_listeners() ->
    ?LOG_NOTICE(#{description => "Starting listeners"}),
    %% Now that the registry has been initialised we can initialise
    %% the remaining listeners for clients to connect
    %% WAMP TCP listeners
    ok = bondy_wamp_tcp:start_listeners(),

    %% WAMP Unix domain socket listener (opt-in; no-op unless configured)
    ok = bondy_wamp_uds:start_listeners(),

    %% WAMP in-VM (local) transport: register the router-side adapter so a
    %% co-located bondy_connect client can use `transport => local'. On a peer
    %% node (no bondy app) no handler is registered and local is unavailable.
    ok = bondy_connect_local:register_handler(bondy_connect_local_handler),

    %% WAMP Websocket and REST Gateway HTTP listeners
    %% @TODO We need to separate the /ws path into another listener/port number
    ok = bondy_http_gateway:start_listeners(),

    %% We flag the status, the HTTP /ready path will now return true.
    ok = bondy_config:set(status, ready),

    %% Bondy Router Bridge Relay (server) connection listeners
    ok = bondy_bridge_relay_manager:start_listeners(),

    %% Bondy Router Bridge Relay (client) connections
    ok = bondy_bridge_relay_manager:start_bridges().

%% @private
setup_event_handlers() ->
    %% We replace the default OTP signal handler with ours
    _ = gen_event:swap_handler(
        erl_signal_server,
        {erl_signal_handler, []},
        {bondy_signal_handler, []}
    ),

    %% We replace the default OTP alarm handler with ours
    _ = bondy_event_manager:swap_watched_handler(
        alarm_handler, {alarm_handler, normal}, {bondy_alarm_handler, []}
    ),

    %% An event handler that republishes some internal events to WAMP
    _ = bondy_event_manager:add_watched_handler(
        bondy_event_wamp_publisher, []
    ),

    %% Metrics no longer ride the gen_event bus: bondy_prometheus only
    %% declares families, attaches telemetry sinks and registers the
    %% Prometheus collectors.
    ok = bondy_prometheus:setup(),

    %% Eagerly allocate the meta-event shed-warning cell off the shed path.
    ok = bondy_meta_events:setup(),

    %% We subscribe to partisan up and down events and republish them
    partisan_peer_service:on_up('_', fun(Node) ->
        bondy_event_manager:notify({[bondy, cluster, connection, up], Node})
    end),

    partisan_peer_service:on_down('_', fun(Node) ->
        bondy_event_manager:notify({[bondy, cluster, connection, down], Node})
    end),

    % Used for debugging
    % _ = bondy_event_manager:add_watched_handler(
    %     bondy_event_logger, []
    % ),

    ok.

%% @private
-doc """
Sets up some internal WAMP subscribers. These are processes supervised
by `bondy_subsribers_sup`.
""".
setup_wamp_subscriptions() ->
    ok.

%% @private
%% Wires the bondy_oplog sync scheduler to the Partisan cluster when oplog
%% anti-entropy is enabled (`db.aae`, off by default). Sets the env the
%% scheduler reads at init: peers from live Partisan membership
%% (`bondy_oplog_peer_source_partisan`) and sessions over the Partisan
%% transport on the dedicated AE channel. A no-op when disabled — the
%% scheduler keeps its defaults (static no-peer source + inline transport),
%% so a non-clustered or replication-off node boots exactly as before.
maybe_setup_oplog_replication() ->
    case application:get_env(bondy_oplog, aae_enabled, false) of
        true ->
            Fanout = application:get_env(bondy_oplog, aae_fanout, 3),
            Channel = bondy_config:get(aae_channel),
            ok = application:set_env(
                bondy_oplog, peer_source, bondy_oplog_peer_source_partisan
            ),
            ok = application:set_env(
                bondy_oplog, peer_source_opts, #{count => Fanout}
            ),
            ok = application:set_env(
                bondy_oplog,
                sync_session_opts,
                #{
                    transport => bondy_oplog_transport_partisan,
                    transport_opts => #{channel => Channel}
                }
            ),
            ?LOG_NOTICE(#{
                description =>
                    "Oplog anti-entropy enabled; sync scheduler wired to "
                    "the Partisan transport and membership peer source",
                channel => Channel,
                fanout => Fanout
            }),
            ok;
        false ->
            ok
    end.

suspend_listeners() ->
    %% We stop accepting new connections on all listeners.
    %% Existing connections are unaffected.

    ?LOG_NOTICE(#{
        description =>
            "Suspending HTTP(S) and WS(S) client listeners. "
            "No new connections will be accepted from now on."
    }),
    ok = bondy_http_gateway:suspend_listeners(),

    ?LOG_NOTICE(#{
        description =>
            "Suspending TCP(TLS) client listeners. "
            "No new connections will be accepted from now on."
    }),
    ok = bondy_wamp_tcp:suspend_listeners(),
    ok = bondy_wamp_uds:suspend_listeners(),

    ?LOG_NOTICE(#{
        description =>
            "Suspending Bridge Relay listeners. "
            "No new connections will be accepted from now on."
    }),
    ok = bondy_bridge_relay_manager:suspend_listeners().

stop_listeners() ->
    %% We force all listeners to stop.
    %% All existing connections will be terminated.

    ?LOG_NOTICE(#{
        description =>
            "Terminating all client HTTP(S) and WS(S) client connections."
    }),
    ok = bondy_http_gateway:stop_listeners(),

    ?LOG_NOTICE(#{
        description => "Terminating all TCP(TLS) client connections."
    }),
    ok = bondy_wamp_tcp:stop_listeners(),
    ok = bondy_wamp_uds:stop_listeners(),
    ok = bondy_connect_local:unregister_handler(),

    ?LOG_NOTICE(#{
        description => "Terminating all Bridge Relay connections."
    }),
    ok = bondy_bridge_relay_manager:stop_listeners().

maybe_leave() ->
    case bondy_config:get(automatic_leave, false) of
        true ->
            ?LOG_NOTICE(#{
                description => "Leaving Bondy cluster.",
                automatic_leave => true
            }),
            partisan_peer_service:leave();
        false ->
            ok
    end.
