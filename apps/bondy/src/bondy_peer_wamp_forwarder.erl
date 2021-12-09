%% =============================================================================
%%  bondy_peer_wamp_forwarder.erl - forwards INVOCATION (their RESULT or
%%  ERROR), INTERRUPT and PUBLISH messages between WAMP clients connected to
%%  different Bondy peers (nodes).
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
%% @doc A gen_server that forwards INVOCATION (their RESULT or ERROR), INTERRUPT
%% and EVENT messages between WAMP clients connected to different Bondy peers
%% (nodes).
%%
%% ```
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
%% '''
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_peer_wamp_forwarder).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").


-define(FORWARD_TIMEOUT, 5000).

-record(peer_ack, {
    from        ::  bondy_ref:t(),
    id          ::  id()
}).

-record(peer_error, {
    from        ::  bondy_ref:t(),
    id          ::  id(),
    reason      ::  any()
}).

-record(state, {
}).



%% API
-export([start_link/0]).
-export([forward/4]).
-export([broadcast/4]).
-export([async_forward/4]).
-export([receive_ack/2]).

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
%% @doc Forwards a wamp message to a peer (cluster node).
%% It returns `ok' when the remote bondy_peer_wamp_forwarder acknoledges the
%% reception of the message, but it does not imply the message handler has
%% actually received the message.
%%
%% This only works for PUBLISH, ERROR, INTERRUPT, INVOCATION and RESULT WAMP
%% message types. It will fail with an exception if another type is passed
%% as the third argument.
%%
%% This is equivalent to calling async_forward/3 and then yield/2.
%% @end
%% -----------------------------------------------------------------------------
-spec forward(bondy_ref:t(), bondy_ref:t(), wamp_message(), map()) ->
    ok | no_return().

forward(From, To, Msg, Opts) ->
    {ok, Id} = async_forward(From, To, Msg, Opts),
    Timeout = maps:get(timeout, Opts, ?FORWARD_TIMEOUT),
    receive_ack(Id, Timeout).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec async_forward(
    bondy_ref:t(), bondy_ref:t(), wamp_message(), map()) ->
    {ok, id()} | no_return().

async_forward(From, To, Msg, Opts) ->
    %% Remote monitoring is not possible given no connections are maintained
    %% directly between nodes.
    %% If remote monitoring is required, Partisan can additionally connect
    %% nodes over Distributed Erlang to provide this functionality but this will
    %% defeat the purpose of using Partisan in the first place.
    PeerMssg = bondy_peer_message:new(From, To, Msg, Opts),

    Id = bondy_peer_message:id(PeerMssg),

    BinPid = bondy_utils:pid_to_bin(self()),

    ok = gen_server:cast(?MODULE, {forward, PeerMssg, BinPid}),

    {ok, Id}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec broadcast(bondy_ref:t(), [node()], wamp_message(), map()) ->
    {ok, Good :: [node()], Bad :: [node()]}.

