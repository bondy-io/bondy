%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_cryptosign_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile([nowarn_export_all, export_all]).

all() ->
    [
        %% Crypto
        generate_key_shape,
        sign_verify_round_trip,
        verify_rejects_tampered_signature,
        verify_rejects_wrong_challenge,
        verify_rejects_wrong_key,
        normalise_64,
        normalise_96_match,
        normalise_96_mismatch,
        normalise_invalid_length,
        known_answer_vector,

        %% Hex
        hex_round_trip_uppercase,
        hex_decode_case_insensitive,
        hex_decode_invalid,
        hex_decode_odd_length,

        %% Key normalisation
        key_pair_from_seed_derives_public,
        key_pair_from_64_byte_secret_splits,
        key_pair_explicit_public_wins,
        key_pair_invalid_secret,

        %% Signer sources
        signer_inline_privkey,
        signer_inline_64_byte_privkey,
        signer_env_var,
        signer_env_var_missing,
        signer_procedure_not_implemented,
        signer_invalid_config
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    Config.

end_per_suite(_) ->
    ok.

%% =============================================================================
%% CRYPTO
%% =============================================================================

generate_key_shape(_) ->
    #{public := Pub, secret := Sec} = bondy_wamp_cryptosign:generate_key(),
    ?assertEqual(32, byte_size(Pub)),
    ?assertEqual(32, byte_size(Sec)),
    %% Two key pairs differ
    ?assertNotEqual(
        bondy_wamp_cryptosign:generate_key(),
        bondy_wamp_cryptosign:generate_key()
    ).

sign_verify_round_trip(_) ->
    KeyPair = #{public := Pub} = bondy_wamp_cryptosign:generate_key(),
    Challenge = bondy_wamp_cryptosign:strong_rand_bytes(32),
    Signature = bondy_wamp_cryptosign:sign(Challenge, KeyPair),
    ?assertEqual(64, byte_size(Signature)),
    ?assert(bondy_wamp_cryptosign:verify(Signature, Challenge, Pub)).

verify_rejects_tampered_signature(_) ->
    KeyPair = #{public := Pub} = bondy_wamp_cryptosign:generate_key(),
    Challenge = bondy_wamp_cryptosign:strong_rand_bytes(32),
    <<First, Rest/binary>> = bondy_wamp_cryptosign:sign(Challenge, KeyPair),
    Tampered = <<(First bxor 1), Rest/binary>>,
    ?assertNot(bondy_wamp_cryptosign:verify(Tampered, Challenge, Pub)).

verify_rejects_wrong_challenge(_) ->
    KeyPair = #{public := Pub} = bondy_wamp_cryptosign:generate_key(),
    Challenge = bondy_wamp_cryptosign:strong_rand_bytes(32),
    Signature = bondy_wamp_cryptosign:sign(Challenge, KeyPair),
    Other = bondy_wamp_cryptosign:strong_rand_bytes(32),
    ?assertNot(bondy_wamp_cryptosign:verify(Signature, Other, Pub)).

verify_rejects_wrong_key(_) ->
    KeyPair = bondy_wamp_cryptosign:generate_key(),
    #{public := OtherPub} = bondy_wamp_cryptosign:generate_key(),
    Challenge = bondy_wamp_cryptosign:strong_rand_bytes(32),
    Signature = bondy_wamp_cryptosign:sign(Challenge, KeyPair),
    ?assertNot(bondy_wamp_cryptosign:verify(Signature, Challenge, OtherPub)).

normalise_64(_) ->
    Sig = bondy_wamp_cryptosign:strong_rand_bytes(64),
    ?assertEqual(Sig, bondy_wamp_cryptosign:normalise_signature(Sig, <<"x">>)).

normalise_96_match(_) ->
    Sig = bondy_wamp_cryptosign:strong_rand_bytes(64),
    Challenge = bondy_wamp_cryptosign:strong_rand_bytes(32),
    Concat = <<Sig/binary, Challenge/binary>>,
    ?assertEqual(
        Sig, bondy_wamp_cryptosign:normalise_signature(Concat, Challenge)
    ).

normalise_96_mismatch(_) ->
    Sig = bondy_wamp_cryptosign:strong_rand_bytes(64),
    Challenge = bondy_wamp_cryptosign:strong_rand_bytes(32),
    Wrong = bondy_wamp_cryptosign:strong_rand_bytes(32),
    Concat = <<Sig/binary, Challenge/binary>>,
    ?assertError(
        invalid_signature,
        bondy_wamp_cryptosign:normalise_signature(Concat, Wrong)
    ).

normalise_invalid_length(_) ->
    ?assertError(
        invalid_signature,
        bondy_wamp_cryptosign:normalise_signature(<<"short">>, <<"x">>)
    ).

%% A deterministic Ed25519 vector: signing a fixed challenge with a fixed seed
%% always yields the same signature, and the matching public key verifies it.
known_answer_vector(_) ->
    Seed = binary:copy(<<7>>, 32),
    KeyPair = #{public := Pub} = bondy_wamp_cryptosign:key_pair(Seed),
    Challenge = <<"the-fixed-challenge">>,
    Sig1 = bondy_wamp_cryptosign:sign(Challenge, KeyPair),
    Sig2 = bondy_wamp_cryptosign:sign(Challenge, KeyPair),
    ?assertEqual(Sig1, Sig2),
    ?assert(bondy_wamp_cryptosign:verify(Sig1, Challenge, Pub)).

%% =============================================================================
%% HEX
%% =============================================================================

hex_round_trip_uppercase(_) ->
    Bin = bondy_wamp_cryptosign:strong_rand_bytes(48),
    Hex = bondy_wamp_cryptosign:encode_hex(Bin),
    ?assertEqual(Hex, string:uppercase(Hex)),
    ?assertEqual(Bin, bondy_wamp_cryptosign:decode_hex(Hex)).

hex_decode_case_insensitive(_) ->
    Bin = bondy_wamp_cryptosign:strong_rand_bytes(48),
    Upper = bondy_wamp_cryptosign:encode_hex(Bin),
    Lower = string:lowercase(Upper),
    ?assertEqual(Bin, bondy_wamp_cryptosign:decode_hex(Upper)),
    ?assertEqual(Bin, bondy_wamp_cryptosign:decode_hex(Lower)).

hex_decode_invalid(_) ->
    ?assertError(
        invalid_hex_encoding, bondy_wamp_cryptosign:decode_hex(<<"not_hex!!!">>)
    ).

hex_decode_odd_length(_) ->
    ?assertError(
        invalid_hex_encoding, bondy_wamp_cryptosign:decode_hex(<<"abc">>)
    ).

%% =============================================================================
%% KEY NORMALISATION
%% =============================================================================

key_pair_from_seed_derives_public(_) ->
    #{public := Pub, secret := Seed} = bondy_wamp_cryptosign:generate_key(),
    #{public := Derived, secret := Seed2} =
        bondy_wamp_cryptosign:key_pair(Seed),
    ?assertEqual(Seed, Seed2),
    ?assertEqual(Pub, Derived).

key_pair_from_64_byte_secret_splits(_) ->
    #{public := Pub, secret := Seed} = bondy_wamp_cryptosign:generate_key(),
    Concat = <<Seed/binary, Pub/binary>>,
    #{public := Pub2, secret := Seed2} =
        bondy_wamp_cryptosign:key_pair(Concat),
    ?assertEqual(Seed, Seed2),
    ?assertEqual(Pub, Pub2).

key_pair_explicit_public_wins(_) ->
    #{secret := Seed} = bondy_wamp_cryptosign:generate_key(),
    #{public := Other} = bondy_wamp_cryptosign:generate_key(),
    #{public := Pub} = bondy_wamp_cryptosign:key_pair(Seed, Other),
    ?assertEqual(Other, Pub).

key_pair_invalid_secret(_) ->
    ?assertError(
        invalid_secret_key, bondy_wamp_cryptosign:key_pair(<<"too-short">>)
    ).

%% =============================================================================
%% SIGNER SOURCES
%% =============================================================================

signer_inline_privkey(_) ->
    #{public := Pub, secret := Seed} = bondy_wamp_cryptosign:generate_key(),
    PrivHex = bondy_wamp_cryptosign:encode_hex(Seed),
    Signer = bondy_wamp_cryptosign:signer(Pub, #{privkey => PrivHex}),
    Challenge = bondy_wamp_cryptosign:strong_rand_bytes(32),
    HexSig = Signer(Challenge),
    ?assert(is_binary(HexSig)),
    Sig = bondy_wamp_cryptosign:decode_hex(HexSig),
    ?assert(bondy_wamp_cryptosign:verify(Sig, Challenge, Pub)).

signer_inline_64_byte_privkey(_) ->
    #{public := Pub, secret := Seed} = bondy_wamp_cryptosign:generate_key(),
    PrivHex = bondy_wamp_cryptosign:encode_hex(<<Seed/binary, Pub/binary>>),
    %% No explicit pubkey: it is taken from the 64-byte secret.
    Signer = bondy_wamp_cryptosign:signer(undefined, #{privkey => PrivHex}),
    Challenge = bondy_wamp_cryptosign:strong_rand_bytes(32),
    Sig = bondy_wamp_cryptosign:decode_hex(Signer(Challenge)),
    ?assert(bondy_wamp_cryptosign:verify(Sig, Challenge, Pub)).

signer_env_var(_) ->
    #{public := Pub, secret := Seed} = bondy_wamp_cryptosign:generate_key(),
    PrivHex = bondy_wamp_cryptosign:encode_hex(Seed),
    Var = "BONDY_WAMP_CS_TEST_PRIV",
    true = os:putenv(Var, binary_to_list(PrivHex)),
    try
        Signer = bondy_wamp_cryptosign:signer(Pub, #{privkey_env_var => Var}),
        Challenge = bondy_wamp_cryptosign:strong_rand_bytes(32),
        Sig = bondy_wamp_cryptosign:decode_hex(Signer(Challenge)),
        ?assert(bondy_wamp_cryptosign:verify(Sig, Challenge, Pub))
    after
        os:unsetenv(Var)
    end.

signer_env_var_missing(_) ->
    Var = "BONDY_WAMP_CS_DEFINITELY_UNSET_VAR",
    os:unsetenv(Var),
    ?assertError(
        {invalid_config, {privkey_env_var, Var}},
        bondy_wamp_cryptosign:signer(undefined, #{privkey_env_var => Var})
    ).

signer_procedure_not_implemented(_) ->
    ?assertError(
        not_implemented,
        bondy_wamp_cryptosign:signer(undefined, #{procedure => <<"x">>})
    ).

signer_invalid_config(_) ->
    ?assertError(
        {invalid_cryptosign_config, _},
        bondy_wamp_cryptosign:signer(undefined, #{bogus => true})
    ).
