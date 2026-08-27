%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_prometheus).
-moduledoc """
We follow the Prometheus metric and label naming practices described at
<https://prometheus.io/docs/practices/naming/>.
""".
-include_lib("kernel/include/logger.hrl").
-include_lib("prometheus/include/prometheus.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

%% API
-export([report/0]).
-export([report_dropped/2]).

%% TELEMETRY HANDLERS
-export([handle_wamp_message/4]).
-export([handle_net_event/4]).
-export([handle_registry_event/4]).
-export([handle_rpc_latency/4]).
-export([handle_lifecycle_event/4]).
-export([handle_partisan_event/4]).
-export([days_duration_buckets/0]).
-export([hours_duration_buckets/0]).
-export([minutes_duration_buckets/0]).
-export([seconds_duration_buckets/0]).
-export([milliseconds_duration_buckets/0]).
-export([microseconds_duration_buckets/0]).

-export([setup/0]).

%% =============================================================================
%% API
%% =============================================================================

report() ->
    prometheus_text_format:format().

-doc """
Records a message or event Bondy declined to deliver.

`Reason` is the cause (e.g. `shed` when dropped by load shedding) and
`Family` the class of dropped work (e.g. `subscription` for a dropped
subscription meta event). Safe to call before the metric is declared;
errors are swallowed so callers stay total.
""".
-spec report_dropped(Reason :: atom(), Family :: atom()) -> ok.

report_dropped(Reason, Family) when is_atom(Reason) andalso is_atom(Family) ->
    try
        prometheus_counter:inc(bondy_wamp_dropped_total, [Reason, Family])
    catch
        _:_ ->
            ok
    end.

days_duration_buckets() ->
    [0, 1, 2, 3, 4, 5, 10, 15, 30].

hours_duration_buckets() ->
    [0, 1, 2, 3, 4, 5, 10, 12, 24, 48, 72].

minutes_duration_buckets() ->
    [0, 1, 2, 3, 4, 5, 10, 15, 30].

seconds_duration_buckets() ->
    [0, 1, 2, 3, 4, 5, 10, 15, 20, 25, 30, 60, 90, 180, 300, 600, 1800, 3600].

milliseconds_duration_buckets() ->
    [
        0,
        1,
        2,
        5,
        10,
        15,
        25,
        50,
        75,
        100,
        150,
        200,
        250,
        300,
        400,
        500,
        750,
        1000,
        1500,
        2000,
        2500,
        3000,
        4000,
        5000
    ].

microseconds_duration_buckets() ->
    [
        10,
        25,
        50,
        100,
        250,
        500,
        1000,
        2500,
        5000,
        10000,
        25000,
        50000,
        100000,
        250000,
        500000,
        1000000,
        2500000,
        5000000,
        10000000
    ].

%% =============================================================================
%% SETUP
%% =============================================================================

-doc """
Declares every metric family this node exposes, attaches the telemetry
sinks and registers the Prometheus collectors. Called once at boot by
`bondy_app`; idempotent.
""".
-spec setup() -> ok.

setup() ->
    ok = declare_wamp_metrics(),
    ok = declare_message_families(),
    ok = declare_net_session_families(),
    ok = declare_rib_families(),
    ok = declare_partisan_families(),
    %% All event-driven metrics are captured inline in the emitting
    %% process (bondy_telemetry) and sunk into bondy_metrics by the
    %% handlers below. Attaching is idempotent.
    _ = telemetry:attach(
        {?MODULE, wamp_message},
        [bondy, wamp, message],
        fun ?MODULE:handle_wamp_message/4,
        undefined
    ),
    _ = telemetry:attach_many(
        {?MODULE, net_events},
        [
            [bondy, socket, open],
            [bondy, socket, closed],
            [bondy, socket, error],
            [bondy, socket, ping_rtt],
            [bondy, session, opened],
            [bondy, session, closed],
            [bondy, wamp, hello],
            [bondy, session_manager, open],
            [bondy, session_manager, cleanup],
            [bondy, router, flow],
            [bondy, broker, publish],
            [bondy, wamp, egress],
            [bondy, registry, ptrie, cas_retry],
            [bondy, registry, ptrie, cas_exhausted]
        ],
        fun ?MODULE:handle_net_event/4,
        undefined
    ),
    _ = telemetry:attach(
        {?MODULE, registry_events},
        [bondy, registry, event],
        fun ?MODULE:handle_registry_event/4,
        undefined
    ),
    _ = telemetry:attach(
        {?MODULE, rpc_latency},
        [bondy, rpc, latency],
        fun ?MODULE:handle_rpc_latency/4,
        undefined
    ),
    _ = telemetry:attach_many(
        {?MODULE, lifecycle_events},
        [
            [bondy, realm, event],
            [bondy, user, event]
        ],
        fun ?MODULE:handle_lifecycle_event/4,
        undefined
    ),
    %% Partisan inter-node telemetry (doc_extras/telemetry.md). Only the events
    %% Bondy's overlay actually emits are attached — the HyParView, Thicket
    %% (interior_load) and causal-messaging events never fire under the
    %% pluggable manager + full-membership + Plumtree defaults.
    _ = telemetry:attach_many(
        {?MODULE, partisan_events},
        [
            [partisan, connection, client, connect],
            [partisan, socket, server, handshake],
            [partisan, connection, client, heartbeat],
            [partisan, connection, server, heartbeat],
            [partisan, connection, up],
            [partisan, connection, down],
            [partisan, channel, connections],
            [partisan, membership, changed]
        ],
        fun ?MODULE:handle_partisan_event/4,
        undefined
    ),
    ok = bondy_prometheus_cowboy_collector:setup(),
    ok = bondy_prometheus_db:setup(),
    %% Required for prometheus_vm_msacc_collector to report anything.
    _ = erlang:system_flag(microstate_accounting, true),
    Collectors = [
        prometheus_vm_memory_collector,
        prometheus_vm_statistics_collector,
        prometheus_vm_system_info_collector,
        prometheus_vm_msacc_collector,
        bondy_prometheus_collector
    ],
    _ = [prometheus_registry:register_collector(C) || C <- Collectors],
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

declare_wamp_metrics() ->
    _ = prometheus_counter:declare([
        {name, bondy_rate_limited_total},
        {help,
            <<"The total number of inbound requests denied by the inbound rate limiter, by class (handshake | auth | connection | message).">>},
        {labels, [class]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_rpc_promise_timeouts_total},
        {help,
            <<"The total number of RPC promises evicted on expiry (the caller received a WAMP timeout error), by promise type.">>},
        {labels, [type]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_dropped_total},
        {help, <<
            "Messages or events Bondy declined to deliver, by reason "
            "(e.g. shed = dropped by load shedding) and family "
            "(e.g. the meta-event family that was dropped)."
        >>},
        {labels, [reason, family]}
    ]),
    ok.

%% @private
%% Declares the per-message families captured wait-free via
%% `bondy_metrics` (see `handle_wamp_message/4`) and rendered at scrape
%% time by `bondy_prometheus_collector`. The per-type counter families
%% keep their historical names and label sets.
declare_message_families() ->
    ok = bondy_metrics:declare(#{
        name => bondy_wamp_messages_total,
        help =>
            <<"The total number of wamp messages routed by a bondy node since reset.">>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_wamp_message_bytes,
        help => <<
            "A histogram of the wire size (encoded frame bytes) of the "
            "wamp messages sent and received by a bondy node"
        >>
    }),
    lists:foreach(
        fun(Type) ->
            {Name, _} = message_type_family(Type),
            Bin = atom_to_binary(Type, utf8),
            ok = bondy_metrics:declare(#{
                name => Name,
                help =>
                    <<"The total number of ", Bin/binary,
                        " messages routed by a bondy node since reset.">>
            })
        end,
        [
            abort,
            authenticate,
            call,
            cancel,
            challenge,
            error,
            event,
            goodbye,
            hello,
            interrupt,
            invocation,
            publish,
            published,
            register,
            registered,
            result,
            subscribe,
            subscribed,
            unregister,
            unregistered,
            unsubscribe,
            unsubscribed,
            welcome,
            yield
        ]
    ).

