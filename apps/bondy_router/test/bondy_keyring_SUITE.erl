%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_keyring_SUITE).
-moduledoc """
`bondy_keyring` (master-key resolution + AES-256-GCM seal/open +
the WAL key-registry behaviour).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(ENV_VAR, "BONDY_KEYRING_SUITE_MASTER_KEY").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        disabled_when_unconfigured,
        seal_open_roundtrip,
        seal_open_with_aad,
        open_wrong_aad_fails,
        open_tampered_envelope_fails,
        current_key_shape,
        lookup_key_only_current_id,
        fail_closed_missing_env,
        fail_closed_invalid_key_size,
        works_as_wal_key_registry
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

init_per_testcase(_Case, Config) ->
    ok = bondy_keyring:reset_cache(),
    Config.

end_per_testcase(_Case, _Config) ->
    os:unsetenv(?ENV_VAR),
    ok = bondy_config:set([security, master_key], undefined),
    ok = bondy_keyring:reset_cache(),
    ok.

%% =============================================================================
%% HELPERS
%% =============================================================================

configure_env_key(KeyBytes) ->
    os:putenv(?ENV_VAR, binary_to_list(base64:encode(KeyBytes))),
    ok = bondy_config:set([security, master_key], #{
        provider => env, var => ?ENV_VAR, encoding => base64
    }),
    ok = bondy_keyring:reset_cache().

new_key() ->
    crypto:strong_rand_bytes(32).

%% =============================================================================
%% TESTS
%% =============================================================================

disabled_when_unconfigured(_Config) ->
    ok = bondy_config:set([security, master_key], undefined),
    ?assertEqual(false, bondy_keyring:is_enabled()).

seal_open_roundtrip(_Config) ->
    configure_env_key(new_key()),
    ?assert(bondy_keyring:is_enabled()),

    Plaintext = <<"realm private key material", 0, 1, 2, 3>>,
    Envelope = bondy_keyring:seal(Plaintext),
    ?assert(is_binary(Envelope)),
    ?assertNotEqual(Plaintext, Envelope),
    ?assertEqual({ok, Plaintext}, bondy_keyring:open(Envelope)).

seal_open_with_aad(_Config) ->
    configure_env_key(new_key()),
    Plaintext = <<"secret">>,
    AAD = <<"com.example.realm|kid-42">>,
    Envelope = bondy_keyring:seal(Plaintext, AAD),
    ?assertEqual({ok, Plaintext}, bondy_keyring:open(Envelope, AAD)).

open_wrong_aad_fails(_Config) ->
    configure_env_key(new_key()),
    Envelope = bondy_keyring:seal(<<"secret">>, <<"aad-a">>),
    %% A different AAD must fail the GCM tag check.
    ?assertEqual(
        {error, decrypt_failed}, bondy_keyring:open(Envelope, <<"aad-b">>)
    ),
    %% ... and so must a missing AAD.
    ?assertEqual({error, decrypt_failed}, bondy_keyring:open(Envelope)).

open_tampered_envelope_fails(_Config) ->
    configure_env_key(new_key()),
    Envelope = bondy_keyring:seal(<<"secret payload">>),
    %% Flip the last ciphertext byte.
    Size = byte_size(Envelope),
    <<Head:(Size - 1)/binary, Last>> = Envelope,
    Tampered = <<Head/binary, (Last bxor 16#FF)>>,
    ?assertEqual({error, decrypt_failed}, bondy_keyring:open(Tampered)),

    %% Unknown algo / malformed envelopes are well-typed errors, not crashes.
    ?assertMatch(
        {error, {unsupported_algo, _}}, bondy_keyring:open(<<99, 0, 0>>)
    ),
    ?assertEqual({error, bad_envelope}, bondy_keyring:open(<<>>)).

current_key_shape(_Config) ->
    Key = new_key(),
    configure_env_key(Key),
    {KeyId, Resolved} = bondy_keyring:current_key(),
    ?assert(is_integer(KeyId)),
    ?assertEqual(Key, Resolved),
    ?assertEqual(32, byte_size(Resolved)).

lookup_key_only_current_id(_Config) ->
    Key = new_key(),
    configure_env_key(Key),
    {KeyId, _} = bondy_keyring:current_key(),
    ?assertEqual({ok, Key}, bondy_keyring:lookup_key(KeyId)),
    %% A different id is not served (reserved for future rotation set).
    ?assertEqual({error, missing}, bondy_keyring:lookup_key(KeyId + 7)).

fail_closed_missing_env(_Config) ->
    %% Configured to use the env provider, but the variable is absent → the
    %% keyring must raise, never silently downgrade to plaintext.
    os:unsetenv(?ENV_VAR),
    ok = bondy_config:set([security, master_key], #{
        provider => env, var => ?ENV_VAR, encoding => base64
    }),
    ok = bondy_keyring:reset_cache(),
    ?assert(bondy_keyring:is_enabled()),
    ?assertError({master_key_unavailable, _}, bondy_keyring:current_key()),
    ?assertError({master_key_unavailable, _}, bondy_keyring:seal(<<"x">>)).

fail_closed_invalid_key_size(_Config) ->
    %% A key that is not 32 bytes must fail closed.
    os:putenv(?ENV_VAR, binary_to_list(base64:encode(<<"too-short">>))),
    ok = bondy_config:set([security, master_key], #{
        provider => env, var => ?ENV_VAR, encoding => base64
    }),
    ok = bondy_keyring:reset_cache(),
    ?assertError(
        {master_key_unavailable, invalid_key_size},
        bondy_keyring:current_key()
    ).

works_as_wal_key_registry(_Config) ->
    %% The keyring is the production implementation of the
    %% `bondy_oplog_wal_key_registry` behaviour: the WAL codec accepts it and a
    %% body round-trips through encrypt/decrypt using current_key/0 + lookup_key/1.
    configure_env_key(new_key()),
    ?assertEqual(
        ok, bondy_oplog_wal_codec:validate_encryption({enabled, bondy_keyring})
    ),
    Opts = #{body_encryption => {enabled, bondy_keyring}},
    Body = <<"a wal frame body", 0, 1, 2, 255>>,
    {Flags, Envelope} = bondy_oplog_wal_codec:encode_body(Body, Opts),
    Bin = iolist_to_binary(Envelope),
    ?assertNotEqual(Body, Bin),
    ?assertEqual(
        {ok, Body}, bondy_oplog_wal_codec:decode_body(Bin, Flags, Opts)
    ).
