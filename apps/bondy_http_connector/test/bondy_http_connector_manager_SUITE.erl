%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_connector_manager_SUITE).

-moduledoc """
Tests for `bondy_http_connector_manager`: the config-driven multi-service
startup pipeline (secrets resolution -> pool startup -> callee startup),
previously the least-tested module in the app (services configured
directly from `bondy.conf`/env, not exercised standalone by any other
suite; `bondy_http_connector_callee_lifecycle_SUITE` boots the manager
only incidentally, as part of the full app).

Each test configures `bondy_http_connector`'s `services` env directly and
starts its own manager instance. Services are configured with
`procedures => #{}` so `start_callees` has nothing to start -- this keeps
these tests independent of the WAMP dealer/session stack (which needs a
full Bondy boot, per `bondy_http_connector_callee_lifecycle_SUITE`) while
still exercising the manager's own secrets/pool orchestration and
readiness bookkeeping for real, against a real (mocked-secrets, real
HTTP) pipeline.

`bondy_http_connector_manager:services/0` and `service_readiness/1` are
synchronous `gen_server:call`s to the manager: since `init/1`'s
`resolve_secrets -> start_pools -> start_callees` continuation chain runs
to completion before the gen_server can answer any call, a successful
call is itself the synchronization point -- no polling needed to know
the pipeline has settled.
""".

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([
    no_services_configured_is_idle/1,
    service_without_secrets_starts_pool_and_is_ready/1,
    service_with_secrets_resolves_and_becomes_ready/1,
    service_with_bad_secrets_stays_not_ready/1,
    multiple_services_are_independent/1
]).

all() ->
    [
        no_services_configured_is_idle,
        service_without_secrets_starts_pool_and_is_ready,
        service_with_secrets_resolves_and_becomes_ready,
        service_with_bad_secrets_stays_not_ready,
        multiple_services_are_independent
    ].

%% ===================================================================
%% CT callbacks
%% ===================================================================

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hackney),
    {ok, _} = application:ensure_all_started(telemetry),
    %% `alarm_handler` (the registered gen_event manager) is started by
    %% `sasl`, not `kernel` — a bare CT run doesn't have it running
    %% otherwise, and a started pool's `mark_up/1` unconditionally calls
    %% `alarm_handler:clear_alarm/1`.
    {ok, _} = application:ensure_all_started(sasl),
    MetricsPid =
        case bondy_metrics:start_link() of
            {ok, Pid} -> Pid;
            {error, {already_started, Pid}} -> Pid
        end,
    true = unlink(MetricsPid),
    ok = bondy_http_connector_telemetry:init(),

    %% Shared across all tests: pools are named per-service, so different
    %% tests (using different service names) never collide, and
    %% `end_per_testcase` stops every child after each test anyway.
    {ok, PoolSup} = bondy_http_connector_http_pool_sup:start_link(),
    unlink(PoolSup),

    %% Stub mocks (NOT passthrough) for the secrets-resolution scenarios —
    %% see `bondy_http_connector_secret_resolver_SUITE` for why passthrough
    %% is avoided here (a costly recompile of the whole erlcloud modules
    %% that can outlast the CT watchdog once another suite has loaded
    %% erlcloud in the same VM).
    ok = meck:new(erlcloud_aws, [no_link]),
    ok = meck:new(erlcloud_sm, [no_link]),
    meck:expect(erlcloud_aws, auto_config, fun() -> {ok, mock_config} end),
    meck:expect(erlcloud_aws, default_config, fun() -> mock_config end),
    meck:expect(
        erlcloud_aws,
        service_config,
        fun(<<"sm">>, _Region, _AwsConfig) -> mock_sm_config end
    ),

    {ok, Port} = mock_auth_http_server:start(),
    BaseUrl = mock_auth_http_server:base_url(),
    [{port, Port}, {base_url, BaseUrl}, {pool_sup, PoolSup} | Config].

end_per_suite(_Config) ->
    catch meck:unload(erlcloud_sm),
    catch meck:unload(erlcloud_aws),
    mock_auth_http_server:stop(),
    ok.

