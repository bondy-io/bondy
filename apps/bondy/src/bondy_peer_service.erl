%% =============================================================================
%%  bondy_peer_service.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
%%  Copyright (c) 2015 Christopher Meiklejohn.  All Rights Reserved.
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
%% @doc
%% Based on: github.com/lasp-lang/lasp/...lasp_peer_service.erl
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_peer_service).
-include_lib("partisan/include/partisan.hrl").
-define(DEFAULT_PEER_SERVICE, bondy_partisan_peer_service).


-export([forward_message/3]).
-export([forward_message/4]).
-export([forward_message/5]).
-export([join/1]).
-export([join/2]).
-export([join/3]).
-export([leave/0]).
-export([leave/1]).
-export([manager/0]).
-export([members/0]).
-export([mynode/0]).
-export([myself/0]).
-export([peer_service/0]).
-export([peers/0]).
-export([stop/0]).
-export([stop/1]).



%% =============================================================================
%% CALLBACKS
%% =============================================================================


%% Forward message to registered process on the remote side.
-callback forward_message(name(), pid(), message()) -> ok.
-callback forward_message(name(), channel(), pid(), message()) -> ok.
-callback forward_message(name(), channel(), pid(), message(), options()) -> ok.


%% Attempt to join node.
-callback join(node()) -> ok | {error, atom()}.

%% Attempt to join node with or without automatically claiming ring
%% ownership.
-callback join(node(), boolean()) -> ok | {error, atom()}.

%% Attempt to join node with or without automatically claiming ring
%% ownership.
-callback join(node(), node(), boolean()) -> ok | {error, atom()}.

%% Remove myself from the cluster.
-callback leave() -> ok.

%% Remove a node from the cluster.
-callback leave(node()) -> ok.

%% Return manager.
-callback manager() -> module().

%% Return members of the cluster.
-callback members() -> {ok, [node()]}.

%% Return manager.
-callback myself() -> map().

%% Return manager.
-callback mynode() -> atom().

%% Stop the peer service on a given node.
-callback stop() -> ok.

%% Stop the peer service on a given node for a particular reason.
-callback stop(iolist()) -> ok.



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Return the currently active peer service.
%% @end
%% -----------------------------------------------------------------------------
peer_service() ->
    application:get_env(bondy, peer_service, ?DEFAULT_PEER_SERVICE).


%% -----------------------------------------------------------------------------
%% @doc Prepare node to join a cluster.
%% @end
%% ----------------------------------------------------------------------------
join(Node) ->
    do(join, [Node, true]).


%% -----------------------------------------------------------------------------
%% @doc Convert nodename to atom.
%% @end
%% -----------------------------------------------------------------------------
join(NodeStr, Auto) when is_list(NodeStr) ->
    do(join, [NodeStr, Auto]);

join(Node, Auto) when is_atom(Node) ->
    do(join, [Node, Auto]);

join(#{name := _Name, listen_addrs := _ListenAddrs} = Node, Auto) ->
    do(join, [Node, Auto]).


%% -----------------------------------------------------------------------------
%% @doc Initiate join. Nodes cannot join themselves.
%% @end
%% -----------------------------------------------------------------------------
join(Node, Node, Auto) ->
    do(join, [Node, Node, Auto]).


%% -----------------------------------------------------------------------------
%% @doc Forward message to registered process on the remote side.
%% @end
%% -----------------------------------------------------------------------------
forward_message(Name, ServerRef, Message) ->
    do(forward_message, [Name, ServerRef, Message]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
forward_message(Name, Channel, ServerRef, Message) ->
    do(forward_message, [Name, Channel, ServerRef, Message]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
forward_message(Name, Channel, ServerRef, Message, Opts) ->
    do(forward_message, [Name, Channel, ServerRef, Message, Opts]).


%% -----------------------------------------------------------------------------
%% @doc Return cluster members.
%% @end
%% -----------------------------------------------------------------------------
members() ->
    do(members, []).


%% -----------------------------------------------------------------------------
%% @doc The list of cluster members excluding ourselves
%% @end
%% -----------------------------------------------------------------------------
peers() ->
    case do(members, []) of
        {ok, [_]} -> {ok, []};
        {ok, L} -> {ok, L -- [mynode()]}
    end.


%% -----------------------------------------------------------------------------
%% @doc Return myself.
%% @end
%% -----------------------------------------------------------------------------
myself() ->
    do(myself, []).


%% -----------------------------------------------------------------------------
%% @doc Return myself.
%% @end
%% -----------------------------------------------------------------------------
mynode() ->
    do(mynode, []).


%% -----------------------------------------------------------------------------
%% @doc Return manager.
%% @end
%% -----------------------------------------------------------------------------
manager() ->
    do(manager, []).


%% -----------------------------------------------------------------------------
%% @doc Leave the cluster.
%% @end
%% -----------------------------------------------------------------------------
leave() ->
    do(leave, []).


%% -----------------------------------------------------------------------------
%% @doc Leave the cluster.
%% @end
%% -----------------------------------------------------------------------------
leave(Peer) ->
    do(leave, [Peer]).


%% -----------------------------------------------------------------------------
%% @doc Stop node.
%% @end
%% -----------------------------------------------------------------------------
stop() ->
    stop(stop_request_received).


%% -----------------------------------------------------------------------------
%% @doc Stop node for a given reason.
%% @end
%% -----------------------------------------------------------------------------
stop(Reason) ->
    do(stop, [Reason]).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Execute call to the proper backend.
%% @end
%% -----------------------------------------------------------------------------
do(Function, Args) ->
    Backend = peer_service(),
    erlang:apply(Backend, Function, Args).


