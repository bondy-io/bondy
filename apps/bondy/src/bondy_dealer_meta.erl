%% =============================================================================
%%  bondy_dealer_meta.erl -
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

handle_call(#call{
        procedure_uri = <<"com.leapsight.bondy.realms.enable_security">>} = M, Ctxt) ->
    ReqId = M#call.request_id,
    R = case bondy_context:realm_uri(Ctxt) of
        ?BONDY_REALM_URI ->        
            case M#call.arguments of
                [Uri] ->
                    maybe_error(
                        bondy_realm:enable_security(bondy_realm:get(Uri)),
                        ReqId);
                _ ->
                    wamp_message:error(
                        ?CALL,
                        ReqId,
                        #{},
                        ?WAMP_ERROR_INVALID_ARGUMENT)
            end;
        _ ->
            unauthorized(ReqId, Ctxt)
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);
handle_call(#call{
        procedure_uri = <<"com.leapsight.bondy.realms.disable_security">>} = M, Ctxt) ->
    ReqId = M#call.request_id,
    R = case bondy_context:realm_uri(Ctxt) of
        ?BONDY_REALM_URI ->        
            case M#call.arguments of
                [Uri] ->
                    maybe_error(
                        bondy_realm:disable_security(bondy_realm:get(Uri)),
                        ReqId);
                _ ->
                    wamp_message:error(
                        ?CALL,
                        ReqId,
                        #{},
                        ?WAMP_ERROR_INVALID_ARGUMENT)
            end;
        _ ->
            unauthorized(ReqId, Ctxt)
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GATEWAY_LOAD_API_SPEC} = M, Ctxt) ->
    ReqId = M#call.request_id,
    R = case bondy_context:realm_uri(Ctxt) of
        ?BONDY_REALM_URI ->        
            case M#call.arguments of
                [Spec] ->
                    maybe_error(
                        bondy_api_gateway:load(Spec), ReqId);
                _ ->
                    wamp_message:error(
                        ?CALL,
                        ReqId,
                        #{},
                        ?WAMP_ERROR_INVALID_ARGUMENT)
            end;
        _ ->
            unauthorized(ReqId, Ctxt)
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GATEWAY_CLIENT_ADD} = M, Ctxt) ->
    ReqId = M#call.request_id,
    MyRealmUri = bondy_context:realm_uri(Ctxt),
    R = case {MyRealmUri, M#call.arguments} of
        {MyRealmUri, [Info]} ->
            maybe_error(
                bondy_api_gateway:add_client(MyRealmUri, Info),
                ReqId
            );
        {MyRealmUri, [Uri, Info]} 
        when MyRealmUri =:= Uri orelse MyRealmUri =:= ?BONDY_REALM_URI ->
            maybe_error(
                bondy_api_gateway:add_client(Uri, Info),
                ReqId
            );
        {_, [_, _]} ->
            unauthorized(ReqId, Ctxt);
        _ ->
            wamp_message:error(
                ?CALL,
                ReqId,
                #{},
                ?WAMP_ERROR_INVALID_ARGUMENT)
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);


handle_call(#call{procedure_uri = ?BONDY_GATEWAY_RESOURCE_OWNER_ADD} = M, Ctxt) ->
    ReqId = M#call.request_id,
    MyRealmUri = bondy_context:realm_uri(Ctxt),
    R = case {MyRealmUri, M#call.arguments} of
        {MyRealmUri, [Info]} ->
            maybe_error(
                bondy_api_gateway:add_resource_owner(MyRealmUri, Info),
                ReqId
            );
        {MyRealmUri, [Uri, Info]} 
        when MyRealmUri =:= Uri orelse MyRealmUri =:= ?BONDY_REALM_URI ->
            maybe_error(
                bondy_api_gateway:add_resource_owner(Uri, Info),
                ReqId
            );
        {_, [_, _]} ->
            unauthorized(ReqId, Ctxt);
        _ ->
            wamp_message:error(
                ?CALL,
                ReqId,
                #{},
                ?WAMP_ERROR_INVALID_ARGUMENT)
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);
    


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
    R = case M#call.arguments of
        [Uri] ->
            case bondy_security_user:list(Uri) of
                L when is_list(L) ->
                    wamp_message:result(ReqId, #{}, [L], #{});
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


%% @private
maybe_error(ok, ReqId) ->
    wamp_message:result(ReqId, #{}, [], #{});

maybe_error({ok, Client}, ReqId) ->
    wamp_message:result(ReqId, #{}, [Client], #{});

maybe_error({error, Reason}, ReqId) ->
    #{<<"code">> := Code} = Map = bondy_error:error_map(Reason),
    wamp_message:error(
        ?CALL,
        ReqId,
        Map,
        bondy_error:error_uri(Code)).


%% @private
unauthorized(ReqId, Ctxt) ->
    R = wamp_message:error(
        ?CALL,
        ReqId,
        #{},
        ?WAMP_ERROR_NOT_AUTHORIZED,
        [
        iolist:to_binary([
            <<"The operation you've requested is a targeting a Realm that is not the one you are logged into, or the operation is only supported when you are logged into the Roote Realm (">>, 
            ?BONDY_REALM_URI, <<$",$)>>
        ])
    ]),
    bondy:send(bondy_context:peer_id(Ctxt), R).