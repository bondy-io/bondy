%% =============================================================================
%%  bondy_auth_password.erl -
%%
%%  Copyright (c) 2016-2023 Leapsight. All rights reserved.
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
-module(bondy_auth_password).
-behaviour(bondy_auth).

-define(VALID_PROTOCOLS, [cra, scram]).

-type state()   ::  undefined.

%% BONDY_AUTH CALLBACKS
-export([init/1]).
-export([challenge/3]).
-export([requirements/0]).
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
        User =/= undefined orelse throw(invalid_context),

        PWD = bondy_rbac_user:password(User),
        User =/= undefined
        andalso lists:member(bondy_password:protocol(PWD), ?VALID_PROTOCOLS)
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
-spec requirements() -> bondy_auth:requirements().

requirements() ->
    #{
        identification => true,
        password => {true, #{protocols => ?VALID_PROTOCOLS}},
        authorized_keys => false
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec challenge(
    DataIn :: map(), Ctxt :: bondy_auth:context(), State :: state()) ->
    {false, NewState :: state()}
    | {error, Reason :: any(), NewState :: state()}.

challenge(_, _, State) ->
    {true, #{}, State}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(
    String :: binary(),
    DataIn :: map(),
    Ctxt :: bondy_auth:context(),
    State :: state()) ->
    {ok, map(), NewState :: state()}
    | {error, Reason :: any(), NewState :: state()}.

authenticate(String, _, _, #{password := PWD} = State) ->
    case bondy_password:verify_string(String, PWD) of
        true ->
            {ok, maps:new(), State};
        false ->
            {error, bad_signature, State}
    end.

