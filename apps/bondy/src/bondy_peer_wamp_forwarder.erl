%% =============================================================================
%%  bondy_peer_wamp_forwarder.erl - forwards INVOCATION (their RESULT or
%%  ERROR), INTERRUPT and EVENT messages between WAMP clients connected to
%%  different Bondy peers (nodes).
%%
%%  Copyright (c) 2016-2018 Ngineo Limited t/a Leapsight. All rights reserved.
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
%% @doc A gen_server that forwards INVOCATION (their RESULT or ERROR), INTERRUPT
%% and EVENT messages between WAMP clients connected to different Bondy peers
%% (nodes).
%%
%% <pre><code>
%% +-------------------------+                    +-------------------------+
%% |         node_1          |                    |         node_2          |
%% |                         |                    |                         |
%% |                         |                    |                         |
%% | +---------------------+ |    cast_message    | +---------------------+ |
%% | |partisan_peer_service| |                    | |partisan_peer_service| |
%% | |      _manager       |<+--------------------+>|      _manager       | |
%% | |                     | |                    | |                     | |
%% | +---------------------+ |                    | +---------------------+ |
%% |    ^          |         |                    |         |          ^    |
%% |    |          v         |                    |         v          |    |
%% |    |  +---------------+ |                    | +---------------+  |    |
%% |    |  |bondy_peer_wamp| |                    | |bondy_peer_wamp|  |    |
%% |    |  |  _forwarder   | |                    | |  _forwarder   |  |    |
%% |    |  |               | |                    | |               |  |    |
%% |    |  +---------------+ |                    | +---------------+  |    |
%% |    |          |         |                    |         |          |    |
%% |    |          |         |                    |         |          |    |
%% |    |          |         |                    |         |          |    |
%% |    |          v         |                    |         v          |    |
%% | +---------------------+ |                    | +---------------------+ |
%% | |       Worker        | |                    | |       Worker        | |
%% | |    (router_pool)    | |                    | |    (router_pool)    | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | +---------------------+ |                    | +---------------------+ |
%% |         ^    |          |                    |          |   ^          |
%% |         |    |          |                    |          |   |          |
%% |         |    v          |                    |          v   |          |
%% | +---------------------+ |                    | +---------------------+ |
%% | |bondy_wamp_*_handler | |                    | |bondy_wamp_*_handler | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | +---------------------+ |                    | +---------------------+ |
%% |         ^    |          |                    |          |   ^          |
%% |         |    |          |                    |          |   |          |
%% +---------+----+----------+                    +----------+---+----------+
%%           |    |                                          |   |
%%           |    |                                          |   |
%%      CALL |    | RESULT | ERROR                INVOCATION |   | YIELD
%%           |    |                                          |   |
%%           |    v                                          v   |
%% +-------------------------+                    +-------------------------+
%% |         Caller          |                    |         Callee          |
%% |                         |                    |                         |
%% |                         |                    |                         |
%% +-------------------------+                    +-------------------------+
%% </code></pre>
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_peer_wamp_forwarder).
-behaviour(gen_server).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-record(peer_message, {
    id          ::  id(),
    peer_id     ::  remote_peer_id(),
    message     ::  wamp_invocation()
                    | wamp_error()
                    | wamp_result()
                    | wamp_interrupt()
                    | wamp_event(),
    options     ::  map()
}).

-record(peer_ack, {
    node        ::  atom(),
    session_id  ::  id(),
    id          ::  id()
}).

-record(peer_error, {
    node        ::  atom(),
    session_id  ::  id(),
    id          ::  id(),
    reason      ::  any()
}).

-record(state, {
}).

