%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_auth).

-moduledoc """
Client-side WAMP authentication behaviour and dispatcher.

This is the client mirror of the router's `auth_challenge`/`bondy_auth`
round: given the configured method and an inbound `CHALLENGE.Extra`, it
produces the `AUTHENTICATE` signature. The cryptographic primitives are the
single source of truth shared with the router (`bondy_wamp_cryptosign`,
`bondy_wamp_cra`).

A client is configured with exactly one method (the common case). The
implementations are:

- `bondy_connect_auth_anonymous`
- `bondy_connect_auth_cryptosign`
- `bondy_connect_auth_cra`
- `bondy_connect_auth_ticket`

Secrets (private keys, passwords, tickets) live only inside the per-method
callback state and are scrubbed by `bondy_connect_protocol:format_status/1`.
""".

-include("bondy_connect.hrl").

-opaque t() :: #{
    method := binary(),
    module := module(),
    authid := binary() | undefined,
    state := term()
}.

-type challenge_extra() :: map().

-export_type([t/0]).
-export_type([challenge_extra/0]).

-export([init/1]).
-export([method/1]).
-export([authid/1]).
-export([authextra/1]).
-export([authenticate/2]).
-export([field/2]).

%% =============================================================================
%% CALLBACKS
%% =============================================================================

-doc "Initialise the per-method callback state from the auth config submap.".
-callback init(Config :: map()) ->
    {ok, State :: term()} | {error, Reason :: term()}.

-doc """
The method's contribution to `HELLO.Details.authextra` (e.g. the cryptosign
public key). Most methods return an empty map.
""".
-callback authextra(State :: term()) -> map().

-doc """
Produce the `AUTHENTICATE` signature (and any extra) for an inbound
`CHALLENGE.Extra`.
""".
-callback authenticate(Extra :: challenge_extra(), State :: term()) ->
    {ok, Signature :: binary(), AuthExtra :: map(), NewState :: term()}
    | {error, Reason :: term()}.

%% =============================================================================
%% API
%% =============================================================================

-doc """
Initialise the dispatcher from the `auth` config submap. The map must contain a
`method` key; `authid` is optional. Returns an opaque handle the protocol layer
threads through the handshake.
""".
-spec init(Config :: map()) -> {ok, t()} | {error, term()}.

init(#{method := Method} = Config) ->
    case module_for(Method) of
        {ok, Mod} ->
            case Mod:init(Config) of
                {ok, State} ->
                    {ok, #{
                        method => Method,
                        module => Mod,
                        authid => maps:get(authid, Config, undefined),
                        state => State
                    }};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
init(_) ->
    {error, missing_authmethod}.

-doc "The configured authentication method.".
-spec method(t()) -> binary().
method(#{method := Method}) -> Method.

-doc "The configured `authid` (may be `undefined`).".
-spec authid(t()) -> binary() | undefined.
authid(#{authid := AuthId}) -> AuthId.

-doc "The method's `HELLO.Details.authextra` contribution.".
-spec authextra(t()) -> map().
authextra(#{module := Mod, state := State}) ->
    Mod:authextra(State).

-doc "Produce the `AUTHENTICATE` response for an inbound `CHALLENGE.Extra`.".
-spec authenticate(Extra :: challenge_extra(), t()) ->
    {ok, Signature :: binary(), AuthExtra :: map(), t()}
    | {error, term()}.

authenticate(Extra, #{module := Mod, state := State} = T) ->
    case Mod:authenticate(Extra, State) of
        {ok, Signature, AuthExtra, NewState} ->
            {ok, Signature, AuthExtra, T#{state := NewState}};
        {error, _} = Error ->
            Error
    end.

-doc """
Read `Key' from a `CHALLENGE.Extra' map, accepting either the atom key or its
binary form (the codec may decode keys either way). Used by the method modules.
""".
-spec field(atom(), map()) -> term().

field(Key, Map) when is_atom(Key) ->
    case maps:find(Key, Map) of
        {ok, Value} ->
            Value;
        error ->
            maps:get(atom_to_binary(Key, utf8), Map)
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
module_for(?WAMP_ANON_AUTH) -> {ok, bondy_connect_auth_anonymous};
module_for(?WAMP_CRA_AUTH) -> {ok, bondy_connect_auth_cra};
module_for(?WAMP_CRYPTOSIGN_AUTH) -> {ok, bondy_connect_auth_cryptosign};
module_for(?WAMP_TICKET_AUTH) -> {ok, bondy_connect_auth_ticket};
module_for(Other) -> {error, {unsupported_authmethod, Other}}.
