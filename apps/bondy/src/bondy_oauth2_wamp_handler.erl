%% =============================================================================
%%  bondy_http_utils.erl -
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
-module(bondy_oauth2_wamp_handler).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(LOOKUP_TOKEN, <<"com.leapsight.bondy.oauth2.lookup_token">>).
-define(REVOKE_TOKEN, <<"com.leapsight.bondy.oauth2.revoke_token">>).
-define(REVOKE_TOKENS, <<"com.leapsight.bondy.oauth2.revoke_tokens">>).

-export([handle_call/2]).



%% =============================================================================
%% API
%% =============================================================================


handle_call(#call{procedure_uri = ?LOOKUP_TOKEN} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Issuer, Token]} ->
            Res = bondy_oauth2:lookup_token(Uri, Issuer, Token),
            bondy_wamp_utils:maybe_error(Res, M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?REVOKE_TOKEN} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3, 4) of
        {ok, [Uri, Issuer, Token]} ->
            Res = bondy_oauth2:revoke_token(
                refresh_token, Uri, Issuer, Token),
            bondy_wamp_utils:maybe_error(Res, M);
        {ok, [Uri, Issuer, Username, DeviceId]} ->
            Res = bondy_oauth2:revoke_token(
                refresh_token, Uri, Issuer, Username, DeviceId),
            bondy_wamp_utils:maybe_error(Res, M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?REVOKE_TOKENS} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Issuer, Username]} ->
            Res = bondy_oauth2:revoke_token(
                refresh_token, Uri, Issuer, Username),
            bondy_wamp_utils:maybe_error(Res, M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{} = M, Ctxt) ->
    Error = bondy_wamp_utils:no_such_procedure_error(M),
    bondy:send(bondy_context:peer_id(Ctxt), Error).
