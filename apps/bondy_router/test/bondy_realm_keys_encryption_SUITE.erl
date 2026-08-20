%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_realm_keys_encryption_SUITE).
-moduledoc """
realm signing/encryption keys encrypted at rest in the
`bondy_realm_keys` cell via `bondy_keyring`.

Proves: (1) with encryption off the layout is plaintext (backward-compatible);
(2) with encryption on the stored bundles are ciphertext envelopes — which is
also what `bondy_export` dumps — while the realm still signs and verifies JWTs;
(3) enabling encryption migrates existing plaintext keys on the next store,
idempotently.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_security.hrl").

-define(ENV_VAR, "BONDY_REALM_KEYS_ENC_SUITE_KEY").
-define(ENC_TAG, '$bondy_enc').
-define(BAND, <<>>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        plaintext_when_disabled,
        ciphertext_when_enabled,
        sign_verify_roundtrip_encrypted,
        store_is_idempotent_encrypted,
        migrates_plaintext_on_enable
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

init_per_testcase(_Case, Config) ->
    disable_encryption(),
    Config.

end_per_testcase(_Case, _Config) ->
    %% CRITICAL: leave encryption OFF so sibling suites are unaffected.
    disable_encryption(),
    ok.

%% =============================================================================
%% HELPERS
%% =============================================================================

enable_encryption() ->
    os:putenv(
        ?ENV_VAR, binary_to_list(base64:encode(crypto:strong_rand_bytes(32)))
    ),
    ok = bondy_config:set([security, master_key], #{
        provider => env, var => ?ENV_VAR, encoding => base64
    }),
    ok = bondy_keyring:reset_cache().

disable_encryption() ->
    os:unsetenv(?ENV_VAR),
    try
        bondy_config:set([security, master_key], undefined)
    catch
        _:_ -> ok
    end,
    try
        bondy_keyring:reset_cache()
    catch
        _:_ -> ok
    end,
    ok.

new_realm(Suffix) ->
    Uri = <<"com.example.test.realm_keys_enc.", Suffix/binary>>,
    _ = bondy_realm:create(#{
        uri => Uri,
        description => <<"realm-keys enc test">>,
        authmethods => [?WAMP_OAUTH2_AUTH, ?PASSWORD_AUTH],
        security_enabled => true
    }),
    Uri.

raw_keys(Uri) ->
    Table = bondy_namespace_catalog:table(bondy_realm_keys),
    case bondy_db:read(Table, ?BAND, Uri) of
        {ok, {KeysMap, _Hlc}} when is_map(KeysMap) -> KeysMap;
        {error, not_found} -> #{}
    end.

%% Collect the sensitive (private/encryption) field values across all bundles.
sensitive_values(KeysMap) ->
    lists:flatten([
        [
            V
         || F <- [private, encryption],
            V <- [maps:get(F, bundle_of(B), undefined)],
            V =/= undefined
        ]
     || {_Kid, B} <- maps:to_list(KeysMap)
    ]).

bundle_of([B | _]) -> B;
bundle_of(B) when is_map(B) -> B.

is_encrypted({?ENC_TAG, _}) -> true;
is_encrypted(_) -> false.

%% =============================================================================
%% TESTS
%% =============================================================================

plaintext_when_disabled(_Config) ->
    ?assertEqual(false, bondy_keyring:is_enabled()),
    Uri = new_realm(<<"plain">>),
    Vals = sensitive_values(raw_keys(Uri)),
    ?assert(Vals =/= []),
    %% None of the stored private keys is enc-tagged.
    ?assertEqual([], [V || V <- Vals, is_encrypted(V)]).

ciphertext_when_enabled(_Config) ->
    enable_encryption(),
    ?assert(bondy_keyring:is_enabled()),
    Uri = new_realm(<<"cipher">>),
    Vals = sensitive_values(raw_keys(Uri)),
    ?assert(Vals =/= []),
    %% EVERY stored sensitive field is an encryption envelope — this is exactly
    %% what a `bondy_export` backup would now contain (S-2 export leak closed).
    ?assertEqual(
        [],
        [V || V <- Vals, not is_encrypted(V)],
        "all sensitive key fields must be ciphertext at rest"
    ),
    %% And the raw ciphertext must not embed the plaintext key term.
    ?assertNot(
        lists:any(
            fun({?ENC_TAG, Env}) ->
                binary:match(Env, <<"jose_jwk">>) =/= nomatch
            end,
            Vals
        )
    ).

sign_verify_roundtrip_encrypted(_Config) ->
    enable_encryption(),
    Uri = new_realm(<<"roundtrip">>),

    %% Fetching the realm decrypts the keys back into the record; signing with
    %% the private key and verifying with the public key must round-trip.
    Realm = bondy_realm:fetch(Uri),
    {Kid, PrivKey} = bondy_realm:get_random_private_key(Realm),
    Claims = #{<<"sub">> => <<"alice">>, <<"n">> => 1},
    JWT = bondy_oauth_jwt:encode(Claims, PrivKey),
    PubKey = bondy_realm:get_public_key(Realm, Kid),
    ?assertMatch({true, {jose_jwt, _}, _}, jose_jwt:verify(PubKey, JWT)).

store_is_idempotent_encrypted(_Config) ->
    enable_encryption(),
    Uri = new_realm(<<"idem">>),
    Before = raw_keys(Uri),

    %% Re-applying config (an update that changes no key material) must NOT
    %% re-write the key cell — a fresh random IV each time would otherwise churn
    %% the aw-map and diverge cross-node.
    _ = bondy_realm:update(Uri, #{description => <<"changed desc">>}),
    After = raw_keys(Uri),
    ?assertEqual(Before, After).

migrates_plaintext_on_enable(_Config) ->
    %% Create with encryption OFF → plaintext keys.
    Uri = new_realm(<<"migrate">>),
    Plain = sensitive_values(raw_keys(Uri)),
    ?assertEqual([], [V || V <- Plain, is_encrypted(V)]),

    %% Enable encryption and trigger a store (a benign update). Existing
    %% plaintext keys migrate to ciphertext.
    enable_encryption(),
    _ = bondy_realm:update(Uri, #{description => <<"now encrypted">>}),
    Migrated = sensitive_values(raw_keys(Uri)),
    ?assertEqual(
        [],
        [V || V <- Migrated, not is_encrypted(V)],
        "plaintext keys must be migrated to ciphertext on the next store"
    ),

    %% Idempotent afterwards: a further no-op store does not re-write.
    Snap = raw_keys(Uri),
    _ = bondy_realm:update(Uri, #{description => <<"again">>}),
    ?assertEqual(Snap, raw_keys(Uri)),

    %% Still usable: sign/verify round-trips through the migrated keys.
    Realm = bondy_realm:fetch(Uri),
    {Kid, PrivKey} = bondy_realm:get_random_private_key(Realm),
    JWT = bondy_oauth_jwt:encode(#{<<"sub">> => <<"bob">>}, PrivKey),
    PubKey = bondy_realm:get_public_key(Realm, Kid),
    ?assertMatch({true, {jose_jwt, _}, _}, jose_jwt:verify(PubKey, JWT)).
