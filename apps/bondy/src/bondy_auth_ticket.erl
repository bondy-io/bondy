%% =============================================================================
%%  bondy_auth_ticket.erl -
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
-module(bondy_auth_ticket).
-behaviour(bondy_auth).

-include("bondy_security.hrl").

-type state()       :: map().

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
        User =/= undefined orelse throw(invalid_context),

        {ok, maps:new()}

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
        any => #{
            password => {true, #{protocols => [cra, scram]}},
            authorized_keys => true
        }
    }.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec challenge(
    Details :: map(), AuthCtxt :: bondy_auth:context(), State :: state()) ->
    {false, NewState :: state()}
    | {true, Extra :: map(), NewState :: state()}
    | {error, Reason :: any(), NewState :: state()}.

challenge(_, _, State) ->
    %% The client will respond to the challenge by sending the Ticket
    {true, #{}, State}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(
    Ticket :: binary(),
    DataIn :: map(),
    Ctxt :: bondy_auth:context(),
    CBState :: state()) ->
    {ok, DataOut :: map(), CBState :: state()}
    | {error, Reason :: any(), CBState :: state()}.

authenticate(Ticket, _, Ctxt, State) ->
    RealmUri = bondy_auth:realm_uri(Ctxt),
    UserId = bondy_auth:user_id(Ctxt),

    % Opts = #{},

    case bondy_ticket:verify(Ticket) of
        {ok, #{authid := UserId, scope := #{realm := Uri}} = Claims}
        when Uri == undefined orelse Uri == RealmUri ->
            Extra = #{
                authmethod_details => #{
                    id => maps:get(id, Claims),
                    authrealm => maps:get(authrealm, Claims),
                    scope => maps:get(scope, Claims)
                }
            },
            {ok, Extra, State};
        {ok, _} ->
            {error, invalid_ticket, State};
        {error, Reason} ->
            {error, Reason, State}
    end.



