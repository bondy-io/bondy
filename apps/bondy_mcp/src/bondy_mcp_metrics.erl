%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_mcp_metrics).

-moduledoc """
MCP gateway telemetry (design §15): the emission helpers, the
`:telemetry` event contract, and the Prometheus sink.

The capture discipline is the node-wide one (`bondy_telemetry`,
`bondy_prometheus`): the hot path emits a `telemetry:execute/3` event
unconditionally — so operators can attach tracing, audit forwarding or
APM handlers without code changes — and this module's own attached
handler sinks each event into wait-free `bondy_metrics` families,
rendered at scrape time by `bondy_prometheus_collector` (which renders
exactly the families declared here via `bondy_metrics:declare/1`).

Emitters and sink clauses are both total: a telemetry handler that
raises is detached permanently by `telemetry`, so every sink clause
try/catches, and every emitter swallows its own failure — metrics are
never allowed to take a request down.

Cardinality (§15.2): `realm`, `listener`, `status`, `reason`, `type`,
`kind`, `trigger`, `surface` and `upstream` are bounded (operator
inventory or closed enums). `name` is bounded by the manifest and rides
the call/read counters; on the duration histograms it is opt-in via
`mcp.metrics.label_by_name` (default off, aggregated to realm level).
Two labels are client-controlled and therefore sanitized BY THE CALLER
before emission: `version` (a known protocol revision or `other` —
`bondy_mcp_http_handler` owns the known set) and `method` (a method the
dispatcher knows or `other`, sanitized here against `?KNOWN_METHODS`).
`principal`, `session_id` and `user` are never labels (§15.2) — they
belong to event metadata and the audit record only.

Durations are recorded in microseconds (`_microseconds` families):
`bondy_metrics` histograms are integer log-linear, matching the node's
existing duration families, so §15.1's `_seconds` names are realized at
microsecond grain.
""".

-include_lib("kernel/include/logger.hrl").

-define(HANDLER_ID, {?MODULE, sink}).

%% The dispatcher's method vocabulary (both eras). A method outside it is
%% labelled `other` — the value is client-controlled, so an unknown
%% method must not mint a Prometheus series. A method added to
%% `bondy_mcp_http_handler` without extending this list shows up as
%% `other`, which is visible and harmless.
-define(KNOWN_METHODS, [
    <<"initialize">>,
    <<"ping">>,
    <<"tools/list">>,
    <<"tools/call">>,
    <<"resources/list">>,
    <<"resources/templates/list">>,
    <<"resources/read">>,
    <<"resources/subscribe">>,
    <<"resources/unsubscribe">>,
    <<"subscriptions/listen">>
]).

-export([setup/0]).

-export([session_opened/2]).
-export([session_closed/3]).
-export([tool_call/6]).
-export([resource_read/6]).
-export([resource_subscribed/2]).
-export([notification_emitted/3]).
-export([rbac_denied/3]).
-export([version_refused/2]).
-export([request_stop/3]).
-export([call_inflight/3]).
-export([manifest_rebuild/4]).
-export([manifest_conflict/3]).
-export([upstream_call/4]).
-export([upstream_drift_blocked/2]).

