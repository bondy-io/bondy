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

-export([is_ready/0]).
-export([prep_stop/1]).
-export([start/2]).
-export([status/0]).
-export([stop/0]).
-export([stop/1]).
-export([vsn/0]).

-ifdef(TEST).
-export([peer_plane_gate/1]).
%% The degraded-boot branch cannot be reached through `start/2` without a
%% real storage substrate and a poisoned data directory; exposing the
%% dispatch lets the branch be pinned directly.
-export([start_services/1]).
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

-doc """
Whether this node should be sent traffic.

The single readiness oracle: `bondy_admin_ready_http_handler` (`/ready`) and
the `bondy_node_ready` Prometheus gauge both answer from here, so a load
balancer and a dashboard cannot disagree about the same node.

Three independent conditions, each read from exactly one source:

1. **Boot finished.** `start_normal_listeners/0` sets the status to `ready`
   once the client listeners are up. On a degraded boot
   (`start_services(failed)`) that step never runs, so the status stays
   `initialising`.
2. **The durable `main` DB opened.** Read from
   `bondy_namespace_catalog:main_status/0`, NOT from the alarm that mirrors
   it: the status is `persistent_term`-backed and survives an
   `alarm_handler` crash, the alarm set does not (`bondy_event_handler_watcher`
   re-installs the handler with `[]` and `bondy_alarm_handler:init/1` then
   starts empty). Only `failed` disqualifies; `idle` means there was nothing
   to provision, a legitimate configuration.
3. **No alarm asks for the node to be drained.** Any active alarm carrying
   `affects_ready => true`. This is a per-alarm declaration and not a severity
   threshold — see `bondy_alarm_handler`.

A degraded boot fails the first two conditions; the second is what keeps the
answer right should boot ever be allowed to complete on a failed store.
Pinned end-to-end by `bondy_degraded_boot_SUITE` (a poisoned `main`
directory and a healthy control node).
""".
-spec is_ready() -> boolean().

