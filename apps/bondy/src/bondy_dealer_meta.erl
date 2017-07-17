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

%% =============================================================================
%% BONDY META PROCEDURES
handle_call(#call{
        procedure_uri = <<"com.leapsight.bondy.realms.enable_security">>} = M, Ctxt) ->
    R = case validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            maybe_error(bondy_realm:enable_security(bondy_realm:get(Uri)), M);
        {error, WampError} ->
            WampError     
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
        procedure_uri = <<"com.leapsight.bondy.realms.disable_security">>} = M, Ctxt) ->
    R = case validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            maybe_error(bondy_realm:disable_security(bondy_realm:get(Uri)), M);
        {error, WampError} ->
            WampError     
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GATEWAY_LOAD_API_SPEC} = M, Ctxt) ->
    R = case validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Spec]} ->
            maybe_error(bondy_api_gateway:load(Spec), M);
        {error, WampError} ->
            WampError     
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GATEWAY_CLIENT_ADD} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            maybe_error(bondy_api_gateway:add_client(Uri, Info), M);
        {error, WampError} ->
            WampError     
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);


handle_call(#call{procedure_uri = <<"com.leapsight.bondy.api_gateway.add_resource_owner">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            maybe_error(bondy_api_gateway:add_resource_owner(Uri, Info), M);
        {error, WampError} ->
            WampError     
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);


handle_call(#call{procedure_uri = <<"com.leapsight.bondy.api_gateway.update_resource_owner">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            maybe_error(
                bondy_api_gateway:update_resource_owner(Uri, Username, Info), 
                M
            );
        {error, WampError} ->
            WampError     
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.api_gateway.remove_resource_owner">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            maybe_error(
                bondy_api_gateway:remove_resource_owner(Uri, Username),
                M
            );
        {error, WampError} ->
            WampError     
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_USER_ADD} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            maybe_error(bondy_security_user:add(Uri, Info), M);
        {error, WampError} ->
            WampError     
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_USER_UPDATE} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            maybe_error(bondy_security_user:update(Uri, Username, Info), M);
        {error, WampError} ->
            WampError     
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_USER_DELETE} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            maybe_error(bondy_security_user:remove(Uri, Username), M);
        {error, WampError} ->
            WampError     
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_USER_LIST} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            maybe_error(bondy_security_user:list(Uri), M);
        {error, WampError} ->
            WampError     
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_USER_LOOKUP} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            maybe_error(bondy_security_user:lookup(Uri, Username), M);
        {error, WampError} ->
            WampError     
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GROUP_ADD} = M, Ctxt) ->
    %% @TODO
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            maybe_error(bondy_security_group:add(Uri, Info), M);
        {error, WampError} ->
            WampError     
    end,
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
maybe_error(ok, M) ->
    wamp_message:result(M#call.request_id, #{}, [], #{});

maybe_error({ok, Val}, M) ->
    wamp_message:result(M#call.request_id, #{}, [Val], #{});

maybe_error({error, Reason}, M) ->
    #{<<"code">> := Code} = Map = bondy_error:error_map(Reason),
    Message = case maps:find(<<"message">>, Map) of
        {ok, Val} -> [Val];
        error -> undefined
    end,
    wamp_message:error(
        ?CALL,
        M#call.request_id,
        Map,
        bondy_error:error_uri(Code),
        Message
    );

maybe_error(Val, M) ->
    wamp_message:result(M#call.request_id, #{}, [Val], #{}).


%% @private
validate_call_args(Call, Ctxt, MinArity) ->
    validate_call_args(Call, Ctxt, MinArity, false).


%% @private
validate_admin_call_args(Call, Ctxt, MinArity) ->
    validate_call_args(Call, Ctxt, MinArity, true).

%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Validates that the first argument of the call is a RealmUri, defaulting to 
%% use the session Realm's uri if one is not provided. It uses the MinArity 
%% to determine wether the RealmUri argument is present or not.
%% Once the Realm is established it validates it is is equal to the
%% session's Realm or any other in case the session's realm is the root realm.
%% @end
%% -----------------------------------------------------------------------------
-spec validate_call_args(
    wamp_call(), 
    bondy_context:context(), 
    MinArity :: integer(), 
    AdminOnly :: boolean()) -> 
        {ok, Args :: list()} | {error, wamp_error()}.
        
validate_call_args(#call{arguments = L} = M, _, N, _) when length(L) + 1 < N ->
    E = wamp_message:error(
        ?CALL,
        M#call.request_id,
        #{},
        ?WAMP_ERROR_INVALID_ARGUMENT,
        [<<"At least one argument is missing">>]),
    {error, E};

validate_call_args(#call{arguments = []} = M, Ctxt, _, AdminOnly) ->
    %% We default to the session's Realm
    case {AdminOnly, bondy_context:realm_uri(Ctxt)} of
        {false, Uri} ->
            {ok, [Uri]};
        {_, ?BONDY_REALM_URI} ->
            {ok, [?BONDY_REALM_URI]};
        {_, _} ->
            {error, unauthorized(M)}
    end;

validate_call_args(#call{arguments = [Uri|_] = L} = M, Ctxt, _, AdminOnly) ->
    %% A call can only proceed if the session's Realm is the one being
    %% modified, unless the session's Realm is the Root Realm in which 
    %% case any Realm can be modified
    case {AdminOnly, bondy_context:realm_uri(Ctxt)} of
        {false, Uri} ->
            {ok, L};
        {_, ?BONDY_REALM_URI} ->
            {ok, L};
        {_, _} ->
            {error, unauthorized(M)}
    end.


%% @private
unauthorized(M) ->
    wamp_message:error(
        ?CALL,
        M#call.request_id,
        #{},
        ?WAMP_ERROR_NOT_AUTHORIZED,
        [
            iolist:to_binary([
                <<"The operation you've requested is a targeting a Realm that is not your session's realm or the operation is only supported when you are logged into the Root Realm (">>, 
                ?BONDY_REALM_URI, <<$",$)>>
            ])
    ]).
