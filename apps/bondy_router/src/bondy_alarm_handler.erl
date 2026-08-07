%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_alarm_handler).
-moduledoc """
A replacement for OTP's default `alarm_handler`.
""".
-behaviour(gen_event).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    alarms = [] :: list()
}).

%% API
-export([clear_alarm/1]).
-export([get_alarms/0]).
-export([set_alarm/1]).

%% GEN_EVENT CALLBACKS
-export([init/1]).
-export([handle_event/2]).
-export([handle_call/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% =============================================================================
%% API
%% =============================================================================

set_alarm(Alarm) ->
    gen_event:notify(alarm_handler, {set_alarm, Alarm}).

clear_alarm(AlarmId) ->
    gen_event:notify(alarm_handler, {clear_alarm, AlarmId}).

get_alarms() ->
    gen_event:call(alarm_handler, ?MODULE, get_alarms).

%% =============================================================================
%% GEN_EVENT CALLBACKS
%% =============================================================================

init([]) ->
    State = #state{},
    {ok, State};
init({[], _}) ->
    %% In case of a swap
    State = #state{},
    {ok, State}.

%% An alarm is identified by its id: raising one that is already raised is a
%% RESTATEMENT, not a second alarm. Callers restate freely — e.g.
%% `bondy_oplog_responder` and `bondy_oplog_applier` set theirs once per
%% offending item — so appending per `set_alarm` grew `alarms` without bound,
%% and because `clear_alarm/1` removes only the FIRST match the alarm could
%% never be cleared again. Key on the id and log only on a transition, so the
%% log records what actually changed rather than the caller's call rate.
handle_event({set_alarm, {Id, Desc} = Alarm}, State0) ->
    Alarms0 = State0#state.alarms,
    case lists:keyfind(Id, 1, Alarms0) of
        {Id, Desc} ->
            %% Already raised, identical description: nothing changed.
            {ok, State0};
        {Id, _Previous} ->
            ?LOG_WARNING(#{
                description => "Alarm updated",
                alarm_id => Id,
                alarm_description => Desc
            }),
            {ok, State0#state{
                alarms = lists:keyreplace(Id, 1, Alarms0, Alarm)
            }};
        false ->
            ?LOG_WARNING(#{
                description => "Alarm set",
                alarm_id => Id,
                alarm_description => Desc
            }),
            {ok, State0#state{alarms = [Alarm | Alarms0]}}
    end;
handle_event({clear_alarm, AlarmId}, State0) ->
    %% Clearing an alarm that was never raised is a no-op, and several callers
    %% do it unconditionally on recovery. Only a real transition is logged —
    %% without this an operator sees alarms raised and never sees them resolve.
    case lists:keymember(AlarmId, 1, State0#state.alarms) of
        false ->
            {ok, State0};
        true ->
            ?LOG_NOTICE(#{
                description => "Alarm cleared",
                alarm_id => AlarmId
            }),
            {ok, State0#state{
                alarms = lists:keydelete(AlarmId, 1, State0#state.alarms)
            }}
    end;
handle_event(_Event, State) ->
    {ok, State}.

handle_call(get_alarms, State) ->
    {ok, State#state.alarms, State};
handle_call(_, State) ->
    {ok, {error, bad_query}, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
