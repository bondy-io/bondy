%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_auth_ticket).

-moduledoc """
Ticket authentication (also used for static password auth): the configured
secret is sent verbatim as the `AUTHENTICATE` signature in response to the
`CHALLENGE`.

Config: `#{ticket => binary()}` (alias `password`).
""".

-behaviour(bondy_connect_auth).

-export([init/1]).
-export([authextra/1]).
-export([authenticate/2]).

-spec init(Config :: map()) -> {ok, binary()} | {error, missing_ticket}.

init(#{ticket := Ticket}) when is_binary(Ticket) ->
    {ok, Ticket};
init(#{password := Ticket}) when is_binary(Ticket) ->
    {ok, Ticket};
init(_) ->
    {error, missing_ticket}.

-spec authextra(term()) -> map().
authextra(_State) ->
    #{}.

-spec authenticate(Extra :: map(), Ticket :: binary()) ->
    {ok, binary(), map(), binary()}.

authenticate(_Extra, Ticket) ->
    {ok, Ticket, #{}, Ticket}.
