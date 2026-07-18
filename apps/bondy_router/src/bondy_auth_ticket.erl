%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_auth_ticket).
-moduledoc """
This module implements the `bondy_auth` behaviour for ticket-based
authentication, verifying a client-supplied ticket against the realm and user
via `bondy_ticket`.
""".
-behaviour(bondy_auth).

-include_lib("kernel/include/logger.hrl").
-include("bondy_security.hrl").

-type state() :: map().

%% BONDY_AUTH CALLBACKS
-export([init/1]).
-export([requirements/0]).
-export([challenge/3]).
-export([authenticate/4]).

%% =============================================================================
%% BONDY_AUTH CALLBACKS
%% =============================================================================

-spec init(bondy_auth:context()) ->
    {ok, State :: state()} | {error, Reason :: any()}.

init(Ctxt) ->
    try
        User = bondy_auth:user(Ctxt),
        User =/= undefined orelse throw(invalid_context),
        {ok, maps:new()}
    catch
        throw:Reason ->
            {error, Reason}
    end.

-spec requirements() -> bondy_auth:requirements().

requirements() ->
    #{
        identification => true,
        any => #{
            password => {true, #{protocols => [cra, scram]}},
            authorized_keys => true
        }
    }.

-spec challenge(
    Details :: map(), AuthCtxt :: bondy_auth:context(), State :: state()
) ->
    {false, NewState :: state()}
    | {true, Extra :: map(), NewState :: state()}
    | {error, Reason :: any(), NewState :: state()}.

challenge(_, _, State) ->
    %% The client will respond to the challenge by sending the Ticket
    {true, #{}, State}.

-spec authenticate(
    Ticket :: binary(),
    DataIn :: map(),
    Ctxt :: bondy_auth:context(),
    CBState :: state()
) ->
    {ok, DataOut :: map(), CBState :: state()}
    | {error, Reason :: any(), CBState :: state()}.

authenticate(Ticket, _, Ctxt, State) ->
    RealmUri = bondy_auth:realm_uri(Ctxt),
    UserId = bondy_auth:user_id(Ctxt),

    case bondy_ticket:verify(Ticket) of
        {ok,
            #{
                authid := UserId,
                authrealm := AuthRealmUri,
                scope := #{realm := Uri}
            } = Claims} when
            Uri == all orelse Uri == RealmUri
        ->
            %% A-1: the ticket's issuer (`authrealm`) must be trusted by the
            %% target realm (itself or its SSO realm); the `scope.realm`
            %% guard above is not sufficient — an SSO ticket carries
            %% `scope.realm = all` and would otherwise be accepted by
            %% any realm against its own issuer's key.
            case bondy_realm:is_trusted_issuer(RealmUri, AuthRealmUri) of
                true ->
                    Extra = #{
                        authmethod_details => #{
                            id => maps:get(id, Claims),
                            authrealm => AuthRealmUri,
                            scope => maps:get(scope, Claims)
                        }
                    },
                    {ok, Extra, State};
                false ->
                    ?LOG_WARNING(#{
                        description =>
                            "Rejected ticket: issuer not trusted by "
                            "target realm",
                        realm_uri => RealmUri,
                        ticket_authrealm => AuthRealmUri
                    }),
                    {error, untrusted_issuer, State}
            end;
        {ok, _} ->
            {error, invalid_ticket, State};
        {error, Reason} ->
            {error, Reason, State}
    end.
