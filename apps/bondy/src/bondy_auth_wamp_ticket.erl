%% =============================================================================
%%  bondy_auth_wamp_ticket.erl -
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
-module(bondy_auth_wamp_ticket).
-behaviour(bondy_auth_method).


%% BONDY_AUTH_METHOD CALLBACKS
-export([challenge/3]).
-export([authenticate/4]).



%% =============================================================================
%% BONDY_AUTH_METHOD CALLBACKS
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
    Extra :: map(),
    ChallengeState :: map(),
    Ctxt :: bondy_context:t()) ->
    {ok, AuthCtxt :: map()} | {error, Reason :: any()}.

authenticate(Signature, _, _, Ctxt) ->
    AuthId = bondy_context:authid(Ctxt),

    Realm = bondy_context:realm_uri(Ctxt),
    {IP, _Port} = bondy_context:peer(Ctxt),

    %% Signature is password
    Result = bondy_security:authenticate(
        Realm, AuthId, Signature, [{ip, IP}]
    ),

    case Result of
        {ok, _AuthCtxt} = OK ->
            OK;
        {error, Reason} ->
            {error, Reason}
    end.
