%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% juno_router provides the routing logic for all interactions.
%%
%% In general juno_router tries to handle all messages asynchronously. 
%% It does it by
%% using either a static or a dynamic pool of workers based on configuration.
%% This module implements both type of workers as a gen_server (this module).
%% A static pool uses a set of supervised processes whereas a 
%% dynamic pool spawns a new erlang process for each message. In both cases,
%% sidejob supervises the processes.
%% By default juno_router uses a dynamic pool.
%%
%% The pools are implemented using the sidejob library in order to provide 
%% load regulation. Inn case a maximum pool capacity has been reached, 
%% the router will handle the message synchronously i.e. blocking the
%% calling processes (usually the one that handles the transport connection
%% e.g. {@link juno_ws_handler}).
%%
%% The router also handles messages synchronously in those 
%% cases where it needs to preserve message ordering guarantees.
%%
%% This module handles only the concurrency and basic routing logic, 
%% delegating the rest to either {@link juno_broker} or {@link juno_dealer},
%% which implement the actual PubSub and RPC logic respectively.
%%
%%<pre>
%% ,------.                                    ,------.
%% | Peer |                                    | Peer |
%% `--+---'                                    `--+---'
%%    |                                           |
%%    |               TCP established             |
%%    |<----------------------------------------->|
%%    |                                           |
%%    |               TLS established             |
%%    |+<--------------------------------------->+|
%%    |+                                         +|
%%    |+           WebSocket established         +|
%%    |+|<------------------------------------->|+|
%%    |+|                                       |+|
%%    |+|            WAMP established           |+|
%%    |+|+<----------------------------------->+|+|
%%    |+|+                                     +|+|
%%    |+|+                                     +|+|
%%    |+|+            WAMP closed              +|+|
%%    |+|+<----------------------------------->+|+|
%%    |+|                                       |+|
%%    |+|                                       |+|
%%    |+|            WAMP established           |+|
%%    |+|+<----------------------------------->+|+|
%%    |+|+                                     +|+|
%%    |+|+                                     +|+|
%%    |+|+            WAMP closed              +|+|
%%    |+|+<----------------------------------->+|+|
%%    |+|                                       |+|
%%    |+|           WebSocket closed            |+|
%%    |+|<------------------------------------->|+|
%%    |+                                         +|
%%    |+              TLS closed                 +|
%%    |+<--------------------------------------->+|
%%    |                                           |
%%    |               TCP closed                  |
%%    |<----------------------------------------->|
%%    |                                           |
%% ,--+---.                                    ,--+---.
%% | Peer |                                    | Peer |
%% `------'                                    `------'
%%</pre>
%% (Diagram copied from WAMP RFC Draft)
%%
%% @end
%% =============================================================================
-module(juno_router).
-behaviour(gen_server).
-include("juno.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(POOL_NAME, juno_router_pool).
-define(ROUTER_ROLES, #{
    <<"broker">> => ?BROKER_FEATURES,
    <<"dealer">> => ?DEALER_FEATURES
}).

-type event()                   ::  {wamp_message(), juno_context:context()}.

                                
-record(state, {
    pool_type = permanent       ::  permanent | transient,
    event                       ::  event()
}).

