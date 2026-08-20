%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_auth_anonymous).

-moduledoc """
Anonymous authentication. No credentials and, normally, no `CHALLENGE` — the
router replies to `HELLO` with `WELCOME` directly. Should a `CHALLENGE` arrive
anyway, an empty signature is returned.
""".

-behaviour(bondy_connect_auth).

-export([init/1]).
-export([authextra/1]).
-export([authenticate/2]).

-spec init(Config :: map()) -> {ok, undefined}.
init(_Config) ->
    {ok, undefined}.

-spec authextra(term()) -> map().
authextra(_State) ->
    #{}.

-spec authenticate(Extra :: map(), State :: term()) ->
    {ok, binary(), map(), term()}.

authenticate(_Extra, State) ->
    {ok, <<>>, #{}, State}.