%% @private
%% Declares the registry RIB routing families, captured wait-free via
%% `bondy_metrics` at their population sites: the dealer (retry and
%% owner-side completion), `bondy_registry_rib` (occupancy and damping)
%% and `bondy_registry` (presence and the divergence sweep).
declare_rib_families() ->
    ok = bondy_metrics:declare(#{
        name => bondy_rpc_rib_retries_total,
        help => <<
            "Pre-invocation retries of cluster CALLs after an owner-side "
            "completion miss, by outcome: node (re-routed to another "
            "node), local (absorbed by a local registration), exhausted "
            "(no candidate, budget or time left — the error was final)."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_rpc_rib_completions_total,
        help => <<
            "Owner-side completions of node-addressed cluster CALLs, by "
            "outcome (ok | miss)."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_registry_rib_members,
        help => <<
            "Live local registry entries feeding this node's replicated "
            "routing summaries."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_registry_rib_stub_cells,
        help => <<
            "Remote routing summary stubs held by this node, by registry "
            "type."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_registry_rib_damping_suppressions_total,
        help => <<
            "Routing summary updates suppressed by the damping window "
            "(count/latest-only changes coalesced into a trailing write)."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_registry_rib_divergences,
        help => <<
            "Keys where the routing summaries disagree with the ground "
            "truth, as of the last periodic consistency sweep."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_registry_projection_miss_total,
        help => <<
            "Index entries resolved by bondy_registry_store:project/2 whose "
            "backing record was already gone from the local entry table. "
            "Expected under concurrent subscribe/unsubscribe churn (the "
            "subscriber left between the index snapshot and the resolve); "
            "a sustained high rate relative to publish throughput may "
            "warrant investigation, but any single occurrence is not a bug."
        >>
    }).

