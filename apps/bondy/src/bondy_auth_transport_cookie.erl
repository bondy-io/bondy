%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_auth_transport_cookie).
-moduledoc """
Implements the `bondy_auth` behaviour for the `cookie` authentication method.

This method validates a Bondy ticket that was issued during an OIDC
authorization code flow. The ticket is expected to have `authmethod` set to
`~"cookie"`.

Unlike the standard `ticket` auth method, `cookie` does not require a
challenge — the user has already authenticated at the external Identity
Provider and the proof is the cookie provided by the transport, no need for
WAMP-level interaction.

Cookies are actually Tickets (JWT).
""".

-behaviour(bondy_auth).

-include("bondy_security.hrl").


-type state()       :: map().


%% BONDY_AUTH CALLBACKS
-export([init/1]).
-export([requirements/0]).
-export([challenge/3]).
-export([authenticate/4]).



%% =============================================================================
%% BONDY_AUTH CALLBACKS
%% =============================================================================




-doc false.
-spec init(bondy_auth:context()) ->
    {ok, State :: state()} | {error, Reason :: any()}.

init(_Ctxt) ->
    {ok, maps:new()}.


-doc false.
requirements() ->
    %% Only identification is required — no password or authorized_keys needed
    %% since the user has already authenticated at the external Identity
    %% Provider.
    #{
        identification => true
    }.


-doc false.
challenge(_, _, State) ->
    %% No challenge we've been authenticated
    {false, State}.


-doc """
Authenticates by verifying the provided ticket.

The ticket must have been issued with `authmethod => ~"oidcrp"` and must
match the user's authid and realm.
""".
-spec authenticate(
    Ticket :: binary(),
    DataIn :: map(),
    Ctxt :: bondy_auth:context(),
    CBState :: state()
) ->
    {ok, DataOut :: map(), CBState :: state()}
    | {error, Reason :: any(), CBState :: state()}.

authenticate(Claims, _, Ctxt, State) when is_map(Claims) ->
    %% Claims already verified at transport open time
    validate_claims(Claims, Ctxt, State);

authenticate(Ticket, _, Ctxt, State) when is_binary(Ticket) ->
    case bondy_ticket:verify(Ticket) of
        {ok, Claims} ->
            validate_claims(Claims, Ctxt, State);
        {error, Reason} ->
            {error, Reason, State}
    end.


%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
validate_claims(#{scope := #{realm := Uri}} = Claims, Ctxt, State) ->
    RealmUri = bondy_auth:realm_uri(Ctxt),
    case Uri == undefined orelse Uri == RealmUri of
        true ->
            Extra = #{
                authmethod_details => #{
                    id => maps:get(id, Claims),
                    authrealm => maps:get(authrealm, Claims),
                    authmethod => maps:get(authmethod, Claims),
                    scope => maps:get(scope, Claims),
                    oidc_provider => maps:get(
                        oidc_provider, Claims, undefined
                    ),
                    oidc_refresh_token => maps:get(
                        oidc_refresh_token, Claims, undefined
                    ),
                    oidc_access_token_expires_at => maps:get(
                        oidc_access_token_expires_at, Claims, undefined
                    )
                }
            },
            {ok, Extra, State};
        false ->
            {error, invalid_cookie, State}
    end;

validate_claims(_Claims, _Ctxt, State) ->
    {error, invalid_cookie, State}.