%% Telemetry callback
-export([handle_event/4]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Declares this app's metric families and attaches the sink handler.
Idempotent — called from `bondy_mcp_app:start/2`. Requires the
`bondy_metrics` tables (started well before this app: its gen_server is
a `bondy_oplog_sup` child, and `bondy_oplog` precedes `bondy_router`,
which starts `bondy_mcp` mid-boot).
""".
-spec setup() -> ok.

setup() ->
    ok = declare_families(),
    _ = telemetry:detach(?HANDLER_ID),
    ok = telemetry:attach_many(
        ?HANDLER_ID,
        [
            [bondy, mcp, session, open],
            [bondy, mcp, session, close],
            [bondy, http_transport, session, closed],
            [bondy, mcp, tool, call, stop],
            [bondy, mcp, resource, read, stop],
            [bondy, mcp, resource, subscribe],
            [bondy, mcp, notification, emit],
            [bondy, mcp, rbac, denied],
            [bondy, mcp, version, refused],
            [bondy, mcp, request, stop],
            [bondy, mcp, call, inflight],
            [bondy, mcp, manifest, rebuild, stop],
            [bondy, mcp, manifest, conflict],
            [bondy, mcp, upstream, call, stop],
            [bondy, mcp, upstream, drift_blocked]
        ],
        fun ?MODULE:handle_event/4,
        undefined
    ).

%% =============================================================================
%% API — emitters (total: a metrics failure never fails the caller)
%% =============================================================================

-doc "A handshake-era session was created (`initialize`).".
-spec session_opened(binary(), atom()) -> ok.

session_opened(Realm, Listener) ->
    execute(
        [bondy, mcp, session, open],
        #{count => 1},
        #{realm => Realm, listener => Listener}
    ).

-doc """
A handshake-era session terminated. Fired by this module's own sink for
the transport session's `[bondy, http_transport, session, closed]`
lifecycle event — the single close seat, covering every termination
that runs `terminate/2` (DELETE, idle timeout, stored-session loss,
supervisor shutdown, crash) — so `opened - closed` is a live-session
count and the sink maintains it as the `bondy_mcp_active_sessions`
gauge. `Reason` must already be one of the closed enum's values (see
`mcp_close_reason/1`).
""".
-spec session_closed(binary(), atom(), atom()) -> ok.

session_closed(Realm, Listener, Reason) ->
    execute(
        [bondy, mcp, session, close],
        #{count => 1},
        #{realm => Realm, listener => Listener, reason => Reason}
    ).

-doc """
A dispatched `tools/call` completed; `DurationUs` covers the WAMP call.