%% API
-export([forward/3]).

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
%% @doc Forwards a wamp message to a peer (node).
%% This only works for EVENT, ERROR, INTERRUPT, INVOCATION and RESULT wamp
%% message types. It will fail with an exception if another type is passed
%% as the second argument.
%% @end
%% -----------------------------------------------------------------------------
forward(Peer, #event{} = M, Opts) ->
    do_forward(Peer, M, Opts);

forward(Peer, #error{} = M, Opts) ->
    do_forward(Peer, M, Opts);

forward(Peer, #interrupt{} = M, Opts) ->
    do_forward(Peer, M, Opts);

forward(Peer, #invocation{} = M, Opts) ->
    do_forward(Peer, M, Opts);

forward(Peer, #result{} = M, Opts) ->
    do_forward(Peer, M, Opts).




%% =============================================================================
%% API : GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    {ok, #state{}}.


handle_call(Event, From, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p, from=~p", [Event, From]
    ),
    {noreply, State}.


handle_cast({forward, #peer_message{} = Mssg} = Event, State) ->
    try
        cast_message(Mssg)
    catch
        Error:Reason ->
            %% @TODO publish metaevent
            _ = lager:error(
                "Error handling cast, event=~p, error=~p, reason=~p",
                [Event, Error, Reason]
            )
    end,
    {noreply, State};

handle_cast(#peer_ack{} = Ack, State) ->
    Node = #peer_ack.node,
    SessionId = #peer_ack.session_id,
    %% We are receving an ACK for a peer_message from another peer
    case Node =:= bondy_peer_service:mynode() of
        true ->
            %% Supporting process identifiers in Partisan, without changing the
            %% internal implementation of Erlang’s process identifiers, is not
            %% possible without allowing nodes to directly connect to every
            %% other node.
            %% See more details in forward/1.
            case bondy_session:lookup(SessionId) of
                {error, not_found} ->
                    %% We have an ACK for a peer who died in the interim
                    ok;
                Session ->
                    Pid = bondy_session:pid(Session),
                    Pid ! Ack
            end;
        false ->
            _ = lager:error(
                "Received a message targetted to another node; message=~p",
                [Ack]
            )
    end,
    {noreply, State};

handle_cast(#peer_message{} = Mssg, State) ->
    %% We are receiving a message from peer
    try bondy_router_worker:cast(fun() -> send(Mssg) end) of
        ok ->
            {noreply, State};
        {error, overload} ->
            ok = cast_message(peer_error(overload, Mssg)),
            {noreply, State}
    catch
        Error:Reason ->
            %% TODO publish metaevent
            _ = lager:error(
                "Error handling cast, error=~p, reason=~p, stacktrace=~p",
                [Error, Reason, erlang:get_stacktrace()]),
            {noreply, State}
    end.


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


%% @private
do_forward(PeerId, M, Opts) ->
    %% Remote monitoring is not possible given no connections are maintained
    %% directly between nodes.
    %% If remote monitoring is required, Partisan can additionally connect
    %% nodes over Distributed Erlang to provide this functionality but this will
    %% defeat the purpose of using Partisan in the first place.
    Timeout = maps:get(timeout, Opts),
    Id = bondy_utils:get_id(global),
    PM = #peer_message{id = Id, peer_id = PeerId, message = M, options = Opts},
    Ack = peer_ack(PM),

    ok = gen_server:cast(?MODULE, {forward, PM}),

    %% Now we need to wait for the remote forwarder to send us an ACK
    %% to be sure the wamp peer received the message
    receive
        Ack ->
            ok
    after
        Timeout ->
            %% maybe_enqueue(Enqueue, SessionId, M, timeout)
            exit(timeout)
    end.


%% @private
cast_message(#peer_message{} = Mssg) ->
    %% When process identifiers are transmitted between nodes, the process
    %% identifiers are translated based on the receiving nodes membership view.
    %% Supporting process identifiers in Partisan, without changing the
    %% internal implementation of Erlang’s process identifiers, is not
    %% possible without allowing nodes to directly connect to every other node.
    %% Instead of relying on Erlang’s process identifiers, Partisan recommends
    %% that processes that wish to receive messages from remote processes
    %% locally register a name that can be used instead of a process identifier
    %% when sending the message.
    Node = bondy_peer_service:mynode(),
    Channel = wamp,
    ServerRef = ?MODULE,
    Manager = bondy_peer_service:manager(),
    Manager:cast_message(Node, Channel, ServerRef, Mssg).


%% @private
peer_ack(#peer_message{} = Mssg) ->
    {Node, SessionId} = Mssg#peer_message.peer_id,
    Id = Mssg#peer_message.id,
    #peer_ack{node = Node, session_id = SessionId, id = Id}.


%% @private
peer_error(Reason, #peer_message{} = Mssg) ->
    {Node, SessionId} = Mssg#peer_message.peer_id,
    Id = Mssg#peer_message.id,
    #peer_error{
        node = Node,
        session_id = SessionId,
        id = Id,
        reason = Reason
    }.


%% @private
send(#peer_message{} = Mssg) ->
    {Node, SessionId} = Mssg#peer_message.peer_id,
    Opts = Mssg#peer_message.options,
    Pid = bondy_session:pid(SessionId),
    PeerId = {Node, SessionId, Pid},
    case Node =:= bondy_peer_service:mynode() of
        true ->
            ok = bondy:send(PeerId, Mssg#peer_message.message, Opts),
            %% We send the ack
            cast_message(peer_ack(Mssg));
        false ->
            _ = lager:error(
                "Received a message targetted at another node; message=~p",
                [Mssg]
            ),
            exit(invalid_node)
    end.