is_ready() ->
    bondy_config:get(status, undefined) == ready andalso
        bondy_namespace_catalog:main_status() =/= failed andalso
        not bondy_alarm_handler:affects_ready().

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

    %% Load every module of every application loaded so far, BEFORE the
    %% supervisor can start anything that decodes wire bytes with
    %% `binary_to_term/2` `[safe]' (the bridge relay, both ends — a
    %% configured bridge dials from bondy_bridge_relay_manager's
    %% handle_continue, i.e. during bondy_sup startup). `[safe]' refuses
    %% atoms absent from the atom table, and the interactive code loader
    %% interns a module's atoms only when the module loads: measured on
    %% a fresh edge node, the bridge server's own cryptosign CHALLENGE
    %% bounced on `channel_binding', and since the decode failure
    %% precedes any interning, every reconnect bounced identically. In a
    %% release this covers every release app: the generated start.script
    %% runs all `application:load' instructions before the first
    %% `start_boot' (verified on 1.0.0-rc-sunlight). Falsifier:
    %% `bondy_bridge_relay_rpc_SUITE:boot_loads_every_app_module'.
    ok = ensure_app_modules_loaded(),

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
                ok ?= start_services(bondy_namespace_catalog:main_status()),
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
    %% The `early' listeners, which `prep_stop/1' deliberately left running so
    %% that liveness, readiness and metrics kept answering for the whole grace
    %% period. Nothing is left to drain by the time this runs, so releasing
    %% their sockets — and, for the internal admin listener, unlinking its
    %% socket file — is the last thing to do rather than the first.
    ok = bondy_listener_manager:stop(early),
    ?LOG_NOTICE(#{description => "Shutdown finished"}),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% See the call site in start/2 for why. A module that fails to load
%% keeps its atoms out of the atom table, silently reinstating the
%% `[safe]'-refusal hazard for terms naming them — logged rather than
%% fatal, because an unloadable module in an otherwise working node is
%% not worth refusing to boot over.
ensure_app_modules_loaded() ->
    Modules = lists:append([
        Mods
     || {App, _, _} <- application:loaded_applications(),
        {ok, Mods} <- [application:get_key(App, modules)]
    ]),
    case code:ensure_modules_loaded(Modules) of
        ok ->
            ok;
        {error, Errors} ->
            ?LOG_WARNING(#{
                description =>
                    "Some application modules failed to load. Atoms "
                    "named only by those modules are not interned, so "
                    "peer messages carrying them will be refused by "
                    "[safe] wire decodes (e.g. the bridge relay).",
                errors => Errors
            }),
            ok
    end.

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
%% Brings up everything above the storage substrate, in one of two shapes
%% depending on whether the durable `main` DB opened.
%%
%% `failed` is the degraded boot. `bondy_namespace_catalog:open_main_into/1`
%% deliberately keeps the catalogue alive on a main-DB open failure so an
%% operator can inspect the node, and `bondy_admin_ready_http_handler` already
%% answers 503 for as long as `main_status/0` is `failed`. Terminating the
%% application here would take that whole diagnostic surface down with it —
%% which is what used to happen: `configure_services/0` raises
%% `bondy_realm_table_unavailable` on its first `bondy_realm:get/1`, escaping
%% `start/2` and killing the VM.
%%
%% The degraded path therefore starts exactly what serves the liveness and
%% readiness probes, and nothing else. That is the rule for where a new boot
%% step belongs — NOT "does it touch durable tables", which is not true of
%% every step skipped here: `init_registry_indices/0` rebuilds from the
%% registry tables, which are provisioned independently of `main` and can be
%% healthy while it is not. A node serving no traffic simply has no use for
%% them.
%%
%% So the degraded path starts the early listeners and stops. Those serve
%% `/ping` and `/ready`, and `bondy_config:get(status)` is left at
%% `initialising` because only `start_normal_listeners/0` promotes it to
%% `ready` — so the readiness probe reports NOT READY on both of its
%% conditions, and no client listener ever opens.
start_services(failed) ->
    ?LOG_ERROR(#{
        description =>
            "The durable main store is unavailable, so the node is booting "
            "in a degraded state: no realms are configured and no client "
            "listeners are started. Only the early-phase listeners come up, "
            "so the node stays inspectable and reports NOT READY. Resolve "
            "the main-store failure and restart.",
        main_status => failed
    }),
    start_early_listeners();
start_services(_) ->
    maybe
        ok ?= configure_services(),
        ok ?= init_registry_indices(),
        ok ?= setup_wamp_subscriptions(),
        ok ?= start_early_listeners(),
        %% Started BEFORE the normal-phase listeners bind: a listener
        %% declaring the `mcp' service must not accept a request while the
        %% application that answers it is down. And not in the early phase
        %% either — an MCP endpoint has nothing to say before the router is
        %% ready, and a degraded boot (`start_services(failed)`) never gets
        %% here.
        {ok, _} = application:ensure_all_started(bondy_mcp, permanent),
        %% Finally we allow clients to connect
        ok ?= start_normal_listeners(),
        {ok, _} = application:ensure_all_started(
            bondy_http_connector, permanent
        ),
        %% Realm inheritance is a router concept and bondy_mail sits
        %% below the router in the dependency graph, so it is told
        %% which module resolves a realm's prototype rather than
        %% calling into one directly.
        ok = application:set_env(bondy_mail, realm_module, bondy_realm),
        ok = application:set_env(
            bondy_mail, master_realm_uri, ?MASTER_REALM_URI
        ),
        %% Dormant unless a `mail.relay.*` is configured: it starts,
        %% supervises nothing, and the bondy.mail.* procedures report
        %% that mail is not configured.
        {ok, _} = application:ensure_all_started(bondy_mail, permanent),
        %% Started here as well as by the release boot script, so that
        %% it also runs under CT and `rebar3 shell`. Every bridge
        %% defaults to disabled, so this starts a manager with no
        %% subscribers unless one is configured.
        {ok, _} = application:ensure_all_started(
            bondy_broker_bridge, permanent
        ),
        ok
    end.

%% @private
configure_services() ->
    ok = bondy_message_id:init(),

    %% Every step below reads and writes the durable realm tables, so it is
    %% gated on the `main` DB actually being open. When the catalogue stood
    %% up with main idle after a storage-open failure (see
    %% `bondy_namespace_catalog:open_main_into/1`) a raise here would return
    %% `{error, _}` from `bondy_app:start/2` and HALT THE VM — turning the
    %% catalogue's documented degraded posture (alarm raised, readiness
    %% probe NOT READY, ephemeral registry alive for inspection) into a
    %% crash loop. Exercised by `bondy_degraded_boot_SUITE`.
    case bondy_namespace_catalog:main_status() of
        open ->
            ?LOG_NOTICE(#{
                description =>
                    "Configuring master and user realms from configuration "
                    "file"
            }),
            %% We use bondy_realm:get/1 to force the creation of the bondy
            %% admin realm if it does not exist.
            _ = bondy_realm:get(?MASTER_REALM_URI),
            %% Idempotent one-shot hardening for installs provisioned before
            %% the master-realm hardening (D-1/D-2). No-op on fresh installs.
            ok = bondy_realm:harden_master_realm(),
            ok = bondy_realm:apply_config(),
            ok = bondy_http_gateway:apply_config();
        Status ->
            ?LOG_ERROR(#{
                description =>
                    "Skipping realm, security and API gateway "
                    "configuration; the durable main database is not open. "
                    "The node is running DEGRADED: durable operations will "
                    "fail and the readiness probe reports NOT READY.",
                main_status => Status
            }),
            ok
    end.

