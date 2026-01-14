%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_cluster_api).
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
    | {reply, wamp_result() | wamp_error()}
    | no_return().

handle_call(?BONDY_CLUSTER_JOIN, #call{} = M, _Ctxt) ->
    R = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, R};

handle_call(?BONDY_CLUSTER_LEAVE, #call{} = M, _Ctxt) ->
    %% TODO
    R = bondy_wamp_message:result(M#call.request_id, #{}, []),
    {reply, R};

handle_call(?BONDY_CLUSTER_CONNECTIONS, #call{} = M, _Ctxt) ->
    %% TODO
    R = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, R};

handle_call(?BONDY_CLUSTER_MEMBERS, #call{} = M, _Ctxt) ->
    {ok, Members} = partisan_peer_service:members(),
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Members]),
    {reply, R};

handle_call(?BONDY_CLUSTER_INFO, #call{} = M, _Ctxt) ->
    %% TODO
    Info = #{
        <<"node_spec">> => bondy_wamp_api_utils:node_spec(),
        <<"nodes">> => partisan:nodes()
    },
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Info]),
    {reply, R};

handle_call(_, #call{} = M, _) ->
    R = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, R}.



%% =============================================================================
%% PRIVATE
%% =============================================================================

