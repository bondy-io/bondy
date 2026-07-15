%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_auth_anonymous).
-moduledoc """
This module implements the `bondy_auth` behaviour to allow access
to clients which connect without credentials assigning them the `anonymous`
group.
""".
-behaviour(bondy_auth).

-include("bondy_security.hrl").

-type state() :: #{
    user_id := binary() | undefined,
    role := binary(),
    roles := [binary()],
    source_ip := inet:ip_address()
}.

%% BONDY_AUTH CALLBACKS
-export([init/1]).
-export([requirements/0]).
-export([challenge/3]).
-export([authenticate/4]).

%% =============================================================================
%% BONDY_AUTH CALLBACKS
%% =============================================================================

-doc """
Raises `invalid_context`.
""".
-spec init(bondy_auth:context()) ->
    {ok, State :: state()} | {error, Reason :: any()}.

init(Ctxt) ->
    try
        UserId = bondy_auth:user_id(Ctxt),
        anonymous =:= UserId orelse throw(invalid_context),

        State = #{
            user_id => UserId,
            role => bondy_auth:role(Ctxt),
            roles => bondy_auth:roles(Ctxt),
            source_ip => bondy_auth:source_ip(Ctxt)
        },
        {ok, State}
    catch
        throw:Reason ->
            {error, Reason}
    end.

-spec requirements() -> map().

requirements() ->
    #{
        identification => false,
        password => false,
        authorized_keys => false
    }.

-spec challenge(
    Details :: map(), AuthCtxt :: bondy_auth:context(), State :: state()
) ->
    {false, NewState :: state()}
    | {error, Reason :: any(), NewState :: state()}.

challenge(_, _, State) ->
    %% No challenge required
    {false, State}.

-spec authenticate(
    Signature :: binary(),
    DataIn :: map(),
    Ctxt :: bondy_auth:context(),
    CBState :: state()
) ->
    {ok, DataOut :: map(), CBState :: state()}
    | {error, Reason :: any(), CBState :: state()}.

authenticate(_, _, Ctxt, State) ->
    %% We validate the ctxt has not changed between init and authenticate calls
    Data = #{
        user_id => bondy_auth:user_id(Ctxt),
        role => bondy_auth:role(Ctxt),
        roles => bondy_auth:roles(Ctxt),
        source_ip => bondy_auth:source_ip(Ctxt)
    },

    case Data == State of
        true ->
            {ok, #{}, State};
        false ->
            {error, invalid_context, State}
    end.
