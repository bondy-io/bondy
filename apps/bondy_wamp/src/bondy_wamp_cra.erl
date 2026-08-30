%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_cra).

-moduledoc """
Pure, router-independent primitives for the WAMP **Challenge-Response
Authentication** (WAMP-CRA) method.

This is the single source of truth for WAMP-CRA in the Bondy monorepo: the
server (`bondy_password_cra` and `bondy_auth_wamp_cra`, which delegate here) and
the WAMP client (`bondy_connect_sdk`) share these functions so that the response
computed by the client matches the one expected by the server.

WAMP-CRA derives a key from the user's secret with PBKDF2 (`salted_password/3`)
and signs the server-issued challenge with HMAC-SHA256 (`response/2`). Following
the historical Bondy convention, the HMAC **key is the base64 representation of
the derived password** (not its raw bytes) — `response/3` and `salted_password/3`
preserve this so client and server agree.

Unlike the legacy `bondy_password_cra`, this module performs **no configuration
lookups**: every parameter is supplied by the caller. The server shim keeps its
own defaults and delegates the algorithm here.
""".

-define(SALT_LENGTH, 16).
-define(NONCE_LENGTH, 16).
-define(HASH_FUNCTION, sha256).
-define(HASH_LENGTH, 32).

-type data() :: #{
    salt := binary(),
    salted_password := binary()
}.
-type params() :: #{
    kdf := kdf(),
    iterations := non_neg_integer(),
    hash_function := hash_fun(),
    hash_length := non_neg_integer(),
    salt => binary(),
    salt_length := non_neg_integer()
}.
-type kdf() :: pbkdf2.
-type hash_fun() :: sha256.

-export_type([data/0]).
-export_type([params/0]).
-export_type([kdf/0]).
-export_type([hash_fun/0]).

%% Parameters / constants
-export([hash_function/0]).
-export([hash_length/0]).
-export([salt_length/0]).
-export([nonce_length/0]).
-export([validate_params/1]).

%% Random material
-export([salt/0]).
-export([nonce/0]).

%% Algorithm
-export([salted_password/3]).
-export([response/2]).
-export([response/3]).
-export([compare/2]).
-export([verify_string/3]).

%% =============================================================================
%% API: PARAMETERS / CONSTANTS
%% =============================================================================

-doc "The hash function used by WAMP-CRA (`sha256`).".
-spec hash_function() -> hash_fun().

hash_function() ->
    ?HASH_FUNCTION.

-doc "The derived-key length in bytes (`32`).".
-spec hash_length() -> pos_integer().

hash_length() ->
    ?HASH_LENGTH.

-doc "The salt length in bytes (`16`).".
-spec salt_length() -> pos_integer().

salt_length() ->
    ?SALT_LENGTH.

-doc "The nonce length in bytes (`16`).".
-spec nonce_length() -> pos_integer().

nonce_length() ->
    ?NONCE_LENGTH.

-doc """
Validates a CRA parameter map, merging in the static fields
(`hash_function`, `hash_length`, `salt_length`).

Requires `kdf` and `iterations` to be present and valid; unlike the legacy
`bondy_password_cra`, it performs **no** configuration lookup for defaults.
""".
-spec validate_params(Params :: map()) -> params() | no_return().

validate_params(#{kdf := pbkdf2, iterations := N} = Params) when
    is_integer(N) andalso N >= 4096 andalso N =< 10000000
->
    Static = #{
        hash_function => hash_function(),
        hash_length => hash_length(),
        salt_length => salt_length()
    },
    maps:merge(Params, Static);
validate_params(#{kdf := pbkdf2, iterations := _}) ->
    error({invalid_argument, iterations});
validate_params(#{iterations := _}) ->
    error({invalid_argument, kdf});
validate_params(_) ->
    error({invalid_argument, kdf}).

%% =============================================================================
%% API: RANDOM MATERIAL
%% =============================================================================

-doc "A base64-encoded 128-bit random salt.".
-spec salt() -> binary().

salt() ->
    base64:encode(crypto:strong_rand_bytes(salt_length())).

-doc "A base64-encoded 128-bit random nonce.".
-spec nonce() -> binary().

nonce() ->
    base64:encode(crypto:strong_rand_bytes(nonce_length())).

%% =============================================================================
%% API: ALGORITHM
%% =============================================================================

-doc """
Derives the salted password, returning its **base64-encoded** value.

`Params` must contain `kdf => pbkdf2`, `iterations`, `hash_function` and
`hash_length`. The base64 encoding is significant: it is the value used as the
HMAC key in `response/2`, so both sides must agree on it.
""".
-spec salted_password(
    Password :: binary(), Salt :: binary(), Params :: params()
) -> binary().

salted_password(Password, Salt, #{kdf := pbkdf2} = Params) ->
    #{
        iterations := Iterations,
        hash_function := HashFun,
        hash_length := HashLen
    } = Params,
    Derived = crypto:pbkdf2_hmac(HashFun, Password, Salt, Iterations, HashLen),
    base64:encode(Derived).

-doc """
Computes the WAMP-CRA response: `base64(HMAC-SHA256(SecretKey, Challenge))`.

This is the shared kernel used by both peers. On the server `SecretKey` is the
stored base64 salted password; on the client it is the base64 salted password
derived from the user's secret (see `response/3`) or, for unsalted CRA, the
shared secret itself.
""".
-spec response(Challenge :: binary(), SecretKey :: binary()) -> binary().

response(Challenge, SecretKey) ->
    base64:encode(crypto:mac(hmac, ?HASH_FUNCTION, SecretKey, Challenge)).

-doc """
Client-side convenience: computes the response from the user's raw `Password`
and the parameters carried in the `CHALLENGE.Extra`.

When `Params` carries a `salt` (salted/PBKDF2 password), the salted password is
derived using `salt`, `iterations` and `keylen` and used as the HMAC key.
Otherwise (`Params` without `salt`) the raw `Password` is used directly as the
shared secret.
""".
-spec response(
    Challenge :: binary(), Password :: binary(), Params :: map()
) -> binary().

response(Challenge, Password, #{salt := Salt} = Params) ->
    SPassword = salted_password(Password, Salt, #{
        kdf => pbkdf2,
        iterations => maps:get(iterations, Params),
        hash_function => hash_function(),
        hash_length => maps:get(keylen, Params)
    }),
    response(Challenge, SPassword);
response(Challenge, Password, _Params) ->
    response(Challenge, Password).

-doc """
Constant-time comparison of two binaries.

The length check is deliberate and is not a timing leak: `crypto:hash_equals/2`
raises `badarg` on operands of different sizes, so without it this function
cannot be used on a wire-supplied value at all — which is why every caller
comparing an attacker-supplied secret needs it. A length difference is already
observable to whoever sent the value, so returning `false` early reveals
nothing the sender did not know.

Equal-length operands take the constant-time path, so the comparison does not
leak *where* two same-length values first differ, which is the property that
matters for a secret.
""".
-spec compare(binary(), binary()) -> boolean().

compare(A, B) when is_binary(A), is_binary(B), byte_size(A) =:= byte_size(B) ->
    crypto:hash_equals(A, B);

compare(A, B) when is_binary(A), is_binary(B) ->
    false.

-doc """
Verifies `String` against stored CRA `Data` (salt + salted_password) using
`Params`. Server-side helper used by password storage.
""".
-spec verify_string(String :: binary(), Data :: data(), Params :: params()) ->
    boolean().

verify_string(String, #{salt := Salt, salted_password := SPassword}, Params) ->
    compare(salted_password(String, Salt, Params), SPassword).
