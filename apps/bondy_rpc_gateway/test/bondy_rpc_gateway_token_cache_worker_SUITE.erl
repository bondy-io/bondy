-module(bondy_rpc_gateway_token_cache_worker_SUITE).

-moduledoc """
Unit tests for `bondy_rpc_gateway_token_cache_worker`.

Tests the worker gen_server in isolation (without the registry or
supervisor) to verify token lifecycle, caching, invalidation,
and preemptive refresh behaviour.
""".

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    get_token_fetches_on_cold_start/1,
    get_token_caches_on_hot/1,
    invalidate_clears_cached_token/1,
    fetch_error_returns_error/1,
    preemptive_refresh_updates_token/1,
    preemptive_refresh_failure_keeps_old_token/1,
    expired_token_triggers_refetch/1,
    meta_expires_in_overrides_default_ttl/1
]).

%% ===================================================================
%% CT callbacks
%% ===================================================================

all() ->
    [
        get_token_fetches_on_cold_start,
        get_token_caches_on_hot,
        invalidate_clears_cached_token,
        fetch_error_returns_error,
        preemptive_refresh_updates_token,
        preemptive_refresh_failure_keeps_old_token,
        expired_token_triggers_refetch,
        meta_expires_in_overrides_default_ttl
    ].

init_per_testcase(_TC, Config) ->
    bondy_rpc_gateway_mock_auth:reset_call_count(),
    bondy_rpc_gateway_mock_auth:set_token(<<"default-token">>),
    Config.

end_per_testcase(_TC, _Config) ->
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
        apply => #{placement => header, name => <<"Authorization">>}
    }.

start_worker() ->
    start_worker(auth_conf()).

start_worker(Conf) ->
    {ok, Pid} = bondy_rpc_gateway_token_cache_worker:start_link(
        <<"test-svc">>, bondy_rpc_gateway_mock_auth, Conf
    ),
    unlink(Pid),
    Pid.

stop_worker(Pid) ->
    exit(Pid, shutdown),
    timer:sleep(20).

%% ===================================================================
%% Test cases
%% ===================================================================

get_token_fetches_on_cold_start(_Config) ->
    bondy_rpc_gateway_mock_auth:set_token(<<"fresh-tok">>),
    Pid = start_worker(),
    {ok, Token} = gen_server:call(Pid, get_token),
    ?assertEqual(<<"fresh-tok">>, Token),
    ?assertEqual(1, bondy_rpc_gateway_mock_auth:call_count()),
    stop_worker(Pid).

get_token_caches_on_hot(_Config) ->
    bondy_rpc_gateway_mock_auth:set_token(<<"cached-tok">>),
    Pid = start_worker(),
    {ok, _} = gen_server:call(Pid, get_token),
    {ok, T2} = gen_server:call(Pid, get_token),
    {ok, T3} = gen_server:call(Pid, get_token),
    ?assertEqual(<<"cached-tok">>, T2),
    ?assertEqual(<<"cached-tok">>, T3),
    ?assertEqual(1, bondy_rpc_gateway_mock_auth:call_count()),
    stop_worker(Pid).

invalidate_clears_cached_token(_Config) ->
    Counter = atomics:new(1, [{signed, false}]),
    bondy_rpc_gateway_mock_auth:set_fetch_fun(fun(_) ->
        N = atomics:add_get(Counter, 1, 1),
        {ok, <<"tok-", (integer_to_binary(N))/binary>>}
    end),
    Pid = start_worker(),
    {ok, <<"tok-1">>} = gen_server:call(Pid, get_token),
    gen_server:cast(Pid, invalidate),
    timer:sleep(10),
    {ok, <<"tok-2">>} = gen_server:call(Pid, get_token),
    ?assertEqual(2, atomics:get(Counter, 1)),
    stop_worker(Pid).

fetch_error_returns_error(_Config) ->
    bondy_rpc_gateway_mock_auth:set_error(boom),
    Pid = start_worker(),
    ?assertEqual({error, boom}, gen_server:call(Pid, get_token)),
    stop_worker(Pid).

preemptive_refresh_updates_token(_Config) ->
    Counter = atomics:new(1, [{signed, false}]),
    bondy_rpc_gateway_mock_auth:set_fetch_fun(fun(_) ->
        N = atomics:add_get(Counter, 1, 1),
        {ok, <<"r-", (integer_to_binary(N))/binary>>, #{expires_in => 2}}
    end),
    %% TTL=2, margin=1 → refresh after 1s
    Conf = (auth_conf())#{cache => #{default_ttl => 2, refresh_margin => 1}},
    Pid = start_worker(Conf),
    {ok, <<"r-1">>} = gen_server:call(Pid, get_token),
    timer:sleep(1500),
    {ok, T2} = gen_server:call(Pid, get_token),
    ?assertEqual(<<"r-2">>, T2),
    stop_worker(Pid).

preemptive_refresh_failure_keeps_old_token(_Config) ->
    bondy_rpc_gateway_mock_auth:set_fetch_fun(fun(_) ->
        {ok, <<"will-keep">>, #{expires_in => 3}}
    end),
    Conf = (auth_conf())#{cache => #{default_ttl => 3, refresh_margin => 2}},
    Pid = start_worker(Conf),
    {ok, <<"will-keep">>} = gen_server:call(Pid, get_token),

    %% Make next fetch fail (the preemptive refresh)
    bondy_rpc_gateway_mock_auth:set_error(refresh_failed),
    timer:sleep(1500),

    %% Token should still be valid (not expired yet: 3s TTL)
    {ok, T2} = gen_server:call(Pid, get_token),
    ?assertEqual(<<"will-keep">>, T2),
    stop_worker(Pid).

expired_token_triggers_refetch(_Config) ->
    Counter = atomics:new(1, [{signed, false}]),
    bondy_rpc_gateway_mock_auth:set_fetch_fun(fun(_) ->
        N = atomics:add_get(Counter, 1, 1),
        {ok, <<"exp-", (integer_to_binary(N))/binary>>}
    end),
    %% Very short TTL, no margin → expires quickly, no preemptive refresh
    Conf = (auth_conf())#{cache => #{default_ttl => 1, refresh_margin => 0}},
    Pid = start_worker(Conf),
    {ok, <<"exp-1">>} = gen_server:call(Pid, get_token),
    timer:sleep(1200),
    {ok, T2} = gen_server:call(Pid, get_token),
    ?assertEqual(<<"exp-2">>, T2),
    stop_worker(Pid).

meta_expires_in_overrides_default_ttl(_Config) ->
    %% The meta expires_in (1s) should override the large default_ttl (3600).
    %% With refresh_margin=0, the preemptive refresh fires at max(1, 1-0) = 1s.
    Counter = atomics:new(1, [{signed, false}]),
    bondy_rpc_gateway_mock_auth:set_fetch_fun(fun(_) ->
        N = atomics:add_get(Counter, 1, 1),
        {ok, <<"meta-tok-", (integer_to_binary(N))/binary>>,
         #{expires_in => 1}}
    end),
    Conf = (auth_conf())#{cache => #{default_ttl => 3600, refresh_margin => 0}},
    Pid = start_worker(Conf),
    {ok, <<"meta-tok-1">>} = gen_server:call(Pid, get_token),
    %% Wait for preemptive refresh at 1s + margin
    timer:sleep(1500),
    {ok, T2} = gen_server:call(Pid, get_token),
    %% Token should have been refreshed due to short expires_in
    ?assertNotEqual(<<"meta-tok-1">>, T2),
    ?assert(atomics:get(Counter, 1) >= 2),
    stop_worker(Pid).