%% @private
init_registry_indices() ->
    %% The rebuild sweeps stale per-realm entries out of the EPHEMERAL
    %% registry store and needs the durable realm table to enumerate the
    %% realms. With `main` not open there is nothing durable to reconcile —
    %% the ephemeral store is fresh on this boot — and the exit below would
    %% halt the VM, so the degraded node skips it (same posture as
    %% `configure_services/0`; exercised by `bondy_degraded_boot_SUITE`).
    case bondy_namespace_catalog:main_status() of
        open ->
            case bondy_registry:init_indices() of
                ok ->
                    ok;
                {error, Reason} ->
                    exit(Reason)
            end;
        Status ->
            ?LOG_ERROR(#{
                description =>
                    "Skipping registry index initialisation; the durable "
                    "main database is not open.",
                main_status => Status
            }),
            ok
    end.

%% @private
%% Listeners marked `start_phase => early' come up first so the liveness
%% (`/ping'), readiness (`/ready') and metrics paths answer while
%% `bondy_config:get(status)' is still `initialising'.
start_early_listeners() ->
    %% The inventory was resolved during `bondy_config:init/1', which had to
    %% happen there because `bondy_cert_manager:init/0' and `setup_wamp/0' both
    %% consume it.
    ?LOG_NOTICE(#{description => "Starting early-phase listeners"}),
    bondy_listener_manager:start(early).

%% @private
start_normal_listeners() ->
    ?LOG_NOTICE(#{description => "Starting listeners"}),

    %% WAMP in-VM (local) transport: register the router-side adapter so a
    %% co-located bondy_connect_sdk client can use `transport => local'. On a peer
    %% node (no bondy app) no handler is registered and local is unavailable.
    ok = bondy_connect_local:register_handler(bondy_connect_local_handler),

    ok = bondy_listener_manager:start(normal),

    %% We flag the status, the HTTP /ready path will now return true.
    ok = bondy_config:set(status, ready),

    %% Bondy Router Bridge Relay (client) connections
    bondy_bridge_relay_manager:start_bridges().

%% @private
setup_event_handlers() ->
    %% We replace the default OTP signal handler with ours
    _ = gen_event:swap_handler(
        erl_signal_server,
        {erl_signal_handler, []},
        {bondy_signal_handler, []}
    ),

    %% We replace the default OTP alarm handler with ours. The old handler's
    %% terminate argument must be `swap`: that is the clause of
    %% `sasl/src/alarm_handler.erl:terminate/2` that returns
    %% `{alarm_handler, Alarms}` for the new handler's `init/1` to adopt.
    %% `normal` returns `ok`, silently dropping every alarm raised before
    %% this point in the boot — `bondy_db_main_unavailable` among them, which
    %% the namespace catalogue raises from its own `init/1` under `bondy_sup`.
    _ = bondy_event_manager:swap_watched_handler(
        alarm_handler, {alarm_handler, swap}, {bondy_alarm_handler, []}
    ),

    %% An event handler that republishes some internal events to WAMP
    _ = bondy_event_manager:add_watched_handler(
        bondy_event_wamp_publisher, []
    ),

    %% Metrics no longer ride the gen_event bus: bondy_prometheus (in
    %% bondy_telemetry_exporter, whose start runs its setup) declares
    %% families, attaches telemetry sinks and registers the Prometheus
    %% collectors. Started HERE — like bondy_mcp in `start_services/1`, also by the
    %% release boot script so it runs under CT and `rebar3 shell` too —
    %% because the sinks must attach before any listener binds: the
    %% socket/session gauges pair open/close deltas, so an open missed
    %% while a later close is counted would drift them negative.
    {ok, _} = application:ensure_all_started(
        bondy_telemetry_exporter, permanent
    ),

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
    %% We stop accepting new connections on the client-facing listeners.
    %% Existing connections are unaffected.
    %%
    %% The NORMAL phase only. `early' is the phase that carries `/ping',
    %% `/ready' and `/metrics', and this runs at the START of a drain that then
    %% sleeps for the whole grace period: suspending those paths would make an
    %% orchestrator read the draining node as dead and hard-kill it, which is
    %% the outcome the grace period exists to avoid. `stop/1' takes them down
    %% once the drain is over.
    ?LOG_NOTICE(#{
        description =>
            "Suspending the normal-phase listeners. No new connections will be "
            "accepted from now on; the readiness and metrics endpoints stay up "
            "for the duration of the drain."
    }),
    bondy_listener_manager:suspend(normal).

stop_listeners() ->
    %% We force the client-facing listeners to stop.
    %% All existing connections will be terminated.
    ?LOG_NOTICE(#{description => "Terminating all client connections."}),
    ok = bondy_listener_manager:stop(normal),
    bondy_connect_local:unregister_handler().

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
