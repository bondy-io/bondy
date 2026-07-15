%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_cryptosign).

-moduledoc """
Pure, router-independent primitives for the WAMP **Cryptosign** authentication
method (Ed25519).

This is the single source of truth for cryptosign in the Bondy monorepo: both
the server (`bondy_cryptosign`, which delegates here) and the WAMP client
(`bondy_connect`) share these functions, so that any signature produced by one
side verifies on the other.

The module is split in three concerns:

* **Crypto** — `generate_key/0`, `sign/2`, `verify/3`, `normalise_signature/2`
  and the `strong_rand_bytes/0,1` helpers. These only depend on `crypto` and
  `public_key`.
* **Hex** — `encode_hex/1`/`decode_hex/1`. WAMP carries the challenge, public
  key and signature as hex strings on the wire. Encoding is **uppercase** (to
  match the historical Bondy wire format); decoding is case-insensitive.
* **Client signer sources** — `key_pair/1,2` (normalising a 32- or 64-byte
  secret into the `t:key_pair/0` accepted by `sign/2`) and `signer/2`, which
  builds a signing function from a declarative configuration: an inline private
  key, an environment variable, or an external executable.

## References
* [WAMP Cryptosign](https://wamp-proto.org/wamp_latest_ietf.html#name-cryptosign-based-authenticat)
""".

-type key_pair() :: #{public := binary(), secret := binary()}.
-type signer() :: fun((Message :: binary()) -> HexSignature :: binary()).
-type signer_config() ::
    #{privkey := binary()}
    | #{privkey_env_var := string() | binary()}
    | #{exec := file:filename_all()}
    | #{procedure := binary()}.

-export_type([key_pair/0]).
-export_type([signer/0]).
-export_type([signer_config/0]).

%% Crypto
-export([generate_key/0]).
-export([sign/2]).
-export([verify/3]).
-export([normalise_signature/2]).
-export([strong_rand_bytes/0]).
-export([strong_rand_bytes/1]).

%% Hex
-export([encode_hex/1]).
-export([decode_hex/1]).

%% Client signer sources
-export([key_pair/1]).
-export([key_pair/2]).
-export([signer/2]).

-define(EXEC_TIMEOUT, 10000).

%% =============================================================================
%% API: CRYPTO
%% =============================================================================

-doc "Generates a fresh Ed25519 key pair (32-byte public key, 32-byte seed).".
-spec generate_key() -> key_pair().

