%% =============================================================================
%%  bondy_security_api_handler.erl -
%%
%%  Copyright (c) 2016-2018 Ngineo Limited t/a Leapsight. All rights reserved.
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
-module(bondy_security_api_handler).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_meta_api.hrl").

-export([handle_call/2]).

%%TODO Replace all this logic with RBAC

handle_call(#call{procedure_uri = ?CREATE_REALM} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Map]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:to_map(bondy_realm:add(Map)), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?UPDATE_REALM} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 2) of
        {ok, [Uri, Map]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:to_map(bondy_realm:update(Uri, Map)), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?DELETE_REALM} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(catch bondy_realm:delete(Uri), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?LIST_REALMS} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 0, 0) of
        {ok, []} ->
            bondy_wamp_utils:maybe_error(
                catch [bondy_realm:to_map(X) || X <- bondy_realm:list()],
                M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);


handle_call(#call{procedure_uri = ?ENABLE_SECURITY} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:enable_security(bondy_realm:fetch(Uri)),
                M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?DISABLE_SECURITY} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:disable_security(bondy_realm:fetch(Uri)),
                M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?SECURITY_STATUS} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:security_status(bondy_realm:fetch(Uri)),
                M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?IS_SECURITY_ENABLED} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:is_security_enabled(bondy_realm:fetch(Uri)), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?ADD_USER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:add(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?UPDATE_USER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:update(Uri, Username, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?DELETE_USER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:remove(Uri, Username), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?LIST_USERS} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(bondy_security_user:list(Uri), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?FIND_USER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:lookup(Uri, Username), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?CHANGE_PASSWORD} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3, 4) of
        {ok, [Uri, Username, New]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:change_password(Uri, Username, New),
                M
            );
        {ok, [Uri, Username, New, Old]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:change_password(Uri, Username, New, Old),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?ADD_GROUP} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_group:add(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?DELETE_GROUP} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Name]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_group:remove(Uri, Name), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?LIST_GROUPS} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(bondy_security_group:list(Uri), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?FIND_GROUP} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Name]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_group:lookup(Uri, Name), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?UPDATE_GROUP} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Name, Info]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_group:update(Uri, Name, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?ADD_SOURCE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?DELETE_SOURCE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?LIST_SOURCES} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?FIND_SOURCE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{} = M, Ctxt) ->
    Error = bondy_wamp_utils:no_such_procedure_error(M),
    bondy:send(bondy_context:peer_id(Ctxt), Error).
