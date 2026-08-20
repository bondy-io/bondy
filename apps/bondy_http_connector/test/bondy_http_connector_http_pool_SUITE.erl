%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_connector_http_pool_SUITE).

-moduledoc """
Tests the periodic up-state liveness probe state machine in
`bondy_http_connector_http_pool`: threshold-gated down transition with
alarm raise, and threshold-gated alarm clear on recovery (while the
pool itself flips back to `up` fail-open on the very first successful
probe). Drives a real pool process against `mock_auth_http_server`,
stopping/restarting its listener to simulate an unreachable upstream.
""".

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([
    pool_up_when_reachable/1,
    pool_marked_down_after_failure_threshold_and_alarm_set/1,
    pool_recovers_and_alarm_cleared_respecting_success_threshold/1,
    pool_liveness_disabled_never_probes/1,
    pool_liveness_probe_uses_get_method/1
]).

-define(ALARM_ID(Service), {http_connector_service_down, Service}).

%% ===================================================================
%% CT callbacks
%% ===================================================================

all() ->
    [
        pool_up_when_reachable,
        pool_marked_down_after_failure_threshold_and_alarm_set,
        pool_recovers_and_alarm_cleared_respecting_success_threshold,
        pool_liveness_disabled_never_probes,
        pool_liveness_probe_uses_get_method
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hackney),
    {ok, _} = application:ensure_all_started(telemetry),
    %% `alarm_handler` (the registered gen_event manager) is started by
    %% `sasl`, not `kernel` — a bare CT run doesn't have it running
    %% otherwise.
    {ok, _} = application:ensure_all_started(sasl),
    %% start_link/0 links to the calling process — init_per_suite's process
    %% is transient (CT tears it down once this function returns), which
    %% would take bondy_metrics' ETS tables down with it. Unlink so the
    %% registry outlives init_per_suite for the rest of the suite.
    MetricsPid =
        case bondy_metrics:start_link() of
            {ok, Pid} -> Pid;
            {error, {already_started, Pid}} -> Pid
        end,
    true = unlink(MetricsPid),
    ok = bondy_http_connector_telemetry:init(),
    {ok, Port} = mock_auth_http_server:start(),
    [{port, Port} | Config].

end_per_suite(_Config) ->
    mock_auth_http_server:stop(),
    ok.

init_per_testcase(TC, Config) ->
    %% mock_auth_http_server:start/0 is idempotent (re-inits ETS) but the
    %% listener itself may have been stopped by a previous testcase to
    %% simulate an outage — make sure it's back up before each test.
    Port = ?config(port, Config),
    try ranch:get_port(mock_auth_http_listener) of
        Port -> ok;
        _ -> {ok, _} = mock_auth_http_server:start(#{port => Port})
    catch
        _:_ -> {ok, _} = mock_auth_http_server:start(#{port => Port})
    end,
    ServiceName = atom_to_binary(TC, utf8),
    [{service_name, ServiceName} | Config].

end_per_testcase(_TC, Config) ->
    ServiceName = ?config(service_name, Config),
    try
        gen_server:stop(binary_to_atom(<<"pool_", ServiceName/binary>>))
    catch
        _:_ -> ok
    end,
    try
        alarm_handler:clear_alarm(?ALARM_ID(ServiceName))
    catch
        _:_ -> ok
    end,
    ok.

%% ===================================================================
%% Helpers
%% ===================================================================

start_pool(ServiceName, LivenessOpts, Config) ->
    Port = ?config(port, Config),
    Name = binary_to_atom(<<"pool_", ServiceName/binary>>),
    Endpoint = iolist_to_binary(io_lib:format("http://localhost:~B", [Port])),
    Opts = #{
        service_name => ServiceName,
        liveness => LivenessOpts,
        retry_opts => #{
            deadline => 0,
            max_retries => 1_000_000,
            backoff_enabled => true,
            backoff_min => 50,
            backoff_max => 200,
            backoff_type => jitter
        }
    },
    {ok, Pid} = bondy_http_connector_http_pool:start_link(Name, Endpoint, Opts),
    {Name, Pid}.

