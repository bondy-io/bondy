%% =============================================================================
%%  bondy_dealer_wamp_handler.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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


-module(bondy_dealer_wamp_handler).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").


-export([handle_call/2]).



%% =============================================================================
%% API
%% =============================================================================



-spec handle_call(M :: wamp_message(), Ctxt :: map()) -> ok | no_return().

%% -----------------------------------------------------------------------------
%% BONDY API GATEWAY META PROCEDURES
%% -----------------------------------------------------------------------------
handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.api_gateway.", _/binary>>} = M,
    Ctxt) ->
    bondy_api_gateway_wamp_handler:handle_call(M, Ctxt);

%% -----------------------------------------------------------------------------
%% BONDY SECURITY META PROCEDURES
%% -----------------------------------------------------------------------------
handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.security.", _/binary>>} = M,
    Ctxt) ->
    bondy_security_wamp_handler:handle_call(M, Ctxt);

%% -----------------------------------------------------------------------------
%% BONDY OAUTH2 META PROCEDURES
%% -----------------------------------------------------------------------------
handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.oauth2.", _/binary>>} = M,
    Ctxt) ->
    bondy_oauth2_wamp_handler:handle_call(M, Ctxt);

%% -----------------------------------------------------------------------------
%% BONDY BACKUP META PROCEDURES
%% -----------------------------------------------------------------------------
handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.backup.", _/binary>>} = M,
    Ctxt) ->
    bondy_backup_wamp_handler:handle_call(M, Ctxt);

%% -----------------------------------------------------------------------------
%% WAMP META PROCEDURES
%% -----------------------------------------------------------------------------
handle_call(#call{procedure_uri = <<"wamp.registration.list">>} = M, Ctxt) ->
    ReqId = M#call.request_id,
    Res = #{
        ?EXACT_MATCH => [], % @TODO
        ?PREFIX_MATCH => [], % @TODO
        ?WILDCARD_MATCH => [] % @TODO
    },
    R = wamp_message:result(ReqId, #{}, [Res]),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(
    #call{
        procedure_uri = <<"wamp.registration.lookup">>,
        arguments = [Proc|_] = L
    } = M,
    Ctxt) when length(L) =:= 1; length(L) =:= 2 ->
    % @TODO: Implement options
    RealmUri = bondy_context:realm_uri(Ctxt),
    Args = case bondy_registry:match(registration, Proc, RealmUri) of
        {[], '$end_of_table'} ->
            [];
        {Sessions, '$end_of_table'} ->
            [bondy_registry_entry:id(hd(Sessions))] % @TODO Get from round-robin?
    end,
    ReqId = M#call.request_id,
    R = wamp_message:result(ReqId, #{}, Args),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(
    #call{
        procedure_uri = <<"wamp.registration.match">>,
        arguments = [Proc] = L
    } = M,
    Ctxt) when length(L) =:= 1 ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Args = case bondy_registry:match(registration, Proc, RealmUri) of
        {[], '$end_of_table'} ->
            [];
        {Sessions, '$end_of_table'} ->
            [bondy_registry_entry:id(hd(Sessions))] % @TODO Get from round-robin?
    end,
    ReqId = M#call.request_id,
    R = wamp_message:result(ReqId, #{}, Args),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"wamp.registration.get">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(
    #call{procedure_uri = <<"wamp.registration.list_callees">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"wamp.registration.count_callees">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{count => 0},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{} = M, Ctxt) ->
    Mssg = <<
        "There are no registered procedures matching the uri",
        $\s, $', (M#call.procedure_uri)/binary, $', $.
    >>,
    R = wamp_message:error(
        ?CALL,
        M#call.request_id,
        #{},
        ?WAMP_NO_SUCH_PROCEDURE,
        [Mssg],
        #{
            message => Mssg,
            description => <<"Either no registration exists for the requested procedure or the match policy used did not match any registered procedures.">>
        }
    ),
    bondy:send(bondy_context:peer_id(Ctxt), R).






