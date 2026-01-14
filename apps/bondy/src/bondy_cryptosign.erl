%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc This modules provides the necessary functions to support the
%% Cryptosign capabilities.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_cryptosign).

-type key_pair()        ::  #{public => binary(), secret => binary()}.

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



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec generate_key() -> KeyPair :: key_pair().

generate_key() ->
    {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
    #{public => Pub, secret => Priv}.


%% -----------------------------------------------------------------------------
%% @doc Calls `strong_rand_bytes/1' with the default length value `32`.
%% @end
%% -----------------------------------------------------------------------------
-spec strong_rand_bytes() -> binary().

strong_rand_bytes() ->
    strong_rand_bytes(32).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec strong_rand_bytes(pos_integer()) -> binary().

strong_rand_bytes(Length) when is_integer(Length) andalso Length >= 0 ->
    crypto:strong_rand_bytes(Length).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec sign(Challenge :: binary(), KeyPair :: key_pair()) ->
    Signature :: binary().

sign(Challenge, #{public := Pub, secret := Priv}) ->
    public_key:sign(Challenge, ignored, {ed_pri, ed25519, Pub, Priv}, []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec verify(
    Signature :: binary(), Challenge :: binary(), PublicKey :: binary()) -> boolean() | no_return().

verify(Signature, Challenge, PublicKey) ->
    Normalised = normalise_signature(Signature, Challenge),

    public_key:verify(
        Challenge, ignored, Normalised, {ed_pub, ed25519, PublicKey}
    ).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc As the cryptosign spec is not formal some clients e.g. Python
%% return Signature(64) ++ Challenge(32) while others e.g. JS return just the
%% Signature(64).
%% @end
%% -----------------------------------------------------------------------------
normalise_signature(Signature, _) when byte_size(Signature) == 64 ->
    Signature;

normalise_signature(Signature, Challenge) when byte_size(Signature) == 96 ->
    case binary:match(Signature, Challenge) of
        {64, 32} ->
            binary:part(Signature, {0, 64});
        _ ->
            error(invalid_signature)
    end;

normalise_signature(_, _) ->
    error(invalid_signature).
