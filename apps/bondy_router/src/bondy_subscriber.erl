%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_subscriber).
-moduledoc """
This module implements a supervised process (gen_server) that acts as a local
(internal) WAMP subscriber that when received an EVENT applies the user provided
function.

It is used by `bondy_broker:subscribe/4` and `bondy_broker:unsubscribe/1`.
""".
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-record(state, {
    realm_uri :: uri(),
    session_id :: bondy_session_id:t(),
    opts :: map(),
    meta :: map(),
    topic :: binary(),
    callback_fun :: function(),
    subscription_id :: id() | undefined,
    stats = #{} :: map()
}).

%% API
-export([info/1]).
-export([name/1]).
-export([pid/1]).
-export([handle_event/2]).
-export([handle_event_sync/2]).
-export([start_link/5]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).

%% =============================================================================
%% CALLBACK API
%% =============================================================================

% -callback init(Args :: any()) ->
%     {ok, NewState :: any()} | {error, Reason :: any()}.

% -callback handle_event(Event :: wamp_event(), State :: any()) ->
%     {ok, NewState :: any()}.

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(id(), uri(), map(), uri(), function()) ->
    {ok, pid()} | {error, any()}.

start_link(Id, RealmUri, Opts, Topic, Fun) ->
    gen_server:start_link(
        {local, name(Id)}, ?MODULE, [Id, RealmUri, Opts, Topic, Fun], []
    ).

%% @private
name(Id) ->
    list_to_atom("bondy_subscriber_" ++ integer_to_list(Id)).

pid(Id) ->
    bondy_gproc:lookup_pid({?MODULE, Id}).

info(Subscriber) ->
    gen_server:call(Subscriber, info, 5000).

handle_event(Subscriber, Event) ->
    gen_server:cast(Subscriber, Event).

handle_event_sync(Subscriber, Event) ->
    gen_server:call(Subscriber, Event, 5000).

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([Id, RealmUri, Opts0, Topic, Fun]) when is_function(Fun, 2) ->
    Opts = maps:put(subscription_id, Id, Opts0),
    Meta = maps:get(meta, Opts0, #{}),
    SessionId = bondy_session_id:new(),

    Ref = bondy_ref:new(internal, self(), SessionId),

    case bondy_broker:subscribe(RealmUri, Opts, Topic, Ref) of
        {ok, Id} ->
            State = #state{
                realm_uri = RealmUri,
                opts = maps:without([meta], Opts),
                meta = Meta,
                topic = Topic,
                callback_fun = Fun,
                subscription_id = Id
            },
            {ok, State};
        {error, already_exists} = Error ->
            Error
    end.

handle_call(info, _From, State) ->
    Info = #{
        meta => State#state.meta,
        options => maps:without([subscription_id], State#state.opts),
        realm_uri => State#state.realm_uri,
        stats => State#state.stats,
        subscription_id => State#state.subscription_id,
        topic => State#state.topic
    },
    {reply, Info, State};
