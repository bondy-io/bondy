-module(bondy_rpc_gateway_token_cache_SUITE).

-moduledoc """
Integration tests for the token cache subsystem.

Tests the full stack: registry, supervisor, and workers together. Uses
`bondy_rpc_gateway_mock_auth` to avoid real HTTP calls.
""".

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    cold_cache_fetches_token/1,
    hot_cache_returns_same_token/1,
    hot_cache_no_extra_fetch/1,
    invalidate_forces_fresh_fetch/1,
    invalidate_nonexistent_service_ok/1,
    multiple_services_isolated/1,
    worker_crash_cleans_registry/1,
    concurrent_cold_cache_single_fetch/1,
    preemptive_refresh_fires/1,
    fetch_error_propagates/1,
    meta_expires_in_respected/1
]).

%% ===================================================================
%% CT callbacks
%% ===================================================================

all() ->
    [{group, cache_tests}].

groups() ->
    [{cache_tests, [sequence], [
        cold_cache_fetches_token,
        hot_cache_returns_same_token,
        hot_cache_no_extra_fetch,
        invalidate_forces_fresh_fetch,
        invalidate_nonexistent_service_ok,
        multiple_services_isolated,
        worker_crash_cleans_registry,
        concurrent_cold_cache_single_fetch,
        preemptive_refresh_fires,
        fetch_error_propagates,
        meta_expires_in_respected
    ]}].

init_per_suite(Config) ->
    _ = application:ensure_all_started(gproc),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    %% Start fresh supervision tree for each test
    {ok, Sup} = bondy_rpc_gateway_sup:start_link(),
    unlink(Sup),
    bondy_rpc_gateway_mock_auth:reset_call_count(),
    bondy_rpc_gateway_mock_auth:set_token(<<"default-token">>),
    [{sup, Sup} | Config].

end_per_testcase(_TC, Config) ->
    Sup = proplists:get_value(sup, Config),
    exit(Sup, shutdown),
    timer:sleep(50),
    %% Clean up persistent_term keys
    lists:foreach(fun(Key) ->
        catch persistent_term:erase(Key)
    end, [
        {bondy_rpc_gateway_mock_auth, result},
        {bondy_rpc_gateway_mock_auth, fetch_fun},
        {bondy_rpc_gateway_mock_auth, call_count}
    ]),
    ok.

%% ===================================================================
%% Helpers
%% ===================================================================

auth_conf() ->
    #{
        fetch => #{
            method     => post,
            url        => <<"http://mock/token">>,
            token_path => [<<"token">>]
        },
        apply => #{
            placement => header,
            name      => <<"Authorization">>,
            format    => <<"Bearer {{token}}">>
        }
    }.

auth_conf_with_cache(TTL, Margin) ->
    (auth_conf())#{cache => #{default_ttl => TTL, refresh_margin => Margin}}.

%% ===================================================================
%% Test cases
%% ===================================================================

cold_cache_fetches_token(_Config) ->
    bondy_rpc_gateway_mock_auth:set_token(<<"tok-1">>),
    {ok, Token} = bondy_rpc_gateway_token_cache:get(
        <<"svc-a">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),
    ?assertEqual(<<"tok-1">>, Token),
    ?assertEqual(1, bondy_rpc_gateway_mock_auth:call_count()).

hot_cache_returns_same_token(_Config) ->
    bondy_rpc_gateway_mock_auth:set_token(<<"tok-2">>),
    {ok, T1} = bondy_rpc_gateway_token_cache:get(
        <<"svc-b">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),
    {ok, T2} = bondy_rpc_gateway_token_cache:get(
        <<"svc-b">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),
    ?assertEqual(T1, T2),
    ?assertEqual(<<"tok-2">>, T1).

hot_cache_no_extra_fetch(_Config) ->
    bondy_rpc_gateway_mock_auth:set_token(<<"tok-3">>),
    _ = bondy_rpc_gateway_token_cache:get(
        <<"svc-c">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),
    _ = bondy_rpc_gateway_token_cache:get(
        <<"svc-c">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),
    _ = bondy_rpc_gateway_token_cache:get(
        <<"svc-c">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),
    %% Only one HTTP call despite three get_token calls
    ?assertEqual(1, bondy_rpc_gateway_mock_auth:call_count()).

invalidate_forces_fresh_fetch(_Config) ->
    bondy_rpc_gateway_mock_auth:set_token(<<"old-tok">>),
    {ok, <<"old-tok">>} = bondy_rpc_gateway_token_cache:get(
        <<"svc-d">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),
    ?assertEqual(1, bondy_rpc_gateway_mock_auth:call_count()),

    ok = bondy_rpc_gateway_token_cache:invalidate(<<"svc-d">>),
    %% Give the cast time to process
    timer:sleep(10),

    bondy_rpc_gateway_mock_auth:set_token(<<"new-tok">>),
    {ok, Token} = bondy_rpc_gateway_token_cache:get(
        <<"svc-d">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),
    ?assertEqual(<<"new-tok">>, Token),
    ?assertEqual(2, bondy_rpc_gateway_mock_auth:call_count()).

invalidate_nonexistent_service_ok(_Config) ->
    %% Should not crash
    ?assertEqual(ok, bondy_rpc_gateway_token_cache:invalidate(<<"no-such-svc">>)).

