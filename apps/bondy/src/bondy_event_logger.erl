%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc An event handler to generates WAMP Meta Events based on internal
%% Bondy events
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_event_logger).
-behaviour(gen_event).
-include_lib("kernel/include/logger.hrl").

-record(state, {}).

%% GEN_EVENT CALLBACKS
-export([init/1]).
-export([handle_event/2]).
-export([handle_call/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).



%% =============================================================================
%% GEN_EVENT CALLBACKS
%% =============================================================================



init([]) ->
    State = #state{},
    {ok, State}.


handle_event(Event, State) when element(1, Event) =/= wamp ->
    ?LOG_NOTICE(#{
        event => Event
    }),
    {ok, State};

handle_event(_, State) ->
    {ok, State}.


handle_call(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_info(_Info, State) ->
    {ok, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
