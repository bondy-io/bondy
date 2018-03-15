%% =============================================================================
%%  bondy_router.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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
%% @doc bondy_router provides the routing logic for all interactions.
%%
%% In general bondy_router tries to handle all messages asynchronously.
%% It does it by
%% using either a static or a dynamic pool of workers based on configuration.
%% This module implements both type of workers as a gen_server (this module).
%% A static pool uses a set of supervised processes whereas a
%% dynamic pool spawns a new erlang process for each message. In both cases,
%% sidejob supervises the processes.
%% By default bondy_router uses a dynamic pool.
%%
%% The pools are implemented using the sidejob library in order to provide
%% load regulation. Inn case a maximum pool capacity has been reached,
%% the router will handle the message synchronously i.e. blocking the
%% calling processes (usually the one that handles the transport connection
%% e.g. {@link bondy_ws_handler}).
%%
%% The router also handles messages synchronously in those
%% cases where it needs to preserve message ordering guarantees.
%%
%% This module handles only the concurrency and basic routing logic,
%% delegating the rest to either {@link bondy_broker} or {@link bondy_dealer},
%% which implement the actual PubSub and RPC logic respectively.
%%
%% <pre>
%% ,------.                                    ,------.
%% | Peer |                                    | Peer |
%% `--+---'                                    `--+---'
%%    |                                           |
%%    |               TCP established             |
%%    |&lt;-----------------------------------------&gt;|
%%    |                                           |
%%    |               TLS established             |
%%    |+&lt;---------------------------------------&gt;+|
%%    |+                                         +|
%%    |+           WebSocket established         +|
%%    |+|&lt;-------------------------------------&gt;|+|
%%    |+|                                       |+|
%%    |+|            WAMP established           |+|
%%    |+|+&lt;-----------------------------------&gt;+|+|
%%    |+|+                                     +|+|
%%    |+|+                                     +|+|
%%    |+|+            WAMP closed              +|+|
%%    |+|+&lt;-----------------------------------&gt;+|+|
%%    |+|                                       |+|
%%    |+|                                       |+|
%%    |+|            WAMP established           |+|
%%    |+|+&lt;-----------------------------------&gt;+|+|
%%    |+|+                                     +|+|
%%    |+|+                                     +|+|
%%    |+|+            WAMP closed              +|+|
%%    |+|+&lt;-----------------------------------&gt;+|+|
%%    |+|                                       |+|
%%    |+|           WebSocket closed            |+|
%%    |+|&lt;-------------------------------------&gt;|+|
%%    |+                                         +|
%%    |+              TLS closed                 +|
%%    |+&lt;---------------------------------------&gt;+|
%%    |                                           |
%%    |               TCP closed                  |
%%    |&lt;-----------------------------------------&gt;|
%%    |                                           |
%% ,--+---.                                    ,--+---.
%% | Peer |                                    | Peer |
%% `------'                                    `------'
%%
%% </pre>
%% (Diagram copied from WAMP RFC Draft)
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_router).
-behaviour(gen_server).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(POOL_NAME, router_pool).
-define(ROUTER_ROLES, #{
    broker => ?BROKER_FEATURES,
    dealer => ?DEALER_FEATURES
}).

-type event()                   ::  {wamp_message(), bondy_context:context()}.


-record(state, {
    pool_type                   ::  permanent | transient,
    event                       ::  event()
}).

%% API
-export([close_context/1]).
-export([forward/2]).
-export([roles/0]).
-export([agent/0]).
-export([start_pool/0]).
%% -export([has_role/2]). ur, ctxt
%% -export([add_role/2]). uri, ctxt
%% -export([remove_role/2]). uri, ctxt
%% -export([authorise/4]). session, uri, action, ctxt
%% -export([start_realm/2]). uri, ctxt
%% -export([stop_realm/2]). uri, ctxt