pool_up_gauge(ServiceName) ->
    bondy_metrics:value(#{
        name => bondy_http_connector_pool_up, label => #{service => ServiceName}
    }).

%% @private
%% `bondy_http_connector_liveness_probes_total` is a counter, so `value/1`
%% returns its cumulative count; `undefined` (metric never touched) reads
%% as 0 so callers don't have to special-case a cold label.
liveness_probes_total(ServiceName, Outcome) ->
    case
        bondy_metrics:value(#{
            name => bondy_http_connector_liveness_probes_total,
            label => #{service => ServiceName, outcome => Outcome}
        })
    of
        undefined -> 0;
        N -> N
    end.

%% @private
%% `bondy_http_connector_liveness_probe_duration_milliseconds` is a
%% histogram; `value/1` reads its observation count (position 1, shared
%% with a plain counter's position — see `bondy_metrics:value/1`).
liveness_probe_duration_count(ServiceName) ->
    case
        bondy_metrics:value(#{
            name => bondy_http_connector_liveness_probe_duration_milliseconds,
            label => #{service => ServiceName}
        })
    of
        undefined -> 0;
        N -> N
    end.

%% @private
%% Stock `alarm_handler:get_alarms/0` hardcodes `gen_event:call(alarm_handler,
%% alarm_handler, get_alarms)` — i.e. it assumes the installed handler's id
%% is the atom `alarm_handler` itself. That's only true for OTP's default
%% handler; a full Bondy boot elsewhere in the same test VM swaps in
%% `bondy_alarm_handler` (a different id), which breaks it with
%% `{error, bad_module}`. Ask the event manager which handler is actually
%% installed instead — both implementations answer `get_alarms`.
current_alarms() ->
    case gen_event:which_handlers(alarm_handler) of
        [Handler | _] -> gen_event:call(alarm_handler, Handler, get_alarms);
        [] -> []
    end.

wait_until(Fun, Retries) when Retries > 0 ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, Retries - 1)
    end;
wait_until(Fun, 0) ->
    ?assert(Fun()).

%% ===================================================================
%% Tests
%% ===================================================================

pool_up_when_reachable(Config) ->
    ServiceName = ?config(service_name, Config),
    {Name, _Pid} = start_pool(
        ServiceName,
        #{
            enabled => true,
            interval => 60_000,
            failure_threshold => 2,
            success_threshold => 1
        },
        Config
    ),
    wait_until(
        fun() -> bondy_http_connector_http_pool:status(Name) =:= up end, 40
    ),
    ?assertEqual(1, pool_up_gauge(ServiceName)),
    ?assertEqual([], [
        A
     || {Id, _} = A <- current_alarms(), Id =:= ?ALARM_ID(ServiceName)
    ]).

