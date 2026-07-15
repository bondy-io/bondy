%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_cra_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile([nowarn_export_all, export_all]).

-define(P1, <<"aWe11KeptSecret">>).
-define(P2, <<"An0therWe11KeptSecret">>).

all() ->
    [
        %% Constants
        constants,

        %% Random material
        salt_is_random_base64,
        nonce_is_random_base64,

        %% salted_password
        salted_password_deterministic,
        salted_password_salt_sensitive,

        %% response (kernel + client) round-trips
        response_kernel_matches_legacy,
        client_response_matches_server_expected,
        client_response_wrong_password_fails,
        client_response_unsalted,
        full_cra_round_trip,

        %% params validation
        validate_params_fills_static,
        validate_params_rejects_bad_kdf,
        validate_params_rejects_low_iterations,
        validate_params_rejects_high_iterations,

        %% verify_string / compare
        verify_string_ok,
        verify_string_wrong,
        compare_constant_time
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    Config.

end_per_suite(_) ->
    ok.

%% @private
params(Iterations, KeyLen) ->
    #{
        kdf => pbkdf2,
        iterations => Iterations,
        hash_function => bondy_wamp_cra:hash_function(),
        hash_length => KeyLen
    }.

%% =============================================================================
%% CONSTANTS
%% =============================================================================

constants(_) ->
    ?assertEqual(sha256, bondy_wamp_cra:hash_function()),
    ?assertEqual(32, bondy_wamp_cra:hash_length()),
    ?assertEqual(16, bondy_wamp_cra:salt_length()),
    ?assertEqual(16, bondy_wamp_cra:nonce_length()).

%% =============================================================================
%% RANDOM MATERIAL
%% =============================================================================

salt_is_random_base64(_) ->
    S1 = bondy_wamp_cra:salt(),
    S2 = bondy_wamp_cra:salt(),
    ?assertNotEqual(S1, S2),
    %% base64 of 16 bytes -> 24 chars
    ?assertEqual(16, byte_size(base64:decode(S1))).

nonce_is_random_base64(_) ->
    N1 = bondy_wamp_cra:nonce(),
    N2 = bondy_wamp_cra:nonce(),
    ?assertNotEqual(N1, N2),
    ?assertEqual(16, byte_size(base64:decode(N1))).

%% =============================================================================
%% SALTED PASSWORD
%% =============================================================================

salted_password_deterministic(_) ->
    Salt = bondy_wamp_cra:salt(),
    P = params(4096, 32),
    ?assertEqual(
        bondy_wamp_cra:salted_password(?P1, Salt, P),
        bondy_wamp_cra:salted_password(?P1, Salt, P)
    ).

salted_password_salt_sensitive(_) ->
    P = params(4096, 32),
    A = bondy_wamp_cra:salted_password(?P1, bondy_wamp_cra:salt(), P),
    B = bondy_wamp_cra:salted_password(?P1, bondy_wamp_cra:salt(), P),
    ?assertNotEqual(A, B).

%% =============================================================================
%% RESPONSE ROUND-TRIPS
%% =============================================================================

%% The kernel response/2 must equal the historical formula so that previously
%% stored expectations keep verifying.
response_kernel_matches_legacy(_) ->
    Salt = bondy_wamp_cra:salt(),
    SPass = bondy_wamp_cra:salted_password(?P1, Salt, params(4096, 32)),
    Challenge = <<"{\"nonce\":\"abc\",\"authid\":\"u\"}">>,
    Legacy = base64:encode(crypto:mac(hmac, sha256, SPass, Challenge)),
    ?assertEqual(Legacy, bondy_wamp_cra:response(Challenge, SPass)).

%% The client's response/3 (raw password + challenge extra) must equal the
%% server's expected response/2 (pre-salted password).
client_response_matches_server_expected(_) ->
    Salt = bondy_wamp_cra:salt(),
    Iter = 4096,
    KeyLen = bondy_wamp_cra:hash_length(),
    SPass = bondy_wamp_cra:salted_password(?P1, Salt, params(Iter, KeyLen)),
    Challenge = <<"{\"nonce\":\"xyz\"}">>,

    ServerExpected = bondy_wamp_cra:response(Challenge, SPass),
    ClientResponse = bondy_wamp_cra:response(Challenge, ?P1, #{
        salt => Salt, iterations => Iter, keylen => KeyLen
    }),
    ?assertEqual(ServerExpected, ClientResponse),
    ?assert(bondy_wamp_cra:compare(ServerExpected, ClientResponse)).

