%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_auth_password).
-moduledoc """
This module implements the `bondy_auth` behaviour for password-based
authentication, verifying a client-supplied string against the user's stored
password using the `cra` or `scram` protocols.
""".
-behaviour(bondy_auth).

-define(VALID_PROTOCOLS, [cra, scram]).

-type state() :: undefined.

%% BONDY_AUTH CALLBACKS
-export([init/1]).
-export([challenge/3]).
-export([requirements/0]).
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

        PWD = bondy_rbac_user:password(User),
        User =/= undefined andalso
            lists:member(bondy_password:protocol(PWD), ?VALID_PROTOCOLS) orelse
            throw(invalid_context),

        {ok, #{password => PWD}}
    catch
        throw:Reason ->
            {error, Reason}
    end.

-spec requirements() -> bondy_auth:requirements().

requirements() ->
    #{
        identification => true,
        password => {true, #{protocols => ?VALID_PROTOCOLS}},
        authorized_keys => false
    }.

-spec challenge(
    DataIn :: map(), Ctxt :: bondy_auth:context(), State :: state()
) ->
    {false, NewState :: state()}
    | {error, Reason :: any(), NewState :: state()}.

challenge(_, _, State) ->
    {true, #{}, State}.

-spec authenticate(
    String :: binary(),
    DataIn :: map(),
    Ctxt :: bondy_auth:context(),
    State :: state()
) ->
    {ok, map(), NewState :: state()}
    | {error, Reason :: any(), NewState :: state()}.

authenticate(String, _, _, #{password := PWD} = State) ->
    case bondy_password:verify_string(String, PWD) of
        true ->
            {ok, maps:new(), State};
        false ->
            {error, bad_signature, State}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% NOTE (S-1): transparent re-hash-on-login was intentionally NOT implemented.
%% `token_version` is the user cell's HLC and the OAuth2 fence requires strict
%% equality (see `bondy_auth_oauth2:check_token_version/2`), so ANY re-store of
%% the user cell — even to upgrade only the stored PBKDF2 iteration count —
%% advances `token_version` and invalidates every outstanding token for that
%% user. There is no side-effect-free write in this model. The S-1 hardening is
%% therefore limited to raising the work factor for NEW and CHANGED passwords
%% (see `schema/bondy.schema` `security.password.pbkdf2.iterations`); an existing
%% low-iteration verifier upgrades on the user's next password change.
