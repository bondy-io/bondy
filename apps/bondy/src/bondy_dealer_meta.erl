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


%% REALM
-define(BONDY_ENABLE_SECURITY,
    <<"com.leapsight.bondy.realms.enable_security">>).
-define(BONDY_DISABLE_SECURITY,
    <<"com.leapsight.bondy.realms.disable_security">>).

% USER
-define(BONDY_USER_ADD, <<"com.leapsight.bondy.security.add_user">>).
-define(BONDY_USER_UPDATE, <<"com.leapsight.bondy.security.replace_user">>).
-define(BONDY_USER_LOOKUP, <<"com.leapsight.bondy.security.find_user">>).
-define(BONDY_USER_DELETE, <<"com.leapsight.bondy.security.delete_user">>).
-define(BONDY_USER_LIST, <<"com.leapsight.bondy.security.list_users">>).
-define(BONDY_USER_CHANGE_PASSWORD, <<"com.leapsight.bondy.security.change_password">>).

-define(BONDY_USER_ON_ADD, <<"com.leapsight.bondy.security.user_added">>).
-define(BONDY_USER_ON_DELETE, <<"com.leapsight.bondy.security.user_deleted">>).
-define(BONDY_USER_ON_UPDATE, <<"com.leapsight.bondy.security.user_updated">>).

% GROUP
-define(BONDY_GROUP_ADD, <<"com.leapsight.bondy.security.add_group">>).
-define(BONDY_GROUP_UPDATE, <<"com.leapsight.bondy.security.replace_group">>).
-define(BONDY_GROUP_LOOKUP, <<"com.leapsight.bondy.security.find_group">>).
-define(BONDY_GROUP_DELETE, <<"com.leapsight.bondy.security.delete_group">>).
-define(BONDY_GROUP_LIST, <<"com.leapsight.bondy.security.list_groups">>).

-define(BONDY_GROUP_ON_ADD, <<"com.leapsight.bondy.security.group_added">>).
-define(BONDY_GROUP_ON_DELETE, <<"com.leapsight.bondy.security.group_deleted">>).
-define(BONDY_GROUP_ON_UPDATE, <<"com.leapsight.bondy.security.group_updated">>).

% SOURCE
-define(BONDY_SOURCE_ADD, <<"com.leapsight.bondy.security.add_source">>).
-define(BONDY_SOURCE_DELETE, <<"com.leapsight.bondy.security.delete_source">>).
-define(BONDY_SOURCE_LOOKUP, <<"com.leapsight.bondy.security.find_source">>).
-define(BONDY_SOURCE_LIST, <<"com.leapsight.bondy.security.list_sources">>).

-define(BONDY_SOURCE_ON_ADD, <<"com.leapsight.bondy.security.source_added">>).
-define(BONDY_SOURCE_ON_DELETE, <<"com.leapsight.bondy.security.source_deleted">>).




%% API GATEWAY

-define(BONDY_GATEWAY_LOAD_API_SPEC,
    <<"com.leapsight.bondy.api_gateway.load_api_spec">>).


-define(BONDY_GATEWAY_CLIENT_CHANGE_PASSWORD,
    <<"com.leapsight.bondy.api_gateway.change_password">>).

-define(BONDY_GATEWAY_CLIENT_ADD,
    <<"com.leapsight.bondy.api_gateway.add_client">>).
-define(BONDY_GATEWAY_CLIENT_DELETE,
    <<"com.leapsight.bondy.api_gateway.delete_client">>).
-define(BONDY_GATEWAY_CLIENT_LIST,
    <<"com.leapsight.bondy.api_gateway.list_clients">>).
-define(BONDY_GATEWAY_CLIENT_LOOKUP,
    <<"com.leapsight.bondy.api_gateway.fetch_client">>).
-define(BONDY_GATEWAY_CLIENT_UPDATE,
    <<"com.leapsight.bondy.api_gateway.update_client">>).

-define(BONDY_GATEWAY_CLIENT_ADDED,
    <<"com.leapsight.bondy.api_gateway.client_added">>).
-define(BONDY_GATEWAY_CLIENT_DELETED,
    <<"com.leapsight.bondy.api_gateway.client_deleted">>).
-define(BONDY_GATEWAY_CLIENT_UPDATED,
    <<"com.leapsight.bondy.api_gateway.client_updated">>).


-define(BONDY_GATEWAY_ADD_RESOURCE_OWNER,
    <<"com.leapsight.bondy.api_gateway.add_resource_owner">>).
-define(BONDY_GATEWAY_DELETE_RESOURCE_OWNER,
    <<"com.leapsight.bondy.api_gateway.delete_resource_owner">>).
-define(BONDY_GATEWAY_LIST_RESOURCE_OWNERS,
    <<"com.leapsight.bondy.api_gateway.list_resource_owners">>).
-define(BONDY_GATEWAY_FETCH_RESOURCE_OWNER,
    <<"com.leapsight.bondy.api_gateway.fetch_resource_owner">>).
-define(BONDY_GATEWAY_UPDATE_RESOURCE_OWNER,
    <<"com.leapsight.bondy.api_gateway.update_resource_owner">>).

-define(BONDY_GATEWAY_RESOURCE_OWNER_ADDED,
    <<"com.leapsight.bondy.api_gateway.resource_owner_added">>).
-define(BONDY_GATEWAY_RESOURCE_OWNER_DELETED,
    <<"com.leapsight.bondy.api_gateway.resource_owner_deleted">>).
-define(BONDY_GATEWAY_RESOURCE_OWNER_UPDATED,
    <<"com.leapsight.bondy.api_gateway.resource_owner_updated">>).


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
handle_call(#call{procedure_uri = ?BONDY_ENABLE_SECURITY} = M, Ctxt) ->
    R = case validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            maybe_error(bondy_realm:enable_security(bondy_realm:get(Uri)), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_DISABLE_SECURITY} = M, Ctxt) ->
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


handle_call(#call{procedure_uri = ?BONDY_GATEWAY_ADD_RESOURCE_OWNER} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            maybe_error(bondy_api_gateway:add_resource_owner(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);


handle_call(#call{procedure_uri = ?BONDY_GATEWAY_UPDATE_RESOURCE_OWNER} = M, Ctxt) ->
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

handle_call(#call{procedure_uri = ?BONDY_GATEWAY_DELETE_RESOURCE_OWNER} = M, Ctxt) ->
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
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            maybe_error(bondy_security_group:add(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GROUP_DELETE} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Name]} ->
            maybe_error(bondy_security_group:remove(Uri, Name), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GROUP_LIST} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            maybe_error(bondy_security_group:list(Uri), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GROUP_LOOKUP} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Name]} ->
            maybe_error(bondy_security_group:lookup(Uri, Name), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?BONDY_GROUP_UPDATE} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Name, Info]} ->
            maybe_error(bondy_security_group:update(Uri, Name, Info), M);
        {error, WampError} ->
            WampError
    end,
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
    #{<<"code">> := Code} = Map = bondy_error:map(Reason),
    Mssg = maps:get(<<"message">>, Map, <<>>),
    wamp_message:error(
        ?CALL,
        M#call.request_id,
        #{},
        bondy_error:code_to_uri(Code),
        [Mssg],
        Map
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