%% @private
%% Declares the inter-node (Partisan) families sunk from Partisan's telemetry
%% by `handle_partisan_event/4`. All are node-wide; the emitting node is the
%% scrape `node` label, the remote is `peer`.
declare_partisan_families() ->
    ok = bondy_metrics:declare(#{
        name => bondy_cluster_peer_rtt_milliseconds,
        help => <<
            "Inter-node Partisan heartbeat round-trip time, by peer, channel "
            "and side (client|server)."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_cluster_peer_send_pending_bytes,
        help => <<
            "Bytes queued to send but not yet flushed to the kernel on the "
            "Partisan peer socket — send backpressure — by peer, channel, side."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_cluster_connect_latency_milliseconds,
        help => <<
            "Latency of an outbound Partisan connection attempt (including TLS "
            "handshake), by result (ok|error)."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_cluster_tls_handshake_milliseconds,
        help => <<
            "Latency of an inbound Partisan TLS handshake, by result; a spike "
            "in result=error is the slowloris signal."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_cluster_connection_up_total,
        help => <<"Partisan connections established, by peer and channel.">>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_cluster_connection_down_total,
        help => <<
            "Partisan connections torn down, by peer, channel and exit reason."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_cluster_channel_connections,
        help => <<
            "Current Partisan connection count for a peer/channel; below the "
            "target it is under-provisioned."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_cluster_channel_connections_target,
        help => <<
            "Configured target connection count (parallelism) for a "
            "peer/channel."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_cluster_membership_changes_total,
        help => <<
            "Partisan membership changes, by direction (added|removed)."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_cluster_membership_size,
        help => <<"Current Partisan cluster member count.">>
    }).

