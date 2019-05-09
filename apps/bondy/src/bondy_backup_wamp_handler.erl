%% =============================================================================
%%  bondy_backup_wamp_handler.erl -
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
-module(bondy_backup_wamp_handler).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_backup.hrl").

-export([handle_call/2]).



%% =============================================================================
%% API
%% =============================================================================



handle_call(
    #call{procedure_uri = ?CREATE_BACKUP} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [Info]} ->
            bondy_wamp_utils:maybe_error(bondy_backup:backup(Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(
    #call{procedure_uri = ?BACKUP_STATUS} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [Info]} ->
            bondy_wamp_utils:maybe_error(bondy_backup:status(Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(
    #call{procedure_uri = ?RESTORE_BACKUP} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [Info]} ->
            bondy_wamp_utils:maybe_error(bondy_backup:restore(Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R).