init_per_testcase(_TC, Config) ->
    Port = ?config(port, Config),
    case catch ranch:get_port(mock_auth_http_listener) of
        Port -> ok;
        _ -> {ok, _} = mock_auth_http_server:start(#{port => Port})
    end,
    mock_auth_http_server:reset(),
    Config.

end_per_testcase(_TC, _Config) ->
    catch gen_server:stop(bondy_http_connector_manager),
    ok = application:unset_env(bondy_http_connector, services),
    stop_all_pools(),
    ok.

%% ===================================================================
%% Helpers
%% ===================================================================

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

stop_all_pools() ->
    case whereis(bondy_http_connector_http_pool_sup) of
        undefined ->
            ok;
        _ ->
            Children = supervisor:which_children(
                bondy_http_connector_http_pool_sup
            ),
            lists:foreach(
                fun
                    ({_, Pid, _, _}) when is_pid(Pid) ->
                        catch gen_server:stop(Pid);
                    (_) ->
                        ok
                end,
                Children
            )
    end.

pool_name(ServiceName) ->
    binary_to_atom(<<"bondy_http_connector_http_pool_", ServiceName/binary>>).

mock_sm_success(SecretJson) ->
    SecretString = iolist_to_binary(json:encode(SecretJson)),
    meck:expect(
        erlcloud_sm,
        get_secret_value,
        fun(_SecretId, [], _SmConfig) ->
            {ok, [{<<"SecretString">>, SecretString}]}
        end
    ).

metric_or_zero(Name, Label) ->
    case bondy_metrics:value(#{name => Name, label => Label}) of
        undefined -> 0;
        N -> N
    end.

secret_resolution_total(Service, Outcome) ->
    metric_or_zero(bondy_http_connector_secret_resolution_total, #{
        service => Service, outcome => Outcome
    }).

service_ready_gauge(Service) ->
    metric_or_zero(bondy_http_connector_service_ready, #{service => Service}).

plain_service(Name, BaseUrl) ->
    #{
        name => Name,
        base_url => BaseUrl,
        auth_mod => bondy_http_connector_mock_auth,
        auth_conf => #{},
        procedures => #{}
    }.

service_with_secrets(Name, BaseUrl, SecretId, VarsSpec) ->
    #{
        name => Name,
        base_url => BaseUrl,
        auth_mod => bondy_http_connector_mock_auth,
        auth_conf => #{
            vars => #{},
            secrets => #{
                provider => aws_sm,
                secret_id => SecretId,
                region => <<"us-east-1">>,
                vars => VarsSpec
            }
        },
        procedures => #{}
    }.

%% ===================================================================
%% Tests
%% ===================================================================

