%% 
%%  Untitled-2 -
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

-module(bondy_dealer_meta).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-export([handle_call/2]).




%% =============================================================================
%% API
%% =============================================================================



handle_call(#call{procedure_uri = <<"wamp.registration.list">>} = M, Ctxt) ->
    ReqId = M#call.request_id,
    Res = #{
        ?EXACT_MATCH => [], % @TODO
        ?PREFIX_MATCH => [], % @TODO
        ?WILDCARD_MATCH => [] % @TODO
    },
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"wamp.registration.lookup">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"wamp.registration.match">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
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

handle_call(
    #call{procedure_uri = <<"wamp.registration.count_callees">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{count => 0},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GATEWAY_CLIENT_ADD} = M, Ctxt) ->
    ReqId = M#call.request_id,
    case bondy_context:realm_uri(Ctxt) of
        ?BONDY_REALM_URI ->        
            R = case M#call.arguments of
                [RealmUri, Info] ->
                    maybe_error(
                        bondy_api_gateway:add_client(RealmUri, Info), ReqId);
                _ ->
                    wamp_message:error(
                        ?CALL,
                        ReqId,
                        #{},
                        ?WAMP_ERROR_INVALID_ARGUMENT)
            end,
            bondy:send(bondy_context:peer_id(Ctxt), R);
        _ ->
            R = wamp_message:error(
                ?CALL,
                ReqId,
                #{},
                ?WAMP_ERROR_NOT_AUTHORIZED,
                [<<"You need to be logged in to root realm to be able to call this procedure.">>]),
            bondy:send(bondy_context:peer_id(Ctxt), R)
    end;


handle_call(#call{procedure_uri = ?BONDY_USER_ADD} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    R = case M#call.arguments of
        [User] ->
            Uri = maps:get(realm_uri, Ctxt),
            case bondy_security_user:add(Uri, User) of
                ok ->
                    wamp_message:result(ReqId, #{}, [], #{});
                {error, Reason} ->
                    #{<<"code">> := Code} = Map = bondy_error:error_map(Reason),
                    wamp_message:error(
                        ?CALL,
                        ReqId,
                        Map,
                        bondy_error:error_uri(Code))
            end;
        _ ->
            wamp_message:error(
                ?CALL,
                ReqId,
                #{},
                ?WAMP_ERROR_INVALID_ARGUMENT)
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_USER_DELETE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_USER_LIST} = M, Ctxt) ->
    ReqId = M#call.request_id,
    Args = [bondy_security_user:list(maps:get(realm_uri, Ctxt))],
    R = wamp_message:result(ReqId, #{}, Args, #{}),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_USER_LOOKUP} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_USER_UPDATE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GROUP_ADD} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GROUP_DELETE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GROUP_LIST} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GROUP_LOOKUP} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GROUP_UPDATE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_SOURCE_ADD} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_SOURCE_DELETE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_SOURCE_LIST} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_SOURCE_LOOKUP} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R).


maybe_error(ok, ReqId) ->
    wamp_message:result(ReqId, #{}, [], #{});

maybe_error({error, Reason}, ReqId) ->
    #{<<"code">> := Code} = Map = bondy_error:error_map(Reason),
    wamp_message:error(
        ?CALL,
        ReqId,
        Map,
        bondy_error:error_uri(Code)).