%% =============================================================================
%%  bondy_auth_wamp_cryptosign.erl -
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
-module(bondy_auth_wamp_cryptosign).
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

challenge(User, ReqDetails, Ctxt) ->
    challenge(
        User, ReqDetails, Ctxt, bondy_security_user:authorized_keys(User)
    ).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(
    AuthId :: binary(),
    ChallengeResponse :: any(),
    ChallengeState :: map(),
    Ctxt :: bondy_context:t()) ->
    {ok, AuthCtxt :: map()} | {error, Reason :: any()}.

authenticate(_AuthId, _ChallengeResponse, _ChallengeState, _Ctxt) ->
    {error, unsupported_authmethod}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



challenge(_, _, _, []) ->
    {error, no_authorized_keys};

challenge(User, ReqDetails, Ctxt, Keys) ->
    Key = maps_utils:get([authextra, <<"pubkey">>], ReqDetails, undefined),
    challenge(User, ReqDetails, Ctxt, Keys, Key).


challenge(_, _, _, _, undefined) ->
    {error, no_authextra_pubkey};

challenge(_, _, _, Keys, Key) ->
    case lists:member(Key, Keys) of
        true ->
            Challenge = hex_utils:bin_to_hexstr(enacl:randombytes(32)),
            {ok, #{challenge => Challenge}, #{}};
        false ->
            {error, no_matching_pubkey}
    end.



