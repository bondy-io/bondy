%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_auth_cra).

-moduledoc """
WAMP-CRA authentication. Given the raw password and the `CHALLENGE.Extra`
(`challenge`, `salt`, `iterations`, `keylen`), it derives the salted password
and computes the HMAC response via `bondy_wamp_cra:response/3` — the same
primitive the router uses to compute the expected signature, so the response
matches by construction.

Config: `#{password => binary()}`.
""".

-behaviour(bondy_connect_auth).

-export([init/1]).
-export([authextra/1]).
-export([authenticate/2]).

-spec init(Config :: map()) -> {ok, binary()} | {error, missing_password}.

init(#{password := Password}) when is_binary(Password) ->
    {ok, Password};
init(_) ->
    {error, missing_password}.

-spec authextra(term()) -> map().
authextra(_State) ->
    #{}.

-spec authenticate(Extra :: map(), Password :: binary()) ->
    {ok, binary(), map(), binary()} | {error, invalid_challenge}.

authenticate(Extra, Password) ->
    try
        Challenge = bondy_connect_auth:field(challenge, Extra),
        Salt = bondy_connect_auth:field(salt, Extra),
        Iterations = bondy_connect_auth:field(iterations, Extra),
        KeyLen = bondy_connect_auth:field(keylen, Extra),
        Signature = bondy_wamp_cra:response(Challenge, Password, #{
            salt => Salt,
            iterations => Iterations,
            keylen => KeyLen
        }),
        {ok, Signature, #{}, Password}
    catch
        error:_ ->
            {error, invalid_challenge}
    end.