client_response_wrong_password_fails(_) ->
    Salt = bondy_wamp_cra:salt(),
    Iter = 4096,
    KeyLen = bondy_wamp_cra:hash_length(),
    SPass = bondy_wamp_cra:salted_password(?P1, Salt, params(Iter, KeyLen)),
    Challenge = <<"{\"nonce\":\"xyz\"}">>,

    ServerExpected = bondy_wamp_cra:response(Challenge, SPass),
    WrongResponse = bondy_wamp_cra:response(Challenge, ?P2, #{
        salt => Salt, iterations => Iter, keylen => KeyLen
    }),
    ?assertNotEqual(ServerExpected, WrongResponse),
    ?assertNot(bondy_wamp_cra:compare(ServerExpected, WrongResponse)).

client_response_unsalted(_) ->
    Challenge = <<"{\"nonce\":\"xyz\"}">>,
    %% No salt in params -> raw password is the HMAC key
    Resp = bondy_wamp_cra:response(Challenge, ?P1, #{}),
    ?assertEqual(bondy_wamp_cra:response(Challenge, ?P1), Resp).

%% Simulate the full WAMP-CRA exchange purely with bondy_wamp_cra:
%%   server: salt + derive expected; client: response/3; server: compare.
full_cra_round_trip(_) ->
    Iter = 8192,
    KeyLen = bondy_wamp_cra:hash_length(),
    Salt = bondy_wamp_cra:salt(),

    %% Server stores the salted password and issues a challenge
    SPass = bondy_wamp_cra:salted_password(?P1, Salt, params(Iter, KeyLen)),
    Challenge = bondy_wamp_cra:nonce(),
    Expected = bondy_wamp_cra:response(Challenge, SPass),

    %% Client, given only the raw password and the CHALLENGE.Extra, responds
    ClientSig = bondy_wamp_cra:response(Challenge, ?P1, #{
        salt => Salt, iterations => Iter, keylen => KeyLen
    }),

    %% Server verifies
    ?assert(bondy_wamp_cra:compare(Expected, ClientSig)).

%% =============================================================================
%% PARAMS VALIDATION
%% =============================================================================

validate_params_fills_static(_) ->
    Validated = bondy_wamp_cra:validate_params(#{
        kdf => pbkdf2, iterations => 4096
    }),
    ?assertEqual(sha256, maps:get(hash_function, Validated)),
    ?assertEqual(32, maps:get(hash_length, Validated)),
    ?assertEqual(16, maps:get(salt_length, Validated)),
    ?assertEqual(4096, maps:get(iterations, Validated)).

validate_params_rejects_bad_kdf(_) ->
    ?assertError(
        {invalid_argument, kdf},
        bondy_wamp_cra:validate_params(#{kdf => bcrypt, iterations => 4096})
    ).

validate_params_rejects_low_iterations(_) ->
    ?assertError(
        {invalid_argument, iterations},
        bondy_wamp_cra:validate_params(#{kdf => pbkdf2, iterations => 1})
    ).

validate_params_rejects_high_iterations(_) ->
    ?assertError(
        {invalid_argument, iterations},
        bondy_wamp_cra:validate_params(#{kdf => pbkdf2, iterations => 100000})
    ).

%% =============================================================================
%% VERIFY_STRING / COMPARE
%% =============================================================================

verify_string_ok(_) ->
    Salt = bondy_wamp_cra:salt(),
    Params = params(4096, 32),
    SPass = bondy_wamp_cra:salted_password(?P1, Salt, Params),
    Data = #{salt => Salt, salted_password => SPass},
    ?assert(bondy_wamp_cra:verify_string(?P1, Data, Params)).

verify_string_wrong(_) ->
    Salt = bondy_wamp_cra:salt(),
    Params = params(4096, 32),
    SPass = bondy_wamp_cra:salted_password(?P1, Salt, Params),
    Data = #{salt => Salt, salted_password => SPass},
    ?assertNot(bondy_wamp_cra:verify_string(?P2, Data, Params)).

compare_constant_time(_) ->
    ?assert(bondy_wamp_cra:compare(<<"abc">>, <<"abc">>)),
    ?assertNot(bondy_wamp_cra:compare(<<"abc">>, <<"abd">>)),
    %% crypto:hash_equals/2 requires equal-length inputs; unequal lengths raise
    %% badarg (preserved from the legacy bondy_password_cra:compare/2).
    ?assertError(badarg, bondy_wamp_cra:compare(<<"abc">>, <<"abcd">>)).