broadcast(From, Nodes, M, Opts) ->
    RealmUri = bondy_ref:realm_uri(From),

    %% We forward the message to the other nodes
    IdNodes = [
        begin
            To = bondy_ref:new(
                internal, RealmUri, {?MODULE, handle, []}, Node
            ),
            {ok, Id} = async_forward(From, To, M, Opts),
            {Id, Node}
        end
        || Node <- Nodes
    ],

    Timeout = maps:get(timeout, Opts, 5000),
    receive_broadcast_acks(IdNodes, Timeout, [], []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec receive_ack(bondy_ref:t(), timeout()) -> ok | no_return().

receive_ack(Id, Timeout) ->
    %% We wait for the remote forwarder to send us an ACK
    %% to be sure the wamp peer received the message
    receive
        #peer_ack{id = Val} when Val == Id ->
            ok;
        #peer_error{id = Val, reason = Reason} when Val == Id ->
            error(Reason)
    after
        Timeout ->
            %% maybe_enqueue(Enqueue, SessionId, M, timeout)
            error(timeout)
    end.



%% =============================================================================
%% API : GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    {ok, #state{}}.


handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_cast({forward, Msg, BinPid} = Event, State) ->
    try
        cast_message(BinPid, Msg)
    catch
        Class:Reason:Stacktrace ->
            %% @TODO publish metaevent
            ?LOG_ERROR(#{
                class => Class,
                event => Event,
                reason => Reason,
                stacktrace => Stacktrace
            })
    end,
    {noreply, State};

handle_cast({'receive', #peer_ack{from = FromRef} = Msg, BinPid}, State) when is_record(Msg, peer_ack) orelse is_record(Msg, peer_error) ->
    %% We are receving an ACK or Error for a message we have previously
    %% forwarded
    RealmUri = bondy_ref:realm_uri(FromRef),

    _ = case bondy_ref:is_local(FromRef) of
        true ->
            %% We use the pid-to-bin trick since we are just waiting for an ack
            %% in case the process died we are not interested in queueing the
            %% ack on behalf of the session (session_resumption)
            Pid = bondy_utils:bin_to_pid(BinPid),
            Pid ! Msg;
        false ->
            ?LOG_WARNING(#{
                description => "Received a message targetted to another node",
                realm_uri => RealmUri,
                wamp_message => Msg
            })
    end,
    {noreply, State};

handle_cast({'receive', Msg, BinPid}, State) ->
    %% We are receiving a message from peer
    try
        bondy_peer_message:is_message(Msg) orelse throw(badarg),

        %% This in theory breaks the CALL order guarantee!!!
        %% We either implement causality or we just use hashing over a pool of
        %% workers by {CallerID, CalleeId}
        Job = fun() ->
            ok = bondy_router:handle_peer_message(Msg),
            %% We send the ack to the remote node
            cast_message(peer_ack(Msg), BinPid)
        end,
        ok = case bondy_router_worker:cast(Job) of
            ok ->
                ok;
            {error, overload} ->
                cast_message(peer_error(overload, Msg), BinPid)
        end,

        {noreply, State}

    catch
        throw:badarg ->
            ok = cast_message(peer_error(badarg, Msg), BinPid),
            {noreply, State};
        Class:Reason:Stacktrace ->
            %% TODO publish metaevent
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok = cast_message(peer_error(Reason, Msg), BinPid),
            {noreply, State}
    end.


handle_info(Info, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Info
    }),
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
receive_broadcast_acks([{Id, Node}|T], Timeout, Good, Bad) ->
    try receive_ack(Id, Timeout) of
        ok ->
            receive_broadcast_acks(T, Timeout, [Node|Good], Bad)
    catch
        _:_ ->
            receive_broadcast_acks(T, Timeout, Good, [Node|Bad])
    end;

receive_broadcast_acks([], _, Good, Bad) ->
    {ok, Good, Bad}.



%% @private
cast_message(Msg, BinPid) ->
    Node = peer_node(Msg),
    Manager = bondy_peer_service:manager(),
    Channel = bondy_config:get(wamp_peer_channel, default),
    ServerRef = ?MODULE,
    Manager:cast_message(Node, Channel, ServerRef, {'receive', Msg, BinPid}).


%% @private
peer_node(#peer_ack{from = Ref}) ->
    bondy_ref:node(Ref);

peer_node(#peer_error{from = Ref}) ->
    bondy_ref:node(Ref);

peer_node(Msg) ->
    bondy_peer_message:node(Msg).


%% @private
peer_ack(Msg) ->
    #peer_ack{
        from = bondy_peer_message:from(Msg),
        id = bondy_peer_message:id(Msg)
    }.


%% @private
peer_error(Reason, Msg) ->
    #peer_error{
        from = bondy_peer_message:from(Msg),
        id = bondy_peer_message:id(Msg),
        reason = Reason
    }.