%% API
-export([close_context/1]).
-export([forward/2]).
-export([roles/0]).
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
-spec close_context(juno_context:context()) -> juno_context:context().
close_context(Ctxt) -> 
    juno_dealer:close_context(juno_broker:close_context(Ctxt)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec roles() -> #{binary() => #{binary() => boolean()}}.
roles() ->
    ?ROUTER_ROLES.


%% -----------------------------------------------------------------------------
%% @doc
%% Starts a sidejob pool of workers according to the configured pool_type 
%% {@link juno_config:pool_type/1} for the pool named 'juno_router_pool'.
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
%% Handles a wamp message.
%% The message might be handled synchronously (performed by the calling
%% process i.e. the transport handler) or asynchronously (by sending the
%% message to the router load regulated worker pool).
%%
%% Most 
%% @end
%% -----------------------------------------------------------------------------
-spec forward(M :: wamp_message(), Ctxt :: juno_context:context()) ->
    {ok, juno_context:context()}
    | {reply, Reply :: wamp_message(), juno_context:context()}
    | {stop, Reply :: wamp_message(), juno_context:context()}.


forward(M, #{session := _} = Ctxt) ->
    %% Client has a session so this should be either a message
    %% for broker or dealer roles
    ok = juno_stats:update(M, Ctxt),
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


handle_call(Event, _From, State) ->
    error_logger:error_report([
        {reason, unsupported_event},
        {event, Event}
    ]),
    {noreply, State}.


handle_cast(Event, State) ->
    try
        ok = route_event(Event),
        {noreply, State}
    catch
        throw:abort ->
            %% TODO publish metaevent
            {noreply, State};
        _:Reason ->
            %% TODO publish metaevent
            error_logger:error_report([
                {reason, Reason},
                {stacktrace, erlang:get_stacktrace()}
            ]),
            {noreply, State}
    end.


handle_info(timeout, #state{pool_type = transient, event = Event} = State)
when Event /= undefined ->
    %% We've been spawned to handle this single event, 
    %% so we should stop right after we do it
    ok = route_event(Event),
    {stop, normal, State};

handle_info(_Info, State) ->
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
    Size = juno_config:pool_size(?POOL_NAME),
    Capacity = juno_config:pool_capacity(?POOL_NAME),
    case juno_config:pool_type(?POOL_NAME) of
        permanent ->
            sidejob:new_resource(?POOL_NAME, ?MODULE, Capacity, Size);
        transient ->
            sidejob:new_resource(?POOL_NAME, sidejob_supervisor, Capacity, Size)
    end.



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec acknowledge_message(map()) -> boolean().
acknowledge_message(#publish{options = Opts}) ->
    maps:get(<<"acknowledge">>, Opts, false);

acknowledge_message(_) ->
    false.



%% =============================================================================
%% PRIVATE : GEN_SERVER
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Asynchronously handles a message by either sending it to an 
%% existing worker or spawning a new one depending on the juno_broker_pool_type 
%% type.
%% @end.
%% -----------------------------------------------------------------------------
-spec async_route_event(wamp_message(), juno_context:context()) -> 
    ok | {error, overload}.
async_route_event(M, Ctxt) ->
    PoolName = ?POOL_NAME,
    %% Todo either fix pool_type based on stats or use mochiweb to compile 
    %% juno_config to avoid bottlenecks.
    PoolType = juno_config:pool_type(PoolName),
    case async_route_event(PoolType, PoolName, M, Ctxt) of
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
%% Helper function for {@link async_route_event/2}
%% @end
%% -----------------------------------------------------------------------------
async_route_event(permanent, PoolName, M, Ctxt) ->
    %% We send a request to an existing permanent worker
    %% using juno_router acting as a sidejob_worker
    sidejob:cast(PoolName, {M, Ctxt});

async_route_event(transient, PoolName, M, Ctxt) ->
    %% We spawn a transient worker using sidejob_supervisor
    sidejob_supervisor:start_child(
        PoolName,
        gen_server,
        start_link,
        [?MODULE, [{M, Ctxt}], []]
    ).



%% @private
do_forward(#goodbye{}, #{goodbye_initiated := true} = Ctxt) ->
    %% The client is replying to our goodbye() message, we stop.
    {stop, Ctxt};

do_forward(#goodbye{} = M, Ctxt) ->
    %% Goodbye initiated by client, we reply with goodbye() and stop.
    error_logger:info_report(
        "Session ~p closed as per client request. Reason: ~p~n",
        [juno_context:session_id(Ctxt), M#goodbye.reason_uri]
    ),
    Reply = wamp_message:goodbye(#{}, ?WAMP_ERROR_GOODBYE_AND_OUT),
    {stop, Reply, Ctxt};

do_forward(#register{} = M, Ctxt) ->
    %% This is a sync call as it is an easy way to preserve RPC ordering as 
    %% defined by RFC 11.2: 
    %% Further, if _Callee A_ registers for *Procedure 1*, the "REGISTERED"
    %% message will be sent by _Dealer_ to _Callee A_ before any 
    %% "INVOCATION" message for *Procedure 1*.
    %% Because we block the callee until we get the response, 
    %% the calle will not receive any other messages.
    %% However, notice that if the callee has another connection with the 
    %% router, then it might receive an invocation through that connection 
    %% before we reply here. 
    %% At the moment this relies on Erlang's guaranteed causal delivery of 
    %% messages between two processes even when in different nodes.

    #register{procedure_uri = Uri, options = Opts, request_id = ReqId} = M,

    Reply = case juno_dealer:register(Uri, Opts, Ctxt) of
        {ok, RegId} ->
            wamp_message:registered(ReqId, RegId);
        {error, not_authorized} ->
            wamp_message:error(
                ?REGISTER, ReqId, #{}, ?WAMP_ERROR_NOT_AUTHORIZED);
        {error, procedure_already_exists} ->
            wamp_message:error(
                ?REGISTER,ReqId, #{}, ?WAMP_ERROR_PROCEDURE_ALREADY_EXISTS)
    end,
    {reply, Reply, Ctxt};

do_forward(#call{request_id = ReqId} = M, Ctxt0) ->
    %% This is a sync call as it is an easy way to guarantees ordering of 
    %% invocations between any given pair of Caller and Callee as 
    %% defined by RFC 11.2, as Erlang guarantees causal delivery of messages
    %% between two processes even when in different nodes (when using 
    %% distributed Erlang).
    ok = route_event({M, Ctxt0}),
    %% The Call response will be delivered asynchronously by the dealer
    {ok, juno_context:add_awaiting_call_id(Ctxt0, ReqId)};

do_forward(M, Ctxt0) ->
    %% Client already has a session.
    %% RFC: By default, publications are unacknowledged, and the _Broker_ will
    %% not respond, whether the publication was successful indeed or not.
    %% This behavior can be changed with the option
    %% "PUBLISH.Options.acknowledge|bool"
    Acknowledge = acknowledge_message(M),
    %% We asynchronously handle the message by sending it to the router pool
    try async_route_event(M, Ctxt0) of
        ok ->
            {ok, Ctxt0};
        {error, overload} ->
            lager:info("Pool ~p is overloaded.", [?POOL_NAME]),
            %% TODO publish metaevent and stats
            %% TODO use throttling and send error to caller conditionally
            %% We do it synchronously i.e. blocking the caller
            ok = route_event({M, Ctxt0}),
            {ok, Ctxt0}
    catch
        error:Reason when Acknowledge == true ->
            %% TODO Maybe publish metaevent
            %% REVIEW are we using the right error uri?
            Reply = wamp_message:error(
                ?UNSUBSCRIBE,
                M#unsubscribe.request_id,
                juno_error:error_map(Reason),
                ?WAMP_ERROR_CANCELLED
            ),
            ok = juno_stats:update(Reply, Ctxt0),
            {reply, Reply, Ctxt0};
        _:_ ->
            %% TODO Maybe publish metaevent and stats
            {ok, Ctxt0}
    end.

%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Synchronously handles a message in the calling process.
%% @end.
%% -----------------------------------------------------------------------------
-spec route_event(event()) -> ok.
route_event({#subscribe{} = M, Ctxt}) ->
    juno_broker:handle_message(M, Ctxt);

route_event({#unsubscribe{} = M, Ctxt}) ->
    juno_broker:handle_message(M, Ctxt);

route_event({#publish{} = M, Ctxt}) ->
    juno_broker:handle_message(M, Ctxt);

route_event({#register{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

route_event({#unregister{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

route_event({#call{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);
  
route_event({#cancel{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

route_event({#yield{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

route_event({#error{request_type = ?INVOCATION} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

route_event({M, _Ctxt}) ->
    error({unexpected_message, M}).
