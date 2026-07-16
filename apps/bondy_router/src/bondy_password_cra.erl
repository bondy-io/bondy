%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_password_cra).
-moduledoc """
Server-side WAMP-CRA password storage.

The cryptographic algorithm lives in `bondy_wamp_cra` (the router-independent
single source of truth shared with the WAMP client). This module keeps the
server-only concerns: building a `bondy_password:t()` and supplying defaults
(`kdf`, `iterations`) from `bondy_config` when the caller omits them.
""".

-type data() :: bondy_wamp_cra:data().
-type params() :: bondy_wamp_cra:params().

-export_type([data/0]).
-export_type([params/0]).

-export([compare/2]).
-export([hash_function/0]).
-export([hash_length/0]).
-export([new/3]).
-export([nonce/0]).
-export([nonce_length/0]).
-export([salt/0]).
-export([salt_length/0]).
-export([salted_password/3]).
-export([validate_params/1]).
-export([verify_string/3]).

%% =============================================================================
%% API
%% =============================================================================

-spec new(binary(), params(), fun((data(), params()) -> bondy_password:t())) ->
    bondy_password:t() | no_return().

new(Password, Params0, Builder) ->
    Params1 = validate_params(Params0),

    {Salt, Params} =
        case maps:take(salt, Params1) of
            {Bytes, Params2} ->
                byte_size(Bytes) == salt_length() orelse error(badarg),
                {base64:encode(Bytes), Params2};
            error ->
                {salt(), Params1}
        end,

    SPassword = salted_password(Password, Salt, Params),
    Data = #{
        salt => Salt,
        salted_password => SPassword
    },
    Builder(Data, Params).

-spec verify_string(binary(), data(), params()) -> boolean().

verify_string(String, Data, Params) ->
    bondy_wamp_cra:verify_string(String, Data, Params).

-doc """
Validates the CRA params, filling `kdf` and `iterations` from `bondy_config`
when absent.
""".
-spec validate_params(Params :: params()) ->
    Validated :: params() | no_return().

validate_params(Params0) ->
    Params1 = validate_kdf(Params0),
    Params2 = validate_iterations(Params1),
    bondy_wamp_cra:validate_params(Params2).

-spec hash_function() -> atom().

hash_function() ->
    bondy_wamp_cra:hash_function().

-spec hash_length() -> integer().

hash_length() ->
    bondy_wamp_cra:hash_length().

-spec salt_length() -> integer().

salt_length() ->
    bondy_wamp_cra:salt_length().

-spec nonce_length() -> integer().

nonce_length() ->
    bondy_wamp_cra:nonce_length().

-spec salt() -> binary().

salt() ->
    bondy_wamp_cra:salt().

-doc "A base64 encoded 128-bit random value.".
-spec nonce() -> binary().

nonce() ->
    bondy_wamp_cra:nonce().

-doc "Returns the 64 encoded salted password.".
-spec salted_password(binary(), binary(), map()) -> binary().

salted_password(Password, Salt, Params) ->
    bondy_wamp_cra:salted_password(Password, Salt, Params).

-spec compare(binary(), binary()) -> boolean().

compare(A, B) ->
    bondy_wamp_cra:compare(A, B).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
validate_kdf(#{kdf := pbkdf2} = Params) ->
    Params;
validate_kdf(#{kdf := _}) ->
    error({invalid_argument, kdf});
validate_kdf(Params) ->
    Default = bondy_config:get([security, password, cra, kdf]),
    maps:put(kdf, Default, Params).

%% @private
validate_iterations(#{iterations := N} = Params) when
    N >= 4096 andalso N =< 10000000
->
    Params;
validate_iterations(#{iterations := _}) ->
    error({invalid_argument, iterations});
validate_iterations(Params) ->
    Default = bondy_config:get([security, password, pbkdf2, iterations]),
    maps:put(iterations, Default, Params).
