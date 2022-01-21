%% =============================================================================
%%  bondy_auth_wamp_cra.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
-behaviour(bondy_auth).

-include("bondy_security.hrl").

-type state()           ::  map().
-type challenge_error() ::  missing_pubkey | no_matching_pubkey.


%% BONDY_AUTH CALLBACKS
-export([init/1]).
-export([requirements/0]).
-export([challenge/3]).
-export([authenticate/4]).






%% =============================================================================
%% BONDY_AUTH CALLBACKS
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec init(bondy_auth:context()) ->
    {ok, State :: state()} | {error, Reason :: any()}.

init(Ctxt) ->
    try

        User = bondy_auth:user(Ctxt),

        User =/= undefined
            orelse throw({no_such_user, bondy_auth:user_id(Ctxt)}),

        PWD = bondy_rbac_user:password(User),

        PWD =/= undefined
        andalso cra =:= bondy_password:protocol(PWD)
        andalso pbkdf2 =:= maps:get(kdf, bondy_password:params(PWD))
        orelse throw(invalid_context),

        {ok, #{password => PWD}}

    catch
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec requirements() -> map().

requirements() ->
    #{
        identification => true,
        password => {true, #{protocols => [cra]}},
        authorized_keys => false
    }.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec challenge(
    DataIn :: map(), Ctxt :: bondy_auth:context(), CBState :: state()) ->
    {true, Extra :: map(), NewState :: state()}
    | {error, Reason :: challenge_error(), NewState :: state()}.

challenge(_, Ctxt, #{password := PWD} = State) ->
    try
        UserId = bondy_auth:user_id(Ctxt),
        Role = bondy_auth:role(Ctxt),

        #{
            data := #{
                salt := Salt,
                salted_password := SPassword
            },
            params := #{
                kdf := pbkdf2,
                iterations := Iterations
            }
        } = PWD,

        %% The CHALLENGE.Details.challenge|string is a string
        %% the client needs to create a signature for.
        ExtSessionId = bondy_session_id:to_external(
            bondy_auth:session_id(Ctxt)
        ),
        Microsecs = erlang:system_time(microsecond),
        Challenge = jsone:encode(#{
            authid => UserId,
            authrole => Role,
            authmethod => ?WAMP_CRA_AUTH,
            authprovider => ?BONDY_AUTH_PROVIDER,
            nonce => bondy_password_cra:nonce(),
            timestamp => bondy_utils:system_time_to_rfc3339(
                Microsecs, [{offset, "Z"}, {unit, microsecond}]
            ),
            session => ExtSessionId
        }),
        ExpectedSignature = base64:encode(
            crypto:mac(hmac, sha256, SPassword, Challenge)
        ),

        KeyLen = bondy_password:hash_length(PWD),

        ChallengeExtra = #{
            challenge => Challenge,
            salt => Salt,
            keylen => KeyLen,
            iterations => Iterations
        },

        NewState = State#{
            signature => ExpectedSignature
        },

        {true, ChallengeExtra, NewState}

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
    DataIn :: map(),
    Ctxt :: bondy_auth:context(),
    CBState :: state()) ->
    {ok, DataOut :: map(), CBState :: state()}
    | {error, Reason :: any(), CBState :: state()}.

authenticate(Signature, _, _, #{signature := Signature} = State) ->
    {ok, #{}, State};

authenticate(_, _, _, State) ->
    {error, bad_signature, State}.
