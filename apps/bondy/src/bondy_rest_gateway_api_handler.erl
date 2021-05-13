%% =============================================================================
%%  bondy_rest_gateway_api_handler.erl - the Cowboy handler for all API Gateway
%%  requests
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


%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_call(M :: wamp_message:call(), Ctxt :: bony_context:t()) -> ok.

handle_call(M, Ctxt) ->
    PeerId = bondy_context:peer_id(Ctxt),

    try
        Reply = do_handle(M, Ctxt),
        bondy:send(PeerId, Reply)
    catch
        _:Reason ->
            %% We catch any exception from do_handle and turn it
            %% into a WAMP Error
            Error = bondy_wamp_utils:maybe_error(Reason, M),
            bondy:send(PeerId, Error)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
handle_event(?USER_ADDED, #event{arguments = [_RealmUri, _Username]}) ->
    ok;

handle_event(?USER_UPDATED, #event{arguments = [RealmUri, Username]}) ->
    bondy_oauth2:revoke_refresh_tokens(RealmUri, Username);

handle_event(?USER_DELETED, #event{arguments = [RealmUri, Username]}) ->
    bondy_oauth2:revoke_refresh_tokens(RealmUri, Username);

handle_event(?PASSWORD_CHANGED, #event{arguments = [RealmUri, Username]}) ->
    bondy_oauth2:revoke_refresh_tokens(RealmUri, Username).



%% =============================================================================
%% PRIVATE
%% =============================================================================



-spec do_handle(M :: wamp_message:call(), Ctxt :: bony_context:t()) ->
    wamp_messsage:result() | wamp_message:error().

do_handle(#call{procedure_uri = ?LOAD_API} = M, Ctxt) ->
    [Spec] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),
    case bondy_rest_gateway:load(Spec) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

do_handle(#call{procedure_uri = ?LIST} = M, Ctxt) ->
    [] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 0),
    Result = bondy_rest_gateway:list(),
    wamp_message:result(M#call.request_id, #{}, [Result]);

do_handle(#call{procedure_uri = ?LOOKUP} = M, Ctxt) ->
    [Id] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),
    case bondy_rest_gateway:lookup(Id) of
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M);
        Spec ->
            wamp_message:result(M#call.request_id, #{}, [Spec])
    end;

do_handle(#call{procedure_uri = ?ADD_CLIENT} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_oauth2_client:add(Uri, Data) of
        {ok, Client} ->
            Ext = bondy_oauth2_client:to_external(Client),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

do_handle(#call{procedure_uri = ?UPDATE_CLIENT} = M, Ctxt) ->
    [Uri, Username, Info] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),
    case bondy_oauth2_client:update(Uri, Username, Info) of
        {ok, Client} ->
            Ext = bondy_oauth2_client:to_external(Client),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

do_handle(#call{procedure_uri = ?DELETE_CLIENT} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    case bondy_oauth2_client:remove(Uri, Username) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

do_handle(#call{procedure_uri = ?ADD_RESOURCE_OWNER} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    case bondy_oauth2_resource_owner:add(Uri, Data) of
        {ok, User} ->
            Ext = bondy_oauth2_resource_owner:to_external(User),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

do_handle(#call{procedure_uri = ?UPDATE_RESOURCE_OWNER} = M, Ctxt) ->
    [Uri, Username, Info] = bondy_wamp_utils:validate_call_args(M, Ctxt, 3),
    case bondy_oauth2_resource_owner:update(Uri, Username, Info) of
        {ok, User} ->
            Ext = bondy_oauth2_resource_owner:to_external(User),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

do_handle(#call{procedure_uri = ?DELETE_RESOURCE_OWNER} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    case bondy_oauth2_resource_owner:remove(Uri, Username) of
        ok ->
            wamp_message:result(M#call.request_id, #{});
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end;

do_handle(#call{} = M, _) ->
    bondy_wamp_utils:no_such_procedure_error(M).



