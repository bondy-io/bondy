%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Ngineo Limited t/a Leapsight.  All Rights Reserved.
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

-module(bondy_broker_events).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-behaviour(gen_event).

%% API

-export([subscribe/4]).
-export([add_handler/2]).
-export([sup_subscribe/4]).
-export([add_sup_handler/2]).
-export([notify/1]).
-export([start_link/0]).
-export([unsubscribe/1]).

%% gen_event callbacks
-export([init/1]).
-export([handle_event/2]).
-export([handle_call/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
    realm_uri           ::  uri(),
    options             ::  map(),
    registration_id     ::  id(),
    topic_uri           ::  binary(),
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
%% @end
%% -----------------------------------------------------------------------------
add_handler(Handler, Args) ->
    gen_event:add_handler(?MODULE, Handler, Args).


%% -----------------------------------------------------------------------------
%% @doc Adds a supervised event handler.
%% Calls `gen_event:add_sup_handler(?MODULE, Handler, Args)'.
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
subscribe(RealmUri, Opts, TopicUri, Fun) when is_function(Fun, 2) ->
    Ref = make_ref(),
    ok = gen_event:add_handler(
        ?MODULE, {?MODULE, Ref}, [RealmUri, Opts, TopicUri, Fun]),
    {ok, Ref}.


%% -----------------------------------------------------------------------------
%% @doc Subscribe to a WAMP event with a supervised callback function.
%% The function needs to have two arguments representing the `topic_uri' and
%% the `wamp_event()' that has been published.
%% @end
%% -----------------------------------------------------------------------------
sup_subscribe(RealmUri, Opts, TopicUri, Fun) when is_function(Fun, 2) ->
    Ref = make_ref(),
    gen_event:add_sup_handler(
        ?MODULE, {?MODULE, Ref}, [RealmUri, Opts, TopicUri, Fun]),
    {ok, Ref}.


%% -----------------------------------------------------------------------------
%% @doc Remove subscription created using `subscribe/3 or sup_subscribe/3'
%% @end
%% -----------------------------------------------------------------------------
unsubscribe(Ref) ->
    gen_event:delete_handler(?MODULE, {?MODULE, Ref}, [unsubscribe]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
notify(Event) ->
    gen_event:notify(?MODULE, Event).




%% =============================================================================
%% GEN_EVENT CALLBACKS
%% This is to support adding a fun via subscribe/1 and sup_subscribe/1
%% =============================================================================


init([RealmUri, Opts, TopicUri, Fun]) when is_function(Fun, 2) ->
    %% Subscribe to wamp topic
    {ok, SubsId} = bondy_broker:subscribe(RealmUri, Opts, TopicUri, self()),

    State = #state{
        realm_uri = RealmUri,
        options = Opts,
        registration_id = SubsId,
        topic_uri = TopicUri,
        callback = Fun
    },
    {ok, State}.


handle_event(#event{} = Event, State) ->
    %% We notify callback funs
    (State#state.callback)(State#state.topic_uri, Event),
    {ok, State}.


handle_call(_Request, State) ->
    {ok, ok, State}.


handle_info(_Info, State) ->
    {ok, State}.


terminate(unsubscribe, #state{registration_id = RegId}) ->
    _ = bondy_broker:unsubscribe(RegId),
    ok;

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.