%% @private
%% Declares the socket and session families captured wait-free via
%% `bondy_metrics` (see `handle_net_event/4`). Names are historical;
%% `bondy_sessions_closed_total` gains the `reason` label (the WAMP
%% close reason URI).
declare_net_session_families() ->
    ok = bondy_metrics:declare(#{
        name => bondy_sockets_total,
        help => <<"The number of active sockets on a bondy node.">>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_sockets_opened_total,
        help => <<"The number of sockets opened on a bondy node since reset.">>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_sockets_closed_total,
        help => <<"The number of sockets closed on a bondy node since reset.">>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_socket_errors_total,
        help => <<"The number of socket errors on a bondy node since reset.">>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_socket_duration_seconds,
        help => <<"A histogram of the duration of a socket.">>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_sessions_total,
        help => <<"The number of active sessions on a bondy node.">>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_sessions_opened_total,
        help => <<"The number of sessions opened on a bondy node since reset.">>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_sessions_closed_total,
        help => <<
            "The number of sessions closed on a bondy node since reset, "
            "by WAMP close reason."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_session_duration_seconds,
        help => <<"A histogram of the duration of a session.">>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_registry_events_total,
        help => <<
            "Registration and subscription lifecycle events routed by this "
            "node, by type, action and realm."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_wamp_call_latency_milliseconds,
        help => <<
            "A histogram of routed RPC response latencies: the time between "
            "the dealer processing a WAMP call message and the first response "
            "(WAMP result or error). Includes router and callee time; compare "
            "with bondy_wamp_invocation_latency_milliseconds to attribute."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_wamp_invocation_latency_milliseconds,
        help => <<
            "A histogram of INVOCATION to YIELD/ERROR latencies (callee "
            "execution plus transport). The difference against "
            "bondy_wamp_call_latency_milliseconds is router overhead."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_realm_events_total,
        help =>
            <<"Realm lifecycle events (created | updated | deleted), by realm.">>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_user_events_total,
        help => <<
            "User lifecycle events (added | updated | deleted | "
            "credentials_updated), by realm."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_ping_rtt_milliseconds,
        help => <<
            "A histogram of round-trip times of router-initiated "
            "transport-level pings, by protocol and transport."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_wamp_hello_duration_microseconds,
        help => <<
            "A histogram of the in-process time spent handling a WAMP HELLO "
            "on the connection process: realm lookup, auth context build and "
            "(when no challenge is required) the full session open up to the "
            "encoded WELCOME."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_session_manager_open_queue_microseconds,
        help => <<
            "A histogram of the time a session open request waited in a "
            "session manager pool worker's mailbox before being served. High "
            "values mean opens are queued behind other worker work (e.g. "
            "crashed-session cleanup)."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_session_manager_open_service_microseconds,
        help => <<
            "A histogram of the time a session manager pool worker spent "
            "serving a session open (store, monitor, procedure registration)."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_session_manager_cleanup_microseconds,
        help => <<
            "A histogram of the time a session manager pool worker spent on "
            "session teardown, by kind (down | close | error). This work "
            "shares the worker mailbox with session opens."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_router_flow_queue_microseconds,
        help => <<
            "A histogram of the time a task waited in a router flow pool "
            "worker's mailbox before executing, by family (router = "
            "submitted by a local connection process, relay = dispatched by "
            "the relay ingress). Ordered flows cannot convert queue depth "
            "into throughput, so sustained growth here is delivery latency "
            "every event behind it will pay."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_router_flow_service_microseconds,
        help => <<
            "A histogram of the execution time of a router flow pool task "
            "(e.g. a PUBLISH: authorize, match and fan out), by family "
            "(router | relay). Pool throughput is bounded by pool size "
            "divided by this duration."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_router_flow_queue_depth,
        help => <<
            "A histogram of a router flow pool worker's mailbox depth at the "
            "moment it dequeued a task, recorded for RELAY INGRESS only. "
            "Those tasks are delivered straight into the mailbox by a peer "
            "and carry no local dispatch timestamp, so "
            "bondy_router_flow_queue_microseconds records nothing for them — "
            "which left the pool's only data-plane role unobservable. A flow "
            "is FIFO on its worker, so depth x service estimates the wait "
            "every message behind this one pays. Sustained growth here is "
            "cross-node delivery latency."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_wamp_egress_queue_depth,
        help => <<
            "A histogram of a subscriber connection process's mailbox depth "
            "at the moment it dequeued an outbound WAMP message, by "
            "transport. Router deliveries arrive as a plain send carrying no "
            "dispatch timestamp, so depth is the backlog signal here, exactly "
            "as it is for relay ingress. A connection process is FIFO on its "
            "mailbox, so depth x service estimates the wait every message "
            "behind this one pays. This is the LAST hop before the wire: a "
            "delivery tail absent from match, fanout and relay ingress but "
            "present here is egress."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_wamp_egress_service_microseconds,
        help => <<
            "A histogram of the in-process time a subscriber connection "
            "process spent handling one outbound WAMP message, by transport. "
            "For WebSocket this is the ENCODE only — cowboy performs the "
            "socket write after the handler callback returns. For transports "
            "whose handler calls Transport:send itself the write is included."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_broker_publish_match_microseconds,
        help => <<
            "A histogram of the time a PUBLISH spent finding matching "
            "subscriptions in the registry, measured inline in the "
            "publisher's connection process. Grows with subscription count "
            "and pattern breadth, not with fanout."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_broker_publish_fanout_microseconds,
        help => <<
            "A histogram of the time a PUBLISH spent delivering: a send per "
            "local subscriber plus one relayed PUBLISH per peer node holding "
            "one. Together with the match histogram this splits publish cost "
            "into lookup vs delivery; a delivery tail that is NOT visible in "
            "either is downstream (relay ingress queueing — see "
            "bondy_router_flow_queue_microseconds — or the subscriber's own "
            "connection process)."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_registry_ptrie_cas_retries_total,
        help => <<
            "Registry pattern-index (ptrie) write rounds lost to a "
            "concurrent writer's root CAS and retried. All pattern writes "
            "of a realm contend on one root per (type, policy), so a "
            "sustained rate here is the trigger for pattern-broadcast "
            "sharding (see _design/REGISTRY_PARTITION_GRAIN.md). Zero on "
            "the uncontended fast path."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_registry_ptrie_cas_exhausted_total,
        help => <<
            "Registry pattern-index (ptrie) writes that exhausted their "
            "CAS retry budget and failed. A safety valve against "
            "pathological livelock — any non-zero value is an incident."
        >>
    }).

