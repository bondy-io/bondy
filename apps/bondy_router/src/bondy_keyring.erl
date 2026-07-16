%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_keyring).
-moduledoc """
The node's data-encryption keyring: resolves an operator-provided **master key**
(a key-encryption key) once via `bondy_secret_resolver`, caches it, and offers
authenticated encryption (AES-256-GCM) for secret material at rest — today the
realm signing/encryption keys (`bondy_realm`), and, when wired, the WAL body
codec.

The master key is a **32-byte** binary. It is named by a
`bondy_secret_resolver:ref()` under the `security.master_key` config key, e.g.

```erlang
#{provider => env, var => "BONDY_SECRET_KEY", encoding => base64}
#{provider => aws_sm, secret_id => <<"...">>, region => <<"...">>,
  field => <<"master_key">>, encoding => base64}
```

Encryption is **opt-in**: with no `security.master_key` configured, `is_enabled/0`
is `false` and callers store plaintext (backward-compatible). When configured but
the key cannot be resolved or is malformed, the keyring **fails closed** — it
never silently downgrades to plaintext.

This module implements the `bondy_oplog_wal_key_registry` behaviour
(`current_key/0`, `lookup_key/1`) so the same master key can back WAL body
encryption. A rotation-aware `key_id` is baked into every envelope; today a
single current key is served, and `lookup_key/1` resolves only the current id
(older ids are reserved for a future multi-key rotation set).

## Envelope format

```
<<Algo:8, KeyId:16/big-unsigned, IV:12/binary, Tag:16/binary, Ciphertext/binary>>
```

`Algo = 1` (AES-256-GCM). The `seal/2`,`open/2` variants bind caller-supplied
Additional Authenticated Data (AAD) — e.g. a realm URI + kid — so an envelope
cannot be lifted from one context to another.
""".

-behaviour(bondy_oplog_wal_key_registry).

-include_lib("kernel/include/logger.hrl").

-define(ALGO_AES_256_GCM, 1).
-define(IV_SIZE, 12).
-define(TAG_SIZE, 16).
-define(KEY_SIZE, 32).
-define(CACHE_KEY(KeyId), {?MODULE, master_key, KeyId}).
-define(DEFAULT_KEY_ID, 1).

-type key_id() :: bondy_oplog_wal_key_registry:key_id().
-type cipher_key() :: bondy_oplog_wal_key_registry:cipher_key().
-type envelope() :: binary().

-export_type([envelope/0]).

%% API
-export([is_enabled/0]).
-export([seal/1]).
-export([seal/2]).
-export([open/1]).
-export([open/2]).
-export([reset_cache/0]).