`Trace` is the request's SEP-414 trace context — the `traceparent` /
`tracestate` / `baggage` `_meta` entries, binary keys, values verbatim;
`#{}` when the request carried none. It rides the event as the `trace`
metadata key so an attached handler can emit an OpenTelemetry span for
the call retroactively, parented to the client's trace: telemetry
handlers run synchronously in the emitting process, so the handler's
own clock at handle time is the span's end time and `duration` gives
the start. That is the §15.4 span contract — one post-hoc event, no
start/stop pair to orphan on a crash.
""".
-spec tool_call(binary(), atom(), binary(), atom(), non_neg_integer(), map()) ->
    ok.

tool_call(Realm, Listener, Name, Status, DurationUs, Trace) ->
    execute(
        [bondy, mcp, tool, call, stop],
        #{duration => DurationUs},
        #{
            realm => Realm,
            listener => Listener,
            name => Name,
            status => Status,
            trace => Trace
        }
    ).

-doc """
A dispatched `resources/read` completed. `Trace` as in `tool_call/6`.
""".
-spec resource_read(
    binary(), atom(), binary(), atom(), non_neg_integer(), map()
) ->
    ok.

resource_read(Realm, Listener, Name, Status, DurationUs, Trace) ->
    execute(
        [bondy, mcp, resource, read, stop],
        #{duration => DurationUs},
        #{
            realm => Realm,
            listener => Listener,
            name => Name,
            status => Status,
            trace => Trace
        }
    ).

-doc "A resource subscription was honoured (either era).".
-spec resource_subscribed(binary(), binary()) -> ok.

resource_subscribed(Realm, Name) ->
    execute(
        [bondy, mcp, resource, subscribe],
        #{count => 1},
        #{realm => Realm, name => Name}
    ).

-doc "The gateway produced `Count` client notifications of `Type`.".
-spec notification_emitted(binary(), atom(), pos_integer()) -> ok.

notification_emitted(Realm, Type, Count) ->
    execute(
        [bondy, mcp, notification, emit],
        #{count => Count},
        #{realm => Realm, type => Type}
    ).

-doc """
RBAC hid or refused something: `list_filter` (entries projected out of a
list), `call_authz` (a direct call/read on a hidden entry) or
`subscribe_authz` (a subscription on a topic the principal cannot
subscribe to — an as-built extension to §15.1's two-surface enum).
""".
-spec rbac_denied(binary(), atom(), pos_integer()) -> ok.

rbac_denied(Realm, Surface, Count) ->
    execute(
        [bondy, mcp, rbac, denied],
        #{count => Count},
        #{realm => Realm, surface => Surface}
    ).

-doc """
A protocol version this endpoint does not carry was refused (§8).
`Version` MUST already be sanitized by the caller: a revision Bondy
knows, or `other` — never the raw client value.
""".
-spec version_refused(atom(), binary()) -> ok.

version_refused(Listener, Version) ->
    execute(
        [bondy, mcp, version, refused],
        #{count => 1},
        #{listener => Listener, version => Version}
    ).

-doc """
A dispatched request completed; `DurationUs` is the whole gateway-side
handling INCLUDING any WAMP call — §15.1's dispatch-overhead histogram
is realized as total request time, with overhead derivable at the
aggregate level as `request_sum - tool_call_sum` (§21.10).
""".
-spec request_stop(binary(), binary(), non_neg_integer()) -> ok.

request_stop(Realm, Method0, DurationUs) ->
    Method =
        case lists:member(Method0, ?KNOWN_METHODS) of
            true -> Method0;
            false -> <<"other">>
        end,
    execute(
        [bondy, mcp, request, stop],
        #{duration => DurationUs},
        #{realm => Realm, method => Method}
    ).

-doc "In-flight WAMP call accounting; `Delta` is `1` or `-1`.".
-spec call_inflight(binary(), atom(), integer()) -> ok.

call_inflight(Realm, Listener, Delta) ->
    execute(
        [bondy, mcp, call, inflight],
        #{delta => Delta},
        #{realm => Realm, listener => Listener}
    ).

-doc """
A manifest rebuild completed. `Counts` carries the compiled entry
census per kind — the sink writes it as the absolute
`bondy_mcp_manifest_entries` gauge value.
""".
-spec manifest_rebuild(
    binary(), atom(), non_neg_integer(), #{atom() => non_neg_integer()}
) -> ok.

manifest_rebuild(Realm, Trigger, DurationUs, Counts) ->
    execute(
        [bondy, mcp, manifest, rebuild, stop],
        Counts#{duration => DurationUs},
        #{realm => Realm, trigger => Trigger}
    ).

-doc "A rebuild reported `Count` §17 collisions of `Kind`.".
-spec manifest_conflict(binary(), atom(), pos_integer()) -> ok.

manifest_conflict(Realm, Kind, Count) ->
    execute(
        [bondy, mcp, manifest, conflict],
        #{count => Count},
        #{realm => Realm, kind => Kind}
    ).

-doc """
A projected upstream tool call completed (§13, §21.9). `Trace` as in
`tool_call/6` — here it is what rode the upstream request's
`params._meta`, so the operator's span parents to the WAMP caller's
trace.
""".
-spec upstream_call(binary(), atom(), non_neg_integer(), map()) -> ok.

upstream_call(Upstream, Status, DurationUs, Trace) ->
    execute(
        [bondy, mcp, upstream, call, stop],
        #{duration => DurationUs},
        #{upstream => Upstream, status => Status, trace => Trace}
    ).

-doc "`Count` upstream tools were blocked by the §13.3 pin gate.".
-spec upstream_drift_blocked(binary(), pos_integer()) -> ok.

upstream_drift_blocked(Upstream, Count) ->
    execute(
        [bondy, mcp, upstream, drift_blocked],
        #{count => Count},
        #{upstream => Upstream}
    ).

%% =============================================================================
%% TELEMETRY CALLBACK (the Prometheus sink)
%% =============================================================================

handle_event([bondy, mcp, session, open], _Meas, Meta, _Config) ->
    try
        Label = #{
            node => node_name(),
            realm => maps:get(realm, Meta, undefined),
            listener => maps:get(listener, Meta, undefined)
        },
        ok = bondy_metrics:counter(#{
            name => bondy_mcp_session_opened_total,
            label => Label
        }),
        ok = bondy_metrics:gauge(#{
            name => bondy_mcp_active_sessions,
            label => Label,
            delta => 1
        })
    catch
        _:_ ->
            ok
    end;
handle_event([bondy, mcp, session, close], _Meas, Meta, _Config) ->
    try
        Label = #{
            node => node_name(),
            realm => maps:get(realm, Meta, undefined),
            listener => maps:get(listener, Meta, undefined)
        },
        ok = bondy_metrics:counter(#{
            name => bondy_mcp_session_closed_total,
            label => Label#{reason => maps:get(reason, Meta, undefined)}
        }),
        ok = bondy_metrics:gauge(#{
            name => bondy_mcp_active_sessions,
            label => Label,
            delta => -1
        })
    catch
        _:_ ->
            ok
    end;
handle_event([bondy, http_transport, session, closed], _Meas, Meta, _Config) ->
    %% The generic transport session's lifecycle event. Only a session
    %% this gateway registered lifecycle metadata for (bootstrap, AFTER
    %% a successful open) is an MCP session — everything else (WAMP
    %% longpoll/SSE transports, part-initialized bootstraps) is ignored.
    %% Re-emitted as the §15.3 `[bondy, mcp, session, close]` event, so
    %% that contract stays THE MCP close event for external handlers.
    case Meta of
        #{
            metadata := #{mcp := #{realm := Realm, listener := Listener}},
            reason := Reason
        } ->
            session_closed(Realm, Listener, mcp_close_reason(Reason));
        _ ->
            ok
    end;
handle_event([bondy, mcp, tool, call, stop], Meas, Meta, _Config) ->
    try
        sink_dispatched(
            bondy_mcp_tool_calls_total,
            bondy_mcp_tool_call_duration_microseconds,
            Meas,
            Meta
        )
    catch
        _:_ ->
            ok
    end;
handle_event([bondy, mcp, resource, read, stop], Meas, Meta, _Config) ->
    try
        sink_dispatched(
            bondy_mcp_resource_reads_total,
            bondy_mcp_resource_read_duration_microseconds,
            Meas,
            Meta
        )
    catch
        _:_ ->
            ok
    end;
handle_event([bondy, mcp, resource, subscribe], _Meas, Meta, _Config) ->
    try
        ok = bondy_metrics:counter(#{
            name => bondy_mcp_resource_subscribes_total,
            label => #{
                node => node_name(),
                realm => maps:get(realm, Meta, undefined),
                name => maps:get(name, Meta, undefined)
            }
        })
    catch
        _:_ ->
            ok
    end;
handle_event([bondy, mcp, notification, emit], Meas, Meta, _Config) ->
    try
        ok = bondy_metrics:counter(#{
            name => bondy_mcp_notifications_emitted_total,
            label => #{
                node => node_name(),
                realm => maps:get(realm, Meta, undefined),
                type => maps:get(type, Meta, undefined)
            },
            delta => maps:get(count, Meas, 1)
        })
    catch
        _:_ ->
            ok
    end;
handle_event([bondy, mcp, rbac, denied], Meas, Meta, _Config) ->
    try
        ok = bondy_metrics:counter(#{
            name => bondy_mcp_rbac_denied_total,
            label => #{
                node => node_name(),
                realm => maps:get(realm, Meta, undefined),
                surface => maps:get(surface, Meta, undefined)
            },
            delta => maps:get(count, Meas, 1)
        })
    catch
        _:_ ->
            ok
    end;
handle_event([bondy, mcp, version, refused], _Meas, Meta, _Config) ->
    try
        ok = bondy_metrics:counter(#{
            name => bondy_mcp_version_refused_total,
            label => #{
                node => node_name(),
                listener => maps:get(listener, Meta, undefined),
                version => maps:get(version, Meta, undefined)
            }
        })
    catch
        _:_ ->
            ok
    end;
handle_event([bondy, mcp, request, stop], Meas, Meta, _Config) ->
    try
        ok = bondy_metrics:histogram(#{
            name => bondy_mcp_request_duration_microseconds,
            label => #{
                node => node_name(),
                realm => maps:get(realm, Meta, undefined),
                method => maps:get(method, Meta, undefined)
            },
            value => maps:get(duration, Meas, 0)
        })
    catch
        _:_ ->
            ok
    end;
handle_event([bondy, mcp, call, inflight], Meas, Meta, _Config) ->
    try
        ok = bondy_metrics:gauge(#{
            name => bondy_mcp_inflight_calls,
            label => #{
                node => node_name(),
                realm => maps:get(realm, Meta, undefined),
                listener => maps:get(listener, Meta, undefined)
            },
            delta => maps:get(delta, Meas, 0)
        })
    catch
        _:_ ->
            ok
    end;
handle_event([bondy, mcp, manifest, rebuild, stop], Meas, Meta, _Config) ->
    try
        Node = node_name(),
        Realm = maps:get(realm, Meta, undefined),
        ok = bondy_metrics:counter(#{
            name => bondy_mcp_manifest_rebuilds_total,
            label => #{
                node => Node,
                realm => Realm,
                trigger => maps:get(trigger, Meta, undefined)
            }
        }),
        ok = bondy_metrics:histogram(#{
            name => bondy_mcp_manifest_rebuild_duration_microseconds,
            label => #{node => Node, realm => Realm},
            value => maps:get(duration, Meas, 0)
        }),
        lists:foreach(
            fun(Kind) ->
                ok = bondy_metrics:gauge(#{
                    name => bondy_mcp_manifest_entries,
                    label => #{node => Node, realm => Realm, kind => Kind},
                    value => maps:get(Kind, Meas, 0)
                })
            end,
            [tool, resource, resource_template]
        )
    catch
        _:_ ->
            ok
    end;
handle_event([bondy, mcp, manifest, conflict], Meas, Meta, _Config) ->
    try
        ok = bondy_metrics:counter(#{
            name => bondy_mcp_manifest_collisions_total,
            label => #{
                node => node_name(),
                realm => maps:get(realm, Meta, undefined),
                kind => maps:get(kind, Meta, undefined)
            },
            delta => maps:get(count, Meas, 1)
        })
    catch
        _:_ ->
            ok
    end;
handle_event([bondy, mcp, upstream, call, stop], Meas, Meta, _Config) ->
    try
        Node = node_name(),
        Upstream = maps:get(upstream, Meta, undefined),
        ok = bondy_metrics:counter(#{
            name => bondy_mcp_upstream_calls_total,
            label => #{
                node => Node,
                upstream => Upstream,
                status => maps:get(status, Meta, undefined)
            }
        }),
        ok = bondy_metrics:histogram(#{
            name => bondy_mcp_upstream_call_duration_microseconds,
            label => #{node => Node, upstream => Upstream},
            value => maps:get(duration, Meas, 0)
        })
    catch
        _:_ ->
            ok
    end;
handle_event([bondy, mcp, upstream, drift_blocked], Meas, Meta, _Config) ->
    try
        ok = bondy_metrics:counter(#{
            name => bondy_mcp_upstream_drift_blocked_total,
            label => #{
                node => node_name(),
                upstream => maps:get(upstream, Meta, undefined)
            },
            delta => maps:get(count, Meas, 1)
        })
    catch
        _:_ ->
            ok
    end;
handle_event(_, _, _, _) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Counter (name always a label — bounded by the manifest) + duration
%% histogram (name opt-in via `mcp.metrics.label_by_name`, §15.2).
sink_dispatched(CounterName, HistName, Meas, Meta) ->
    Node = node_name(),
    Realm = maps:get(realm, Meta, undefined),
    Status = maps:get(status, Meta, undefined),
    Name = maps:get(name, Meta, undefined),
    ok = bondy_metrics:counter(#{
        name => CounterName,
        label => #{
            node => Node,
            realm => Realm,
            listener => maps:get(listener, Meta, undefined),
            name => Name,
            status => Status
        }
    }),
    HistLabel0 = #{node => Node, realm => Realm, status => Status},
    HistLabel =
        case application:get_env(bondy_mcp, metrics_label_by_name, false) of
            true -> HistLabel0#{name => Name};
            false -> HistLabel0
        end,
    ok = bondy_metrics:histogram(#{
        name => HistName,
        label => HistLabel,
        value => maps:get(duration, Meas, 0)
    }).

%% @private
%% The closed-reason label enum. The inputs are server-side stop tags
%% (never client-controlled), but the label must stay a closed set: a
%% tag added upstream without extending this mapping shows up as
%% `other`, which is visible and harmless. As-built deviations from
%% §15.1's enum: `stored_session_closed` covers both the admin-kill and
%% realm-deletion rows (the liveness-check seat cannot tell them
%% apart), and `server_shutdown` is any supervisor-driven stop
%% (listener stop and node shutdown are indistinguishable at
%% `terminate/2`).
mcp_close_reason(client_close) -> client_close;
mcp_close_reason(idle_timeout) -> idle_timeout;
mcp_close_reason(stored_session_closed) -> stored_session_closed;
mcp_close_reason(shutdown) -> server_shutdown;
mcp_close_reason(crash) -> crash;
mcp_close_reason(_) -> other.

%% @private
node_name() ->
    bondy_config:node().

%% @private
%% Total: the metric plane must never fail the data plane. A failure
%% here is logged at debug (it would repeat per request) and dropped.
execute(Event, Meas, Meta) ->
    try
        telemetry:execute(Event, Meas, Meta)
    catch
        Class:Reason ->
            ?LOG_DEBUG(#{
                description => "MCP telemetry emission failed",
                event => Event,
                class => Class,
                reason => Reason
            }),
            ok
    end.

%% @private
declare_families() ->
    lists:foreach(
        fun({Name, Help}) ->
            ok = bondy_metrics:declare(#{name => Name, help => Help})
        end,
        [
            {bondy_mcp_session_opened_total,
                <<"Handshake-era MCP sessions created by initialize.">>},
            {bondy_mcp_session_closed_total, <<
                "Handshake-era MCP session terminations, by reason, "
                "counted at the transport session's terminate."
            >>},
            {bondy_mcp_active_sessions, <<
                "Handshake-era MCP sessions currently alive "
                "(opened minus closed; resets with the node)."
            >>},
            {bondy_mcp_tool_calls_total,
                <<"Dispatched MCP tools/call requests, by tool and status.">>},
            {bondy_mcp_resource_reads_total, <<
                "Dispatched MCP resources/read requests, by resource "
                "name and status."
            >>},
            {bondy_mcp_resource_subscribes_total,
                <<"Honoured MCP resource subscriptions, by resource name.">>},
            {bondy_mcp_notifications_emitted_total,
                <<"Client notifications produced by the MCP gateway.">>},
            {bondy_mcp_rbac_denied_total, <<
                "MCP requests or list entries RBAC hid or refused, by "
                "surface."
            >>},
            {bondy_mcp_version_refused_total, <<
                "Requests refused for a protocol version the endpoint "
                "does not carry; unknown client values are labelled "
                "'other'."
            >>},
            {bondy_mcp_request_duration_microseconds, <<
                "Whole gateway-side request handling time, including "
                "any underlying WAMP call."
            >>},
            {bondy_mcp_inflight_calls,
                <<"WAMP calls currently in flight on behalf of MCP requests.">>},
            {bondy_mcp_tool_call_duration_microseconds,
                <<"MCP tools/call WAMP-call time, by status.">>},
            {bondy_mcp_resource_read_duration_microseconds,
                <<"MCP resources/read WAMP-call time, by status.">>},
            {bondy_mcp_manifest_rebuilds_total,
                <<"MCP manifest rebuilds, by trigger (demand or db_event).">>},
            {bondy_mcp_manifest_rebuild_duration_microseconds,
                <<"MCP manifest rebuild (compile) time.">>},
            {bondy_mcp_manifest_entries,
                <<"Entries in the served MCP manifest, by kind.">>},
            {bondy_mcp_manifest_collisions_total,
                <<"Name collisions a manifest rebuild reported (design §17).">>},
            {bondy_mcp_upstream_calls_total,
                <<"Projected upstream MCP tool calls, by upstream and status.">>},
            {bondy_mcp_upstream_call_duration_microseconds,
                <<"Projected upstream MCP tool-call round-trip time.">>},
            {bondy_mcp_upstream_drift_blocked_total,
                <<"Upstream tools the definition pin gate blocked (§13.3).">>}
        ]
    ).