%% @private
%% Telemetry sink for the socket and session events emitted by
%% `bondy_telemetry`. Same discipline as `handle_wamp_message/4`:
%% wait-free `bondy_metrics` writes only, total.
handle_net_event([bondy, registry, ptrie, Outcome], Meas, _Meta, _Config) when
    Outcome == cas_retry orelse Outcome == cas_exhausted
->
    try
        Name =
            case Outcome of
                cas_retry -> bondy_registry_ptrie_cas_retries_total;
                cas_exhausted -> bondy_registry_ptrie_cas_exhausted_total
            end,
        ok = bondy_metrics:counter(#{
            name => Name,
            label => #{node => node_name()},
            delta => maps:get(count, Meas, 1)
        })
    catch
        _:_ ->
            ok
    end;
handle_net_event([bondy, socket, ping_rtt], Meas, Meta, _Config) ->
    try
        bondy_metrics:histogram(#{
            name => bondy_ping_rtt_milliseconds,
            label => #{
                node => node_name(),
                protocol => maps:get(protocol, Meta, undefined),
                transport => maps:get(transport, Meta, undefined)
            },
            value => maps:get(duration, Meas, 0)
        }),
        ok
    catch
        _:_ ->
            ok
    end;
handle_net_event([bondy, socket, Action], Meas, Meta, _Config) ->
    try
        Labels = #{
            node => node_name(),
            protocol => maps:get(protocol, Meta, undefined),
            transport => maps:get(transport, Meta, undefined)
        },
        case Action of
            open ->
                ok = bondy_metrics:counter(#{
                    name => bondy_sockets_opened_total, label => Labels
                }),
                ok = bondy_metrics:gauge(#{
                    name => bondy_sockets_total, label => Labels, delta => 1
                });
            closed ->
                ok = bondy_metrics:counter(#{
                    name => bondy_sockets_closed_total, label => Labels
                }),
                ok = bondy_metrics:gauge(#{
                    name => bondy_sockets_total, label => Labels, delta => -1
                }),
                ok = bondy_metrics:histogram(#{
                    name => bondy_socket_duration_seconds,
                    label => Labels,
                    value => maps:get(duration, Meas, 0)
                });
            error ->
                %% No gauge decrement here: every error-class termination
                %% also emits [bondy, socket, closed] (which decrements),
                %% so decrementing on error too would drift the gauge
                %% negative — one extra decrement per errored socket.
                ok = bondy_metrics:counter(#{
                    name => bondy_socket_errors_total, label => Labels
                })
        end
    catch
        _:_ ->
            ok
    end;
handle_net_event([bondy, session, Action], Meas, Meta, _Config) ->
    try
        Labels = #{
            realm => maps:get(realm, Meta, undefined),
            node => node_name()
        },
        case Action of
            opened ->
                ok = bondy_metrics:counter(#{
                    name => bondy_sessions_opened_total, label => Labels
                }),
                ok = bondy_metrics:gauge(#{
                    name => bondy_sessions_total, label => Labels, delta => 1
                });
            closed ->
                ok = bondy_metrics:counter(#{
                    name => bondy_sessions_closed_total,
                    label => Labels#{
                        reason => maps:get(reason, Meta, undefined)
                    }
                }),
                ok = bondy_metrics:gauge(#{
                    name => bondy_sessions_total, label => Labels, delta => -1
                }),
                ok = bondy_metrics:histogram(#{
                    name => bondy_session_duration_seconds,
                    label => Labels,
                    value => maps:get(duration, Meas, 0)
                })
        end
    catch
        _:_ ->
            ok
    end;
handle_net_event([bondy, wamp, hello], Meas, _Meta, _Config) ->
    try
        bondy_metrics:histogram(#{
            name => bondy_wamp_hello_duration_microseconds,
            label => #{node => node_name()},
            value => maps:get(duration, Meas, 0)
        }),
        ok
    catch
        _:_ ->
            ok
    end;
handle_net_event([bondy, session_manager, open], Meas, _Meta, _Config) ->
    try
        Labels = #{node => node_name()},
        ok = bondy_metrics:histogram(#{
            name => bondy_session_manager_open_queue_microseconds,
            label => Labels,
            value => maps:get(queue, Meas, 0)
        }),
        ok = bondy_metrics:histogram(#{
            name => bondy_session_manager_open_service_microseconds,
            label => Labels,
            value => maps:get(service, Meas, 0)
        })
    catch
        _:_ ->
            ok
    end;
