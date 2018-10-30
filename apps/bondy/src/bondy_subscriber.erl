%% =============================================================================
%%  bondy_subscriber.erl -
%%
%%  Copyright (c) 2018 Ngineo Limited t/a Leapsight. All rights reserved.
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
%% @doc An anonymous subscription
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_subscriber).
-behaviour(gen_server).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-record(state, {
    realm_uri           ::  uri(),
    opts                ::  map(),
    topic               ::  binary(),
    callback_fun        ::  function(),
    subscription_id     ::  id() | undefined,
    stats = #{}         ::  map()
}).


%% API
-export([info/1]).
-export([name/1]).
-export([handle_event/2]).
-export([handle_event_sync/2]).
-export([start_link/4]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_link(uri(), map(), uri(), function()) ->
    {ok, pid()} | {error, any()}.

start_link(RealmUri, Opts0, Topic, Fun) ->
    Id =bondy_utils:get_id(global),
    Opts = maps:put(subscription_id, Id, Opts0),
    gen_server:start_link(
        {local, name(Id)}, ?MODULE, [RealmUri, Opts, Topic, Id, Fun], []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
%% @private
name(Id) ->
    list_to_atom("bondy_subscriber_" ++ integer_to_list(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
info(Subscriber) ->
    gen_server:call(Subscriber, info, 5000).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
handle_event(Subscriber, Event) ->
    gen_server:cast(Subscriber, Event).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
handle_event_sync(Subscriber, Event) ->
    gen_server:call(Subscriber, Event, 5000).




%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([RealmUri, Opts, Topic, Id, Fun]) when is_function(Fun, 2) ->
    {ok, Id} = bondy_broker:subscribe(RealmUri, Opts, Topic, self()),
    State = #state{
        realm_uri = RealmUri,
        opts = Opts,
        topic = Topic,
        callback_fun = Fun,
        subscription_id = Id
    },
    %% TODO maybe add Id as name for pid in gproc to enable unsubscribe
    {ok, State}.


handle_call(info, _From, State) ->
    Info = #{
        realm_uri => State#state.realm_uri,
        topic => State#state.topic,
        opts => State#state.topic,
        stats => State#state.stats,
        subscription_id => State#state.subscription_id
    },
    {reply, Info, State};

handle_call(#event{} = Event, _From, State) ->
    case do_handle_event(Event, State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {error, Reason, NewState} ->
            _ = lager:error(
                "Error while handling event; "
                "realm_uri=~p, event=~p, topic=~p, subscription_id=~p, pid=~p",
                [
                    Reason,
                    State#state.realm_uri,
                    State#state.topic,
                    State#state.subscription_id,
                    self()
                ]
            ),
            {reply, {error, Reason}, NewState}
    end;

handle_call(Event, From, State) ->
    _ = lager:debug("Unexpected event; event=~p, from=~p", [Event, From]),
    {noreply, State}.


handle_cast(#event{} = Event, State) ->
    %% TODO spawn using sidejob
    case do_handle_event(Event, State) of
        {ok, NewState} ->
            {noreply, NewState};
        {error, Reason, NewState} ->
            _ = lager:error(
                "Error while handling event; reason=~p "
                "realm_uri=~p, topic=~p, subscription_id=~p, pid=~p, event=~p",
                [
                    Reason,
                    State#state.realm_uri,
                    State#state.topic,
                    State#state.subscription_id,
                    self(),
                    Event
                ]
            ),
            {noreply, NewState}
    end;

handle_cast(Event, State) ->
    _ = lager:debug("Unexpected event; event=~p", [Event]),
    {noreply, State}.


handle_info(Info, State) ->
    _ = lager:debug("Unexpected event; event=~p", [Info]),
    {noreply, State}.


terminate(normal, State) ->
    do_unsubscribe(State);

terminate(shutdown, State) ->
    do_unsubscribe(State);

terminate({shutdown, _}, State) ->
    do_unsubscribe(State);

terminate(Reason, State) ->
    do_unsubscribe(State),
    _ = lager:error(
        "Terminating local subscriber; reason=~p, "
        "realm_uri=~p, topic=~p, subscription_id=~p, pid=~p",
        [Reason, State#state.realm_uri, State#state.topic, State#state.subscription_id, self()]
    ),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_unsubscribe(#state{subscription_id = undefined} = State) ->
    {{error, not_found}, State};

do_unsubscribe(#state{subscription_id = Id} = State) ->
    RealmUri = State#state.realm_uri,
    {bondy_broker:unsubscribe(Id, RealmUri), State#state{subscription_id = undefined}}.


%% @private
do_handle_event(#event{} = Event, State) ->
    try (State#state.callback_fun)(State#state.topic, Event) of
        ok ->
            {ok, State};
        {retry, _} ->
            retry_handle_event(Event, State, 50, 1);
        {error, Reason} ->
            {error, Reason, State}
    catch
        ?EXCEPTION(_, Reason, Stacktrace) ->
            _ = lager:error(
                "Error while evaluating action; reason=~p, "
                "stacktrace=~p",
                [Reason, ?STACKTRACE(Stacktrace)]
            ),
            {error, Reason, State}
    end.


%% @private

retry_handle_event(Event, State, Time, Cnt) ->
    timer:sleep(Time),
    case handle_event(Event, State) of
        {retry, Reason} when Cnt == 3 ->
            {error, Reason};
        {retry, _} ->
            retry_handle_event(Event, State, Time * 2, Cnt + 1)
    end.