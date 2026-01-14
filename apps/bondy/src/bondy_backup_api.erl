%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_backup_api).
-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
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


handle_call(?BONDY_BACKUP_CREATE, #call{} = M, Ctxt) ->
    [Info] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    E = bondy_wamp_api_utils:maybe_error(bondy_backup:backup(Info), M),
    {reply, E};

handle_call(?BONDY_BACKUP_STATUS, #call{} = M, Ctxt) ->
    [Info] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    E = bondy_wamp_api_utils:maybe_error(bondy_backup:status(Info), M),
    {reply, E};

handle_call(?BONDY_BACKUP_RESTORE, #call{} = M, Ctxt) ->
    [Info] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    E = bondy_wamp_api_utils:maybe_error(bondy_backup:restore(Info), M),
    {reply, E};

handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.