%% -export([callees/2]).
%% -export([count_callees/2]).
%% -export([count_registrations/2]).
%% -export([lookup_registration/2]).
%% -export([fetch_registration/2]). % wamp.registration.get


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
-spec close_context(bondy_context:context()) -> bondy_context:context().
close_context(Ctxt) ->
    bondy_dealer:close_context(bondy_broker:close_context(Ctxt)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec roles() -> #{binary() => #{binary() => boolean()}}.
roles() ->
    ?ROUTER_ROLES.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the Bondy agent identification string
%% @end
%% -----------------------------------------------------------------------------
agent() ->
    Vsn = list_to_binary(bondy_app:vsn()),
    <<"LEAPSIGHT-BONDY-", Vsn/binary>>.


%% -----------------------------------------------------------------------------
%% @doc
%% Starts a sidejob pool of workers according to the configuration
%% for the entry named 'router_pool'.
%% @end
%% -----------------------------------------------------------------------------
-spec start_pool() -> ok.
start_pool() ->
    case do_start_pool() of
        {ok, _Child} -> ok;
        {ok, _Child, _Info} -> ok;
        {error, already_present} -> ok;
        {error, {already_started, _Child}} -> ok;
        {error, Reason} -> error(Reason)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Forwards a WAMP message to the Dealer or Broker based on message type.
%% The message might end up being handled synchronously
%% (performed by the calling process i.e. the transport handler)
%% or asynchronously (by sending the message to the router load regulated
%% worker pool).
%%
%% @end
%% -----------------------------------------------------------------------------
-spec forward(M :: wamp_message(), Ctxt :: bondy_context:context()) ->
    {ok, bondy_context:context()}
    | {reply, Reply :: wamp_message(), bondy_context:context()}
    | {stop, Reply :: wamp_message(), bondy_context:context()}.


forward(M, #{session := _} = Ctxt) ->
    %% Client has a session so this should be either a message
    %% for broker or dealer roles
    ok = bondy_stats:update(M, Ctxt),
    do_forward(M, Ctxt).




%% =============================================================================
%% API : GEN_SERVER CALLBACKS FOR SIDEJOB WORKER
%% =============================================================================



init([?POOL_NAME]) ->
    %% We've been called by sidejob_worker
    %% We will be called via a a cast (handle_cast/2)
    %% TODO publish metaevent and stats
    {ok, #state{pool_type = permanent}};

init([Event]) ->
    %% We've been called by sidejob_supervisor
    %% We immediately timeout so that we find ourselfs in handle_info/2.
    %% TODO publish metaevent and stats
    State = #state{
        pool_type = transient,
        event = Event
    },
    {ok, State, 0}.


handle_call(Event, From, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p, from=~p", [Event, From]),
    {noreply, State}.


handle_cast(Event, State) ->
    try
        ok = sync_forward(Event),
        {noreply, State}
    catch
        Error:Reason ->
            %% TODO publish metaevent
            _ = lager:error(
                "Error handling cast, error=~p, reason=~p, stacktrace=~p",
                [Error, Reason, erlang:get_stacktrace()]),
            {noreply, State}
    end.


handle_info(timeout, #state{pool_type = transient, event = Event} = State)
when Event /= undefined ->
    %% We are a worker that has been spawned to handle this single event,
    %% so we should stop right after we do it
    ok = sync_forward(Event),
    {stop, normal, State};

handle_info(Info, State) ->
    _ = lager:debug("Unexpected message, message=~p", [Info]),
    {noreply, State}.


terminate(normal, _State) ->
    ok;
terminate(shutdown, _State) ->
    ok;
terminate({shutdown, _}, _State) ->
    ok;
terminate(_Reason, _State) ->
    %% TODO publish metaevent
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Actually starts a sidejob pool based on system configuration.
%% @end
%% -----------------------------------------------------------------------------
do_start_pool() ->
    Opts = bondy_config:router_pool(),
    {_, Size} = lists:keyfind(size, 1, Opts),
    {_, Capacity} = lists:keyfind(capacity, 1, Opts),
    case lists:keyfind(type, 1, Opts) of
        {_, permanent} ->
            sidejob:new_resource(?POOL_NAME, ?MODULE, Capacity, Size);
        {_, transient} ->
            sidejob:new_resource(?POOL_NAME, sidejob_supervisor, Capacity, Size)
    end.



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec acknowledge_message(map()) -> boolean().
acknowledge_message(#publish{options = Opts}) ->
    maps:get(acknowledge, Opts, false);

acknowledge_message(_) ->
    false.



%% =============================================================================
%% PRIVATE : GEN_SERVER
%% =============================================================================


%% @private
do_forward(#goodbye{}, #{goodbye_initiated := true} = Ctxt) ->
    %% The client is replying to our goodbye() message, we stop.
    {stop, Ctxt};

do_forward(#goodbye{} = M, Ctxt) ->
    %% Goodbye initiated by client, we reply with goodbye() and stop.
    _ = lager:error(
        "Session closed per client request, session=~p, reason=~p",
        [bondy_context:session_id(Ctxt), M#goodbye.reason_uri]),
    Reply = wamp_message:goodbye(#{}, ?WAMP_ERROR_GOODBYE_AND_OUT),
    {stop, Reply, Ctxt};

do_forward(#register{} = M, Ctxt) ->
    %% This is a sync call as it is an easy way to preserve RPC ordering as
    %% defined by RFC 11.2:
    %% Further, if _Callee A_ registers for *Procedure 1*, the "REGISTERED"
    %% message will be sent by _Dealer_ to _Callee A_ before any
    %% "INVOCATION" message for *Procedure 1*.
    %% Because we block the callee until we get the response,
    %% the callee will not receive any other messages.
    %% However, notice that if the callee has another connection with the
    %% router, then it might receive an invocation through that connection
    %% before we reply here.
    %% At the moment this relies on Erlang's guaranteed causal delivery of
    %% messages between two processes even when in different nodes.

    #register{procedure_uri = Uri, options = Opts, request_id = ReqId} = M,

    Reply = case bondy_dealer:register(Uri, Opts, Ctxt) of
        {ok, Map} ->
            wamp_message:registered(ReqId, maps:get(id, Map));
        {error, {not_authorized, Mssg}} ->
            wamp_message:error(
                ?REGISTER, ReqId,
                #{},
                ?WAMP_ERROR_NOT_AUTHORIZED,
                [Mssg]
            );
        {error, {procedure_already_exists, Mssg}} ->
            wamp_message:error(
                ?REGISTER,
                ReqId,
                #{},
                ?WAMP_ERROR_PROCEDURE_ALREADY_EXISTS,
                [Mssg]
            )
    end,
    {reply, Reply, Ctxt};

do_forward(#call{request_id = ReqId} = M, Ctxt0) ->
    %% This is a sync call as it is an easy way to guarantee ordering of
    %% invocations between any given pair of Caller and Callee as
    %% defined by RFC 11.2, as Erlang guarantees causal delivery of messages
    %% between two processes even when in different nodes (when using
    %% distributed Erlang).
    %% RFC:
    %% If Callee A has registered endpoints for both Procedure 1 and Procedure
    %% 2, and Caller B first issues a Call 1 to Procedure 1 and then a Call 2
    %% to Procedure 2, and both calls are routed to Callee A, then Callee A
    %% will first receive an invocation corresponding to Call 1 and then Call
    %% 2. This also holds if Procedure 1 and Procedure 2 are identical.
    ok = sync_forward({M, Ctxt0}),
    %% The invocation is always async,
    %% so the response will be delivered asynchronously by the dealer
    {ok, bondy_context:add_awaiting_call(Ctxt0, ReqId)};

%% do_forward(#publish{} = M, Ctxt0) ->
%%     %% RFC:
%%     %% If Subscriber A is subscribed to both Topic 1 and Topic 2, and Publisher
%%     %% B first publishes an Event 1 to Topic 1 and then an Event 2 to Topic 2,
%%     %% then Subscriber A will first receive Event 1 and then Event 2. This also
%%     %% holds if Topic 1 and Topic 2 are identical.
%%     %% In other words, WAMP guarantees ordering of events between any given
%%     %% pair of Publisher and Subscriber.
%%     ok = sync_forward({M, Ctxt0}),
%%     {ok, Ctxt0};

do_forward(M, Ctxt0) ->
    %% Client already has a session.
    %% RFC: By default, publications are unacknowledged, and the _Broker_ will
    %% not respond, whether the publication was successful indeed or not.
    %% This behavior can be changed with the option
    %% "PUBLISH.Options.acknowledge|bool"
    Acknowledge = acknowledge_message(M),
    %% We asynchronously handle the message by sending it to the router pool
    try async_forward(M, Ctxt0) of
        ok ->
            {ok, Ctxt0};
        {error, overload} ->
            _ = lager:info("Pool ~p is overloaded.", [?POOL_NAME]),
            %% TODO publish metaevent and stats
            %% TODO use throttling and send error to caller conditionally
            %% We do it synchronously i.e. blocking the caller
            ok = sync_forward({M, Ctxt0}),
            {ok, Ctxt0}
    catch
        error:Reason when Acknowledge == true ->
            %% TODO Maybe publish metaevent
            %% REVIEW are we using the right error uri?
            ErrorMap = bondy_error:map(Reason),
            Reply = wamp_message:error(
                ?UNSUBSCRIBE,
                M#unsubscribe.request_id,
                #{},
                ?WAMP_ERROR_CANCELLED,
                [maps:get(<<"message">>, ErrorMap)],
                #{error => ErrorMap}
            ),
            ok = bondy_stats:update(Reply, Ctxt0),
            {reply, Reply, Ctxt0};
        _:_ ->
            %% TODO Maybe publish metaevent and stats
            {ok, Ctxt0}
    end.

%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Synchronously forwards a message in the calling process.
%% @end.
%% -----------------------------------------------------------------------------
-spec sync_forward(event()) -> ok.

sync_forward({#subscribe{} = M, Ctxt}) ->
    bondy_broker:handle_message(M, Ctxt);

sync_forward({#unsubscribe{} = M, Ctxt}) ->
    bondy_broker:handle_message(M, Ctxt);

sync_forward({#publish{} = M, Ctxt}) ->
    bondy_broker:handle_message(M, Ctxt);

sync_forward({#register{} = M, Ctxt}) ->
    bondy_dealer:handle_message(M, Ctxt);

sync_forward({#unregister{} = M, Ctxt}) ->
    bondy_dealer:handle_message(M, Ctxt);

sync_forward({#call{} = M, Ctxt}) ->
    bondy_dealer:handle_message(M, Ctxt);

sync_forward({#cancel{} = M, Ctxt}) ->
    bondy_dealer:handle_message(M, Ctxt);

sync_forward({#yield{} = M, Ctxt}) ->
    bondy_dealer:handle_message(M, Ctxt);

sync_forward({#error{request_type = Type} = M, Ctxt})
when Type == ?INVOCATION orelse Type == ?INTERRUPT ->
    bondy_dealer:handle_message(M, Ctxt);

sync_forward({M, _Ctxt}) ->
    error({unexpected_message, M}).




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Asynchronously forwards a message by either sending it to an
%% existing worker or spawning a new one depending on the bondy_broker_pool_type
%% type.
%% @end.
%% -----------------------------------------------------------------------------
-spec async_forward(wamp_message(), bondy_context:context()) ->
    ok | {error, overload}.

async_forward(M, Ctxt) ->
    %% Todo either fix pool_type based on stats or use mochiweb to compile
    %% bondy_config to avoid bottlenecks.
    {_, PoolType} = lists:keyfind(type, 1, bondy_config:router_pool()),
    case async_forward(PoolType, router_pool, M, Ctxt) of
        ok ->
            ok;
        {ok, _} ->
            ok;
        overload ->
            {error, overload}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Helper function for {@link async_forward/2}
%% @end
%% -----------------------------------------------------------------------------
async_forward(permanent, PoolName, M, Ctxt) ->
    %% We send a request to an existing permanent worker
    %% using bondy_router acting as a sidejob_worker
    sidejob:cast(PoolName, {M, Ctxt});

async_forward(transient, PoolName, M, Ctxt) ->
    %% We spawn a transient worker using sidejob_supervisor
    sidejob_supervisor:start_child(
        PoolName,
        gen_server,
        start_link,
        [?MODULE, [{M, Ctxt}], []]
    ).