generate_key() ->
    {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
    #{public => Pub, secret => Priv}.

-doc """
Signs `Challenge` with the Ed25519 `secret` of `KeyPair`, returning the raw
64-byte signature.

`secret` must be the 32-byte Ed25519 seed (as produced by `generate_key/0` or
`key_pair/1,2`); pass a 32- or 64-byte secret through `key_pair/1` first to
normalise it.
""".
-spec sign(Challenge :: binary(), KeyPair :: key_pair()) ->
    Signature :: binary().

sign(Challenge, #{public := Pub, secret := Priv}) ->
    public_key:sign(Challenge, ignored, {ed_pri, ed25519, Pub, Priv}, []).

-doc """
Verifies that `Signature` is a valid Ed25519 signature of `Challenge` for
`PublicKey`.

`Signature` is normalised via `normalise_signature/2` first, so both the bare
64-byte form and the 96-byte `Signature ++ Challenge` form (emitted by some
clients) are accepted.
""".
-spec verify(
    Signature :: binary(), Challenge :: binary(), PublicKey :: binary()
) ->
    boolean() | no_return().

verify(Signature, Challenge, PublicKey) ->
    Normalised = normalise_signature(Signature, Challenge),
    public_key:verify(
        Challenge, ignored, Normalised, {ed_pub, ed25519, PublicKey}
    ).

-doc """
Normalises a cryptosign signature.

As the cryptosign spec is not formal, some clients (e.g. Python) return
`Signature(64) ++ Challenge(32)` while others (e.g. JS) return just the
`Signature(64)`. Returns the bare 64-byte signature or raises
`invalid_signature`.
""".
-spec normalise_signature(Signature :: binary(), Challenge :: binary()) ->
    binary() | no_return().

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

-doc "Calls `strong_rand_bytes/1` with the default length of `32`.".
-spec strong_rand_bytes() -> binary().

strong_rand_bytes() ->
    strong_rand_bytes(32).

-doc "Returns `Length` cryptographically strong random bytes.".
-spec strong_rand_bytes(Length :: non_neg_integer()) -> binary().

strong_rand_bytes(Length) when is_integer(Length) andalso Length >= 0 ->
    crypto:strong_rand_bytes(Length).

%% =============================================================================
%% API: HEX
%% =============================================================================

-doc """
Encodes `Bin` as an **uppercase** hex binary.

Matches the historical Bondy wire format for cryptosign pubkeys, challenges and
signatures.
""".
-spec encode_hex(Bin :: binary()) -> binary().

encode_hex(Bin) when is_binary(Bin) ->
    binary:encode_hex(Bin).

-doc """
Decodes a hex string (upper- or lower-case) into a binary.

Raises `invalid_hex_encoding` if the input is not valid hex (non-hex characters
or odd length).
""".
-spec decode_hex(Hex :: binary() | string()) -> binary() | no_return().

decode_hex(Hex) when is_binary(Hex) ->
    try
        binary:decode_hex(Hex)
    catch
        error:badarg ->
            error(invalid_hex_encoding)
    end;
decode_hex(Hex) when is_list(Hex) ->
    decode_hex(list_to_binary(Hex)).

%% =============================================================================
%% API: CLIENT SIGNER SOURCES
%% =============================================================================

-doc "Equivalent to `key_pair(Secret, undefined)`.".
-spec key_pair(Secret :: binary()) -> key_pair() | no_return().

key_pair(Secret) ->
    key_pair(Secret, undefined).

-doc """
Normalises an Ed25519 secret into a `t:key_pair/0` usable by `sign/2`.

`Secret` may be either:

* the bare 32-byte seed, or
* the 64-byte `seed ++ public_key` concatenation emitted by some libraries.

`Public` is the 32-byte public key, or `undefined`. When `undefined`, the
public key is taken from the 64-byte secret or derived from the seed. An
explicitly supplied `Public` takes precedence.
""".
-spec key_pair(Secret :: binary(), Public :: binary() | undefined) ->
    key_pair() | no_return().

key_pair(Secret, Public) when is_binary(Secret) ->
    {Seed, EmbeddedPub} = split_secret(Secret),
    #{public => resolve_public(Public, EmbeddedPub, Seed), secret => Seed}.

-doc """
Builds a signing function from a declarative `t:signer_config/0`.

The returned `t:signer/0` takes the **raw** challenge bytes (i.e. the decoded
`CHALLENGE.Extra.challenge`) and returns the **hex-encoded** signature ready to
place in the `AUTHENTICATE` message.

`PubKey` is the raw 32-byte public key (or `undefined`). It is required for the
`exec` source (passed to the external program) and used, when supplied, to build
the key pair for the inline/env-var sources.

Sources:

* `#{privkey => Hex}` — inline hex-encoded secret (seed or `seed ++ pubkey`).
* `#{privkey_env_var => Var}` — read the hex secret from environment variable
  `Var`.
* `#{exec => Filename}` — run `Filename PubKeyHex MessageHex` and read a hex
  signature from its stdout. The executable is invoked once with a dummy message
  to validate it.
* `#{procedure => _}` — not implemented.
""".
-spec signer(PubKey :: binary() | undefined, Config :: signer_config()) ->
    signer() | no_return().

signer(_, #{procedure := _}) ->
    error(not_implemented);
signer(PubKey, #{exec := Filename}) ->
    SignerFun = fun(Message) ->
        exec_sign(Filename, PubKey, Message)
    end,
    %% Validate the executable eagerly with a dummy message.
    try SignerFun(<<"foo">>) of
        Val when is_binary(Val) ->
            SignerFun
    catch
        error:Reason ->
            error(Reason)
    end;
signer(PubKey, #{privkey := HexString}) ->
    KeyPair = key_pair(decode_hex(HexString), PubKey),
    fun(Message) ->
        encode_hex(sign(Message, KeyPair))
    end;
signer(PubKey, #{privkey_env_var := Var}) ->
    case os:getenv(ensure_list(Var)) of
        false ->
            error({invalid_config, {privkey_env_var, Var}});
        HexString ->
            KeyPair = key_pair(decode_hex(HexString), PubKey),
            fun(Message) ->
                encode_hex(sign(Message, KeyPair))
            end
    end;
signer(_, Config) ->
    error({invalid_cryptosign_config, Config}).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
-spec split_secret(binary()) ->
    {Seed :: binary(), Public :: binary() | undefined}.

split_secret(Secret) when byte_size(Secret) == 32 ->
    {Secret, undefined};
split_secret(Secret) when byte_size(Secret) == 64 ->
    <<Seed:32/binary, Public:32/binary>> = Secret,
    {Seed, Public};
split_secret(_) ->
    error(invalid_secret_key).

%% @private
-spec resolve_public(
    Supplied :: binary() | undefined,
    Embedded :: binary() | undefined,
    Seed :: binary()
) -> binary() | no_return().

resolve_public(Public, _, _) when is_binary(Public), byte_size(Public) == 32 ->
    Public;
resolve_public(undefined, Public, _) when is_binary(Public) ->
    Public;
resolve_public(undefined, undefined, Seed) ->
    {Public, Seed} = crypto:generate_key(eddsa, ed25519, Seed),
    Public;
resolve_public(_, _, _) ->
    error(invalid_public_key).

%% @private
-spec exec_sign(
    Filename :: file:filename_all(),
    PubKey :: binary() | undefined,
    Message :: binary()
) -> binary() | no_return().

exec_sign(Filename, PubKey, Message) ->
    Args = [encode_hex_arg(PubKey), encode_hex(Message)],
    try
        Port = erlang:open_port(
            {spawn_executable, Filename}, [{args, Args}, binary, exit_status]
        ),
        exec_receive(Port, <<>>)
    catch
        error:Reason ->
            error({invalid_executable, Reason})
    end.

%% @private
exec_receive(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            exec_receive(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            string:trim(Acc);
        {Port, {exit_status, Status}} ->
            catch erlang:port_close(Port),
            error({cryptosign_exit_status, Status})
    after ?EXEC_TIMEOUT ->
        catch erlang:port_close(Port),
        error(cryptosign_timeout)
    end.

%% @private
encode_hex_arg(undefined) ->
    <<>>;
encode_hex_arg(Bin) when is_binary(Bin) ->
    encode_hex(Bin).

%% @private
ensure_list(Var) when is_list(Var) ->
    Var;
ensure_list(Var) when is_binary(Var) ->
    binary_to_list(Var).
