%% =============================================================================
%%  bondy_ticket_wamp_api.erl -
%%
%%  Copyright (c) 2016-2023 Leapsight. All rights reserved.
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
-module(bondy_ticket_wamp_api).
-behaviour(bondy_wamp_api).

-include_lib("wamp/include/wamp.hrl").
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
    Proc :: uri(), M :: wamp_message:call(), Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined)
    }
    | {reply, wamp_result() | wamp_error()}.

handle_call(?BONDY_TICKET_ISSUE, #call{} = M, Ctxt) ->
    [_Uri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 0),
    Session = bondy_context:session(Ctxt),

    Opts = case M#call.kwargs of
        undefined -> maps:new();
        Map -> Map
    end,

    case bondy_ticket:issue(Session, Opts) of
        {ok, Ticket, Claims} ->
            Resp0 = maps:with(
                [id, expires_at, issued_at, scope], Claims
            ),
            Resp = maps:put(ticket, Ticket, Resp0),
            R = wamp_message:result(M#call.request_id, #{}, [Resp]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_TICKET_REVOKE_ALL, #call{} = M, Ctxt) ->
    [Uri, Authid] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    ok = bondy_ticket:revoke_all(Uri, Authid),
    R = wamp_message:result(M#call.request_id, #{}),
    {reply, R};

%% TODO BONDY_TICKET_VERIFY
%% TODO BONDY_TICKET_REVOKE

handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_utils:no_such_procedure_error(M),
    {reply, E}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------

handle_event(_, _) ->
    ok.



