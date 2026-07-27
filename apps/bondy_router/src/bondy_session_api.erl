%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_session_api).
-moduledoc """
Implements the WAMP API procedures for sessions, such as `bondy.session.get`
and `bondy.session.self`.
""".
-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-export([get/3]).

-export([handle_call/3]).

%% =============================================================================
%% API
%% =============================================================================

get(RealmUri, Guid, _Details) when is_binary(Guid) ->
    %% Callback for the per-node `wamp.session.<hash>..get` wildcard. `Guid` is
    %% the client-facing session id (`{NodeHash}.{Rest}`), which is also the
    %% internal session store key; the lookup is realm-scoped so a caller cannot
    %% read a session in another realm co-located on this node.
    case bondy_session:lookup(RealmUri, Guid) of
        {ok, Session} ->
            {ok, #{}, [bondy_session:to_external(Session)], #{}};
        {error, not_found} ->
            no_such_session_error()
    end;

get(_RealmUri, _Guid, _Details) ->
    no_such_session_error().

%% =============================================================================
%% CALBACKS
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

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
no_such_session_error() ->
    Uri = ?WAMP_NO_SUCH_SESSION,
    Msg = <<"No session exists for the supplied identifier">>,
    {error, Uri, #{}, [Msg]}.