handle_net_event([bondy, router, flow], Meas, Meta, _Config) ->
    try
        Labels = #{
            node => node_name(),
            family => maps:get(family, Meta, undefined)
        },
        %% The queue measurement is absent for tasks delivered straight
        %% into the worker mailbox by a remote peer (no local dispatch
        %% timestamp); recording a zero would fake a perfect queue.
        ok =
            case Meas of
                #{queue := Queue} ->
                    bondy_metrics:histogram(#{
                        name => bondy_router_flow_queue_microseconds,
                        label => Labels,
                        value => Queue
                    });
                _ ->
                    ok
            end,
        ok = bondy_metrics:histogram(#{
            name => bondy_router_flow_service_microseconds,
            label => Labels,
            value => maps:get(service, Meas, 0)
        }),
        %% Depth is present only for relay ingress, where no queue wait can be
        %% measured (the task arrives from a peer with no local dispatch
        %% timestamp). It is the substitute backlog signal for the flow pool's
        %% only data-plane role.
        ok =
            case Meas of
                #{depth := Depth} ->
                    bondy_metrics:histogram(#{
                        name => bondy_router_flow_queue_depth,
                        label => Labels,
                        value => Depth
                    });
                _ ->
                    ok
            end
    catch
        _:_ ->
            ok
    end;
handle_net_event([bondy, wamp, egress], Meas, Meta, _Config) ->
    try
        Labels = #{
            node => node_name(),
            transport => maps:get(transport, Meta, undefined)
        },
        ok = bondy_metrics:histogram(#{
            name => bondy_wamp_egress_service_microseconds,
            label => Labels,
            value => maps:get(service, Meas, 0)
        }),
        ok = bondy_metrics:histogram(#{
            name => bondy_wamp_egress_queue_depth,
            label => Labels,
            value => maps:get(depth, Meas, 0)
        })
    catch
        _:_ ->
            ok
    end;
handle_net_event([bondy, broker, publish], Meas, _Meta, _Config) ->
    try
        Labels = #{node => node_name()},
        ok = bondy_metrics:histogram(#{
            name => bondy_broker_publish_match_microseconds,
            label => Labels,
            value => maps:get(match, Meas, 0)
        }),
        ok = bondy_metrics:histogram(#{
            name => bondy_broker_publish_fanout_microseconds,
            label => Labels,
            value => maps:get(fanout, Meas, 0)
        })
    catch
        _:_ ->
            ok
    end;
handle_net_event([bondy, session_manager, cleanup], Meas, Meta, _Config) ->
    try
        bondy_metrics:histogram(#{
            name => bondy_session_manager_cleanup_microseconds,
            label => #{
                node => node_name(),
                kind => maps:get(kind, Meta, undefined)
            },
            value => maps:get(duration, Meas, 0)
        }),
        ok
    catch
        _:_ ->
            ok
    end;
handle_net_event(_, _, _, _) ->
    ok.

%% @private
%% Telemetry sink for `[bondy, realm, event]` and `[bondy, user, event]`
%% (emitted by `bondy_telemetry:realm_event/2` / `user_event/3`). Same
%% discipline as the other sinks: wait-free `bondy_metrics` writes only,
%% total.
handle_lifecycle_event([bondy, Subject, event], _Meas, Meta, _Config) ->
    try
        Name =
            case Subject of
                realm -> bondy_realm_events_total;
                user -> bondy_user_events_total
            end,
        bondy_metrics:counter(#{
            name => Name,
            label => #{
                node => node_name(),
                realm => maps:get(realm, Meta, undefined),
                action => maps:get(action, Meta, undefined)
            }
        }),
        ok
    catch
        _:_ ->
            ok
    end;
handle_lifecycle_event(_, _, _, _) ->
    ok.

%% @private
%% Telemetry sink for Partisan's inter-node events (doc_extras/telemetry.md).
%% Wait-free `bondy_metrics` writes only. `node` is omitted from every label —
%% it is the emitting node and comes from the Prometheus scrape target; `peer`
%% is the remote (`peer_node`). Values are already integers from Partisan.
handle_partisan_event(
    [partisan, connection, Side, heartbeat], Meas, Meta, _
) when
    Side == client orelse Side == server
->
    Label = #{
        peer => maps:get(peer_node, Meta, undefined),
        channel => maps:get(channel, Meta, undefined),
        side => Side
    },
    _ = bondy_metrics:histogram(#{
        name => bondy_cluster_peer_rtt_milliseconds,
        label => Label,
        value => pint(maps:get(latency, Meas, 0))
    }),
    _ = bondy_metrics:gauge(#{
        name => bondy_cluster_peer_send_pending_bytes,
        label => Label,
        value => pint(maps:get(send_pend, Meas, 0))
    }),
    ok;
