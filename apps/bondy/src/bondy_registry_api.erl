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
-module(bondy_registry_api).
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

%% -----------------------------------------------------------------------------
%% bondy.registration.*
%% -----------------------------------------------------------------------------
handle_call(?BONDY_REGISTRATION_LIST, M, Ctxt) ->
    [RealmUri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    case list(registration, RealmUri) of
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};

        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_REGISTRATION_CALLEE_LIST, M, Ctxt) ->
    Args = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1, 2),
    case list_callees(Args) of
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};

        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

%% -----------------------------------------------------------------------------
%% bondy.subscription.*
%% -----------------------------------------------------------------------------
handle_call(?BONDY_SUBSCRIPTION_LIST, M, Ctxt) ->
    [RealmUri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    case list(subscription, RealmUri) of
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};

        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(_, M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.




%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
list(Type, RealmUri) ->
    list(Type, RealmUri, fun bondy_registry_entry:to_external/1).


list(Type, RealmUri, Fun) ->
    try
        case bondy_registry:entries(Type, RealmUri, '_') of
            [] ->
                {ok, []};
            Entries ->
                {ok, [Fun(E) || E <- Entries]}
        end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.

%% @private
list_callees([RealmUri]) ->
    try
        case bondy_dealer:callees(RealmUri) of
            [] ->
                {ok, []};
            Callees ->
                {ok, Callees}
        end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end;

list_callees([RealmUri, ProcedureUri]) ->
    try
        case bondy_dealer:callees(RealmUri, ProcedureUri) of
            [] ->
                {ok, []};
            Callees ->
                {ok, Callees}
        end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.
