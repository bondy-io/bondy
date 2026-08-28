%% =============================================================================
%%  bondy_mst_test_crdt_server.erl -
%%
%%  Copyright (c) 2023-2025 Leapsight. All rights reserved.
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
-module(bondy_mst_test_crdt_server).

-behaviour(bondy_mst_crdt).
-behaviour(gen_server).

-include_lib("common_test/include/ct.hrl").

%% API
-export([peers/0]).
-export([start_all/1]).
-export([start/2]).

%% BONDY_MSRT_GROVE CALLBACKS
-export([send/2]).
-export([broadcast/1]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

peers() ->
    [
        peer1,
        peer2,
        peer3
    ].

start_all(Opts) ->
    start(Opts, peers()).

start(#{store := _, store_opts := #{name := _}} = Opts, Peers) ->
    Started = [
        begin
            {ok, _} = start_link(NodeId, Opts),
            NodeId
        end
     || NodeId <- Peers
    ],
    {ok, Started}.

start_link(NodeId, Opts) when is_atom(NodeId) ->
    ServerOpts = [
        {spawn_opt, [{message_queue_data, off_heap}]}
    ],
    gen_server:start_link({local, NodeId}, ?MODULE, [NodeId, Opts], ServerOpts).

%% =============================================================================
%% bondy_mst_crdt CALLBACKS
%% =============================================================================

send(Peer, Message) ->
    gen_server:cast(Peer, {grove_message, Message}).

broadcast(Gossip) ->
    Myself = element(2, Gossip),
    Peers = peers() -- [Myself],

    ct:pal("Broadcasting event ~p to peer ~p", [Gossip, Peers]),
    _ = [send(Peer, Gossip) || Peer <- Peers],
    ok.

%% =============================================================================
%% GEN_SERVER BEHAVIOR CALLBACKS
%% ============================================================================

init([NodeId, Opts0]) ->
    %% Trap exists otherwise terminate/1 won't be called when shutdown by
    %% supervisor.
    erlang:process_flag(trap_exit, true),

    StoreOpts0 = key_value:get(store_opts, Opts0, #{}),
    Name0 = key_value:get(name, StoreOpts0),
    Name = <<Name0/binary, "-", (atom_to_binary(NodeId))/binary>>,
    StoreOpts = key_value:put(name, Name, StoreOpts0),
    Opts1 = key_value:put(store_opts, StoreOpts, Opts0),
    Defaults = #{
        callback_mod => ?MODULE,
        max_merges => 3,
        max_same_merge => 1
    },
    Opts = maps:merge(Defaults, Opts1),

    %% We create an ets-based MST bound to this process.
    %% The ets table will be garbage collected if this process terminates.
    Grove = bondy_mst_crdt:new(NodeId, Opts),
    {ok, Grove}.

handle_call(ping, _From, Grove) ->
    {reply, pong, Grove};
handle_call(root, _From, Grove) ->
    ct:pal("handling root"),
    Reply = bondy_mst_crdt:root(Grove),
    {reply, Reply, Grove};
handle_call({get, Key}, _From, Grove) ->
    ct:pal("handling get key: ~p", [Key]),
    Reply = bondy_mst:get(bondy_mst_crdt:tree(Grove), Key),
    {reply, Reply, Grove};
handle_call(gc, _From, Grove0) ->
    ct:pal("Triggering GC on peer"),
    Grove = bondy_mst_crdt:gc(Grove0, [bondy_mst_crdt:root(Grove0)]),
    {reply, ok, Grove};
handle_call(list, _From, Grove) ->
    ct:pal("handling list"),
    Reply = bondy_mst:to_list(bondy_mst_crdt:tree(Grove)),
    {reply, Reply, Grove};
handle_call(list_pages, _From, Grove) ->
    ct:pal("handling list_pages"),
    Store = bondy_mst:store(bondy_mst_crdt:tree(Grove)),
    Reply = bondy_mst_store:list(Store),
    {reply, Reply, Grove};
handle_call({fold_pages, Fun, Acc, Opts}, _From, Grove) ->
    ct:pal("handling fold_pages"),
    Tree = bondy_mst_crdt:tree(Grove),
    Reply = bondy_mst:fold_pages(Tree, Fun, Acc, Opts),
    {reply, Reply, Grove};
handle_call({put, Key}, _From, Grove0) ->
    ct:pal("handling put key: ~p", [Key]),
    Grove1 = bondy_mst_crdt:put(Grove0, Key, true),
    {reply, ok, Grove1};
handle_call({put, Key, Value}, _From, Grove0) ->
    ct:pal("handling put key: ~p, value: ~p", [Key, Value]),
    Grove1 = bondy_mst_crdt:put(Grove0, Key, Value),
    {reply, ok, Grove1};
handle_call({trigger, Peer}, _From, Grove) ->
    ct:pal("Triggering sync on peer: ~p", [Peer]),
    Reply = bondy_mst_crdt:trigger(Grove, Peer),
    {reply, Reply, Grove};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({grove_message, Message}, Grove0) ->
    ct:pal(
        "(~p) Handling grove_message: ~p",
        [bondy_mst_crdt:node_id(Grove0), Message]
    ),
    Grove = bondy_mst_crdt:handle(Grove0, Message),
    {noreply, Grove};
handle_cast(_Request, Grove) ->
    {noreply, Grove}.

handle_info(_, Grove) ->
    {noreply, Grove}.

terminate(_Reason, _Grove) ->
    ok.
