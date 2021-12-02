%% =============================================================================
%%  bondy_router.erl -
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
%% e.g. {@link bondy_wamp_ws_connection_handler}).
%%
%% The router also handles messages synchronously in those
%% cases where it needs to preserve message ordering guarantees.
%%
%% This module handles only the concurrency and basic routing logic,
%% delegating the rest to either {@link bondy_broker} or {@link bondy_dealer},
%% which implement the actual PubSub and RPC logic respectively.
%%
%% ```
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
%%
%% '''
%% (Diagram copied from WAMP RFC Draft)
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_router).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(ROUTER_ROLES, #{
    broker => #{features => ?BROKER_FEATURES},
    dealer => #{features => ?DEALER_FEATURES}
}).


-type event()       ::  {wamp_message(), bondy_context:t()}.


%% API
-export([close_context/1]).
-export([forward/2]).
-export([handle_peer_message/1]).
-export([roles/0]).
-export([agent/0]).
-export([shutdown/0]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Sends a GOODBYE message to all existing client connections.
%% The client should reply with another GOODBYE within the configured time and
%% when it does or on timeout, Bondy will close the connection triggering the
%% cleanup of all the client sessions.
%% @end
%% -----------------------------------------------------------------------------
shutdown() ->
    M = wamp_message:goodbye(
        #{message => <<"Router is shutting down">>},
        ?WAMP_SYSTEM_SHUTDOWN
    ),
    Fun = fun(PeerId) -> catch bondy:send(PeerId, M) end,

    try
        _ = bondy_utils:foreach(Fun, bondy_session:list_peer_ids(100))
    catch
       Class:Reason ->
            ?LOG_ERROR(#{
                description => "Error while shutting down router",
                class => Class,
                reason => Reason
            })
    end,

    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec close_context(bondy_context:t()) -> bondy_context:t().

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
%% Forwards a WAMP message to the Dealer or Broker based on message type.
%% The message might end up being handled synchronously
%% (performed by the calling process i.e. the transport handler)
%% or asynchronously (by sending the message to the router load regulated
%% worker pool).
%%
%% @end
%% -----------------------------------------------------------------------------
-spec forward(M :: wamp_message(), Ctxt :: bondy_context:t()) ->
    {ok, bondy_context:t()}
    | {reply, Reply :: wamp_message(), bondy_context:t()}
    | {stop, Reply :: wamp_message(), bondy_context:t()}.


forward(M, #{session := _} = Ctxt0) ->
    Ctxt1 = bondy_context:set_request_timestamp(Ctxt0, erlang:monotonic_time()),

    %% ?LOG_DEBUG(#{
    %%     description => "Forwarding message",
    %%     peer_id => bondy_context:peer_id(Ctxt0),
    %%     message => M
    %% }),

    %% Client has a session so this should be either a message
    %% for broker or dealer roles
    do_forward(M, Ctxt1).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_peer_message(bondy_peer_message:t()) -> ok | no_return().

handle_peer_message(PM) ->
    bondy_peer_message:is_message(PM) orelse exit(badarg),

    Payload = bondy_peer_message:payload(PM),
    PeerId = bondy_peer_message:to(PM),
    From = bondy_peer_message:from(PM),
    Opts = bondy_peer_message:options(PM),

    handle_peer_message(Payload, PeerId, From, Opts).


-spec handle_peer_message(wamp_message(), peer_id(), remote_peer_id(), map()) ->
    ok | no_return().

handle_peer_message(#publish{} = M, PeerId, From, Opts) ->
    bondy_broker:handle_peer_message(M, PeerId, From, Opts);

handle_peer_message(#error{} = M, PeerId, From, Opts) ->
    %% This is a CALL, INVOCATION or INTERRUPT error
    %% see bondy_peer_message for more details
    bondy_dealer:handle_peer_message(M, PeerId, From, Opts);

handle_peer_message(#interrupt{} = M, PeerId, From, Opts) ->
    bondy_dealer:handle_peer_message(M, PeerId, From, Opts);

handle_peer_message(#call{} = M, PeerId, From, Opts) ->
    bondy_dealer:handle_peer_message(M, PeerId, From, Opts);

handle_peer_message(#invocation{} = M, PeerId, From, Opts) ->
    bondy_dealer:handle_peer_message(M, PeerId, From, Opts);

handle_peer_message(#yield{} = M, PeerId, From, Opts) ->
    bondy_dealer:handle_peer_message(M, PeerId, From, Opts).




%% =============================================================================
%% PRIVATE
%% =============================================================================



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
do_forward(#subscribe{} = M, Ctxt) ->
    %% This is a sync call as clients can call subscribe multiple times
    %% concurrently. This is becuase matching and adding to the registry is not
    %% done atomically: bondy_registry:add uses art_server:match/2 to
    %% determine if a subscription already exists and then adds to the registry
    %% (and trie). If we allow this request to be concurrent 2 or more request
    %% could get no matches from match and thus create 3 subscriptions when
    %% according to the protocol the subscriber should always get the same
    %% subscription as result.
    %% REVIEW An alternative approach would be for this to be handled async and
    %% a pool of register servers to block.
    ok = sync_forward({M, Ctxt}),
    {ok, Ctxt};

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
    ok = sync_forward({M, Ctxt}),
    {ok, Ctxt};

do_forward(#call{procedure_uri = <<"wamp.", _/binary>>} = M, Ctxt) ->
    async_forward(M, Ctxt);

do_forward(
    #call{procedure_uri = <<"bondy.", _/binary>>} = M, Ctxt) ->
    async_forward(M, Ctxt);

do_forward(#call{} = M, Ctxt0) ->
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
    %% The invocation is always async and the result or error will be delivered
    %% asynchronously by the dealer.
    {ok, Ctxt0};

do_forward(M, Ctxt) ->
    async_forward(M, Ctxt).


%% @private
async_forward(M, Ctxt0) ->
    %% Client already has a session.
    %% RFC: By default, publications are unacknowledged, and the _Broker_ will
    %% not respond, whether the publication was successful indeed or not.
    %% This behavior can be changed with the option
    %% "PUBLISH.Options.acknowledge|bool"
    Acknowledge = acknowledge_message(M),
    %% Asynchronously forwards a message by either sending it to an
    %% existing worker or spawning a new one depending on
    %% bondy_broker_pool_type.
    Event = {M, Ctxt0},
    try bondy_router_worker:cast(fun() -> sync_forward(Event) end) of
        ok ->
            {ok, Ctxt0};
        {error, overload} ->
            ?LOG_WARNING(#{
                description => "Router pool overloaded, will route message synchronously"
            }),
            %% @TODO publish metaevent and stats
            %% @TODO use throttling and send error to caller conditionally
            %% We do it synchronously i.e. blocking the caller
            ok = sync_forward(Event),
            {ok, Ctxt0}
    catch
        error:Reason when Acknowledge == true ->
            %% TODO Maybe publish metaevent
            %% REVIEW are we using the right error uri?
            ErrorMap = bondy_error:map(Reason),
            Reply = wamp_message:error_from(
                M,
                #{},
                ?WAMP_CANCELLED,
                [maps:get(<<"message">>, ErrorMap)],
                #{error => ErrorMap}
            ),
            {reply, Reply, Ctxt0};
        Class:Reason:Stacktrace ->
            Ctxt = bondy_context:realm_uri(Ctxt0),
            SessionId = bondy_context:session_id(Ctxt0),
            ?LOG_ERROR(#{
                description => "Error while routing message",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace,
                session_id => SessionId,
                context => Ctxt,
                message => M
            }),
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

