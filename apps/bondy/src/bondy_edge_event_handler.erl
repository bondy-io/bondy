%% =============================================================================
%%  bondy_edge_event_handler - An event handler to turn bondy events into
%% WAMP events.
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
%% @doc An event handler to generates WAMP Meta Events based on internal
%% Bondy events
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_edge_event_handler).
-behaviour(gen_event).
-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").


-record(state, {
    realm_uri       ::  uri(),
    pid             ::  pid()
}).


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



init([RealmUri, Pid]) ->
    State = #state{
        realm_uri = RealmUri,
        pid = Pid
    },
    {ok, State}.


handle_event({_, _, Ctxt} = Event, State) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    case RealmUri == State#state.realm_uri of
        true ->
            do_handle_event(Event, State);
        false ->
            {ok, State}
    end.


handle_call(Event, State) ->
    ?LOG_ERROR(#{
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



%% =============================================================================
%% PRIVATE
%% =============================================================================


forward(Msg, State) ->
    Uri = State#state.realm_uri,
    Pid = State#state.pid,
    gen_statem:cast(Pid, {forward, Msg, Uri}).



do_handle_event({registration_added = T, Entry, _}, State) ->
    ok = forward({T, Entry}, State),
    {ok, State};

do_handle_event({registration_deleted = T, Entry, _}, State) ->
    ok = forward({T, Entry}, State),
    {ok, State};

do_handle_event({registration_removed = T, Entry, _}, State) ->
    ok = forward({T, Entry}, State),
    {ok, State};

do_handle_event({subscription_created = T, Entry, _}, State) ->
    ok = forward({T, Entry}, State),
    {ok, State};

do_handle_event({subscription_added = T, Entry, _}, State) ->
    ok = forward({T, Entry}, State),
    {ok, State};

do_handle_event({subscription_removed = T, Entry, _}, State) ->
    ok = forward({T, Entry}, State),
    {ok, State};

do_handle_event({subscription_deleted = T, Entry, _}, State) ->
    ok = forward({T, Entry}, State),
    {ok, State};

do_handle_event(_, State) ->
    %% We are not interested in this event
    {ok, State}.

