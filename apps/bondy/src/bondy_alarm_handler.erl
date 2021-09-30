%% =============================================================================
%%  bondy_alarm_handler.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
%% @doc This module implements a replacement for OTP's default alarm_handler.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_alarm_handler).
-behaviour(gen_event).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    alarms = []     ::  list()
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


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
set_alarm(Alarm) ->
    gen_event:notify(alarm_handler, {set_alarm, Alarm}).

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
clear_alarm(AlarmId) ->
    gen_event:notify(alarm_handler, {clear_alarm, AlarmId}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
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

handle_event({set_alarm, {Id, Desc} = Alarm}, State0)->
    ?LOG_WARNING(#{
        description => "Alarm set",
        alarm_id => Id,
        alarm_description => Desc
    }),
    Alarms = case {State0#state.alarms, Id} of
        {[], _} ->
            [Alarm];
        {L, system_memory_high_watermark} ->
            lists:keyreplace(
                system_memory_high_watermark, 1, L, Alarm);
        {L, _} ->
            [Alarm | L]
    end,
    State1 = State0#state{alarms = Alarms},
    {ok, State1};

handle_event({clear_alarm, AlarmId}, State0)->
    State1 = State0#state{
        alarms = lists:keydelete(AlarmId, 1, State0#state.alarms)
    },
    {ok, State1};

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

