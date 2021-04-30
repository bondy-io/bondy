%% =============================================================================
%%  bondy_auth_wamp_cra.erl -
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
-module(bondy_auth_wamp_cra).
-behaviour(bondy_auth_method).

-include("bondy_security.hrl").

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
    bondy_security_user:t(), ReqDetails :: map(), bondy_context:t()) ->
    {ok, ChallengeExtra :: map(), ChallengeState :: map()}
    | {error, Reason :: any()}.

challenge(User, ReqDetails, Ctxt) ->
    try
        HasPWD = bondy_security_user:has_password(User),
        challenge(User, ReqDetails, Ctxt, HasPWD)
    catch
        throw:Reason ->
            {error, Reason}
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(
    Signature :: binary(),
    Extra :: map(),
    ChallengeState :: map(),
    Ctxt :: bondy_context:t()) ->
    {ok, AuthExtra :: map()} | {error, Reason :: any()}.

authenticate(Signature, _Extra, #{signature := Signature}, Ctxt) ->
    Realm = bondy_context:realm_uri(Ctxt),
    AuthId = bondy_context:authid(Ctxt),
    PW = bondy_security_user:password(Realm, AuthId),
    HashedPass = maps:get(hash_pass, PW),
    {IP, _} = bondy_context:peer(Ctxt),

    %% TODO Review this as we have already validated the signatures are correct
    %% we just need to check source allows Peer.
    Result = bondy_security:authenticate(
        Realm, AuthId, {hash, HashedPass}, [{ip, IP}]
    ),
    case Result of
        {ok, _AuthCtxt} ->
            {ok, #{}};
        Error ->
            Error
    end;

authenticate(_, _, _, _) ->
    %% Signatures do not match
    {error, bad_password}.



%% =============================================================================
%% PRIVATE
%% =============================================================================




challenge(_, _, _, false) ->
    {error, no_password};

challenge(User, Details, Ctxt, true) ->
    Role = bondy_auth_method:valid_authrole(
        maps:get(authrole, Details, <<"user">>),
        User
    ),
    AuthId = bondy_security_user:username(User),
    Pass = bondy_security_user:password(bondy_context:realm_uri(Ctxt), User),

    #{
        auth_name := pbkdf2,
        hash_pass := SPassword,
        salt := Salt,
        iterations := Iterations
    } = Pass,

    %% The CHALLENGE.Details.challenge|string is a string the client needs to
    %% create a signature for.
    Microsecs = erlang:system_time(microsecond),
    Challenge = jsone:encode(#{
        session => bondy_context:session_id(Ctxt),
        authprovider => ?BONDY_AUTH_PROVIDER,
        authmethod => ?WAMPCRA_AUTH,
        authid => AuthId,
        authrole => Role,
        nonce => bondy_password_cra:nonce(),
        timestamp => bondy_utils:iso8601(Microsecs)
    }),
    Signature = base64:encode(crypto:mac(hmac, sha256, SPassword, Challenge)),

    KeyLen = bondy_password:hash_length(Pass),

    ChallengeExtra = #{
        challenge => Challenge,
        salt => Salt,
        keylen => KeyLen,
        iterations => Iterations
    },

    ChallengeState = #{
        authprovider => ?BONDY_AUTH_PROVIDER,
        authmethod => ?WAMPCRA_AUTH,
        authid => bondy_security_user:username(User),
        authrole => Role,
        '_authroles' => bondy_security_user:groups(User),
        signature => Signature
    },

    {ok, ChallengeExtra, ChallengeState}.