handle_partisan_event([partisan, connection, client, connect], Meas, Meta, _) ->
    _ = bondy_metrics:histogram(#{
        name => bondy_cluster_connect_latency_milliseconds,
        label => #{result => maps:get(result, Meta, undefined)},
        value => pint(maps:get(latency, Meas, 0))
    }),
    ok;
handle_partisan_event([partisan, socket, server, handshake], Meas, Meta, _) ->
    _ = bondy_metrics:histogram(#{
        name => bondy_cluster_tls_handshake_milliseconds,
        label => #{result => maps:get(result, Meta, undefined)},
        value => pint(maps:get(latency, Meas, 0))
    }),
    ok;
handle_partisan_event([partisan, connection, up], Meas, Meta, _) ->
    _ = bondy_metrics:counter(#{
        name => bondy_cluster_connection_up_total,
        label => #{
            peer => maps:get(peer_node, Meta, undefined),
            channel => maps:get(channel, Meta, undefined)
        },
        delta => pint(maps:get(count, Meas, 1))
    }),
    ok;
handle_partisan_event([partisan, connection, down], Meas, Meta, _) ->
    _ = bondy_metrics:counter(#{
        name => bondy_cluster_connection_down_total,
        label => #{
            peer => maps:get(peer_node, Meta, undefined),
            channel => maps:get(channel, Meta, undefined),
            reason => maps:get(reason, Meta, undefined)
        },
        delta => pint(maps:get(count, Meas, 1))
    }),
    ok;
handle_partisan_event([partisan, channel, connections], Meas, Meta, _) ->
    Label = #{
        peer => maps:get(peer_node, Meta, undefined),
        channel => maps:get(channel, Meta, undefined)
    },
    _ = bondy_metrics:gauge(#{
        name => bondy_cluster_channel_connections,
        label => Label,
        value => pint(maps:get(size, Meas, 0))
    }),
    case maps:get(target, Meas, undefined) of
        Target when is_integer(Target) ->
            _ = bondy_metrics:gauge(#{
                name => bondy_cluster_channel_connections_target,
                label => Label,
                value => Target
            });
        _ ->
            ok
    end,
    ok;
handle_partisan_event([partisan, membership, changed], Meas, _Meta, _) ->
    Added = pint(maps:get(added, Meas, 0)),
    Removed = pint(maps:get(removed, Meas, 0)),
    Added > 0 andalso
        bondy_metrics:counter(#{
            name => bondy_cluster_membership_changes_total,
            label => #{direction => added},
            delta => Added
        }),
    Removed > 0 andalso
        bondy_metrics:counter(#{
            name => bondy_cluster_membership_changes_total,
            label => #{direction => removed},
            delta => Removed
        }),
    _ = bondy_metrics:gauge(#{
        name => bondy_cluster_membership_size,
        value => pint(maps:get(total, Meas, 0))
    }),
    ok;
handle_partisan_event(_, _, _, _) ->
    ok.

%% @private
%% Coerce a telemetry measurement to a non-negative integer for bondy_metrics.
pint(V) when is_integer(V) andalso V >= 0 -> V;
pint(V) when is_number(V) andalso V >= 0 -> trunc(V);
pint(_) -> 0.

%% @private
%% Telemetry sink for `[bondy, rpc, latency]` (emitted by
%% `bondy_telemetry:rpc_latency/4` at the dealer's promise-settlement
%% sites). `kind` selects the family: `call` = full round trip,
%% `invocation` = INVOCATION→YIELD leg. Same discipline as the other
%% sinks: wait-free `bondy_metrics` writes only, total.
handle_rpc_latency(_EventName, Meas, Meta, _Config) ->
    try
        Name =
            case maps:get(kind, Meta, call) of
                invocation -> bondy_wamp_invocation_latency_milliseconds;
                _ -> bondy_wamp_call_latency_milliseconds
            end,
        bondy_metrics:histogram(#{
            name => Name,
            label => #{
                node => node_name(),
                procedure_uri => maps:get(procedure_uri, Meta, undefined)
            },
            value => maps:get(duration, Meas, 0)
        }),
        ok
    catch
        _:_ ->
            ok
    end.

