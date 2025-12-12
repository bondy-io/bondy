%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_http_gateway_api).
-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").



-export([handle_call/3]).
-export([handle_event/2]).


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


handle_call(?BONDY_HTTP_GATEWAY_LOAD, #call{} = M, Ctxt) ->
    [Spec] = bondy_wamp_api_utils:validate_admin_call_args(M, Ctxt, 1),

    case bondy_http_gateway:load(Spec) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_HTTP_GATEWAY_LIST, #call{} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:validate_admin_call_args(M, Ctxt, 0),

    Result = bondy_http_gateway:list(),
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
    {reply, R};

handle_call(?BONDY_HTTP_GATEWAY_GET, #call{} = M, Ctxt) ->
    [Id] = bondy_wamp_api_utils:validate_admin_call_args(M, Ctxt, 1),

    case bondy_http_gateway:lookup(Id) of
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E};
        Spec ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Spec]),
            {reply, R}
    end;

handle_call(?BONDY_HTTP_GATEWAY_DELETE, #call{} = M, Ctxt) ->
    [Id] = bondy_wamp_api_utils:validate_admin_call_args(M, Ctxt, 1),

    case bondy_http_gateway:delete(Id) of
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E};
        Spec ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Spec]),
            {reply, R}
    end;

handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
handle_event(_, #event{}) ->
    ok.




