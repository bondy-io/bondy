%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_telemetry_exporter_SUITE).

-moduledoc """
Application lifecycle tests for `bondy_telemetry_exporter`: the app and
its OpenTelemetry dependency chain start and stop cleanly with the
exporter disabled (`traces_exporter = none`), the shipped default.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [app_starts_and_stops].

init_per_suite(Config) ->
    %% bondy_metrics is a library app: its named gen_server (owner of
    %% the tables bondy_prometheus:setup/0 writes at this app's start)
    %% is hosted by the consumer's supervision tree — bondy_oplog_sup in
    %% a full node. Standalone, this suite is the consumer.
    MetricsStarted =
        case whereis(bondy_metrics) of
            undefined ->
                {ok, Pid} = bondy_metrics:start_link(),
                true = unlink(Pid),
                true;
            _ ->
                false
        end,
    %% A suite that ran earlier on this node may have booted Bondy, and
    %% bondy_app starts bondy_telemetry_exporter — so stop it (and the
    %% SDK, which reads its env only at start) before setting this
    %% suite's posture.
    _ = application:stop(bondy_telemetry_exporter),
    _ = application:stop(opentelemetry),
    %% The disabled posture the schema generates when tracing.otlp.enabled
    %% is off — set BEFORE the SDK starts so its export-to-localhost
    %% default never takes effect in the test run.
    ok = application:set_env(opentelemetry, traces_exporter, none),
    [{metrics_started, MetricsStarted} | Config].

end_per_suite(Config) ->
    case ?config(metrics_started, Config) of
        true ->
            %% This suite hosted the registry, so no booted node needs
            %% the sinks: leave app AND registry stopped (see the otel
            %% suite's end_per_suite for the full rationale — orphan
            %% registry clash / stale declares).
            _ = application:stop(bondy_telemetry_exporter),
            ok = gen_server:stop(bondy_metrics);
        _ ->
            %% A booted node's posture: the sinks belong attached.
            {ok, _} = application:ensure_all_started(
                bondy_telemetry_exporter
            )
    end,
    ok.

app_starts_and_stops(_) ->
    {ok, Started} = application:ensure_all_started(bondy_telemetry_exporter),
    ?assert(lists:member(bondy_telemetry_exporter, Started)),
    %% The OpenTelemetry dependency chain came up with it.
    Running = [A || {A, _, _} <- application:which_applications()],
    ?assert(lists:member(opentelemetry, Running)),
    ?assert(lists:member(opentelemetry_exporter, Running)),
    ?assert(is_pid(whereis(bondy_telemetry_exporter_sup))),

    ok = application:stop(bondy_telemetry_exporter),
    ?assertEqual(undefined, whereis(bondy_telemetry_exporter_sup)),
    ?assertNot(
        lists:member(
            bondy_telemetry_exporter,
            [A || {A, _, _} <- application:which_applications()]
        )
    ).