pool_marked_down_after_failure_threshold_and_alarm_set(Config) ->
    ServiceName = ?config(service_name, Config),
    {Name, _Pid} = start_pool(
        ServiceName,
        #{
            enabled => true,
            interval => 100,
            timeout => 500,
            failure_threshold => 2,
            success_threshold => 1
        },
        Config
    ),
    wait_until(
        fun() -> bondy_http_connector_http_pool:status(Name) =:= up end, 40
    ),

    %% Simulate an outage: stop the mock listener so every probe (and the
    %% down-state retry) hits {error, econnrefused}.
    mock_auth_http_server:stop(),

    wait_until(
        fun() -> bondy_http_connector_http_pool:status(Name) =:= down end, 60
    ),
    ?assertEqual(0, pool_up_gauge(ServiceName)),
    ?assertMatch(
        [{_, #{service := ServiceName}}],
        [A || {Id, _} = A <- current_alarms(), Id =:= ?ALARM_ID(ServiceName)]
    ),
    ?assertEqual(
        {error, pool_down},
        bondy_http_connector_http_pool:request(Name, get, <<"/">>, [], <<>>)
    ),
    %% failure_threshold=2 -- at least 2 failed up-state probes must have
    %% fired (and been recorded) before the down transition.
    ?assert(liveness_probes_total(ServiceName, error) >= 2).

pool_recovers_and_alarm_cleared_respecting_success_threshold(Config) ->
    ServiceName = ?config(service_name, Config),
    Port = ?config(port, Config),
    {Name, _Pid} = start_pool(
        ServiceName,
        #{
            enabled => true,
            interval => 100,
            timeout => 500,
            failure_threshold => 2,
            success_threshold => 2
        },
        Config
    ),
    wait_until(
        fun() -> bondy_http_connector_http_pool:status(Name) =:= up end, 40
    ),

    mock_auth_http_server:stop(),
    wait_until(
        fun() -> bondy_http_connector_http_pool:status(Name) =:= down end, 60
    ),
    ?assertNotEqual(
        [], [
            A
         || {Id, _} = A <- current_alarms(), Id =:= ?ALARM_ID(ServiceName)
        ]
    ),

    {ok, _} = mock_auth_http_server:start(#{port => Port}),

    %% The pool itself recovers fail-open on the very first successful
    %% probe (down-state bondy_retry loop), well before the up-state
    %% cadence has run success_threshold=2 times.
    wait_until(
        fun() -> bondy_http_connector_http_pool:status(Name) =:= up end, 60
    ),
    ?assertEqual(1, pool_up_gauge(ServiceName)),

    %% ...but the alarm requires 2 consecutive successful up-state
    %% liveness probes (100ms interval) to clear, so it should still be
    %% active immediately after recovery.
    ?assertNotEqual(
        [], [
            A
         || {Id, _} = A <- current_alarms(), Id =:= ?ALARM_ID(ServiceName)
        ]
    ),

    wait_until(
        fun() ->
            [] =:=
                [
                    A
                 || {Id, _} = A <- current_alarms(),
                    Id =:= ?ALARM_ID(ServiceName)
                ]
        end,
        60
    ).

pool_liveness_disabled_never_probes(Config) ->
    ServiceName = ?config(service_name, Config),
    {Name, _Pid} = start_pool(
        ServiceName,
        %% A short interval that WOULD have ticked several times over the
        %% test's runtime if the periodic probe were armed.
        #{
            enabled => false,
            interval => 100,
            timeout => 500,
            failure_threshold => 2,
            success_threshold => 1
        },
        Config
    ),
    wait_until(
        fun() -> bondy_http_connector_http_pool:status(Name) =:= up end, 40
    ),

    %% The one-shot startup health check always runs regardless of
    %% `liveness.enabled` (that's the pre-existing behaviour), but it
    %% does not emit `liveness_probe` telemetry -- only the periodic
    %% up-state timer does, and that timer must never have been armed.
    mock_auth_http_server:stop(),
    timer:sleep(500),

    ?assertEqual(up, bondy_http_connector_http_pool:status(Name)),
    ?assertEqual(1, pool_up_gauge(ServiceName)),
    ?assertEqual(0, liveness_probes_total(ServiceName, ok)),
    ?assertEqual(0, liveness_probes_total(ServiceName, error)),
    ?assertEqual([], [
        A
     || {Id, _} = A <- current_alarms(), Id =:= ?ALARM_ID(ServiceName)
    ]).

pool_liveness_probe_uses_get_method(Config) ->
    ServiceName = ?config(service_name, Config),
    {Name, _Pid} = start_pool(
        ServiceName,
        #{
            enabled => true,
            method => get,
            interval => 100,
            timeout => 500,
            failure_threshold => 2,
            success_threshold => 1
        },
        Config
    ),
    wait_until(
        fun() -> bondy_http_connector_http_pool:status(Name) =:= up end, 40
    ),

    %% At least one periodic (GET-method) up-state probe must have fired
    %% and been recorded, both as the counter and the duration histogram.
    wait_until(fun() -> liveness_probes_total(ServiceName, ok) >= 1 end, 40),
    ?assert(liveness_probe_duration_count(ServiceName) >= 1),
    ?assertEqual(1, pool_up_gauge(ServiceName)),
    ?assertEqual([], [
        A
     || {Id, _} = A <- current_alarms(), Id =:= ?ALARM_ID(ServiceName)
    ]).
