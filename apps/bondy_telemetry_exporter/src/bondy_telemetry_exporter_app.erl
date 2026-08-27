%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_telemetry_exporter_app).

-moduledoc """
OTP application callback for `bondy_telemetry_exporter`.

The OpenTelemetry SDK (the `opentelemetry` application) runs its own
supervision tree and reads its configuration from its application
environment, which the `tracing.*` bondy.conf keys populate via the
cuttlefish schema (`schema/bondy_telemetry_exporter.schema`) — including
`traces_exporter = none` whenever `tracing.otlp.enabled` is off, which
overrides the SDK's own export-to-localhost default. This application
therefore supervises Bondy's own event-consuming handlers and, on
start, runs `bondy_prometheus:setup/0` (metric-family declarations,
telemetry sinks, collector registration).

`bondy_app` starts this application before it binds any listener, so
the Prometheus sinks are attached before the first socket/session event
can fire — the `bondy_sockets_total`/`bondy_sessions_total` gauges
would drift if an open were missed and its close counted.
""".

-behaviour(application).

-export([start/2]).
-export([stop/1]).

%% =============================================================================
%% APPLICATION CALLBACKS
%% =============================================================================

-doc false.
start(_Type, _Args) ->
    ok = bondy_prometheus:setup(),
    bondy_telemetry_exporter_sup:start_link().

-doc false.
stop(_State) ->
    ok.
