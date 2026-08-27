%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_telemetry_exporter_sup).

-moduledoc """
Root supervisor for `bondy_telemetry_exporter`.

Its only child, `bondy_telemetry_exporter_otel` (the telemetry-event →
OpenTelemetry-span bridge), starts only when the OpenTelemetry SDK has
an exporter explicitly configured — `opentelemetry`'s `traces_exporter`
env is set and not `none`, which is exactly what `tracing.otlp.enabled`
writes through the schema. Disabled (or unconfigured) means no
handlers are attached, so traced traffic costs nothing beyond the
events the producers already emit.
""".

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> supervisor:startlink_ret().

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

-doc false.
init([]) ->
    Flags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children =
        case application:get_env(opentelemetry, traces_exporter) of
            {ok, Exporter} when Exporter =/= none ->
                [
                    #{
                        id => bondy_telemetry_exporter_otel,
                        start => {bondy_telemetry_exporter_otel, start_link, []}
                    }
                ];
            _ ->
                []
        end,
    {ok, {Flags, Children}}.
