%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_auth_oauth2).
-moduledoc """
This module implements the `bondy_auth` behaviour for OAuth2 authentication,
verifying a JWT bearer token presented by the client against the realm.
""".
-behaviour(bondy_auth).

-include("bondy_security.hrl").

-type state() :: map().

%% API
-export([cp_security_check/2]).

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

-spec requirements() -> map().

requirements() ->
    #{
        identification => true,
        password => {true, #{protocols => [cra, scram]}},
        authorized_keys => false
    }.

-spec challenge(
    Details :: map(), AuthCtxt :: bondy_auth:context(), State :: state()
) ->
    {false, NewState :: state()}
    | {true, Extra :: map(), NewState :: state()}
    | {error, Reason :: any(), NewState :: state()}.

challenge(_, _, State) ->
    %% The client will respond to the challenge by sending the Token
    {true, #{}, State}.

-spec authenticate(
    JWT :: binary(),
    DataIn :: map(),
    Ctxt :: bondy_auth:context(),
    CBState :: state()
) ->
    {ok, DataOut :: map(), CBState :: state()}
    | {error, Reason :: any(), CBState :: state()}.

authenticate(JWT, _, Ctxt, State) ->
    RealmUri = bondy_auth:realm_uri(Ctxt),
    UserId = bondy_auth:user_id(Ctxt),

    case bondy_oauth_jwt:verify(RealmUri, JWT) of
        {ok, #{<<"sub">> := UserId} = Claims} ->
            case cp_security_check(Claims, UserId) of
                ok ->
                    {ok, Claims, State};
                {error, Reason} ->
                    {error, Reason, State}
            end;
        {ok, _} ->
            {error, oauth2_invalid_grant, State};
        {error, Reason} ->
            {error, Reason, State}
    end.

%% =============================================================================
%% API
%% =============================================================================

-doc """
The oauth2-specific half of the §9.2 CP-for-security gate: the `token_version`
zookie comparison (steps 3-4). The generic AE freshness fence (step 2) that
refuses on a stale/isolated node is applied to EVERY method in the common
`bondy_auth:authenticate/4` path (§9.8), so it is not repeated here.

Active only in the AAE phase (`bondy_oplog` `aae_enabled`). With anti-entropy
off there is no cross-node staleness window, so the check is a deliberate no-op
— a credential change closes sessions inline and tokens carry the synchronous
local `token_version`.

Exported so that credential verification outside a WAMP handshake — see
`bondy_http_verify_handler` — applies the same gate, rather than accepting a
token that this node would refuse on the session path.
""".
-spec cp_security_check(Claims :: map(), UserId :: binary()) ->
    ok | {error, oauth2_invalid_grant}.

cp_security_check(Claims, UserId) ->
    case aae_enabled() of
        false ->
            ok;
        true ->
            check_token_version(Claims, UserId)
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Steps 3-4: the JWT's issue-time `tv` (the user cell's HLC at issue) must
%% equal the user's current `token_version`, else the token predates a
%% credential/membership change and re-authentication is forced. Read from the
%% AUTH realm (`aud`) — the canonical user cell, matching the issue-time read.
check_token_version(Claims, UserId) ->
    AuthRealmUri = maps:get(<<"aud">>, Claims),
    Embedded = maps:get(<<"tv">>, Claims, 0),
    case bondy_rbac_user:token_version(AuthRealmUri, UserId) of
        {ok, Embedded} ->
            ok;
        {ok, _Current} ->
            {error, oauth2_invalid_grant};
        {error, not_found} ->
            {error, oauth2_invalid_grant}
    end.

%% @private
aae_enabled() ->
    application:get_env(bondy_oplog, aae_enabled, false) =:= true.
