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
            [bondy, session, closed]
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
            <<"The total number of inbound requests denied by the AV-1 rate limiter, by class (handshake | auth | connection | message).">>},
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
        help =>
            <<"A histogram of the size of the wamp messages received by a bondy node">>
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
    }).

%% @private
%% Telemetry sink for the socket and session events emitted by
%% `bondy_telemetry`. Same discipline as `handle_wamp_message/4`:
%% wait-free `bondy_metrics` writes only, total.
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
%% Telemetry sink for `[bondy, rpc, latency]` (emitted by
%% `bondy_telemetry:rpc_latency/3` at the dealer's promise-settlement
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
        ok = bondy_metrics:histogram(#{
            name => bondy_wamp_message_bytes,
            label => Labels,
            value => maps:get(size, Measurements, 0)
        }),
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

node_name() ->
    bondy_config:node().

%% @private
