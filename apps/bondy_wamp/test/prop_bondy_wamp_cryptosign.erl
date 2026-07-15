%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% @doc Property-based tests for bondy_wamp_cryptosign (Ed25519 sign/verify,
%% hex encoding and key normalisation).
%% @end
-module(prop_bondy_wamp_cryptosign).

-include_lib("proper/include/proper.hrl").

-export([
    prop_sign_verify_round_trip/0,
    prop_verify_rejects_other_challenge/0,
    prop_hex_round_trip/0,
    prop_hex_decode_case_insensitive/0,
    prop_key_pair_seed_derives_consistent_public/0
]).

%% =============================================================================
%% PROPERTIES
%% =============================================================================

%% Signing any challenge with a key pair always verifies with its public key.
prop_sign_verify_round_trip() ->
    ?FORALL(
        {Seed, Challenge},
        {binary(32), binary()},
        begin
            KeyPair = #{public := Pub} = bondy_wamp_cryptosign:key_pair(Seed),
            Sig = bondy_wamp_cryptosign:sign(Challenge, KeyPair),
            byte_size(Sig) =:= 64 andalso
                bondy_wamp_cryptosign:verify(Sig, Challenge, Pub)
        end
    ).

%% A signature never verifies against a different challenge.
prop_verify_rejects_other_challenge() ->
    ?FORALL(
        {Seed, C1, C2},
        {binary(32), binary(), binary()},
        ?IMPLIES(
            C1 =/= C2,
            begin
                KeyPair =
                    #{public := Pub} =
                    bondy_wamp_cryptosign:key_pair(Seed),
                Sig = bondy_wamp_cryptosign:sign(C1, KeyPair),
                not bondy_wamp_cryptosign:verify(Sig, C2, Pub)
            end
        )
    ).

%% encode_hex/decode_hex round-trips for any binary.
prop_hex_round_trip() ->
    ?FORALL(
        Bin,
        binary(),
        Bin =:=
            bondy_wamp_cryptosign:decode_hex(
                bondy_wamp_cryptosign:encode_hex(Bin)
            )
    ).

%% decode_hex accepts both upper- and lower-case forms.
prop_hex_decode_case_insensitive() ->
    ?FORALL(
        Bin,
        binary(),
        begin
            Upper = bondy_wamp_cryptosign:encode_hex(Bin),
            Lower = string:lowercase(Upper),
            Bin =:= bondy_wamp_cryptosign:decode_hex(Upper) andalso
                Bin =:= bondy_wamp_cryptosign:decode_hex(Lower)
        end
    ).

%% Normalising the 32-byte seed and the 64-byte (seed ++ pub) form yields the
%% same, consistent public key.
prop_key_pair_seed_derives_consistent_public() ->
    ?FORALL(
        Seed,
        binary(32),
        begin
            #{public := Pub, secret := Seed} =
                bondy_wamp_cryptosign:key_pair(Seed),
            Concat = <<Seed/binary, Pub/binary>>,
            #{public := Pub2, secret := Seed2} =
                bondy_wamp_cryptosign:key_pair(Concat),
            Pub =:= Pub2 andalso Seed =:= Seed2
        end
    ).
