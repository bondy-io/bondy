%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_export_api).
-moduledoc """
Implements the `bondy_wamp_api` behaviour for the Bondy export administrative
procedures, dispatching WAMP calls to create exports, query their status, and
import export files via `m:bondy_export`.

The `bondy.export.*` procedures are the current API; the legacy
`bondy.backup.*` procedures (`create`/`status`/`restore`) are kept as
deprecated aliases that map onto the same operations.
""".
-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

-export([handle_call/3]).

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

handle_call(?BONDY_EXPORT_CREATE, #call{} = M, Ctxt) ->
    [Info] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 1),
    E = bondy_wamp_api_utils:maybe_error(bondy_export:export(Info), M),
    {reply, E};
handle_call(?BONDY_EXPORT_STATUS, #call{} = M, Ctxt) ->
    [Info] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 1),
    E = bondy_wamp_api_utils:maybe_error(bondy_export:status(Info), M),
    {reply, E};
handle_call(?BONDY_EXPORT_IMPORT, #call{} = M, Ctxt) ->
    [Info] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 1),
    E = bondy_wamp_api_utils:maybe_error(bondy_export:import(Info), M),
    {reply, E};
%% Deprecated bondy.backup.* aliases.
handle_call(?BONDY_BACKUP_CREATE, #call{} = M, Ctxt) ->
    [Info] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 1),
    E = bondy_wamp_api_utils:maybe_error(bondy_export:export(Info), M),
    {reply, E};
handle_call(?BONDY_BACKUP_STATUS, #call{} = M, Ctxt) ->
    [Info] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 1),
    E = bondy_wamp_api_utils:maybe_error(bondy_export:status(Info), M),
    {reply, E};
handle_call(?BONDY_BACKUP_RESTORE, #call{} = M, Ctxt) ->
    [Info] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 1),
    E = bondy_wamp_api_utils:maybe_error(bondy_export:import(Info), M),
    {reply, E};
handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.
