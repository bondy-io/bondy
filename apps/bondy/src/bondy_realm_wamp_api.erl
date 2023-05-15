%% =============================================================================
%%  bondy_realm_wamp_api.erl -
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
-module(bondy_realm_wamp_api).
-behaviour(bondy_wamp_api).

-include_lib("wamp/include/wamp.hrl").
-include("bondy_uris.hrl").

-export([handle_call/3]).



%% =============================================================================
%% API
%% =============================================================================



-spec handle_call(
    Proc :: uri(), M :: wamp_message:call(), Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined)
    }
    | {reply, wamp_result() | wamp_error()}.

handle_call(?BONDY_REALM_CREATE, M, Ctxt) ->
    [Data] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),
    Realm = bondy_realm:create(Data),
    Ext = bondy_realm:to_external(Realm),
    R = wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

handle_call(?BONDY_REALM_DELETE, M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),
    KWArgs = to_map(M#call.kwargs),

    case bondy_realm:delete(Uri, KWArgs) of
        ok ->
            R = wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_REALM_GET, M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),

    Ext = bondy_realm:to_external(bondy_realm:fetch(Uri)),
    R = wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

handle_call(?BONDY_REALM_LIST, M, Ctxt) ->
    [] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 0, 0),

    Ext = [bondy_realm:to_external(X) || X <- bondy_realm:list()],
    R = wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

handle_call(?BONDY_REALM_UPDATE, M, Ctxt) ->
    [Uri, Data] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 2),

    Realm = bondy_realm:update(Uri, Data),
    Ext = bondy_realm:to_external(Realm),
    R = wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, R};

handle_call(?BONDY_REALM_SECURITY_ENABLE, M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),

    ok = bondy_realm:enable_security(Uri),
    R = wamp_message:result(M#call.request_id, #{}),
    {reply, R};

handle_call(?BONDY_REALM_SECURITY_DISABLE, M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),

    ok = bondy_realm:disable_security(Uri),
    R = wamp_message:result(M#call.request_id, #{}),
    {reply, R};

handle_call(?BONDY_REALM_SECURITY_STATUS, M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),

    Status = bondy_realm:security_status(Uri),
    R = wamp_message:result(M#call.request_id, #{}, [Status]),
    {reply, R};

handle_call(?BONDY_REALM_SECURITY_IS_ENABLED, M, Ctxt) ->
    [Uri] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),

    Boolean = bondy_realm:is_security_enabled(Uri),
    R = wamp_message:result(M#call.request_id, #{}, [Boolean]),
    {reply, R};

handle_call(_, M, _) ->
    E = bondy_wamp_utils:no_such_procedure_error(M),
    {reply, E}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
to_map(undefined) ->
    maps:new();

to_map(Term) when is_map(Term) ->
    Term.



