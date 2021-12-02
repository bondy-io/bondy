%% -------------------------------------------------------------------
%%
%%  Copyright (c) 2017-2021 Leapsight. All rights reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% -----------------------------------------------------------------------------
%% @doc This module provides a bridge between WAMP events and OTP events.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_wamp_event_manager).
-behaviour(gen_event).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").


%% API

-export([add_handler/2]).
-export([add_callback/1]).
-export([add_sup_callback/1]).
-export([add_sup_handler/2]).
-export([notify/2]).
-export([start_link/0]).

%% gen_event callbacks
-export([init/1]).
-export([handle_event/2]).
-export([handle_call/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
    callback            ::  function()
}).



%% ===================================================================
%% API functions
%% ===================================================================



start_link() ->
    gen_event:start_link({local, ?MODULE}).


%% -----------------------------------------------------------------------------
%% @doc Adds an event handler.
%% Calls `gen_event:add_handler(?MODULE, Handler, Args)'.
%% The handler will receive all WAMP events.
%% @end
%% -----------------------------------------------------------------------------
add_handler(Handler, Args) ->
    gen_event:add_handler(?MODULE, Handler, Args).


%% -----------------------------------------------------------------------------
%% @doc Adds a supervised event handler.
%% Calls `gen_event:add_sup_handler(?MODULE, Handler, Args)'.
%% The handler will receive all WAMP events.
%% @end
%% -----------------------------------------------------------------------------
add_sup_handler(Handler, Args) ->
    gen_event:add_sup_handler(?MODULE, Handler, Args).


%% -----------------------------------------------------------------------------
%% @doc Subscribe to a WAMP event with a callback function.
%% The function needs to have two arguments representing the `topic_uri' and
%% the `wamp_event()' that has been published.
%% @end
%% -----------------------------------------------------------------------------
add_callback(Fun) when is_function(Fun, 2) ->
    Ref = make_ref(),
    ok = gen_event:add_handler(?MODULE, {?MODULE, Ref}, [Fun]),
    {ok, Ref}.


%% -----------------------------------------------------------------------------
%% @doc Subscribe to a WAMP event with a supervised callback function.
%% The function needs to have two arguments representing the `topic_uri' and
%% the `wamp_event()' that has been published.
%% @end
%% -----------------------------------------------------------------------------
add_sup_callback(Fun) when is_function(Fun, 2) ->
    Ref = make_ref(),
    gen_event:add_sup_handler(?MODULE, {?MODULE, Ref}, [Fun]),
    {ok, Ref}.


%% -----------------------------------------------------------------------------
%% @doc Notifies all event handlers of the event
%% @end
%% -----------------------------------------------------------------------------
notify(Topic, Event) ->
    gen_event:notify(?MODULE, {event, Topic, Event}).



%% =============================================================================
%% GEN_EVENT CALLBACKS
%% This is to support adding a fun via subscribe/1 and sup_subscribe/1
%% =============================================================================


init([Fun]) when is_function(Fun, 2) ->
    State = #state{
        callback = Fun
    },
    {ok, State}.


handle_event({event, Topic, #event{} = Event}, State) ->
    (State#state.callback)(Topic, Event),
    {ok, State}.


handle_call(Event, State) ->
    ?LOG_WARNING(#{
        description => "Error handling call",
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