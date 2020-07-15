%% =============================================================================
%%  bondy_rest_gateway_api_handler.erl - the Cowboy handler for all API Gateway
%%  requests
%%
%%  Copyright (c) 2016-2019 Ngineo Limited t/a Leapsight. All rights reserved.
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
-module(bondy_rest_gateway_api_handler).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_meta_api.hrl").



%% -----------------------------------------------------------------------------
%% bondy.api_gateway
%% -----------------------------------------------------------------------------
-define(LOAD_API,
    <<"bondy.api_gateway.load">>
).
-define(LIST,
    <<"bondy.api_gateway.list">>
).
-define(LOOKUP,
    <<"bondy.api_gateway.lookup">>
).
-define(CLIENT_LIST,
    <<"bondy.api_gateway.list_clients">>
).
-define(CLIENT_LOOKUP,
    <<"bondy.api_gateway.fetch_client">>
).
-define(ADD_CLIENT,
    <<"bondy.api_gateway.add_client">>
).
-define(CLIENT_ADDED,
    <<"bondy.api_gateway.client_added">>
).
-define(DELETE_CLIENT,
    <<"bondy.api_gateway.delete_client">>
).
-define(CLIENT_DELETED,
    <<"bondy.api_gateway.client_deleted">>
).
-define(UPDATE_CLIENT,
    <<"bondy.api_gateway.update_client">>
).
-define(CLIENT_UPDATED,
    <<"bondy.api_gateway.client_updated">>
).
-define(LIST_RESOURCE_OWNERS,
    <<"bondy.api_gateway.list_resource_owners">>
).
-define(FETCH_RESOURCE_OWNER,
    <<"bondy.api_gateway.fetch_resource_owner">>
).
-define(ADD_RESOURCE_OWNER,
    <<"bondy.api_gateway.add_resource_owner">>
).
-define(DELETE_RESOURCE_OWNER,
    <<"bondy.api_gateway.delete_resource_owner">>
).
-define(UPDATE_RESOURCE_OWNER,
    <<"bondy.api_gateway.update_resource_owner">>
).

-define(RESOURCE_OWNER_ADDED,
    <<"bondy.api_gateway.resource_owner_added">>
).
-define(RESOURCE_OWNER_DELETED,
    <<"bondy.api_gateway.resource_owner_deleted">>
).
-define(RESOURCE_OWNER_UPDATED,
    <<"bondy.api_gateway.resource_owner_updated">>
).

-export([handle_call/2]).
-export([handle_event/2]).




handle_call(#call{procedure_uri = ?LOAD_API} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Spec]} ->
            bondy_wamp_utils:maybe_error(catch bondy_rest_gateway:load(Spec), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?LIST} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 0) of
        {ok, []} ->
            bondy_wamp_utils:maybe_error(catch bondy_rest_gateway:list(), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?LOOKUP} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Id]} ->
            bondy_wamp_utils:maybe_error(catch bondy_rest_gateway:lookup(Id), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?ADD_CLIENT} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            bondy_wamp_utils:maybe_error(bondy_oauth2_client:add(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?UPDATE_CLIENT} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            bondy_wamp_utils:maybe_error(
                bondy_oauth2_client:update(Uri, Username, Info),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?DELETE_CLIENT} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            bondy_wamp_utils:maybe_error(
                bondy_oauth2_client:remove(Uri, Username),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?ADD_RESOURCE_OWNER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            bondy_wamp_utils:maybe_error(
                bondy_oauth2_resource_owner:add(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);


handle_call(#call{procedure_uri = ?UPDATE_RESOURCE_OWNER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            bondy_wamp_utils:maybe_error(
                bondy_oauth2_resource_owner:update(Uri, Username, Info),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?DELETE_RESOURCE_OWNER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            bondy_wamp_utils:maybe_error(
                bondy_oauth2_resource_owner:remove(Uri, Username),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{} = M, Ctxt) ->
    Error = bondy_wamp_utils:no_such_procedure_error(M),
    bondy:send(bondy_context:peer_id(Ctxt), Error).



handle_event(?USER_ADDED, #event{arguments = [_RealmUri, _Username]}) ->
    ok;

handle_event(?USER_UPDATED, #event{arguments = [RealmUri, Username]}) ->
    bondy_oauth2:revoke_refresh_tokens(RealmUri, Username);

handle_event(?USER_DELETED, #event{arguments = [RealmUri, Username]}) ->
    bondy_oauth2:revoke_refresh_tokens(RealmUri, Username);

handle_event(?PASSWORD_CHANGED, #event{arguments = [RealmUri, Username]}) ->
    bondy_oauth2:revoke_refresh_tokens(RealmUri, Username).