handle_call(#event{} = Event, _From, State) ->
    %% Synchronous delivery does not retry -- see apply_callback/3.
    case apply_callback(Event, undefined, State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {error, Reason, NewState} ->
            ok = log_event_error(Reason, State),
            {reply, {error, Reason}, NewState}
    end;
handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {noreply, State}.

handle_cast(#event{} = Event, State) ->
    case do_handle_event(Event, State) of
        {ok, NewState} ->
            {noreply, NewState};
        {error, Reason, NewState} ->
            ok = log_event_error(Reason, State),
            {noreply, NewState}
    end;
handle_cast(Event, State) ->
    ?LOG_DEBUG(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

handle_info(
    {?BONDY_REQ, _Pid, _RealmUri, #event{} = WAMPEvent}, State
) ->
    case do_handle_event(WAMPEvent, State) of
        {ok, NewState} ->
            {noreply, NewState};
        {error, Reason, NewState} ->
            ?LOG_ERROR(#{
                description => "Error while handling event",
                reason => Reason,
                realm_uri => State#state.realm_uri,
                topic => State#state.topic,
                subscription_id => State#state.subscription_id,
                wamp_event => WAMPEvent
            }),
            {noreply, NewState}
    end;
handle_info({?MODULE, retry, Event, Retry}, State) ->
    case apply_callback(Event, Retry, State) of
        {ok, NewState} ->
            {noreply, NewState};
        {error, Reason, NewState} ->
            ok = log_event_error(Reason, State),
            {noreply, NewState}
    end;
handle_info(Event, State) ->
    ?LOG_DEBUG(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

terminate(normal, State) ->
    do_unsubscribe(State);
terminate(shutdown, State) ->
    do_unsubscribe(State);
terminate({shutdown, _}, State) ->
    do_unsubscribe(State);
terminate(Reason, State) ->
    do_unsubscribe(State),
    ?LOG_ERROR(#{
        description => "Error while handling event",
        reason => Reason,
        realm_uri => State#state.realm_uri,
        topic => State#state.topic,
        subscription_id => State#state.subscription_id
    }),
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
    {
        bondy_broker:unsubscribe(Id, RealmUri),
        State#state{subscription_id = undefined}
    }.

%% @private
do_handle_event(Event, State) ->
    apply_callback(Event, new_retry(), State).

%% @private
%% `Retry` is `undefined` for synchronous delivery: backing off inside a
%% `gen_server:call/3` would hold the caller for the whole budget, so the
%% outcome is reported and the caller decides what to do with it.
apply_callback(Event, Retry, State) ->
    try (State#state.callback_fun)(State#state.topic, Event) of
        ok ->
            {ok, State};
        {retry, Reason} when Retry == undefined ->
            {error, {retry_not_supported, Reason}, State};
        {retry, Reason} ->
            schedule_retry(Event, Reason, Retry, State);
        {error, Reason} ->
            {error, Reason, State}
    catch
        _:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while evaluating action",
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason, State}
    end.

%% @private
%% A retry goes back through the mailbox instead of being slept on.
%%
%% This used to call `timer:sleep/1` and then `handle_event(Event, State)` --
%% the public API, whose arguments are `(Subscriber, Event)` -- so the retry
%% became `gen_server:cast(#event{}, State)` and crashed. Even had it called the
%% right function, there was no `ok` clause, and it answered two-tuples where
%% every caller matches three. The sleep also stalled this `gen_server`, and
%% with it every later event on this subscription.
%%
%% Rescheduling means a retried event can be delivered after events published
%% after it. Forwarding to an external sink is best-effort and unordered
%% already, so a late retry beats a blocked subscriber.
schedule_retry(Event, Reason, Retry0, State) ->
    case bondy_retry:fail(Retry0) of
        {Delay, Retry} when is_integer(Delay) ->
            Msg = {?MODULE, retry, Event, Retry},
            _ = erlang:send_after(Delay, self(), Msg),
            {ok, State};
        {Limit, _Retry} ->
            {error, {retry_limit_reached, Limit, Reason}, State}
    end.

%% @private
%% Preserves the original budget -- three attempts from 50ms, doubling -- and
%% adds jitter, so a fleet of subscribers failing against the same sink does not
%% retry in lockstep.
new_retry() ->
    bondy_retry:init(?MODULE, #{
        max_retries => 3,
        interval => 50,
        %% Bounded by attempts, not by wall clock.
        deadline => 0,
        backoff_enabled => true,
        backoff_min => 50,
        backoff_max => 400,
        backoff_type => jitter
    }).

%% @private
log_event_error(Reason, State) ->
    ?LOG_ERROR(#{
        description => "Error while handling event",
        reason => Reason,
        realm_uri => State#state.realm_uri,
        topic => State#state.topic,
        subscription_id => State#state.subscription_id,
        pid => self()
    }).
