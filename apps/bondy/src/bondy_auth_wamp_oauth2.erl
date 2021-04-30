%% =============================================================================
%%  bondy_auth_wamp_oauth2.erl -
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
-module(bondy_auth_wamp_oauth2).
-behaviour(bondy_auth_method).


%% bondy_auth_method CALLBACKS
-export([challenge/3]).
-export([authenticate/4]).



%% =============================================================================
%% bondy_auth_method CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec challenge(
    User :: bondy_security_user:t(),
    ReqDetails :: map(),
    Ctxt :: bondy_context:t()) ->
    {ok, ChallengeExtra :: map(), ChallengeState :: map()}
    | {error, Reason :: any()}.

challenge(_, _, _) ->
    {ok, #{}, #{}}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(
    Signature :: binary(),
    ChallenExtrageResponse :: map(),
    ChallengeState :: map(),
    Ctxt :: bondy_context:t()) ->
    {ok, AuthCtxt :: map()} | {error, Reason :: any()}.

authenticate(Signature, _, _, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    AuthId = bondy_context:authid(Ctxt),

    %% Signature is the JWT Token
    case bondy_oauth2:verify_jwt(RealmUri, Signature) of
        {ok, #{<<"sub">> := AuthId}} = OK ->
            OK;
        {ok, _} ->
            %% The authid does not match the token's sub!
            %% TODO Flag as potential threat and limit attempts
            {error, oauth2_invalid_grant};
        {error, Reason} ->
            {error, Reason}
    end.

