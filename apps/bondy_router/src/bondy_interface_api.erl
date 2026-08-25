%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_interface_api).
-moduledoc """
Implements the `bondy_wamp_api` behaviour for the interface metadata store
(`bondy_interface`): loading, listing, fetching and deleting interface
DOCUMENTS — the versioned artifacts a developer or CI pipeline publishes at
deploy time. All four are administrative (master-realm) operations, the
same posture as the API Gateway specification calls, because a document's
entries name their own realms.

The read side of the ENTRIES is not here: reading is WAMP Interface
Reflection (`wamp.reflection.*`, in `bondy_wamp_meta_api`).
""".
-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

-export([handle_call/3]).
-export([handle_event/2]).

%% =============================================================================
%% API
%% =============================================================================

-spec handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()
) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}.

handle_call(?BONDY_INTERFACE_LOAD, #call{} = M, Ctxt) ->
    [Document] = bondy_wamp_api_utils:validate_admin_call_args(M, Ctxt, 1),

    case bondy_interface:load(Document) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(?BONDY_INTERFACE_GET, #call{} = M, Ctxt) ->
    [Id] = bondy_wamp_api_utils:validate_admin_call_args(M, Ctxt, 1),

    case bondy_interface:get(Id) of
        {ok, Document} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Document]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(?BONDY_INTERFACE_LIST, #call{} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:validate_admin_call_args(M, Ctxt, 0),

    Result = bondy_interface:list(),
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
    {reply, R};
handle_call(?BONDY_INTERFACE_DELETE, #call{} = M, Ctxt) ->
    [Id] = bondy_wamp_api_utils:validate_admin_call_args(M, Ctxt, 1),

    case bondy_interface:delete(Id) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.

handle_event(_, #event{}) ->
    ok.
