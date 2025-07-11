%% =============================================================================
%%  bondy_http_utils.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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
-module(bondy_oauth2_api).
-behaviour(bondy_wamp_api).


-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-export([handle_call/3]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined)
    }
    | {reply, wamp_result() | wamp_error()}.


handle_call(?BONDY_OAUTH2_CLIENT_ADD, #call{} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),

    case bondy_oauth2_client:add(Uri, Data) of
        {ok, Client} ->
            Ext = bondy_oauth2_client:to_external(Client),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_OAUTH2_CLIENT_DELETE, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    case bondy_oauth2_client:remove(Uri, Username) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

% handle_call(?BONDY_OAUTH2_CLIENT_GET, #call{} = M, Ctxt) ->
%     [Uri, Username] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),
%     case bondy_oauth2_client:lookup(Uri, Username) of
%         {ok, Client} ->
%             Ext = bondy_oauth2_client:to_external(Client),
%             R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]);
%         {error, Reason} ->
%             E = bondy_wamp_api_utils:error(Reason, M)
%     end;

% handle_call(?BONDY_OAUTH2_CLIENT_LIST, #call{} = M, Ctxt) ->
%     [Uri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),
%     case bondy_oauth2_client:list(Uri) of
%         {error, Reason} ->
%             E = bondy_wamp_api_utils:error(Reason, M);
%         List ->
%             Ext = [bondy_oauth2_client:to_external(C) || C <- List],
%             R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext])
%     end;

handle_call(?BONDY_OAUTH2_CLIENT_UPDATE, #call{} = M, Ctxt) ->
    [Uri, Username, Info] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),
    case bondy_oauth2_client:update(Uri, Username, Info) of
        {ok, Client} ->
            Ext = bondy_oauth2_client:to_external(Client),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_OAUTH2_RES_OWNER_ADD, #call{} = M, Ctxt) ->
    [Uri, Data] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),

    case bondy_oauth2_resource_owner:add(Uri, Data) of
        {ok, User} ->
            Ext = bondy_oauth2_resource_owner:to_external(User),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_OAUTH2_RES_OWNER_DELETE, #call{} = M, Ctxt) ->
    [Uri, Username] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    case bondy_oauth2_resource_owner:remove(Uri, Username) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

% handle_call(?BONDY_OAUTH2_RES_OWNER_GET, #call{} = M, Ctxt) ->
%     [Uri, Username] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),
%     case bondy_oauth2_resource_owner:lookup(Uri, Username) of
%         {ok, Client} ->
%             Ext = bondy_oauth2_resource_owner:to_external(Client),
%             R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            % {reply, R};
%         {error, Reason} ->
%             E = bondy_wamp_api_utils:error(Reason, M),
            % {reply, E}
%     end;

% handle_call(?BONDY_OAUTH2_RES_OWNER_LIST, #call{} = M, Ctxt) ->
%     [Uri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),
%     case bondy_oauth2_resource_owner:list(Uri) of
%         {error, Reason} ->
%             E = bondy_wamp_api_utils:error(Reason, M),
            % {reply, E};
%         List ->
%             Ext = [bondy_oauth2_resource_owner:to_external(C) || C <- List],
%             R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            % {reply, R}
%     end;


handle_call(?BONDY_OAUTH2_RES_OWNER_UPDATE, #call{} = M, Ctxt) ->
    [Uri, Username, Info] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),
    case bondy_oauth2_resource_owner:update(Uri, Username, Info) of
        {ok, User} ->
            Ext = bondy_oauth2_resource_owner:to_external(User),
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_OAUTH2_TOKEN_GET, #call{} = M, _txt) ->
    %% TODO
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E};

handle_call(?BONDY_OAUTH2_TOKEN_LOOKUP, #call{} = M, _Ctxt) ->
    %% [Uri, ClientId, Token] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),
    %% Result = bondy_oauth_token:lookup(Uri, ClientId, Token),
    %% R = bondy_wamp_api_utils:maybe_error(Result, M),
    %% Deprecates
    E = bondy_wamp_api_utils:deprecated_procedure_error(M),
    {reply, E};

handle_call(?BONDY_OAUTH2_TOKEN_REVOKE, #call{} = M, Ctxt) ->
    Result =
        case bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3, 3) of
            [RealmUri, _ClientId, RefreshToken] ->
                bondy_oauth_token:revoke(RealmUri, RefreshToken)
        end,

    R = bondy_wamp_api_utils:maybe_error(Result, M),
    {reply, R};

handle_call(?BONDY_OAUTH2_TOKEN_REVOKE_ALL, #call{} = M, Ctxt) ->
    [RealmUri, _ClientId, Authid] =
        bondy_wamp_api_utils:validate_call_args(M, Ctxt, 3),
    Result = bondy_oauth_token:revoke_all(RealmUri, Authid),
    R = bondy_wamp_api_utils:maybe_error(Result, M),
    {reply, R};

handle_call(?BONDY_OAUTH2_TOKEN_REFRESH, #call{} = M, _txt) ->
    %% TODO
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E};

handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.