multiple_services_isolated(_Config) ->
    Counter = atomics:new(1, [{signed, false}]),
    bondy_rpc_gateway_mock_auth:set_fetch_fun(fun(_Conf) ->
        N = atomics:add_get(Counter, 1, 1),
        {ok, <<"tok-", (integer_to_binary(N))/binary>>}
    end),

    {ok, TA} = bondy_rpc_gateway_token_cache:get(
        <<"iso-a">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),
    {ok, TB} = bondy_rpc_gateway_token_cache:get(
        <<"iso-b">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),
    %% Each service got its own token
    ?assertNotEqual(TA, TB),

    %% Invalidating one does not affect the other
    ok = bondy_rpc_gateway_token_cache:invalidate(<<"iso-a">>),
    timer:sleep(10),
    {ok, TB2} = bondy_rpc_gateway_token_cache:get(
        <<"iso-b">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),
    ?assertEqual(TB, TB2).

worker_crash_cleans_registry(_Config) ->
    bondy_rpc_gateway_mock_auth:set_token(<<"crash-tok">>),
    {ok, _} = bondy_rpc_gateway_token_cache:get(
        <<"crash-svc">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),

    %% Find the worker pid via the pool and kill it
    PoolName = {bondy_rpc_gateway_token_cache, pool},
    Pid = gproc_pool:pick_worker(PoolName, <<"crash-svc">>),
    ?assert(is_pid(Pid)),
    exit(Pid, kill),
    timer:sleep(100),

    %% The supervisor restarts the worker with a fresh ETS table,
    %% so the cached token is gone. A new get should fetch fresh.
    bondy_rpc_gateway_mock_auth:set_token(<<"new-crash-tok">>),
    {ok, Token} = bondy_rpc_gateway_token_cache:get(
        <<"crash-svc">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),
    ?assertEqual(<<"new-crash-tok">>, Token).

concurrent_cold_cache_single_fetch(_Config) ->
    Counter = atomics:new(1, [{signed, false}]),
    bondy_rpc_gateway_mock_auth:set_fetch_fun(fun(_Conf) ->
        %% Simulate slow fetch
        timer:sleep(50),
        atomics:add_get(Counter, 1, 1),
        {ok, <<"concurrent-tok">>}
    end),

    Self = self(),
    N = 20,
    Pids = [spawn_link(fun() ->
        Result = bondy_rpc_gateway_token_cache:get(
            <<"conc-svc">>, bondy_rpc_gateway_mock_auth, auth_conf()
        ),
        Self ! {done, self(), Result}
    end) || _ <- lists:seq(1, N)],

    Results = [receive {done, P, R} -> R end || P <- Pids],

    %% All should succeed with the same token
    lists:foreach(fun(R) ->
        ?assertEqual({ok, <<"concurrent-tok">>}, R)
    end, Results),

    %% fetch_token should only have been called once (or very few times
    %% if there was a race before the worker was registered)
    FetchCount = atomics:get(Counter, 1),
    ?assert(FetchCount =< 2).

preemptive_refresh_fires(_Config) ->
    Counter = atomics:new(1, [{signed, false}]),
    bondy_rpc_gateway_mock_auth:set_fetch_fun(fun(_Conf) ->
        N = atomics:add_get(Counter, 1, 1),
        {ok, {<<"refresh-tok-", (integer_to_binary(N))/binary>>,
         #{expires_in => 2}}}
    end),

    %% TTL=2s, margin=1s => refresh fires after 1s
    Conf = auth_conf_with_cache(2, 1),
    {ok, T1} = bondy_rpc_gateway_token_cache:get(
        <<"refresh-svc">>, bondy_rpc_gateway_mock_auth, Conf
    ),
    ?assertEqual(<<"refresh-tok-1">>, T1),

    %% Wait for preemptive refresh
    timer:sleep(1500),

    %% Token should have been refreshed in background
    {ok, T2} = bondy_rpc_gateway_token_cache:get(
        <<"refresh-svc">>, bondy_rpc_gateway_mock_auth, Conf
    ),
    ?assertEqual(<<"refresh-tok-2">>, T2),
    ?assert(atomics:get(Counter, 1) >= 2).

fetch_error_propagates(_Config) ->
    bondy_rpc_gateway_mock_auth:set_error(endpoint_unreachable),
    Result = bondy_rpc_gateway_token_cache:get(
        <<"err-svc">>, bondy_rpc_gateway_mock_auth, auth_conf()
    ),
    ?assertEqual({error, endpoint_unreachable}, Result).

meta_expires_in_respected(_Config) ->
    %% The meta expires_in should override the default_ttl.
    %% We use a counter to return different tokens on each fetch,
    %% and a short TTL (1s) with refresh_margin=0 so the preemptive
    %% refresh fires at max(1, 1-0) = 1s, causing a re-fetch.
    Counter = atomics:new(1, [{signed, false}]),
    bondy_rpc_gateway_mock_auth:set_fetch_fun(fun(_Conf) ->
        N = atomics:add_get(Counter, 1, 1),
        %% Always return expires_in => 1 so the cache TTL is 1s,
        %% overriding the large default_ttl in cache config.
        {ok, {<<"meta-tok-", (integer_to_binary(N))/binary>>,
         #{expires_in => 1}}}
    end),
    Conf = auth_conf_with_cache(3600, 0),
    {ok, <<"meta-tok-1">>} = bondy_rpc_gateway_token_cache:get(
        <<"meta-svc">>, bondy_rpc_gateway_mock_auth, Conf
    ),
    %% Wait for the preemptive refresh (fires at 1s) + a small margin
    timer:sleep(1500),
    {ok, T2} = bondy_rpc_gateway_token_cache:get(
        <<"meta-svc">>, bondy_rpc_gateway_mock_auth, Conf
    ),
    %% Token should have been refreshed (counter incremented)
    ?assertNotEqual(<<"meta-tok-1">>, T2),
    ?assert(atomics:get(Counter, 1) >= 2).
