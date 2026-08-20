%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_auth_cryptosign).

-moduledoc """
Cryptosign (Ed25519) authentication. On `CHALLENGE` the client signs the raw
challenge bytes (the hex `challenge` decoded) and returns the hex signature, to
be verified by the router against the advertised public key.

The client advertises its public key in `HELLO.Details.authextra.pubkey` (hex),
and the signing source is pluggable via `bondy_wamp_cryptosign:signer/2`:

- `#{privkey => HexString}` — inline private key (the public key is derived if
  not supplied).
- `#{privkey_env_var => Var}` — private key read from an environment variable.
- `#{exec => Filename}` — sign via an external executable.

For the `exec`/`privkey_env_var` sources the public key cannot be derived, so a
`#{pubkey => HexString}` must be supplied.
""".

-behaviour(bondy_connect_auth).

-export([init/1]).
-export([authextra/1]).
-export([authenticate/2]).

-spec init(Config :: map()) ->
    {ok, map()} | {error, {invalid_cryptosign_config, term()}}.

init(Config) ->
    try
        {PubKeyHex, PubKey} = resolve_pubkey(Config),
        Signer = bondy_wamp_cryptosign:signer(PubKey, Config),
        {ok, #{pubkey_hex => PubKeyHex, signer => Signer}}
    catch
        error:Reason ->
            {error, {invalid_cryptosign_config, Reason}};
        throw:Reason ->
            {error, {invalid_cryptosign_config, Reason}}
    end.

-spec authextra(map()) -> map().
authextra(#{pubkey_hex := PubKeyHex}) ->
    #{<<"pubkey">> => PubKeyHex}.

-spec authenticate(Extra :: map(), State :: map()) ->
    {ok, binary(), map(), map()} | {error, invalid_challenge}.

authenticate(Extra, #{signer := Signer} = State) ->
    try
        ChallengeHex = bondy_connect_auth:field(challenge, Extra),
        Message = bondy_wamp_cryptosign:decode_hex(ChallengeHex),
        SignatureHex = Signer(Message),
        {ok, SignatureHex, #{}, State}
    catch
        error:_ ->
            {error, invalid_challenge}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private An explicit pubkey wins; otherwise derive it from an inline privkey.
resolve_pubkey(#{pubkey := PubKeyHex}) when is_binary(PubKeyHex) ->
    {PubKeyHex, bondy_wamp_cryptosign:decode_hex(PubKeyHex)};
resolve_pubkey(#{privkey := PrivKeyHex}) when is_binary(PrivKeyHex) ->
    Secret = bondy_wamp_cryptosign:decode_hex(PrivKeyHex),
    #{public := PubKey} = bondy_wamp_cryptosign:key_pair(Secret),
    {bondy_wamp_cryptosign:encode_hex(PubKey), PubKey};
resolve_pubkey(_) ->
    error(missing_pubkey).
