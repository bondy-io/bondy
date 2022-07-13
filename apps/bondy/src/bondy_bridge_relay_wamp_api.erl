%% =============================================================================
%%  bondy_bridge_api.erl - Bondy configuration schema for Cuttlefish
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
-module(bondy_bridge_relay_wamp_api).
-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").

-include("bondy_uris.hrl").

-export([handle_call/3]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_call(
    Proc :: uri(), M :: wamp_message:call(), Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined)
    }
    | {reply, wamp_result() | wamp_error()}.


handle_call(?BONDY_ROUTER_BRIDGE_ADD, #call{} = M, Ctxt) ->
    [Data] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),
    Reply = case bondy_bridge_relay_manager:add_bridge(Data, M#call.kwargs) of
        {ok, Bridge} ->
            Ext = bondy_bridge_relay:to_external(Bridge),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end,
    {reply, Reply};

handle_call(?BONDY_ROUTER_BRIDGE_CHECK_SPEC, #call{} = M, Ctxt) ->
    [Data] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),
    Reply = try bondy_bridge_relay:new(Data) of
        Bridge ->
            Ext = bondy_bridge_relay:to_external(Bridge),
            wamp_message:result(M#call.request_id, #{}, [Ext])
        catch
            _:Reason ->
                bondy_wamp_utils:error(Reason, M)
    end,
    {reply, Reply};

handle_call(?BONDY_ROUTER_BRIDGE_REMOVE, #call{} = M, Ctxt) ->
    [Name] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),
    Reply = case bondy_bridge_relay_manager:remove_bridge(Name) of
        ok ->
            wamp_message:result(M#call.request_id, #{}, []);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end,
    {reply, Reply};

handle_call(?BONDY_ROUTER_BRIDGE_START, #call{} = M, Ctxt) ->
    [Name] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),
    Reply = case bondy_bridge_relay_manager:start_bridge(Name) of
        ok ->
            wamp_message:result(M#call.request_id, #{}, []);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end,
    {reply, Reply};

handle_call(?BONDY_ROUTER_BRIDGE_STOP, #call{} = M, Ctxt) ->
    [Name] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),
    Reply = case bondy_bridge_relay_manager:stop_bridge(Name) of
        ok ->
            wamp_message:result(M#call.request_id, #{}, []);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end,
    {reply, Reply};

handle_call(?BONDY_ROUTER_BRIDGE_GET, #call{} = M, Ctxt) ->
    [Name] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1),
    Reply = case bondy_bridge_relay_manager:get_bridge(Name) of
        {ok, Bridge} ->
            Ext = bondy_bridge_relay:to_external(Bridge),
            wamp_message:result(M#call.request_id, #{}, [Ext]);
        {error, Reason} ->
            bondy_wamp_utils:error(Reason, M)
    end,
    {reply, Reply};

handle_call(?BONDY_ROUTER_BRIDGE_LIST, #call{} = M, Ctxt) ->
    [] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 0),
    List = bondy_bridge_relay_manager:list_bridges(),
    Ext = [bondy_bridge_relay:to_external(B) || B <- List],
    Reply = wamp_message:result(M#call.request_id, #{}, [Ext]),
    {reply, Reply};

handle_call(?BONDY_ROUTER_BRIDGE_STATUS, #call{} = M, Ctxt) ->
    [] = bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 0),
    Status = bondy_bridge_relay_manager:status(),
    Reply = wamp_message:result(M#call.request_id, #{}, [Status]),
    {reply, Reply};

handle_call(_, #call{} = M, _) ->
    no_such_procedure(M).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
no_such_procedure(M) ->
    E = bondy_wamp_utils:no_such_procedure_error(M),
    {reply, E}.