no_services_configured_is_idle(_Config) ->
    ok = application:set_env(bondy_http_connector, services, []),
    {ok, _Pid} = bondy_http_connector_manager:start_link(),

    ?assertEqual([], bondy_http_connector_manager:services()),
    ?assertEqual(
        {ok, #{}},
        bondy_http_connector_manager:service_readiness(<<"anything">>)
    ).

service_without_secrets_starts_pool_and_is_ready(Config) ->
    BaseUrl = ?config(base_url, Config),
    ServiceName = <<"plain">>,
    Service = plain_service(ServiceName, BaseUrl),
    ok = application:set_env(bondy_http_connector, services, [Service]),
    {ok, _Pid} = bondy_http_connector_manager:start_link(),

    ?assertEqual([Service], bondy_http_connector_manager:services()),
    %% No `auth_conf.secrets` -> no ETS entry -> always ready.
    ?assertEqual(
        {ok, #{}}, bondy_http_connector_manager:service_readiness(ServiceName)
    ),

    PoolName = pool_name(ServiceName),
    wait_until(
        fun() -> bondy_http_connector_http_pool:status(PoolName) =:= up end, 40
    ).

service_with_secrets_resolves_and_becomes_ready(Config) ->
    BaseUrl = ?config(base_url, Config),
    ServiceName = <<"secure">>,
    mock_sm_success(#{<<"CLIENT_ID">> => <<"secret-client-id">>}),
    Service = service_with_secrets(
        ServiceName,
        BaseUrl,
        <<"/test/secure">>,
        #{client_id => #{field => <<"CLIENT_ID">>, transform => none}}
    ),
    ok = application:set_env(bondy_http_connector, services, [Service]),
    {ok, _Pid} = bondy_http_connector_manager:start_link(),

    %% `services/0` is a `gen_server:call` -- unlike `service_readiness/1`
    %% (a raw ETS read), a reply from it is only possible once the
    %% `resolve_secrets -> start_pools -> start_callees` continuation
    %% chain has fully run, so it doubles as the synchronization point.
    %% (Its return value isn't asserted here: a service with secrets is
    %% stored with `auth_conf.secrets` stripped, already covered by
    %% `service_without_secrets_starts_pool_and_is_ready`'s identity check.)
    _ = bondy_http_connector_manager:services(),
    ?assertMatch(
        {ok, #{client_id := <<"secret-client-id">>}},
        bondy_http_connector_manager:service_readiness(ServiceName)
    ),
    ?assertEqual(1, secret_resolution_total(ServiceName, ok)),
    ?assertEqual(1, service_ready_gauge(ServiceName)),

    PoolName = pool_name(ServiceName),
    wait_until(
        fun() -> bondy_http_connector_http_pool:status(PoolName) =:= up end, 40
    ).

service_with_bad_secrets_stays_not_ready(Config) ->
    BaseUrl = ?config(base_url, Config),
    ServiceName = <<"broken">>,
    meck:expect(
        erlcloud_sm,
        get_secret_value,
        fun(_SecretId, [], _SmConfig) ->
            {error, {http_error, 403, <<"Forbidden">>}}
        end
    ),
    Service = service_with_secrets(
        ServiceName, BaseUrl, <<"/test/broken">>, #{}
    ),
    ok = application:set_env(bondy_http_connector, services, [Service]),
    {ok, _Pid} = bondy_http_connector_manager:start_link(),

    %% Synchronization point -- see the comment in
    %% service_with_secrets_resolves_and_becomes_ready/1.
    _ = bondy_http_connector_manager:services(),
    ?assertEqual(
        {error, not_ready},
        bondy_http_connector_manager:service_readiness(ServiceName)
    ),
    ?assertEqual(1, secret_resolution_total(ServiceName, error)),
    ?assertEqual(0, service_ready_gauge(ServiceName)),

    %% A secrets failure doesn't block the rest of the pipeline -- the
    %% pool for this service still starts.
    PoolName = pool_name(ServiceName),
    wait_until(
        fun() -> bondy_http_connector_http_pool:status(PoolName) =:= up end, 40
    ).

multiple_services_are_independent(Config) ->
    BaseUrl = ?config(base_url, Config),
    PlainName = <<"multi-plain">>,
    SecureName = <<"multi-secure">>,
    mock_sm_success(#{<<"CLIENT_ID">> => <<"multi-secret">>}),
    Plain = plain_service(PlainName, BaseUrl),
    Secure = service_with_secrets(
        SecureName,
        BaseUrl,
        <<"/test/multi">>,
        #{client_id => #{field => <<"CLIENT_ID">>, transform => none}}
    ),
    ok = application:set_env(bondy_http_connector, services, [Plain, Secure]),
    {ok, _Pid} = bondy_http_connector_manager:start_link(),

    ?assertEqual(2, length(bondy_http_connector_manager:services())),
    ?assertEqual(
        {ok, #{}}, bondy_http_connector_manager:service_readiness(PlainName)
    ),
    ?assertMatch(
        {ok, #{client_id := <<"multi-secret">>}},
        bondy_http_connector_manager:service_readiness(SecureName)
    ),

    wait_until(
        fun() ->
            bondy_http_connector_http_pool:status(pool_name(PlainName)) =:= up
        end,
        40
    ),
    wait_until(
        fun() ->
            bondy_http_connector_http_pool:status(pool_name(SecureName)) =:= up
        end,
        40
    ).