%% BONDY_OPLOG_WAL_KEY_REGISTRY CALLBACKS
-export([current_key/0]).
-export([lookup_key/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Returns `true` if a master key is configured (`security.master_key`), so
at-rest encryption is active. Returns `false` when unset — callers then store
plaintext (backward-compatible).
""".
-spec is_enabled() -> boolean().

is_enabled() ->
    master_key_ref() =/= undefined.

-doc "Equivalent to `seal(Plaintext, <<>>)`.".
-spec seal(Plaintext :: binary()) -> envelope().

seal(Plaintext) ->
    seal(Plaintext, <<>>).

-doc """
Encrypts `Plaintext` with the current master key under AES-256-GCM, binding
`AAD` as additional authenticated data, and returns the self-describing
envelope. Fails closed (raises) if the master key is unavailable.
""".
-spec seal(Plaintext :: binary(), AAD :: binary()) -> envelope().

seal(Plaintext, AAD) when is_binary(Plaintext) andalso is_binary(AAD) ->
    {KeyId, Key} = current_key(),
    IV = crypto:strong_rand_bytes(?IV_SIZE),
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(
        aes_256_gcm, Key, IV, Plaintext, AAD, true
    ),
    <<?ALGO_AES_256_GCM:8, KeyId:16/big-unsigned, IV/binary, Tag/binary,
        Ciphertext/binary>>.

-doc "Equivalent to `open(Envelope, <<>>)`.".
-spec open(Envelope :: envelope()) ->
    {ok, binary()} | {error, term()}.

open(Envelope) ->
    open(Envelope, <<>>).

-doc """
Decrypts an envelope produced by `seal/2` with the same `AAD`. Returns
`{error, {missing_key, KeyId}}` if the envelope's key id cannot be resolved,
`{error, decrypt_failed}` on a tag/AAD mismatch, and `{error, {unsupported_algo,
_}}`/`{error, bad_envelope}` for a malformed envelope.
""".
-spec open(Envelope :: envelope(), AAD :: binary()) ->
    {ok, binary()} | {error, term()}.

open(
    <<?ALGO_AES_256_GCM:8, KeyId:16/big-unsigned, IV:?IV_SIZE/binary,
        Tag:?TAG_SIZE/binary, Ciphertext/binary>>,
    AAD
) when is_binary(AAD) ->
    case lookup_key(KeyId) of
        {ok, Key} ->
            case
                crypto:crypto_one_time_aead(
                    aes_256_gcm, Key, IV, Ciphertext, AAD, Tag, false
                )
            of
                error ->
                    {error, decrypt_failed};
                Plaintext when is_binary(Plaintext) ->
                    {ok, Plaintext}
            end;
        {error, missing} ->
            {error, {missing_key, KeyId}}
    end;
open(<<Algo:8, _/binary>>, _AAD) when Algo =/= ?ALGO_AES_256_GCM ->
    {error, {unsupported_algo, Algo}};
open(_Other, _AAD) ->
    {error, bad_envelope}.

-doc """
Clears the cached master key(s). Intended for tests and for forcing a re-read
after the operator rotates the underlying secret.
""".
-spec reset_cache() -> ok.

reset_cache() ->
    _ = [
        persistent_term:erase(K)
     || {K, _} <- persistent_term:get(),
        is_tuple(K),
        tuple_size(K) =:= 3,
        element(1, K) =:= ?MODULE,
        element(2, K) =:= master_key
    ],
    ok.

%% =============================================================================
%% BONDY_OPLOG_WAL_KEY_REGISTRY CALLBACKS
%% =============================================================================

-doc """
Returns the writer's current `{KeyId, Key}`. Resolves and caches the master key
on first use. Raises `{master_key_unavailable, Reason}` when encryption is
configured but the key cannot be resolved (fail-closed).
""".
-spec current_key() -> {key_id(), cipher_key()}.

current_key() ->
    KeyId = current_key_id(),
    {KeyId, resolve_key(KeyId)}.

-doc """
Resolves a key by id. Serves only the current key id today; other ids return
`{error, missing}` (reserved for a future multi-key rotation set).
""".
-spec lookup_key(key_id()) -> {ok, cipher_key()} | {error, missing}.

lookup_key(KeyId) ->
    case KeyId =:= current_key_id() of
        true ->
            try
                {ok, resolve_key(KeyId)}
            catch
                _:_ ->
                    {error, missing}
            end;
        false ->
            {error, missing}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Build the `bondy_secret_resolver:ref()` for the master key from config. The
%% whole `[security, master_key]` value is read once and its fields extracted
%% in-memory — reading deeper paths (e.g. `[security, master_key, provider]`)
%% would crash when the key is unset (`undefined`, not a container). Accepts both
%% the flat ref set programmatically in tests (`#{provider, var, ...}`) and the
%% nested schema shape (`#{provider, env => #{var}, aws_sm => #{...}}`).
master_key_ref() ->
    case master_key_config() of
        MK when is_map(MK) ->
            build_ref(maps:get(provider, MK, none), MK);
        _ ->
            undefined
    end.

%% @private
master_key_config() ->
    bondy_config:get([security, master_key], undefined).

%% @private
build_ref(none, _MK) ->
    undefined;
build_ref(env, MK) ->
    #{
        provider => env,
        var => sub(MK, var, [env, var]),
        encoding => maps:get(encoding, MK, base64)
    };
build_ref(aws_sm, MK) ->
    Base = #{
        provider => aws_sm,
        secret_id => sub(MK, secret_id, [aws_sm, secret_id]),
        region => sub(MK, region, [aws_sm, region]),
        encoding => maps:get(encoding, MK, base64)
    },
    case sub(MK, field, [aws_sm, field]) of
        undefined -> Base;
        Field -> Base#{field => Field}
    end;
build_ref(_Other, _MK) ->
    undefined.

%% @private
%% Read a value that may be present at the top level (`Key`, flat test ref) or
%% under a nested `Path` (schema shape).
sub(MK, Key, Path) ->
    case maps:get(Key, MK, undefined) of
        undefined -> nested_get(MK, Path);
        V -> V
    end.

%% @private
nested_get(MK, [K]) when is_map(MK) ->
    maps:get(K, MK, undefined);
nested_get(MK, [K | Rest]) when is_map(MK) ->
    nested_get(maps:get(K, MK, undefined), Rest);
nested_get(_, _) ->
    undefined.

%% @private
current_key_id() ->
    case master_key_config() of
        MK when is_map(MK) -> maps:get(id, MK, ?DEFAULT_KEY_ID);
        _ -> ?DEFAULT_KEY_ID
    end.

%% @private
%% Resolves + caches the master key for `KeyId`. Raises on any failure so the
%% caller fails closed rather than encrypting/decrypting with a bad key.
resolve_key(KeyId) ->
    case persistent_term:get(?CACHE_KEY(KeyId), undefined) of
        Key when is_binary(Key) ->
            Key;
        undefined ->
            Key = do_resolve_key(),
            persistent_term:put(?CACHE_KEY(KeyId), Key),
            Key
    end.

%% @private
do_resolve_key() ->
    case master_key_ref() of
        undefined ->
            error(master_key_not_configured);
        Ref ->
            case bondy_secret_resolver:resolve(Ref) of
                {ok, Key} when byte_size(Key) =:= ?KEY_SIZE ->
                    Key;
                {ok, Other} ->
                    ?LOG_ERROR(#{
                        description =>
                            "Master key has an invalid size; expected 32 bytes",
                        size => byte_size(Other)
                    }),
                    error({master_key_unavailable, invalid_key_size});
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        description => "Could not resolve the master key",
                        reason => Reason
                    }),
                    error({master_key_unavailable, Reason})
            end
    end.
