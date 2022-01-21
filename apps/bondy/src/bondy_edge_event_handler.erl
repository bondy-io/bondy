%% =============================================================================
%%  bondy_edge_event_handler - An event handler to turn bondy events into
%% WAMP events.
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
    session_id      ::  id(),
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



init([RealmUri, SessionId, Pid]) ->
    State = #state{
        realm_uri = RealmUri,
        session_id = SessionId,
        pid = Pid
    },
    {ok, State}.


handle_event({Tag, Entry}, State)
when Tag =:= registration_created
orelse Tag =:= registration_added
orelse Tag =:= registration_deleted
orelse Tag =:= registration_removed
orelse Tag =:= subscription_created
orelse Tag =:= subscription_added
orelse Tag =:= subscription_removed
orelse Tag =:= subscription_deleted ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    SessionId = bondy_registry_entry:session_id(Entry),
    %% We avoid forwaring our own teh edge client own subscriptions
    Forward =
        RealmUri =:= State#state.realm_uri
        andalso SessionId =/= State#state.session_id,

    case Forward of
        true ->
            ok = forward({Tag, bondy_registry_entry:to_external(Entry)}, State),
            {ok, State};
        false ->
            {ok, State}
    end;

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



%% =============================================================================
%% PRIVATE
%% =============================================================================



forward(Msg, State) ->
    Pid = State#state.pid,
    SessionId = State#state.session_id,
    bondy_edge_uplink_client:forward(Pid, Msg, SessionId).