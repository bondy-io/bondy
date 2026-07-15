%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_cryptosign).
-moduledoc """
This module provides the necessary functions to support the Cryptosign
capabilities.

It is a thin shim over `bondy_wamp_cryptosign`, the router-independent single
source of truth shared with the WAMP client. New code should call
`bondy_wamp_cryptosign` directly.
""".

-type key_pair() :: bondy_wamp_cryptosign:key_pair().

-export_type([key_pair/0]).

%% API
-export([generate_key/0]).
-export([normalise_signature/2]).
-export([sign/2]).
-export([strong_rand_bytes/0]).
-export([strong_rand_bytes/1]).
-export([verify/3]).

%% =============================================================================
%% API
%% =============================================================================

-spec generate_key() -> KeyPair :: key_pair().

generate_key() ->
    bondy_wamp_cryptosign:generate_key().

-doc "Calls `strong_rand_bytes/1` with the default length value `32`.".
-spec strong_rand_bytes() -> binary().

strong_rand_bytes() ->
    bondy_wamp_cryptosign:strong_rand_bytes().

-spec strong_rand_bytes(non_neg_integer()) -> binary().

strong_rand_bytes(Length) ->
    bondy_wamp_cryptosign:strong_rand_bytes(Length).

-spec sign(Challenge :: binary(), KeyPair :: key_pair()) ->
    Signature :: binary().

sign(Challenge, KeyPair) ->
    bondy_wamp_cryptosign:sign(Challenge, KeyPair).

-spec verify(
    Signature :: binary(), Challenge :: binary(), PublicKey :: binary()
) ->
    boolean() | no_return().

verify(Signature, Challenge, PublicKey) ->
    bondy_wamp_cryptosign:verify(Signature, Challenge, PublicKey).

-doc """
As the cryptosign spec is not formal some clients e.g. Python return
`Signature(64) ++ Challenge(32)` while others e.g. JS return just the
`Signature(64)`.
""".
-spec normalise_signature(Signature :: binary(), Challenge :: binary()) ->
    binary() | no_return().

normalise_signature(Signature, Challenge) ->
    bondy_wamp_cryptosign:normalise_signature(Signature, Challenge).
