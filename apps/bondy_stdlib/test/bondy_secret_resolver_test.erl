%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_secret_resolver_test).

-include_lib("eunit/include/eunit.hrl").

-define(VAR, "BONDY_SECRET_RESOLVER_TEST_VAR").

%% =============================================================================
%% env provider
%% =============================================================================

env_raw_test() ->
    os:putenv(?VAR, "s3cr3t"),
    try
        ?assertEqual(
            {ok, <<"s3cr3t">>},
            bondy_secret_resolver:resolve(#{provider => env, var => ?VAR})
        )
    after
        os:unsetenv(?VAR)
    end.

env_binary_var_name_test() ->
    os:putenv(?VAR, "value"),
    try
        ?assertEqual(
            {ok, <<"value">>},
            bondy_secret_resolver:resolve(#{
                provider => env, var => list_to_binary(?VAR)
            })
        )
    after
        os:unsetenv(?VAR)
    end.

env_base64_decodes_test() ->
    Raw = crypto:strong_rand_bytes(32),
    os:putenv(?VAR, binary_to_list(base64:encode(Raw))),
    try
        ?assertEqual(
            {ok, Raw},
            bondy_secret_resolver:resolve(#{
                provider => env, var => ?VAR, encoding => base64
            })
        )
    after
        os:unsetenv(?VAR)
    end.

env_missing_is_error_test() ->
    os:unsetenv(?VAR),
    ?assertEqual(
        {error, {missing_env, ?VAR}},
        bondy_secret_resolver:resolve(#{provider => env, var => ?VAR})
    ).

env_empty_is_missing_test() ->
    os:putenv(?VAR, ""),
    try
        ?assertEqual(
            {error, {missing_env, ?VAR}},
            bondy_secret_resolver:resolve(#{provider => env, var => ?VAR})
        )
    after
        os:unsetenv(?VAR)
    end.

env_bad_base64_is_error_test() ->
    %% A value that cannot be valid base64 (odd length, illegal chars).
    os:putenv(?VAR, "!!!not-base64!!!"),
    try
        ?assertEqual(
            {error, {invalid_base64, env}},
            bondy_secret_resolver:resolve(#{
                provider => env, var => ?VAR, encoding => base64
            })
        )
    after
        os:unsetenv(?VAR)
    end.

%% =============================================================================
%% dispatch / validation
%% =============================================================================

unknown_provider_is_error_test() ->
    ?assertEqual(
        {error, {provider_unavailable, no_such_provider_xyz}},
        bondy_secret_resolver:resolve(#{provider => no_such_provider_xyz})
    ).

invalid_ref_is_error_test() ->
    ?assertMatch(
        {error, {invalid_ref, _}},
        bondy_secret_resolver:resolve(#{no_provider_key => true})
    ).

%% =============================================================================
%% register_provider override
%% =============================================================================

register_provider_override_test() ->
    %% Register this test module as the `mock` provider; resolve dispatches to
    %% our fetch/1.
    ok = bondy_secret_resolver:register_provider(mock, ?MODULE),
    try
        ?assertEqual(
            {ok, <<"mock-secret">>},
            bondy_secret_resolver:resolve(#{provider => mock})
        ),
        %% base64 encoding still applies over an override provider.
        Raw = crypto:strong_rand_bytes(16),
        ok = bondy_secret_resolver:register_provider(mock64, ?MODULE),
        put(mock_value, base64:encode(Raw)),
        ?assertEqual(
            {ok, Raw},
            bondy_secret_resolver:resolve(#{
                provider => mock64, encoding => base64
            })
        )
    after
        persistent_term:erase({bondy_secret_resolver, provider, mock}),
        persistent_term:erase({bondy_secret_resolver, provider, mock64}),
        erase(mock_value)
    end.

%% Provider callback used by register_provider_override_test.
fetch(#{provider := mock}) ->
    {ok, <<"mock-secret">>};
fetch(#{provider := mock64}) ->
    {ok, get(mock_value)}.