%% @private
%% Telemetry sink for `[bondy, registry, event]` (emitted by
%% `bondy_telemetry:registry_event/3`) — the unconditional aggregate of
%% registration/subscription lifecycle actions, counted whether or not
%% the corresponding WAMP meta event was demanded. Same discipline as
%% the other sinks: wait-free `bondy_metrics` writes only, total.
handle_registry_event(_EventName, _Meas, Meta, _Config) ->
    try
        bondy_metrics:counter(#{
            name => bondy_registry_events_total,
            label => #{
                node => node_name(),
                realm => maps:get(realm, Meta, undefined),
                type => maps:get(type, Meta, undefined),
                action => maps:get(action, Meta, undefined)
            }
        }),
        ok
    catch
        _:_ ->
            ok
    end.

%% @private
%% Telemetry sink for `[bondy, wamp, message]` (emitted by
%% `bondy_telemetry:wamp_message/2`). Runs inline in the emitting
%% process, so it only performs wait-free `bondy_metrics` writes and is
%% total — a failure here must never affect routing (and would otherwise
%% permanently detach the handler).
handle_wamp_message(_EventName, Measurements, Meta, _Config) ->
    try
        Labels = #{
            realm_type => maps:get(realm_type, Meta, undefined),
            node => node_name(),
            protocol => maps:get(protocol, Meta, wamp),
            transport => maps:get(transport, Meta, undefined),
            frame_type => maps:get(frame_type, Meta, undefined),
            encoding => maps:get(encoding, Meta, undefined)
        },
        ok = bondy_metrics:counter(#{
            name => bondy_wamp_messages_total, label => Labels
        }),
        %% `size` (wire bytes) is only measured at transport boundaries;
        %% internal emitters omit it rather than skew the histogram with
        %% zeros.
        ok =
            case Measurements of
                #{size := Size} ->
                    bondy_metrics:histogram(#{
                        name => bondy_wamp_message_bytes,
                        label => Labels,
                        value => Size
                    });
                _ ->
                    ok
            end,
        case message_type_family(maps:get(type, Meta, undefined)) of
            undefined ->
                ok;
            {Name, undefined} ->
                bondy_metrics:counter(#{name => Name, label => Labels});
            {Name, UriLabel} ->
                bondy_metrics:counter(#{
                    name => Name,
                    label => Labels#{UriLabel => maps:get(uri, Meta, undefined)}
                })
        end
    catch
        _:_ ->
            ok
    end.

%% @private
%% Maps a WAMP message type to its counter family and, for the families
%% that carry one, the URI label name.
message_type_family(abort) ->
    {bondy_wamp_abort_messages_total, undefined};
message_type_family(authenticate) ->
    {bondy_wamp_authenticate_messages_total, undefined};
message_type_family(call) ->
    {bondy_wamp_call_messages_total, procedure_uri};
message_type_family(cancel) ->
    {bondy_wamp_cancel_messages_total, undefined};
message_type_family(challenge) ->
    {bondy_wamp_challenge_messages_total, undefined};
message_type_family(error) ->
    {bondy_wamp_error_messages_total, error_uri};
message_type_family(event) ->
    {bondy_wamp_event_messages_total, undefined};
message_type_family(goodbye) ->
    {bondy_wamp_goodbye_messages_total, undefined};
message_type_family(hello) ->
    {bondy_wamp_hello_messages_total, undefined};
message_type_family(interrupt) ->
    {bondy_wamp_interrupt_messages_total, undefined};
message_type_family(invocation) ->
    {bondy_wamp_invocation_messages_total, undefined};
message_type_family(publish) ->
    {bondy_wamp_publish_messages_total, topic_uri};
message_type_family(published) ->
    {bondy_wamp_published_messages_total, undefined};
message_type_family(register) ->
    {bondy_wamp_register_messages_total, procedure_uri};
message_type_family(registered) ->
    {bondy_wamp_registered_messages_total, undefined};
message_type_family(result) ->
    {bondy_wamp_result_messages_total, undefined};
message_type_family(subscribe) ->
    {bondy_wamp_subscribe_messages_total, topic_uri};
message_type_family(subscribed) ->
    {bondy_wamp_subscribed_messages_total, undefined};
message_type_family(unregister) ->
    {bondy_wamp_unregister_messages_total, undefined};
message_type_family(unregistered) ->
    {bondy_wamp_unregistered_messages_total, undefined};
message_type_family(unsubscribe) ->
    {bondy_wamp_unsubscribe_messages_total, undefined};
message_type_family(unsubscribed) ->
    {bondy_wamp_unsubscribed_messages_total, undefined};
message_type_family(welcome) ->
    {bondy_wamp_welcome_messages_total, undefined};
message_type_family(yield) ->
    {bondy_wamp_yield_messages_total, undefined};
message_type_family(_) ->
    undefined.

%% @private
node_name() ->
    bondy_config:node().
