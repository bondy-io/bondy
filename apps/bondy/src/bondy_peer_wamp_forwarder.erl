%% =============================================================================
%%  bondy_peer_wamp_forwarder.erl - forwards INVOCATION (their RESULT or
%%  ERROR), INTERRUPT and PUBLISH messages between WAMP clients connected to
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




-record(peer_ack, {
    from        ::  {uri(), Node :: atom()},
    id          ::  id()
}).

-record(peer_error, {
    from        ::  {uri(), Node :: atom()},
    id          ::  id(),
    reason      ::  any()
}).

-record(state, {
}).



%% API
-export([start_link/0]).
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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_link() -> {'ok', pid()} | 'ignore' | {'error', term()}.

start_link() ->
    %% bondy_peer_wamp_forwarder may receive a huge amount of
    %% messages. Make sure that they are stored off heap to
    %% avoid exessive GCs. This makes messaging slower though.
    SpawnOpts = [
        {spawn_opt, [{message_queue_data, off_heap}]}
    ],
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], SpawnOpts).


%% -----------------------------------------------------------------------------
%% @doc Forwards a wamp message to a peer (node).
%% This only works for EVENT, ERROR, INTERRUPT, INVOCATION and RESULT wamp
%% message types. It will fail with an exception if another type is passed
%% as the second argument.
%% @end
%% -----------------------------------------------------------------------------
-spec forward(remote_peer_id(), wamp_message(), map()) ->
    ok | no_return().

forward(PeerId, Mssg, Opts) when is_tuple(PeerId) ->
    %% Remote monitoring is not possible given no connections are maintained
    %% directly between nodes.
    %% If remote monitoring is required, Partisan can additionally connect
    %% nodes over Distributed Erlang to provide this functionality but this will
    %% defeat the purpose of using Partisan in the first place.
    Timeout = maps:get(timeout, Opts),
    PeerMssg = bondy_peer_message:new(PeerId, Mssg, Opts),
    Id = bondy_peer_message:id(PeerMssg),
    BinPid = pid_to_bin(self()),


    ok = gen_server:cast(?MODULE, {forward, PeerMssg, BinPid}),

    %% Now we need to wait for the remote forwarder to send us an ACK
    %% to be sure the wamp peer received the message
    receive
        #peer_ack{id = Id} ->
            ok;
        #peer_error{id = Id, reason = Reason} ->
            exit(Reason)
    after
        Timeout ->
            %% maybe_enqueue(Enqueue, SessionId, M, timeout)
            exit(timeout)
    end.





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


handle_cast({forward, Mssg, BinPid} = Event, State) ->
    try
        cast_message(Mssg, BinPid)
    catch
        Error:Reason ->
            %% @TODO publish metaevent
            _ = lager:error(
                "Error handling cast, event=~p, error=~p, reason=~p",
                [Event, Error, Reason]
            )
    end,
    {noreply, State};

handle_cast({'receive', AckOrError, BinPid}, State)
when is_record(AckOrError, peer_ack) orelse is_record(AckOrError, peer_error) ->
    %% We are receving an ACK o Error for a message we have previously forwarded
    {RealmUri, Node} = AckOrError#peer_ack.from,

    case Node =:= bondy_peer_service:mynode() of
        true ->
            %% Supporting process identifiers in Partisan, without changing the
            %% internal implementation of Erlang’s process identifiers, is not
            %% possible without allowing nodes to directly connect to every
            %% other node.
            %% See more details in forward/1.
            %% We use the pid-to-bin trick since we are just waiting for an ack
            %% in case the process died we are not interested in queueing the
            %% ack on behalf of the session (session_resumption)
            Pid = bin_to_pid(BinPid),
            Pid ! AckOrError;
        false ->
            _ = lager:error(
                "Received a message targetted to another node; realm_uri=~p, message=~p",
                [RealmUri, AckOrError]
            )
    end,
    {noreply, State};

handle_cast({'receive', Mssg, BinPid}, State) ->
    %% We are receiving a message from peer
    try
        bondy_peer_message:is_message(Mssg) orelse throw(badarg),

        Job = fun() ->
            ok = bondy_router:handle_peer_message(Mssg),
            %% We send the ack to the remote node
            cast_message(peer_ack(Mssg), BinPid)
        end,

        ok = case bondy_router_worker:cast(Job) of
            ok ->
                ok;
            {error, overload} ->
                cast_message(peer_error(overload, Mssg), BinPid)
        end,

        {noreply, State}

    catch
        throw:badarg ->
            ok = cast_message(peer_error(badarg, Mssg), BinPid),
            {noreply, State};
        Error:Reason ->
            %% TODO publish metaevent
            _ = lager:error(
                "Error handling cast, error=~p, reason=~p, stacktrace=~p",
                [Error, Reason, erlang:get_stacktrace()]),
            ok = cast_message(peer_error(Reason, Mssg), BinPid),
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
cast_message(Mssg, BinPid) ->
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
    Channel = wamp_channel,
    ServerRef = ?MODULE,
    Manager = bondy_peer_service:manager(),
    Manager:cast_message(Node, Channel, ServerRef, {'receive', Mssg, BinPid}).


%% @private
peer_ack(Mssg) ->
    #peer_ack{
        from = bondy_peer_message:from(Mssg),
        id = bondy_peer_message:id(Mssg)
    }.


%% @private
peer_error(Reason, Mssg) ->
    #peer_error{
        from = bondy_peer_message:from(Mssg),
        id = bondy_peer_message:id(Mssg),
        reason = Reason
    }.


%% %% @private
%% send(Mssg) ->
%%     {RealmUri, Node, SessionId} = bondy_peer_message:peer_id(Mssg),
%%     %% We match for extra validation
%%     LocalPeerId = bondy_session:peer_id(SessionId),
%%     {RealmUri, Node, SessionId, _Pid} = LocalPeerId,

%%     Opts = bondy_peer_message:options(Mssg),
%%     Payload = bondy_peer_message:payload(Mssg),

%%     case Node =:= bondy_peer_service:mynode() of
%%         true ->
%%             ok = bondy:send(LocalPeerId, Payload, Opts),
%%             %% We send the ack to the remote node
%%             cast_message(peer_ack(Mssg));
%%         false ->
%%             _ = lager:error(
%%                 "Received a message targeted at another node; message=~p",
%%                 [Mssg]
%%             ),
%%             exit(invalid_node)
%%     end.


%% @private
pid_to_bin(Pid) ->
    list_to_binary(pid_to_list(Pid)).


%% @private
bin_to_pid(Bin) ->
    list_to_pid(binary_to_list(Bin)).