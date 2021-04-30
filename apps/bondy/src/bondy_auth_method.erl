%% =============================================================================
%%  bondy_auth_method.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_auth_method).
-include("bondy_security.hrl").


-export([challenge/4]).
-export([authenticate/5]).
-export([valid_methods/3]).
-export([valid_authrole/2]).



%% =============================================================================
%% CALLBACKS
%% =============================================================================



-callback challenge(
    User :: bondy_security_user:t(),
    ReqDetails :: map(),
    Ctxt :: bondy_context:t()) ->
    {ok, ChallengeExtra :: map(), ChallengeState :: map()}
    | {error, Reason :: any()}.

-callback authenticate(
    Signature :: binary(),
    Extra :: map(),
    ChallengeState :: map(),
    Ctxt :: bondy_context:t()) ->
    {ok, AuthExtra :: map()} | {error, Reason :: any()}.



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Returns the sublist of `List' containing only the valid authentication
%% methods that can be used with user `User' in realm `Realm'.
%% @end
%% -----------------------------------------------------------------------------
-spec valid_methods(
    List :: [binary()],
    User :: bondy_security_user:t(),
    Ctxt :: bondy_context:t()) -> [binary()].


valid_methods(List, User, Ctxt) ->
    Password = bondy_security_user:password(User),
    HasAuthKeys = bondy_security_user:has_authorized_keys(User),
    valid_methods(List, User, Ctxt, Password, HasAuthKeys).


%% -----------------------------------------------------------------------------
%% @doc Returns the requested role `Role' if user `User' is a member of that
%% role, otherwise throws an 'invalid_authrole' exception.
%% In case the requested role is the
%% atom 'undefined' it returns the first groups in the user's groups or
%% undefined if the user is not a member of any group.
%% @end
%% -----------------------------------------------------------------------------
-spec valid_authrole(Role :: binary(), User :: bondy_security_user:t()) ->
    binary() | undefined.

valid_authrole(undefined, User) ->
    case bondy_security_user:groups(User) of
        [] -> undefined;
        L -> hd(L)
    end;

valid_authrole(Role, User) ->
    %% Validate the user is a member of the requested group (role).
    bondy_security_user:has_group(Role, User) orelse throw(invalid_authrole),
    Role.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec challenge(
    Authmethod :: binary(),
    User :: bondy_security_user:t(),
    ReqDetails :: map(),
    Ctxt :: bondy_context:t()) ->
    {ok, ChallengeExtra :: map(), ChallengeState :: map()}
    | {error, Reason :: any()}.

challenge(Authmethod, User, ReqDetails, Ctxt) ->
    try
        (callback_mod(Authmethod)):challenge(User, ReqDetails, Ctxt)
    catch
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(
    Authmethod :: binary(),
    Signature :: binary(),
    Extra :: map(),
    ChallengeState :: map(),
    Ctxt :: bondy_context:t()) ->
    {ok, AuthExtra :: map()} | {error, Reason :: any()}.

authenticate(Authmethod, Signature, Extra, ChallengeState, Ctxt) ->
    try
        (callback_mod(Authmethod)):authenticate(
            Signature, Extra, ChallengeState, Ctxt
        )
    catch
        throw:Reason ->
            {error, Reason}
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
callback_mod(?TICKET_AUTH) ->
    bondy_auth_wamp_ticket;

callback_mod(?OAUTH2_AUTH) ->
    bondy_auth_wamp_oauth2;

callback_mod(?WAMPCRA_AUTH) ->
    bondy_auth_wamp_cra;

callback_mod(?WAMPSCRAM_AUTH) ->
    bondy_auth_wamp_scram;

callback_mod(?WAMP_CRYPTOSIGN_AUTH) ->
    bondy_auth_wamp_crytosign;

callback_mod(?COOKIE_AUTH) ->
    throw(unsupported_authmethod);

callback_mod(?TLS_AUTH) ->
    throw(unsupported_authmethod);

callback_mod(_) ->
    throw(invalid_authmethod).



%% @private
valid_methods(Requested, _, Ctxt, undefined, HasAuthKeys) ->
    Realm = bondy_context:realm_uri(Ctxt),
    RealmValid = bondy_realm:auth_methods(Realm),
    UserValid0 = [?ANON_AUTH, ?OAUTH2_AUTH, ?COOKIE_AUTH],
    UserValid1 = case HasAuthKeys of
        true ->
            [?WAMP_CRYPTOSIGN_AUTH | UserValid0];
        false ->
            UserValid0
    end,
    intersection(Requested, RealmValid, UserValid1);

valid_methods(Requested, _, Ctxt, Password, HasAuthKeys) ->
    Realm = bondy_context:realm_uri(Ctxt),
    RealmValid = bondy_realm:auth_methods(Realm),
    UserValid0 = [
        ?ANON_AUTH, ?WAMPSCRAM_AUTH, ?TICKET_AUTH, ?OAUTH2_AUTH, ?COOKIE_AUTH
    ],
    UserValid1 = case maps:get(auth_name, Password) of
        pbkdf2 ->
            UserValid0;
        argon2id ->
            [?WAMPSCRAM_AUTH | UserValid0]
    end,
    UserValid2 = case HasAuthKeys of
        true ->
            [?WAMP_CRYPTOSIGN_AUTH | UserValid1];
        false ->
            UserValid1
    end,
    intersection(Requested, RealmValid, UserValid2).


%% @private
intersection(Requested, RealmValid, UserValid) ->
    sets:to_list(
        sets:intersection([
            sets:from_list(Requested),
            sets:from_list(RealmValid),
            sets:from_list(UserValid)
        ])
    ).