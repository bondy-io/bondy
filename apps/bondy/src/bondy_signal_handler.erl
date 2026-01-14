%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_signal_handler).
-behaviour(gen_event).

-include_lib("kernel/include/logger.hrl").

-export([init/1]).
-export([handle_event/2]).
-export([handle_call/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {}).



%% =============================================================================
%% GEN_EVENT CALLBACKS
%% =============================================================================



init(_Args) ->
    {ok, #state{}}.


handle_event(sigterm, S) ->
    ?LOG_WARNING(#{
        description => "SIGTERM received. Initiating shutdown."
    }),
    ok = init:stop(),
    {ok, S};

handle_event(SignalMsg, S) ->
    %% Handle all other signals using the default OTP handler
    erl_signal_handler:handle_event(SignalMsg, S),
    {ok, S}.


handle_info(_Info, S) ->
    {ok, S}.


handle_call(_Request, S) ->
    {ok, ok, S}.


code_change(_OldVsn, S, _Extra) ->
    {ok, S}.


terminate(_Args, _S) ->
    ok.
