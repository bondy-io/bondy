%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_ticket_api).
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

handle_call(?BONDY_TICKET_ISSUE, #call{} = M, Ctxt) ->
    [_Uri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 0),
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
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Resp]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(?BONDY_TICKET_REVOKE_ALL, #call{} = M, Ctxt) ->
    [Uri, Authid] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    ok = bondy_ticket:revoke_all(Uri, Authid),
    R = bondy_wamp_message:result(M#call.request_id, #{}),
    {reply, R};

%% TODO BONDY_TICKET_VERIFY
%% TODO BONDY_TICKET_REVOKE

handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------

handle_event(_, _) ->
    ok.



