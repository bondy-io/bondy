%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_session_api).
-behaviour(bondy_wamp_api).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-export([get/3]).

-export([handle_call/3]).

%% =============================================================================
%% API
%% =============================================================================

get(Key, SessionId, _Details) ->
    try
        case bondy_session:lookup(Key) of
            {ok, Session} ->
                case bondy_session:external_id(Session) of
                    SessionId ->
                        {ok, #{}, [bondy_session:to_external(Session)], #{}};
                    OtherId ->
                        ?LOG_WARNING(#{
                            description => "Session data inconsistency. SessionId should be " ++ integer_to_list(SessionId) ++ ".",
                            session_id => OtherId
                        }),
                        throw(no_such_session)
                end;
            {error, not_found} ->
                throw(no_such_session)
        end

    catch
        throw:no_such_session ->
            Uri = ?WAMP_NO_SUCH_SESSION,
            Msg = <<"No session exists for the supplied identifier">>,
            {error, Uri, #{}, [Msg]}
    end.

%% =============================================================================
%% CALBACKS
%% =============================================================================


-spec handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined)
    }
    | {reply, wamp_result() | wamp_error()}.


handle_call(~"bondy.session.self", #call{} = M, Ctxt) ->
    case bondy_context:session(Ctxt) of
        undefined ->
            E = bondy_wamp_api_utils:error(not_found, M),
            {reply, E};
        Session ->
            Ext0 = bondy_session:to_external(Session),
            Ext = Ext0#{
                'x_authroles' => bondy_session:authroles(Session),
                'x_meta' => key_value:get([authextra, meta], Ext0, #{})
            },
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Ext]),
            {reply, R}
    end.
